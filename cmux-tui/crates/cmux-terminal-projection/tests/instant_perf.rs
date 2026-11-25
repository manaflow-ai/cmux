//! The projection's instant-perf bench, by the rules of
//! `cmux-next-ios/design/instant-perf.md`: each metric runs on a SMALL and
//! a GOD terminal, the Mac's grid 120 x 40, the phone's 52 x 38. SMALL holds
//! 100 history rows, GOD 100,000 (`docs/design/ios-terminal-projection.md`
//! in manaflow-ai/cmuxterm-hq, phase 2).
//!
//! - `terminal_dirty_rows_frame` (target 4 ms): one frame of streamed
//!   output (a Claude Code like burst: colored lines, wide characters and a
//!   spinner rewrite, taken in chunks as the link delivers them, then
//!   painted once) to the bytes the phone's terminal draws.
//! - `terminal_column_change_first_frame` (target 16 ms): the phone's
//!   terminal goes from 120 to 52 columns (fit-width to readable, or a
//!   rotation): the projection re-wraps its window at 52 and the phone's
//!   Ghostty VT takes the reset, the first frame's state.
//! - The ratio: god at most 1.2x small, as `god / max(small, 1 ms)`.
//!
//! Budget = 3x target. The god budget and the ratio always assert in a
//! release build; the small budget fails the run only with
//! `CMUX_INSTANT_PERF_STRICT=1` (a quiet harness), elsewhere a miss is in the
//! line's `failing`. A debug build prints and asserts nothing: its numbers
//! measure the optimizer, not the projection. Each metric prints
//! `INSTANTPERF {json}` (`CMUX_INSTANT_PERF_OUT=DIR` appends it to
//! `DIR/terminal-projection.jsonl`, which `cmux-next-ios/scripts/instant_perf_table.py`
//! reads) and the three checks as `INSTANTPERF check:` lines.
//!
//!     cargo test --release -p cmux-terminal-projection --test instant_perf -- --nocapture
//!
//! Small and god are built first and timed in turn, run by run, so both
//! share one heap (a 100k-row heap alone moves every paint of the process).

use std::time::Instant;

use cmux_terminal_projection::{Projection, Segment};
use ghostty_vt::{Callbacks, Terminal as Vt};

const HOST: (usize, usize) = (120, 40);
const PHONE: (usize, usize) = (52, 38);
const SMALL_ROWS: usize = 100;
const GOD_ROWS: usize = 100_000;
const RUNS: usize = 31;
const BUDGET_FACTOR: f64 = 3.0;
const RATIO_LIMIT: f64 = 1.2;
const RATIO_FLOOR_MS: f64 = 1.0;
const NOISE_MS: f64 = 2.0;
const NOISE_SHARE_OF_TARGET: f64 = 0.1;

fn history(rows: usize) -> Vec<u8> {
    let mut bytes = Vec::new();
    for i in 0..rows {
        bytes.extend_from_slice(
            format!(
                "\x1b[32m{i:06}\x1b[0m build step compiling a crate with a long enough line to wrap on the phone {i}\r\n"
            )
            .as_bytes(),
        );
    }
    bytes.extend_from_slice(b"$ ");
    bytes
}

/// One frame's worth of agent output (~2 KB, 8 new rows and a spinner).
fn burst(frame: usize) -> Vec<u8> {
    let mut b = Vec::new();
    for i in 0..8 {
        b.extend_from_slice(
            format!(
                "\r\x1b[K\x1b[38;5;174m⏺\x1b[0m Update(src/lib.rs) 中文 ✅ \x1b[2mframe {frame} line {i} of a long tool result that wraps on the phone\x1b[0m\r\n"
            )
            .as_bytes(),
        );
    }
    b.extend_from_slice(
        format!("\x1b[38;5;174m✻\x1b[0m Thinking… {frame} (esc to interrupt)").as_bytes(),
    );
    b
}

struct Phone {
    projection: Projection,
    vt: Vt,
    cols: usize,
    rows: usize,
}

fn vt(cols: usize, rows: usize) -> Vt {
    Vt::new(cols as u16, rows as u16, 256 << 20, Callbacks::default()).expect("ghostty vt")
}

impl Phone {
    fn new(history_rows: usize) -> Phone {
        let mut projection = Projection::new(HOST.0, HOST.1, history_rows + 1_000);
        let mut phone = Phone {
            vt: vt(PHONE.0, PHONE.1),
            projection: Projection::new(1, 1, 1),
            cols: PHONE.0,
            rows: PHONE.1,
        };
        let mut segments = projection.set_viewport(PHONE.0, PHONE.1);
        segments.extend(projection.feed(&history(history_rows), true));
        phone.projection = projection;
        phone.take(segments);
        phone
    }

    /// The phone's terminal takes what the projection wrote.
    fn take(&mut self, segments: Vec<Segment>) -> usize {
        let mut n = 0;
        for segment in segments {
            match segment {
                Segment::Reset(bytes) => {
                    n += bytes.len();
                    self.vt = vt(self.cols, self.rows);
                    self.vt.vt_write(&bytes);
                }
                Segment::Paint(bytes) | Segment::Raw(bytes) => {
                    n += bytes.len();
                    self.vt.vt_write(&bytes);
                }
                Segment::Alternate(_) => {}
            }
        }
        n
    }

    fn resize(&mut self, cols: usize, rows: usize) -> usize {
        self.cols = cols;
        self.rows = rows;
        let _ = self.vt.resize(cols as u16, rows as u16, 0, 0);
        let segments = self.projection.set_viewport(cols, rows);
        self.take(segments)
    }

    /// One frame: the burst arrives in three chunks, the frame paints once.
    fn frame(&mut self, frame: usize) -> usize {
        let bytes = burst(frame);
        let third = bytes.len() / 3;
        let mut segments = self.projection.feed(&bytes[..third], false);
        segments.extend(self.projection.feed(&bytes[third..2 * third], false));
        segments.extend(self.projection.feed(&bytes[2 * third..], false));
        segments.extend(self.projection.flush());
        self.take(segments)
    }
}

fn median(mut v: Vec<f64>) -> f64 {
    v.sort_by(f64::total_cmp);
    v[v.len() / 2]
}

struct Report {
    metric: &'static str,
    target: f64,
    small: Vec<f64>,
    god: Vec<f64>,
    note: String,
}

struct Verdict {
    small_ms: f64,
    god_ms: f64,
    ratio: f64,
    budget: f64,
    failing: Vec<&'static str>,
}

fn report(r: Report) -> Verdict {
    let small_ms = median(r.small.clone());
    let god_ms = median(r.god.clone());
    let budget = r.target * BUDGET_FACTOR;
    let ratio = god_ms / small_ms.max(RATIO_FLOOR_MS);
    let noise = NOISE_MS.max(r.target * NOISE_SHARE_OF_TARGET);
    let mut failing = Vec::new();
    if small_ms > budget {
        failing.push("small_budget");
    }
    if god_ms > budget {
        failing.push("god_budget");
    }
    if ratio > RATIO_LIMIT && god_ms - small_ms > noise {
        failing.push("ratio");
    }
    let runs = |v: &[f64]| v.iter().map(|x| format!("{x:.4}")).collect::<Vec<_>>().join(",");
    let failing_json = failing.iter().map(|f| format!("\"{f}\"")).collect::<Vec<_>>().join(",");
    let line = format!(
        "{{\"metric\":\"{}\",\"platform\":\"rust-{}\",\"small_ms\":{small_ms:.4},\"god_ms\":{god_ms:.4},\"ratio\":{ratio:.4},\"ratio_limit\":{RATIO_LIMIT},\"target_ms\":{},\"budget_ms\":{budget},\"small_runs\":[{}],\"god_runs\":[{}],\"known_red\":[],\"failing\":[{failing_json}],\"note\":\"{}\"}}",
        r.metric,
        std::env::consts::OS,
        r.target,
        runs(&r.small),
        runs(&r.god),
        r.note.replace('"', "'"),
    );
    println!("INSTANTPERF {line}");
    if let Ok(dir) = std::env::var("CMUX_INSTANT_PERF_OUT") {
        use std::io::Write;
        std::fs::create_dir_all(&dir).expect("CMUX_INSTANT_PERF_OUT");
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(std::path::Path::new(&dir).join("terminal-projection.jsonl"))
            .expect("report file");
        writeln!(file, "{line}").expect("report write");
    }
    Verdict { small_ms, god_ms, ratio, budget, failing }
}

fn check(label: &str, pass: bool, detail: String) {
    println!("INSTANTPERF check: {} {label}: {detail}", if pass { "PASS" } else { "FAIL" });
}

#[test]
fn projection_small_vs_god() {
    let build = Instant::now();
    let mut small = Phone::new(SMALL_ROWS);
    let mut god = Phone::new(GOD_ROWS);
    let build_ms = build.elapsed().as_secs_f64() * 1e3;

    // A frame of dirty rows, small and god in turn (one warm-up each).
    let mut frame_small = Vec::new();
    let mut frame_god = Vec::new();
    let mut frame_bytes = 0;
    for i in 0..=RUNS {
        let start = Instant::now();
        frame_bytes = small.frame(i);
        let s = start.elapsed().as_secs_f64() * 1e3;
        let start = Instant::now();
        let _ = god.frame(i);
        let g = start.elapsed().as_secs_f64() * 1e3;
        if i > 0 {
            frame_small.push(s);
            frame_god.push(g);
        }
    }
    let frame = report(Report {
        metric: "terminal_dirty_rows_frame",
        target: 4.0,
        small: frame_small,
        god: frame_god,
        note: format!(
            "120x40 host, 52x38 phone; a ~2 KB burst (8 rows, a spinner) fed in 3 chunks, painted once, into the phone's Ghostty VT; {frame_bytes} bytes painted per frame"
        ),
    });

    // A column change, 120 -> 52, to the first frame. Each run starts from
    // the phone at 120 columns (untimed) so every timed change is 120 -> 52.
    let mut col_small = Vec::new();
    let mut col_god = Vec::new();
    let mut col_bytes = (0, 0);
    for i in 0..=RUNS {
        small.resize(HOST.0, PHONE.1);
        god.resize(HOST.0, PHONE.1);
        let start = Instant::now();
        let bs = small.resize(PHONE.0, PHONE.1);
        let s = start.elapsed().as_secs_f64() * 1e3;
        let start = Instant::now();
        let bg = god.resize(PHONE.0, PHONE.1);
        let g = start.elapsed().as_secs_f64() * 1e3;
        col_bytes = (bs, bg);
        if i > 0 {
            col_small.push(s);
            col_god.push(g);
        }
    }
    let column = report(Report {
        metric: "terminal_column_change_first_frame",
        target: 16.0,
        small: col_small,
        god: col_god,
        note: format!(
            "the phone's terminal 120 -> 52 columns: the projection's window re-wrapped and the reset taken by a fresh Ghostty VT; first frame {} bytes small, {} bytes god; {} god rows older than the window; fixtures built in {build_ms:.0} ms",
            col_bytes.0,
            col_bytes.1,
            god.projection.older_rows()
        ),
    });

    let raw = |v: &Verdict| v.god_ms / v.small_ms;
    check(
        "a frame of dirty rows under 4 ms",
        frame.small_ms < 4.0 && frame.god_ms < 4.0,
        format!(
            "small {:.3} ms, god {:.3} ms (budget {} ms)",
            frame.small_ms, frame.god_ms, frame.budget
        ),
    );
    check(
        "a column change (120 -> 52) to the first frame under 16 ms",
        column.small_ms < 16.0 && column.god_ms < 16.0,
        format!(
            "small {:.3} ms, god {:.3} ms (budget {} ms)",
            column.small_ms, column.god_ms, column.budget
        ),
    );
    check(
        "god at most 1.2x small",
        frame.ratio <= RATIO_LIMIT && column.ratio <= RATIO_LIMIT,
        format!(
            "dirty frame {:.2}x, column change {:.2}x (god / max(small, 1 ms)); unfloored {:.2}x and {:.2}x",
            frame.ratio,
            column.ratio,
            raw(&frame),
            raw(&column)
        ),
    );

    if cfg!(debug_assertions) {
        println!("INSTANTPERF warning: a debug build; run with --release for numbers that assert");
        return;
    }
    let strict = std::env::var("CMUX_INSTANT_PERF_STRICT").is_ok_and(|v| v == "1");
    for (name, v) in
        [("terminal_dirty_rows_frame", &frame), ("terminal_column_change_first_frame", &column)]
    {
        if v.failing.contains(&"small_budget") && !strict {
            println!("INSTANTPERF warning: {name}: small over its budget (not strict)");
        }
        assert!(
            !v.failing.contains(&"god_budget"),
            "{name}: god {:.3} ms over {} ms",
            v.god_ms,
            v.budget
        );
        assert!(
            !v.failing.contains(&"ratio"),
            "{name}: god {:.3} ms is {:.2}x small {:.3} ms",
            v.god_ms,
            v.ratio,
            v.small_ms
        );
        assert!(
            !(strict && v.failing.contains(&"small_budget")),
            "{name}: small {:.3} ms over {} ms",
            v.small_ms,
            v.budget
        );
    }
}
