use super::super::{Callbacks, Terminal};

/// Pieces every pre-parse step reacts to, plus the neutral bytes the
/// fused scan skips: SGR and other inert CSIs, modes, OSC 133 marks,
/// color and palette OSCs, empty and real Kitty APCs, 8-bit C1 forms,
/// complete, split and invalid UTF-8, line ends and lone controls.
const PIECES: &[&[u8]] = &[
    b"cargo build",
    b" ",
    b"ok",
    b"\r\n",
    b"\n",
    b"\x0b",
    b"\x0c",
    b"\t",
    b"\x07",
    b"\x1b[31m",
    b"\x1b[38;5;200m",
    b"\x1b[0m",
    b"\x1b[2J",
    b"\x1b[H",
    b"\x1b[3;4H",
    b"\x1b[?1000h",
    b"\x1b[?1000l",
    b"\x1b[?1006h",
    b"\x1b[?1006l",
    b"\x1b[?2004h",
    b"\x1b[s",
    b"\x1b[u",
    b"\x1b[2 q",
    b"\x1b[c",
    b"\x1b[>4;1m",
    b"\x1b[?1049h",
    b"\x1b[?1049l",
    b"\x1b]133;A\x07",
    b"\x1b]133;B\x1b\\",
    b"\x1b]133;C\x07",
    b"\x1b]133;D;0\x07",
    b"\x1b]133;P;k=i\x07",
    b"\x1b]0;title\x07",
    b"\x1b]10;#ff0000\x07",
    b"\x1b]11;rgb:00/00/ff\x1b\\",
    b"\x1b]4;1;rgb:00/ff/00\x1b\\",
    b"\x1b]104\x07",
    b"\x1b]110\x07",
    b"\x1b]112\x07",
    b"\x1b]12;#00ff00\x07",
    b"\x1b]7;file://h/tmp\x07",
    b"\x1b_G\x1b\\",
    b"\x1b_Ga=q,i=1;AAAA\x1b\\",
    b"\x9fG\x9c",
    b"\x9d0;x\x9c",
    b"\x90q\x9c",
    b"\x9b",
    b"\x1bP+q544e\x1b\\",
    "é".as_bytes(),
    "日本語".as_bytes(),
    "🙂".as_bytes(),
    b"\xe6",
    b"\x80",
    b"\xed\xa0\x80",
    b"\xc0\xaf",
    b"\xf4\x90\x80\x80",
    b"\x1b",
    b"\x18",
    b"\x1a",
    b"\x1b[",
    b"\x1b]",
];

fn stream(seed: u64, pieces: usize) -> Vec<u8> {
    let mut state = seed;
    let mut out = Vec::new();
    for _ in 0..pieces {
        state = state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        let index = usize::try_from(state >> 33).unwrap_or(0) % PIECES.len();
        out.extend_from_slice(PIECES[index]);
    }
    out
}

fn state(term: &Terminal) -> impl PartialEq + std::fmt::Debug {
    (
        term.vt_stream_is_ground(),
        term.vt_replay_resumes_stream(),
        term.mouse_mode_bits,
        term.color_overrides(),
        term.c1_normalizer.utf8_remaining,
    )
}

/// The fused pre-parse scan accepts the same bytes, leaves the same
/// tracker state and builds the same replay as the byte-at-a-time
/// reference, for streams cut into frames at every kind of boundary.
#[test]
fn the_fused_pre_parse_scan_matches_the_byte_at_a_time_reference() {
    for seed in 0..300u64 {
        let bytes = stream(seed, 400);
        let mut fast = Terminal::new(30, 6, 4096, Callbacks::default()).unwrap();
        let mut reference = Terminal::new(30, 6, 4096, Callbacks::default()).unwrap();
        let mut cut_state = seed ^ 0x9e37_79b9;
        let mut at = 0;
        while at < bytes.len() {
            cut_state =
                cut_state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            let len = 1 + usize::try_from(cut_state >> 33).unwrap_or(0) % 97;
            let frame = &bytes[at..(at + len).min(bytes.len())];
            let accepted = fast.vt_write_with_normalized(frame).into_owned();
            let expected = reference.vt_write_with_normalized_reference(frame).into_owned();
            assert_eq!(accepted, expected, "seed {seed} at {at}");
            assert_eq!(state(&fast), state(&reference), "seed {seed} at {at}");
            at += frame.len();
        }
        assert_eq!(fast.vt_replay_bytes().ok(), reference.vt_replay_bytes().ok(), "seed {seed}");
    }
}

/// `cat` output: long plain lines, SGR-colored words and runs of non-ASCII
/// text, with now and then a sequence the trackers act on. Cut into frames
/// from 1 byte to 4 KiB, a cut lands inside a code point, a CSI and an OSC,
/// and between two 16-byte scan blocks; every frame must give the same
/// bytes and state as the byte-at-a-time reference.
#[test]
fn plain_and_colored_frames_match_the_reference_at_every_cut() {
    const WORDS: &[&[u8]] = &[
        b"cargo",
        b"warning:",
        b"src/main.rs:42:7",
        "日本語".as_bytes(),
        "│─┼".as_bytes(),
        "é→✓".as_bytes(),
        "🙂".as_bytes(),
        b"0123456789abcdef0123456789abcdef",
    ];
    const RARE: &[&[u8]] =
        &[b"\x1b]133;A\x07", b"\x1b[?25l", b"\x1b[?25h", b"\x1b]0;t\x07", b"\x1b_G\x1b\\", b"\x9c"];
    let mut seed: u64 = 3;
    let mut next = move |n: usize| {
        seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        usize::try_from(seed >> 33).unwrap_or(0) % n
    };
    let mut bytes = Vec::new();
    for line in 0..300 {
        for word in 0..1 + next(30) {
            if word > 0 {
                bytes.push(b' ');
            }
            let text = WORDS[next(WORDS.len())];
            if line % 4 == 0 {
                bytes.extend_from_slice(format!("\x1b[38;5;{}m", next(256)).as_bytes());
                bytes.extend_from_slice(text);
                bytes.extend_from_slice(b"\x1b[0m");
            } else {
                bytes.extend_from_slice(text);
            }
        }
        if line % 97 == 13 {
            bytes.extend_from_slice(RARE[next(RARE.len())]);
        }
        bytes.extend_from_slice(b"\r\n");
    }
    for frame_len in [1, 2, 3, 7, 15, 16, 17, 31, 33, 64, 255, 1024, 4096] {
        let mut fast = Terminal::new(80, 24, 1 << 20, Callbacks::default()).unwrap();
        let mut reference = Terminal::new(80, 24, 1 << 20, Callbacks::default()).unwrap();
        for (index, frame) in bytes.chunks(frame_len).enumerate() {
            let accepted = fast.vt_write_with_normalized(frame).into_owned();
            let expected = reference.vt_write_with_normalized_reference(frame).into_owned();
            assert_eq!(accepted, expected, "frames of {frame_len}, frame {index}");
            assert_eq!(state(&fast), state(&reference), "frames of {frame_len}, frame {index}");
        }
        assert_eq!(fast.vt_replay_bytes().ok(), reference.vt_replay_bytes().ok(), "{frame_len}");
    }
}

/// `step_if_unchanged` agrees with the normalizer on every byte from every
/// code point state: it steps exactly the bytes the normalizer copies, to
/// the same state, and refuses the ones it replaces.
#[test]
fn the_unchanged_step_matches_the_normalizer_on_every_byte() {
    use super::super::vt_boundary::C1Normalizer;
    for remaining in 0..=3u8 {
        for byte in 0..=u8::MAX {
            let mut stepped = C1Normalizer { utf8_remaining: remaining };
            let mut normalized = C1Normalizer { utf8_remaining: remaining };
            let unchanged = normalized.normalize_reference(&[byte]).as_ref() == [byte];
            assert_eq!(stepped.step_if_unchanged(byte), unchanged, "{remaining} {byte:#04x}");
            if unchanged {
                assert_eq!(
                    stepped.utf8_remaining, normalized.utf8_remaining,
                    "{remaining} {byte:#04x}"
                );
            } else {
                assert_eq!(stepped.utf8_remaining, remaining, "{remaining} {byte:#04x}");
            }
        }
    }
}

/// Frames cut inside an SGR's parameters or a code point resume the
/// neutral scan after finishing the cut sequence, and still match the
/// reference byte for byte.
#[test]
fn frames_that_start_inside_a_cut_sequence_match_the_reference() {
    let mut bytes = Vec::new();
    for line in 0..200 {
        bytes.extend_from_slice(format!("\x1b[38;5;{}mword{line} ", line % 256).as_bytes());
        bytes.extend_from_slice("日本→🙂".as_bytes());
        bytes.extend_from_slice(b"\x1b[0m\r\n");
    }
    for frame_len in [3, 5, 7, 11, 13, 64, 65, 127] {
        let mut fast = Terminal::new(30, 6, 4096, Callbacks::default()).unwrap();
        let mut reference = Terminal::new(30, 6, 4096, Callbacks::default()).unwrap();
        for (index, frame) in bytes.chunks(frame_len).enumerate() {
            let accepted = fast.vt_write_with_normalized(frame).into_owned();
            let expected = reference.vt_write_with_normalized_reference(frame).into_owned();
            assert_eq!(accepted, expected, "len {frame_len} frame {index}");
            assert_eq!(state(&fast), state(&reference), "len {frame_len} frame {index}");
        }
        assert_eq!(
            fast.vt_replay_bytes().ok(),
            reference.vt_replay_bytes().ok(),
            "len {frame_len}"
        );
    }
}
