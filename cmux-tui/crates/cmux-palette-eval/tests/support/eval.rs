//! The palette ranking eval (plans/cmux-next/palette-ranking.md section 3).
//!
//! Replays real root-palette entries (dumped from a tagged build with `debug.palette.entries`)
//! through the ranker for a fixed set of queries with expected rows, and reports top-1, top-3
//! and MRR. Ranking changes are measured against this report, not guessed. `tests/eval.rs` holds
//! the floors; `examples/eval.rs` prints the report.

// Shared by the test and the example; each reads a different part.
#![allow(dead_code)]

use cmux_palette_ranker::{RankRequest, rank_request};
use serde::Deserialize;
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, BTreeSet, HashMap};

pub const EVAL_NOW: f64 = 800_000_000.0;
const DAY: f64 = 24.0 * 60.0 * 60.0;
const HALF_LIFE: f64 = 3.0 * DAY;
const PICK_HALF_LIFE: f64 = 7.0 * DAY;

#[derive(Debug, Clone, Deserialize)]
pub struct FixtureEntry {
    pub id: String,
    pub entry: Value,
}

#[derive(Debug, Clone, Deserialize)]
pub struct FixtureSection {
    pub id: String,
    pub title: String,
    pub order: i64,
}

/// The ranker input of one scope, as `debug.palette.entries` writes it.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Fixture {
    pub scope: String,
    pub shows_recent: bool,
    pub section_orders: Vec<i64>,
    pub sections: Vec<FixtureSection>,
    pub entries: Vec<FixtureEntry>,
}

/// Rows a fresh tagged build does not have (workspaces, tabs): added with their provider's shape.
#[derive(Debug, Clone, Deserialize)]
pub struct OverlayEntry {
    pub id: String,
    pub entry: Value,
    pub section: FixtureSection,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(untagged)]
pub enum ReplayEvent {
    Pick {
        query: String,
        pick: String,
        #[serde(rename = "daysAgo")]
        days_ago: Option<f64>,
    },
    Hide {
        hide: String,
    },
    Unhide {
        unhide: String,
    },
    Forget {
        forget: String,
    },
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Case {
    pub query: String,
    /// Any of these row ids is a correct answer; the first is the best one.
    pub expect: Vec<String>,
    pub group: String,
    /// Rank with this usage profile (`profiles` of the cases file).
    pub profile: Option<String>,
    /// A guard case: its row must stay in the top 3.
    #[serde(default)]
    pub guard: bool,
    /// Learning: these runs happen first (oldest first), each `daysAgo` before the query.
    pub replay: Option<Vec<ReplayEvent>>,
    /// Learning: this row must NOT be first (an old pick that should have faded).
    pub not_first: Option<String>,
    /// Learning: this row must not be among the results at all (a hidden row).
    pub absent: Option<String>,
    /// The first expected row must be at exactly this 1-based position (empty-query order).
    pub at: Option<usize>,
    /// The user's settings for this case: cmux.json `palette.aliases` and `palette.pins`.
    pub aliases: Option<HashMap<String, Vec<String>>>,
    pub pins: Option<Vec<String>>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Cases {
    /// Decayed use counts per frecency key, all last used at the eval's `now`.
    #[serde(default)]
    pub profiles: HashMap<String, HashMap<String, f64>>,
    pub cases: Vec<Case>,
}

#[derive(Debug, Clone)]
pub struct CaseResult {
    pub query: String,
    pub group: String,
    pub profile: Option<String>,
    /// 1-based rank of the first expected row in display order, none when absent from the first 50.
    pub rank: Option<usize>,
    pub top: Vec<String>,
    pub expect: Vec<String>,
}

#[derive(Debug, Clone, Copy, Default)]
pub struct Summary {
    pub cases: usize,
    pub top1: f64,
    pub top3: f64,
    pub mrr: f64,
}

#[derive(Debug, Clone)]
pub struct Report {
    pub summary: Summary,
    pub by_group: BTreeMap<String, Summary>,
    pub results: Vec<CaseResult>,
}

fn dir() -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests").join("eval")
}

fn read<T: serde::de::DeserializeOwned>(path: &std::path::Path) -> Result<T, String> {
    let text =
        std::fs::read_to_string(path).map_err(|error| format!("{}: {error}", path.display()))?;
    serde_json::from_str(&text).map_err(|error| format!("{}: {error}", path.display()))
}

/// The checked-in fixture (or `fixture_path`) with the overlay rows, and the cases.
pub fn load(fixture_path: Option<&std::path::Path>) -> Result<(Fixture, Cases), String> {
    let fixture: Fixture = read(fixture_path.unwrap_or(&dir().join("root-entries.json")))?;
    let overlay: Vec<OverlayEntry> = read(&dir().join("overlay.json"))?;
    Ok((merge_overlay(fixture, overlay), read(&dir().join("cases.json"))?))
}

/// Row ids of the checked-in fixture, without the overlay (what a fresh build has).
pub fn fixture_ids() -> Result<BTreeSet<String>, String> {
    let fixture: Fixture = read(&dir().join("root-entries.json"))?;
    Ok(fixture.entries.into_iter().map(|row| row.id).collect())
}

/// The fixture's entries plus the overlay rows, with section indexes resolved.
pub fn merge_overlay(mut fixture: Fixture, overlay: Vec<OverlayEntry>) -> Fixture {
    // A page that merges sections while typing puts the overlay rows there too.
    let typing = fixture
        .entries
        .first()
        .and_then(|row| row.entry.get("typingSectionIndex").cloned())
        .unwrap_or(Value::Null);
    for row in overlay {
        let index = match fixture.sections.iter().position(|section| section.id == row.section.id) {
            Some(index) => index,
            None => {
                fixture.sections.push(row.section.clone());
                fixture.sections.len() - 1
            }
        };
        let mut entry = row.entry;
        if let Some(object) = entry.as_object_mut() {
            object.insert("sectionIndex".into(), json!(index));
            object.insert("typingSectionIndex".into(), typing.clone());
        }
        fixture.entries.push(FixtureEntry { id: row.id, entry });
    }
    fixture.section_orders = fixture.sections.iter().map(|section| section.order).collect();
    fixture
}

fn decay(score: f64, from: f64, to: f64, life: f64) -> f64 {
    score * 2f64.powf(-(to - from).max(0.0) / life)
}

fn profile_history(profile: Option<&HashMap<String, f64>>) -> Map<String, Value> {
    let mut entries = Map::new();
    for (key, score) in profile.into_iter().flatten() {
        entries.insert(key.clone(), json!({ "score": score, "lastUsed": EVAL_NOW }));
    }
    entries
}

/// The history the daemon would hold after `replay` (test-only model of cmux-tui-core
/// state/palette_usage.rs `record`: +1 per use with a 3-day half-life, +1 per pick under each
/// 1-8 character start of the normalized query with a 7-day half-life, and the latest pick per
/// start). The daemon is the real writer; this lets the eval measure learning without one.
pub fn replay_history(replay: &[ReplayEvent], mut entries: Map<String, Value>) -> Value {
    #[derive(Clone)]
    struct Pick {
        prefix: String,
        key: String,
        score: f64,
        last_used: f64,
        last: bool,
    }
    let mut picks: Vec<Pick> = Vec::new();
    let mut hidden: Vec<String> = Vec::new();
    for event in replay {
        match event {
            ReplayEvent::Hide { hide } => {
                if !hidden.contains(hide) {
                    hidden.push(hide.clone());
                }
            }
            ReplayEvent::Unhide { unhide } => hidden.retain(|key| key != unhide),
            ReplayEvent::Forget { forget } => {
                entries.remove(forget);
                picks.retain(|pick| &pick.key != forget);
            }
            ReplayEvent::Pick { query, pick, days_ago } => {
                let at = EVAL_NOW - days_ago.unwrap_or(0.0) * DAY;
                let previous = entries.get(pick).map(|entry| {
                    let score = entry["score"].as_f64().unwrap_or(0.0);
                    let last_used = entry["lastUsed"].as_f64().unwrap_or(at);
                    decay(score, last_used, at, HALF_LIFE)
                });
                entries.insert(
                    pick.clone(),
                    json!({ "score": previous.unwrap_or(0.0) + 1.0, "lastUsed": at }),
                );
                let normalized =
                    query.split_whitespace().collect::<Vec<_>>().join(" ").to_lowercase();
                let chars: Vec<char> = normalized.chars().collect();
                let mut prefixes: Vec<String> = Vec::new();
                for length in 1..=chars.len().min(8) {
                    let prefix: String =
                        chars[..length].iter().collect::<String>().trim_end().to_owned();
                    if !prefix.is_empty() && !prefixes.contains(&prefix) {
                        prefixes.push(prefix);
                    }
                }
                for prefix in prefixes {
                    for other in picks.iter_mut().filter(|other| other.prefix == prefix) {
                        other.last = false;
                    }
                    match picks
                        .iter_mut()
                        .find(|other| other.prefix == prefix && &other.key == pick)
                    {
                        Some(existing) => {
                            existing.score =
                                decay(existing.score, existing.last_used, at, PICK_HALF_LIFE) + 1.0;
                            existing.last_used = at;
                            existing.last = true;
                        }
                        None => picks.push(Pick {
                            prefix,
                            key: pick.clone(),
                            score: 1.0,
                            last_used: at,
                            last: true,
                        }),
                    }
                }
            }
        }
    }
    let picks: Vec<Value> = picks
        .into_iter()
        .map(|pick| {
            json!({
                "prefix": pick.prefix, "key": pick.key, "score": pick.score,
                "lastUsed": pick.last_used, "last": pick.last,
            })
        })
        .collect();
    json!({
        "entries": entries, "picks": picks, "halfLife": HALF_LIFE,
        "pickHalfLife": PICK_HALF_LIFE, "hidden": hidden,
    })
}

/// The ranker's answer for `query`: sections in display order with each row's fixture id.
pub fn rank(
    fixture: &Fixture,
    query: &str,
    frecency: Value,
    aliases: Option<&HashMap<String, Vec<String>>>,
    pins: Option<&[String]>,
    now: f64,
) -> Result<Vec<cmux_palette_ranker::RankedSection>, String> {
    let entries: Vec<&Value> = fixture.entries.iter().map(|row| &row.entry).collect();
    let request: RankRequest = serde_json::from_value(json!({
        "operation": "rank",
        "entries": entries,
        "query": query,
        "sectionOrders": fixture.section_orders,
        "frecency": frecency,
        "now": now,
        "showsRecent": fixture.shows_recent,
        "aliases": aliases,
        "pins": pins,
    }))
    .map_err(|error| error.to_string())?;
    Ok(rank_request(&request))
}

/// Row ids in display order (sections in their order, rows in theirs).
pub fn ranked_ids(fixture: &Fixture, case: &Case, frecency: Value) -> Result<Vec<String>, String> {
    let sections = rank(
        fixture,
        &case.query,
        frecency,
        case.aliases.as_ref(),
        case.pins.as_deref(),
        EVAL_NOW,
    )?;
    Ok(sections
        .iter()
        .flat_map(|section| section.rows.iter().map(|row| fixture.entries[row.index].id.clone()))
        .collect())
}

fn summarize<'a>(results: impl Iterator<Item = &'a CaseResult>) -> Summary {
    let mut summary = Summary::default();
    let (mut top1, mut top3, mut reciprocal) = (0usize, 0usize, 0f64);
    for result in results {
        summary.cases += 1;
        if result.rank == Some(1) {
            top1 += 1;
        }
        if result.rank.is_some_and(|rank| rank <= 3) {
            top3 += 1;
        }
        reciprocal += result.rank.map_or(0.0, |rank| 1.0 / rank as f64);
    }
    if summary.cases > 0 {
        let cases = summary.cases as f64;
        summary.top1 = top1 as f64 / cases;
        summary.top3 = top3 as f64 / cases;
        summary.mrr = reciprocal / cases;
    }
    summary
}

/// Scores `ranked(case, history)` (row ids, best first) against the cases.
pub fn score_cases<'a>(
    profiles: &HashMap<String, HashMap<String, f64>>,
    cases: impl Iterator<Item = &'a Case>,
    mut ranked: impl FnMut(&Case, Value) -> Result<Vec<String>, String>,
) -> Result<Report, String> {
    let mut results = Vec::new();
    for case in cases {
        let profile = profile_history(case.profile.as_ref().and_then(|name| profiles.get(name)));
        let frecency = match &case.replay {
            Some(replay) => replay_history(replay, profile),
            None => json!({ "entries": profile }),
        };
        let mut ids = ranked(case, frecency)?;
        ids.truncate(50);
        let found = if let Some(absent) = &case.absent {
            (!ids.contains(absent)).then_some(0)
        } else if let Some(at) = case.at {
            (ids.get(at.wrapping_sub(1)) == case.expect.first()).then_some(0)
        } else if let Some(not_first) = &case.not_first {
            (ids.first() != Some(not_first)).then_some(0)
        } else {
            ids.iter().position(|id| case.expect.contains(id))
        };
        results.push(CaseResult {
            query: case.query.clone(),
            group: case.group.clone(),
            profile: case.profile.clone(),
            rank: found.map(|position| position + 1),
            top: ids.iter().take(3).cloned().collect(),
            expect: case.expect.clone(),
        });
    }
    let groups: BTreeSet<String> = results.iter().map(|result| result.group.clone()).collect();
    let by_group = groups
        .into_iter()
        .map(|group| {
            let summary = summarize(results.iter().filter(|result| result.group == group));
            (group, summary)
        })
        .collect();
    Ok(Report { summary: summarize(results.iter()), by_group, results })
}

/// Scores the ranker over `cases` of the fixture.
pub fn evaluate<'a>(
    fixture: &Fixture,
    profiles: &HashMap<String, HashMap<String, f64>>,
    cases: impl Iterator<Item = &'a Case>,
) -> Result<Report, String> {
    score_cases(profiles, cases, |case, frecency| ranked_ids(fixture, case, frecency))
}

fn percent(value: f64) -> String {
    format!("{:.1}%", value * 100.0)
}

/// A plain-text report: totals, per group, then every miss with what ranked first.
pub fn format_report(report: &Report, title: &str) -> String {
    let total = report.summary;
    let mut lines = vec![format!(
        "{title}: {} cases  top-1 {}  top-3 {}  MRR {:.3}",
        total.cases,
        percent(total.top1),
        percent(total.top3),
        total.mrr
    )];
    for (group, value) in &report.by_group {
        lines.push(format!(
            "  {group:<12} {:>3}  top-1 {:>6}  top-3 {:>6}  MRR {:.3}",
            value.cases,
            percent(value.top1),
            percent(value.top3),
            value.mrr
        ));
    }
    let misses: Vec<&CaseResult> =
        report.results.iter().filter(|result| result.rank != Some(1)).collect();
    if !misses.is_empty() {
        lines.push("  not first:".into());
    }
    for miss in misses {
        let profile =
            miss.profile.as_ref().map(|profile| format!(" [{profile}]")).unwrap_or_default();
        lines.push(format!(
            "    {}{profile} rank {}  want {}  got {}",
            Value::from(miss.query.clone()),
            miss.rank.map_or("-".into(), |rank| rank.to_string()),
            miss.expect.first().map_or("", String::as_str),
            miss.top.join(", ")
        ));
    }
    lines.join("\n")
}
