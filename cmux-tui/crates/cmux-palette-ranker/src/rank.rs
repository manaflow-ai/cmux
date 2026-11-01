//! Ranking: the typed query and the empty query, learned picks, frecency and aliases.

use crate::shortcut::{self, Stroke};
use crate::text::Query;
use crate::text::{collapsed_lower, js_string_cmp, js_trim, js_trim_end, title_is_query};
use crate::tier::{
    self, DEMOTION, Field, MAXIMUM_QUALITY, TIER_SCALE, entry_tier, highlights_for, match_quality,
    match_tier,
};
use crate::{Entry, Frecency, RankRequest, RankedRow, RankedSection};
use std::collections::{HashMap, HashSet};

/// Below every enabled row of any tier.
const DISABLED_PENALTY: i64 = 100_000;
const MAXIMUM_BOOST: i64 = 60;
const DEFAULT_HALF_LIFE: f64 = 3.0 * 24.0 * 60.0 * 60.0;
/// The typo pass runs only when the strict pass found fewer rows than this at the substring tier
/// or better.
const TYPO_PASS_THRESHOLD: usize = 3;
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
}

impl Prepared {
    pub(crate) fn new(entries: &[Entry]) -> Self {
        Self {
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
        }
    }
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

pub(crate) fn rank_empty(request: &RankRequest, entries: &[Entry]) -> Vec<RankedSection> {
    let store = request.frecency.as_ref();
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
    highlights: Vec<usize>,
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
) -> Vec<RankedSection> {
    let raw = request.query.as_deref().unwrap_or("");
    let query = Query::new(raw);
    if query.is_empty() {
        return rank_empty(request, entries);
    }
    let store = request.frecency.as_ref();
    let now = request.now.unwrap_or(0.0);
    let gated = entries
        .iter()
        .any(|entry| entry.query_prefix.is_some() || entry.hides_when_typing == Some(true));
    let hidden: HashSet<&str> = store
        .and_then(|store| store.hidden.as_ref())
        .map(|hidden| hidden.iter().map(String::as_str).collect())
        .unwrap_or_default();
    let aliased = aliased_actions(request.aliases.as_ref(), raw);
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
    let rank_pass = |allows_typo: bool, scored: &mut Vec<Scored>| {
        let mut strong = 0;
        for (index, entry) in entries.iter().enumerate() {
            if !shown_while_typing(entry, gated, raw) {
                continue;
            }
            let Some(fields) = prepared.fields.get(index) else { continue };
            let handle = prepared
                .handles
                .get(index)
                .is_some_and(|handles| names_handle(handles, &handle_query));
            let found =
                entry_tier(entry, prepared.ids[index].as_deref(), &query, fields, allows_typo);
            let (found, highlights) = match found {
                Some(found) => {
                    let highlights = fields
                        .first()
                        .map(|field| highlights_for(found.query.get(), &field.text))
                        .unwrap_or_default();
                    (found, highlights)
                }
                None if handle => (
                    tier::TierMatch {
                        tier: match_tier::HANDLE,
                        query: tier::QueryRef::Original(&query),
                    },
                    Vec::new(),
                ),
                None => continue,
            };
            let tier_reached = if handle { match_tier::HANDLE } else { found.tier };
            let key = entry.frecency_key.as_deref().filter(|key| !key.is_empty());
            if key.is_some_and(|key| hidden.contains(key))
                && !handle
                && !title_is_query(&entry.title, raw)
            {
                continue;
            }
            // Whole-title rows tie on quality, so the provider order decides.
            let quality = if handle
                || (found.tier >= match_tier::WHOLE_TITLE - 1 && title_is_query(&entry.title, raw))
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
            scored.push(Scored {
                index,
                score,
                tier: tier_reached,
                enabled,
                demoted: entry.demoted == Some(true),
                exact_name: entry.demoted == Some(true) && title_is_query(&entry.title, raw),
                shortcut: entry.has_shortcut == Some(true),
                chord: names_shortcut(index),
                lifted: false,
                aliased: enabled && entry.action_id.as_ref().is_some_and(|id| aliased.contains(id)),
                handle: enabled && handle,
                highlights,
            });
        }
        strong
    };
    if rank_pass(false, &mut scored) < TYPO_PASS_THRESHOLD {
        scored.clear();
        rank_pass(true, &mut scored);
    }
    // The strongest learned pick for this query that still matches it goes first.
    let candidates = lift_candidates(store, raw, now);
    if !candidates.is_empty() {
        let mut by_key: HashMap<&str, usize> = HashMap::new();
        for (position, item) in scored.iter().enumerate() {
            if let Some(key) =
                entries[item.index].frecency_key.as_deref().filter(|key| !key.is_empty())
                && item.enabled
            {
                by_key.entry(key).or_insert(position);
            }
        }
        if let Some(&position) = candidates.iter().find_map(|key| by_key.get(key.as_str())) {
            scored[position].lifted = true;
        }
    }
    // The user's alias names its row, even when the query matches none of its text.
    if !aliased.is_empty() {
        let mut present: HashSet<Option<&str>> =
            scored.iter().map(|item| entries[item.index].action_id.as_deref()).collect();
        for (index, entry) in entries.iter().enumerate() {
            let Some(id) = entry.action_id.as_deref().filter(|id| !id.is_empty()) else { continue };
            if !aliased.contains(id)
                || present.contains(&Some(id))
                || entry.is_enabled == Some(false)
            {
                continue;
            }
            if !shown_while_typing(entry, gated, raw) {
                continue;
            }
            present.insert(Some(id));
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
                highlights: Vec::new(),
            });
        }
    }
    // The row bound to the shortcut the query names, even when the query matches none of its text.
    if chord.is_some() {
        let present: HashSet<usize> = scored.iter().map(|item| item.index).collect();
        for (index, entry) in entries.iter().enumerate() {
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
                highlights: Vec::new(),
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
    if request.ranks_prefix_first == Some(true) {
        let prefix = js_trim(raw).to_lowercase();
        let starts: HashSet<usize> = scored
            .iter()
            .filter(|item| entries[item.index].title.to_lowercase().starts_with(&prefix))
            .map(|item| item.index)
            .collect();
        scored.sort_by(|left, right| {
            let (left_starts, right_starts) =
                (starts.contains(&left.index), starts.contains(&right.index));
            right
                .handle
                .cmp(&left.handle)
                .then(right.aliased.cmp(&left.aliased))
                .then((right.chord && right.enabled).cmp(&(left.chord && left.enabled)))
                .then(right_starts.cmp(&left_starts))
                .then_with(|| {
                    if left_starts {
                        left.index.cmp(&right.index)
                    } else {
                        right.score.cmp(&left.score).then(left.index.cmp(&right.index))
                    }
                })
        });
    } else {
        scored.sort_by(|left, right| {
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
        });
    }
    let row_limit = usize::try_from(request.row_limit.unwrap_or(400)).unwrap_or(0);
    let highlight_limit = usize::try_from(request.highlight_limit.unwrap_or(60)).unwrap_or(0);
    let (mut order, rows_by_section) =
        group(scored.into_iter().take(row_limit).enumerate().map(|(rank, item)| {
            let entry = &entries[item.index];
            let section = entry.typing_section_index.or(entry.section_index).unwrap_or(0);
            let highlights = if rank < highlight_limit { item.highlights } else { Vec::new() };
            (section, RankedRow { index: item.index, score: item.score, highlights })
        }));
    if request.keeps_section_order == Some(true) {
        section_order(&mut order, request.section_orders.as_deref().unwrap_or_default());
    }
    sections_of(order, rows_by_section)
}
