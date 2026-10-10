//! Command-palette usage history (`palette-usage-v1`,
//! plans/cmux-next/palette-ranking.md section 5.2): which palette rows the
//! user runs, and which rows they run for a typed query start ("learned
//! picks"). One per-user document, personal state of the home session; the
//! daemon is its one writer, the app and the web palette read it. It stays
//! on this Mac: no op sends it anywhere.
//!
//! Each use adds 1 to a row's score, and a score halves every
//! [`HALF_LIFE_MS`]; a learned pick halves every [`PICK_HALF_LIFE_MS`]
//! (habits fade over weeks, plans/cmux-next/palette-ranking.md 5.2). A
//! stored score is the decayed score as of `last_used_ms`; readers decay it
//! to their own clock. The ranking rules that read the history live in the
//! shared ranker (webviews/src/palette/ranker.ts); this module only stores.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// A score halves every three days (the palette's former UserDefaults
/// history used the same half-life, so imported scores keep their meaning).
pub(crate) const HALF_LIFE_MS: u64 = 3 * 24 * 60 * 60 * 1000;
/// A learned pick halves every seven days.
pub(crate) const PICK_HALF_LIFE_MS: u64 = 7 * 24 * 60 * 60 * 1000;
/// Rows kept; the least recently used row goes first beyond this.
pub(crate) const MAX_ENTRIES: usize = 500;
/// Query starts kept for learned picks, and rows kept per query start.
pub(crate) const MAX_PICK_PREFIXES: usize = 512;
pub(crate) const MAX_PICKS_PER_PREFIX: usize = 8;
/// Learned picks are kept for query starts of 1 to this many characters.
pub(crate) const MAX_PICK_PREFIX_CHARS: usize = 8;
/// The longest row key (`action:<id>`, `setting:<id>`, `workspace:<id>`).
pub(crate) const MAX_KEY_CHARS: usize = 512;
/// A row or pick decayed below this is forgotten at the next use (about
/// 20 half-lives: two months for a row, five months for a pick).
pub(crate) const FORGET_BELOW: f64 = 1e-6;
/// Rows that may be hidden at once.
pub(crate) const MAX_HIDDEN: usize = 2048;
/// The largest score an imported row keeps (a damaged former history must
/// not overflow the sum to infinity, which would not serialize).
pub(crate) const MAX_IMPORTED_SCORE: f64 = 1e6;
/// Rows one import may carry.
pub(crate) const MAX_IMPORT_ENTRIES: usize = MAX_ENTRIES;

#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
pub(crate) struct Entry {
    /// The decayed use count as of `last_used_ms`.
    pub(crate) score: f64,
    pub(crate) last_used_ms: u64,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub(crate) struct Document {
    #[serde(default)]
    pub(crate) revision: u64,
    #[serde(default)]
    pub(crate) entries: BTreeMap<String, Entry>,
    /// Normalized query start -> the rows picked for it.
    #[serde(default)]
    pub(crate) picks: BTreeMap<String, Picks>,
    /// Sources already imported, so each imports once.
    #[serde(default)]
    pub(crate) imported: Vec<String>,
    /// Rows the user hid from the palette (shown again only by an explicit show).
    #[serde(default)]
    pub(crate) hidden: std::collections::BTreeSet<String>,
    /// Keys a newer daemon wrote, kept verbatim (L5).
    #[serde(flatten)]
    pub(crate) extra: BTreeMap<String, Value>,
}

/// The rows picked for one query start, and the latest of them.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub(crate) struct Picks {
    #[serde(default)]
    pub(crate) rows: BTreeMap<String, Entry>,
    /// The row picked most recently for this query start.
    #[serde(default)]
    pub(crate) last: String,
}

fn decay(entry: &Entry, now_ms: u64, half_life_ms: u64) -> f64 {
    let elapsed = now_ms.saturating_sub(entry.last_used_ms) as f64;
    entry.score * (-elapsed / half_life_ms as f64).exp2()
}

/// A row's score decayed from `entry.last_used_ms` to `now_ms`.
pub(crate) fn decayed(entry: &Entry, now_ms: u64) -> f64 {
    decay(entry, now_ms, HALF_LIFE_MS)
}

/// A learned pick decayed to `now_ms`.
pub(crate) fn decayed_pick(entry: &Entry, now_ms: u64) -> f64 {
    decay(entry, now_ms, PICK_HALF_LIFE_MS)
}

/// The query as learned picks key it: trimmed, lowercased, inner runs of
/// white space as one space.
pub(crate) fn normalized_query(query: &str) -> String {
    query.split_whitespace().collect::<Vec<_>>().join(" ").to_lowercase()
}

/// The query starts a pick is recorded under: 1 to
/// [`MAX_PICK_PREFIX_CHARS`] characters of the normalized query.
pub(crate) fn pick_prefixes(query: &str) -> Vec<String> {
    let normalized = normalized_query(query);
    let chars: Vec<char> = normalized.chars().collect();
    (1..=chars.len().min(MAX_PICK_PREFIX_CHARS))
        .map(|length| chars[..length].iter().collect::<String>().trim_end().to_string())
        .filter(|prefix| !prefix.is_empty())
        .collect::<std::collections::BTreeSet<_>>()
        .into_iter()
        .collect()
}

fn bump(map: &mut BTreeMap<String, Entry>, key: &str, now_ms: u64, half_life_ms: u64) {
    let score = map.get(key).map(|entry| decay(entry, now_ms, half_life_ms)).unwrap_or(0.0) + 1.0;
    map.insert(key.to_string(), Entry { score, last_used_ms: now_ms });
}

/// Drops the least recently used keys of `map` beyond `limit` (ties: the
/// lower score, then the key).
fn evict<V>(map: &mut BTreeMap<String, V>, limit: usize, last_used: impl Fn(&V) -> (u64, f64)) {
    while map.len() > limit {
        let oldest = map
            .iter()
            .min_by(|(left_key, left), (right_key, right)| {
                let (left_time, left_score) = last_used(left);
                let (right_time, right_score) = last_used(right);
                left_time
                    .cmp(&right_time)
                    .then(left_score.total_cmp(&right_score))
                    .then(left_key.cmp(right_key))
            })
            .map(|(key, _)| key.clone());
        match oldest {
            Some(key) => {
                map.remove(&key);
            }
            None => break,
        }
    }
}

fn newest(picks: &Picks) -> (u64, f64) {
    picks.rows.values().fold((0, 0.0), |(time, score), entry| {
        (time.max(entry.last_used_ms), score.max(entry.score))
    })
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Reject {
    KeyRequired,
    KeyTooLong,
    SourceRequired,
}

impl Reject {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::KeyRequired => "key_required",
            Self::KeyTooLong => "key_too_long",
            Self::SourceRequired => "source_required",
        }
    }
}

fn check_key(key: &str) -> Result<(), Reject> {
    if key.trim().is_empty() {
        return Err(Reject::KeyRequired);
    }
    if key.chars().count() > MAX_KEY_CHARS {
        return Err(Reject::KeyTooLong);
    }
    Ok(())
}

/// One use of row `key` at `now_ms`, run for `query` (empty: picked with no
/// query, so no learned pick).
pub(crate) fn record(
    document: &Document,
    key: &str,
    query: &str,
    now_ms: u64,
) -> Result<Document, Reject> {
    check_key(key)?;
    let mut next = document.clone();
    bump(&mut next.entries, key, now_ms, HALF_LIFE_MS);
    evict(&mut next.entries, MAX_ENTRIES, |entry| (entry.last_used_ms, entry.score));
    next.entries.retain(|_, entry| decayed(entry, now_ms) >= FORGET_BELOW);
    next.picks.retain(|_, picks| {
        picks.rows.retain(|_, entry| decayed_pick(entry, now_ms) >= FORGET_BELOW);
        !picks.rows.is_empty()
    });
    for prefix in pick_prefixes(query) {
        let picks = next.picks.entry(prefix).or_default();
        bump(&mut picks.rows, key, now_ms, PICK_HALF_LIFE_MS);
        evict(&mut picks.rows, MAX_PICKS_PER_PREFIX, |entry| (entry.last_used_ms, entry.score));
        picks.last = key.to_string();
    }
    evict(&mut next.picks, MAX_PICK_PREFIXES, newest);
    next.revision = document.revision + 1;
    Ok(next)
}

/// Hides row `key` from the palette, or shows it again. Hiding an already
/// hidden row (or showing a shown one) changes nothing.
pub(crate) fn set_hidden(document: &Document, key: &str, hidden: bool) -> Result<Document, Reject> {
    check_key(key)?;
    if document.hidden.contains(key) == hidden {
        return Ok(document.clone());
    }
    let mut next = document.clone();
    if hidden {
        insert_bounded(&mut next.hidden, key);
    } else {
        next.hidden.remove(key);
    }
    next.revision = document.revision + 1;
    Ok(next)
}

fn insert_bounded(set: &mut std::collections::BTreeSet<String>, key: &str) {
    if set.len() < MAX_HIDDEN {
        set.insert(key.to_string());
    }
}

/// Reset Ranking: forgets every use and learned pick of row `key`. A row
/// with no history changes nothing.
pub(crate) fn forget(document: &Document, key: &str) -> Result<Document, Reject> {
    check_key(key)?;
    let has_picks = document.picks.values().any(|picks| picks.rows.contains_key(key));
    if !document.entries.contains_key(key) && !has_picks {
        return Ok(document.clone());
    }
    let mut next = document.clone();
    next.entries.remove(key);
    next.picks.retain(|_, picks| {
        picks.rows.remove(key);
        if picks.last == key {
            picks.last = picks
                .rows
                .iter()
                .max_by_key(|(_, entry)| entry.last_used_ms)
                .map(|(row, _)| row.clone())
                .unwrap_or_default();
        }
        !picks.rows.is_empty()
    });
    next.revision = document.revision + 1;
    Ok(next)
}

/// Merges a former history (`source`: where it came from, for example a
/// build's defaults domain; every source is remembered, never evicted, so a
/// source never imports twice) once: each score is decayed to `now_ms` and
/// added to the row's score. A source imported before changes nothing.
/// Invalid keys in `entries` are skipped.
pub(crate) fn import(
    document: &Document,
    source: &str,
    entries: &[(String, Entry)],
    now_ms: u64,
) -> Result<Document, Reject> {
    let source = source.trim();
    if source.is_empty() {
        return Err(Reject::SourceRequired);
    }
    if document.imported.iter().any(|seen| seen == source) {
        return Ok(document.clone());
    }
    let mut next = document.clone();
    for (key, entry) in entries.iter().take(MAX_IMPORT_ENTRIES) {
        if check_key(key).is_err() || !entry.score.is_finite() || entry.score <= 0.0 {
            continue;
        }
        // Both scores decayed to the later use and summed, stored as of that
        // use (an import never makes a row look more recently used).
        let incoming = Entry {
            score: entry.score.min(MAX_IMPORTED_SCORE),
            last_used_ms: entry.last_used_ms.min(now_ms),
        };
        let stored = next.entries.get(key).copied();
        let last_used_ms =
            stored.map_or(0, |stored| stored.last_used_ms).max(incoming.last_used_ms);
        let score = decayed(&incoming, last_used_ms)
            + stored.map_or(0.0, |stored| decayed(&stored, last_used_ms));
        next.entries.insert(key.clone(), Entry { score, last_used_ms });
    }
    evict(&mut next.entries, MAX_ENTRIES, |entry| (entry.last_used_ms, entry.score));
    next.imported.push(source.to_string());
    next.revision = document.revision + 1;
    Ok(next)
}
