//! A replay lays its text out once when no visible image needs room
//! (H10 follow-up): the formatter pass for the second budget repeated the
//! first with the same arguments. The bytes must not change.

use super::*;

fn layouts() -> u64 {
    REPLAY_TEXT_LAYOUTS.with(std::cell::Cell::get)
}

/// Scrollback in bytes, the daemon's default (`DEFAULT_SCROLLBACK_LIMIT_BYTES`),
/// so the 10,000 lines of history stay in the terminal.
const SCROLLBACK_BYTES: usize = 10_000_000;

fn terminal_with(cols: u16, rows: u16, bytes: &[u8]) -> Terminal {
    let mut term = Terminal::new(cols, rows, SCROLLBACK_BYTES, Callbacks::default()).unwrap();
    term.resize(cols, rows, 8, 16).unwrap();
    term.vt_write(bytes);
    term
}

fn history_text(lines: usize) -> Vec<u8> {
    let mut bytes = Vec::new();
    for line in 0..lines {
        bytes.extend_from_slice(
            format!("\x1b[3{}mline {line:05} the quick brown fox\x1b[0m\r\n", line % 8).as_bytes(),
        );
    }
    bytes
}

#[test]
fn a_replay_without_a_visible_image_lays_its_text_out_once() {
    let mut term = terminal_with(120, 40, &history_text(10_000));
    let before = layouts();
    let _ = term.vt_replay_bounded(15 * 1024 * 1024).unwrap();
    assert_eq!(layouts() - before, 1, "the text was laid out more than once");
}

/// The theme-portable replay is the one a byte mirror gets on attach and resize.
#[test]
fn a_theme_portable_replay_without_a_visible_image_lays_its_text_out_once() {
    let mut term = terminal_with(120, 40, &history_text(10_000));
    let before = layouts();
    let _ = term.vt_replay_bounded_theme_portable_with_aliases(15 * 1024 * 1024).unwrap();
    assert_eq!(layouts() - before, 1, "the theme-portable text was laid out more than once");
}

/// The replay corpus (schemas/terminal-corpus) plus long history: the
/// bytes are what the two-pass layout made. The expected bytes come from
/// laying out twice by hand with the same arguments the replay used.
#[test]
fn one_pass_replays_equal_the_two_pass_bytes_on_the_corpus() {
    let dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../schemas/terminal-corpus");
    let mut cases: Vec<(String, u16, u16, Vec<u8>)> = std::fs::read_dir(&dir)
        .unwrap()
        .flatten()
        .filter(|entry| entry.path().extension().is_some_and(|ext| ext == "vt"))
        .map(|entry| {
            (
                entry.file_name().to_string_lossy().into_owned(),
                80,
                24,
                std::fs::read(entry.path()).unwrap(),
            )
        })
        .collect();
    assert!(cases.len() >= 4, "the corpus is missing: {}", dir.display());
    cases.push(("history-10k".into(), 120, 40, history_text(10_000)));
    for (name, cols, rows, bytes) in cases {
        for budget in [15 * 1024 * 1024, 256 * 1024, 4 * 1024] {
            for palette in [true, false] {
                let mut one = terminal_with(cols, rows, &bytes);
                let got = one.vt_replay_bounded_with_palette(budget, palette);
                let mut two = terminal_with(cols, rows, &bytes);
                let expected = two.vt_replay_bounded_two_pass_for_test(budget, palette);
                let (got, expected) = (got.map(|r| r.bytes), expected.map(|r| r.bytes));
                assert_eq!(
                    got.as_ref().ok(),
                    expected.as_ref().ok(),
                    "{name} at a {budget}-byte budget, palette {palette}: the replay bytes changed"
                );
                assert_eq!(
                    got.is_err(),
                    expected.is_err(),
                    "{name} at {budget}, palette {palette}: errors differ"
                );
            }
        }
    }
}

/// Bench: one theme-portable replay build (what a byte mirror gets on attach
/// and resize) of a 120x40 terminal with 10,000 lines of history, one pass
/// against two (the reference path). The arms are interleaved, their
/// order alternated each round, so neither always runs warm. Off unless
/// CMUX_REPLAY_BUILD_BENCH=<runs> is set: each run prints one
/// REPLAY-BUILD-BENCH line to stderr and appends it to
/// .build/artifacts/replay-build-bench.txt (nextest hides a passing test's
/// output; a fleet step returns the file with --artifact). Release build:
/// scripts/measure/replay-build-bench.sh.
#[test]
fn replay_build_bench_one_pass_against_two() {
    let Some(runs) = std::env::var("CMUX_REPLAY_BUILD_BENCH")
        .ok()
        .and_then(|runs| runs.parse::<usize>().ok())
        .filter(|runs| *runs > 0)
    else {
        return;
    };
    const BUILDS: usize = 60;
    const BUDGET: usize = 15 * 1024 * 1024;
    let mut one = terminal_with(120, 40, &history_text(10_000));
    let mut two = terminal_with(120, 40, &history_text(10_000));
    let build = |term: &mut Terminal, two_pass: bool| {
        let started = std::time::Instant::now();
        let replay = if two_pass {
            term.vt_replay_bounded_two_pass_for_test(BUDGET, false)
        } else {
            term.vt_replay_bounded_with_palette(BUDGET, false)
        }
        .unwrap();
        (started.elapsed().as_secs_f64() * 1000.0, replay.bytes)
    };
    let (_, one_bytes) = build(&mut one, false);
    let (_, two_bytes) = build(&mut two, true);
    assert_eq!(one_bytes, two_bytes, "the arms built different replay bytes");
    let percentiles = |times: &mut Vec<f64>| {
        times.sort_by(f64::total_cmp);
        let at = |p: f64| times[((times.len() - 1) as f64 * p).round() as usize];
        format!(
            "p50 {:.3} ms p95 {:.3} ms p99 {:.3} ms max {:.3} ms",
            at(0.5),
            at(0.95),
            at(0.99),
            at(1.0)
        )
    };
    let profile = if cfg!(debug_assertions) { "dev-profile" } else { "release" };
    let artifacts =
        std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../.build/artifacts");
    std::fs::create_dir_all(&artifacts).unwrap();
    let mut out = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(artifacts.join("replay-build-bench.txt"))
        .unwrap();
    for run in 1..=runs {
        let (mut one_ms, mut two_ms) = (Vec::with_capacity(BUILDS), Vec::with_capacity(BUILDS));
        for round in 0..BUILDS {
            if round % 2 == 0 {
                two_ms.push(build(&mut two, true).0);
                one_ms.push(build(&mut one, false).0);
            } else {
                one_ms.push(build(&mut one, false).0);
                two_ms.push(build(&mut two, true).0);
            }
        }
        let line = format!(
            "REPLAY-BUILD-BENCH run {run}/{runs} {profile} theme-portable 120x40 10k lines, \
             {BUILDS} interleaved builds per arm, {} replay bytes: two-pass {}; one-pass {}",
            one_bytes.len(),
            percentiles(&mut two_ms),
            percentiles(&mut one_ms)
        );
        eprintln!("{line}");
        std::io::Write::write_all(&mut out, format!("{line}\n").as_bytes()).unwrap();
    }
}
