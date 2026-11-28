//! The palette model's rules (`PaletteModel` in CmuxNextPalette): what its search, its empty-query
//! rank cache, its keys and its page chrome decide, over row ids and indexes only. The rows
//! themselves (their commands are Swift closures), the providers' reads and the views stay in the
//! app; it asks these ops and applies the answer.
//!
//! Every op is one JSON request through `cmux_palette_ranker_rank` with `"operation":
//! "model.<op>"` ([`call`]), so the C ABI gains no export. Each op's answer is the one the Swift
//! code gave (pinned by `model_tests.rs`).

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, HashSet};

/// The prefix of a model op's `operation`.
pub const OPERATION_PREFIX: &str = "model.";

/// Runs model op `operation` (with its `model.` prefix) on `request` (the whole request JSON).
pub fn call(operation: &str, request: &[u8]) -> Result<Vec<u8>, String> {
    let op = operation.strip_prefix(OPERATION_PREFIX).unwrap_or(operation);
    fn run<Q: for<'de> Deserialize<'de>, A: Serialize>(
        request: &[u8],
        answer: impl FnOnce(Q) -> A,
    ) -> Result<Vec<u8>, String> {
        let parsed: Q = serde_json::from_slice(request).map_err(|error| error.to_string())?;
        serde_json::to_vec(&answer(parsed)).map_err(|error| error.to_string())
    }
    match op {
        "wordHighlights" => {
            run(request, |q: WordHighlightsRequest| word_highlights(&q.title, &q.words))
        }
        "querySections" => run(request, |q: QuerySectionsRequest| query_sections(&q)),
        "unranked" => run(request, |q: UnrankedRequest| unranked(&q)),
        "resolveRank" => run(request, |q: ResolveRankRequest| resolve_rank(&q)),
        "storeEmptyRank" => run(request, |q: StoreEmptyRankRequest| store_empty_rank(&q)),
        "selectionAfterRemoving" => run(request, |q: SelectionAfterRemovingRequest| {
            selection_after_removing(&q.removed, &q.rows)
        }),
        "moveSelection" => run(request, |q: MoveSelectionRequest| move_selection(&q)),
        "moveRail" => run(request, |q: MoveRailRequest| move_rail(q.count, q.index, q.delta)),
        "selectableRows" => run(request, |q: SelectableRowsRequest| {
            selectable_rows(&q.shown, q.navigable.as_deref())
        }),
        "actionsMenuKey" => run(request, |q: ActionsMenuKeyRequest| actions_menu_key(&q)),
        "prefixHints" => run(request, |q: PrefixHintsRequest| prefix_hints(&q)),
        "querySelection" => run(request, |q: QuerySelectionRequest| query_selection(&q)),
        _ => Err(format!("unknown palette model op {operation:?}")),
    }
}

/// Answers `call` as a JSON value (tests and hosts that hold JSON values).
pub fn call_value(request: &Value) -> Result<Value, String> {
    let operation = request.get("operation").and_then(Value::as_str).unwrap_or_default();
    let bytes = serde_json::to_vec(request).map_err(|error| error.to_string())?;
    let answer = call(operation, &bytes)?;
    serde_json::from_slice(&answer).map_err(|error| error.to_string())
}

// MARK: Highlights

#[derive(Debug, Deserialize)]
struct WordHighlightsRequest {
    title: String,
    #[serde(default)]
    words: Vec<String>,
}

/// Scalar offsets of every case-insensitive occurrence of `words` in `title`, ascending. A match
/// steps past itself (no overlapping occurrence of one word). Empty when lowercasing changes the
/// title's scalar count (the offsets would point past it).
pub fn word_highlights(title: &str, words: &[String]) -> Vec<usize> {
    if words.is_empty() {
        return Vec::new();
    }
    let scalars: Vec<char> = title.to_lowercase().chars().collect();
    if scalars.len() != title.chars().count() {
        return Vec::new();
    }
    let mut marked = vec![false; scalars.len()];
    for word in words {
        let needle: Vec<char> = word.to_lowercase().chars().collect();
        if needle.is_empty() || needle.len() > scalars.len() {
            continue;
        }
        let mut start = 0;
        while start + needle.len() <= scalars.len() {
            if scalars[start..start + needle.len()] == needle[..] {
                marked[start..start + needle.len()].iter_mut().for_each(|mark| *mark = true);
                start += needle.len();
            } else {
                start += 1;
            }
        }
    }
    marked.iter().enumerate().filter_map(|(index, mark)| mark.then_some(index)).collect()
}

// MARK: A page's own query results

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct QuerySectionsRequest {
    /// Each item's section id, in item order.
    sections: Vec<String>,
    /// Each item's title (for highlights); absent or short: no highlights.
    #[serde(default)]
    titles: Vec<String>,
    #[serde(default)]
    query: String,
}

/// One section block of a page's own results.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct QuerySection {
    pub section: String,
    pub rows: Vec<QueryRow>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct QueryRow {
    /// The item's index in the request.
    pub index: usize,
    pub highlights: Vec<usize>,
}

/// One block per section, in the order the sections first appear, each item with the query's
/// whitespace-separated words highlighted in its title. Linear in the items.
fn query_sections(request: &QuerySectionsRequest) -> Vec<QuerySection> {
    let words: Vec<String> = request.query.split_whitespace().map(str::to_owned).collect();
    let mut order: Vec<QuerySection> = Vec::new();
    let mut slot: HashMap<&str, usize> = HashMap::new();
    for (index, section) in request.sections.iter().enumerate() {
        let title = request.titles.get(index).map(String::as_str).unwrap_or_default();
        let row = QueryRow { index, highlights: word_highlights(title, &words) };
        let at = *slot.entry(section.as_str()).or_insert_with(|| {
            order.push(QuerySection { section: section.clone(), rows: Vec::new() });
            order.len() - 1
        });
        order[at].rows.push(row);
    }
    order
}

// MARK: The empty query

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct UnrankedEntry {
    #[serde(default = "yes")]
    visible_when_query_empty: bool,
    section_index: i64,
}

fn yes() -> bool {
    true
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct UnrankedRequest {
    entries: Vec<UnrankedEntry>,
    /// Each section's display order, by section index.
    section_orders: Vec<i64>,
    /// How many items the page has (an entry past them is dropped).
    item_count: usize,
}

/// One unranked block: the rows of one section by position.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UnrankedSection {
    pub section_index: usize,
    pub positions: Vec<usize>,
}

/// A page's empty-query rows in provider order, grouped by section, the sections by their order
/// (then index): the first open's rows until its first rank lands. Hidden entries, entries past
/// the items and entries of an unknown section are dropped.
fn unranked(request: &UnrankedRequest) -> Vec<UnrankedSection> {
    let mut rows: HashMap<usize, Vec<usize>> = HashMap::new();
    for (position, entry) in request.entries.iter().enumerate() {
        let Ok(section) = usize::try_from(entry.section_index) else { continue };
        if entry.visible_when_query_empty
            && position < request.item_count
            && section < request.section_orders.len()
        {
            rows.entry(section).or_default().push(position);
        }
    }
    let mut sections: Vec<usize> = rows.keys().copied().collect();
    sections.sort_by_key(|&index| (request.section_orders[index], index));
    sections
        .into_iter()
        .map(|section_index| UnrankedSection {
            section_index,
            positions: rows.remove(&section_index).unwrap_or_default(),
        })
        .collect()
}

#[derive(Debug, Deserialize)]
struct RankRow {
    id: String,
    #[serde(default)]
    score: i64,
    #[serde(default)]
    highlights: Vec<usize>,
}

#[derive(Debug, Deserialize)]
struct RankSection {
    section: Value,
    rows: Vec<RankRow>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ResolveRankRequest {
    /// A kept rank's sections, rows by stable id.
    sections: Vec<RankSection>,
    /// The page's item ids now, by position.
    ids: Vec<String>,
}

/// A kept rank's section on a page's rows now.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ResolvedSection {
    pub section: Value,
    pub rows: Vec<ResolvedRow>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ResolvedRow {
    /// The row's position among the page's items now.
    pub position: usize,
    pub score: i64,
    pub highlights: Vec<usize>,
}

/// The ranked rows the page still has, by id, at their positions now. Rows the page no longer
/// has drop, and a section left with none drops; rows it gained wait for the next rank. Of
/// two items with one id, the last one answers.
fn resolve_rank(request: &ResolveRankRequest) -> Vec<ResolvedSection> {
    let positions: HashMap<&str, usize> =
        request.ids.iter().enumerate().map(|(position, id)| (id.as_str(), position)).collect();
    request
        .sections
        .iter()
        .filter_map(|section| {
            let rows: Vec<ResolvedRow> = section
                .rows
                .iter()
                .filter_map(|row| {
                    positions.get(row.id.as_str()).map(|&position| ResolvedRow {
                        position,
                        score: row.score,
                        highlights: row.highlights.clone(),
                    })
                })
                .collect();
            (!rows.is_empty()).then(|| ResolvedSection { section: section.section.clone(), rows })
        })
        .collect()
}

/// How many pages keep their last empty-query rank.
pub const EMPTY_RANK_PAGE_LIMIT: usize = 4;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct StoreEmptyRankRequest {
    /// The kept pages' ids, oldest first.
    order: Vec<String>,
    page_id: String,
    limit: Option<usize>,
}

/// The kept pages after one more rank is kept.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct StoredEmptyRanks {
    /// Oldest first; the stored page last.
    pub order: Vec<String>,
    /// The pages whose rank is no longer kept.
    pub evicted: Vec<String>,
}

/// Keeps `page_id`'s rank as the newest; the oldest pages past the limit drop.
fn store_empty_rank(request: &StoreEmptyRankRequest) -> StoredEmptyRanks {
    let limit = request.limit.unwrap_or(EMPTY_RANK_PAGE_LIMIT);
    let mut order: Vec<String> =
        request.order.iter().filter(|id| **id != request.page_id).cloned().collect();
    order.push(request.page_id.clone());
    let cut = order.len().saturating_sub(limit);
    let evicted = order.drain(..cut).collect();
    StoredEmptyRanks { order, evicted }
}

// MARK: Selection

#[derive(Debug, Deserialize)]
pub struct PlacedRow {
    pub id: String,
    pub section: String,
}

#[derive(Debug, Deserialize)]
struct SelectionAfterRemovingRequest {
    removed: String,
    rows: Vec<PlacedRow>,
}

/// The row to select after `removed` leaves `rows`: the next row of its section, else the
/// previous row of its section, else none (repeated Cmd-W never walks into another section).
pub fn selection_after_removing(removed: &str, rows: &[PlacedRow]) -> Option<String> {
    let index = rows.iter().position(|row| row.id == removed)?;
    let section = &rows[index].section;
    if let Some(next) = rows.get(index + 1).filter(|row| row.section == *section) {
        return Some(next.id.clone());
    }
    index
        .checked_sub(1)
        .map(|before| &rows[before])
        .filter(|row| row.section == *section)
        .map(|row| row.id.clone())
}

/// Page Up and Page Down move this many rows.
pub const PAGE_STEP: i64 = 8;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct MoveSelectionRequest {
    count: i64,
    /// The selected row's index, absent or -1 when none is selected.
    current: Option<i64>,
    delta: i64,
    #[serde(default)]
    wrap: bool,
}

/// The index a move of `delta` from the selection lands on (clamped, or wrapped). None for no
/// rows: the host still sends the move (an empty-list key is explicit navigation).
fn move_selection(request: &MoveSelectionRequest) -> Option<i64> {
    if request.count <= 0 {
        return None;
    }
    let next = request.current.unwrap_or(-1) + request.delta;
    Some(if request.wrap {
        next.rem_euclid(request.count)
    } else {
        next.clamp(0, request.count - 1)
    })
}

#[derive(Debug, Deserialize)]
struct MoveRailRequest {
    count: i64,
    /// The chosen entry's index (0, All, when none matches).
    index: i64,
    delta: i64,
}

/// The rail entry `delta` steps from `index`, no wrap. None when no rail shows.
pub fn move_rail(count: i64, index: i64, delta: i64) -> Option<i64> {
    (count > 0).then(|| (index + delta).clamp(0, count - 1))
}

#[derive(Debug, Deserialize)]
struct SelectableRowsRequest {
    /// The rows on screen, by id.
    shown: Vec<String>,
    /// The rows the navigation state holds; absent with no level.
    navigable: Option<Vec<String>>,
}

/// The indexes of the shown rows navigation may select: every one with no level or when all
/// are navigable, else only those it holds (never an older query's answer still shown).
pub fn selectable_rows(shown: &[String], navigable: Option<&[String]>) -> Vec<usize> {
    let Some(navigable) = navigable else { return (0..shown.len()).collect() };
    let ids: HashSet<&str> = navigable.iter().map(String::as_str).collect();
    (0..shown.len()).filter(|&index| ids.contains(shown[index].as_str())).collect()
}

// MARK: The Actions menu

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ActionsMenuKeyRequest {
    /// The menu's visible command count before the key.
    count: i64,
    selected_index: i64,
    #[serde(default)]
    filter: String,
    /// The key command's name (`PaletteKeyCommand`): moveUp, moveDown, moveToFirst, pageUp,
    /// moveToLast, pageDown, submit, submitAlternate, toggleActions, closeActions, escape,
    /// openActions, enterRow, leaveLevel, back, closeItem, actionsFilterAppend,
    /// actionsFilterDeleteBackward.
    key: String,
    /// The typed text of actionsFilterAppend.
    #[serde(default)]
    text: String,
}

/// What a key does with the Actions menu open.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ActionsMenuKey {
    /// `update` (the menu stays with `selectedIndex` and `filter`), `close`, `run` (the command
    /// at `selectedIndex`, which the host still checks), `closeItem` (Cmd-W), `none` (consumed,
    /// no change) or `pass` (not consumed: the field takes it).
    pub outcome: &'static str,
    pub selected_index: i64,
    pub filter: String,
}

/// The Actions menu's key rules: arrows wrap, first/last and page keys jump, Return runs, Escape
/// and the toggle close, typing filters (back to the first command), Backspace on an empty
/// filter closes.
fn actions_menu_key(request: &ActionsMenuKeyRequest) -> ActionsMenuKey {
    let count = request.count;
    let keep = |outcome: &'static str| ActionsMenuKey {
        outcome,
        selected_index: request.selected_index,
        filter: request.filter.clone(),
    };
    let update = |selected_index: i64, filter: String| ActionsMenuKey {
        outcome: "update",
        selected_index,
        filter,
    };
    match request.key.as_str() {
        "moveUp" | "moveDown" => {
            if count <= 0 {
                return keep("none");
            }
            let delta = if request.key == "moveUp" { -1 } else { 1 };
            update(
                (request.selected_index + delta + count).rem_euclid(count),
                request.filter.clone(),
            )
        }
        "moveToFirst" | "pageUp" => update(0, request.filter.clone()),
        "moveToLast" | "pageDown" => update((count - 1).max(0), request.filter.clone()),
        "submit" | "submitAlternate" => keep("run"),
        "toggleActions" | "closeActions" | "escape" => keep("close"),
        "back" => keep("pass"),
        "closeItem" => keep("closeItem"),
        "actionsFilterAppend" => update(0, format!("{}{}", request.filter, request.text)),
        "actionsFilterDeleteBackward" => {
            let mut filter = request.filter.clone();
            if filter.pop().is_none() {
                return keep("close");
            }
            update(0, filter)
        }
        _ => keep("none"),
    }
}

// MARK: Page chrome

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct HintScope {
    id: String,
    prefix: Option<String>,
    title: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PrefixHintsRequest {
    /// The root's child scopes, in graph order.
    scopes: Vec<HintScope>,
    /// The title the all-scopes scope's hint shows.
    all_scopes_title: String,
    /// The all-scopes scope's id.
    #[serde(default = "scopes_id")]
    all_scopes_id: String,
}

fn scopes_id() -> String {
    "scopes".to_owned()
}

/// "@ Tabs   # Workspaces   > Commands   ? All Scopes": each root child with a prefix, three
/// spaces apart. None when no child has one.
fn prefix_hints(request: &PrefixHintsRequest) -> Option<String> {
    let hints: Vec<String> = request
        .scopes
        .iter()
        .filter_map(|scope| {
            let prefix = scope.prefix.as_deref()?;
            let title = if scope.id == request.all_scopes_id {
                &request.all_scopes_title
            } else {
                &scope.title
            };
            Some(format!("{prefix} {title}"))
        })
        .collect();
    (!hints.is_empty()).then(|| hints.join("   "))
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct QuerySelectionRequest {
    /// The page is a text step.
    #[serde(default)]
    text_input: bool,
    /// The text step's initial text, or the list page's initial query.
    #[serde(default)]
    initial: String,
    /// The query the page shows.
    #[serde(default)]
    query: String,
    /// A list page's `initialQuerySelection`.
    initial_query_selection: Option<i64>,
}

/// Whether the field selects its text as a page shows, and how much of it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QuerySelection {
    pub selects_query: bool,
    /// UTF-16 units from the start; None selects all.
    pub selected_query_length: Option<i64>,
}

/// A text step that shows its initial text selects all of it (typing replaces a rename's name);
/// a list page that shows its initial query selects the length it names; else nothing.
fn query_selection(request: &QuerySelectionRequest) -> QuerySelection {
    let shows_initial = !request.initial.is_empty() && request.query == request.initial;
    if request.text_input {
        return QuerySelection { selects_query: shows_initial, selected_query_length: None };
    }
    match request.initial_query_selection {
        Some(length) if shows_initial => {
            QuerySelection { selects_query: true, selected_query_length: Some(length) }
        }
        _ => QuerySelection { selects_query: false, selected_query_length: None },
    }
}

#[cfg(test)]
#[path = "model_tests.rs"]
mod tests;
