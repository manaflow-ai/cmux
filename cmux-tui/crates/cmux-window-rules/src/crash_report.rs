//! The rules of the app's own crash reports (`~/Library/Logs/cmux-next/`):
//! the JSON object of a Chromium failure and of an app crash found at
//! launch, a report's file name, which reports the folder drops past its
//! limit, which log "Show Crash Logs" opens, the restart notice's cause line
//! and the Report button's crashed build. Pure: the app lists the folders,
//! reads the clock and writes the files. Was `CrashReportWriter.swift`'s,
//! `CrashLogOpener.swift`'s, `CrashRecoveryService.swift`'s and
//! `CrashIssueReport.swift`'s (cause, scrub) rules.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

/// How many reports the folder keeps.
pub const RETAIN: usize = 100;
/// The restart notice's cause line is cut past this many characters.
pub const NOTICE_CAUSE_LIMIT: usize = 80;

/// `text` with every character but a letter, a digit, `.` and `-` as `_` (a file name part).
pub fn safe(text: &str) -> String {
    text.chars()
        .map(|c| if c.is_alphabetic() || c.is_numeric() || c == '.' || c == '-' { c } else { '_' })
        .collect()
}

/// A local date's parts, as the app's calendar reads them.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Stamp {
    pub year: i32,
    pub month: u32,
    pub day: u32,
    pub hour: u32,
    pub minute: u32,
    pub second: u32,
    pub millis: u32,
}

/// `YYYYMMDD-HHMMSS-mmm`.
pub fn stamp(date: &Stamp) -> String {
    format!(
        "{:04}{:02}{:02}-{:02}{:02}{:02}-{:03}",
        date.year, date.month, date.day, date.hour, date.minute, date.second, date.millis
    )
}

/// A report's file name: `<bundle>-<name>-<stamp>.json`, each part made safe.
pub fn file_name(bundle: &str, name: &str, date: &Stamp) -> String {
    format!("{}-{}-{}.json", safe(bundle), safe(name), stamp(date))
}

/// A file in a listed folder.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Listed {
    /// Its file name.
    pub name: String,
    /// Its modification time (ms since 1970); none: never, the oldest.
    #[serde(default)]
    pub modified_ms: Option<i64>,
    /// Whether it is a folder.
    #[serde(default)]
    pub folder: bool,
}

impl Listed {
    fn modified(&self) -> i64 {
        self.modified_ms.unwrap_or(i64::MIN)
    }
}

fn extension(name: &str) -> Option<&str> {
    let (stem, extension) = name.rsplit_once('.')?;
    (!stem.is_empty()).then_some(extension)
}

/// The reports (`.json`) to delete after a write so `retain` stay: the oldest.
pub fn prune(files: &[Listed], retain: usize) -> Vec<String> {
    let mut reports: Vec<&Listed> =
        files.iter().filter(|file| extension(&file.name) == Some("json")).collect();
    if reports.len() <= retain {
        return Vec::new();
    }
    reports.sort_by_key(|file| file.modified());
    let drop = reports.len() - retain;
    reports.into_iter().take(drop).map(|file| file.name.clone()).collect()
}

/// Whether `name` is a macOS crash report (`<executable>-<date>.ips`) of `executable`.
fn is_system_log(name: &str, executable: &str) -> bool {
    extension(name) == Some("ips") && name.starts_with(&format!("{executable}-"))
}

fn newest(files: &[Listed], keep: impl Fn(&Listed) -> bool) -> Option<&Listed> {
    files.iter().filter(|file| keep(file)).fold(None, |best: Option<&Listed>, file| match best {
        Some(best) if best.modified() >= file.modified() => Some(best),
        _ => Some(file),
    })
}

/// The newest macOS crash report of `executable` in `files` (DiagnosticReports) written at or after `after_ms`.
pub fn system_log(files: &[Listed], executable: &str, after_ms: i64) -> Option<String> {
    newest(files, |file| is_system_log(&file.name, executable) && file.modified() >= after_ms)
        .map(|file| file.name.clone())
}

/// What "Show Crash Logs" opens.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum LogTarget {
    /// The previous run's macOS report (a path the app gave).
    PreviousSystemLog,
    /// cmux's own report of the previous run (a path the app gave).
    PreviousReport,
    /// The newest macOS report of this executable, in the system logs folder.
    SystemLog { name: String },
    /// The newest cmux report, in the report folder.
    Report { name: String },
    /// No log yet: the report folder (Finder).
    Folder,
}

/// The previous run's macOS report, else cmux's own report of it, else
/// the newest macOS report of this executable, else the newest cmux
/// report, else the report folder.
pub fn log_target(
    previous_system_log: bool,
    previous_report: bool,
    system_logs: &[Listed],
    reports: &[Listed],
    executable: &str,
) -> LogTarget {
    if previous_system_log {
        return LogTarget::PreviousSystemLog;
    }
    if previous_report {
        return LogTarget::PreviousReport;
    }
    if let Some(file) = newest(system_logs, |file| is_system_log(&file.name, executable)) {
        return LogTarget::SystemLog { name: file.name.clone() };
    }
    if let Some(file) = newest(reports, |file| extension(&file.name) == Some("json")) {
        return LogTarget::Report { name: file.name.clone() };
    }
    LogTarget::Folder
}

/// The build a report is written by.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Writer {
    pub bundle_id: String,
    pub version: String,
}

/// `CFBundleShortVersionString` and `CFBundleVersion` joined by a space, `unknown` when neither is set.
pub fn version(short: Option<&str>, build: Option<&str>) -> String {
    let joined = [short, build].into_iter().flatten().collect::<Vec<_>>().join(" ");
    if joined.is_empty() { "unknown".into() } else { joined }
}

/// A Chromium helper or renderer failure (`BrowserCrashRecord`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Chromium {
    /// ISO 8601 with milliseconds (the app's formatter).
    pub date: String,
    pub process_type: String,
    pub reason: String,
    pub source: String,
    #[serde(default)]
    pub sub_type: Option<String>,
    #[serde(default)]
    pub pid: Option<i64>,
    #[serde(default)]
    pub code: Option<i64>,
    #[serde(default)]
    pub code_text: Option<String>,
    #[serde(default)]
    pub tab: Option<String>,
}

fn insert<T: Serialize>(object: &mut Map<String, Value>, key: &str, value: Option<T>) {
    if let Some(value) = value {
        object.insert(key.into(), json!(value));
    }
}

/// A Chromium failure's report object, and its file name part.
pub fn chromium_report(record: &Chromium, writer: &Writer) -> (Value, String) {
    let mut object = Map::new();
    object.insert("kind".into(), json!("chromium"));
    object.insert("date".into(), json!(record.date));
    object.insert("process_type".into(), json!(record.process_type));
    object.insert("reason".into(), json!(record.reason));
    object.insert("source".into(), json!(record.source));
    object.insert("bundle_id".into(), json!(writer.bundle_id));
    object.insert("version".into(), json!(writer.version));
    insert(&mut object, "sub_type", record.sub_type.as_ref());
    insert(&mut object, "pid", record.pid);
    insert(&mut object, "code", record.code);
    insert(&mut object, "code_text", record.code_text.as_ref());
    insert(&mut object, "tab", record.tab.as_ref());
    (Value::Object(object), format!("chromium-{}", record.process_type))
}

/// An uncaught exception the previous run recorded.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Exception {
    pub name: String,
    #[serde(default)]
    pub reason: Option<String>,
    #[serde(default)]
    pub frames: Vec<String>,
}

/// The previous run, as an app crash report reads it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppCrash {
    /// ISO 8601 times of its launch and of this launch finding it.
    pub launched: String,
    pub found: String,
    pub pid: i64,
    /// It was itself a restart.
    pub recovery: bool,
    pub survived: bool,
    #[serde(default)]
    pub signal: Option<i32>,
    /// The signal's name (`BrowserProcessExit`'s code text), if it has one.
    #[serde(default)]
    pub signal_name: Option<String>,
    #[serde(default)]
    pub exception: Option<Exception>,
    /// How many browser pages this launch holds back.
    #[serde(default)]
    pub pages_held: usize,
    /// macOS's report of it, when found.
    #[serde(default)]
    pub system_report: Option<String>,
}

/// An app crash's report object.
pub fn app_report(crash: &AppCrash, writer: &Writer) -> Value {
    let mut object = Map::new();
    object.insert("kind".into(), json!("app"));
    object.insert("launched".into(), json!(crash.launched));
    object.insert("found".into(), json!(crash.found));
    object.insert("pid".into(), json!(crash.pid));
    object.insert("was_restart".into(), json!(crash.recovery));
    object.insert("lived_past_quick_window".into(), json!(crash.survived));
    object.insert("bundle_id".into(), json!(writer.bundle_id));
    object.insert("version".into(), json!(writer.version));
    object.insert("browser_pages_held".into(), json!(crash.pages_held));
    if let Some(signal) = crash.signal {
        object.insert("signal".into(), json!(signal));
        let name = crash.signal_name.clone().unwrap_or_else(|| signal.to_string());
        object.insert("signal_name".into(), json!(name));
    }
    if let Some(exception) = &crash.exception {
        object.insert("exception_name".into(), json!(exception.name));
        insert(&mut object, "exception_reason", exception.reason.as_ref());
        object.insert("exception_frames".into(), json!(exception.frames));
    }
    insert(&mut object, "system_report", crash.system_report.as_ref());
    Value::Object(object)
}

/// `text` with the home folder path as `~`.
pub fn scrub(text: &str, home: &str) -> String {
    if home.is_empty() { text.to_owned() } else { text.replace(home, "~") }
}

/// A crash's one-line cause: the exception summary (scrubbed), else the
/// signal's name, else `signal N`; none without either.
pub fn cause(
    exception_summary: Option<&str>,
    signal: Option<i32>,
    signal_name: Option<&str>,
    home: &str,
) -> Option<String> {
    if let Some(summary) = exception_summary {
        return Some(scrub(summary, home));
    }
    let signal = signal?;
    Some(signal_name.map(str::to_owned).unwrap_or_else(|| format!("signal {signal}")))
}

/// The restart notice's cause, cut to 79 characters and `…` past 80.
pub fn notice_cause(cause: &str) -> String {
    if cause.chars().count() > NOTICE_CAUSE_LIMIT {
        let mut cut: String = cause.chars().take(NOTICE_CAUSE_LIMIT - 1).collect();
        cut.push('…');
        cut
    } else {
        cause.to_owned()
    }
}

/// The crashed build the Report button names.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct CrashedBuild {
    pub version: String,
    pub commit: Option<String>,
}

/// The crashed build, not this one (an update may have installed since):
/// the marker's version, else macOS's report's, else this build's; the
/// marker's commit, else this build's commit only when the version is this
/// build's.
pub fn crashed_build(
    marker_version: Option<&str>,
    marker_commit: Option<&str>,
    system_version: Option<&str>,
    running_version: &str,
    running_commit: Option<&str>,
) -> CrashedBuild {
    let version = marker_version.or(system_version).unwrap_or(running_version).to_owned();
    let commit = match marker_commit {
        Some(commit) => Some(commit.to_owned()),
        None if version == running_version => running_commit.map(str::to_owned),
        None => None,
    };
    CrashedBuild { version, commit }
}

#[cfg(test)]
#[path = "crash_report_tests.rs"]
mod tests;
