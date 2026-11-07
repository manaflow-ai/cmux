//! `cmux perf record`: a profile of the running cmux app on any build (dev,
//! nightly, release) in one Chrome trace event file that ui.perfetto.dev
//! opens, plus a summary (plans/cmux-next/trace.md, "Quick capture on any
//! build").
//!
//! It attaches to what already runs: no app launch, no Debug-only socket
//! method, no xctrace. For the window it records:
//! - every process of the app (the bundle's executables and the WebKit
//!   processes the app is responsible for; [`process`]) every interval: CPU %
//!   of one core, wakeups a second (context switches on Linux) and memory
//!   (phys_footprint; resident on Linux), as counter tracks per process;
//! - cmux's signposts from `log stream` (macOS; [`signposts`]): action,
//!   key and tab timings as slices on the thread that emitted them;
//! - the agent page ring the app always writes ([`pages`]): frame windows,
//!   long frames, loads and visibility changes.
//!
//! No stack samples: for those use scripts/cmux-next/trace.py or Instruments.
//!
//! Every source says in the summary whether it recorded and why not, so
//! nothing is dropped silently. One clock for everything: wall-clock
//! microseconds since the Unix epoch ([`clock`]).
//!
//! The window ends after [`Config::seconds`], or at SIGINT or SIGTERM, and
//! either way everything recorded is written. The only wait that is not on
//! an event is the sampling interval itself; every other wait has a deadline.

#![cfg(unix)]

pub mod clock;
pub mod pages;
pub mod process;
pub mod signposts;
mod stop;
pub mod summary;
pub mod trace;

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::summary::Source;
use crate::trace::Event;

pub const DEFAULT_SECONDS: u64 = 10;
pub const SECONDS: std::ops::RangeInclusive<u64> = 1..=600;
pub const DEFAULT_INTERVAL_MS: u64 = 250;
pub const INTERVAL_MS: std::ops::RangeInclusive<u64> = 50..=5000;

/// What to record.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Config {
    pub target: process::Target,
    /// The app's name for the summary (the bundle's file name).
    pub app: String,
    pub bundle_id: Option<String>,
    pub version: Option<String>,
    pub seconds: u64,
    pub interval: Duration,
    pub signposts: bool,
    /// The app's `diagnostics` folder (the agent page ring), when known.
    pub diagnostics: Option<PathBuf>,
}

/// A finished recording: the trace document and the summary.
pub struct Recording {
    pub trace: Value,
    pub summary: Value,
}

impl Recording {
    /// Writes `trace.json` and `summary.json` into `dir` (made if missing).
    pub fn write(&self, dir: &Path) -> std::io::Result<()> {
        std::fs::create_dir_all(dir)?;
        trace::write(&dir.join("trace.json"), &self.trace)?;
        let mut text = serde_json::to_string_pretty(&self.summary)?;
        text.push('\n');
        std::fs::write(dir.join("summary.json"), text)
    }
}

/// Records the window. `trace_path` is where the trace will be written (for the summary).
pub fn record(config: &Config, trace_path: &Path) -> Recording {
    let stop = stop::Stop::install();
    let mut sources = Vec::new();
    let stream = match (config.signposts, cfg!(target_os = "macos")) {
        (false, _) => {
            sources.push(Source::unavailable("signposts", "off (--no-signposts)"));
            None
        }
        (true, false) => {
            sources.push(Source::unavailable("signposts", "macOS only (log stream)"));
            None
        }
        (true, true) => match signposts::Stream::start() {
            Ok(stream) => Some(stream),
            Err(error) => {
                sources.push(Source::unavailable(
                    "signposts",
                    format!("log stream did not start: {error}"),
                ));
                None
            }
        },
    };
    let mut sampler = process::Sampler::new(config.target.clone());
    let started = Instant::now();
    let start_us = clock::now_us();
    let window = Duration::from_secs(config.seconds);
    let mut ticks = Vec::new();
    let mut interrupted = false;
    loop {
        let mono = u64::try_from(started.elapsed().as_nanos()).unwrap_or(u64::MAX);
        ticks.push(sampler.sample(clock::now_us(), mono));
        let left = window.saturating_sub(started.elapsed());
        if left.is_zero() {
            break;
        }
        if stop.wait(left.min(config.interval)) {
            interrupted = true;
            break;
        }
    }
    let end_us = clock::now_us();
    let mut events = Vec::new();
    let mut summary_signposts = json!(null);
    if let Some(stream) = stream {
        match stream.stop() {
            Ok(lines) => {
                let parsed = signposts::parse(lines.iter().map(String::as_str), start_us, end_us);
                let top = summary::top_intervals(&parsed.intervals, summary::TOP_INTERVALS);
                summary_signposts = json!({
                    "intervals": parsed.intervals.len(),
                    "instants": parsed.instants,
                    "unpaired_begin": parsed.unpaired_begin,
                    "unpaired_end": parsed.unpaired_end,
                    "lost": parsed.lost,
                    "top": top.iter().map(|interval| json!({
                        "name": interval.name,
                        "category": interval.category,
                        "pid": interval.pid,
                        "ms": trace::rounded(interval.ms),
                        "at": clock::iso_utc(interval.start_us),
                    })).collect::<Vec<_>>(),
                });
                let mut detail = format!(
                    "{} intervals, {} events, {} unpaired",
                    parsed.intervals.len(),
                    parsed.instants,
                    parsed.unpaired_begin + parsed.unpaired_end
                );
                if parsed.lost > 0 {
                    detail.push_str(&format!(", logd dropped {} batches", parsed.lost));
                }
                sources.push(Source::ok("signposts", detail));
                events.extend(parsed.events);
            }
            Err(reason) => sources.push(Source::unavailable("signposts", reason)),
        }
    }
    let app_pid = app_pid(&sampler, config);
    let pages_summary = read_pages(config, start_us, end_us, app_pid, &mut events, &mut sources);
    events.extend(counter_events(&ticks));
    for (pid, kind) in &sampler.seen {
        events.push(Event::name_of(i64::from(*pid), None, &format!("{kind} {pid}")));
    }
    let sampled = sampler.seen.len();
    sources.insert(
        0,
        match sampled {
            0 => Source::unavailable(
                "processes",
                format!("no process of {} ran during the window", config.target.root.display()),
            ),
            _ => Source::ok("processes", format!("{sampled} processes, {} samples", ticks.len())),
        },
    );
    match process::webkit_attribution() {
        Ok(()) => sources.insert(1, Source::ok("webkit", "WebKit processes attributed to the app")),
        Err(reason) => sources.insert(1, Source::unavailable("webkit", reason)),
    }
    let seconds = (end_us - start_us) as f64 / 1e6;
    let sources_json = summary::sources_json(&sources);
    let metadata = json!({
        "app": config.app,
        "bundle_id": config.bundle_id,
        "version": config.version,
        "host": host_name(),
        "os": os_name(),
        "start": clock::iso_utc(start_us),
        "seconds": trace::rounded(seconds),
        "interrupted": interrupted,
        "sources": sources_json,
    });
    let mut summary = metadata.clone();
    if let Value::Object(map) = &mut summary {
        map.insert("interval_ms".to_owned(), json!(config.interval.as_millis() as u64));
        map.insert("wakeups_name".to_owned(), json!(process::wakeups_name()));
        map.insert("memory_name".to_owned(), json!(process::memory_name()));
        map.insert("processes".to_owned(), json!(summary::kinds(&ticks)));
        map.insert("pages".to_owned(), pages_summary);
        map.insert("signposts".to_owned(), summary_signposts);
        map.insert("trace".to_owned(), json!(trace_path));
    }
    Recording { trace: trace::document(events, metadata), summary }
}

/// The app's pid: the target pid, else the sampled `app` process.
fn app_pid(sampler: &process::Sampler, config: &Config) -> i64 {
    config
        .target
        .pid
        .or_else(|| sampler.seen.iter().find(|(_, kind)| kind == "app").map(|(pid, _)| *pid))
        .map_or(0, i64::from)
}

/// Reads the page ring into `events`; returns the page rows of the summary.
fn read_pages(
    config: &Config,
    start_us: i64,
    end_us: i64,
    app_pid: i64,
    events: &mut Vec<Event>,
    sources: &mut Vec<Source>,
) -> Value {
    let Some(diagnostics) = &config.diagnostics else {
        let reason = if cfg!(target_os = "macos") {
            "the app's bundle id is unknown"
        } else {
            "macOS app only"
        };
        sources.push(Source::unavailable("pages", reason));
        return Value::Null;
    };
    let texts: Vec<String> = pages::files(diagnostics)
        .iter()
        .filter_map(|path| std::fs::read_to_string(path).ok())
        .collect();
    if texts.is_empty() {
        sources.push(Source::unavailable(
            "pages",
            format!(
                "no {} in {} (no agent page has drawn in this build)",
                pages::FILE_NAME,
                diagnostics.display()
            ),
        ));
        return Value::Null;
    }
    let parsed =
        pages::parse(texts.iter().flat_map(|text| text.lines()), start_us, end_us, app_pid);
    sources.push(Source::ok(
        "pages",
        format!(
            "{} lines, {} frame windows, {} long frames",
            parsed.lines,
            parsed.frames.len(),
            parsed.long_frames
        ),
    ));
    for (pid, tid, name) in &parsed.threads {
        events.push(Event::name_of(*pid, Some(*tid), name));
    }
    events.extend(parsed.events);
    json!(summary::pages(&parsed.frames, parsed.long_frames))
}

/// One counter event per process per sample and metric.
pub fn counter_events(ticks: &[process::Tick]) -> Vec<Event> {
    let (wakeups, memory) = (process::wakeups_name(), process::memory_name());
    let mut events = Vec::new();
    for tick in ticks {
        for row in &tick.rows {
            let pid = i64::from(row.pid);
            if let Some(cpu) = row.cpu_pct {
                events.push(Event::counter("cpu_pct", tick.at_us, pid, &[("cpu_pct", cpu)]));
            }
            if let Some(rate) = row.wakeups_per_s {
                events.push(Event::counter(wakeups, tick.at_us, pid, &[(wakeups, rate)]));
            }
            events.push(Event::counter(memory, tick.at_us, pid, &[(memory, row.memory_mb)]));
        }
    }
    events
}

fn host_name() -> String {
    let mut buffer = [0u8; 256];
    // SAFETY: `buffer` holds its length in bytes.
    let status = unsafe { libc::gethostname(buffer.as_mut_ptr().cast(), buffer.len()) };
    if status != 0 {
        return String::new();
    }
    let end = buffer.iter().position(|byte| *byte == 0).unwrap_or(buffer.len());
    String::from_utf8_lossy(&buffer[..end]).into_owned()
}

fn os_name() -> String {
    // SAFETY: an all-zero utsname is a valid out buffer.
    let mut name: libc::utsname = unsafe { std::mem::zeroed() };
    // SAFETY: `name` is a valid out pointer.
    if unsafe { libc::uname(&mut name) } != 0 {
        return std::env::consts::OS.to_owned();
    }
    let field = |chars: &[libc::c_char]| {
        // SAFETY: uname NUL-terminates each field within its array.
        unsafe { std::ffi::CStr::from_ptr(chars.as_ptr()) }.to_string_lossy().into_owned()
    };
    format!("{} {} {}", field(&name.sysname), field(&name.release), field(&name.machine))
}

#[cfg(test)]
mod tests;
