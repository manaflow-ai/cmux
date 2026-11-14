//! History a browser exports as JSON (`ExportedHistory.swift`): Safari's History.json (File >
//! Export Browsing Data to File, `{"history": [{url, title, time_usec, visit_count}]}`) and
//! Chrome's in Google Takeout (BrowserHistory.json or Chrome/History.json,
//! `{"Browser History": [{url, title, time_usec}]}`, one row per visit). Times are microseconds
//! since 1970. One entry per URL, the newest `limit` by last visit; only importable URLs.

use crate::json;
use crate::model::HistoryEntry;
use crate::{time, url};
use std::collections::HashMap;

/// `ImportPlan.defaultHistoryLimit`.
pub const DEFAULT_HISTORY_LIMIT: i64 = 5_000;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Format {
    Safari,
    ChromeTakeout,
}

impl Format {
    pub fn name(self) -> &'static str {
        match self {
            Format::Safari => "safari",
            Format::ChromeTakeout => "chromeTakeout",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ExportedHistory {
    pub format: Format,
    pub entries: Vec<HistoryEntry>,
}

/// Whether `head` (a file's first bytes) looks like one of the formats.
pub fn looks_like_history(head: &str) -> bool {
    head.starts_with('{') && (head.contains("\"history\"") || head.contains("\"Browser History\""))
}

/// None when `data` is neither format.
pub fn parse(data: &[u8], limit: i64) -> Option<ExportedHistory> {
    let object = json::object_or_none(data)?;
    let (format, rows) = if let Some(rows) = json::objects(object.get("history")) {
        (Format::Safari, rows)
    } else if let Some(rows) = json::objects(object.get("Browser History")) {
        (Format::ChromeTakeout, rows)
    } else {
        return None;
    };
    let mut order: Vec<String> = Vec::new();
    let mut by_url: HashMap<String, HistoryEntry> = HashMap::new();
    for row in rows {
        let Some(text) = json::string(row.get("url")).and_then(url::importable) else { continue };
        let microseconds = json::double(row.get("time_usec")).unwrap_or(0.0);
        let visit = time::from_unix(microseconds / 1_000_000.0);
        let visits = if format == Format::Safari {
            json::double(row.get("visit_count")).map_or(1, truncate).max(1)
        } else {
            1
        };
        let title = json::non_empty(row.get("title")).map(str::to_owned);
        match by_url.get_mut(text) {
            None => {
                order.push(text.to_owned());
                by_url.insert(
                    text.to_owned(),
                    HistoryEntry {
                        url: text.to_owned(),
                        title,
                        visit_count: visits,
                        last_visit: visit,
                    },
                );
            }
            Some(entry) => {
                entry.visit_count = entry.visit_count.saturating_add(visits);
                if visit > entry.last_visit {
                    entry.last_visit = visit;
                    if title.is_some() {
                        entry.title = title;
                    }
                }
            }
        }
    }
    let mut entries: Vec<HistoryEntry> =
        order.into_iter().filter_map(|key| by_url.remove(&key)).collect();
    entries.sort_by(|a, b| b.last_visit.total_cmp(&a.last_visit));
    entries.truncate(usize::try_from(limit.max(0)).unwrap_or(usize::MAX));
    Some(ExportedHistory { format, entries })
}

/// `NSNumber.intValue` of a double: toward zero, saturating.
#[allow(clippy::cast_possible_truncation, reason = "a saturating truncation, as intValue")]
fn truncate(value: f64) -> i64 {
    value as i64
}
