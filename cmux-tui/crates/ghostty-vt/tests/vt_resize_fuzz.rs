//! Terminal fuzz (fuzz catalog row e, 2026-10-31): random byte streams and
//! escape sequences into a libghostty-vt terminal at random sizes, with
//! random resizes between the writes. After every step:
//!
//! - no crash (a panic or an abort fails the test binary);
//! - GRID: after a resize to `cols x rows`, the terminal is `max(cols, 1) x
//!   max(rows, 1)`, and the cursor is inside the grid;
//! - REPLAY (the R3a view side; off while #29136 is open, see
//!   [`OPEN_FINDING_ORACLES`]): a fresh terminal of the same size fed the
//!   attach replay shows the same viewport text and cursor, which is what a
//!   frontend that attaches at that moment shows; checked only while the
//!   stream is at ground (no unfinished sequence);
//! - SNAPSHOT: the READY snapshot encodes (off while #29136 is open);
//! - STALL: no single write, resize or replay takes over 5 s (a hang
//!   detector under a loaded runner; `CMUX_VT_FUZZ_STALL_MS=100` is the
//!   100 ms main-thread budget for a run on an idle host).
//!
//! `CMUX_VT_FUZZ_CASES` sets the number of sequences (default 128). A failure
//! prints the shrunk op list: paste it into a red test.

use std::time::{Duration, Instant};

use ghostty_vt::{Callbacks, SnapshotPhase, Terminal};
use proptest::prelude::*;
use proptest::test_runner::RngSeed;

const SCROLLBACK: usize = 1 << 20;

/// The REPLAY and SNAPSHOT oracles find the open findings e1-e3 (issue
/// #29136; red tests on `fuzz-red/terminal-e1`). While they are open both
/// are off here, so this test does not turn the base red. The fuzz runs keep
/// them on, with a random seed (scratch branch `cp/fuzz-vt-replay-on`). The
/// fix PR for #29136 sets this to true.
const OPEN_FINDING_ORACLES: bool = true;

/// The landed test uses a fixed seed, so it gives the same cases every run
/// and cannot turn the base red on a new random input; the fuzz runs on the
/// scratch branch use a random seed.
const FIXED_SEED: Option<u64> = None;

#[derive(Debug, Clone)]
enum Op {
    Write(Vec<u8>),
    Resize(u16, u16),
}

fn env_u64(name: &str, default: u64) -> u64 {
    std::env::var(name).ok().and_then(|value| value.parse().ok()).unwrap_or(default)
}

fn stall_limit() -> Duration {
    Duration::from_millis(env_u64("CMUX_VT_FUZZ_STALL_MS", 5_000))
}

/// A grid size: mostly ordinary, sometimes 0, 1 or huge.
fn size() -> impl Strategy<Value = (u16, u16)> {
    prop_oneof![
        6 => (20u16..=200, 5u16..=60),
        2 => (1u16..=8, 1u16..=4),
        1 => (0u16..=2, 0u16..=2),
        1 => (300u16..=500, 100u16..=300),
    ]
}

fn csi_final() -> impl Strategy<Value = u8> {
    prop::sample::select(b"@ABCDEFGHIJKLMPSTXZ`abcdefghilmnqrstuxz".to_vec())
}

/// One piece of terminal output.
fn piece() -> impl Strategy<Value = Vec<u8>> {
    let params = prop::collection::vec(0u16..=1200, 0..4).prop_map(|params| {
        params.iter().map(u16::to_string).collect::<Vec<_>>().join(";").into_bytes()
    });
    prop_oneof![
        // Text: ASCII lines, sometimes longer than the widest grid.
        4 => "[ -~]{0,600}".prop_map(String::into_bytes),
        // Wide, combining and emoji text.
        2 => "[a-z\u{4e00}-\u{4e20}\u{0301}\u{1f600}-\u{1f610}\u{200d}\u{fe0f} ]{0,80}"
            .prop_map(String::into_bytes),
        // Control characters.
        2 => prop::collection::vec(prop::sample::select(b"\r\n\t\x08\x07\x0b\x0c\x0e\x0f".to_vec()), 1..8),
        // CSI with parameters, private or not.
        4 => (any::<bool>(), params, csi_final()).prop_map(|(private, params, last)| {
            let mut bytes = b"\x1b[".to_vec();
            if private {
                bytes.push(b'?');
            }
            bytes.extend(params);
            bytes.push(last);
            bytes
        }),
        // Modes that change geometry handling: alt screen, autowrap, origin,
        // scroll region, reflow-sensitive ones.
        2 => prop::sample::select(vec![
            b"\x1b[?1049h".to_vec(), b"\x1b[?1049l".to_vec(), b"\x1b[?47h".to_vec(),
            b"\x1b[?7l".to_vec(), b"\x1b[?7h".to_vec(), b"\x1b[?6h".to_vec(),
            b"\x1b[?6l".to_vec(), b"\x1b[3;10r".to_vec(), b"\x1b[r".to_vec(),
            b"\x1b[?2004h".to_vec(), b"\x1b[?1000h".to_vec(), b"\x1b[?1006h".to_vec(),
            b"\x1b7".to_vec(), b"\x1b8".to_vec(), b"\x1bc".to_vec(), b"\x1b[!p".to_vec(),
            b"\x1b#8".to_vec(), b"\x1b[2J".to_vec(), b"\x1b[3J".to_vec(), b"\x1bM".to_vec(),
            b"\x1bD".to_vec(), b"\x1bE".to_vec(), b"\x1b[18t".to_vec(), b"\x1b[6n".to_vec(),
        ]),
        // OSC title, cwd, hyperlink and clipboard, terminated by BEL or ST,
        // sometimes not terminated.
        1 => ("[0-9]{1,4}", "[ -~]{0,40}", 0..3u8).prop_map(|(code, text, end)| {
            let mut bytes = format!("\x1b]{code};{text}").into_bytes();
            match end {
                0 => bytes.push(0x07),
                1 => bytes.extend_from_slice(b"\x1b\\"),
                _ => {}
            }
            bytes
        }),
        // DCS and APC strings (DECRQSS, tmux, Kitty graphics headers).
        1 => ("[ -~]{0,40}", any::<bool>()).prop_map(|(text, apc)| {
            let mut bytes = if apc { b"\x1b_G".to_vec() } else { b"\x1bP".to_vec() };
            bytes.extend(text.into_bytes());
            bytes.extend_from_slice(b"\x1b\\");
            bytes
        }),
        // Raw bytes, including C1 controls and invalid UTF-8.
        2 => prop::collection::vec(any::<u8>(), 1..64),
    ]
}

fn op() -> impl Strategy<Value = Op> {
    prop_oneof![
        5 => prop::collection::vec(piece(), 1..12).prop_map(|pieces| Op::Write(pieces.concat())),
        2 => size().prop_map(|(cols, rows)| Op::Resize(cols, rows)),
    ]
}

/// Run `work`, failing when it takes longer than the stall limit.
fn timed<T>(what: &str, work: impl FnOnce() -> T) -> Result<T, String> {
    let start = Instant::now();
    let result = work();
    let elapsed = start.elapsed();
    if elapsed > stall_limit() {
        return Err(format!("STALL: {what} took {} ms", elapsed.as_millis()));
    }
    Ok(result)
}

fn check_grid(term: &Terminal, cols: u16, rows: u16) -> Result<(), String> {
    let (want_cols, want_rows) = (cols.max(1), rows.max(1));
    if (term.cols(), term.rows()) != (want_cols, want_rows) {
        return Err(format!(
            "GRID: the terminal is {}x{} after a resize to {cols}x{rows}",
            term.cols(),
            term.rows()
        ));
    }
    match term.cursor_position() {
        Some((x, y)) if x < want_cols && y < want_rows => Ok(()),
        cursor => {
            Err(format!("GRID: cursor {cursor:?} is outside the {want_cols}x{want_rows} grid"))
        }
    }
}

fn check_replay(term: &mut Terminal) -> Result<(), String> {
    if !OPEN_FINDING_ORACLES || !term.vt_stream_is_ground() {
        return Ok(());
    }
    let (cols, rows) = (term.cols(), term.rows());
    let replay = timed("vt_replay_bytes", || term.vt_replay_bytes())?
        .map_err(|error| format!("REPLAY: vt_replay_bytes failed: {error:#}"))?;
    let mut mirror = Terminal::new(cols, rows, SCROLLBACK, Callbacks::default())
        .map_err(|error| format!("REPLAY: mirror terminal: {error:#}"))?;
    timed("replay write", || mirror.vt_write(&replay))?;
    let source_text = term.viewport_text().map_err(|error| format!("viewport_text: {error:#}"))?;
    let mirror_text =
        mirror.viewport_text().map_err(|error| format!("mirror viewport_text: {error:#}"))?;
    if source_text != mirror_text {
        return Err(format!(
            "REPLAY: at {cols}x{rows} the attached view differs from the terminal:\n terminal {source_text:?}\n view     {mirror_text:?}"
        ));
    }
    if term.cursor_position() != mirror.cursor_position() {
        return Err(format!(
            "REPLAY: at {cols}x{rows} the attached view's cursor {:?} is not the terminal's {:?}",
            mirror.cursor_position(),
            term.cursor_position()
        ));
    }
    Ok(())
}

fn run_sequence(start: (u16, u16), ops: &[Op]) -> Result<(), String> {
    let (mut cols, mut rows) = start;
    let mut term = Terminal::new(cols, rows, SCROLLBACK, Callbacks::default())
        .map_err(|error| format!("setup: {error:#}"))?;
    check_grid(&term, cols, rows)?;
    for (index, op) in ops.iter().enumerate() {
        let at = |error: String| format!("step {index} ({op:?}): {error}");
        match op {
            Op::Write(bytes) => timed("vt_write", || term.vt_write(bytes)).map_err(at)?,
            Op::Resize(new_cols, new_rows) => {
                (cols, rows) = (*new_cols, *new_rows);
                timed("resize", || term.resize(cols, rows, 8, 16))
                    .map_err(at)?
                    .map_err(|error| at(format!("resize failed: {error:#}")))?;
            }
        }
        // A program may change the grid itself, only through DECCOLM
        // (CSI ? 3 h / l with mode 40): 80 or 132 columns, the same rows.
        if matches!(op, Op::Write(_)) && (term.cols(), term.rows()) != (cols.max(1), rows.max(1)) {
            if term.rows() != rows.max(1) || ![80, 132].contains(&term.cols()) {
                return Err(at(format!(
                    "GRID: a write changed the grid from {}x{} to {}x{} (only DECCOLM may, to 80 or 132 columns)",
                    cols.max(1),
                    rows.max(1),
                    term.cols(),
                    term.rows()
                )));
            }
            cols = term.cols();
        }
        check_grid(&term, cols, rows).map_err(at)?;
        let snapshot =
            timed("encode_snapshot", || term.encode_snapshot(SnapshotPhase::Ready)).map_err(at)?;
        if OPEN_FINDING_ORACLES {
            snapshot.map_err(|error| at(format!("SNAPSHOT: {error:#}")))?;
        }
        check_replay(&mut term).map_err(at)?;
    }
    Ok(())
}

proptest! {
    #![proptest_config(ProptestConfig {
        cases: u32::try_from(env_u64("CMUX_VT_FUZZ_CASES", 128)).unwrap_or(u32::MAX),
        failure_persistence: None,
        max_shrink_iters: 4_000,
        max_shrink_time: 60_000,
        rng_seed: FIXED_SEED.map_or(RngSeed::Random, RngSeed::Fixed),
        ..ProptestConfig::default()
    })]

    #[test]
    fn vt_resize_fuzz(start in size(), ops in prop::collection::vec(op(), 1..=40)) {
        if let Err(error) = run_sequence(start, &ops) {
            prop_assert!(false, "{}", error);
        }
    }
}
