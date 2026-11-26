//! Turns daemon log text (tracing lines, Rust panics) into events: WARN/WARNING lines are
//! warnings, ERROR lines errors, FATAL/CRITICAL lines and panics faults. The rules of the Swift
//! `LogLineParser`.

use crate::entry::{Event, Level};
use crate::text::{parse_iso8601, split_lines, trim_whitespaces};
use regex::Regex;
use std::collections::BTreeMap;
use std::sync::OnceLock;

struct Patterns {
    ansi: Regex,
    level: Regex,
    panic: Regex,
    timestamp: Regex,
}

fn patterns() -> Option<&'static Patterns> {
    static PATTERNS: OnceLock<Option<Patterns>> = OnceLock::new();
    PATTERNS
        .get_or_init(|| {
            Some(Patterns {
                ansi: Regex::new(r"\x1b\[[0-9;]*[A-Za-z]").ok()?,
                level: Regex::new(r"\b(WARN|WARNING|ERROR|FATAL|CRITICAL)\b").ok()?,
                // ICU's `(.*)$`: `.` stops at a line terminator and `$` also matches before a final one.
                panic: Regex::new(
                    r"panicked at ([^\s:]+:\d+)(?::\d+)?:?\s*([^\n\x0B\x0C\r\u{85}\u{2028}\u{2029}]*)(?:\r\n|[\n\x0B\x0C\r\u{85}\u{2028}\u{2029}])?$",
                )
                .ok()?,
                timestamp: Regex::new(r"^\s*(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z)").ok()?,
            })
        })
        .as_ref()
}

fn line_date(patterns: &Patterns, line: &str) -> Option<f64> {
    parse_iso8601(patterns.timestamp.captures(line)?.get(1)?.as_str())
}

/// The events in `text` from `source`'s log `file`; a line with no leading timestamp is dated `now`.
pub fn log_events(text: &str, source: &str, file: &str, now: f64) -> Vec<Event> {
    let Some(patterns) = patterns() else { return Vec::new() };
    let lines: Vec<String> = split_lines(text, false)
        .into_iter()
        .map(|line| patterns.ansi.replace_all(line, "").into_owned())
        .collect();
    let context = BTreeMap::from([("file".to_owned(), file.to_owned())]);
    let mut events = Vec::new();
    let mut index = 0;
    while index < lines.len() {
        let line = &lines[index];
        index += 1;
        let date = line_date(patterns, line).unwrap_or(now);
        if let Some(captures) = patterns.panic.captures(line)
            && let (Some(frame), Some(rest)) = (captures.get(1), captures.get(2))
        {
            let mut message = trim_whitespaces(rest.as_str()).to_owned();
            if message.is_empty() && index < lines.len() {
                message = trim_whitespaces(&lines[index]).to_owned();
                index += 1;
            }
            events.push(Event {
                source: source.to_owned(),
                level: Level::Fault,
                message: format!("panic: {message}"),
                top_frame: Some(frame.as_str().to_owned()),
                context: context.clone(),
                date,
            });
            continue;
        }
        let Some(word) = patterns.level.captures(line).and_then(|captures| captures.get(1)) else {
            continue;
        };
        let level = match word.as_str() {
            "WARN" | "WARNING" => Level::Warning,
            "ERROR" => Level::Error,
            _ => Level::Fault,
        };
        let message =
            line[word.end()..].trim_matches(|c| matches!(c, ' ' | ':' | ']' | '-' | '\t'));
        events.push(Event {
            source: source.to_owned(),
            level,
            message: if message.is_empty() { line.clone() } else { message.to_owned() },
            top_frame: None,
            context: context.clone(),
            date,
        });
    }
    events
}
