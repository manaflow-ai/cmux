//! A render state's frame rebuilds only its dirty rows and shares the others
//! with the previous frame. These tests hold it to the reference: the frame a
//! fresh render state reads in full from a twin terminal fed the same input.

use std::sync::Arc;

use ghostty_vt::{Callbacks, Dirty, RenderFrame, RenderState, Rgb, Terminal};

const WHITE: Rgb = Rgb { r: 255, g: 255, b: 255 };
const BLACK: Rgb = Rgb { r: 0, g: 0, b: 0 };

/// One change to both terminals.
#[derive(Clone)]
enum Step {
    Bytes(Vec<u8>),
    Resize(u16, u16),
    Scroll(isize),
    Bottom,
    DefaultColors(Option<Rgb>, Option<Rgb>),
}

impl Step {
    fn apply(&self, term: &mut Terminal) {
        match self {
            Step::Bytes(bytes) => term.vt_write(bytes),
            Step::Resize(cols, rows) => term.resize(*cols, *rows, 8, 16).unwrap(),
            Step::Scroll(delta) => term.scroll_delta(*delta),
            Step::Bottom => term.scroll_to_bottom(),
            Step::DefaultColors(fg, bg) => term.set_default_colors(*fg, *bg, None),
        }
    }
}

/// The terminal with a long-lived render state (rows reused) and its twin
/// read in full by a new render state each frame.
struct Pair {
    term: Terminal,
    state: RenderState,
    twin: Terminal,
    previous: Option<RenderFrame>,
}

impl Pair {
    fn new(cols: u16, rows: u16) -> Self {
        let configured = |mut term: Terminal| {
            // Every cmux terminal has configured default colors: with none,
            // a reset (OSC 110/111) leaves any render state's last colors.
            term.set_default_colors(Some(WHITE), Some(BLACK), None);
            term
        };
        Self {
            term: configured(Terminal::new(cols, rows, 200, Callbacks::default()).unwrap()),
            state: RenderState::new().unwrap(),
            twin: configured(Terminal::new(cols, rows, 200, Callbacks::default()).unwrap()),
            previous: None,
        }
    }

    fn step(&mut self, step: &Step, label: &str) -> RenderFrame {
        step.apply(&mut self.term);
        step.apply(&mut self.twin);
        self.frame(label)
    }

    /// Build the reused frame and check it against the reference frame, and
    /// that its damage names every row that differs from the previous frame.
    fn frame(&mut self, label: &str) -> RenderFrame {
        self.state.update(&mut self.term).unwrap();
        let frame = self.state.build_frame().unwrap();
        let mut fresh = RenderState::new().unwrap();
        fresh.update(&mut self.twin).unwrap();
        let reference = fresh.build_frame().unwrap();

        assert_eq!(frame.size, reference.size, "{label}: size");
        assert_eq!(frame.default_colors, reference.default_colors, "{label}: default colors");
        assert_eq!(frame.styled_rows().len(), reference.styled_rows().len(), "{label}: rows");
        for (row, (cells, expected)) in
            frame.styled_rows().iter().zip(reference.styled_rows()).enumerate()
        {
            assert_eq!(&**cells, &**expected, "{label}: row {row} differs from a full read");
        }
        if let Some(previous) = &self.previous
            && previous.size == frame.size
            && frame.dirty != Dirty::Full
        {
            for (row, (cells, before)) in
                frame.styled_rows().iter().zip(previous.styled_rows()).enumerate()
            {
                if cells != before {
                    assert!(
                        frame.dirty_rows.contains(&(row as u16)),
                        "{label}: row {row} changed but is not in dirty_rows {:?}",
                        frame.dirty_rows
                    );
                }
            }
        }
        self.previous = Some(frame.clone());
        frame
    }
}

fn bytes(text: &str) -> Step {
    Step::Bytes(text.as_bytes().to_vec())
}

#[test]
fn a_frame_shares_its_clean_rows_with_the_previous_frame() {
    let mut pair = Pair::new(20, 6);
    pair.step(&bytes("top\r\nmiddle\r\nbottom"), "fill");
    let before = pair.frame("settled");
    let after = pair.step(&bytes("\x1b[2;1Hchanged"), "one row");

    assert_eq!(after.dirty, Dirty::Partial);
    assert!(after.dirty_rows.contains(&1), "{:?}", after.dirty_rows);
    // The cursor left row 2, which may be damaged too; rows 0, 4 and 5 are not.
    for row in [0u16, 4, 5] {
        assert!(!after.dirty_rows.contains(&row), "{:?}", after.dirty_rows);
    }
    for row in 0..6u16 {
        let shared = Arc::ptr_eq(
            &after.styled_rows()[usize::from(row)],
            &before.styled_rows()[usize::from(row)],
        );
        assert_eq!(
            shared,
            !after.dirty_rows.contains(&row),
            "row {row}: a clean row must be the previous frame's row, a dirty row a new one"
        );
    }

    let idle = pair.frame("no change");
    assert!(idle.dirty_rows.is_empty());
    for row in 0..6 {
        assert!(Arc::ptr_eq(&idle.styled_rows()[row], &after.styled_rows()[row]));
    }
}

#[test]
fn walk_rows_and_set_clean_between_frames_force_a_full_read() {
    let mut pair = Pair::new(12, 4);
    pair.step(&bytes("one\r\ntwo"), "fill");
    // A walk consumes the row damage of this change; the next frame must not
    // keep the old row it no longer sees as dirty.
    bytes("\x1b[1;1HXX").apply(&mut pair.term);
    bytes("\x1b[1;1HXX").apply(&mut pair.twin);
    pair.state.update(&mut pair.term).unwrap();
    pair.state.walk_rows(|_, _, _| {}).unwrap();
    // The walk consumed the damage, so the frame names none: only its rows
    // are checked against the full read.
    pair.previous = None;
    pair.frame("after walk_rows");

    bytes("\x1b[2;1HYY").apply(&mut pair.term);
    bytes("\x1b[2;1HYY").apply(&mut pair.twin);
    pair.state.update(&mut pair.term).unwrap();
    pair.state.set_clean();
    pair.state.walk_rows(|_, _, _| {}).unwrap();
    pair.previous = None;
    pair.frame("after set_clean");
}

/// Sequences that move, erase, recolor or replace rows in every way the
/// terminal knows, each applied alone and then in a seeded random mix with
/// resizes, viewport scrolls and default-color changes.
fn vocabulary() -> Vec<Step> {
    [
        "plain text",
        "\r\n",
        "\r\nline that is long enough to wrap around the right edge of the grid",
        "\x1b[31mred\x1b[42mgreen-bg\x1b[1;3;4;9mstyled\x1b[0m",
        "\x1b[38;5;196mpal\x1b[48;2;1;2;3mrgb\x1b[0m",
        "\x1b]4;1;rgb:12/34/56\x1b\\",
        "\x1b]4;196;rgb:ff/00/ff\x07",
        "\x1b]104\x07",
        "\x1b]10;rgb:aa/bb/cc\x07",
        "\x1b]11;rgb:01/02/03\x07",
        "\x1b]110\x07\x1b]111\x07",
        "\x1b[?5h",
        "\x1b[?5l",
        "\x1b[2;5r\x1b[3;1H\x1b[2S",
        "\x1b[2;5r\x1b[3;1H\x1b[1T",
        "\x1b[r",
        "\x1b[3;1H\x1b[2L",
        "\x1b[2;1H\x1b[1M",
        "\x1b[1;3H\x1b[2@",
        "\x1b[1;2H\x1b[3P",
        "\x1b[1;4H\x1b[2X",
        "\x1b[K",
        "\x1b[1K",
        "\x1b[2K",
        "\x1b[J",
        "\x1b[1J",
        "\x1b[2J",
        "\x1b[3J",
        "\x1b[H\x1b[5B\x1b[3C",
        "\x1bM",
        "\x1bD",
        "\x1bE",
        "日本語🙂wide",
        "e\u{301}a\u{308}\u{1F468}\u{200D}\u{1F469}",
        "\x1b[?1049h\x1b[Halt screen",
        "\x1b[?1049l",
        "\x1b[?47h",
        "\x1b[?47l",
        "\x1b#8",
        "\x1b]8;;https://example.invalid\x1b\\link\x1b]8;;\x1b\\",
        "\x1b[?6h\x1b[2;4r\x1b[Horigin\x1b[?6l\x1b[r",
        "\x1b[?7l no autowrap past the right edge of this grid\x1b[?7h",
        "\x1b[4h insert\x1b[4l",
        "\x1b[5;10H\x1b[?25l\x1b[?25h",
        "\x1b[2 q\x1b[6 q",
        "\x1b[?2026hsync\x1b[?2026l",
        "\x1bc",
        "\x1b[?1h\x1b=",
        "\x00\x07\x08\x0b\x0c\x0e\x0f",
        "\u{fffd}\u{ff}",
    ]
    .iter()
    .map(|text| bytes(text))
    .chain([
        Step::Bytes(vec![0xff, 0xfe, 0xc3]),
        Step::Bytes(vec![0x1b]),
        Step::Bytes(b"[1;31".to_vec()),
        Step::Bytes(b"mtail".to_vec()),
        Step::Resize(30, 8),
        Step::Resize(12, 4),
        Step::Resize(20, 6),
        Step::Scroll(-3),
        Step::Scroll(-50),
        Step::Scroll(2),
        Step::Bottom,
        Step::DefaultColors(Some(Rgb { r: 10, g: 20, b: 30 }), Some(Rgb { r: 200, g: 100, b: 0 })),
        Step::DefaultColors(Some(WHITE), Some(BLACK)),
    ])
    .collect()
}

#[test]
fn every_single_change_matches_a_full_read() {
    for (index, step) in vocabulary().iter().enumerate() {
        let mut pair = Pair::new(20, 6);
        for line in 0..12 {
            pair.step(&bytes(&format!("history line {line}\r\n")), "history");
        }
        pair.step(step, &format!("step {index}"));
        pair.step(&bytes("after"), &format!("step {index} then text"));
    }
}

#[test]
fn random_mixes_match_a_full_read() {
    let vocabulary = vocabulary();
    for seed in 1..=24u64 {
        let mut pair = Pair::new(20, 6);
        let mut state = seed.wrapping_mul(0x9E37_79B9_7F4A_7C15);
        for index in 0..250 {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            let step = &vocabulary[(state % vocabulary.len() as u64) as usize];
            pair.step(step, &format!("seed {seed} step {index}"));
        }
    }
}
