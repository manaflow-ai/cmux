//! Where a hang goes: a hang file under `<state root>/hangs/` (the newest 20 kept), a JSON line in
//! `<state root>/client-hangs.jsonl` (sent to Sentry by `crash_forward`, each line once), and a
//! client-log warning.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::json;

use super::Config;

/// Hang files kept in `hangs/`.
const KEEP_HANG_FILES: usize = 20;
const AREA: &str = "hangs";

/// One hang of the UI thread, as seen while it runs.
#[derive(Clone, Debug, Default)]
pub(crate) struct HangReport {
    pub(crate) session: String,
    /// How long the turn had run when this was taken.
    pub(crate) duration: Duration,
    /// The UI thread's stack, innermost first (raw addresses; empty when no sample).
    pub(crate) stack: Vec<usize>,
    /// Known waits in flight.
    pub(crate) waits: Vec<String>,
    /// Known waits the watchdog cancelled in this turn.
    pub(crate) cancelled: Vec<String>,
}

impl HangReport {
    /// The stack, one named line per frame.
    pub(crate) fn frames(&self) -> Vec<String> {
        #[cfg(unix)]
        {
            super::sampler::describe(&self.stack)
        }
        #[cfg(not(unix))]
        {
            Vec::new()
        }
    }
}

/// `<state root>`: the parent of the sessions directory.
pub(super) fn state_root() -> Option<PathBuf> {
    let sessions = cmux_tui_core::platform::workspace_state_dir()?;
    Some(sessions.parent().map(PathBuf::from).unwrap_or(sessions))
}

/// The JSON-lines log of client hangs in `dir`.
pub(crate) fn hang_log(dir: &Path) -> PathBuf {
    dir.join("client-hangs.jsonl")
}

pub(super) fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX))
        .unwrap_or_default()
}

/// The first frame that is cmux's own code, else the first frame: what groups one hang's reports.
fn top_frame(frames: &[String]) -> String {
    let name = |line: &String| line.splitn(3, ' ').nth(2).map(str::to_string);
    frames
        .iter()
        .filter_map(name)
        .find(|name| name.contains("cmux"))
        .or_else(|| frames.first().and_then(name))
        .unwrap_or_else(|| "unknown".into())
}

/// The record's JSON line (`kind: "client-hang"`, as `crash_forward::event_for` reads it).
pub(super) fn json_line(report: &HangReport, frames: &[String], at_ms: u64) -> String {
    let seconds = report.duration.as_secs_f64();
    let top = top_frame(frames);
    json!({
        "kind": "client-hang",
        "at_ms": at_ms,
        "message": format!("cmux-tui UI loop stalled {seconds:.1}s in {top}"),
        "location": top,
        "duration_ms": u64::try_from(report.duration.as_millis()).unwrap_or(u64::MAX),
        "backtrace": frames.join("\n"),
        "waits": report.waits,
        "cancelled": report.cancelled,
        "thread": "ui",
        "version": crate::version_report::DISTRIBUTION_VERSION,
        "os": std::env::consts::OS,
        "arch": std::env::consts::ARCH,
    })
    .to_string()
}

fn hang_text(report: &HangReport, frames: &[String], at_ms: u64) -> String {
    let mut text = format!(
        "cmux-tui UI loop hang\nat_ms: {at_ms}\npid: {}\nsession: {}\nstalled: {:.2}s\nversion: {}\n",
        std::process::id(),
        report.session,
        report.duration.as_secs_f64(),
        crate::version_report::DISTRIBUTION_VERSION,
    );
    for (title, lines) in
        [("waits in flight", &report.waits), ("waits cancelled", &report.cancelled)]
    {
        if !lines.is_empty() {
            text.push_str(&format!("{title}:\n"));
            for line in lines {
                text.push_str(&format!("  {line}\n"));
            }
        }
    }
    text.push_str("ui thread stack:\n");
    if frames.is_empty() {
        text.push_str("  (no sample)\n");
    }
    for frame in frames {
        text.push_str(&format!("  {frame}\n"));
    }
    text
}

fn private_file(path: &Path, append: bool) -> std::io::Result<std::fs::File> {
    let mut options = std::fs::OpenOptions::new();
    options.create(true);
    if append {
        options.append(true);
    } else {
        options.write(true).truncate(true);
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    options.open(path)
}

fn prune(hangs: &Path) {
    let Ok(entries) = std::fs::read_dir(hangs) else { return };
    let mut files: Vec<PathBuf> = entries
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with("hang-") && name.ends_with(".txt"))
        })
        .collect();
    if files.len() <= KEEP_HANG_FILES {
        return;
    }
    // Names start with the time in milliseconds, zero-padded: oldest sort first.
    files.sort();
    for path in &files[..files.len() - KEEP_HANG_FILES] {
        let _ = std::fs::remove_file(path);
    }
}

/// Writes the hang everywhere it goes; returns the JSON-lines log it appended to.
pub(super) fn write(config: &Config, report: &HangReport) -> Option<PathBuf> {
    let frames = report.frames();
    let at_ms = now_ms();
    crate::client_log::warn(
        AREA,
        &format!(
            "ui loop stalled {:.1}s; top frame {}; waits {:?}; cancelled {:?}",
            report.duration.as_secs_f64(),
            top_frame(&frames),
            report.waits,
            report.cancelled
        ),
    );
    let dir = config.dir.as_ref()?;
    let hangs = dir.join("hangs");
    if std::fs::create_dir_all(&hangs).is_ok() {
        let path = hangs.join(format!("hang-{at_ms:016}-{}.txt", std::process::id()));
        if let Ok(mut file) = private_file(&path, false) {
            let _ = file.write_all(hang_text(report, &frames, at_ms).as_bytes());
        }
        prune(&hangs);
    }
    let log = hang_log(dir);
    let mut line = json_line(report, &frames, at_ms);
    line.push('\n');
    match private_file(&log, true).and_then(|mut file| file.write_all(line.as_bytes())) {
        Ok(()) => Some(log),
        Err(error) => {
            crate::client_log::warn(AREA, &format!("cannot append {}: {error}", log.display()));
            None
        }
    }
}
