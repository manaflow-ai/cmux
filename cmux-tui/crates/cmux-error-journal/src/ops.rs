//! The JSON ops the app calls through the app FFI's JSON channel (cmux-layout-reducer-ffi
//! `cmux_layout_reducer_json`, ops `error_journal_*`). [`ErrorJournals`] holds each open journal
//! by the id the app gives it (its directory); every other op is pure.
//!
//! | op | request | reply |
//! | --- | --- | --- |
//! | `error_journal_open` | `{journal, limits?, segments: [text], current_bytes?}` | `{write}`: lines to compact (purpose `open`), null when none |
//! | `error_journal_record` | `{journal, events}` | [`FlushAdvice`] |
//! | `error_journal_flush` | `{journal}` | `{write}`: [`Write`] or null |
//! | `error_journal_compact_all` | `{journal}` | `{data}`: the table's lines (an append that could not open its file) |
//! | `error_journal_written` | `{journal, ...}` [`Written`] | [`AfterWrite`] |
//! | `error_journal_entries` | `{journal, query?}` | `{entries}` |
//! | `error_journal_count` | `{journal}` | `{count}` |
//! | `error_journal_write_error` | `{journal}` | `{error}` |
//! | `error_journal_clear` | `{journal, fingerprints?}` | `{removed, data}`: compact `data` (purpose `clear`) |
//! | `error_journal_close` | `{journal}` | `{}` |
//! | `error_journal_redact` | `{text}` | `{text}` |
//! | `error_journal_rules_digest` | `{}` | `{digest}` |
//! | `error_journal_template` | `{message, max_bytes?}` | `{template}` |
//! | `error_journal_fingerprint` | `{source, template, top_frame?}` | `{fingerprint}` |
//! | `error_journal_log_events` | `{text, source, file, now}` | `{events}` |
//! | `error_journal_log_plan` | `{cursor?, inode, size, first_read_bytes?, max_read_bytes?}` | [`LogPlan`] |
//! | `error_journal_log_chunk` | `{inode, start, starts_mid_line, complete?, complete_bytes, source, file, now}` | `{events, cursor}` |
//! | `error_journal_crash_names` | `{names, prefixes}` | `{names}` |
//! | `error_journal_crash_scan` | `{cursor?, now, look_back?, files}` | `{reports, cursor}` |
//! | `error_journal_crash_event` | `{text, path, modified}` | `{event}` |
//! | `error_journal_oslog_start` | `{cursor?, process_id, launch, now}` | `{start}` |
//! | `error_journal_oslog_collect` | `{start, now, process_id, records}` | `{events, cursor}` |
//! | `error_journal_console_log_text` | `{level, message, stack?}` | `{text}` |
//! | `error_journal_console_top_frame` | `{stack}` | `{frame}` |
//! | `error_journal_report_text` | `{header, entries}` | `{text}` |

use crate::entry::{Entry, Event};
use crate::fingerprint::fingerprint;
use crate::journal::{Journal, Limits, Written};
use crate::query::{Query, report_text};
use crate::sources::{self, OsLogRecord, ReportFile};
use crate::{normalize, redact};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};
use std::collections::HashMap;

/// Why an op failed.
#[derive(Debug, PartialEq, Eq)]
pub enum OpError {
    /// The op is not one of the table's.
    UnknownOp(String),
    /// The request is not the JSON the op takes, or names a journal that is not open.
    Invalid(String),
}

/// The app's open journals, by id.
#[derive(Debug, Default)]
pub struct ErrorJournals {
    journals: HashMap<String, Journal>,
}

#[derive(Deserialize)]
struct JournalRequest {
    journal: String,
}

#[derive(Deserialize)]
struct OpenRequest {
    journal: String,
    #[serde(default)]
    limits: Limits,
    #[serde(default)]
    segments: Vec<String>,
    #[serde(default)]
    current_bytes: Option<u64>,
}

#[derive(Deserialize)]
struct RecordRequest {
    journal: String,
    #[serde(default)]
    events: Vec<Event>,
}

#[derive(Deserialize)]
struct WrittenRequest {
    journal: String,
    #[serde(flatten)]
    outcome: Written,
}

#[derive(Deserialize)]
struct EntriesRequest {
    journal: String,
    #[serde(default)]
    query: Query,
}

#[derive(Deserialize)]
struct ClearRequest {
    journal: String,
    #[serde(default)]
    fingerprints: Option<Vec<String>>,
}

#[derive(Deserialize)]
struct TextRequest {
    text: String,
}

#[derive(Deserialize)]
struct TemplateRequest {
    message: String,
    #[serde(default = "default_message_bytes")]
    max_bytes: usize,
}

fn default_message_bytes() -> usize {
    1024
}

#[derive(Deserialize)]
struct FingerprintRequest {
    source: String,
    template: String,
    #[serde(default)]
    top_frame: Option<String>,
}

#[derive(Deserialize)]
struct LogEventsRequest {
    text: String,
    source: String,
    file: String,
    now: f64,
}

#[derive(Deserialize)]
struct LogPlanRequest {
    #[serde(default)]
    cursor: Option<String>,
    inode: u64,
    size: u64,
    #[serde(default = "default_first_read")]
    first_read_bytes: u64,
    #[serde(default = "default_max_read")]
    max_read_bytes: u64,
}

fn default_first_read() -> u64 {
    256 * 1024
}

fn default_max_read() -> u64 {
    4 << 20
}

#[derive(Deserialize)]
struct LogChunkRequest {
    inode: u64,
    start: u64,
    #[serde(default)]
    starts_mid_line: bool,
    #[serde(default)]
    complete: Option<String>,
    #[serde(default)]
    complete_bytes: u64,
    source: String,
    file: String,
    now: f64,
}

#[derive(Deserialize)]
struct CrashNamesRequest {
    names: Vec<String>,
    prefixes: Vec<String>,
}

#[derive(Deserialize)]
struct CrashScanRequest {
    #[serde(default)]
    cursor: Option<String>,
    now: f64,
    #[serde(default = "default_look_back")]
    look_back: f64,
    #[serde(default)]
    files: Vec<ReportFile>,
}

fn default_look_back() -> f64 {
    7.0 * 86_400.0
}

#[derive(Deserialize)]
struct CrashEventRequest {
    text: String,
    path: String,
    modified: f64,
}

#[derive(Deserialize)]
struct OsLogStartRequest {
    #[serde(default)]
    cursor: Option<String>,
    process_id: i32,
    launch: f64,
    now: f64,
}

#[derive(Deserialize)]
struct OsLogCollectRequest {
    start: f64,
    now: f64,
    process_id: i32,
    #[serde(default)]
    records: Vec<OsLogRecord>,
}

#[derive(Deserialize)]
struct ConsoleRequest {
    level: String,
    message: String,
    #[serde(default)]
    stack: String,
}

#[derive(Deserialize)]
struct StackRequest {
    stack: String,
}

#[derive(Deserialize)]
struct ReportRequest {
    #[serde(default)]
    header: Vec<String>,
    #[serde(default)]
    entries: Vec<Entry>,
}

fn parse<T: DeserializeOwned>(request: Value) -> Result<T, OpError> {
    serde_json::from_value(request).map_err(|error| OpError::Invalid(error.to_string()))
}

fn to_json<T: serde::Serialize>(value: &T) -> Value {
    serde_json::to_value(value).unwrap_or(Value::Null)
}

impl ErrorJournals {
    /// No journal open.
    pub fn new() -> Self {
        Self::default()
    }

    /// True for the ops this answers.
    pub fn serves(op: &str) -> bool {
        op.starts_with("error_journal_")
    }

    fn journal(&mut self, id: &str) -> Result<&mut Journal, OpError> {
        self.journals
            .get_mut(id)
            .ok_or_else(|| OpError::Invalid(format!("journal {id} is not open")))
    }

    /// Runs `op` on `request` (a JSON object; null means `{}`).
    pub fn call(&mut self, op: &str, request: Value) -> Result<Value, OpError> {
        let request = if request.is_null() { json!({}) } else { request };
        match op {
            "error_journal_open" => {
                let OpenRequest { journal, limits, segments, current_bytes } = parse(request)?;
                let mut opened = Journal::new(limits);
                let segments: Vec<&str> = segments.iter().map(String::as_str).collect();
                let data = opened.open(&segments, current_bytes);
                self.journals.insert(journal, opened);
                Ok(json!({ "write": data.map(|data| json!({ "mode": "compact", "data": data })) }))
            }
            "error_journal_record" => {
                let RecordRequest { journal, events } = parse(request)?;
                Ok(to_json(&self.journal(&journal)?.record(events)))
            }
            "error_journal_flush" => {
                let JournalRequest { journal } = parse(request)?;
                Ok(json!({ "write": self.journal(&journal)?.flush() }))
            }
            "error_journal_compact_all" => {
                let JournalRequest { journal } = parse(request)?;
                Ok(json!({ "data": self.journal(&journal)?.compact_all() }))
            }
            "error_journal_written" => {
                let WrittenRequest { journal, outcome } = parse(request)?;
                Ok(to_json(&self.journal(&journal)?.written(&outcome)))
            }
            "error_journal_entries" => {
                let EntriesRequest { journal, query } = parse(request)?;
                Ok(json!({ "entries": self.journal(&journal)?.entries(&query) }))
            }
            "error_journal_count" => {
                let JournalRequest { journal } = parse(request)?;
                Ok(json!({ "count": self.journal(&journal)?.count() }))
            }
            "error_journal_write_error" => {
                let JournalRequest { journal } = parse(request)?;
                Ok(json!({ "error": self.journal(&journal)?.write_error() }))
            }
            "error_journal_clear" => {
                let ClearRequest { journal, fingerprints } = parse(request)?;
                let (removed, data) = self.journal(&journal)?.clear(fingerprints.as_deref());
                Ok(json!({ "removed": removed, "data": data }))
            }
            "error_journal_close" => {
                let JournalRequest { journal } = parse(request)?;
                self.journals.remove(&journal);
                Ok(json!({}))
            }
            _ => Self::call_pure(op, request),
        }
    }

    fn call_pure(op: &str, request: Value) -> Result<Value, OpError> {
        match op {
            "error_journal_redact" => {
                let TextRequest { text } = parse(request)?;
                Ok(json!({ "text": redact::Redactor::shared().redact(&text) }))
            }
            "error_journal_rules_digest" => {
                Ok(json!({ "digest": redact::Redactor::shared().rules_digest() }))
            }
            "error_journal_template" => {
                let TemplateRequest { message, max_bytes } = parse(request)?;
                Ok(json!({ "template": normalize::template(&message, max_bytes) }))
            }
            "error_journal_fingerprint" => {
                let FingerprintRequest { source, template, top_frame } = parse(request)?;
                Ok(json!({ "fingerprint": fingerprint(&source, &template, top_frame.as_deref()) }))
            }
            "error_journal_log_events" => {
                let LogEventsRequest { text, source, file, now } = parse(request)?;
                Ok(json!({ "events": crate::log_parser::log_events(&text, &source, &file, now) }))
            }
            "error_journal_log_plan" => {
                let LogPlanRequest { cursor, inode, size, first_read_bytes, max_read_bytes } =
                    parse(request)?;
                Ok(to_json(&sources::log_plan(
                    cursor.as_deref(),
                    inode,
                    size,
                    first_read_bytes,
                    max_read_bytes,
                )))
            }
            "error_journal_log_chunk" => {
                let LogChunkRequest {
                    inode,
                    start,
                    starts_mid_line,
                    complete,
                    complete_bytes,
                    source,
                    file,
                    now,
                } = parse(request)?;
                let complete = complete.as_deref().map(|text| (text, complete_bytes));
                let (events, cursor) = sources::log_chunk(
                    inode,
                    start,
                    starts_mid_line,
                    complete,
                    &source,
                    &file,
                    now,
                );
                Ok(json!({ "events": events, "cursor": cursor }))
            }
            "error_journal_crash_names" => {
                let CrashNamesRequest { names, prefixes } = parse(request)?;
                Ok(json!({ "names": sources::crash_report_names(&names, &prefixes) }))
            }
            "error_journal_crash_scan" => {
                let CrashScanRequest { cursor, now, look_back, files } = parse(request)?;
                let (reports, cursor) =
                    sources::crash_scan(cursor.as_deref(), now, look_back, &files);
                Ok(json!({ "reports": reports, "cursor": cursor }))
            }
            "error_journal_crash_event" => {
                let CrashEventRequest { text, path, modified } = parse(request)?;
                Ok(json!({ "event": sources::crash_event(&text, &path, modified) }))
            }
            "error_journal_oslog_start" => {
                let OsLogStartRequest { cursor, process_id, launch, now } = parse(request)?;
                Ok(
                    json!({ "start": sources::oslog_start(cursor.as_deref(), process_id, launch, now) }),
                )
            }
            "error_journal_oslog_collect" => {
                let OsLogCollectRequest { start, now, process_id, records } = parse(request)?;
                let (events, cursor) = sources::oslog_collect(start, now, process_id, &records);
                Ok(json!({ "events": events, "cursor": cursor }))
            }
            "error_journal_console_log_text" => {
                let ConsoleRequest { level, message, stack } = parse(request)?;
                Ok(json!({ "text": sources::console_log_text(&level, &message, &stack) }))
            }
            "error_journal_console_top_frame" => {
                let StackRequest { stack } = parse(request)?;
                Ok(json!({ "frame": sources::console_top_frame(&stack) }))
            }
            "error_journal_report_text" => {
                let ReportRequest { header, entries } = parse(request)?;
                Ok(json!({ "text": report_text(&header, &entries) }))
            }
            other => Err(OpError::UnknownOp(other.to_owned())),
        }
    }
}
