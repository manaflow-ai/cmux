//! Investigation harness (term-fidelity lane, not for landing as is): random
//! TUI-like byte streams, and three equalities a correct terminal stack
//! must hold for every stream:
//!
//! 1. chunking: a terminal fed the stream in one write equals one fed the
//!    same stream in arbitrary chunks (the PTY reader's cuts);
//! 2. snapshot mirror: a terminal restored from a GHOSTSNP snapshot taken at
//!    any byte offset, then fed the rest of the stream, equals the source
//!    (the Mac app's mirror: READY restore, then live output);
//! 3. replay mirror: a new terminal fed the VT replay taken at any byte
//!    offset, then the rest of the stream, equals the source (byte-mode
//!    viewers, and a daemon rebuilt from a replay prologue).
//!
//! Equality is the idle-digest input (every SCREEN, PAGE and CONTINUATION
//! record of READY), so it covers cells, styles, cursor and modes.
//!
//! Run: `MIRROR_FUZZ_SEEDS=0..2000 cargo test -p ghostty-vt --lib mirror_fuzz -- --nocapture`

use super::*;
use crate::{Callbacks, Cell, CellWidth, ColorSpec, RenderState, Terminal};

struct Rng(u64);

impl Rng {
    fn new(seed: u64) -> Self {
        Self(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15).wrapping_add(0x2545_F491_4F6C_DD1D) | 1)
    }
    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x
    }
    fn below(&mut self, n: usize) -> usize {
        (self.next() % n.max(1) as u64) as usize
    }
    fn range(&mut self, low: usize, high: usize) -> usize {
        low + self.below(high - low + 1)
    }
    fn chance(&mut self, percent: usize) -> bool {
        self.below(100) < percent
    }
    fn pick<'a, T: ?Sized>(&mut self, items: &[&'a T]) -> &'a T {
        items[self.below(items.len())]
    }
}

const WORDS: &[&str] = &[
    "agent",
    "review",
    "merge",
    "deploy",
    "Slack",
    "gate",
    "fix",
    "the",
    "runs",
    "PR",
    "103",
    "a",
    "If",
    "that",
    "漢字",
    "日本語",
    "한국어",
    "😀",
    "❤️",
    "👨‍👩‍👧",
    "🇯🇵",
    "e\u{301}",
    "a\u{308}\u{323}",
    "→",
    "●",
    "λ",
    "│",
    "└─",
    "✓",
    "⏺",
    "✻",
    "…",
    "  ",
    " ",
];
const STYLES: &[&str] = &[
    "0",
    "1",
    "2",
    "3",
    "4",
    "4:3",
    "7",
    "9",
    "22",
    "27",
    "2;3",
    "1;7",
    "38;5;135",
    "38;5;118;48;5;236",
    "38;2;255;100;0",
    "48;2;30;30;60",
    "2;38;5;244",
    "7;38;5;240",
    "58;5;196;4:3",
    "53",
    "39",
    "49",
];

/// Which rare, risky sequence families a stream may use.
#[derive(Clone, Copy)]
struct Features {
    alternate_screen: bool,
    raw_c1: bool,
    invalid_utf8: bool,
    prompts: bool,
}

/// The stream and the end offset of each operation in it.
fn generate(
    seed: u64,
    cols: u16,
    rows: u16,
    ops: usize,
    features: Features,
) -> (Vec<u8>, Vec<usize>) {
    let mut rng = Rng::new(seed);
    let mut out: Vec<u8> = Vec::new();
    let mut bounds: Vec<usize> = Vec::new();
    let (cols, rows) = (usize::from(cols), usize::from(rows));
    macro_rules! w {
        ($($arg:tt)*) => { out.extend_from_slice(format!($($arg)*).as_bytes()) };
    }
    for _ in 0..ops {
        match rng.below(100) {
            // Styled words: the bulk of any TUI.
            0..=29 => {
                if rng.chance(50) {
                    w!("\x1b[{}m", rng.pick(STYLES));
                }
                for _ in 0..rng.range(1, 6) {
                    w!("{}", rng.pick(WORDS));
                    if rng.chance(70) {
                        w!(" ");
                    }
                }
                if rng.chance(40) {
                    w!("\x1b[0m");
                }
            }
            // Absolute and relative cursor moves.
            30..=41 => w!("\x1b[{};{}H", rng.range(1, rows), rng.range(1, cols)),
            42..=49 => {
                let n = rng.range(1, 5);
                w!("\x1b[{}{}", n, rng.pick(&["A", "B", "C", "D", "E", "F", "G", "d"]));
            }
            // A diffing renderer: a row painted with skips over cells it
            // believes are unchanged.
            50..=57 => {
                w!("\x1b[{};1H", rng.range(1, rows));
                for _ in 0..rng.range(2, 10) {
                    if rng.chance(55) {
                        w!("{}", rng.pick(WORDS));
                    } else {
                        w!("\x1b[{}C", rng.range(1, 6));
                    }
                }
            }
            58..=61 => w!("\r\n"),
            62 => w!("\r"),
            63 => w!("\n"),
            64 => w!("\t"),
            65 => w!("\x08"),
            // Erases, some with a background color set.
            66..=72 => {
                if rng.chance(40) {
                    w!("\x1b[48;5;{}m", rng.range(16, 231));
                }
                match rng.below(6) {
                    0 => w!("\x1b[K"),
                    1 => w!("\x1b[1K"),
                    2 => w!("\x1b[2K"),
                    3 => w!("\x1b[J"),
                    4 => w!("\x1b[1J"),
                    _ => w!("\x1b[{}X", rng.range(1, 20)),
                }
                if rng.chance(60) {
                    w!("\x1b[0m");
                }
            }
            // Insert and delete of cells and lines.
            73..=77 => {
                let n = rng.range(1, 4);
                w!("\x1b[{}{}", n, rng.pick(&["@", "P", "L", "M"]));
            }
            // Scroll regions and scrolls.
            78..=81 => match rng.below(6) {
                0 => {
                    let top = rng.range(1, rows.saturating_sub(2).max(1));
                    w!("\x1b[{};{}r", top, rng.range(top + 1, rows.max(top + 1)));
                }
                1 => w!("\x1b[r"),
                2 => w!("\x1b[{}S", rng.range(1, 3)),
                3 => w!("\x1b[{}T", rng.range(1, 3)),
                4 => w!("\x1bM"),
                _ => w!("\x1bD"),
            },
            // A row filled to the last column (pending wrap), a wide cell at
            // the last column.
            82..=84 => {
                w!("\x1b[{};1H", rng.range(1, rows));
                let fill = rng.pick(&["x", "─", " "]);
                for _ in 0..cols {
                    w!("{fill}");
                }
            }
            85..=86 => {
                w!("\x1b[{};{}H{}", rng.range(1, rows), cols, rng.pick(&["漢", "😀", "❤️", "x"]))
            }
            // A long line that soft-wraps.
            87..=88 => {
                for _ in 0..rng.range(cols / 4, cols) {
                    w!("{} ", rng.pick(WORDS));
                }
            }
            // Saved cursor, modes.
            89 => w!("{}", rng.pick(&["\x1b7", "\x1b8", "\x1b[s", "\x1b[u"])),
            90..=91 => w!(
                "{}",
                rng.pick(&[
                    "\x1b[?2026h",
                    "\x1b[?2026l",
                    "\x1b[?25l",
                    "\x1b[?25h",
                    "\x1b[?7l",
                    "\x1b[?7h",
                    "\x1b[4h",
                    "\x1b[4l",
                    "\x1b[?6h",
                    "\x1b[?6l",
                    "\x1b[?2027h",
                    "\x1b[?2027l",
                    "\x1b[?2004h",
                    "\x1b[?1h",
                    "\x1b[?1l",
                    "\x1b(0",
                    "\x1b(B",
                    "\x1b[1 q",
                    "\x1b[5 q",
                ])
            ),
            // Strings: links, titles, DCS, APC.
            92..=93 => match rng.below(5) {
                0 => w!("\x1b]8;;https://example.com/{}\x07link\x1b]8;;\x07", rng.below(9)),
                1 => w!("\x1b]0;title {}\x07", rng.below(9)),
                2 => w!("\x1b]2;title λ {}\x1b\\", rng.below(9)),
                3 => w!("\x1bP$qm\x1b\\"),
                _ => w!("\x1b_ignored\x1b\\"),
            },
            94..=95 if features.prompts => match rng.below(5) {
                0 => w!("\x1b]133;A;redraw=1;cl=line\x07"),
                1 => w!("\x1b]133;B\x07"),
                2 => w!("\x1b]133;C\x07"),
                3 => w!("\x1b]133;D;0\x07"),
                _ => w!("\x1b]133;P;k=s\x07"),
            },
            96 if features.alternate_screen => {
                w!(
                    "{}",
                    rng.pick(&[
                        "\x1b[?1049h",
                        "\x1b[?1049l",
                        "\x1b[?1049l",
                        "\x1b[?47h",
                        "\x1b[?47l"
                    ])
                )
            }
            97 if features.raw_c1 => {
                // 8-bit CSI and OSC forms.
                match rng.below(3) {
                    0 => out.extend_from_slice(b"\x9b1m"),
                    1 => out.extend_from_slice(b"\x9d0;c1 title\x9c"),
                    _ => out.extend_from_slice(b"\x9b2K"),
                }
            }
            98 if features.invalid_utf8 => {
                out.extend_from_slice(rng.pick(&[
                    b"\xe6\xbc".as_slice(),
                    b"\xf0\x9f".as_slice(),
                    b"\xff".as_slice(),
                    b"\xc3".as_slice(),
                ]));
            }
            // Full erase, as a TUI does on a redraw.
            99 if rng.chance(30) => w!("\x1b[H\x1b[2J"),
            _ => w!("{} ", rng.pick(WORDS)),
        }
        bounds.push(out.len());
    }
    (out, bounds)
}

const SCROLLBACK_BYTES: usize = 10_000_000;

fn terminal(cols: u16, rows: u16) -> Terminal {
    let mut term = Terminal::new(cols, rows, SCROLLBACK_BYTES, Callbacks::default()).unwrap();
    term.resize(cols, rows, 8, 16).unwrap();
    term
}

fn digest(term: &Terminal) -> Vec<u8> {
    snapshot_digest_input(&term.encode_snapshot(SnapshotPhase::Ready).unwrap())
}

fn cells(term: &mut Terminal) -> Vec<Vec<Cell>> {
    let mut rs = RenderState::new().unwrap();
    rs.update(term).unwrap();
    let mut rows = Vec::new();
    rs.walk_rows(|_, _, cells| rows.push(cells.to_vec())).unwrap();
    rows
}

/// The first way two terminals differ, as text for a report.
fn describe(a: &mut Terminal, b: &mut Terminal) -> String {
    if (a.cols(), a.rows()) != (b.cols(), b.rows()) {
        return format!("grid {:?} vs {:?}", (a.cols(), a.rows()), (b.cols(), b.rows()));
    }
    if a.active_screen() != b.active_screen() {
        return format!("screen {:?} vs {:?}", a.active_screen(), b.active_screen());
    }
    let (ca, cb) = (cells(a), cells(b));
    for (y, (ra, rb)) in ca.iter().zip(cb.iter()).enumerate() {
        for (x, (xa, xb)) in ra.iter().zip(rb.iter()).enumerate() {
            if xa != xb {
                return format!("cell row {y} col {x}: {xa:?} vs {xb:?}");
            }
        }
        if ra.len() != rb.len() {
            return format!("row {y} length {} vs {}", ra.len(), rb.len());
        }
    }
    if a.cursor_position() != b.cursor_position() {
        return format!("cursor {:?} vs {:?}", a.cursor_position(), b.cursor_position());
    }
    "cells and cursor equal; digest differs (modes, wrap flags, history or hidden state)".into()
}

/// Where two digest inputs first differ: record index, tag and payload offset.
fn describe_digest(a: &[u8], b: &[u8]) -> String {
    let (mut at, mut index) = (0usize, 0usize);
    loop {
        if at + 6 > a.len() || at + 6 > b.len() {
            return format!("record {index}: one side ends (lengths {} vs {})", a.len(), b.len());
        }
        let tag = u16::from_le_bytes([a[at], a[at + 1]]);
        let len_a = u32::from_le_bytes([a[at + 2], a[at + 3], a[at + 4], a[at + 5]]) as usize;
        let len_b = u32::from_le_bytes([b[at + 2], b[at + 3], b[at + 4], b[at + 5]]) as usize;
        if a[at..at + 6] != b[at..at + 6] {
            return format!(
                "record {index} header differs: tag {tag} len {len_a} vs tag {} len {len_b}",
                u16::from_le_bytes([b[at], b[at + 1]])
            );
        }
        let (pa, pb) = (&a[at + 6..at + 6 + len_a], &b[at + 6..at + 6 + len_a]);
        if let Some(offset) = pa.iter().zip(pb.iter()).position(|(x, y)| x != y) {
            let low = offset.saturating_sub(8);
            let high = (offset + 24).min(len_a);
            return format!(
                "record {index} tag {tag} len {len_a}: payload byte {offset}: {:02x?} vs {:02x?}",
                &pa[low..high],
                &pb[low..high]
            );
        }
        at += 6 + len_a;
        index += 1;
    }
}

/// Splits `bytes` at random points; some cases use single bytes only.
fn chunks<'a>(rng: &mut Rng, bytes: &'a [u8]) -> Vec<&'a [u8]> {
    let max = *rng.pick(&[&1usize, &3, &17, &64, &1024]);
    let mut out = Vec::new();
    let mut at = 0;
    while at < bytes.len() {
        let len = rng.range(1, max).min(bytes.len() - at);
        out.push(&bytes[at..at + len]);
        at += len;
    }
    out
}

fn seeds() -> std::ops::Range<u64> {
    let spec = std::env::var("MIRROR_FUZZ_SEEDS").unwrap_or_else(|_| "0..300".into());
    let (low, high) = spec.split_once("..").expect("MIRROR_FUZZ_SEEDS is LOW..HIGH");
    low.parse().unwrap()..high.parse().unwrap()
}

/// With `MIRROR_FUZZ_TRACE` set, names each case before it runs, so a crash
/// inside libghostty-vt (a Debug build's integrity check) names its case.
fn trace(name: &str, seed: u64) {
    if std::env::var_os("MIRROR_FUZZ_TRACE").is_some() {
        eprintln!("MIRROR-FUZZ-TRACE {name} seed {seed}");
    }
}

fn ops() -> usize {
    std::env::var("MIRROR_FUZZ_OPS").ok().and_then(|ops| ops.parse().ok()).unwrap_or(300)
}

struct Case {
    seed: u64,
    cols: u16,
    rows: u16,
    bytes: Vec<u8>,
    /// The end offset of each operation in `bytes`.
    bounds: Vec<usize>,
}

fn case(seed: u64, features: Features) -> Case {
    let mut rng = Rng::new(seed ^ 0xABCD_EF01);
    let cols = *rng.pick(&[&80u16, &120, &37, &100, &20]);
    let rows = *rng.pick(&[&24u16, &10, &40, &5]);
    let (bytes, bounds) = generate(seed, cols, rows, ops(), features);
    Case { seed, cols, rows, bytes, bounds }
}

const PLAIN: Features =
    Features { alternate_screen: false, raw_c1: false, invalid_utf8: false, prompts: true };
const EVERYTHING: Features =
    Features { alternate_screen: true, raw_c1: true, invalid_utf8: true, prompts: true };

fn report(name: &str, failures: &[String], total: u64) {
    println!("MIRROR-FUZZ {name}: {} of {total} cases differ", failures.len());
    for failure in failures.iter().take(400) {
        println!("MIRROR-FUZZ {name}: {failure}");
    }
    assert!(failures.is_empty(), "{name}: {} of {total} cases differ", failures.len());
}

fn run_chunking(name: &str, features: Features) {
    let mut failures = Vec::new();
    let range = seeds();
    let total = range.end - range.start;
    for seed in range {
        trace(name, seed);
        let case = case(seed, features);
        let mut whole = terminal(case.cols, case.rows);
        whole.vt_write(&case.bytes);
        let mut rng = Rng::new(seed ^ 0x5151);
        let mut chunked = terminal(case.cols, case.rows);
        let mut accepted = Vec::new();
        for chunk in chunks(&mut rng, &case.bytes) {
            accepted.extend_from_slice(&chunked.vt_write_with_normalized(chunk));
        }
        if digest(&whole) != digest(&chunked) {
            failures.push(format!(
                "seed {seed} {}x{} whole vs chunked: {}",
                case.cols,
                case.rows,
                describe(&mut whole, &mut chunked)
            ));
            continue;
        }
        // What viewers parse: the accepted (normalized) stream.
        let mut viewer = terminal(case.cols, case.rows);
        viewer.vt_write(&accepted);
        if digest(&viewer) != digest(&chunked) {
            failures.push(format!(
                "seed {seed} {}x{} accepted stream vs source: {}",
                case.cols,
                case.rows,
                describe(&mut viewer, &mut chunked)
            ));
        }
    }
    report(name, &failures, total);
}

#[test]
fn mirror_fuzz_chunking_plain() {
    run_chunking("chunking-plain", PLAIN);
}

#[test]
fn mirror_fuzz_chunking_everything() {
    run_chunking("chunking-everything", EVERYTHING);
}

/// A terminal's whole state as the VT formatter writes it (every row with
/// its styles, cursor, modes, scrolling region, tab stops, keyboard state,
/// charsets, palette). It depends on the cells, not on how pages hold them,
/// so two terminals with the same state give the same bytes. (A snapshot's
/// own bytes do not: page counts and style tables differ after a restore.)
fn dump(raw: sys::GhosttyTerminal) -> Vec<u8> {
    use std::mem::size_of;
    let opts = sys::GhosttyFormatterTerminalOptions {
        size: size_of::<sys::GhosttyFormatterTerminalOptions>(),
        emit: sys::GHOSTTY_FORMATTER_FORMAT_VT,
        unwrap: false,
        trim: false,
        extra: sys::GhosttyFormatterTerminalExtra {
            size: size_of::<sys::GhosttyFormatterTerminalExtra>(),
            palette: true,
            modes: true,
            scrolling_region: true,
            tabstops: true,
            pwd: true,
            keyboard: true,
            screen: sys::GhosttyFormatterScreenExtra {
                size: size_of::<sys::GhosttyFormatterScreenExtra>(),
                cursor: true,
                style: true,
                hyperlink: true,
                protection: true,
                kitty_keyboard: true,
                charsets: true,
            },
        },
        selection: std::ptr::null(),
    };
    let mut formatter: sys::GhosttyFormatter = std::ptr::null_mut();
    check(unsafe {
        sys::ghostty_formatter_terminal_new(std::ptr::null(), &mut formatter, raw, opts)
    })
    .unwrap();
    let mut needed: usize = 0;
    let _ = unsafe {
        sys::ghostty_formatter_format_buf(formatter, std::ptr::null_mut(), 0, &mut needed)
    };
    let mut buf = vec![0u8; needed.max(1)];
    let mut written: usize = 0;
    check(unsafe {
        sys::ghostty_formatter_format_buf(formatter, buf.as_mut_ptr(), buf.len(), &mut written)
    })
    .unwrap();
    unsafe { sys::ghostty_formatter_free(formatter) };
    buf.truncate(written);
    buf
}

/// The dump of a terminal restored from `raw`'s COMPLETE snapshot. A live
/// terminal's rows carry bookkeeping the formatter reads but no one sees
/// (the `Row.blank` flag changes where it writes a style reset); a restore
/// sets that bookkeeping from the cells alone, so equal cells and state give
/// equal bytes.
fn canonical(raw: sys::GhosttyTerminal) -> Vec<u8> {
    let Ok(complete) = encode_raw(raw, SnapshotPhase::Complete) else {
        return b"<encode failed>".to_vec();
    };
    match DecodedTerminal::decode(&complete) {
        Ok(restored) => dump(restored.raw()),
        Err(_) => b"<decode failed>".to_vec(),
    }
}

/// How two terminals' dumps differ, with the bytes around the first
/// difference, or `None` when they are equal.
fn compare(source: sys::GhosttyTerminal, mirror: sys::GhosttyTerminal) -> Option<String> {
    let (a, b) = (canonical(source), canonical(mirror));
    if a == b {
        return None;
    }
    let at = a.iter().zip(b.iter()).position(|(x, y)| x != y).unwrap_or(a.len().min(b.len()));
    let show = |bytes: &[u8]| {
        let low = at.saturating_sub(40);
        let high = (at + 60).min(bytes.len());
        format!("{:?}", String::from_utf8_lossy(&bytes[low..high]))
    };
    Some(format!("dump byte {at} of {}/{}: {} vs {}", a.len(), b.len(), show(&a), show(&b)))
}

/// Source fed `prefix`, a mirror made at that point, then both fed `rest`.
fn run_mirror(name: &str, features: Features, snapshot: bool, resize_at_cut: bool) {
    let mut failures = Vec::new();
    let range = seeds();
    let total = range.end - range.start;
    for seed in range {
        trace(name, seed);
        let case = case(seed, features);
        let mut rng = Rng::new(seed ^ 0x7777);
        let cut = rng.below(case.bytes.len() + 1);
        let (prefix, rest) = case.bytes.split_at(cut);
        let mut source = terminal(case.cols, case.rows);
        for chunk in chunks(&mut rng, prefix) {
            source.vt_write(chunk);
        }
        let (mut cols, mut rows) = (case.cols, case.rows);
        if resize_at_cut {
            cols = (i32::from(cols) + rng.range(0, 30) as i32 - 15).clamp(4, 200) as u16;
            rows = (i32::from(rows) + rng.range(0, 10) as i32 - 5).clamp(2, 80) as u16;
            source.resize(cols, rows, 8, 16).unwrap();
        }
        let label = format!(
            "seed {seed} {}x{} cut {cut}/{} grid-at-cut {cols}x{rows}",
            case.cols,
            case.rows,
            case.bytes.len()
        );
        if snapshot {
            let complete = match source.encode_snapshot(SnapshotPhase::Complete) {
                Ok(complete) => complete,
                Err(error) => {
                    failures.push(format!("{label}: CLASS encode-failed {error:?}"));
                    continue;
                }
            };
            let mirror = match DecodedTerminal::decode(&complete) {
                Ok(mirror) => mirror,
                Err(error) => {
                    failures.push(format!("{label}: CLASS decode-failed {error:?}"));
                    continue;
                }
            };
            if let Some(difference) = compare(source.raw(), mirror.raw()) {
                failures.push(format!("{label}: CLASS snapshot-at-cut {difference}"));
                continue;
            }
            for chunk in chunks(&mut rng, rest) {
                let accepted = source.vt_write_with_normalized(chunk);
                unsafe {
                    sys::ghostty_terminal_vt_write(mirror.raw(), accepted.as_ptr(), accepted.len())
                };
            }
            if let Some(difference) = compare(source.raw(), mirror.raw()) {
                failures.push(format!("{label}: CLASS snapshot-then-stream {difference}"));
            }
        } else {
            let replay = source.vt_replay().unwrap();
            let mut mirror = terminal(cols, rows);
            mirror.vt_write(&replay.bytes);
            mirror.vt_write(&replay.pending_sequence);
            let at_cut = compare(source.raw(), mirror.raw());
            let cells_at_cut = describe(&mut source, &mut mirror);
            let cells_equal = cells_at_cut.starts_with("cells and cursor equal");
            if !cells_equal {
                failures.push(format!("{label}: CLASS replay-cells {cells_at_cut}"));
                continue;
            }
            for chunk in chunks(&mut rng, rest) {
                let accepted = source.vt_write_with_normalized(chunk).into_owned();
                mirror.vt_write(&accepted);
            }
            let after = describe(&mut source, &mut mirror);
            if !after.starts_with("cells and cursor equal") {
                failures.push(format!(
                    "{label}: CLASS replay-then-stream-cells (state at cut: {}) {after}",
                    at_cut.as_deref().unwrap_or("equal")
                ));
            } else if let Some(difference) = at_cut {
                failures.push(format!("{label}: CLASS replay-state-only {difference}"));
            }
        }
    }
    report(name, &failures, total);
}

#[test]
fn mirror_fuzz_snapshot_plain() {
    run_mirror("snapshot-plain", PLAIN, true, false);
}

#[test]
fn mirror_fuzz_snapshot_everything() {
    run_mirror("snapshot-everything", EVERYTHING, true, false);
}

#[test]
fn mirror_fuzz_snapshot_after_resize() {
    run_mirror("snapshot-after-resize", EVERYTHING, true, true);
}

#[test]
fn mirror_fuzz_replay_plain() {
    run_mirror("replay-plain", PLAIN, false, false);
}

#[test]
fn mirror_fuzz_replay_everything() {
    run_mirror("replay-everything", EVERYTHING, false, false);
}

#[test]
fn mirror_fuzz_replay_after_resize() {
    run_mirror("replay-after-resize", EVERYTHING, false, true);
}

/// Whether a snapshot mirror made after `prefix` differs from the source
/// once both got `rest` (each written whole).
fn snapshot_mirror_differs(cols: u16, rows: u16, prefix: &[u8], rest: &[u8]) -> bool {
    let mut source = terminal(cols, rows);
    source.vt_write(prefix);
    let Ok(complete) = source.encode_snapshot(SnapshotPhase::Complete) else { return false };
    let Ok(mirror) = DecodedTerminal::decode(&complete) else { return false };
    if canonical(source.raw()) != canonical(mirror.raw()) {
        return true;
    }
    let accepted = source.vt_write_with_normalized(rest).into_owned();
    unsafe { sys::ghostty_terminal_vt_write(mirror.raw(), accepted.as_ptr(), accepted.len()) };
    canonical(source.raw()) != canonical(mirror.raw())
}

/// Shrinks failing snapshot cases to the operations that still fail, and
/// prints them (`MIRROR-FUZZ-MIN`), so a person can read the cause.
#[test]
fn mirror_fuzz_snapshot_minimize() {
    let wanted: usize =
        std::env::var("MIRROR_FUZZ_MINIMIZE").ok().and_then(|n| n.parse().ok()).unwrap_or(6);
    let mut found = 0;
    for seed in seeds() {
        if found == wanted {
            break;
        }
        let case = case(seed, PLAIN);
        let mut ops: Vec<&[u8]> = Vec::new();
        let mut start = 0;
        for end in &case.bounds {
            ops.push(&case.bytes[start..*end]);
            start = *end;
        }
        let mut rng = Rng::new(seed ^ 0x7777);
        let cut = rng.below(ops.len() + 1);
        let (mut prefix, mut rest) = (ops[..cut].to_vec(), ops[cut..].to_vec());
        let fails = |prefix: &[&[u8]], rest: &[&[u8]]| {
            snapshot_mirror_differs(case.cols, case.rows, &prefix.concat(), &rest.concat())
        };
        if !fails(&prefix, &rest) {
            continue;
        }
        found += 1;
        loop {
            let mut changed = false;
            for list in 0..2 {
                let mut index = if list == 0 { prefix.len() } else { rest.len() };
                while index > 0 {
                    index -= 1;
                    let (mut p, mut r) = (prefix.clone(), rest.clone());
                    if list == 0 {
                        p.remove(index);
                    } else {
                        r.remove(index);
                    }
                    if fails(&p, &r) {
                        prefix = p;
                        rest = r;
                        changed = true;
                    }
                }
            }
            if !changed {
                break;
            }
        }
        let (prefix, rest) = (prefix.concat(), rest.concat());
        let mut source = terminal(case.cols, case.rows);
        source.vt_write(&prefix);
        let complete = source.encode_snapshot(SnapshotPhase::Complete).unwrap();
        let mirror = DecodedTerminal::decode(&complete).unwrap();
        let at_cut = compare(source.raw(), mirror.raw());
        let accepted = source.vt_write_with_normalized(&rest).into_owned();
        unsafe { sys::ghostty_terminal_vt_write(mirror.raw(), accepted.as_ptr(), accepted.len()) };
        println!(
            "MIRROR-FUZZ-MIN seed {} {}x{} prefix=\"{}\" rest=\"{}\" at-cut={:?} after={:?}",
            case.seed,
            case.cols,
            case.rows,
            prefix.escape_ascii(),
            rest.escape_ascii(),
            at_cut,
            compare(source.raw(), mirror.raw())
        );
    }
}

/// `cell` without what no one can see: a blank cell (no text, or a space)
/// shows only its background, inverse, underline and strikethrough.
fn visible(cell: &Cell) -> Cell {
    let mut cell = cell.clone();
    if cell.text.is_empty() || cell.text == " " {
        cell.text = String::new();
        cell.width = CellWidth::Narrow;
        cell.bold = false;
        cell.faint = false;
        cell.italic = false;
        cell.blink = false;
        cell.invisible = false;
        if !cell.inverse {
            cell.fg = ColorSpec::Default;
            cell.resolved_fg = None;
        }
    }
    cell
}

/// The first cell two terminals show differently, or `None`.
fn visible_difference(a: &mut Terminal, b: &mut Terminal) -> Option<String> {
    if (a.cols(), a.rows()) != (b.cols(), b.rows()) || a.active_screen() != b.active_screen() {
        return Some(describe(a, b));
    }
    let (ca, cb) = (cells(a), cells(b));
    for (y, (ra, rb)) in ca.iter().zip(cb.iter()).enumerate() {
        for (x, (xa, xb)) in ra.iter().zip(rb.iter()).enumerate() {
            let (va, vb) = (visible(xa), visible(xb));
            if va != vb {
                let brief = |c: &Cell| {
                    format!(
                        "{:?} fg={:?} bg={:?} b{} f{} i{} u{} s{} inv{}",
                        c.text,
                        c.fg,
                        c.bg,
                        c.bold as u8,
                        c.faint as u8,
                        c.italic as u8,
                        c.underline as u8,
                        c.strikethrough as u8,
                        c.inverse as u8
                    )
                };
                return Some(format!("row {y} col {x}: [{}] vs [{}]", brief(&va), brief(&vb)));
            }
        }
    }
    (a.cursor_position() != b.cursor_position())
        .then(|| format!("cursor {:?} vs {:?}", a.cursor_position(), b.cursor_position()))
}

/// How a replay mirror made after `prefix` shows something else than the
/// source, at once or after `rest`.
fn replay_mirror_difference(cols: u16, rows: u16, prefix: &[u8], rest: &[u8]) -> Option<String> {
    let mut source = terminal(cols, rows);
    source.vt_write(prefix);
    let replay = source.vt_replay().ok()?;
    let mut mirror = terminal(cols, rows);
    mirror.vt_write(&replay.bytes);
    mirror.vt_write(&replay.pending_sequence);
    if let Some(difference) = visible_difference(&mut source, &mut mirror) {
        return Some(format!("at the cut: {difference}"));
    }
    let accepted = source.vt_write_with_normalized(rest).into_owned();
    mirror.vt_write(&accepted);
    visible_difference(&mut source, &mut mirror).map(|d| format!("after the rest: {d}"))
}

/// Counts replay cases a person would see, and shrinks the first ones
/// (`MIRROR-FUZZ-MIN replay`).
#[test]
fn mirror_fuzz_replay_minimize() {
    let wanted: usize =
        std::env::var("MIRROR_FUZZ_MINIMIZE").ok().and_then(|n| n.parse().ok()).unwrap_or(6);
    let (mut found, mut visible_cases, mut total) = (0, 0u64, 0u64);
    for seed in seeds() {
        total += 1;
        let case = case(seed, PLAIN);
        let mut ops: Vec<&[u8]> = Vec::new();
        let mut start = 0;
        for end in &case.bounds {
            ops.push(&case.bytes[start..*end]);
            start = *end;
        }
        let mut rng = Rng::new(seed ^ 0x7777);
        let cut = rng.below(ops.len() + 1);
        let (mut prefix, mut rest) = (ops[..cut].to_vec(), ops[cut..].to_vec());
        let difference = |prefix: &[&[u8]], rest: &[&[u8]]| {
            replay_mirror_difference(case.cols, case.rows, &prefix.concat(), &rest.concat())
        };
        if difference(&prefix, &rest).is_none() {
            continue;
        }
        visible_cases += 1;
        if found == wanted {
            continue;
        }
        found += 1;
        loop {
            let mut changed = false;
            for list in 0..2 {
                let mut index = if list == 0 { prefix.len() } else { rest.len() };
                while index > 0 {
                    index -= 1;
                    let (mut p, mut r) = (prefix.clone(), rest.clone());
                    if list == 0 {
                        p.remove(index);
                    } else {
                        r.remove(index);
                    }
                    if difference(&p, &r).is_some() {
                        prefix = p;
                        rest = r;
                        changed = true;
                    }
                }
            }
            if !changed {
                break;
            }
        }
        let mut source = terminal(case.cols, case.rows);
        source.vt_write(&prefix.concat());
        let replay = source.vt_replay().unwrap();
        println!(
            "MIRROR-FUZZ-MIN replay seed {} {}x{} prefix=\"{}\" rest=\"{}\" replay-tail=\"{}\" difference={:?}",
            case.seed,
            case.cols,
            case.rows,
            prefix.concat().escape_ascii(),
            rest.concat().escape_ascii(),
            replay.bytes[replay.bytes.len().saturating_sub(260)..].escape_ascii(),
            difference(&prefix, &rest)
        );
    }
    println!("MIRROR-FUZZ replay-visible: {visible_cases} of {total} cases show a difference");
}
