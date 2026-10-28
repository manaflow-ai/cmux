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
    while let Some(word) = data.get(index..).and_then(<[u8]>::first_chunk::<8>) {
        if word_may_match(u64::from_le_bytes(*word)) {
            break;
        }
        index += 8;
    }
    while data.get(index).is_some_and(|byte| !matches(*byte)) {
        index += 1;
    }
    index
}

/// Index of the first ESC at or after `from`, or `data.len()`.
#[inline]
pub(crate) fn find_esc(data: &[u8], from: usize) -> usize {
    find(data, from, |word| has_byte(word, 0x1b), |byte| byte == 0x1b)
}

/// Index of the first ESC or byte >= 0x80 at or after `from`, or `data.len()`.
#[inline]
pub(crate) fn find_esc_or_high(data: &[u8], from: usize) -> usize {
    find(
        data,
        from,
        |word| word & HIGH != 0 || has_byte(word, 0x1b),
        |byte| byte == 0x1b || byte >= 0x80,
    )
}

/// Index of the first byte >= 0x80 at or after `from`, or `data.len()`.
#[inline]
pub(crate) fn find_high(data: &[u8], from: usize) -> usize {
    find(data, from, |word| word & HIGH != 0, |byte| byte >= 0x80)
}

/// CSI finals no tracker acts on (cursor motion, erase, insert/delete,
/// scroll, SGR, ...). Excluded on purpose: modes (h l), save/restore (s r),
/// soft reset and DECRQM (p), DECSCUSR (q), reports and queries (c n t u x).
const INERT_CSI_FINALS: &[u8] = b"@ABCDEFGHIJKLMPSTXZ`abdefgm";

/// Length of the complete inert CSI sequence at `data[at..]` (`ESC [`,
/// parameters from `0-9 ; :` only, then a final in [`INERT_CSI_FINALS`]),
/// or 0 when the bytes there are not one.
#[inline]
fn inert_csi_len(data: &[u8], at: usize) -> usize {
    let Some([_, b'[', after_introducer @ ..]) = data.get(at..) else {
        return 0;
    };
    let parameters = after_introducer
        .iter()
        .position(|byte| !matches!(byte, b'0'..=b'9' | b';' | b':'))
        .unwrap_or(after_introducer.len());
    match after_introducer.get(parameters) {
        // ESC, `[`, the parameters and the final.
        Some(fin) if INERT_CSI_FINALS.contains(fin) => parameters + 3,
        _ => 0,
    }
}

/// Length of the complete, strictly valid UTF-8 multibyte code point at
/// `data[at..]`, or 0. Strict means the same DFA libghostty decodes with:
/// the second byte after E0, ED, F0 and F4 has the narrower ranges.
#[inline]
fn utf8_len(data: &[u8], at: usize) -> usize {
    let Some((lead, after_lead)) = data.get(at..).and_then(<[u8]>::split_first) else {
        return 0;
    };
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
    let Some((second_byte, rest)) = after_lead.get(..len - 1).and_then(<[u8]>::split_first) else {
        return 0;
    };
    if second.contains(second_byte) && rest.iter().all(|b| matches!(b, 0x80..=0xbf)) {
        len
    } else {
        0
    }
}

/// End of the longest run starting at `from` that leaves every VT tracker
/// idle when all of them start idle, with no other effect than the boundary
/// tracker's idempotent `clear_pending`: ASCII other than ESC (and other
/// than LF, VT, FF unless `line_ends_neutral`), complete valid UTF-8 code
/// points, and complete inert CSI sequences.
pub(crate) fn neutral_run_end(data: &[u8], from: usize, line_ends_neutral: bool) -> usize {
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
        let step = match data.get(at) {
            None => return at,
            Some(0x1b) => inert_csi_len(data, at),
            Some(byte) if *byte >= 0x80 => utf8_len(data, at),
            Some(_) => 0,
        };
        if step == 0 {
            return at;
        }
        at += step;
    }
}
