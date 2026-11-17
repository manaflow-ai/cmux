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

/// [`neutral_run_end`] with line ends neutral, from ESC to ESC: the bytes
/// between two ESCs are neutral exactly when they are valid UTF-8 (ASCII
/// other than ESC is neutral, and `str::from_utf8` accepts the same code
/// points as [`utf8_len`]: no overlong forms, surrogates or values past
/// U+10FFFF), and its `valid_up_to` stops before an invalid or incomplete
/// code point, where the byte walk stops too. Each byte is validated once.
fn neutral_run_end_by_escape(data: &[u8], from: usize) -> usize {
    let mut at = from;
    loop {
        let rest = data.get(at..).unwrap_or_default();
        let esc = memchr::memchr(0x1b, rest).map_or(data.len(), |offset| at + offset);
        if let Err(error) = std::str::from_utf8(data.get(at..esc).unwrap_or_default()) {
            return at + error.valid_up_to();
        }
        if esc == data.len() {
            return esc;
        }
        let csi = inert_csi_len(data, esc);
        if csi == 0 {
            return esc;
        }
        at = esc + csi;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const INERT_CSI_FINALS: &[u8] = b"@ABCDEFGHIJKLMPSTXZ`abdefgm";

    #[test]
    fn the_inert_final_test_is_the_list() {
        for byte in 0..=u8::MAX {
            assert_eq!(is_inert_csi_final(byte), INERT_CSI_FINALS.contains(&byte), "{byte:#04x}");
        }
    }

    /// The byte walk the ESC-to-ESC form replaces.
    fn walk(data: &[u8], from: usize) -> usize {
        let mut at = from;
        loop {
            at = find_esc_or_high(data, at);
            if at == data.len() {
                return at;
            }
            let step = match data[at] {
                0x1b => inert_csi_len(data, at),
                _ => utf8_len(data, at),
            };
            if step == 0 {
                return at;
            }
            at += step;
        }
    }

    /// Every UTF-8 edge (each strict second-byte range, overlongs,
    /// surrogates, past U+10FFFF, cut code points) and every ESC form,
    /// in random orders, from every start.
    #[test]
    fn the_escape_to_escape_scan_ends_where_the_byte_walk_ends() {
        const PIECES: &[&[u8]] = &[
            b"ab",
            b" ",
            b"\r\n",
            b"\x00",
            b"\x7f",
            b"\x1b",
            b"\x1b[",
            b"\x1b[0m",
            b"\x1b[38;5;9m",
            b"\x1b[1;2H",
            b"\x1b[?25h",
            b"\x1b[2 q",
            b"\x1b]0;t\x07",
            b"\x1b_G\x1b\\",
            b"\xc2\x80",
            b"\xdf\xbf",
            b"\xc0\xaf",
            b"\xc1\xbf",
            b"\xe0\xa0\x80",
            b"\xe0\x9f\xbf",
            b"\xed\x9f\xbf",
            b"\xed\xa0\x80",
            b"\xef\xbf\xbf",
            b"\xf0\x90\x80\x80",
            b"\xf0\x8f\xbf\xbf",
            b"\xf4\x8f\xbf\xbf",
            b"\xf4\x90\x80\x80",
            b"\xf5\x80\x80\x80",
            b"\x80",
            b"\xbf",
            b"\xe6",
            b"\xe6\x97",
            b"\xf0\x9f",
            b"\xff",
            b"\x9c",
            b"\x90",
        ];
        let mut state: u64 = 571;
        for _ in 0..4000 {
            let mut data = Vec::new();
            state = state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            let count = 1 + usize::try_from(state >> 60).unwrap_or(0);
            for _ in 0..count {
                state = state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                data.extend_from_slice(
                    PIECES[usize::try_from(state >> 33).unwrap_or(0) % PIECES.len()],
                );
            }
            for from in 0..=data.len() {
                assert_eq!(
                    neutral_run_end(&data, from, true),
                    walk(&data, from),
                    "{data:?} from {from}"
                );
            }
        }
    }
}
