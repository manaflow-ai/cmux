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

use std::fs;
use std::io::Write;
use std::path::Path;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// The file each owner start appends its timings to, in the session directory.
pub const STARTUP_TIMINGS_FILE: &str = "startup-timings.jsonl";
/// Starts the file keeps; older lines are dropped.
pub const KEPT_STARTS: usize = 20;

/// The named, ordered laps of one startup.
#[derive(Debug, Clone)]
pub struct StartupTimings {
    started: Instant,
    mark: Instant,
    steps: Vec<(&'static str, Duration)>,
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

    /// Records the time since the previous lap (or the start) as `step`.
    pub fn lap(&mut self, step: &'static str) {
        let now = Instant::now();
        self.steps.push((step, now.saturating_duration_since(self.mark)));
        self.mark = now;
    }

    /// Takes `inner`'s laps, which ran since this clock's previous lap, and
    /// names the rest of that time `other` (the phase's untimed work).
    pub fn absorb(&mut self, inner: StartupTimings, other: &'static str) {
        let now = Instant::now();
        let span = now.saturating_duration_since(self.mark);
        let covered: Duration = inner.steps.iter().map(|(_, took)| *took).sum();
        self.steps.extend(inner.steps);
        self.steps.push((other, span.saturating_sub(covered)));
        self.mark = now;
    }

    /// The laps so far, in order.
    pub fn steps(&self) -> &[(&'static str, Duration)] {
        &self.steps
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
                .map(|(step, took)| serde_json::json!({"step": step, "ms": ms(*took)}))
                .collect::<Vec<_>>(),
        })
    }

    /// A one-line summary for the log: the total and the slowest laps.
    pub fn summary(&self) -> String {
        let mut slowest = self.steps.clone();
        slowest.sort_by_key(|(_, took)| std::cmp::Reverse(*took));
        let top = slowest
            .iter()
            .take(3)
            .map(|(step, took)| format!("{step} {} ms", took.as_millis()))
            .collect::<Vec<_>>()
            .join(", ");
        format!("startup {} ms to the first answer; slowest: {top}", self.total().as_millis())
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn absorbed_laps_keep_their_order_and_name_the_untimed_rest() {
        let mut outer = StartupTimings::start();
        outer.lap("socket.bind");
        let mut inner = StartupTimings::start();
        inner.lap("registry.open");
        std::thread::sleep(Duration::from_millis(5));
        outer.absorb(inner, "open.other");
        outer.lap("server.attach");
        let names: Vec<_> = outer.steps().iter().map(|(step, _)| *step).collect();
        assert_eq!(names, ["socket.bind", "registry.open", "open.other", "server.attach"]);
        let sum: Duration = outer.steps().iter().map(|(_, took)| *took).sum();
        assert!(sum <= outer.total());
        assert!(outer.steps()[2].1 >= Duration::from_millis(5));
    }

    #[test]
    fn the_file_keeps_only_the_latest_starts() {
        let dir = std::env::temp_dir().join(format!(
            "cmux-startup-timings-{}-{}",
            std::process::id(),
            unix_now_ms()
        ));
        fs::create_dir_all(&dir).unwrap();
        for pid in 0..(KEPT_STARTS as u32 + 3) {
            append_startup_timings(&dir, &StartupTimings::start().to_line(pid, 1)).unwrap();
        }
        let text = fs::read_to_string(dir.join(STARTUP_TIMINGS_FILE)).unwrap();
        let _ = fs::remove_dir_all(&dir);
        let pids: Vec<u64> = text
            .lines()
            .map(|line| {
                serde_json::from_str::<serde_json::Value>(line).unwrap()["pid"].as_u64().unwrap()
            })
            .collect();
        assert_eq!(pids.len(), KEPT_STARTS);
        assert_eq!(pids.first(), Some(&3));
        assert_eq!(pids.last(), Some(&(KEPT_STARTS as u64 + 2)));
    }
}
