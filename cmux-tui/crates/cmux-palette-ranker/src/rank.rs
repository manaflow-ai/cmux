//! Ranking: the typed query and the empty query, learned picks, frecency and aliases.

use crate::shortcut::{self, Stroke};
use crate::text::Query;
use crate::text::{collapsed_lower, is_lu, js_string_cmp, js_trim, js_trim_end};
use crate::tier::{
    self, DEMOTION, Field, MAXIMUM_QUALITY, TIER_SCALE, entry_tier, highlights_for, match_quality,
    match_tier, title_is,
};
use crate::{
    Entry, Frecency, RankAnswer, RankRequest, RankedRow, RankedSection, TYPO_PASS_THRESHOLD,
};
use std::collections::{HashMap, HashSet};

/// Below every enabled row of any tier.
const DISABLED_PENALTY: i64 = 100_000;
const MAXIMUM_BOOST: i64 = 60;
const DEFAULT_HALF_LIFE: f64 = 3.0 * 24.0 * 60.0 * 60.0;
/// A row picked at least this often (decayed) for the query's longest known start lifts,
const LIFT_PICKS: f64 = 2.0;
/// or the latest pick for that start while at least this much of it is left.
const LIFT_LATEST_PICK: f64 = 0.5;
/// Learned picks are kept for query starts of at most this many characters (the daemon's bound).
const PICK_PREFIX_CHARS: usize = 8;
const DEFAULT_PICK_HALF_LIFE: f64 = 7.0 * 24.0 * 60.0 * 60.0;
/// Suggested rows the empty query shows at most.
const SUGGESTION_LIMIT: usize = 5;

/// The prepared text of a set of entries: fields and folded action ids.
pub(crate) struct Prepared {
    pub fields: Vec<Vec<Field>>,
    pub ids: Vec<Option<Vec<char>>>,
    /// Each row's shortcut strokes, from its keycaps.
    pub shortcuts: Vec<Option<Vec<Stroke>>>,
    /// Each row's handles, lowercased.
    pub handles: Vec<Vec<String>>,
    /// Each row's own aliases, spacing collapsed and lowercased.
    pub aliases: Vec<Vec<String>>,
    /// The rows each own alias names, in catalog order, so a keystroke looks up the rows its
    /// query names instead of walking every row.
    pub alias_rows: HashMap<String, Vec<usize>>,
    /// The rows of each action id, in catalog order (a user alias names its action's rows).
    pub action_rows: HashMap<String, Vec<usize>>,
    /// Some row has a query prefix or hides while typing.
    pub gated: bool,
    /// The rows of each title's whole key, for the whole-title tier.
    pub title_rows: HashMap<String, Vec<usize>>,
    /// The scope rows of each keyword's whole key, for the scope-keyword tier.
    pub scope_rows: HashMap<String, Vec<usize>>,
    /// The rows of each handle, and of each handle's digits after its letters (`612`).
    pub handle_rows: HashMap<String, Vec<usize>>,
    pub handle_number_rows: HashMap<String, Vec<usize>>,
    /// The rows with an action id, ordered by their folded id, then row.
    pub id_order: Vec<usize>,
    /// The rows with shortcut keycaps.
    pub shortcut_rows: Vec<usize>,
}

/// Appends `index` to `key`'s rows in `map`, once.
fn index_row(map: &mut HashMap<String, Vec<usize>>, key: &str, index: usize) {
    if key.is_empty() {
        return;
    }
    let rows = map.entry(key.to_owned()).or_default();
    if rows.last() != Some(&index) {
        rows.push(index);
    }
}

impl Prepared {
    pub(crate) fn new(entries: &[Entry]) -> Self {
        let mut prepared = Self {
            fields: entries.iter().map(tier::fields_for).collect(),
            ids: entries
                .iter()
                .map(|entry| {
                    entry
                        .action_id
                        .as_deref()
                        .filter(|id| !id.is_empty())
                        .map(|id| id.chars().map(crate::text::fold_scalar).collect())
                })
                .collect(),
            shortcuts: entries
                .iter()
                .map(|entry| shortcut::parse_keycaps(&entry.keycaps))
                .collect(),
            handles: entries
                .iter()
                .map(|entry| {
                    entry
                        .handles
                        .iter()
                        .map(|handle| js_trim(handle).to_lowercase())
                        .filter(|handle| !handle.is_empty())
                        .collect()
                })
                .collect(),
            aliases: entries
                .iter()
                .map(|entry| {
                    entry
                        .aliases
                        .iter()
                        .map(|alias| collapsed_lower(alias))
                        .filter(|alias| !alias.is_empty())
                        .collect()
                })
                .collect(),
            alias_rows: HashMap::new(),
            action_rows: HashMap::new(),
            gated: entries
                .iter()
                .any(|entry| entry.query_prefix.is_some() || entry.hides_when_typing == Some(true)),
            title_rows: HashMap::new(),
            scope_rows: HashMap::new(),
            handle_rows: HashMap::new(),
            handle_number_rows: HashMap::new(),
            id_order: Vec::new(),
            shortcut_rows: Vec::new(),
        };
        for (index, entry) in entries.iter().enumerate() {
            if let Some(title) = prepared.fields.get(index).and_then(|fields| fields.first()) {
                index_row(&mut prepared.title_rows, &title.whole, index);
            }
            if entry.enters_scope == Some(true) {
                for keyword in &entry.keywords {
                    index_row(&mut prepared.scope_rows, &crate::text::whole_key(keyword), index);
                }
            }
            for handle in prepared.handles.get(index).into_iter().flatten() {
                index_row(&mut prepared.handle_rows, handle, index);
                let number = handle.trim_start_matches(char::is_alphabetic);
                if number.len() < handle.len() {
                    index_row(&mut prepared.handle_number_rows, number, index);
                }
            }
            if prepared.ids.get(index).is_some_and(Option::is_some) {
                prepared.id_order.push(index);
            }
            if prepared.shortcuts.get(index).is_some_and(Option::is_some) {
                prepared.shortcut_rows.push(index);
            }
        }
        let ids = &prepared.ids;
        let id_of = |index: usize| ids.get(index).and_then(Option::as_deref).unwrap_or_default();
        prepared.id_order.sort_by(|&a, &b| id_of(a).cmp(id_of(b)).then(a.cmp(&b)));
        for (index, aliases) in prepared.aliases.iter().enumerate() {
            for alias in aliases {
                let rows = prepared.alias_rows.entry(alias.clone()).or_default();
                if rows.last() != Some(&index) {
                    rows.push(index);
                }
            }
        }
        for (index, entry) in entries.iter().enumerate() {
            if let Some(id) = entry.action_id.as_deref() {
                prepared.action_rows.entry(id.to_owned()).or_default().push(index);
            }
        }
        prepared
    }

    /// The rows a query may match through what it names rather than through text a shorter
    /// query matched: a whole title or scope keyword, a handle, an action id. Sorted, once each.
    fn named_rows(&self, query: &Query, handle_query: &str) -> Vec<usize> {
        let mut rows: Vec<usize> = Vec::new();
        let mut add = |map: &HashMap<String, Vec<usize>>, key: &str| {
            rows.extend(map.get(key).into_iter().flatten());
        };
        if !query.whole.is_empty() {
            add(&self.title_rows, &query.whole);
            add(&self.scope_rows, &query.whole);
        }
        // `names_handle`'s queries: one word, the whole handle or a handle's digits.
        if !handle_query.is_empty() && !handle_query.chars().any(char::is_whitespace) {
            add(&self.handle_rows, handle_query);
            if handle_query.chars().all(|c| c.is_ascii_digit()) {
                add(&self.handle_number_rows, handle_query);
            }
        }
        // `action_id_tier`'s queries: one word of 4+ letters that is an id, or starts one and
        // is written like an id.
        if query.tokens.len() == 1 && query.joined.len() >= 4 {
            let raw = js_trim(&query.raw);
            let starts_count = raw.contains('.') || raw.chars().any(is_lu);
            let id_of =
                |index: usize| self.ids.get(index).and_then(Option::as_deref).unwrap_or_default();
            let first =
                self.id_order.partition_point(|&index| id_of(index) < query.joined.as_slice());
            // Ids that start with the query follow `first` in order, the query itself first.
            for &index in self.id_order.get(first..).unwrap_or_default() {
                let id = id_of(index);
                if !id.starts_with(&query.joined)
                    || (!starts_count && id.len() != query.joined.len())
                {
                    break;
                }
                rows.push(index);
            }
        }
        rows.sort_unstable();
        rows.dedup();
        rows
    }
}

/// How many narrowed queries a ranker keeps: a backspace returns to the one it extends.
const STEPS_KEPT: usize = 32;

/// The candidate rows of recent queries, newest last, each query extending the one before.
#[derive(Default)]
struct Steps(Vec<Step>);

struct Step {
    tokens: Vec<Vec<char>>,
    /// Sorted rows, every row the query or one that extends it can match.
    rows: Vec<usize>,
}

/// Whether `query` extends `shorter`: the same tokens but the last, which `query`'s token at
/// that place starts with, and maybe more tokens after it. Typing on, pasting onto the end or a
/// trailing space extend a query; a backspace or an edit before the end does not.
fn extends(shorter: &[Vec<char>], query: &[Vec<char>]) -> bool {
    let Some((last, before)) = shorter.split_last() else { return false };
    query.get(..before.len()) == Some(before)
        && query.get(before.len()).is_some_and(|token| token.starts_with(last))
}

impl Steps {
    /// The rows of the newest kept query that `tokens` extends; the newer ones it does not
    /// extend are dropped.
    fn base(&mut self, tokens: &[Vec<char>]) -> Option<&[usize]> {
        while self.0.last().is_some_and(|step| !extends(&step.tokens, tokens)) {
            self.0.pop();
        }
        self.0.last().map(|step| step.rows.as_slice())
    }

    /// Keeps `rows` for `tokens`, which extend the newest kept query ([`Steps::base`] first).
    fn push(&mut self, tokens: &[Vec<char>], rows: Vec<usize>) {
        if self.0.last().is_some_and(|step| step.tokens == tokens) {
            self.0.pop();
        }
        if self.0.len() >= STEPS_KEPT {
            self.0.remove(0);
        }
        self.0.push(Step { tokens: tokens.to_vec(), rows });
    }
}

/// What a ranker remembers between keystrokes so a keystroke that extends the query scores only
/// the rows the shorter query could still lead to, not every row.
///
/// Why the narrowed rows are every row the longer query can match:
/// - The strict pass keeps each row that matched (any tier) or may stem-match
///   ([`tier::may_stem_match`]). Every tier but four implies each token is a title, keyword,
///   subtitle or accessory match on its own (the substring tier's test), and a start of such a
///   token still is, so a longer query matches by them only rows the shorter one matched. A
///   stem match needs every token's head to start a title word, which holds for a start of the
///   token too. The four others, a whole title or scope keyword, a handle and an action id, the
///   query names: their rows come from prepared maps every keystroke ([`Prepared::named_rows`]).
/// - The typo pass keeps each row that may typo-match ([`tier::may_typo_match`]), whose test a
///   start of a token passes whenever the token does, and adds the strict rows and named rows.
///   It is kept only when a keystroke runs the typo pass, and extends from the newest typo step
///   the query extends.
#[derive(Default)]
pub(crate) struct Narrowing {
    strict: Steps,
    typo: Steps,
}

/// Merges two sorted lists of rows, each row once.
fn merged(a: &[usize], b: &[usize]) -> Vec<usize> {
    let mut rows = Vec::with_capacity(a.len() + b.len());
    let (mut a, mut b) = (a.iter().copied().peekable(), b.iter().copied().peekable());
    loop {
        let next = match (a.peek().copied(), b.peek().copied()) {
            (Some(x), Some(y)) if x == y => {
                b.next();
                a.next()
            }
            (Some(x), Some(y)) if x < y => a.next(),
            (_, Some(_)) => b.next(),
            (Some(_), None) => a.next(),
            (None, None) => None,
        };
        let Some(next) = next else { break };
        rows.push(next);
    }
    rows
}

/// The rows a pass scores, in catalog order: every row, or a narrowed list.
enum Candidates {
    All(usize),
    Rows(Vec<usize>),
}

impl Candidates {
    fn iter(&self) -> impl Iterator<Item = usize> + '_ {
        let (all, rows) = match self {
            Candidates::All(count) => (0..*count, &[][..]),
            Candidates::Rows(rows) => (0..0, rows.as_slice()),
        };
        all.chain(rows.iter().copied())
    }
}

/// `title.to_lowercase().starts_with(prefix)` without lowercasing the whole title.
fn lowercase_starts_with(title: &str, prefix: &str) -> bool {
    // A capital sigma lowercases by its context; only the whole-string lowercase knows it.
    if title.contains('\u{3a3}') {
        return title.to_lowercase().starts_with(prefix);
    }
    let mut lowered = title.chars().flat_map(char::to_lowercase);
    prefix.chars().all(|scalar| lowered.next() == Some(scalar))
}

/// Whether `query` (trimmed, lowercased, one word) names one of `handles`: the whole handle
/// (`a612`), or, for an all-digit query, the handle's digits after its letters (`612`).
fn names_handle(handles: &[String], query: &str) -> bool {
    if query.is_empty() || query.chars().any(char::is_whitespace) {
        return false;
    }
    let digits = query.chars().all(|c| c.is_ascii_digit());
    handles.iter().any(|handle| {
        handle == query
            || (digits && {
                let number = handle.trim_start_matches(char::is_alphabetic);
                number.len() < handle.len() && number == query
            })
    })
}

fn row(index: usize) -> RankedRow {
    RankedRow { index, score: 0, highlights: Vec::new() }
}

fn frecency_score(store: Option<&Frecency>, key: Option<&str>, now: f64) -> f64 {
    let (Some(store), Some(key)) = (store, key.filter(|key| !key.is_empty())) else { return 0.0 };
    let Some(entry) = store.entries.as_ref().and_then(|entries| entries.get(key)) else {
        return 0.0;
    };
    let half_life = store.half_life.unwrap_or(DEFAULT_HALF_LIFE);
    let elapsed = (now - entry.last_used).max(0.0);
    entry.score * 2f64.powf(-elapsed / half_life)
}

fn frecency_boost(store: Option<&Frecency>, key: Option<&str>, now: f64) -> i64 {
    let score = frecency_score(store, key, now);
    if score <= 0.01 {
        return 0;
    }
    MAXIMUM_BOOST.min((18.0 * (1.0 + score).log2()).round() as i64)
}

fn top_frecency_keys(store: Option<&Frecency>, limit: usize, now: f64) -> Vec<String> {
    let Some(entries) = store.and_then(|store| store.entries.as_ref()) else { return Vec::new() };
    let mut scored: Vec<(&String, f64)> = entries
        .keys()
        .map(|key| (key, frecency_score(store, Some(key), now)))
        .filter(|(_, score)| *score >= 0.05)
        .collect();
    scored.sort_by(|a, b| {
        b.1.partial_cmp(&a.1)
            .filter(|order| order.is_ne())
            .unwrap_or_else(|| js_string_cmp(a.0, b.0))
    });
    scored.into_iter().take(limit).map(|(key, _)| key.clone()).collect()
}

/// The rows that may lift for `raw`, strongest first.
fn lift_candidates(store: Option<&Frecency>, raw: &str, now: f64) -> Vec<String> {
    let Some(picks) =
        store.and_then(|store| store.picks.as_ref()).filter(|picks| !picks.is_empty())
    else {
        return Vec::new();
    };
    let chars: Vec<char> = collapsed_lower(raw).chars().collect();
    let half_life = store.and_then(|store| store.pick_half_life).unwrap_or(DEFAULT_PICK_HALF_LIFE);
    for length in (1..=chars.len().min(PICK_PREFIX_CHARS)).rev() {
        let start: String = chars[..length].iter().collect();
        let prefix = js_trim_end(&start);
        let mut rows: Vec<(&crate::LearnedPick, f64)> = picks
            .iter()
            .filter(|pick| pick.prefix == prefix)
            .map(|pick| {
                (pick, pick.score * 2f64.powf(-(now - pick.last_used).max(0.0) / half_life))
            })
            .collect();
        if rows.is_empty() {
            continue;
        }
        rows.retain(|(pick, score)| {
            *score >= LIFT_PICKS || (pick.last && *score >= LIFT_LATEST_PICK)
        });
        rows.sort_by(|a, b| {
            b.1.partial_cmp(&a.1)
                .filter(|order| order.is_ne())
                .unwrap_or_else(|| js_string_cmp(&a.0.key, &b.0.key))
        });
        return rows.into_iter().map(|(pick, _)| pick.key.clone()).collect();
    }
    Vec::new()
}

fn section_order(sections: &mut [i64], orders: &[i64]) {
    let order_of = |section: i64| {
        usize::try_from(section)
            .ok()
            .and_then(|index| orders.get(index))
            .map_or(f64::INFINITY, |&order| order as f64)
    };
    sections.sort_by(|&a, &b| {
        let (left, right) = (order_of(a), order_of(b));
        if left != right { left.total_cmp(&right) } else { a.cmp(&b) }
    });
}

/// The action ids whose user alias is the whole query.
fn aliased_actions(aliases: Option<&HashMap<String, Vec<String>>>, raw: &str) -> HashSet<String> {
    let mut ids = HashSet::new();
    let Some(aliases) = aliases else { return ids };
    let query = collapsed_lower(raw);
    if query.is_empty() {
        return ids;
    }
    for (id, words) in aliases {
        if words.iter().any(|word| collapsed_lower(word) == query) {
            ids.insert(id.clone());
        }
    }
    ids
}

fn group(
    items: impl Iterator<Item = (i64, RankedRow)>,
) -> (Vec<i64>, HashMap<i64, Vec<RankedRow>>) {
    let mut order = Vec::new();
    let mut rows_by_section: HashMap<i64, Vec<RankedRow>> = HashMap::new();
    for (section, ranked) in items {
        rows_by_section
            .entry(section)
            .or_insert_with(|| {
                order.push(section);
                Vec::new()
            })
            .push(ranked);
    }
    (order, rows_by_section)
}

fn sections_of(
    order: Vec<i64>,
    mut rows_by_section: HashMap<i64, Vec<RankedRow>>,
) -> Vec<RankedSection> {
    order
        .into_iter()
        .map(|section| RankedSection {
            section_index: Some(section),
            rows: rows_by_section.remove(&section).unwrap_or_default(),
        })
        .collect()
}

pub(crate) fn rank_empty(
    request: &RankRequest,
    entries: &[Entry],
    store: Option<&Frecency>,
) -> Vec<RankedSection> {
    let hidden: HashSet<&str> = store
        .and_then(|store| store.hidden.as_ref())
        .map(|hidden| hidden.iter().map(String::as_str).collect())
        .unwrap_or_default();
    let is_hidden =
        |entry: &Entry| entry.frecency_key.as_deref().is_some_and(|key| hidden.contains(key));
    let now = request.now.unwrap_or(0.0);
    let recent_limit = request.recent_limit.unwrap_or(5);
    let shows_recent = request.shows_recent == Some(true);
    let mut recent: HashSet<usize> = HashSet::new();
    let mut sections = Vec::new();
    // Pinned: the user's pins in their order, first, even when hidden, disabled or kept out of the
    // empty query.
    if shows_recent && let Some(pins) = request.pins.as_ref().filter(|pins| !pins.is_empty()) {
        let mut position_by_action: HashMap<&str, usize> = HashMap::new();
        for (index, entry) in entries.iter().enumerate() {
            if let Some(id) = entry.action_id.as_deref().filter(|id| !id.is_empty()) {
                position_by_action.entry(id).or_insert(index);
            }
        }
        let mut seen = HashSet::new();
        let rows: Vec<RankedRow> = pins
            .iter()
            .filter(|id| seen.insert(id.as_str()))
            .filter_map(|id| position_by_action.get(id.as_str()).copied())
            .map(row)
            .collect();
        if !rows.is_empty() {
            recent.extend(rows.iter().map(|ranked| ranked.index));
            sections.push(RankedSection { section_index: request.pinned_section_index, rows });
        }
    }
    let has_entries =
        store.and_then(|store| store.entries.as_ref()).is_some_and(|entries| !entries.is_empty());
    if shows_recent && recent_limit > 0 && has_entries {
        let mut position_by_key: HashMap<&str, usize> = HashMap::new();
        for (index, entry) in entries.iter().enumerate() {
            let Some(key) = entry.frecency_key.as_deref().filter(|key| !key.is_empty()) else {
                continue;
            };
            if entry.is_enabled.unwrap_or(true) && entry.query_prefix.is_none() && !is_hidden(entry)
            {
                position_by_key.entry(key).or_insert(index);
            }
        }
        let limit = usize::try_from(recent_limit).unwrap_or(0);
        let rows: Vec<RankedRow> = top_frecency_keys(store, limit.saturating_mul(3), now)
            .iter()
            .filter_map(|key| position_by_key.get(key.as_str()).copied())
            .filter(|index| !recent.contains(index))
            .take(limit)
            .map(row)
            .collect();
        if !rows.is_empty() {
            recent.extend(rows.iter().map(|ranked| ranked.index));
            sections.push(RankedSection { section_index: None, rows });
        }
    }
    // Suggested: the catalog's first-use commands in its order, after Recent.
    let mut suggested: Vec<(usize, &Entry)> = entries
        .iter()
        .enumerate()
        .filter(|(index, entry)| {
            entry.suggested_rank.is_some()
                && entry.suggested_section_index.is_some()
                && entry.is_enabled.unwrap_or(true)
                && entry.is_visible_when_query_empty.unwrap_or(true)
                && !recent.contains(index)
                && !is_hidden(entry)
        })
        .collect();
    suggested.sort_by(|a, b| a.1.suggested_rank.cmp(&b.1.suggested_rank).then(a.0.cmp(&b.0)));
    suggested.truncate(SUGGESTION_LIMIT);
    if shows_recent && !suggested.is_empty() {
        sections.push(RankedSection {
            section_index: suggested[0].1.suggested_section_index,
            rows: suggested.iter().map(|(index, _)| row(*index)).collect(),
        });
        recent.extend(suggested.iter().map(|(index, _)| *index));
    }
    let (mut order, rows_by_section) =
        group(entries.iter().enumerate().filter_map(|(index, entry)| {
            let visible = entry.is_visible_when_query_empty.unwrap_or(true)
                && !recent.contains(&index)
                && !is_hidden(entry);
            visible.then(|| (entry.section_index.unwrap_or(0), row(index)))
        }));
    section_order(&mut order, request.section_orders.as_deref().unwrap_or_default());
    sections.extend(sections_of(order, rows_by_section));
    sections
}

/// Every row `keeps` keeps, for a filter with no words (`in:tabs`): in section order, each
/// section's most used rows first, then provider order; at most `limit` rows. Rows the user hid
/// stay out, as on the empty query.
pub(crate) fn rank_kept(
    request: &RankRequest,
    entries: &[Entry],
    store: Option<&Frecency>,
    keeps: impl Fn(&Entry) -> bool,
    limit: usize,
) -> Vec<RankedSection> {
    let hidden: HashSet<&str> = store
        .and_then(|store| store.hidden.as_ref())
        .map(|hidden| hidden.iter().map(String::as_str).collect())
        .unwrap_or_default();
    let now = request.now.unwrap_or(0.0);
    let mut kept: Vec<(usize, f64)> = entries
        .iter()
        .enumerate()
        .filter(|(_, entry)| {
            keeps(entry) && !entry.frecency_key.as_deref().is_some_and(|key| hidden.contains(key))
        })
        .map(|(index, entry)| (index, frecency_score(store, entry.frecency_key.as_deref(), now)))
        .collect();
    kept.sort_by(|a, b| b.1.total_cmp(&a.1).then(a.0.cmp(&b.0)));
    let (mut order, mut rows_by_section) = group(kept.into_iter().map(|(index, _)| {
        let entry = &entries[index];
        (entry.typing_section_index.or(entry.section_index).unwrap_or(0), row(index))
    }));
    section_order(&mut order, request.section_orders.as_deref().unwrap_or_default());
    let mut left = limit;
    for section in &order {
        if let Some(rows) = rows_by_section.get_mut(section) {
            rows.truncate(left);
            left -= rows.len();
        }
    }
    order.retain(|section| rows_by_section.get(section).is_some_and(|rows| !rows.is_empty()));
    sections_of(order, rows_by_section)
}

struct Scored {
    index: usize,
    score: i64,
    tier: i64,
    enabled: bool,
    demoted: bool,
    /// A demoted row whose whole title is the query.
    exact_name: bool,
    shortcut: bool,
    /// The query names this row's shortcut ("cmd i" for ⌘I): first among enabled rows after the
    /// user's own aliases.
    chord: bool,
    lifted: bool,
    aliased: bool,
    /// The query is one of the row's handles: first of all enabled rows.
    handle: bool,
    /// The title starts with the trimmed, lowercased query (read by `ranks_prefix_first`).
    starts: bool,
    /// The query the row's highlights are measured with, found only for the rows that show.
    highlight: Highlight,
}

/// Which query a row's title highlights follow.
enum Highlight {
    None,
    Original,
    /// A typo or stem row: the corrected query.
    Corrected(Query),
}

fn shown_while_typing(entry: &Entry, gated: bool, raw: &str) -> bool {
    if gated && entry.hides_when_typing == Some(true) {
        return false;
    }
    !(gated && entry.query_prefix.as_deref().is_some_and(|prefix| !raw.starts_with(prefix)))
}

pub(crate) fn rank(
    request: &RankRequest,
    entries: &[Entry],
    prepared: &Prepared,
    store: Option<&Frecency>,
    mut narrowing: Option<&mut Narrowing>,
    work: &mut usize,
) -> RankAnswer {
    let raw = request.query.as_deref().unwrap_or("");
    let query = Query::new(raw);
    if query.is_empty() {
        return RankAnswer { sections: rank_empty(request, entries, store), strict_matches: 0 };
    }
    let now = request.now.unwrap_or(0.0);
    let gated = prepared.gated;
    let hidden: HashSet<&str> = store
        .and_then(|store| store.hidden.as_ref())
        .map(|hidden| hidden.iter().map(String::as_str).collect())
        .unwrap_or_default();
    let aliased = aliased_actions(request.aliases.as_ref(), raw);
    // A row's own alias (the catalog's) names it as the user's alias does.
    let alias_query = collapsed_lower(raw);
    let names_alias = |index: usize, entry: &Entry| {
        entry.action_id.as_ref().is_some_and(|id| aliased.contains(id))
            || prepared.aliases.get(index).is_some_and(|aliases| aliases.contains(&alias_query))
    };
    // A query that may name a row's handle (`a612`, `612`).
    let handle_query = js_trim(raw).to_lowercase();
    // A query that names a shortcut ("cmd i", "⌥⇧K"); plain words parse to nothing.
    let chord = shortcut::parse_query(raw);
    let names_shortcut = |index: usize| {
        chord.as_deref().is_some_and(|chord| {
            prepared.shortcuts[index].as_deref().is_some_and(|row| shortcut::matches(chord, row))
        })
    };
    let mut scored: Vec<Scored> = Vec::new();
    // Scores `rows`; with `keep`, also collects the rows a query extending this one may match in
    // this pass (see `Narrowing`).
    let rank_pass = |allows_typo: bool,
                     rows: &Candidates,
                     scored: &mut Vec<Scored>,
                     mut keep: Option<&mut Vec<usize>>| {
        let (mut strong, mut visited) = (0, 0);
        for index in rows.iter() {
            let Some(entry) = entries.get(index) else { continue };
            visited += 1;
            if !shown_while_typing(entry, gated, raw) {
                // Hidden for this query, not by its text: a longer one may show it.
                if let Some(keep) = keep.as_deref_mut() {
                    keep.push(index);
                }
                continue;
            }
            let Some(fields) = prepared.fields.get(index) else { continue };
            let handle = prepared
                .handles
                .get(index)
                .is_some_and(|handles| names_handle(handles, &handle_query));
            let id = prepared.ids.get(index).and_then(Option::as_deref);
            let found = entry_tier(entry, id, &query, fields, allows_typo);
            if let Some(keep) = keep.as_deref_mut()
                && (found.is_some()
                    || if allows_typo {
                        tier::may_typo_match(&query, fields)
                    } else {
                        tier::may_stem_match(&query, fields)
                    })
            {
                keep.push(index);
            }
            let (found, highlighted) = match found {
                Some(found) => (found, true),
                None if handle => (
                    tier::TierMatch {
                        tier: match_tier::HANDLE,
                        query: tier::QueryRef::Original(&query),
                    },
                    false,
                ),
                None => continue,
            };
            let tier_reached = if handle { match_tier::HANDLE } else { found.tier };
            let key = entry.frecency_key.as_deref().filter(|key| !key.is_empty());
            if key.is_some_and(|key| hidden.contains(key)) && !handle && !title_is(fields, &query) {
                continue;
            }
            // Whole-title rows tie on quality, so the provider order decides.
            let quality = if handle
                || (found.tier >= match_tier::WHOLE_TITLE - 1 && title_is(fields, &query))
            {
                MAXIMUM_QUALITY
            } else {
                match_quality(found.query.get(), fields)
            };
            if found.tier >= match_tier::SUBSTRING {
                strong += 1;
            }
            let enabled = entry.is_enabled != Some(false);
            // Saturating: an extreme rank bias must not wrap (or panic) the score.
            let mut score = (tier_reached * TIER_SCALE + quality)
                .saturating_add(entry.rank_bias.unwrap_or(0))
                .saturating_add(frecency_boost(store, key, now));
            if !enabled {
                score = score.saturating_sub(DISABLED_PENALTY);
            }
            let highlight = match (highlighted, found.query) {
                (false, _) => Highlight::None,
                (true, tier::QueryRef::Original(_)) => Highlight::Original,
                (true, tier::QueryRef::Corrected(corrected)) => Highlight::Corrected(corrected),
            };
            scored.push(Scored {
                index,
                score,
                tier: tier_reached,
                enabled,
                demoted: entry.demoted == Some(true),
                exact_name: entry.demoted == Some(true) && title_is(fields, &query),
                shortcut: entry.has_shortcut == Some(true),
                chord: names_shortcut(index),
                lifted: false,
                aliased: enabled && names_alias(index, entry),
                handle: enabled && handle,
                starts: false,
                highlight,
            });
        }
        (strong, visited)
    };
    // The rows this query names, which no shorter query's matches need hold.
    let named_rows =
        if narrowing.is_some() { prepared.named_rows(&query, &handle_query) } else { Vec::new() };
    let all = || Candidates::All(entries.len());
    let strict_rows = match narrowing.as_deref_mut().and_then(|n| n.strict.base(&query.tokens)) {
        Some(base) => Candidates::Rows(merged(base, &named_rows)),
        None => all(),
    };
    let mut kept = narrowing.is_some().then(Vec::new);
    let (strict_matches, visited) = rank_pass(false, &strict_rows, &mut scored, kept.as_mut());
    *work += visited;
    if request.typo_pass.unwrap_or(strict_matches < TYPO_PASS_THRESHOLD) {
        scored.clear();
        match narrowing.as_deref_mut() {
            Some(narrowing) => {
                let may_typo = |index: &usize| {
                    prepared
                        .fields
                        .get(*index)
                        .is_some_and(|fields| tier::may_typo_match(&query, fields))
                };
                let typos = match narrowing.typo.base(&query.tokens) {
                    // Only the shorter query's typo rows may typo-match, with this query's strict
                    // and named rows.
                    Some(base) => {
                        *work += base.len();
                        let typos: Vec<usize> = base.iter().copied().filter(may_typo).collect();
                        let strict = kept.as_deref().unwrap_or_default();
                        let rows = merged(&merged(strict, &typos), &named_rows);
                        *work += rank_pass(true, &Candidates::Rows(rows), &mut scored, None).1;
                        typos
                    }
                    // No typo pass to extend: every row, keeping the rows that may typo-match.
                    None => {
                        let mut typos = Vec::new();
                        *work += rank_pass(true, &all(), &mut scored, Some(&mut typos)).1;
                        typos
                    }
                };
                narrowing.typo.push(&query.tokens, typos);
            }
            None => *work += rank_pass(true, &all(), &mut scored, None).1,
        }
    }
    if let (Some(narrowing), Some(kept)) = (narrowing, kept) {
        narrowing.strict.push(&query.tokens, kept);
    }
    // The strongest learned pick for this query that still matches it goes first.
    let candidates = lift_candidates(store, raw, now);
    // A few candidates, each found by one walk of the matched rows: no map of every match.
    if let Some(position) = candidates.iter().filter(|key| !key.is_empty()).find_map(|key| {
        scored.iter().position(|item| {
            item.enabled && entries[item.index].frecency_key.as_deref() == Some(key.as_str())
        })
    }) {
        scored[position].lifted = true;
    }
    // An alias (the user's or the row's own) names its row, even when the query matches none of
    // its text. One row per action id.
    // Only the rows an alias names are candidates: the query's own-alias rows and the rows of
    // the actions the user's aliases name, in catalog order.
    let mut named: Vec<usize> = prepared.alias_rows.get(&alias_query).cloned().unwrap_or_default();
    for id in &aliased {
        named.extend(prepared.action_rows.get(id).into_iter().flatten());
    }
    named.sort_unstable();
    named.dedup();
    if !named.is_empty() {
        // Which of the named rows, and of their action ids, the matches already hold: sets as
        // large as the named rows, not as every match.
        let named_rows: HashSet<usize> = named.iter().copied().collect();
        let named_ids: HashSet<&str> = named
            .iter()
            .filter_map(|&index| entries.get(index)?.action_id.as_deref())
            .filter(|id| !id.is_empty())
            .collect();
        let mut present: HashSet<&str> = HashSet::new();
        let mut present_rows: HashSet<usize> = HashSet::new();
        for item in &scored {
            if named_rows.contains(&item.index) {
                present_rows.insert(item.index);
            }
            if let Some(id) = entries.get(item.index).and_then(|entry| entry.action_id.as_deref())
                && let Some(&id) = named_ids.get(id)
            {
                present.insert(id);
            }
        }
        for index in named {
            let Some(entry) = entries.get(index) else { continue };
            let id = entry.action_id.as_deref().filter(|id| !id.is_empty());
            if !names_alias(index, entry)
                || present_rows.contains(&index)
                || id.is_some_and(|id| present.contains(id))
                || entry.is_enabled == Some(false)
            {
                continue;
            }
            if !shown_while_typing(entry, gated, raw) {
                continue;
            }
            // A row the user hid stays hidden unless the user's own alias names it.
            if !id.is_some_and(|id| aliased.contains(id))
                && entry.frecency_key.as_deref().is_some_and(|key| hidden.contains(key))
            {
                continue;
            }
            present.extend(id);
            present_rows.insert(index);
            scored.push(Scored {
                index,
                score: 0,
                tier: 0,
                enabled: true,
                demoted: entry.demoted == Some(true),
                exact_name: false,
                shortcut: entry.has_shortcut == Some(true),
                chord: names_shortcut(index),
                lifted: false,
                aliased: true,
                handle: false,
                starts: false,
                highlight: Highlight::None,
            });
        }
    }
    // The row bound to the shortcut the query names, even when the query matches none of its text.
    if chord.is_some() {
        let present: HashSet<usize> = scored.iter().map(|item| item.index).collect();
        // Only rows with keycaps name a shortcut.
        for &index in &prepared.shortcut_rows {
            let Some(entry) = entries.get(index) else { continue };
            if present.contains(&index)
                || !names_shortcut(index)
                || !shown_while_typing(entry, gated, raw)
            {
                continue;
            }
            if entry.frecency_key.as_deref().is_some_and(|key| hidden.contains(key)) {
                continue;
            }
            let enabled = entry.is_enabled != Some(false);
            scored.push(Scored {
                index,
                score: if enabled { 0 } else { -DISABLED_PENALTY },
                tier: 0,
                enabled,
                demoted: entry.demoted == Some(true),
                exact_name: false,
                shortcut: true,
                chord: true,
                lifted: false,
                aliased: false,
                handle: false,
                starts: false,
                highlight: Highlight::None,
            });
        }
    }
    // A setting whose whole title is the query, and the only one, keeps the whole-title tier.
    let exact: Vec<usize> =
        scored.iter().enumerate().filter(|(_, item)| item.exact_name).map(|(at, _)| at).collect();
    if let [only] = exact.as_slice() {
        scored[*only].tier += DEMOTION;
        scored[*only].score = scored[*only].score.saturating_add(DEMOTION * TIER_SCALE);
    }
    let row_limit = usize::try_from(request.row_limit.unwrap_or(400)).unwrap_or(0);
    let highlight_limit = usize::try_from(request.highlight_limit.unwrap_or(60)).unwrap_or(0);
    type Order = fn(&Scored, &Scored) -> std::cmp::Ordering;
    let order: Order = if request.ranks_prefix_first == Some(true) {
        let prefix = js_trim(raw).to_lowercase();
        for item in &mut scored {
            item.starts = lowercase_starts_with(&entries[item.index].title, &prefix);
        }
        |left, right| {
            right
                .handle
                .cmp(&left.handle)
                .then(right.aliased.cmp(&left.aliased))
                .then((right.chord && right.enabled).cmp(&(left.chord && left.enabled)))
                .then(right.starts.cmp(&left.starts))
                .then_with(|| {
                    if left.starts {
                        left.index.cmp(&right.index)
                    } else {
                        right.score.cmp(&left.score).then(left.index.cmp(&right.index))
                    }
                })
        }
    } else {
        |left, right| {
            right
                .enabled
                .cmp(&left.enabled)
                .then(right.handle.cmp(&left.handle))
                .then(right.aliased.cmp(&left.aliased))
                .then(right.chord.cmp(&left.chord))
                .then(right.lifted.cmp(&left.lifted))
                .then(right.tier.cmp(&left.tier))
                .then(left.demoted.cmp(&right.demoted))
                .then(right.score.cmp(&left.score))
                .then(right.shortcut.cmp(&left.shortcut))
                .then(left.index.cmp(&right.index))
        }
    };
    // Every order ends on the row index, unique per row, so it is total: selecting the first
    // `row_limit` rows and sorting only those gives the same rows as sorting every match.
    if scored.len() > row_limit {
        scored.select_nth_unstable_by(row_limit, order);
        scored.truncate(row_limit);
    }
    scored.sort_unstable_by(order);
    let (mut order, rows_by_section) = group(scored.into_iter().enumerate().map(|(rank, item)| {
        let entry = &entries[item.index];
        let section = entry.typing_section_index.or(entry.section_index).unwrap_or(0);
        // Highlights only for the rows that show them.
        let highlights = match (
            &item.highlight,
            prepared.fields.get(item.index).and_then(|fields| fields.first()),
        ) {
            (_, None) | (Highlight::None, _) => Vec::new(),
            _ if rank >= highlight_limit => Vec::new(),
            (Highlight::Original, Some(title)) => highlights_for(&query, &title.text),
            (Highlight::Corrected(corrected), Some(title)) => {
                highlights_for(corrected, &title.text)
            }
        };
        (section, RankedRow { index: item.index, score: item.score, highlights })
    }));
    if request.keeps_section_order == Some(true) {
        section_order(&mut order, request.section_orders.as_deref().unwrap_or_default());
    }
    RankAnswer { sections: sections_of(order, rows_by_section), strict_matches }
}
