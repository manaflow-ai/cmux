//! How long each step of an owner's startup took (`startup-timings.jsonl`).
//!
//! A relaunch whose first answer took 10-17 s left no trace of where the
//! time went (2026-10-28). The owner times its startup as contiguous laps,
//! from the start of startup to the moment it can first answer, and appends
//! one JSON line per start to `startup-timings.jsonl` in its session
//! directory, keeping the latest [`KEPT_STARTS`] starts:
//!
//! ```json
//! {"pid":123,"at_ms":1793260000000,"total_ms":13210.4,
//!  "steps":[{"step":"socket.bind","ms":1.2},{"step":"registry.open","ms":2950.1}]}
//! ```
//!
//! Laps never overlap and are recorded in order, so their sum is at most the
//! total. Time a nested phase's own steps did not cover is named
//! `<phase>.other`.
//!
//! The clock starts at the process's first statement, not at the owner's
//! first step: the process marks its own steps before it knows it is an
//! owner ([`process_mark`], `process.*` laps). A first start after a bump
//! spent 1.5 s of a 1.5 s start before the owner's clock (2026-11-09).

use std::borrow::Cow;
use std::fs;
use std::io::Write;
use std::path::Path;
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// The file each owner start appends its timings to, in the session directory.
pub const STARTUP_TIMINGS_FILE: &str = "startup-timings.jsonl";
/// Starts the file keeps; older lines are dropped.
pub const KEPT_STARTS: usize = 20;

/// The process's steps before the owner's clock: each the step that ended at
/// its instant. The first is the process's start.
static PROCESS_MARKS: Mutex<Vec<(&'static str, Instant)>> = Mutex::new(Vec::new());

/// Marks the end of the process's `step` now (`process.start` first, at
/// the first statement of main). [`StartupTimings::from_process_start`]
/// turns the marks into laps.
pub fn process_mark(step: &'static str) {
    PROCESS_MARKS
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .push((step, Instant::now()));
}

/// The named, ordered laps of one startup.
#[derive(Debug, Clone)]
pub struct StartupTimings {
    started: Instant,
    mark: Instant,
    steps: Vec<Step>,
}

/// One lap: its name, how long it took and, for a lap over table rows, how
/// many rows it changed.
#[derive(Debug, Clone)]
struct Step {
    name: Cow<'static, str>,
    took: Duration,
    rows: Option<u64>,
}

impl Default for StartupTimings {
    fn default() -> Self {
        Self::start()
    }
}

impl StartupTimings {
    /// Starts the clock now.
    pub fn start() -> Self {
        let now = Instant::now();
        Self { started: now, mark: now, steps: Vec::new() }
    }

    /// Starts the clock at the process's first mark, with the time between
    /// marks as laps and the time since the last one as `rest`. Without
    /// marks, the clock starts now.
    pub fn from_process_start(rest: &'static str) -> Self {
        let marks = std::mem::take(
            &mut *PROCESS_MARKS.lock().unwrap_or_else(std::sync::PoisonError::into_inner),
        );
        let Some((_, started)) = marks.first().copied() else { return Self::start() };
        let mut timings = Self { started, mark: started, steps: Vec::new() };
        for (step, at) in marks.into_iter().skip(1) {
            let took = at.saturating_duration_since(timings.mark);
            timings.steps.push(Step { name: Cow::Borrowed(step), took, rows: None });
            timings.mark = at;
        }
        timings.lap(rest);
        timings
    }

    /// Records the time since the previous lap (or the start) as `step`.
    pub fn lap(&mut self, step: &'static str) {
        let now = Instant::now();
        let took = now.saturating_duration_since(self.mark);
        self.steps.push(Step { name: Cow::Borrowed(step), took, rows: None });
        self.mark = now;
    }

    /// Records a step timed by its caller, named at run time, with the rows
    /// it changed (a table's share of a migration). It does not move the
    /// lap mark: a phase collects these on its own clock and the caller
    /// [`absorb`](Self::absorb)s it, which names the rest of the phase.
    pub fn record_rows(&mut self, step: String, took: Duration, rows: u64) {
        self.steps.push(Step { name: Cow::Owned(step), took, rows: Some(rows) });
    }

    /// Takes `inner`'s laps, which ran since this clock's previous lap, and
    /// names the rest of that time `other` (the phase's untimed work).
    pub fn absorb(&mut self, inner: StartupTimings, other: &'static str) {
        let now = Instant::now();
        let span = now.saturating_duration_since(self.mark);
        let covered: Duration = inner.steps.iter().map(|step| step.took).sum();
        self.steps.extend(inner.steps);
        self.steps.push(Step {
            name: Cow::Borrowed(other),
            took: span.saturating_sub(covered),
            rows: None,
        });
        self.mark = now;
    }

    /// The laps so far, in order.
    pub fn steps(&self) -> Vec<(&str, Duration)> {
        self.steps.iter().map(|step| (step.name.as_ref(), step.took)).collect()
    }

    /// From the start of the clock to now.
    pub fn total(&self) -> Duration {
        self.started.elapsed()
    }

    /// One JSON line: the process, when, the total and each lap.
    pub fn to_line(&self, pid: u32, at_ms: u64) -> serde_json::Value {
        let ms = |took: Duration| (took.as_secs_f64() * 10_000.0).round() / 10.0;
        serde_json::json!({
            "pid": pid,
            "at_ms": at_ms,
            "total_ms": ms(self.total()),
            "steps": self
                .steps
                .iter()
                .map(|step| match step.rows {
                    Some(rows) => {
                        serde_json::json!({"step": step.name, "ms": ms(step.took), "rows": rows})
                    }
                    None => serde_json::json!({"step": step.name, "ms": ms(step.took)}),
                })
                .collect::<Vec<_>>(),
        })
    }

    /// A one-line summary for the log: the total and the slowest laps.
    pub fn summary(&self) -> String {
        format!(
            "startup {} ms to the first answer; slowest: {}",
            self.total().as_millis(),
            self.slowest(3)
        )
    }

    /// The `count` slowest laps, slowest first: `step N ms, ...`.
    pub fn slowest(&self, count: usize) -> String {
        let mut slowest = self.steps();
        slowest.sort_by_key(|(_, took)| std::cmp::Reverse(*took));
        slowest
            .iter()
            .take(count)
            .map(|(step, took)| format!("{step} {} ms", took.as_millis()))
            .collect::<Vec<_>>()
            .join(", ")
    }
}

/// Milliseconds since the Unix epoch now.
pub fn unix_now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|now| u64::try_from(now.as_millis()).unwrap_or(u64::MAX))
        .unwrap_or_default()
}

/// Appends `line` to the session's timings file, keeping the latest
/// [`KEPT_STARTS`] lines. Written to a temporary file and renamed, so a
/// reader never sees half a line.
pub fn append_startup_timings(session_dir: &Path, line: &serde_json::Value) -> std::io::Result<()> {
    let path = session_dir.join(STARTUP_TIMINGS_FILE);
    let previous = fs::read_to_string(&path).unwrap_or_default();
    let mut lines: Vec<&str> = previous.lines().filter(|line| !line.trim().is_empty()).collect();
    let new_line = line.to_string();
    lines.push(&new_line);
    let keep = lines.get(lines.len().saturating_sub(KEPT_STARTS)..).unwrap_or_default();
    let staged = session_dir.join(format!(".{STARTUP_TIMINGS_FILE}.{}", std::process::id()));
    {
        let mut file = fs::File::create(&staged)?;
        for line in keep {
            file.write_all(line.as_bytes())?;
            file.write_all(b"\n")?;
        }
    }
    fs::rename(&staged, &path).inspect_err(|_| {
        let _ = fs::remove_file(&staged);
    })
}

/// Puts `laps` on the line of the start `pid` at `at_ms` as the list `after_ready`: the laps
/// of work that ended after that start could first answer. The line's other fields do not
/// change. `false` when the file has no such line (it left the latest [`KEPT_STARTS`]). The
/// caller serializes this with [`append_startup_timings`] for its own process.
pub fn add_after_ready(
    session_dir: &Path,
    pid: u32,
    at_ms: u64,
    laps: &serde_json::Value,
) -> std::io::Result<bool> {
    let path = session_dir.join(STARTUP_TIMINGS_FILE);
    let previous = fs::read_to_string(&path).unwrap_or_default();
    let mut found = false;
    let lines = previous
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| {
            let Ok(mut value) = serde_json::from_str::<serde_json::Value>(line) else {
                return line.to_string();
            };
            let number = |key: &str| value.get(key).and_then(serde_json::Value::as_u64);
            if found || number("pid") != Some(u64::from(pid)) || number("at_ms") != Some(at_ms) {
                return line.to_string();
            }
            let Some(fields) = value.as_object_mut() else {
                return line.to_string();
            };
            found = true;
            fields.insert("after_ready".into(), laps.clone());
            value.to_string()
        })
        .collect::<Vec<_>>();
    if !found {
        return Ok(false);
    }
    let staged = session_dir.join(format!(".{STARTUP_TIMINGS_FILE}.{}", std::process::id()));
    {
        let mut file = fs::File::create(&staged)?;
        for line in &lines {
            file.write_all(line.as_bytes())?;
            file.write_all(b"\n")?;
        }
    }
    fs::rename(&staged, &path).inspect_err(|_| {
        let _ = fs::remove_file(&staged);
    })?;
    Ok(true)
}

#[cfg(test)]
mod tests;
