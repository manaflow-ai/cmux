//! tk-gradient: tuikit.py's 120 fps gradient, compiled. tuikit.py `gradient` runs it (with the seeded
//! style on the command line) when it is built; the frames are byte for byte the Python engine's.
//!
//!   tk-gradient --seed N --hue F --sat F --val F --speed N --diag N --word W --cjk 8CHARS --emoji 8CHARS
//!               [--fps 120] [--cell 1|2] [--no-sync] [--size CxR] [--frames N] [--duration S]
//!               [--fake-clock] [--pace spin|hybrid|sleep] [--spin-ms 1] [--log FILE] [--summary]
//!
//! The log's `end` event has `achieved_fps` (frames over the time from the first frame to the last),
//! `target_fps` and `verdict`: "ok", "NOT RUN" (below 95 % of the target, cmux-ad 03:40Z) or "n/a"
//! (--fake-clock, or under 2 frames). --summary prints the same line on stderr at the end.

use std::io::Write;
use std::process::ExitCode;

use tuikit_load::args::Args;
use tuikit_load::gradient::{self, Gradient, Style};
use tuikit_load::jsonl::{Log, Value};
use tuikit_load::pace::{Mode, Pacer};
use tuikit_load::sys;

const FLAGS: &[&str] = &["no-sync", "fake-clock", "summary"];
const KNOWN: &[&str] = &[
    "seed",
    "hue",
    "sat",
    "val",
    "speed",
    "diag",
    "word",
    "cjk",
    "emoji",
    "fps",
    "cell",
    "size",
    "frames",
    "duration",
    "pace",
    "spin-ms",
    "log",
    "no-sync",
    "fake-clock",
    "summary",
];

struct Opts {
    style: Style,
    fps: f64,
    cell: usize,
    sync: bool,
    size: Option<(usize, usize)>,
    frames: u64,
    duration: f64,
    fake_clock: bool,
    mode: Mode,
    spin_ms: f64,
    log: Option<String>,
    summary: bool,
}

fn need<'a>(a: &'a Args, name: &str) -> Result<&'a str, String> {
    a.text(name).ok_or_else(|| format!("--{name} is required"))
}

fn opts(argv: &[String]) -> Result<Opts, String> {
    let a = Args::parse(argv, FLAGS)?;
    if let Some(unknown) = a.names().find(|n| !KNOWN.contains(n)) {
        return Err(format!("unknown option --{unknown}"));
    }
    let style = Style {
        seed: a.num("seed", 1_i64)?,
        hue: need(&a, "hue")?
            .parse()
            .map_err(|_| "--hue: not a number".to_string())?,
        sat: need(&a, "sat")?
            .parse()
            .map_err(|_| "--sat: not a number".to_string())?,
        val: need(&a, "val")?
            .parse()
            .map_err(|_| "--val: not a number".to_string())?,
        speed: a.num("speed", 1_u64)?,
        diag: a.num("diag", 1_u64)?,
        word: need(&a, "word")?.to_string(),
        cjk: need(&a, "cjk")?.chars().collect(),
        emoji: need(&a, "emoji")?.chars().collect(),
    };
    if style.cjk.len() != 8 || style.emoji.len() != 8 {
        return Err("--cjk and --emoji are 8 characters each".into());
    }
    let fps: f64 = a.num("fps", 120.0)?;
    if fps.is_nan() || fps <= 0.0 {
        return Err("--fps must be above 0".into());
    }
    let cell: usize = a.num("cell", 1)?;
    if cell != 1 && cell != 2 {
        return Err("--cell is 1 or 2".into());
    }
    let mode = Mode::parse(a.text("pace").unwrap_or("spin"))
        .ok_or_else(|| "--pace is spin, hybrid or sleep".to_string())?;
    Ok(Opts {
        style,
        fps,
        cell,
        sync: !a.flag("no-sync"),
        size: a.size()?,
        frames: a.num("frames", 0)?,
        duration: a.num("duration", 30.0)?,
        fake_clock: a.flag("fake-clock"),
        mode,
        spin_ms: a.num("spin-ms", 1.0)?,
        log: a.text("log").map(str::to_string),
        summary: a.flag("summary"),
    })
}

/// Writes the whole frame. A non-blocking stdout that is full (WouldBlock) waits until it can write
/// again, as tuikit.py's Out does with select; any other error ends the program.
fn write_frame(out: &mut impl Write, mut bytes: &[u8]) -> std::io::Result<()> {
    while !bytes.is_empty() {
        match out.write(bytes) {
            Ok(0) => return Err(std::io::ErrorKind::WriteZero.into()),
            Ok(n) => bytes = bytes.get(n..).unwrap_or_default(),
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => sys::wait_writable(1),
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(e) => return Err(e),
        }
    }
    loop {
        match out.flush() {
            Ok(()) => return Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => sys::wait_writable(1),
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(e) => return Err(e),
        }
    }
}

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let o = match opts(&argv) {
        Ok(o) => o,
        Err(e) => {
            eprintln!("tk-gradient: {e}");
            return ExitCode::from(2);
        }
    };
    let mut log = match Log::open(o.log.as_deref()) {
        Ok(log) => log,
        Err(e) => {
            eprintln!("tk-gradient: {e}");
            return ExitCode::from(2);
        }
    };
    sys::install_signals(o.size.is_none());
    let stdout = std::io::stdout();
    let mut out = stdout.lock();
    let seed = o.style.seed;
    let mut g = Gradient::new(o.style.clone(), o.cell, o.sync);
    let t0 = sys::monotonic();
    let mut pacer = Pacer::new(o.fps, o.mode, o.spin_ms, t0);
    let mut clock = sys::monotonic;
    let mut sleep = |s: f64| std::thread::sleep(std::time::Duration::from_secs_f64(s.max(0.0)));
    let mut k: u64 = 0;
    let mut first: Option<f64> = None;
    let mut last = 0.0_f64;
    let mut late_frames: u64 = 0;
    let period = 1.0 / o.fps;
    let mut winch = true;
    let _ = out.write_all(
        format!(
            "{}{}{}\x1b[2J",
            gradient::ALT_ON,
            gradient::HIDE,
            gradient::WRAP_OFF
        )
        .as_bytes(),
    );
    log.event(
        "start",
        vec![
            ("program", Value::Str("tk-gradient".into())),
            ("seed", Value::Int(seed)),
            ("fps", Value::Num(o.fps, 3)),
            ("pace", Value::Str(format!("{:?}", o.mode).to_lowercase())),
            ("spin_ms", Value::Num(o.spin_ms, 3)),
            ("engine", Value::Str("rust".into())),
            ("darwin_bg", Value::Str(sys::darwin_bg().into())),
            ("pid", Value::Int(i64::from(std::process::id()))),
        ],
    );
    loop {
        if sys::quit_requested() || (o.frames > 0 && k >= o.frames) {
            break;
        }
        if o.duration > 0.0 && sys::monotonic() - t0 >= o.duration {
            break;
        }
        if winch || sys::take_winch() {
            winch = false;
            let (cols, rows) = o.size.or_else(sys::term_size).unwrap_or((80, 24));
            if (cols, rows) != g.size() {
                g.resize(cols, rows);
                log.event(
                    "size",
                    vec![
                        ("cols", Value::Int(cols as i64)),
                        ("rows", Value::Int(rows as i64)),
                        ("frame", Value::Int(k as i64)),
                    ],
                );
            }
        }
        let late = pacer.wait(k, &mut clock, &mut sleep);
        let drawn = sys::monotonic();
        let drawn_wall = sys::wall();
        let t = if o.fake_clock {
            k as f64 / o.fps
        } else {
            drawn - t0
        };
        let text = g.frame(k, t);
        if write_frame(&mut out, text.as_bytes()).is_err() {
            break; // the reader went away (EPIPE): end quietly
        }
        if late > period {
            late_frames += 1;
        }
        if first.is_none() {
            first = Some(drawn);
        }
        last = drawn;
        log.event(
            "frame",
            vec![
                ("frame", Value::Int(k as i64)),
                ("late_ms", Value::Num(late * 1000.0, 3)),
                ("before_ms", Value::Num(pacer.before * 1000.0, 3)),
                ("bytes", Value::Int(text.len() as i64)),
                (
                    "draw_ms",
                    Value::Num((sys::monotonic() - drawn) * 1000.0, 3),
                ),
                ("mono", Value::Num(drawn, 6)),
                ("wall", Value::Num(drawn_wall, 6)),
            ],
        );
        k += 1;
    }
    let _ = out.write_all(
        format!(
            "{}{}{}{}{}",
            gradient::ESU,
            gradient::RESET,
            gradient::WRAP_ON,
            gradient::SHOW,
            gradient::ALT_OFF
        )
        .as_bytes(),
    );
    let _ = out.flush();
    let span = first.map_or(0.0, |f| last - f);
    let achieved = if k > 1 && span > 0.0 {
        (k - 1) as f64 / span
    } else {
        0.0
    };
    let verdict = if o.fake_clock || k < 2 {
        "n/a"
    } else if achieved < 0.95 * o.fps {
        "NOT RUN"
    } else {
        "ok"
    };
    log.event(
        "end",
        vec![
            ("frames", Value::Int(k as i64)),
            ("achieved_fps", Value::Num(achieved, 3)),
            ("target_fps", Value::Num(o.fps, 3)),
            ("late_over_one_frame", Value::Int(late_frames as i64)),
            ("verdict", Value::Str(verdict.into())),
            ("engine", Value::Str("rust".into())),
            ("darwin_bg", Value::Str(sys::darwin_bg().into())),
        ],
    );
    log.flush();
    if o.summary {
        eprintln!(
            "TK-GRADIENT frames={k} achieved_fps={achieved:.2} target_fps={:.2} late_over_one_frame={late_frames} verdict={verdict}",
            o.fps
        );
    }
    ExitCode::SUCCESS
}
