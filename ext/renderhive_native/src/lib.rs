use magnus::{
    encoding::EncodingCapable, function, prelude::*, rb_sys::AsRawValue, Error, RArray, RString,
    Ruby,
};
use std::os::raw::c_long;

#[cfg(all(ruby_gte_3_3, unix))]
mod gvl;

fn expect_string(ruby: &Ruby, item: magnus::Value) -> Result<RString, Error> {
    RString::from_value(item).ok_or_else(|| {
        Error::new(
            ruby.exception_type_error(),
            "join_buffers expects an Array of Strings",
        )
    })
}

/// Allocates an empty, UTF-8 tagged Ruby string with room for `len` bytes and
/// returns it together with a pointer to its (uninitialized) storage.
///
/// The encoding is set while the string is still empty so that the final
/// `rb_str_set_len` derives the coderange under UTF-8 instead of inheriting a
/// stale ASCII-8BIT one.
fn utf8_buffer(ruby: &Ruby, len: usize) -> Result<(RString, *mut u8), Error> {
    let out = ruby.str_buf_new(len);
    out.enc_associate(ruby.utf8_encindex())?;
    let ptr = unsafe { rb_sys::RSTRING_PTR(out.as_raw()) as *mut u8 };
    Ok((out, ptr))
}

/// Joins already-rendered HTML fragments into one UTF-8 Ruby string.
///
/// The output length is computed with overflow checks, the destination is
/// allocated exactly once, and every fragment is `memcpy`'d straight into the
/// Ruby string's storage (no intermediate Rust buffer, no per-fragment
/// `rb_str_cat` bookkeeping). The GVL is held throughout: the sources are
/// Ruby-owned strings.
fn join_buffers(ruby: &Ruby, arr: RArray) -> Result<RString, Error> {
    let mut total = 0usize;
    for item in arr.into_iter() {
        total = total
            .checked_add(expect_string(ruby, item)?.len())
            .filter(|&n| n <= isize::MAX as usize)
            .ok_or_else(|| Error::new(ruby.exception_arg_error(), "joined buffer is too large"))?;
    }

    // Allocate before borrowing any source bytes: allocation can trigger GC
    // compaction, which may move embedded string contents.
    let (out, dst) = utf8_buffer(ruby, total)?;
    let mut offset = 0usize;
    for item in arr.into_iter() {
        let string = expect_string(ruby, item)?;
        // No Ruby allocation happens between borrowing `src` and the copy.
        let src = unsafe { string.as_slice() };
        if offset + src.len() > total {
            // The array was mutated concurrently; never write past capacity.
            return Err(Error::new(
                ruby.exception_runtime_error(),
                "join_buffers input changed during join",
            ));
        }
        unsafe { std::ptr::copy_nonoverlapping(src.as_ptr(), dst.add(offset), src.len()) };
        offset += src.len();
    }
    unsafe { rb_sys::rb_str_set_len(out.as_raw(), offset as c_long) };
    Ok(out)
}

/// Extra output bytes produced by each input byte (0 = copied verbatim).
static ESCAPE_EXTRA: [u8; 256] = {
    let mut table = [0u8; 256];
    table[b'&' as usize] = 4; // &amp;
    table[b'<' as usize] = 3; // &lt;
    table[b'>' as usize] = 3; // &gt;
    table[b'"' as usize] = 5; // &quot;
    table[b'\'' as usize] = 4; // &#39;
    table
};

/// Replacement padded to 8 bytes, so it can be stored with one unaligned
/// 64-bit write, and its real length.
#[inline(always)]
fn replacement(byte: u8) -> ([u8; 8], usize) {
    match byte {
        b'&' => (*b"&amp;\0\0\0", 5),
        b'<' => (*b"&lt;\0\0\0\0", 4),
        b'>' => (*b"&gt;\0\0\0\0", 4),
        b'"' => (*b"&quot;\0\0", 6),
        _ => (*b"&#39;\0\0\0", 5),
    }
}

/// Bytes `escape_into` may write past the escaped length (fixed-width
/// stores); destinations must reserve this much extra capacity.
const ESCAPE_SLACK: usize = 16;

const BLOCK: usize = 16;

/// Bit `i` is set when `block[i]` must be escaped.
#[cfg(target_arch = "x86_64")]
#[inline(always)]
fn special_mask(block: &[u8; BLOCK]) -> u32 {
    use std::arch::x86_64::*;
    // SSE2 is part of the x86_64 baseline, so no runtime detection needed.
    unsafe {
        let v = _mm_loadu_si128(block.as_ptr() as *const __m128i);
        let hits = _mm_or_si128(
            _mm_or_si128(
                _mm_cmpeq_epi8(v, _mm_set1_epi8(b'&' as i8)),
                _mm_cmpeq_epi8(v, _mm_set1_epi8(b'<' as i8)),
            ),
            _mm_or_si128(
                _mm_or_si128(
                    _mm_cmpeq_epi8(v, _mm_set1_epi8(b'>' as i8)),
                    _mm_cmpeq_epi8(v, _mm_set1_epi8(b'"' as i8)),
                ),
                _mm_cmpeq_epi8(v, _mm_set1_epi8(b'\'' as i8)),
            ),
        );
        _mm_movemask_epi8(hits) as u32
    }
}

#[cfg(not(target_arch = "x86_64"))]
#[inline(always)]
fn special_mask(block: &[u8; BLOCK]) -> u32 {
    let mut mask = 0u32;
    for (i, &b) in block.iter().enumerate() {
        mask |= ((ESCAPE_EXTRA[b as usize] != 0) as u32) << i;
    }
    mask
}

/// Calls `f(index)` for every byte of `bytes` that must be escaped, in order.
/// Clean 16-byte blocks cost a handful of vector instructions.
#[inline(always)]
fn for_each_special(bytes: &[u8], mut f: impl FnMut(usize)) {
    let mut chunks = bytes.chunks_exact(BLOCK);
    let mut base = 0usize;
    for chunk in &mut chunks {
        let mut mask = special_mask(chunk.try_into().unwrap());
        while mask != 0 {
            f(base + mask.trailing_zeros() as usize);
            mask &= mask - 1;
        }
        base += BLOCK;
    }
    for (i, &b) in chunks.remainder().iter().enumerate() {
        if ESCAPE_EXTRA[b as usize] != 0 {
            f(base + i);
        }
    }
}

/// Extra bytes escaping one 16-byte block adds. Each matching byte lane is
/// set to its replacement's extra length and `psadbw` sums all 16 lanes.
#[cfg(target_arch = "x86_64")]
#[inline(always)]
fn block_extra(block: &[u8; BLOCK]) -> usize {
    use std::arch::x86_64::*;
    unsafe {
        let v = _mm_loadu_si128(block.as_ptr() as *const __m128i);
        let lane = |byte: u8, extra: i8| {
            _mm_and_si128(_mm_cmpeq_epi8(v, _mm_set1_epi8(byte as i8)), _mm_set1_epi8(extra))
        };
        let extras = _mm_or_si128(
            _mm_or_si128(lane(b'&', 4), lane(b'<', 3)),
            _mm_or_si128(_mm_or_si128(lane(b'>', 3), lane(b'"', 5)), lane(b'\'', 4)),
        );
        let sums = _mm_sad_epu8(extras, _mm_setzero_si128());
        (_mm_cvtsi128_si32(sums) + _mm_extract_epi16(sums, 4)) as usize
    }
}

#[cfg(not(target_arch = "x86_64"))]
#[inline(always)]
fn block_extra(block: &[u8; BLOCK]) -> usize {
    block.iter().map(|&b| ESCAPE_EXTRA[b as usize] as usize).sum()
}

/// Number of extra bytes escaping `bytes` would add (0 = nothing to escape).
#[inline]
fn escaped_extra(bytes: &[u8]) -> usize {
    let mut chunks = bytes.chunks_exact(BLOCK);
    let mut extra = 0usize;
    for chunk in &mut chunks {
        extra += block_extra(chunk.try_into().unwrap());
    }
    extra
        + chunks
            .remainder()
            .iter()
            .map(|&b| ESCAPE_EXTRA[b as usize] as usize)
            .sum::<usize>()
}

/// Writes the escaped form of `src` to `out`.
///
/// Short verbatim runs and replacements are stored with fixed-width
/// unaligned writes instead of variable-length `memcpy` calls, which dominate
/// on markup-dense input. Those writes may scribble up to `ESCAPE_SLACK` bytes
/// past the escaped length; later writes overwrite the excess.
///
/// # Safety
/// `out` must be valid for `src.len() + escaped_extra(src) + ESCAPE_SLACK`
/// bytes and must not overlap `src`.
unsafe fn escape_into(src: &[u8], out: *mut u8) {
    let mut written = 0usize;
    let mut last = 0usize;
    for_each_special(src, |i| {
        let run = i - last;
        if run <= 16 && last + 16 <= src.len() {
            let chunk = std::ptr::read_unaligned(src.as_ptr().add(last) as *const [u8; 16]);
            std::ptr::write_unaligned(out.add(written) as *mut [u8; 16], chunk);
        } else {
            std::ptr::copy_nonoverlapping(src.as_ptr().add(last), out.add(written), run);
        }
        written += run;
        let (bytes, len) = replacement(*src.get_unchecked(i));
        std::ptr::write_unaligned(out.add(written) as *mut [u8; 8], bytes);
        written += len;
        last = i + 1;
    });
    let run = src.len() - last;
    std::ptr::copy_nonoverlapping(src.as_ptr().add(last), out.add(written), run);
}

/// HTML-escapes a string using the exact replacement set Rails relies on
/// (`&`, `<`, `>`, `"`, `'`), matching `ERB::Util.html_escape` /
/// `CGI.escapeHTML`.
///
/// * No escapable byte: the original `RString` is returned untouched (zero
///   allocation, encoding preserved).
/// * Otherwise the exact output size is computed first and the result is
///   written straight into a single Ruby allocation, tagged with the input's
///   encoding.
///
/// The five escapable characters are all ASCII (< 0x80), so scanning raw
/// bytes is safe for UTF-8 input: multibyte continuation bytes are always
/// >= 0x80 and can never be mistaken for a delimiter.
fn escape_html(ruby: &Ruby, input: RString) -> Result<RString, Error> {
    let extra = escaped_extra(unsafe { input.as_slice() });
    if extra == 0 {
        return Ok(input);
    }

    let len = input.len() + extra;
    let out = ruby.str_buf_new(len + ESCAPE_SLACK);
    out.enc_associate(input.enc_get())?;
    unsafe {
        // Re-borrow the source after the allocation above (GC compaction).
        // `out` has capacity for `len + ESCAPE_SLACK` bytes, with `len`
        // computed from the same (unchanged) source bytes.
        escape_into(input.as_slice(), rb_sys::RSTRING_PTR(out.as_raw()) as *mut u8);
        rb_sys::rb_str_set_len(out.as_raw(), len as c_long);
    }
    Ok(out)
}

#[cfg(not(all(ruby_gte_3_3, unix)))]
fn gvl_stats() -> Option<(u64, u64, u64)> {
    None
}

#[cfg(all(ruby_gte_3_3, unix))]
fn gvl_stats(ruby: &Ruby) -> Result<Option<(u64, u64, u64)>, Error> {
    gvl::current_thread_stats(ruby)
}

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let module = ruby.define_module("Renderhive")?;
    let native = module.define_module("Native")?;
    native.define_singleton_method("join_buffers", function!(join_buffers, 1))?;
    native.define_singleton_method("escape_html", function!(escape_html, 1))?;
    native.define_singleton_method("gvl_stats", function!(gvl_stats, 0))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn escape(s: &str) -> String {
        let src = s.as_bytes();
        let len = src.len() + escaped_extra(src);
        let mut dst = vec![0u8; len + ESCAPE_SLACK];
        unsafe { escape_into(src, dst.as_mut_ptr()) };
        dst.truncate(len);
        String::from_utf8(dst).unwrap()
    }

    #[test]
    fn escapes_every_special_byte() {
        assert_eq!(escape(r#"<a href="x">&'</a>"#), "&lt;a href=&quot;x&quot;&gt;&amp;&#39;&lt;/a&gt;");
        assert_eq!(escape("plain"), "plain");
        assert_eq!(escape("日本<語>"), "日本&lt;語&gt;");
        assert_eq!(escaped_extra(b"no specials"), 0);
        // Exercise block boundaries: specials at every offset of 16-byte blocks.
        for len in 0..70 {
            for pos in 0..len {
                let mut s = "x".repeat(len);
                s.replace_range(pos..pos + 1, "&");
                let expected = s.replace('&', "&amp;");
                assert_eq!(escape(&s), expected, "len={len} pos={pos}");
            }
        }
    }
}
