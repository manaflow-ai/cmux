//! The shared command-palette ranker.
//!
//! One implementation of the palette's match tiers, typo correction, user
//! aliases and pins, learned picks and frecency, so every host (the macOS
//! app over the C ABI in [`ffi`], browser pages and other frontends) ranks a
//! query the same way. It is a 1:1 port of the TypeScript ranker
//! (`webviews/src/palette/ranker.ts`): the same scores, the same order and
//! the same JSON request and response shapes. The checked-in corpus
//! (`tests/corpus/`) holds that ranker's answers and the behavior test
//! replays it through the C ABI.
//!
//! Known differences, all on input the app never sends or for the better:
//! lowercasing here uses no locale, where JavaScriptCore's
//! `toLocaleLowerCase` followed the system locale (a Turkish, Azeri or
//! Lithuanian locale lowercased "I" to a dotless "ı", so "find in file" did
//! not equal the title "Find In File"); a frecency key named like an
//! `Object.prototype` member, a zero half-life, negative limits or section
//! indexes and fractional integers gave NaN or JavaScript-only results there.

pub mod ffi;
mod rank;
mod shortcut;
mod text;
mod tier;

use serde::{Deserialize, Deserializer, Serialize};
use std::collections::HashMap;

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
    pub frecency: Option<Frecency>,
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
        }
    }
}

impl std::error::Error for RankError {}

struct Installed {
    version: i64,
    entries: Vec<Entry>,
    prepared: rank::Prepared,
}

/// A ranker that holds one snapshot of entries, so a keystroke sends only its query.
#[derive(Default)]
pub struct Ranker {
    installed: Option<Installed>,
}

impl Ranker {
    pub fn new() -> Self {
        Self::default()
    }

    /// Holds `entries` for `version`; later requests for that version carry no entries.
    pub fn install(&mut self, version: i64, entries: Vec<Entry>) {
        let prepared = rank::Prepared::new(&entries);
        self.installed = Some(Installed { version, entries, prepared });
    }

    /// Ranks one request: its own entries, or the installed ones of its version.
    pub fn rank(&self, request: &RankRequest) -> Result<Vec<RankedSection>, RankError> {
        if let Some(entries) = request.entries.as_deref() {
            return Ok(rank_entries(request, entries, None));
        }
        match &self.installed {
            Some(installed) if Some(installed.version) == request.version => {
                Ok(rank_entries(request, &installed.entries, Some(&installed.prepared)))
            }
            _ => Err(RankError::NotInstalled(request.version)),
        }
    }
}

fn rank_entries(
    request: &RankRequest,
    entries: &[Entry],
    prepared: Option<&rank::Prepared>,
) -> Vec<RankedSection> {
    if request.operation == "rankEmpty" {
        return rank::rank_empty(request, entries);
    }
    match prepared {
        Some(prepared) => rank::rank(request, entries, prepared),
        None => rank::rank(request, entries, &rank::Prepared::new(entries)),
    }
}

/// Ranks a request that carries its own entries.
pub fn rank_request(request: &RankRequest) -> Vec<RankedSection> {
    rank_entries(request, request.entries.as_deref().unwrap_or_default(), None)
}
