//! The history filter: port of Swift `HistoryQuery` and `HistoryRange`.

use serde::{Deserialize, Serialize};
use url::Url;

use crate::entry::{HistoryEntry, HistoryKind};
use crate::fold::{fold, tokens};

const HOUR_MS: i64 = 3_600_000;
const DAY_MS: i64 = 86_400_000;

/// A time range for filtering and clearing history.
#[derive(Serialize, Deserialize, Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum HistoryRange {
    Hour,
    Today,
    Week,
    Month,
    #[default]
    All,
}

impl HistoryRange {
    /// The inclusive bounds `(start, end)` in Unix milliseconds, or `None` for
    /// all time. The end is one second after `now_ms`, as in Swift.
    /// `local_day_start_ms` is the local start of today, which the caller
    /// computes in the user's time zone.
    pub fn bounds(self, now_ms: i64, local_day_start_ms: i64) -> Option<(i64, i64)> {
        let end = now_ms.saturating_add(1_000);
        let start = match self {
            Self::Hour => now_ms.saturating_sub(HOUR_MS),
            Self::Today => local_day_start_ms,
            Self::Week => now_ms.saturating_sub(7 * DAY_MS),
            Self::Month => now_ms.saturating_sub(28 * DAY_MS),
            Self::All => return None,
        };
        Some((start, end))
    }

    /// The earliest time the range covers (`None`: all time). Clearing a
    /// range removes everything at or after this time.
    pub fn start(self, now_ms: i64, local_day_start_ms: i64) -> Option<i64> {
        self.bounds(now_ms, local_day_start_ms).map(|(start, _)| start)
    }
}

/// A filter over merged history entries: the history page's search field
/// and chips, `cmux history list|search`, the palette's history page.
#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq, Eq)]
pub struct HistoryQuery {
    /// Empty means every kind.
    #[serde(default)]
    pub kinds: Vec<HistoryKind>,
    /// Every whitespace-separated token must appear in the entry's search
    /// text, folded, in any order.
    #[serde(default)]
    pub text: String,
    #[serde(default)]
    pub range: HistoryRange,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit: Option<usize>,
}

impl HistoryQuery {
    /// True when the query selects `kind`.
    pub fn wants(&self, kind: HistoryKind) -> bool {
        self.kinds.is_empty() || self.kinds.contains(&kind)
    }

    /// See [`apply`].
    pub fn apply(
        &self,
        entries: &[HistoryEntry],
        now_ms: i64,
        local_day_start_ms: i64,
        is_directory: impl Fn(&str) -> bool,
    ) -> Vec<HistoryEntry> {
        apply(self, entries, now_ms, local_day_start_ms, is_directory)
    }
}

/// The entries that match `query`, newest first by `(at_ms, id)`, at most
/// `query.limit`. An entry matches when it is displayable, its kind is
/// selected, its time is in the range and every token is in its folded
/// search text. `is_directory` answers whether a local path is a directory;
/// it is called only for `file:` URLs.
pub fn apply(
    query: &HistoryQuery,
    entries: &[HistoryEntry],
    now_ms: i64,
    local_day_start_ms: i64,
    is_directory: impl Fn(&str) -> bool,
) -> Vec<HistoryEntry> {
    let _ = (query, entries, now_ms, local_day_start_ms, is_directory);
    Vec::new()
}

/// True when every folded token is a substring of the folded `haystack`.
/// No tokens match everything.
pub fn matches(haystack: &str, tokens: &[String]) -> bool {
        let _ = (haystack, tokens); true
    }

/// The text the search matches: title, detail and machine, then the kind's
/// own fields (Swift `HistoryEntry.searchText`), joined by spaces.
pub fn search_text(entry: &HistoryEntry) -> String {
        entry.title.clone()
    }

/// False for navigation machinery that is not a destination: a page that is
/// not http, https or file, a directory `file:` URL, a location on a `cmux:`
/// page or `about:blank` or a directory, and the home placeholder location
/// titled `~` (Swift `HistoryQuery.isDisplayable`).
pub fn is_displayable(entry: &HistoryEntry, is_directory: impl Fn(&str) -> bool) -> bool {
        let _ = (entry, is_directory); true
    }

fn is_directory_url(url: &Url, is_directory: &impl Fn(&str) -> bool) -> bool {
    url.to_file_path().is_ok_and(|path| is_directory(&path.to_string_lossy()))
}

#[cfg(test)]
#[path = "query_tests.rs"]
mod tests;
