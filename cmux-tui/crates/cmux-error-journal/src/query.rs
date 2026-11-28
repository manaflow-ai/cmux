//! Which entries a reader asked for, in which order, and the text Copy Logs puts on the clipboard.

use crate::entry::{Entry, Level};
use crate::text::format_iso8601_ms;
use serde::{Deserialize, Serialize};

/// The order entries come back in.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Order {
    /// Newest first.
    #[default]
    Recent,
    /// Most occurrences first.
    Count,
}

/// A filter over the journal. `since` is seconds since 1970.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Query {
    /// Only entries last seen at or after this time.
    pub since: Option<f64>,
    /// Only these sources (`page` matches `page:settings`); empty is all.
    pub sources: Vec<String>,
    /// Only this level and worse.
    pub minimum_level: Level,
    /// Only entries whose template or sample contains this, ignoring case.
    pub text: Option<String>,
    /// The order.
    pub order: Order,
    /// At most this many.
    pub limit: i64,
}

impl Default for Query {
    fn default() -> Self {
        Self {
            since: None,
            sources: Vec::new(),
            minimum_level: Level::Warning,
            text: None,
            order: Order::Recent,
            limit: 50,
        }
    }
}

fn contains_ignoring_case(haystack: &str, needle: &str) -> bool {
    haystack.to_lowercase().contains(&needle.to_lowercase())
}

impl Query {
    /// Whether `entry` passes the filter.
    pub fn matches(&self, entry: &Entry) -> bool {
        if let Some(since) = self.since
            && entry.last_ms < (since * 1000.0) as i64
        {
            return false;
        }
        if entry.level < self.minimum_level {
            return false;
        }
        if !self.sources.is_empty()
            && !self.sources.iter().any(|source| {
                entry.source == *source || entry.source.starts_with(&format!("{source}:"))
            })
        {
            return false;
        }
        if let Some(text) = self.text.as_deref().filter(|text| !text.is_empty())
            && !contains_ignoring_case(&entry.template, text)
            && !contains_ignoring_case(&entry.sample, text)
        {
            return false;
        }
        true
    }

    /// The entries that pass, sorted and cut to the limit.
    pub fn select<'a>(&self, entries: impl IntoIterator<Item = &'a Entry>) -> Vec<Entry> {
        let mut matching: Vec<&Entry> =
            entries.into_iter().filter(|entry| self.matches(entry)).collect();
        match self.order {
            Order::Recent => {
                matching.sort_by_key(|entry| std::cmp::Reverse((entry.last_ms, entry.count)));
            }
            Order::Count => {
                matching.sort_by_key(|entry| std::cmp::Reverse((entry.count, entry.last_ms)));
            }
        }
        matching
            .into_iter()
            .take(usize::try_from(self.limit.max(0)).unwrap_or(0))
            .cloned()
            .collect()
    }
}

/// Copy Logs' text: the header, a blank line, then per entry its last-seen time, level, source,
/// count and sample, with its top frame under it.
pub fn report_text(header: &[String], entries: &[Entry]) -> String {
    let mut lines: Vec<String> = header.to_vec();
    lines.push(String::new());
    if entries.is_empty() {
        lines.push("No problems recorded.".to_owned());
    }
    for entry in entries {
        lines.push(format!(
            "{} {} {} ×{}: {}",
            format_iso8601_ms(entry.last_ms),
            entry.level.as_str(),
            entry.source,
            entry.count,
            entry.sample
        ));
        if let Some(frame) = entry.top_frame.as_deref().filter(|frame| !frame.is_empty()) {
            lines.push(format!("    at {frame}"));
        }
    }
    lines.join("\n") + "\n"
}
