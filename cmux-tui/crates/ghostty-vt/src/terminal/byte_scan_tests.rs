use super::*;

const INERT_CSI_FINALS: &[u8] = b"@ABCDEFGHIJKLMPSTXZ`abdefgm";

#[test]
fn the_inert_final_test_is_the_list() {
    for byte in 0..=u8::MAX {
        assert_eq!(is_inert_csi_final(byte), INERT_CSI_FINALS.contains(&byte), "{byte:#04x}");
    }
}

/// The byte walk, one byte at a time: the definition of the neutral run.
fn walk(data: &[u8], from: usize) -> usize {
    let mut at = from;
    loop {
        while at < data.len() && data[at] != 0x1b && data[at] < 0x80 {
            at += 1;
        }
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
            let expected = walk(&data, from);
            assert_eq!(neutral_run_end(&data, from, true), expected, "{data:?} from {from}");
            assert_eq!(escape_to_escape(&data, from), expected, "{data:?} from {from}");
        }
    }
}

/// The form the fused walk replaced (ESC to ESC, `memchr` and
/// `str::from_utf8` a segment), kept to show both end in the same place.
fn escape_to_escape(data: &[u8], from: usize) -> usize {
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

/// The 16-byte scans find the first match at every offset of a block and
/// in the short tail, from every start, against a plain byte search.
#[test]
fn the_wide_scans_find_the_first_match_at_every_position() {
    let mut state: u64 = 52_643;
    for len in 0..48usize {
        for hit in 0..=len {
            for kind in [0x1bu8, 0x80, 0x9c, 0xff, 0xe6] {
                let mut data = vec![0u8; len];
                for byte in &mut data {
                    state =
                        state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                    // ASCII other than ESC: 0x00..=0x7f without 0x1b.
                    let ascii = u8::try_from((state >> 57) & 0x7f).unwrap_or(0);
                    *byte = if ascii == 0x1b { b'a' } else { ascii };
                }
                if hit < len {
                    data[hit] = kind;
                }
                for from in 0..=len {
                    let plain_esc_or_high = data[from..]
                        .iter()
                        .position(|byte| *byte == 0x1b || *byte >= 0x80)
                        .map_or(len, |offset| from + offset);
                    let plain_high = data[from..]
                        .iter()
                        .position(|byte| *byte >= 0x80)
                        .map_or(len, |offset| from + offset);
                    assert_eq!(find_esc_or_high(&data, from), plain_esc_or_high, "{data:?} {from}");
                    assert_eq!(find_high(&data, from), plain_high, "{data:?} {from}");
                }
            }
        }
    }
}

/// Random bytes from ESC, CSI pieces, ASCII and UTF-8 lead, continuation
/// and invalid bytes, from every start: the escape scan ends where the byte
/// walk ends.
#[test]
fn the_escape_scan_matches_the_byte_walk_on_random_bytes() {
    const PICK: &[u8] = &[
        b'a', 0x1b, b'[', b'0', b'm', b';', 0x80, 0xc3, 0xa9, 0xe6, 0xf0, 0x9f, 0xff, 0x9b, b'H',
        b'h',
    ];
    let mut state: u64 = 99;
    for _ in 0..50_000 {
        state = state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        let len = usize::try_from(state >> 57).unwrap_or(0);
        let mut data = Vec::with_capacity(len);
        for _ in 0..len {
            state = state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            data.push(PICK[usize::try_from(state >> 33).unwrap_or(0) % PICK.len()]);
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
