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

use serde::{Deserialize, Serialize};

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
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[serde(default)]
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

impl Default for FamilySummary {
    fn default() -> Self {
        Self {
            name: String::new(),
            enabled: true,
            entries: 0,
            reclaimable: 0,
            freed: 0,
            removed: 0,
            kept: 0,
            report_only: false,
            bytes: 0,
        }
    }
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
    /// What the pass's walks and reads cost.
    pub cost: crate::walk_memo::Cost,
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

/// [`look`] without recording a sample: `status` changes nothing.
pub fn peek(home: &Path, store: &Store, settings: &crate::policy::Settings) -> Option<Look> {
    let usage = disk::usage(home)?;
    let used = usage.total.saturating_sub(usage.available);
    let forecast =
        budget::forecast(&Samples::in_dir(&store.dir).load(), now_ms(), used, usage.total);
    let plan = budget::plan(settings, usage.used_fraction(), &forecast);
    Some(Look { usage, plan, forecast })
}

/// The file the last whole pass's report is kept in, in the store folder
/// (hidden, so the manifest listing never reads it).
const LAST_PASS: &str = ".care-last-pass";

/// The last whole pass (every family, every worktree), as it was recorded.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LastPass {
    pub at_ms: u64,
    /// How long the pass took.
    #[serde(default)]
    pub took_ms: u64,
    /// The [`Report`], as JSON.
    pub report: serde_json::Value,
}

impl LastPass {
    /// The report's family lines.
    pub fn families(&self) -> Vec<FamilySummary> {
        self.report
            .get("families")
            .cloned()
            .and_then(|v| serde_json::from_value(v).ok())
            .unwrap_or_default()
    }

    fn u64_field(&self, key: &str) -> u64 {
        self.report.get(key).and_then(serde_json::Value::as_u64).unwrap_or(0)
    }

    pub fn reclaimable(&self) -> u64 {
        self.u64_field("reclaimable")
    }

    pub fn freed(&self) -> u64 {
        self.u64_field("freed")
    }

    pub fn applied(&self) -> bool {
        self.report.get("applied").and_then(serde_json::Value::as_bool).unwrap_or(false)
    }

    pub fn errors(&self) -> Vec<String> {
        self.report
            .get("errors")
            .cloned()
            .and_then(|v| serde_json::from_value(v).ok())
            .unwrap_or_default()
    }
}

/// Records `report` as the machine's last pass, whole to a temporary file
/// and renamed, so a reader never sees half of one.
pub fn record_last_pass(store: &Store, report: &Report, took_ms: u64) -> Result<(), String> {
    let last = LastPass {
        at_ms: now_ms(),
        took_ms,
        report: serde_json::to_value(report).map_err(|e| e.to_string())?,
    };
    let path = store.dir.join(LAST_PASS);
    let temporary = store.dir.join(format!("{LAST_PASS}.{}.tmp", std::process::id()));
    let text = serde_json::to_vec(&last).map_err(|e| e.to_string())?;
    std::fs::write(&temporary, text).map_err(|e| format!("{}: {e}", temporary.display()))?;
    std::fs::rename(&temporary, &path).map_err(|e| format!("{}: {e}", path.display()))
}

/// The last whole pass on record, if one ran and its file reads.
pub fn last_pass(store: &Store) -> Option<LastPass> {
    let bytes = std::fs::read(store.dir.join(LAST_PASS)).ok()?;
    serde_json::from_slice(&bytes).ok()
}

/// What `care status` shows: the volume now (one `statvfs`, the sample file
/// read) and the last whole pass's report. No walk, no git, no write.
pub struct Status {
    pub look: Look,
    pub last: Option<LastPass>,
}

pub fn status(home: &Path, store: &Store, settings: &crate::policy::Settings) -> Option<Status> {
    Some(Status { look: peek(home, store, settings)?, last: last_pass(store) })
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
    let started = std::time::Instant::now();
    // What the last passes measured stands in for walking it all again (`walk_memo`).
    crate::walk_memo::open(&config.store.dir);
    let _ = crate::walk_memo::take_cost();
    let report = run_inner(config, look);
    if let Err(error) = crate::walk_memo::close(now_ms()) {
        eprintln!("care: could not keep the walk memo: {error}");
    }
    let mut report = report?;
    report.cost = crate::walk_memo::take_cost();
    // A whole pass is what `status` shows next; a filtered one is not the machine's picture.
    if config.only_families.is_empty() && config.pass.only.is_empty() {
        let took = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX);
        if let Err(error) = record_last_pass(&config.store, &report, took) {
            eprintln!("care: could not record the pass's report: {error}");
        }
    }
    Ok(report)
}

fn run_inner(config: &Config, look: Option<&Look>) -> Result<Report, String> {
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
        cost: crate::walk_memo::Cost::default(),
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
mod tests {
    use super::*;
    use crate::procs::Process;
    use crate::store::care_tests::scratch;
    use std::sync::Arc;

    fn config(home: &Path, apply: bool) -> Config {
        let uses: Arc<crate::procs::Uses> = Arc::new(|| Ok::<Vec<Process>, String>(Vec::new()));
        let open: Arc<crate::procs::Open> = Arc::new(|_: &Path| Ok(None));
        Config {
            pass: pass::Options {
                roots: Vec::new(),
                sessions: Vec::new(),
                uses,
                open,
                settings: crate::policy::Settings::default(),
                apply,
                pressure: None,
                only: Vec::new(),
                still: None,
                measure: true,
                guarded: Arc::new(|_: &Path| false),
            },
            home: home.to_path_buf(),
            store: Store::open(home.join("store")).unwrap(),
            apply,
            only_families: vec!["xcode-derived-data".into()],
            off: Vec::new(),
            clean_caches: true,
            clone_roots: Vec::new(),
            pressure: Some(Pressure::High),
        }
    }

    fn project(home: &Path, name: &str, days_old: u64) -> PathBuf {
        let path = home.join("Library/Developer/Xcode/DerivedData").join(name);
        std::fs::create_dir_all(path.join("Build")).unwrap();
        std::fs::write(path.join("Build/app.o"), vec![0u8; 8192]).unwrap();
        let when = std::time::SystemTime::now() - std::time::Duration::from_secs(days_old * 86_400);
        for p in [path.join("Build/app.o"), path.join("Build"), path.clone()] {
            std::fs::File::open(&p).unwrap().set_modified(when).unwrap();
        }
        path
    }

    #[test]
    fn a_pass_removes_an_idle_cache_and_writes_the_ledger() {
        let home = scratch("care-ledger");
        let old = project(&home, "Old-abc", 20);
        let config = config(&home, true);
        let report = run(&config, None).unwrap();
        assert!(!old.exists(), "{:?}", report.caches.items);
        assert!(report.freed > 0);
        let rows = Ledger::in_dir(&config.store.dir).for_path(&old, 10);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].family, "xcode-derived-data");
        assert_eq!(rows[0].action, "removed");
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn a_dry_run_removes_nothing_and_a_cleaning_switch_off_keeps_caches() {
        let home = scratch("care-dry");
        let old = project(&home, "Old-abc", 20);
        run(&config(&home, false), None).unwrap();
        assert!(old.exists());
        let mut off = config(&home, true);
        off.clean_caches = false;
        run(&off, None).unwrap();
        assert!(old.exists());
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn a_family_switched_off_is_left_alone() {
        let home = scratch("care-off");
        let old = project(&home, "Old-abc", 20);
        let mut config = config(&home, true);
        config.off = vec!["xcode-derived-data".into()];
        run(&config, None).unwrap();
        assert!(old.exists());
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn the_never_delete_file_keeps_what_it_names() {
        let home = scratch("care-never");
        let old = project(&home, "Keep-me-abc", 20);
        let gone = project(&home, "Old-def", 20);
        std::fs::create_dir_all(crate::never_delete::user_file(&home).parent().unwrap()).unwrap();
        std::fs::write(crate::never_delete::user_file(&home), "# mine\nKeep-me-*\n").unwrap();
        let config = config(&home, true);
        let report = run(&config, None).unwrap();
        assert!(old.exists());
        assert!(!gone.exists());
        let item = report.caches.items.iter().find(|i| i.path == old).unwrap();
        assert!(item.verdict.reason.contains("never-delete"), "{}", item.verdict.reason);
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn a_family_filtered_pass_reads_no_worktree_from_sessions() {
        let home = scratch("care-filtered");
        let repo = home.join("repo");
        std::fs::create_dir_all(&repo).unwrap();
        let git = |dir: &Path, args: &[&str]| {
            let out = std::process::Command::new("git")
                .args(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"])
                .args(args)
                .current_dir(dir)
                .output()
                .unwrap();
            assert!(out.status.success(), "{args:?}: {}", String::from_utf8_lossy(&out.stderr));
        };
        git(&repo, &["init", "-q", "-b", "main"]);
        git(&repo, &["commit", "-q", "--allow-empty", "-m", "one"]);
        let linked = home.join("linked");
        git(&repo, &["worktree", "add", "-q", "-b", "side", &linked.to_string_lossy()]);
        let mut config = config(&home, true);
        config.pass.sessions = vec![crate::policy::Session {
            name: "s".into(),
            cwd: repo.clone(),
            open: false,
            archived_checkout: None,
            updated_ms: 0,
            ids: Vec::new(),
        }];
        let report = run(&config, None).unwrap();
        assert!(report.worktrees.items.is_empty(), "{:?}", report.worktrees.items);
        assert!(report.worktrees.expired.is_empty());
        assert!(linked.exists());
        let _ = std::fs::remove_dir_all(&home);
    }

    /// Every family but DerivedData off: a whole pass that reads only the scratch home.
    fn whole(home: &Path) -> Config {
        let mut config = config(home, false);
        config.only_families = Vec::new();
        config.off =
            caches::families(&caches::Layout { home, worktree_roots: &[], clone_roots: &[] })
                .iter()
                .map(|f| f.name.to_string())
                .filter(|name| name != "xcode-derived-data")
                .collect();
        config
    }

    #[test]
    fn a_whole_pass_is_what_status_reads_back_without_walking() {
        let home = scratch("care-status");
        project(&home, "Old-abc", 30);
        let config = whole(&home);
        assert!(status(&home, &config.store, &Default::default()).unwrap().last.is_none());
        let report = run(&config, None).unwrap();
        assert!(report.reclaimable >= 8192);
        assert_eq!(report.cost.sizes_walked, 1);

        let _ = crate::walk_memo::take_cost();
        let shown = status(&home, &config.store, &Default::default()).unwrap();
        let last = shown.last.expect("the pass was recorded");
        assert_eq!(last.reclaimable(), report.reclaimable);
        assert!(
            last.families().iter().any(|f| f.name == "xcode-derived-data" && f.reclaimable >= 8192)
        );
        assert_eq!(crate::walk_memo::take_cost(), crate::walk_memo::Cost::default());

        // The next pass measures nothing again: the memo answers.
        let again = run(&config, None).unwrap();
        assert_eq!(again.reclaimable, report.reclaimable);
        assert_eq!((again.cost.sizes_walked, again.cost.sizes_reused, again.cost.stats), (0, 1, 0));
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn a_filtered_pass_is_not_recorded_for_status() {
        let home = scratch("care-status-filtered");
        project(&home, "Old-abc", 30);
        let config = config(&home, false);
        run(&config, None).unwrap();
        assert!(last_pass(&config.store).is_none());
        let _ = std::fs::remove_dir_all(&home);
    }
}
