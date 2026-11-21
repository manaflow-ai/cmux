//! The shared command-palette ranker.
//!
//! One implementation of the palette's match tiers, typo correction, user
//! aliases and pins, learned picks and frecency, so every host (the macOS
//! app over the C ABI in [`ffi`], browser pages and other frontends) ranks a
//! query the same way. It began as a 1:1 port of the TypeScript ranker it
//! replaced (deleted since): the same scores, the same order and the same
//! JSON request and response shapes. The checked-in corpus (`tests/corpus/`)
//! holds that ranker's answers and the behavior test replays it through the
//! C ABI.
//!
//! Known differences, all on input the app never sends or for the better:
//! lowercasing here uses no locale, where JavaScriptCore's
//! `toLocaleLowerCase` followed the system locale (a Turkish, Azeri or
//! Lithuanian locale lowercased "I" to a dotless "ı", so "find in file" did
//! not equal the title "Find In File"); a frecency key named like an
//! `Object.prototype` member, a zero half-life, negative limits or section
//! indexes and fractional integers gave NaN or JavaScript-only results there.

pub mod ffi;
pub mod filter;
mod rank;
mod shortcut;
mod text;
mod tier;

use serde::{Deserialize, Deserializer, Serialize};
use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Mutex, PoisonError};

fn null_as_default<'de, D, T>(deserializer: D) -> Result<T, D::Error>
where
    D: Deserializer<'de>,
    T: Default + Deserialize<'de>,
{
    Ok(Option::<T>::deserialize(deserializer)?.unwrap_or_default())
}

/// One palette row as the ranker reads it (`PaletteRankEntry`).
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    pub title: String,
    #[serde(default, deserialize_with = "null_as_default")]
    pub keywords: Vec<String>,
    pub subtitle: Option<String>,
    pub accessory: Option<String>,
    pub rank_bias: Option<i64>,
    pub frecency_key: Option<String>,
    pub is_enabled: Option<bool>,
    pub is_visible_when_query_empty: Option<bool>,
    pub query_prefix: Option<String>,
    pub hides_when_typing: Option<bool>,
    pub section_index: Option<i64>,
    /// The row enters a palette scope.
    pub enters_scope: Option<bool>,
    /// The section the row joins while the user types.
    pub typing_section_index: Option<i64>,
    /// The catalog's first-use suggestion order, if any.
    pub suggested_rank: Option<i64>,
    /// The section a suggested row shows in on the empty query.
    pub suggested_section_index: Option<i64>,
    /// The registry action id; found only by a query that is the id or starts it (4+ letters).
    #[serde(rename = "actionID")]
    pub action_id: Option<String>,
    /// A row of a secondary kind (a setting): one tier lower than a command with the same match.
    pub demoted: Option<bool>,
    /// The row has a keyboard shortcut: first among equal matches.
    pub has_shortcut: Option<bool>,
    /// The keycaps the row shows for its live shortcut (`["⇧", "⌘", "P"]`): a query that names
    /// this shortcut ("cmd shift p", "⇧⌘P") ranks the row first.
    #[serde(default, deserialize_with = "null_as_default")]
    pub keycaps: Vec<String>,
    /// Short ids the row is known by (a Chief subagent's workspace: `a612`). A query that is one
    /// of them, or its digits (`612`), ranks the row first, above every text match.
    #[serde(default, deserialize_with = "null_as_default")]
    pub handles: Vec<String>,
    /// Phrases that name this row (the catalog's built-in aliases, `palette::ALIASES`): a query
    /// that is one of them, ignoring case and spacing, ranks the row like the user's own
    /// `palette.aliases` match does, first among enabled rows after a handle.
    #[serde(default, deserialize_with = "null_as_default")]
    pub aliases: Vec<String>,
}

/// One frecency record.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FrecencyEntry {
    pub score: f64,
    pub last_used: f64,
}

/// A learned pick: the row the user ran for a normalized query start (palette-usage-v1).
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LearnedPick {
    pub prefix: String,
    pub key: String,
    /// Decayed pick count as of `last_used`; halves every `pick_half_life`.
    pub score: f64,
    pub last_used: f64,
    /// The latest row picked for `prefix`.
    pub last: bool,
}

/// The usage the ranker reads (`PaletteFrecency`).
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Frecency {
    pub entries: Option<HashMap<String, FrecencyEntry>>,
    pub half_life: Option<f64>,
    pub picks: Option<Vec<LearnedPick>>,
    pub pick_half_life: Option<f64>,
    /// Usage keys of rows the user hid.
    pub hidden: Option<Vec<String>>,
}

/// One rank request (`PaletteRankRequest`). `entries` is absent when the ranker already holds
/// this `version`'s entries ([`Ranker::install`]).
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RankRequest {
    /// `rank` or `rankEmpty`.
    #[serde(default)]
    pub operation: String,
    pub entries: Option<Vec<Entry>>,
    pub version: Option<i64>,
    pub query: Option<String>,
    pub section_orders: Option<Vec<i64>>,
    /// The usage history for this request. Absent with `history_revision`: the ranker reads the
    /// history installed for that revision ([`Ranker::install_history`]).
    pub frecency: Option<Frecency>,
    /// The revision of the installed history to rank with when `frecency` is absent, so a
    /// keystroke does not send (and parse) the whole history again.
    pub history_revision: Option<i64>,
    pub now: Option<f64>,
    pub shows_recent: Option<bool>,
    pub keeps_section_order: Option<bool>,
    pub ranks_prefix_first: Option<bool>,
    pub recent_limit: Option<i64>,
    /// The user's aliases (cmux.json `palette.aliases`): action id to words.
    pub aliases: Option<HashMap<String, Vec<String>>>,
    /// The user's pinned action ids (cmux.json `palette.pins`), first on the empty query.
    pub pins: Option<Vec<String>>,
    /// The section the pinned rows show in.
    pub pinned_section_index: Option<i64>,
    pub row_limit: Option<i64>,
    pub highlight_limit: Option<i64>,
    /// Whether a typed query also ranks one-edit typos: absent, only when the strict pass found
    /// fewer than [`TYPO_PASS_THRESHOLD`] rows at the substring tier or better; false never; true
    /// always. A host that ranks one catalog in several requests (each within a size cap) ranks
    /// them all strictly, sums their [`RankAnswer::strict_matches`], and ranks them again with
    /// true when that sum is below the threshold, so they decide the pass as one request would.
    /// (Rust only: the TypeScript ranker has no such field.)
    pub typo_pass: Option<bool>,
    /// The page's section names, one list (title, id) per section index. With them, filter
    /// tokens in the query (`in:tabs`, `-in:history`, [`filter`]) keep or drop sections' rows.
    /// (Rust only.)
    pub section_names: Option<Vec<Vec<String>>>,
}

/// The typo pass runs only when the strict pass found fewer rows than this at the substring tier
/// or better (see [`RankRequest::typo_pass`]).
pub const TYPO_PASS_THRESHOLD: usize = 3;

/// One request's answer and the count a host needs to merge several requests' answers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RankAnswer {
    pub sections: Vec<RankedSection>,
    /// Rows the strict pass matched at the substring tier or better (0 for the empty query).
    pub strict_matches: usize,
}

/// One ranked row by entry index.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct RankedRow {
    pub index: usize,
    pub score: i64,
    /// Scalar offsets into the entry title that matched.
    pub highlights: Vec<usize>,
}

/// A group of ranked rows. `section_index` none is the Recent section.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RankedSection {
    pub section_index: Option<i64>,
    pub rows: Vec<RankedRow>,
}

/// Why a request could not be ranked.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RankError {
    /// The request has no entries and the ranker holds none for its version.
    NotInstalled(Option<i64>),
    /// The request names a history revision the ranker does not hold.
    HistoryNotInstalled(i64),
}

impl std::fmt::Display for RankError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RankError::NotInstalled(Some(version)) => {
                write!(f, "palette ranker: no entries installed for version {version}")
            }
            RankError::NotInstalled(None) => {
                write!(f, "palette ranker: no entries installed for version undefined")
            }
            RankError::HistoryNotInstalled(revision) => {
                write!(f, "palette ranker: no history installed for revision {revision}")
            }
        }
    }
}

impl std::error::Error for RankError {}

struct Installed {
    version: i64,
    entries: Vec<Entry>,
    prepared: rank::Prepared,
    /// The candidate rows of the latest queries, so a keystroke that extends the query scores
    /// only the rows the shorter query could still lead to.
    narrowing: Mutex<rank::Narrowing>,
}

/// A ranker that holds one snapshot of entries and one usage history, so a keystroke sends
/// only its query.
#[derive(Default)]
pub struct Ranker {
    installed: Option<Installed>,
    history: Option<(i64, Frecency)>,
    /// Rows scored since the ranker was made ([`Ranker::rows_scored`]).
    rows_scored: AtomicUsize,
}

impl Ranker {
    pub fn new() -> Self {
        Self::default()
    }

    /// Holds `entries` for `version`; later requests for that version carry no entries.
    pub fn install(&mut self, version: i64, entries: Vec<Entry>) {
        let prepared = rank::Prepared::new(&entries);
        self.installed =
            Some(Installed { version, entries, prepared, narrowing: Mutex::default() });
    }

    /// Holds `history` for `revision`; later requests name the revision and carry no history.
    pub fn install_history(&mut self, revision: i64, history: Frecency) {
        self.history = Some((revision, history));
    }

    /// Ranks one request: its own entries, or the installed ones of its version, with its own
    /// history, or the installed one of its history revision.
    ///
    /// A keystroke that extends the installed entries' previous query scores only the rows that
    /// query could still lead to ([`rank::Narrowing`]); the answer is the same.
    pub fn rank(&self, request: &RankRequest) -> Result<Vec<RankedSection>, RankError> {
        self.rank_with(request, true)
    }

    /// [`Ranker::rank`] with every row scored again: the reference a keystroke's answer must
    /// equal.
    pub fn rank_full(&self, request: &RankRequest) -> Result<Vec<RankedSection>, RankError> {
        self.rank_with(request, false)
    }

    /// The rows this ranker has scored (matched against a query) since it was made: the work a
    /// keystroke costs, counted rather than timed.
    pub fn rows_scored(&self) -> usize {
        self.rows_scored.load(Ordering::Relaxed)
    }

    fn rank_with(
        &self,
        request: &RankRequest,
        narrows: bool,
    ) -> Result<Vec<RankedSection>, RankError> {
        let mut work = 0;
        let answer = self.answer(request, narrows, &mut work);
        self.rows_scored.fetch_add(work, Ordering::Relaxed);
        answer
    }

    fn answer(
        &self,
        request: &RankRequest,
        narrows: bool,
        work: &mut usize,
    ) -> Result<Vec<RankedSection>, RankError> {
        let store = match (request.frecency.as_ref(), request.history_revision) {
            (Some(frecency), _) => Some(frecency),
            (None, Some(revision)) => match &self.history {
                Some((installed, history)) if *installed == revision => Some(history),
                _ => return Err(RankError::HistoryNotInstalled(revision)),
            },
            (None, None) => None,
        };
        if let Some(entries) = request.entries.as_deref() {
            return Ok(rank_entries(request, entries, None, store, None, work).sections);
        }
        match &self.installed {
            Some(installed) if Some(installed.version) == request.version => {
                // A panic mid-keystroke leaves every kept step whole (a step is kept only once
                // complete), so a poisoned lock is still sound.
                let mut narrowing = narrows
                    .then(|| installed.narrowing.lock().unwrap_or_else(PoisonError::into_inner));
                Ok(rank_entries(
                    request,
                    &installed.entries,
                    Some(&installed.prepared),
                    store,
                    narrowing.as_deref_mut(),
                    work,
                )
                .sections)
            }
            _ => Err(RankError::NotInstalled(request.version)),
        }
    }
}

fn rank_entries(
    request: &RankRequest,
    entries: &[Entry],
    prepared: Option<&rank::Prepared>,
    store: Option<&Frecency>,
    narrowing: Option<&mut rank::Narrowing>,
    work: &mut usize,
) -> RankAnswer {
    if request.operation != "rankEmpty"
        && let Some(names) = request.section_names.as_deref()
    {
        let parsed = filter::parse(request.query.as_deref().unwrap_or(""), names);
        if parsed.applied {
            return rank_filtered(request, &parsed, entries, prepared, store, narrowing, work);
        }
    }
    if request.operation == "rankEmpty" {
        return RankAnswer {
            sections: rank::rank_empty(request, entries, store),
            strict_matches: 0,
        };
    }
    match prepared {
        Some(prepared) => rank::rank(request, entries, prepared, store, narrowing, work),
        None => rank::rank(request, entries, &rank::Prepared::new(entries), store, None, work),
    }
}

/// A request without its entries and history (passed beside it), its query `query`.
fn narrowed_request(request: &RankRequest, query: String, row_limit: Option<i64>) -> RankRequest {
    RankRequest {
        operation: request.operation.clone(),
        entries: None,
        version: request.version,
        query: Some(query),
        section_orders: request.section_orders.clone(),
        frecency: None,
        history_revision: request.history_revision,
        now: request.now,
        shows_recent: request.shows_recent,
        keeps_section_order: request.keeps_section_order,
        ranks_prefix_first: request.ranks_prefix_first,
        recent_limit: request.recent_limit,
        aliases: request.aliases.clone(),
        pins: request.pins.clone(),
        pinned_section_index: request.pinned_section_index,
        row_limit,
        highlight_limit: request.highlight_limit,
        typo_pass: request.typo_pass,
        section_names: None,
    }
}

/// Keeps at most `limit` rows across `sections`, in order, and drops the emptied sections.
fn keep_rows(
    sections: Vec<RankedSection>,
    limit: usize,
    keeps: impl Fn(&RankedRow) -> bool,
) -> Vec<RankedSection> {
    let mut left = limit;
    sections
        .into_iter()
        .filter_map(|mut section| {
            section.rows.retain(&keeps);
            section.rows.truncate(left);
            left -= section.rows.len();
            (!section.rows.is_empty()).then_some(section)
        })
        .collect()
}

/// Ranks a query with filter tokens ([`filter`]): the rest of the query over the rows the
/// filter keeps. With no rest (`in:tabs` alone), every kept row, most used first, so a filter
/// alone lists its kind.
fn rank_filtered(
    request: &RankRequest,
    parsed: &filter::QueryFilter,
    entries: &[Entry],
    prepared: Option<&rank::Prepared>,
    store: Option<&Frecency>,
    narrowing: Option<&mut rank::Narrowing>,
    work: &mut usize,
) -> RankAnswer {
    let row_limit = usize::try_from(request.row_limit.unwrap_or(400)).unwrap_or(0);
    if parsed.rest.trim().is_empty() {
        let sections = if parsed.restricts() {
            rank::rank_kept(request, entries, store, |entry| parsed.allows_entry(entry), row_limit)
        } else {
            rank::rank_empty(request, entries, store)
        };
        return RankAnswer { sections, strict_matches: 0 };
    }
    // Every match, so the filter keeps up to `row_limit` rows of the kept sections.
    let every =
        i64::try_from(entries.len()).unwrap_or(i64::MAX).max(request.row_limit.unwrap_or(400));
    let inner = narrowed_request(request, parsed.rest.clone(), Some(every));
    let answer = match prepared {
        Some(prepared) => rank::rank(&inner, entries, prepared, store, narrowing, work),
        None => rank::rank(&inner, entries, &rank::Prepared::new(entries), store, None, work),
    };
    let sections = keep_rows(answer.sections, row_limit, |row| {
        entries.get(row.index).is_some_and(|entry| parsed.allows_entry(entry))
    });
    RankAnswer { sections, strict_matches: answer.strict_matches }
}

/// Ranks a request that carries its own entries and history.
pub fn rank_request(request: &RankRequest) -> Vec<RankedSection> {
    rank_request_answer(request).sections
}

/// [`rank_request`] with the strict match count.
pub fn rank_request_answer(request: &RankRequest) -> RankAnswer {
    rank_entries(
        request,
        request.entries.as_deref().unwrap_or_default(),
        None,
        request.frecency.as_ref(),
        None,
        &mut 0,
    )
}
