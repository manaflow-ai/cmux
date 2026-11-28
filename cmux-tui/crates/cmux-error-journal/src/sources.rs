//! The harvest sources' decisions; the app does their reading. Daemon logs (where to read from,
//! what the bytes say, the next cursor), crash reports (which are new, what one says), the
//! unified log (where to start, which records are problems, the next cursor) and the page
//! console's log line.

use crate::entry::{Event, Level};
use crate::log_parser::log_events;
use crate::redact::Redactor;
use crate::text::{
    after_first_line_break, ceil_ms, split_colon, split_lines, trim_whitespaces, utf8_prefix,
};
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
use std::sync::OnceLock;

/// The unified log subsystem the page console logs under.
pub const PAGE_CONSOLE_SUBSYSTEM: &str = "com.cmuxterm.page-console";
/// How far back the unified log is read at most, in seconds (3 days).
pub const OSLOG_LONGEST_WINDOW: f64 = 3.0 * 86_400.0;
/// How long the unified log may take to show a record, in seconds.
pub const OSLOG_STORE_LAG: f64 = 5.0;
/// The most unified log records one harvest keeps.
pub const OSLOG_MOST_ENTRIES: usize = 5000;

/// Swift's `Int(text)` / `UInt64(text)`: an optional sign, then ASCII digits only.
fn parse_integer<T: std::str::FromStr>(text: &str) -> Option<T> {
    let digits = text.strip_prefix('+').or_else(|| text.strip_prefix('-')).unwrap_or(text);
    if digits.is_empty() || !digits.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    text.strip_prefix('+').unwrap_or(text).parse().ok()
}

/// Swift's `Double(text)`: decimal or hex floats, `inf`, `nan`; no surrounding space.
fn parse_double(text: &str) -> Option<f64> {
    if text.is_empty()
        || text.starts_with(char::is_whitespace)
        || text.ends_with(char::is_whitespace)
    {
        return None;
    }
    text.parse().ok()
}

// MARK: - Daemon logs

/// Where a log read starts and how much it reads.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct LogPlan {
    /// The byte offset to read from.
    pub start: u64,
    /// The bytes to read; 0 means read nothing and save `cursor`.
    pub read: u64,
    /// The first bytes are the end of a line already passed over: drop through the first newline.
    pub starts_mid_line: bool,
    /// The cursor to save when nothing is read (or the file cannot be opened).
    pub cursor: String,
}

/// Where to read a log of `size` bytes and file number `inode`, after `cursor` ("inode:offset").
/// A new file number or a shorter file starts over; no cursor reads the last `first_read_bytes`;
/// at most `max_read_bytes` are read (the newest).
pub fn log_plan(
    cursor: Option<&str>,
    inode: u64,
    size: u64,
    first_read_bytes: u64,
    max_read_bytes: u64,
) -> LogPlan {
    let saved = cursor.and_then(|cursor| {
        let parts = split_colon(cursor);
        let [inode, offset] = parts.as_slice() else {
            return None;
        };
        Some((parse_integer::<u64>(inode)?, parse_integer::<i64>(offset)?))
    });
    let mut start = match (cursor, saved) {
        (Some(_), Some((saved_inode, offset)))
            if saved_inode == inode && offset >= 0 && offset as u64 <= size =>
        {
            offset as u64
        }
        (None, _) => size.saturating_sub(first_read_bytes),
        _ => 0,
    };
    let mut starts_mid_line = cursor.is_none() && start > 0;
    if size - start > max_read_bytes {
        start = size - max_read_bytes;
        starts_mid_line = true;
    }
    if start >= size {
        return LogPlan { start, read: 0, starts_mid_line, cursor: format!("{inode}:{size}") };
    }
    LogPlan {
        start,
        read: (size - start).min(max_read_bytes),
        starts_mid_line,
        cursor: format!("{inode}:{size}"),
    }
}

/// The events in a read log chunk and the cursor after it. `complete` is the chunk through its
/// last newline, decoded, and `complete_bytes` its length in bytes; None when the chunk held no
/// newline (the cursor stays at `start` until the line is finished).
pub fn log_chunk(
    inode: u64,
    start: u64,
    starts_mid_line: bool,
    complete: Option<(&str, u64)>,
    source: &str,
    file: &str,
    now: f64,
) -> (Vec<Event>, String) {
    let Some((text, complete_bytes)) = complete else {
        return (Vec::new(), format!("{inode}:{start}"));
    };
    let mut text = text;
    if starts_mid_line && let Some(after) = after_first_line_break(text) {
        text = text.get(after..).unwrap_or_default();
    }
    (log_events(text, source, file, now), format!("{inode}:{}", start + complete_bytes))
}

// MARK: - Crash reports

/// The report names a crash scan looks at: `.ips` files whose lowercased name starts with one of
/// `prefixes` (lowercased).
pub fn crash_report_names(names: &[String], prefixes: &[String]) -> Vec<String> {
    let prefixes: Vec<String> = prefixes.iter().map(|prefix| prefix.to_lowercase()).collect();
    names
        .iter()
        .filter(|name| {
            let lowered = name.to_lowercase();
            name.ends_with(".ips")
                && prefixes.iter().any(|prefix| lowered.starts_with(prefix.as_str()))
        })
        .cloned()
        .collect()
}

/// A crash report and when it was last modified (seconds since 1970).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ReportFile {
    /// The file name.
    pub name: String,
    /// Its modification time; None when it could not be read.
    #[serde(default)]
    pub modified: Option<f64>,
}

/// Which `files` are new since `cursor` (ms since 1970; none: `now - look_back` seconds), and the
/// cursor after them.
pub fn crash_scan(
    cursor: Option<&str>,
    now: f64,
    look_back: f64,
    files: &[ReportFile],
) -> (Vec<ReportFile>, String) {
    let since = cursor.and_then(parse_double).map_or(now - look_back, |ms| ms / 1000.0);
    let mut newest = since;
    let mut reports = Vec::new();
    for file in files {
        let Some(modified) = file.modified.filter(|&modified| modified > since) else { continue };
        newest = newest.max(modified);
        reports.push(file.clone());
    }
    (reports, ceil_ms(newest).to_string())
}

fn crash_patterns() -> &'static [Option<Regex>; 3] {
    static PATTERNS: OnceLock<[Option<Regex>; 3]> = OnceLock::new();
    PATTERNS.get_or_init(|| {
        [
            Regex::new(r#""exception"\s*:\s*\{[^}]*"type"\s*:\s*"([^"]+)""#).ok(),
            Regex::new(r#""signal"\s*:\s*"([^"]+)""#).ok(),
            Regex::new(r#""symbol"\s*:\s*"([^"]+)""#).ok(),
        ]
    })
}

fn first_capture(pattern: Option<&Regex>, text: &str) -> Option<String> {
    Some(pattern?.captures(text)?.get(1)?.as_str().to_owned())
}

/// The event for the crash report at `path`, from the decoded start of its text.
pub fn crash_event(text: &str, path: &str, modified: f64) -> Event {
    let header: serde_json::Map<String, Value> = split_lines(text, true)
        .first()
        .and_then(|line| serde_json::from_str::<Value>(line).ok())
        .and_then(|value| match value {
            Value::Object(map) => Some(map),
            _ => None,
        })
        .unwrap_or_default();
    let stem = {
        let name = path.rsplit('/').next().unwrap_or(path);
        match name.rfind('.') {
            Some(dot) if dot > 0 => name.get(..dot).unwrap_or(name),
            _ => name,
        }
    };
    let app = header.get("app_name").and_then(Value::as_str).unwrap_or(stem);
    let kind = match header.get("bug_type").and_then(Value::as_str) {
        Some("309") => "crash".to_owned(),
        Some("298" | "288") => "hang".to_owned(),
        Some("211") => "analytics".to_owned(),
        Some(other) => format!("report {other}"),
        None => "report".to_owned(),
    };
    let [exception, signal, symbol] = crash_patterns();
    let exception = first_capture(exception.as_ref(), text);
    let signal = first_capture(signal.as_ref(), text);
    let frame = first_capture(symbol.as_ref(), text);
    let message = [Some(format!("{kind} {app}")), exception, signal]
        .into_iter()
        .flatten()
        .collect::<Vec<_>>()
        .join(" ");
    let mut context = BTreeMap::from([("report".to_owned(), path.to_owned())]);
    if let Some(version) = header.get("app_version").and_then(Value::as_str) {
        context.insert("version".to_owned(), version.to_owned());
    }
    Event {
        source: "crash".to_owned(),
        level: Level::Crash,
        message,
        top_frame: frame,
        context,
        date: modified,
    }
}

// MARK: - Unified log

/// Where a unified log read starts (seconds since 1970): after `cursor` ("pid:ms") when it is this
/// process's, else at launch; never more than three days back.
pub fn oslog_start(cursor: Option<&str>, process_id: i32, launch: f64, now: f64) -> f64 {
    let mut start = launch;
    if let Some(cursor) = cursor {
        let parts = split_colon(cursor);
        if let [pid, ms] = parts.as_slice()
            && parse_integer::<i32>(pid) == Some(process_id)
            && let Some(ms) = parse_double(ms)
        {
            start = ms / 1000.0;
        }
    }
    start.max(now - OSLOG_LONGEST_WINDOW)
}

/// A unified log record.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct OsLogRecord {
    /// Its subsystem (may be empty).
    #[serde(default)]
    pub subsystem: String,
    /// Its category.
    #[serde(default)]
    pub category: String,
    /// `error`, `fault` or another level (skipped).
    pub level: String,
    /// The message.
    pub message: String,
    /// When it was logged, seconds since 1970.
    pub date: f64,
}

/// The events in `records` read from `start`, and the cursor after them (the newest record or
/// `now` less the store's lag, whichever is later).
pub fn oslog_collect(
    start: f64,
    now: f64,
    process_id: i32,
    records: &[OsLogRecord],
) -> (Vec<Event>, String) {
    let found: Vec<&OsLogRecord> = records
        .iter()
        .filter(|record| {
            record.date > start && (record.level == "error" || record.level == "fault")
        })
        .collect();
    let mut newest = start;
    let mut events = Vec::new();
    for record in found.get(found.len().saturating_sub(OSLOG_MOST_ENTRIES)..).unwrap_or_default() {
        newest = newest.max(record.date);
        events.push(oslog_event(
            &record.subsystem,
            &record.category,
            record.level == "fault",
            &record.message,
            record.date,
        ));
    }
    let end = newest.max(now - OSLOG_STORE_LAG);
    (events, format!("{process_id}:{}", ceil_ms(end)))
}

/// The event for one unified log record: page console records are `page:<category>` (a `[warn] `
/// line a warning), the app's own `app`, the rest `system:<subsystem>`; the first line is the
/// message and a later `at …` line the frame.
pub fn oslog_event(
    subsystem: &str,
    category: &str,
    is_fault: bool,
    message: &str,
    date: f64,
) -> Event {
    let source = if subsystem == PAGE_CONSOLE_SUBSYSTEM {
        format!("page:{category}")
    } else if subsystem.starts_with("com.cmuxterm") || subsystem.is_empty() {
        "app".to_owned()
    } else {
        format!("system:{subsystem}")
    };
    let lines = split_lines(message, true);
    let first = lines.first().copied().unwrap_or(message);
    let frame = lines
        .iter()
        .skip(1)
        .map(|line| trim_whitespaces(line))
        .find(|line| line.starts_with("at "))
        .map(|line| line.get(3..).unwrap_or_default().to_owned());
    let mut level = if is_fault { Level::Fault } else { Level::Error };
    if source.starts_with("page:") && first.starts_with("[warn] ") {
        level = Level::Warning;
    }
    Event {
        source,
        level,
        message: first.to_owned(),
        top_frame: frame,
        context: BTreeMap::from([
            ("subsystem".to_owned(), subsystem.to_owned()),
            ("category".to_owned(), category.to_owned()),
        ]),
        date,
    }
}

// MARK: - Page console

/// The unified log line for a page console message: its first line redacted (prefixed `[warn] `
/// for a warning), then its stack's top frame.
pub fn console_log_text(level: &str, message: &str, stack: &str) -> String {
    let redactor = Redactor::shared();
    let prefix = if level == "warn" { "[warn] " } else { "" };
    let first_line = split_lines(message, true).first().copied().unwrap_or(message);
    let mut text = format!("{prefix}{}", utf8_prefix(&redactor.redact(first_line), 1024));
    if let Some(frame) = console_top_frame(stack) {
        text.push_str("\n    at ");
        text.push_str(&utf8_prefix(&redactor.redact(&frame), 256));
    }
    text
}

/// A JavaScript stack's top frame: the first `at …` line, or a Safari `name@url:line:col` line.
pub fn console_top_frame(stack: &str) -> Option<String> {
    for raw in split_lines(stack, true) {
        let line = trim_whitespaces(raw);
        if let Some(rest) = line.strip_prefix("at ") {
            return Some(rest.to_owned());
        }
        if line.contains('@') && line.contains(':') {
            return Some(line.to_owned());
        }
    }
    None
}
