//! Word-at-a-time scans the VT trackers use to jump over byte runs that
//! cannot change their idle state.
//!
//! Every scan is exact: a word test may report a candidate that is not a
//! match (it then checks the bytes one by one), but it never misses one.

const ONES: u64 = 0x0101_0101_0101_0101;
const HIGH: u64 = 0x8080_8080_8080_8080;

/// True when some byte of `word` is zero.
#[inline(always)]
fn has_zero(word: u64) -> bool {
    word.wrapping_sub(ONES) & !word & HIGH != 0
}

/// True when some byte of `word` equals `byte`.
#[inline(always)]
fn has_byte(word: u64, byte: u8) -> bool {
    has_zero(word ^ (ONES * u64::from(byte)))
}

/// True when some byte of `word` is below `limit` (`limit <= 0x80`).
#[inline(always)]
fn has_less(word: u64, limit: u8) -> bool {
    word.wrapping_sub(ONES * u64::from(limit)) & !word & HIGH != 0
}

#[inline(always)]
fn find(
    data: &[u8],
    from: usize,
    word_may_match: impl Fn(u64) -> bool,
    matches: impl Fn(u8) -> bool,
) -> usize {
    let mut index = from;
    while index + 8 <= data.len() {
        let mut bytes = [0u8; 8];
        bytes.copy_from_slice(&data[index..index + 8]);
        let word = u64::from_le_bytes(bytes);
        if word_may_match(word) {
            break;
        }
        index += 8;
    }
    while index < data.len() && !matches(data[index]) {
        index += 1;
    }
    index
}

/// Index of the first ESC or byte >= 0x80 at or after `from`, or `data.len()`.
#[inline]
pub(crate) fn find_esc_or_high(data: &[u8], from: usize) -> usize {
    let at = wide::find::<true>(data, from);
    find(
        data,
        at,
        |word| word & HIGH != 0 || has_byte(word, 0x1b),
        |byte| byte == 0x1b || byte >= 0x80,
    )
}

/// Index of the first byte >= 0x80 at or after `from`, or `data.len()`.
#[inline]
pub(crate) fn find_high(data: &[u8], from: usize) -> usize {
    let at = wide::find::<false>(data, from);
    find(data, at, |word| word & HIGH != 0, |byte| byte >= 0x80)
}

/// 16 bytes a step with the target's baseline SIMD (SSE2 on x86_64, NEON on
/// aarch64): the index of the first byte >= 0x80 (or ESC, with `ESC`) at or
/// after `from`, or the start of the last block shorter than 16 bytes, which
/// the word scan above finishes. Every comparison is exact, so the index is
/// the first match itself, with no byte-by-byte search after a hit.
mod wide {
    #[cfg(target_arch = "x86_64")]
    #[inline(always)]
    pub(super) fn find<const ESC: bool>(data: &[u8], from: usize) -> usize {
        use std::arch::x86_64::{
            _mm_cmpeq_epi8, _mm_loadu_si128, _mm_movemask_epi8, _mm_or_si128, _mm_set1_epi8,
        };
        let mut at = from;
        // SAFETY: SSE2 is in the x86_64 baseline, and every load reads the 16
        // bytes at `at`, which the loop condition keeps inside `data`.
        unsafe {
            let esc = _mm_set1_epi8(0x1b);
            while at + 16 <= data.len() {
                let block = _mm_loadu_si128(data.as_ptr().add(at).cast());
                // The movemask takes each byte's top bit: set for >= 0x80, and
                // for every byte of the all-ones ESC comparison.
                let hits =
                    if ESC { _mm_or_si128(block, _mm_cmpeq_epi8(block, esc)) } else { block };
                let mask = _mm_movemask_epi8(hits) as u32;
                if mask != 0 {
                    return at + mask.trailing_zeros() as usize;
                }
                at += 16;
            }
        }
        at
    }

    #[cfg(target_arch = "aarch64")]
    #[inline(always)]
    pub(super) fn find<const ESC: bool>(data: &[u8], from: usize) -> usize {
        use std::arch::aarch64::{
            vceqq_u8, vcgeq_u8, vdupq_n_u8, vget_lane_u64, vld1q_u8, vorrq_u8, vreinterpret_u64_u8,
            vreinterpretq_u16_u8, vshrn_n_u16,
        };
        let mut at = from;
        // SAFETY: NEON is in the aarch64 baseline, and every load reads the 16
        // bytes at `at`, which the loop condition keeps inside `data`.
        unsafe {
            let esc = vdupq_n_u8(0x1b);
            let high = vdupq_n_u8(0x80);
            while at + 16 <= data.len() {
                let block = vld1q_u8(data.as_ptr().add(at));
                let high_bytes = vcgeq_u8(block, high);
                let hits =
                    if ESC { vorrq_u8(high_bytes, vceqq_u8(block, esc)) } else { high_bytes };
                // Narrow each 0x00/0xff byte to a nibble: 4 mask bits a byte,
                // in byte order.
                let mask = vget_lane_u64::<0>(vreinterpret_u64_u8(vshrn_n_u16::<4>(
                    vreinterpretq_u16_u8(hits),
                )));
                if mask != 0 {
                    return at + (mask.trailing_zeros() / 4) as usize;
                }
                at += 16;
            }
        }
        at
    }

    #[cfg(not(any(target_arch = "x86_64", target_arch = "aarch64")))]
    #[inline(always)]
    pub(super) fn find<const ESC: bool>(_data: &[u8], from: usize) -> usize {
        from
    }
}

/// Whether `byte` is a CSI final no tracker acts on (cursor motion, erase,
/// insert/delete, scroll, SGR, ...): `@ABCDEFGHIJKLMPSTXZ` and
/// `` `abdefgm ``. Excluded on purpose: modes (h l), save/restore (s r),
/// soft reset and DECRQM (p), DECSCUSR (q), reports and queries (c n t u x).
/// One range test per CSI; a test holds it equal to that list.
#[inline(always)]
fn is_inert_csi_final(byte: u8) -> bool {
    matches!(
        byte,
        b'@'..=b'M' | b'P' | b'S' | b'T' | b'X' | b'Z' | b'`' | b'a' | b'b' | b'd'..=b'g' | b'm'
    )
}

/// Length of the complete inert CSI sequence at `data[at..]` (`ESC [`,
/// parameters from `0-9 ; :` only, then a final [`is_inert_csi_final`] accepts),
/// or 0 when the bytes there are not one.
#[inline]
fn inert_csi_len(data: &[u8], at: usize) -> usize {
    if data.get(at + 1) != Some(&b'[') {
        return 0;
    }
    let mut end = at + 2;
    while end < data.len() && matches!(data[end], b'0'..=b'9' | b';' | b':') {
        end += 1;
    }
    match data.get(end) {
        Some(&fin) if is_inert_csi_final(fin) => end + 1 - at,
        _ => 0,
    }
}

/// Length of the complete, strictly valid UTF-8 multibyte code point at
/// `data[at..]`, or 0. Strict means the same DFA libghostty decodes with:
/// the second byte after E0, ED, F0 and F4 has the narrower ranges.
#[inline]
fn utf8_len(data: &[u8], at: usize) -> usize {
    let lead = data[at];
    let (len, second) = match lead {
        0xc2..=0xdf => (2, 0x80..=0xbf),
        0xe0 => (3, 0xa0..=0xbf),
        0xe1..=0xec | 0xee..=0xef => (3, 0x80..=0xbf),
        0xed => (3, 0x80..=0x9f),
        0xf0 => (4, 0x90..=0xbf),
        0xf1..=0xf3 => (4, 0x80..=0xbf),
        0xf4 => (4, 0x80..=0x8f),
        _ => return 0,
    };
    if at + len > data.len() || !second.contains(&data[at + 1]) {
        return 0;
    }
    if data[at + 2..at + len].iter().all(|b| matches!(b, 0x80..=0xbf)) { len } else { 0 }
}

/// End of the longest run starting at `from` that leaves every VT tracker
/// idle when all of them start idle, with no other effect than the boundary
/// tracker's idempotent `clear_pending`: ASCII other than ESC (and other
/// than LF, VT, FF unless `line_ends_neutral`), complete valid UTF-8 code
/// points, and complete inert CSI sequences.
pub(crate) fn neutral_run_end(data: &[u8], from: usize, line_ends_neutral: bool) -> usize {
    if line_ends_neutral {
        return neutral_run_end_by_escape(data, from);
    }
    let mut at = from;
    loop {
        at = if line_ends_neutral {
            find_esc_or_high(data, at)
        } else {
            find(
                data,
                at,
                |word| word & HIGH != 0 || has_less(word, 0x20),
                |byte| matches!(byte, 0x1b | b'\n' | 0x0b | 0x0c) || byte >= 0x80,
            )
        };
        if at == data.len() {
            return at;
        }
        let step = match data[at] {
            0x1b => inert_csi_len(data, at),
            byte if byte >= 0x80 => utf8_len(data, at),
            _ => 0,
        };
        if step == 0 {
            return at;
        }
        at += step;
    }
}

/// [`neutral_run_end`] with line ends neutral: one pass that stops only at
/// ESC and bytes >= 0x80 (16 bytes a step, [`find_esc_or_high`]), steps over
/// a complete inert CSI or a run of complete valid code points there, and
/// ends at the first that is neither. A frame of SGR-colored text has an ESC
/// every few bytes, so the walk makes no call per ESC-to-ESC segment.
fn neutral_run_end_by_escape(data: &[u8], from: usize) -> usize {
    let mut at = from;
    loop {
        at = find_esc_or_high(data, at);
        let Some(&byte) = data.get(at) else { return at };
        if byte == 0x1b {
            let csi = inert_csi_len(data, at);
            if csi == 0 {
                return at;
            }
            at += csi;
            continue;
        }
        // Non-ASCII text comes in runs (CJK, box drawing): stay on them.
        loop {
            let len = utf8_len(data, at);
            if len == 0 {
                return at;
            }
            at += len;
            if data.get(at).is_none_or(|next| *next < 0x80) {
                break;
            }
        }
    }
}

#[cfg(test)]
#[path = "byte_scan_tests.rs"]
mod tests;
