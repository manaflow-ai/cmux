//! The running app is older than the installed one: one line on stderr.
//!
//! An update swaps the app bundle on disk, but the running process keeps its old code until it is
//! relaunched (Leo's NIGHTLY, 2026-11-21: installed 1.0.0-nightly.4487759453601, process started
//! 11-16, so `cmux chat --on vm:new` was answered by 5-day-old code). This `cmux` is the installed
//! one: it ships inside the bundle on disk. When the app it connects to reports another build
//! (`system.identify`'s `build`, the app's `CFBundleVersion`), it says so once and goes on. It warns
//! only: it never refuses, never relaunches, and stays quiet outside human output (`--json`).
//!
//! The date is when the running process started (`ps -o lstart=` of the pid `identify` reports),
//! which every app version answers, old ones included.

use std::os::unix::net::UnixStream;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use serde_json::{Value, json};

use super::{GlobalArgs, OutputMode};

/// How long the one `identify` read waits. A slow app is not this CLI's business.
const IDENTIFY_WAIT: Duration = Duration::from_secs(1);

/// What `identify` says about the running app.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct RunningApp {
    /// `CFBundleVersion`.
    pub build: String,
    /// `CFBundleShortVersionString`, shown when there is one.
    pub version: Option<String>,
    pub pid: Option<u32>,
}

impl RunningApp {
    /// `None` without a build.
    pub(super) fn from_identity(identity: &Value) -> Option<Self> {
        let text = |key: &str| identity[key].as_str().map(str::trim).filter(|v| !v.is_empty());
        Some(Self {
            build: text("build")?.to_owned(),
            version: text("version").map(str::to_owned),
            pid: identity["pid"].as_u64().and_then(|pid| u32::try_from(pid).ok()),
        })
    }

    fn name(&self) -> &str {
        self.version.as_deref().unwrap_or(&self.build)
    }
}

/// The installed build: the bundle this CLI ships in.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct InstalledApp {
    pub build: String,
    pub version: Option<String>,
}

impl InstalledApp {
    fn name(&self) -> &str {
        self.version.as_deref().unwrap_or(&self.build)
    }
}

/// The line to print, or `None` when the running app is the installed build, or not older than it
/// (a build this CLI cannot order never warns: the text would be a guess). `started` is the
/// running app's start date (`YYYY-MM-DD`), left out of the line when unknown.
pub(super) fn notice(
    running: &RunningApp,
    installed: &InstalledApp,
    started: Option<&str>,
) -> Option<String> {
    if !is_newer(&installed.build, &running.build) {
        return None;
    }
    let from = started.map(|date| format!(" from {date}")).unwrap_or_default();
    Some(format!(
        "cmux: the running app is build {}{from}; build {} is installed. Restart cmux to use it.",
        running.name(),
        installed.name(),
    ))
}

/// Whether build `candidate` is newer than `base`. Builds are dotted (`1.2.3`) or one plain number
/// (`4487759453601`): digit runs compare by length, then text, so a long number never overflows.
/// Equal, blank or non-comparable builds are not newer.
pub(super) fn is_newer(candidate: &str, base: &str) -> bool {
    let (candidate, base) = (candidate.trim(), base.trim());
    if candidate.is_empty() || base.is_empty() || candidate == base {
        return false;
    }
    let parts = |build: &str| {
        build
            .split(['.', '-', '+'])
            .filter(|part| !part.is_empty())
            .map(str::to_owned)
            .collect::<Vec<_>>()
    };
    let (new, old) = (parts(candidate), parts(base));
    for index in 0..new.len().max(old.len()) {
        let lhs = new.get(index).map_or("0", String::as_str);
        let rhs = old.get(index).map_or("0", String::as_str);
        if lhs != rhs {
            let order = compare_part(lhs, rhs);
            if order != std::cmp::Ordering::Equal {
                return order == std::cmp::Ordering::Greater;
            }
        }
    }
    false
}

fn compare_part(lhs: &str, rhs: &str) -> std::cmp::Ordering {
    let digits = |text: &str| !text.is_empty() && text.bytes().all(|byte| byte.is_ascii_digit());
    if digits(lhs) && digits(rhs) {
        let (lhs, rhs) = (lhs.trim_start_matches('0'), rhs.trim_start_matches('0'));
        return lhs.len().cmp(&rhs.len()).then_with(|| lhs.cmp(rhs));
    }
    lhs.cmp(rhs)
}

/// `ps -o lstart=`'s `Mon Nov 16 14:55:03 2026` as `2026-11-16`.
pub(super) fn start_date(lstart: &str) -> Option<String> {
    let words: Vec<&str> = lstart.split_whitespace().collect();
    let [_, month, day, _time, year] = words.as_slice() else { return None };
    const MONTHS: [&str; 12] =
        ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    let month = MONTHS.iter().position(|name| name == month)? + 1;
    let day: u32 = day.parse().ok()?;
    let year: u32 = year.parse().ok().filter(|year| (1970..=9999).contains(year))?;
    (1..=31).contains(&day).then(|| format!("{year:04}-{month:02}-{day:02}"))
}

static CHECKED: AtomicBool = AtomicBool::new(false);

/// After a successful connection to the app's socket: once per process, in human output only, asks
/// the app which build it runs on a connection of its own (the command's stream is never touched)
/// and prints [`notice`]. Every failure is silent.
pub(super) fn warn_if_stale(global: &GlobalArgs, socket: &Path) {
    if global.output != OutputMode::Human || CHECKED.swap(true, Ordering::Relaxed) {
        return;
    }
    let Some(installed) = installed_build() else { return };
    let Ok(mut stream) = connect(socket) else { return };
    let Ok(Ok(identity)) =
        super::app::exchange(&mut stream, "system.identify", json!({}), IDENTIFY_WAIT)
    else {
        return;
    };
    let Some(running) = RunningApp::from_identity(&identity) else { return };
    // Only a differing build costs the `ps`.
    if !is_newer(&installed.build, &running.build) {
        return;
    }
    let started = running.pid.and_then(process_start_date);
    if let Some(line) = notice(&running, &installed, started.as_deref()) {
        eprintln!("{line}");
    }
}

fn connect(socket: &Path) -> std::io::Result<UnixStream> {
    let stream = UnixStream::connect(socket)?;
    stream.set_read_timeout(Some(IDENTIFY_WAIT))?;
    stream.set_write_timeout(Some(IDENTIFY_WAIT))?;
    Ok(stream)
}

fn installed_build() -> Option<InstalledApp> {
    let exe = std::env::current_exe().ok()?;
    crate::app_identity::bundle_build(&exe)
}

fn process_start_date(pid: u32) -> Option<String> {
    let output = std::process::Command::new("/bin/ps")
        .args(["-o", "lstart=", "-p", &pid.to_string()])
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output()
        .ok()
        .filter(|output| output.status.success())?;
    start_date(&String::from_utf8_lossy(&output.stdout))
}

#[cfg(test)]
#[path = "stale_app_tests.rs"]
mod tests;
