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
