//! tk-beacon: the SWITCH FRAMES beacon (ext_switch.py `beacon`), compiled, on CLOCK_UPTIME_RAW.
//!
//!   tk-beacon --ws N [--pane M] [--hz 240] [--cell-cols 2] [--fill] [--label TEXT] [--log-frames]
//!             [--pace rt|spin|hybrid|sleep] [--duration S] [--log FILE] [--summary]
//!
//! Each frame is one DEC 2026 synchronized update with the three beacon rows (beacon.rs) and the label row
//! "WS n  PANE m  frame k". It never draws catch-up frames: each frame takes the slot nearest the current
//! time, so a wake late by half a refresh or more skips slots and logs a `gap` event (frames missed, gap ms). The log has a `start`, a `size` per resize,
//! `frame` lines with --log-frames, and an `end` with frames, missed_frames, stalls, longest_gap_ms,
//! achieved_hz, target_hz and verdict ("NOT RUN" below 95 %, cmux-ad 03:40Z).

use std::io::Write;
use std::process::ExitCode;

use tuikit_load::args::Args;
use tuikit_load::beacon;
use tuikit_load::jsonl::{Log, Value};
use tuikit_load::pace::Mode;
use tuikit_load::sys;

const FLAGS: &[&str] = &["fill", "summary", "log-frames"];
const KNOWN: &[&str] = &[
    "ws",
    "pane",
    "hz",
    "cell-cols",
    "fill",
    "label",
    "pace",
    "spin-ms",
    "duration",
    "log",
    "summary",
    "log-frames",
    "inject-stall-ms",
    "inject-stall-at",
];

/// Waits until `due` (monotonic seconds): spin polls; rt and sleep sleep (rt on mach_wait_until in a
/// time-constraint thread); hybrid sleeps to `spin` before and polls the rest.
fn wait_until(due: f64, mode: Mode, spin: f64) {
    let left = due - sys::monotonic();
    if left <= 0.0 {
        return;
    }
    match mode {
        Mode::Rt if cfg!(target_os = "macos") => sys::precise_sleep(left),
        Mode::Sleep => sys::plain_sleep(left),
        Mode::Rt | Mode::Hybrid | Mode::Spin => {
            // rt off macOS spins, as pace.rs says
            if mode == Mode::Hybrid && left > spin {
                sys::plain_sleep(left - spin);
            }
            while sys::monotonic() < due {
                std::hint::spin_loop();
            }
        }
    }
}

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let a = match Args::parse(&argv, FLAGS) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("tk-beacon: {e}");
            return ExitCode::from(2);
        }
    };
    if let Some(unknown) = a.names().find(|n| !KNOWN.contains(n)) {
        eprintln!("tk-beacon: unknown option --{unknown}");
        return ExitCode::from(2);
    }
    let parsed = (|| -> Result<(u64, u64, f64, usize, f64, f64, Mode), String> {
        let ws: u64 = a.num("ws", u64::MAX)?;
        if ws == u64::MAX {
            return Err("--ws is required".into());
        }
        let hz: f64 = a.num("hz", 240.0)?;
        if hz.is_nan() || hz <= 0.0 {
            return Err("--hz must be above 0".into());
        }
        let duration: f64 = a.num("duration", 0.0)?;
        if duration.is_nan() || duration < 0.0 {
            return Err("--duration must be 0 or more".into());
        }
        let mode = Mode::parse(a.text("pace").unwrap_or("rt"))
            .ok_or_else(|| "--pace is spin, rt, hybrid or sleep".to_string())?;
        Ok((
            ws,
            a.num("pane", 0)?,
            hz,
            a.num("cell-cols", 2)?,
            duration,
            a.num("spin-ms", 1.0)?,
            mode,
        ))
    })();
    let (ws, pane, hz, cell_cols, duration, spin_ms, mode) = match parsed {
        Ok(p) => p,
        Err(e) => {
            eprintln!("tk-beacon: {e}");
            return ExitCode::from(2);
        }
    };
    let label = a
        .text("label")
        .map_or_else(|| format!("WS {ws}  PANE {pane}"), str::to_string);
    let fill = a.flag("fill");
    let mut log = match Log::open(a.text("log")) {
        Ok(log) => log,
        Err(e) => {
            eprintln!("tk-beacon: {e}");
            return ExitCode::from(2);
        }
    };
    sys::install_signals(true);
    let stdout = std::io::stdout();
    let mut out = stdout.lock();
    let _ = out.write_all(b"\x1b[?1049h\x1b[?25l");
    let t0 = sys::monotonic();
    let period = 1.0 / hz;
    // The beacon never draws catch-up frames (lead 07:4xZ): frame n is due at t0 + n * period; after a late
    // wake it draws the frame of the current time and counts the frames it skipped, so a stall of one
    // refresh shows in the log and on film instead of being filled by a burst. The shared Pacer (which the
    // gradient keeps: its frame index is the analyzer's clock) is not used here.
    let realtime = mode == Mode::Rt && sys::realtime_thread(period);
    let spin = spin_ms / 1000.0;
    let log_frames = a.flag("log-frames");
    let stall = (|| -> Result<(f64, u64), String> {
        let ms: f64 = a.num("inject-stall-ms", 0.0)?;
        let at: u64 = a.num("inject-stall-at", 100)?;
        if !ms.is_finite() || !(0.0..=10_000.0).contains(&ms) || at == 0 {
            return Err("--inject-stall-ms is 0..10000 and --inject-stall-at at least 1".into());
        }
        Ok((ms, at))
    })();
    let (stall_ms, stall_at) = match stall {
        Ok(v) => v,
        Err(e) => {
            eprintln!("tk-beacon: {e}");
            return ExitCode::from(2);
        }
    };
    let mut size = sys::term_size().unwrap_or((80, 24));
    let mut clear = true;
    let mut k: u64 = 0; // frames drawn
    let mut slot: u64 = 0; // the schedule slot of the next frame
    let mut missed: u64 = 0;
    let mut stalls: u64 = 0;
    let mut longest_gap = 0.0_f64;
    let mut first: Option<f64> = None;
    let mut last = 0.0_f64;
    log.event(
        "start",
        vec![
            ("program", Value::Str("tk-beacon".into())),
            ("ws", Value::Int(ws as i64)),
            ("pane", Value::Int(pane as i64)),
            ("hz", Value::Num(hz, 3)),
            ("pace", Value::Str(format!("{mode:?}").to_lowercase())),
            ("catch_up", Value::Bool(false)),
            ("clock", Value::Str("uptime_raw_2ms_18bit".into())),
            ("darwin_bg", Value::Str(sys::darwin_bg().into())),
            ("realtime", Value::Bool(realtime)),
            ("pid", Value::Int(i64::from(std::process::id()))),
        ],
    );
    loop {
        if sys::quit_requested() || (duration > 0.0 && sys::monotonic() - t0 >= duration) {
            break;
        }
        if sys::take_winch() {
            size = sys::term_size().unwrap_or(size);
            clear = true;
            log.event(
                "size",
                vec![
                    ("cols", Value::Int(size.0 as i64)),
                    ("rows", Value::Int(size.1 as i64)),
                    ("frame", Value::Int(k as i64)),
                ],
            );
        }
        let due = t0 + slot as f64 * period;
        wait_until(due, mode, spin);
        let now = sys::monotonic();
        // The frame takes the NEAREST slot (round, not floor), so the next frame is always at least half a refresh
        // later: a wake late by half a refresh or more skips its slot (missed) instead of drawing two frames 2-4 ms
        // apart, one of which never reaches the screen (review of ed7ecd5d53a1).
        let behind = ((now - t0) / period + 0.5).floor() as u64;
        if behind > slot {
            let skipped = behind - slot;
            missed += skipped;
            stalls += 1;
            log.event(
                "gap",
                vec![
                    ("frame", Value::Int(k as i64)),
                    ("missed", Value::Int(skipped as i64)),
                    ("gap_ms", Value::Num((now - last.max(t0)) * 1000.0, 3)),
                    ("mono", Value::Num(now, 6)),
                ],
            );
            slot = behind;
        }
        if first.is_some() {
            longest_gap = longest_gap.max(now - last);
        }
        let units = beacon::clock_units((now * 1e9) as u64);
        let text = beacon::frame(
            ws,
            pane,
            units,
            cell_cols,
            &label,
            k,
            clear,
            if fill { Some(size) } else { None },
        );
        clear = false;
        if out
            .write_all(text.as_bytes())
            .and_then(|()| out.flush())
            .is_err()
        {
            break;
        }
        if log_frames {
            log.event(
                "frame",
                vec![
                    ("frame", Value::Int(k as i64)),
                    ("mono", Value::Num(now, 6)),
                ],
            );
        }
        if first.is_none() {
            first = Some(now);
        }
        last = now;
        k += 1;
        slot += 1;
        if stall_ms > 0.0 && k == stall_at {
            // tests: a stall the program itself cannot prevent (as a busy host or a blocked pty write)
            std::thread::sleep(std::time::Duration::from_secs_f64(stall_ms / 1000.0));
        }
    }
    let _ = out.write_all(b"\x1b[0m\x1b[?25h\x1b[?1049l");
    let _ = out.flush();
    let span = first.map_or(0.0, |f| last - f);
    let achieved = if k > 1 && span > 0.0 {
        (k - 1) as f64 / span
    } else {
        0.0
    };
    let verdict = if k < 2 {
        "n/a"
    } else if achieved < 0.95 * hz {
        "NOT RUN"
    } else {
        "ok"
    };
    log.event(
        "end",
        vec![
            ("frames", Value::Int(k as i64)),
            ("missed_frames", Value::Int(missed as i64)),
            ("stalls", Value::Int(stalls as i64)),
            ("longest_gap_ms", Value::Num(longest_gap * 1000.0, 3)),
            ("achieved_hz", Value::Num(achieved, 3)),
            ("target_hz", Value::Num(hz, 3)),
            ("verdict", Value::Str(verdict.into())),
            ("engine", Value::Str("rust".into())),
            ("darwin_bg", Value::Str(sys::darwin_bg().into())),
        ],
    );
    log.flush();
    if a.flag("summary") {
        eprintln!(
            "TK-BEACON frames={k} achieved_hz={achieved:.2} target_hz={hz:.2} verdict={verdict}"
        );
    }
    ExitCode::SUCCESS
}
