//! `cmux care`: one pass over everything a machine can reclaim, held to a
//! disk budget. The worktrees ([`crate::pass`]) and the families of
//! [`crate::caches`] are scanned once, their candidates ordered, and acted
//! on:
//!
//! - under budget pressure (the volume at 70% or more, or its forecast
//!   crossing 75% before the next look): largest first, oldest first among
//!   equals, until the projected use is under 70%, then it stops;
//! - below that: only what is clearly dead on the normal ages, oldest first.
//!
//! Every disk look is recorded (`disk-samples.jsonl`), every action goes in
//! the ledger (`care-ledger.jsonl`), and nothing here removes what
//! `never_delete` names. [`due`] is the headless tick's cheap half: a
//! sample, the spacing, the machine's claim.

use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::budget::{self, Forecast, Plan, Projection, Samples};
use crate::caches;
use crate::disk::{self, Usage};
use crate::inventory::now_ms;
use crate::ledger::{Ledger, Row};
use crate::never_delete::NeverDelete;
use crate::pass;
use crate::policy::{Action, Pressure};
use crate::schedule::{self, Claim, Refused};
use crate::store::Store;

/// The family name of worktrees in a report.
pub const WORKTREES: &str = "worktrees";

/// What one care run needs.
pub struct Config {
    /// The worktree pass (its `apply`, `pressure` and `measure` are set here).
    pub pass: pass::Options,
    pub home: PathBuf,
    pub store: Store,
    /// Act; otherwise only report (`--dry-run`).
    pub apply: bool,
    /// Only these families (`worktrees` included); all when empty.
    pub only_families: Vec<String>,
    /// Families switched off (`care.families.<name>`).
    pub off: Vec<String>,
    /// Whether regenerable caches may be removed (`worktrees.cleanBuildCaches`).
    pub clean_caches: bool,
    /// Plain clones the lane-clones family reads.
    pub clone_roots: Vec<PathBuf>,
    /// Decide at this pressure instead of the volume's.
    pub pressure: Option<Pressure>,
}

/// One family's line in a report.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FamilySummary {
    pub name: String,
    pub enabled: bool,
    pub entries: usize,
    /// Bytes the entries that may go take.
    pub reclaimable: u64,
    pub freed: u64,
    pub removed: usize,
    pub kept: usize,
    /// Never removed by care, only reported.
    pub report_only: bool,
    pub bytes: u64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Report {
    pub disk: Option<Usage>,
    pub budget: Plan,
    pub forecast: Forecast,
    pub families: Vec<FamilySummary>,
    pub worktrees: pass::Report,
    pub caches: caches::Report,
    pub applied: bool,
    pub freed: u64,
    pub reclaimable: u64,
    /// The projected used share after the run (the volume's when nothing was freed).
    pub projected_fraction: f64,
    /// A budget-pressure run stopped because the projection got under 70%.
    pub stopped_at_budget: bool,
    pub errors: Vec<String>,
    /// Files the never-delete list was read from that could not be.
    pub never_delete_problems: Vec<String>,
}

/// The cheap half of a tick: look at the volume, record the sample, and
/// say how soon the next pass is due.
pub struct Look {
    pub usage: Usage,
    pub plan: Plan,
    pub forecast: Forecast,
}

/// Records a sample of the volume `home` is on and plans from it.
pub fn look(home: &Path, store: &Store, settings: &crate::policy::Settings) -> Option<Look> {
    let usage = disk::usage(home)?;
    let used = usage.total.saturating_sub(usage.available);
    let now = now_ms();
    let samples = Samples::in_dir(&store.dir);
    if let Err(error) = samples.record(budget::Sample { at_ms: now, used, total: usage.total }) {
        eprintln!("care: could not record a disk sample: {error}");
    }
    let forecast = budget::forecast(&samples.load(), now, used, usage.total);
    let plan = budget::plan(settings, usage.used_fraction(), &forecast);
    Some(Look { usage, plan, forecast })
}

/// The machine's claim for an automatic pass, when one is due: the plan's
/// spacing since the last recorded pass, and none running.
pub fn due(store: &Store, look: &Look) -> Result<Claim, Refused> {
    schedule::claim(&store.dir, now_ms(), Some(look.plan.spacing_ms), true)
}

#[derive(Clone, Copy)]
enum Slot {
    Worktree(usize),
    Cache(usize),
}

struct Candidate {
    slot: Slot,
    bytes: u64,
    /// Last use, milliseconds; unknown sorts as the oldest of all (it is kept anyway).
    last: u64,
}

fn wanted(config: &Config, family: &str) -> bool {
    (config.only_families.is_empty() || config.only_families.iter().any(|f| f == family))
        && !config.off.iter().any(|f| f == family)
}

/// Runs one pass under the budget.
pub fn run(config: &Config, look: Option<&Look>) -> Result<Report, String> {
    let _background = cmux_git::run::background();
    let (never, never_problems) = NeverDelete::load(&config.home);
    let settings = config.pass.settings.clone();
    let fallback;
    let look = match look {
        Some(look) => look,
        None => {
            fallback = self::look(&config.home, &config.store, &settings)
                .ok_or("cannot read the disk's size")?;
            &fallback
        }
    };
    let plan = look.plan;
    let pressure = config.pressure.unwrap_or(plan.pressure);
    let budget_run =
        config.pressure.is_some_and(|p| p != Pressure::Normal) || plan.budget_pressure();
    let used = look.usage.total.saturating_sub(look.usage.available);
    // Over budget: down to the pressure line. Only forecast to cross it: a margin under
    // where the disk is now, so acting early frees something.
    let stop_below = if plan.over_budget {
        settings.high
    } else {
        settings.high.min(look.usage.used_fraction() - 0.03)
    };
    let mut projection = Projection::new(used, look.usage.total, stop_below);
    let ledger = Ledger::in_dir(&config.store.dir);
    let mut rows: Vec<Row> = Vec::new();
    let mut errors = Vec::new();

    // Scan: the worktrees, then the families.
    let mut options = config.pass.clone();
    options.pressure = Some(pressure);
    options.apply = config.apply;
    options.measure = true;
    // Worktrees not chosen (`--family docker-images`, or turned off): no
    // root, no session folder to find repositories from, and no archive
    // expiry at the end; the scan finds nothing and nothing of theirs moves.
    let worktrees_wanted = wanted(config, WORKTREES);
    let skipped = pass::Options {
        roots: Vec::new(),
        sessions: Vec::new(),
        only: Vec::new(),
        apply: false,
        ..options.clone()
    };
    let mut scan = if worktrees_wanted {
        pass::scan(&options, &config.store)?
    } else {
        pass::scan(&skipped, &config.store)?
    };
    for item in &mut scan.report.items {
        // Only a worktree that would go is walked for something kept inside.
        let held = if item.verdict.action == Action::Keep {
            never.holds(&config.home, &item.path)
        } else {
            never.holds_tree(&config.home, &item.path)
        };
        if let Some(glob) = held {
            item.verdict.action = Action::Keep;
            item.verdict.reason = format!("never-delete: {glob}");
        }
    }
    let layout_roots = options.roots.clone();
    let families = caches::families(&caches::Layout {
        home: &config.home,
        worktree_roots: &layout_roots,
        clone_roots: &config.clone_roots,
    });
    let off: Vec<String> = families
        .iter()
        .map(|f| f.name.to_string())
        .filter(|name| !wanted(config, name))
        .chain(config.off.iter().cloned())
        .collect();
    let cache_options = caches::Options {
        families,
        pressure,
        now_ms: now_ms(),
        apply: config.apply && config.clean_caches,
        uses: options.uses.as_ref(),
        open: options.open.as_ref(),
        measure: true,
        home: &config.home,
        never: &never,
        store: Some(&config.store),
        off: &off,
    };
    let mut cache_report = caches::scan(&cache_options);

    // Candidates, in the order they go.
    let mut candidates = Vec::new();
    for (index, item) in scan.report.items.iter().enumerate() {
        if item.verdict.action != Action::Keep {
            let last = item.facts.as_ref().map_or(0, |f| f.last_activity_ms);
            candidates.push(Candidate {
                slot: Slot::Worktree(index),
                bytes: item.bytes.unwrap_or(0),
                last,
            });
        }
    }
    for (index, item) in cache_report.items.iter().enumerate() {
        if item.verdict.action == Action::Reclaim {
            candidates.push(Candidate {
                slot: Slot::Cache(index),
                bytes: item.bytes.unwrap_or(0),
                last: item.last_activity_ms.unwrap_or(0),
            });
        }
    }
    if budget_run {
        candidates.sort_by(|a, b| b.bytes.cmp(&a.bytes).then(a.last.cmp(&b.last)));
    } else {
        candidates.sort_by_key(|c| c.last);
    }

    let mut stopped = false;
    if config.apply {
        for candidate in &candidates {
            if budget_run && projection.done() {
                stopped = true;
                break;
            }
            let before = (scan.report.freed, cache_report.freed);
            match candidate.slot {
                Slot::Worktree(index) => {
                    pass::act_on_guarded(&mut scan, index, &options, &config.store, &|path| {
                        match never.holds_tree(&config.home, path) {
                            Some(why) => Err(format!("never-delete: {why}")),
                            None => Ok(()),
                        }
                    });
                    if let Some(item) = scan.report.items.get(index) {
                        rows.push(worktree_row(item));
                    }
                }
                Slot::Cache(index) => {
                    if !config.clean_caches {
                        continue;
                    }
                    caches::apply(&cache_options, &mut cache_report, index);
                    if let Some(item) = cache_report.items.get(index) {
                        rows.push(cache_row(item));
                    }
                }
            }
            projection.add(scan.report.freed.saturating_sub(before.0));
            projection.add(cache_report.freed.saturating_sub(before.1));
        }
    }
    errors.extend(scan.report.errors.clone());
    errors.extend(cache_report.errors.clone());
    let worktrees =
        pass::finish(scan, if worktrees_wanted { &options } else { &skipped }, &config.store)?;
    if let Err(error) = ledger.append(&rows) {
        errors.push(format!("ledger: {error}"));
    }
    if config.apply {
        // The volume after the run, so the next forecast sees the drop.
        if let Some(usage) = disk::usage(&config.home) {
            let used = usage.total.saturating_sub(usage.available);
            let _ = Samples::in_dir(&config.store.dir).record(budget::Sample {
                at_ms: now_ms(),
                used,
                total: usage.total,
            });
        }
    }
    let families = summarize(&worktrees, &cache_report, &cache_options, config);
    let freed = worktrees.freed + cache_report.freed;
    let reclaimable = worktrees.reclaimable + cache_report.reclaimable;
    Ok(Report {
        disk: look.usage.into(),
        budget: plan,
        forecast: look.forecast,
        families,
        worktrees,
        caches: cache_report,
        applied: config.apply,
        freed,
        reclaimable,
        projected_fraction: projection.fraction(),
        stopped_at_budget: stopped,
        errors,
        never_delete_problems: never_problems,
    })
}

fn worktree_row(item: &pass::Item) -> Row {
    let (action, archive, reason) = match &item.outcome {
        Some(o) if o.ok => (
            if o.archive.is_some() {
                "archived"
            } else if item.verdict.action == Action::Trim {
                "trimmed"
            } else {
                "removed"
            },
            o.archive.clone(),
            item.verdict.reason.clone(),
        ),
        Some(o) => ("failed", None, o.error.clone().unwrap_or_default()),
        None => ("kept", None, item.verdict.reason.clone()),
    };
    Row {
        at_ms: now_ms(),
        family: WORKTREES.into(),
        path: item.path.clone(),
        bytes: item.outcome.as_ref().map_or(item.bytes.unwrap_or(0), |o| o.freed),
        verdict: format!("{:?}", item.verdict.action).to_lowercase(),
        action: action.into(),
        archive,
        reason,
    }
}

fn cache_row(item: &caches::Item) -> Row {
    let (action, archive, reason) = match &item.outcome {
        Some(o) if o.ok => ("removed", o.archive.clone(), item.verdict.reason.clone()),
        Some(o) => ("failed", o.archive.clone(), o.error.clone().unwrap_or_default()),
        None => ("kept", None, item.verdict.reason.clone()),
    };
    Row {
        at_ms: now_ms(),
        family: item.family.clone(),
        path: item.path.clone(),
        bytes: item.outcome.as_ref().map_or(item.bytes.unwrap_or(0), |o| o.freed),
        verdict: "reclaim".into(),
        action: action.into(),
        archive,
        reason,
    }
}

fn summarize(
    worktrees: &pass::Report,
    cache_report: &caches::Report,
    options: &caches::Options,
    config: &Config,
) -> Vec<FamilySummary> {
    let mut out = vec![FamilySummary {
        name: WORKTREES.into(),
        enabled: wanted(config, WORKTREES),
        entries: worktrees.items.len(),
        reclaimable: worktrees.reclaimable,
        freed: worktrees.freed,
        removed: worktrees
            .items
            .iter()
            .filter(|i| i.outcome.as_ref().is_some_and(|o| o.ok))
            .count(),
        kept: worktrees.items.iter().filter(|i| i.verdict.action == Action::Keep).count(),
        report_only: false,
        bytes: worktrees.items.iter().filter_map(|i| i.bytes).sum(),
    }];
    let mut names: Vec<&'static str> = Vec::new();
    for family in &options.families {
        if !names.contains(&family.name) {
            names.push(family.name);
        }
    }
    for name in names {
        let items: Vec<&caches::Item> =
            cache_report.items.iter().filter(|i| i.family == name).collect();
        let report_only = options
            .families
            .iter()
            .any(|f| f.name == name && f.source == caches::Source::ReportOnly);
        out.push(FamilySummary {
            name: name.into(),
            enabled: !options.off.iter().any(|f| f == name),
            entries: items.len(),
            reclaimable: items
                .iter()
                .filter(|i| i.verdict.action == Action::Reclaim)
                .filter_map(|i| i.bytes)
                .sum(),
            freed: items.iter().filter_map(|i| i.outcome.as_ref()).map(|o| o.freed).sum(),
            removed: items.iter().filter(|i| i.outcome.as_ref().is_some_and(|o| o.ok)).count(),
            kept: items.iter().filter(|i| i.verdict.action == Action::Keep).count(),
            report_only,
            bytes: items.iter().filter_map(|i| i.bytes).sum(),
        });
    }
    out
}

/// Why `path` is or is not removed: what the ledger recorded for it, whether
/// the never-delete list holds it, and the family and verdict it has now.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Why {
    pub path: PathBuf,
    pub never_delete: Option<String>,
    pub ledger: Vec<Row>,
    pub now: Option<caches::Item>,
}

pub fn why(config: &Config, path: &Path) -> Why {
    let (never, _) = NeverDelete::load(&config.home);
    let ledger = Ledger::in_dir(&config.store.dir).for_path(path, 20);
    let layout_roots = config.pass.roots.clone();
    let families = caches::families(&caches::Layout {
        home: &config.home,
        worktree_roots: &layout_roots,
        clone_roots: &config.clone_roots,
    });
    let look = look(&config.home, &config.store, &config.pass.settings);
    let pressure = look.map_or(Pressure::Normal, |l| l.plan.pressure);
    let options = caches::Options {
        families,
        pressure,
        now_ms: now_ms(),
        apply: false,
        uses: config.pass.uses.as_ref(),
        open: config.pass.open.as_ref(),
        measure: false,
        home: &config.home,
        never: &never,
        store: None,
        off: &[],
    };
    let now = caches::scan(&options)
        .items
        .into_iter()
        .find(|i| path == i.path || path.starts_with(&i.path));
    Why { path: path.to_path_buf(), never_delete: never.holds(&config.home, path), ledger, now }
}

#[cfg(test)]
#[path = "care_tests.rs"]
mod tests;
