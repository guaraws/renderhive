use magnus::{function, prelude::*, Error, RArray, RString, Ruby};
use rayon::prelude::*;

// Inputs larger than this (in total bytes) and with more than one fragment are
// concatenated using a parallel, multi-core memory copy. Below the threshold a
// single-threaded copy wins because it avoids the rayon scheduling overhead.
const PARALLEL_THRESHOLD_BYTES: usize = 64 * 1024;

/// Concatenates an array of strings (HTML fragments) into a single string.
///
/// The whole result is allocated once and then filled in a single pass, which
/// avoids the repeated reallocations performed by Ruby's incremental
/// `String#<<` / `ActiveSupport::SafeBuffer#<<`. For large payloads the copy is
/// spread across CPU cores with rayon, giving true parallelism that is not
/// constrained by the GVL (each worker only touches disjoint byte ranges).
///
/// Safety: all source pointers belong to Ruby strings referenced by `arr`,
/// which is kept alive for the duration of the call. Because the GVL is held
/// throughout, the GC cannot run and therefore cannot move or free those
/// strings, so the raw pointers stay valid while we copy.
fn join_buffers(ruby: &Ruby, arr: RArray) -> Result<RString, Error> {
    let len = arr.len();
    if len == 0 {
        return Ok(ruby.str_new(""));
    }

    // (destination offset, source pointer as usize, byte length)
    let mut segments: Vec<(usize, usize, usize)> = Vec::with_capacity(len);
    let mut total: usize = 0;

    for item in arr.into_iter() {
        let rstring = RString::from_value(item).ok_or_else(|| {
            Error::new(
                ruby.exception_type_error(),
                "join_buffers espera um Array de Strings",
            )
        })?;

        let bytes = unsafe { rstring.as_slice() };
        let byte_len = bytes.len();
        segments.push((total, bytes.as_ptr() as usize, byte_len));
        total += byte_len;
    }

    if total == 0 {
        return Ok(ruby.str_new(""));
    }

    let mut buf: Vec<u8> = vec![0u8; total];
    let dst = buf.as_mut_ptr() as usize;

    if total >= PARALLEL_THRESHOLD_BYTES && segments.len() > 1 {
        segments.par_iter().for_each(|&(offset, src, src_len)| {
            if src_len == 0 {
                return;
            }
            unsafe {
                std::ptr::copy_nonoverlapping(
                    src as *const u8,
                    (dst as *mut u8).add(offset),
                    src_len,
                );
            }
        });
    } else {
        for &(offset, src, src_len) in &segments {
            if src_len == 0 {
                continue;
            }
            unsafe {
                std::ptr::copy_nonoverlapping(
                    src as *const u8,
                    (dst as *mut u8).add(offset),
                    src_len,
                );
            }
        }
    }

    Ok(ruby.str_from_slice(&buf))
}

/// HTML-escapes a string using the exact replacement set Rails relies on
/// (`&`, `<`, `>`, `"`, `'`), matching `ERB::Util.html_escape` /
/// `CGI.escapeHTML`.
///
/// Fast paths:
/// * When the input contains no escapable byte, the original `RString` is
///   returned untouched (zero allocation, encoding preserved).
/// * Otherwise the safe runs between escapable bytes are copied in bulk
///   instead of byte-by-byte, and the whole result is allocated once.
///
/// The five escapable characters are all ASCII (< 0x80), so scanning raw
/// bytes is safe for UTF-8 input: multibyte continuation bytes are always
/// >= 0x80 and can never be mistaken for a delimiter.
fn escape_html(ruby: &Ruby, input: RString) -> Result<RString, Error> {
    let bytes = unsafe { input.as_slice() };

    match escape_html_bytes(bytes) {
        None => Ok(input),
        Some(escaped) => Ok(ruby.str_from_slice(&escaped)),
    }
}

#[inline]
fn replacement(byte: u8) -> Option<&'static [u8]> {
    match byte {
        b'&' => Some(b"&amp;"),
        b'<' => Some(b"&lt;"),
        b'>' => Some(b"&gt;"),
        b'"' => Some(b"&quot;"),
        b'\'' => Some(b"&#39;"),
        _ => None,
    }
}

/// Returns `None` when nothing needs escaping, otherwise the escaped bytes.
fn escape_html_bytes(bytes: &[u8]) -> Option<Vec<u8>> {
    // Reserve a little headroom so the common case avoids reallocations.
    let mut out: Vec<u8> = Vec::new();
    let mut last = 0usize;
    let mut escaped_any = false;

    for (i, &byte) in bytes.iter().enumerate() {
        if let Some(rep) = replacement(byte) {
            if !escaped_any {
                out.reserve(bytes.len() + bytes.len() / 8 + 16);
                escaped_any = true;
            }
            out.extend_from_slice(&bytes[last..i]);
            out.extend_from_slice(rep);
            last = i + 1;
        }
    }

    if !escaped_any {
        return None;
    }

    out.extend_from_slice(&bytes[last..]);
    Some(out)
}

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let module = ruby.define_module("Renderhive")?;
    let native = module.define_module("Native")?;
    native.define_singleton_method("join_buffers", function!(join_buffers, 1))?;
    native.define_singleton_method("escape_html", function!(escape_html, 1))?;
    Ok(())
}
