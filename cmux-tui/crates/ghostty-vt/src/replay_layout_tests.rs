//! A replay lays its text out once when no visible image needs room
//! (H10 follow-up): the formatter pass for the second budget repeated the
//! first with the same arguments. The bytes must not change.

use super::*;

fn layouts() -> u64 {
    REPLAY_TEXT_LAYOUTS.with(std::cell::Cell::get)
}

fn terminal_with(cols: u16, rows: u16, bytes: &[u8]) -> Terminal {
    let mut term = Terminal::new(cols, rows, 10_000, Callbacks::default()).unwrap();
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
            let mut one = terminal_with(cols, rows, &bytes);
            let got = one.vt_replay_bounded(budget).map(|replay| replay.bytes);
            let mut two = terminal_with(cols, rows, &bytes);
            let expected =
                two.vt_replay_bounded_two_pass_for_test(budget).map(|replay| replay.bytes);
            assert_eq!(
                got.as_ref().ok(),
                expected.as_ref().ok(),
                "{name} at a {budget}-byte budget: the replay bytes changed"
            );
            assert_eq!(got.is_err(), expected.is_err(), "{name} at {budget}: errors differ");
        }
    }
}

/// Bench: one replay build of a 120x40 terminal with 10,000 lines of history,
/// one pass against two. Run with --release --ignored --nocapture.
#[test]
#[ignore = "bench: prints replay build times"]
fn replay_build_bench_one_pass_against_two() {
    let mut one = terminal_with(120, 40, &history_text(10_000));
    let mut two = terminal_with(120, 40, &history_text(10_000));
    let mut sample = |term: &mut Terminal, two_pass: bool| {
        let mut times: Vec<f64> = (0..30)
            .map(|_| {
                let started = std::time::Instant::now();
                let _ = if two_pass {
                    term.vt_replay_bounded_two_pass_for_test(15 * 1024 * 1024)
                } else {
                    term.vt_replay_bounded(15 * 1024 * 1024)
                }
                .unwrap();
                started.elapsed().as_secs_f64() * 1000.0
            })
            .collect();
        times.sort_by(f64::total_cmp);
        (times[15], times[28])
    };
    let (two_p50, two_p95) = sample(&mut two, true);
    let (one_p50, one_p95) = sample(&mut one, false);
    eprintln!(
        "REPLAY-BUILD-BENCH 120x40 10k lines: two-pass p50 {two_p50:.1} ms p95 {two_p95:.1} ms; \
         one-pass p50 {one_p50:.1} ms p95 {one_p95:.1} ms"
    );
}
