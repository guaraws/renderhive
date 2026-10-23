//! Per-thread GVL accounting (Ruby >= 3.3, Unix: Ruby does not fire thread
//! events on Windows/WebAssembly).
//!
//! A process-wide thread-event hook timestamps every GVL transition and
//! accumulates, for each Ruby thread that opted in, how long it *held* the
//! GVL (running Ruby / C code) and how long it *waited* for it (runnable but
//! blocked behind another thread). Whatever remains of a wall-clock interval
//! is time spent off the GVL: blocking I/O, sleeps, DB round-trips.
//!
//! Renderhive uses the split to decide whether parallel rendering can pay
//! off: only off-GVL time can overlap across MRI threads.
//!
//! Hook callbacks run without the GVL (except RESUMED) and may run on a
//! native thread other than the Ruby thread's own, so per-thread state is
//! reached through `event_data->thread` + Ruby's thread-specific storage and
//! kept in atomics. Only threads that called `gvl_stats` carry state; every
//! other thread costs one `rb_internal_thread_specific_get` per transition.

use magnus::{Error, Ruby};
use rb_sys::{
    rb_event_flag_t, rb_internal_thread_add_event_hook, rb_internal_thread_event_data_t,
    rb_internal_thread_specific_get, rb_internal_thread_specific_key_create,
    rb_internal_thread_specific_key_t, rb_internal_thread_specific_set, rb_thread_current,
    RUBY_INTERNAL_THREAD_EVENT_EXITED, RUBY_INTERNAL_THREAD_EVENT_READY,
    RUBY_INTERNAL_THREAD_EVENT_RESUMED, RUBY_INTERNAL_THREAD_EVENT_SUSPENDED,
};
use std::os::raw::c_void;
use std::sync::atomic::{AtomicU64, Ordering::Relaxed};
use std::sync::OnceLock;
use std::time::Instant;

#[derive(Default)]
struct ThreadStats {
    held_ns: AtomicU64,
    wait_ns: AtomicU64,
    /// When the thread last acquired the GVL (0 = not holding it).
    resumed_at: AtomicU64,
    /// When the thread became runnable and started waiting (0 = not waiting).
    ready_at: AtomicU64,
}

static KEY: OnceLock<rb_internal_thread_specific_key_t> = OnceLock::new();
static EPOCH: OnceLock<Instant> = OnceLock::new();

/// Monotonic nanoseconds, never 0 (0 marks an unset timestamp).
#[inline]
fn now_ns() -> u64 {
    EPOCH.get_or_init(Instant::now).elapsed().as_nanos() as u64 + 1
}

unsafe extern "C" fn on_thread_event(
    event: rb_event_flag_t,
    data: *const rb_internal_thread_event_data_t,
    _user: *mut c_void,
) {
    let Some(&key) = KEY.get() else { return };
    let thread = (*data).thread;
    let ptr = rb_internal_thread_specific_get(thread, key) as *mut ThreadStats;
    if ptr.is_null() {
        return;
    }

    if event == RUBY_INTERNAL_THREAD_EVENT_EXITED {
        rb_internal_thread_specific_set(thread, key, std::ptr::null_mut());
        drop(Box::from_raw(ptr));
        return;
    }

    let stats = &*ptr;
    let now = now_ns();
    match event {
        RUBY_INTERNAL_THREAD_EVENT_READY => stats.ready_at.store(now, Relaxed),
        RUBY_INTERNAL_THREAD_EVENT_RESUMED => {
            let ready = stats.ready_at.swap(0, Relaxed);
            if ready != 0 {
                stats.wait_ns.fetch_add(now.saturating_sub(ready), Relaxed);
            }
            stats.resumed_at.store(now, Relaxed);
        }
        RUBY_INTERNAL_THREAD_EVENT_SUSPENDED => {
            let resumed = stats.resumed_at.swap(0, Relaxed);
            if resumed != 0 {
                stats.held_ns.fetch_add(now.saturating_sub(resumed), Relaxed);
            }
        }
        _ => {}
    }
}

fn key(ruby: &Ruby) -> Result<rb_internal_thread_specific_key_t, Error> {
    if let Some(&key) = KEY.get() {
        return Ok(key);
    }
    // Called with the GVL held, so creation cannot race with itself.
    let key = unsafe { rb_internal_thread_specific_key_create() };
    if key < 0 {
        return Err(Error::new(ruby.exception_runtime_error(), "no thread-specific key available"));
    }
    let _ = KEY.set(key);
    unsafe {
        rb_internal_thread_add_event_hook(
            Some(on_thread_event),
            RUBY_INTERNAL_THREAD_EVENT_READY
                | RUBY_INTERNAL_THREAD_EVENT_RESUMED
                | RUBY_INTERNAL_THREAD_EVENT_SUSPENDED
                | RUBY_INTERNAL_THREAD_EVENT_EXITED,
            std::ptr::null_mut(),
        );
    }
    Ok(key)
}

/// `[held_ns, wait_ns, now_ns]` for the calling thread, which holds the GVL.
/// The first call for a thread starts its accounting (counters at zero);
/// callers work with deltas between two snapshots.
pub fn current_thread_stats(ruby: &Ruby) -> Result<Option<(u64, u64, u64)>, Error> {
    let key = key(ruby)?;
    let now = now_ns();
    unsafe {
        let thread = rb_thread_current();
        let mut ptr = rb_internal_thread_specific_get(thread, key) as *mut ThreadStats;
        if ptr.is_null() {
            let stats = ThreadStats::default();
            stats.resumed_at.store(now, Relaxed);
            ptr = Box::into_raw(Box::new(stats));
            rb_internal_thread_specific_set(thread, key, ptr as *mut c_void);
        }
        let stats = &*ptr;
        let resumed = stats.resumed_at.load(Relaxed);
        if resumed == 0 {
            // Hook installed while this thread already held the GVL.
            stats.resumed_at.store(now, Relaxed);
        }
        let running = if resumed == 0 { 0 } else { now - resumed };
        Ok(Some((
            stats.held_ns.load(Relaxed) + running,
            stats.wait_ns.load(Relaxed),
            now,
        )))
    }
}
