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
/// a complete inert CSI there, and ends at the first ESC that is not one. A
/// frame of SGR-colored text has an ESC every few bytes, so the walk makes no
/// call per ESC-to-ESC segment.
///
/// From a byte >= 0x80 the bytes up to the next ESC are neutral exactly when
/// they are valid UTF-8 (`simdutf8` accepts the same code points as
/// [`utf8_len`]: no overlong forms, surrogates or values past U+10FFFF), and
/// its `valid_up_to` stops before an invalid or incomplete code point, where
/// the byte walk stops too. Non-ASCII text (CJK, box drawing, emoji) is then
/// validated 16-64 bytes a step instead of one code point at a time.
fn neutral_run_end_by_escape(data: &[u8], from: usize) -> usize {
    let mut at = from;
    loop {
        at = block::skip(data, at);
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
        let rest = data.get(at..).unwrap_or_default();
        let esc = memchr::memchr(0x1b, rest).map_or(data.len(), |offset| at + offset);
        if let Err(error) = simdutf8::compat::from_utf8(data.get(at..esc).unwrap_or_default()) {
            return at + error.valid_up_to();
        }
        at = esc;
    }
}

/// 64 bytes a step for the ESC-dense case: a frame of SGR-colored text has an
/// ESC every ~10 bytes, so a walk that stops at each one pays a branchy
/// CSI walk per ESC. Here one block's ESC, `[`, parameter (`0-9 ; :`), `m` and
/// high-bit bytes become five 64-bit masks, and every CSI in the block is
/// checked at once:
///
/// - each ESC must start `ESC [` (`starts`);
/// - adding each start's first parameter position (`starts << 2`) to the
///   parameter mask carries through that CSI's parameter run and lands on the
///   first byte after it, its final (`(S + P) & !P`, one bit a start);
/// - every final must be inert ([`is_inert_csi_final`]): `m` from its mask,
///   any other from the byte.
///
/// A block passes up to `limit`, its first byte >= 0x80 (or its end). When a
/// CSI runs past the block's end, the block passes up to that CSI's ESC and
/// the next block starts there. Anything else (a byte >= 0x80, a CSI that is
/// not inert) leaves the bytes from there to the byte walk, so the result is
/// exactly the byte walk's.
pub(super) mod block {
    use super::is_inert_csi_final;

    pub(super) struct Masks {
        pub(super) esc: u64,
        pub(super) bracket: u64,
        pub(super) param: u64,
        pub(super) final_m: u64,
        pub(super) high: u64,
    }

    /// Index after the 64-byte blocks from `from` that hold only neutral
    /// bytes and complete inert CSIs, and no byte >= 0x80; `from` if the
    /// first block does not start that way.
    #[inline]
    pub(in crate::terminal) fn skip(data: &[u8], from: usize) -> usize {
        let mut at = from;
        while at + 64 <= data.len() {
            let block: &[u8; 64] = data[at..at + 64].try_into().unwrap_or(&[0; 64]);
            let step = passes(block, &masks(block));
            if step == 0 {
                break;
            }
            at += step;
        }
        at
    }

    /// How many leading bytes of `block` are neutral (see the module doc).
    #[inline(always)]
    pub(super) fn passes(block: &[u8; 64], m: &Masks) -> usize {
        let limit = if m.high == 0 { 64 } else { m.high.trailing_zeros() };
        let below = if limit == 64 { u64::MAX } else { (1u64 << limit) - 1 };
        let starts = m.esc & (m.bracket >> 1);
        if all_inert(block, m, starts, below) {
            return limit as usize;
        }
        let escs = m.esc & below;
        if escs == 0 {
            return 0;
        }
        let last = 63 - escs.leading_zeros();
        if last != 0 && all_inert(block, m, starts, (1u64 << last) - 1) { last as usize } else { 0 }
    }

    /// True when every ESC under `mask` starts a complete inert CSI whose
    /// final is in the block.
    #[inline(always)]
    fn all_inert(block: &[u8; 64], m: &Masks, starts: u64, mask: u64) -> bool {
        let starts = starts & mask;
        if m.esc & mask != starts || starts >> 62 != 0 {
            return false;
        }
        let (sum, carried) = (starts << 2).overflowing_add(m.param);
        if carried {
            return false;
        }
        let mut others = sum & !m.param & !m.final_m;
        while others != 0 {
            if !is_inert_csi_final(block[others.trailing_zeros() as usize]) {
                return false;
            }
            others &= others - 1;
        }
        true
    }

    #[cfg(target_arch = "x86_64")]
    #[inline(always)]
    pub(super) fn masks(block: &[u8; 64]) -> Masks {
        use std::arch::x86_64::{
            __m128i, _mm_cmpeq_epi8, _mm_loadu_si128, _mm_min_epu8, _mm_movemask_epi8,
            _mm_set1_epi8, _mm_sub_epi8,
        };
        // SAFETY: SSE2 is in the x86_64 baseline, and the four loads read the
        // 64 bytes of `block`.
        unsafe {
            let esc = _mm_set1_epi8(0x1b);
            let bracket = _mm_set1_epi8(b'[' as i8);
            let final_m = _mm_set1_epi8(b'm' as i8);
            let zero = _mm_set1_epi8(b'0' as i8);
            let eleven = _mm_set1_epi8(11);
            let bits = |f: &dyn Fn(__m128i) -> __m128i| -> u64 {
                let mut out = 0u64;
                for lane in 0..4 {
                    let v = _mm_loadu_si128(block.as_ptr().add(lane * 16).cast());
                    out |= u64::from(_mm_movemask_epi8(f(v)) as u16) << (lane * 16);
                }
                out
            };
            Masks {
                esc: bits(&|v| _mm_cmpeq_epi8(v, esc)),
                bracket: bits(&|v| _mm_cmpeq_epi8(v, bracket)),
                // 0x30..=0x3b is `byte - '0' <= 11`, unsigned.
                param: bits(&|v| {
                    let d = _mm_sub_epi8(v, zero);
                    _mm_cmpeq_epi8(_mm_min_epu8(d, eleven), d)
                }),
                final_m: bits(&|v| _mm_cmpeq_epi8(v, final_m)),
                high: bits(&|v| v),
            }
        }
    }

    #[cfg(target_arch = "aarch64")]
    #[inline(always)]
    pub(super) fn masks(block: &[u8; 64]) -> Masks {
        use std::arch::aarch64::{
            uint8x16_t, vandq_u8, vceqq_u8, vcgeq_u8, vcleq_u8, vdupq_n_u8, vgetq_lane_u64,
            vld1q_u8, vpaddq_u8, vreinterpretq_u64_u8, vsubq_u8,
        };
        // SAFETY: NEON is in the aarch64 baseline, and the four loads read the
        // 64 bytes of `block`.
        unsafe {
            const WEIGHTS: [u8; 16] = [1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16, 32, 64, 128];
            let weights = vld1q_u8(WEIGHTS.as_ptr());
            let v = [
                vld1q_u8(block.as_ptr()),
                vld1q_u8(block.as_ptr().add(16)),
                vld1q_u8(block.as_ptr().add(32)),
                vld1q_u8(block.as_ptr().add(48)),
            ];
            // One bit a byte from four all-ones/all-zeros comparisons: weight
            // each byte by its bit, then three pairwise adds fold 64 bytes to 8.
            let bits = |f: &dyn Fn(uint8x16_t) -> uint8x16_t| -> u64 {
                let t = [
                    vandq_u8(f(v[0]), weights),
                    vandq_u8(f(v[1]), weights),
                    vandq_u8(f(v[2]), weights),
                    vandq_u8(f(v[3]), weights),
                ];
                let s = vpaddq_u8(vpaddq_u8(t[0], t[1]), vpaddq_u8(t[2], t[3]));
                vgetq_lane_u64(vreinterpretq_u64_u8(vpaddq_u8(s, s)), 0)
            };
            let esc = vdupq_n_u8(0x1b);
            let bracket = vdupq_n_u8(b'[');
            let final_m = vdupq_n_u8(b'm');
            let zero = vdupq_n_u8(b'0');
            let eleven = vdupq_n_u8(11);
            let high = vdupq_n_u8(0x80);
            Masks {
                esc: bits(&|x| vceqq_u8(x, esc)),
                bracket: bits(&|x| vceqq_u8(x, bracket)),
                param: bits(&|x| vcleq_u8(vsubq_u8(x, zero), eleven)),
                final_m: bits(&|x| vceqq_u8(x, final_m)),
                high: bits(&|x| vcgeq_u8(x, high)),
            }
        }
    }

    #[cfg(not(any(target_arch = "x86_64", target_arch = "aarch64")))]
    #[inline(always)]
    pub(super) fn masks(block: &[u8; 64]) -> Masks {
        scalar_masks(block)
    }

    /// The masks one byte at a time: the reference the SIMD versions match.
    #[cfg_attr(any(target_arch = "x86_64", target_arch = "aarch64"), allow(dead_code))]
    pub(super) fn scalar_masks(block: &[u8; 64]) -> Masks {
        let mut m = Masks { esc: 0, bracket: 0, param: 0, final_m: 0, high: 0 };
        for (index, &byte) in block.iter().enumerate() {
            let bit = 1u64 << index;
            if byte == 0x1b {
                m.esc |= bit;
            }
            if byte == b'[' {
                m.bracket |= bit;
            }
            if byte.wrapping_sub(b'0') < 12 {
                m.param |= bit;
            }
            if byte == b'm' {
                m.final_m |= bit;
            }
            if byte >= 0x80 {
                m.high |= bit;
            }
        }
        m
    }
}

#[cfg(test)]
#[path = "byte_scan_tests.rs"]
mod tests;
