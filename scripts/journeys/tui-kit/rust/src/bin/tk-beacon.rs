//! tk-beacon: the SWITCH FRAMES beacon (ext_switch.py `beacon`), compiled, on CLOCK_UPTIME_RAW.
//!
//!   tk-beacon --ws N [--pane M] [--hz 240] [--cell-cols 2] [--fill] [--label TEXT]
//!             [--pace spin|hybrid|sleep] [--duration S] [--log FILE] [--summary]
//!
//! Each frame is one DEC 2026 synchronized update with the three beacon rows (beacon.rs) and the label row
//! "WS n  PANE m  frame k". The log has a `start`, a `size` per resize, and an `end` with achieved_hz,
//! target_hz and verdict ("NOT RUN" below 95 %, cmux-ad 03:40Z). --log off writes no per-frame lines.

use std::io::Write;
use std::process::ExitCode;

use tuikit_load::args::Args;
use tuikit_load::beacon;
use tuikit_load::jsonl::{Log, Value};
use tuikit_load::pace::{Mode, Pacer};
use tuikit_load::sys;

const FLAGS: &[&str] = &["fill", "summary"];
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
];

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
    let mut pacer = Pacer::new(hz, mode, spin_ms, t0);
    let mut clock = sys::monotonic;
    let realtime = mode == Mode::Rt && sys::realtime_thread(1.0 / hz);
    let sleep_fn: fn(f64) = if mode == Mode::Rt {
        sys::precise_sleep
    } else {
        sys::plain_sleep
    };
    let mut sleep = |s: f64| sleep_fn(s);
    let mut size = sys::term_size().unwrap_or((80, 24));
    let mut clear = true;
    let mut k: u64 = 0;
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
        let _late = pacer.wait(k, &mut clock, &mut sleep);
        let now = sys::monotonic();
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
        if first.is_none() {
            first = Some(now);
        }
        last = now;
        k += 1;
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
