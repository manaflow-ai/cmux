//! One pass over a machine's worktrees: inventory, a verdict for each, and
//! (with `apply`) the actions. A pass reads what works where (`uses`: the
//! registries of programs outside acpmux) once up front and refuses to act
//! without it; every action reads it again.

use std::path::PathBuf;
use std::sync::Arc;

use serde::Serialize;

use crate::archive;
use crate::disk::{self, Usage};
use crate::inventory::{self, now_ms};
use crate::policy::{self, Action, Pressure, Session, Settings, Verdict};
use crate::procs::{Open, Uses};
use crate::store::Store;

/// How long measuring one worktree may take.
const MEASURE: std::time::Duration = std::time::Duration::from_secs(10);

/// What a pass looks at and may do.
#[derive(Clone)]
pub struct Options {
    /// Folders whose repositories (the folder and its children) are read.
    pub roots: Vec<PathBuf>,
    /// The agent sessions on this machine.
    pub sessions: Vec<Session>,
    /// What else works where (`procs::claude_sessions`, ...).
    pub uses: Arc<Uses>,
    /// Whether a program has a folder open, checked right before it goes
    /// (`procs::open_inside`).
    pub open: Arc<Open>,
    pub settings: Settings,
    /// Act; otherwise only report.
    pub apply: bool,
    /// Decide as if the disk were this full.
    pub pressure: Option<Pressure>,
    /// Only these worktrees (folders); all when empty.
    pub only: Vec<PathBuf>,
    /// Measure the bytes each worktree a pass would act on takes.
    pub measure: bool,
    /// Act only on stale worktrees (`policy::stale`), and measure only
    /// them: the Storage panel's frees, which never touch work in progress.
    pub stale_only: bool,
    /// How long measuring may take in all; worktrees after it go
    /// unmeasured (`bytes` absent). None: no limit but `MEASURE` each.
    pub measure_budget: Option<std::time::Duration>,
    /// The sessions as they are now, read again right before each action
    /// (the daemon's live list): a chat that opened in a worktree while the
    /// pass scanned and measured keeps it. `sessions` is the scan's.
    pub sessions_now: Option<Arc<SessionsNow>>,
}

/// Reads the sessions as they are now (`Options::sessions_now`).
pub type SessionsNow = dyn Fn() -> Vec<Session> + Send + Sync;

/// One worktree's line in a report.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Item {
    pub path: PathBuf,
    pub repository: PathBuf,
    pub branch: Option<String>,
    pub verdict: Verdict,
    /// Facts the verdict came from, when readable.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub facts: Option<inventory::Facts>,
    /// With `measure`: the bytes acting on it would free (a lower bound
    /// when the walk ran out of time).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bytes: Option<u64>,
    /// With `apply`: what happened.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub outcome: Option<Outcome>,
    /// Clean, finished and used by nothing live (`policy::stale`).
    pub stale: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Outcome {
    pub ok: bool,
    pub freed: u64,
    /// The archive id, for a reclaimed worktree.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub archive: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Report {
    pub disk: Option<Usage>,
    pub pressure: Pressure,
    pub applied: bool,
    pub items: Vec<Item>,
    pub freed: u64,
    /// With `measure`: the bytes all actions would free.
    pub reclaimable: u64,
    /// Repositories that could not be read, with why.
    pub errors: Vec<String>,
    /// Archives dropped for their age.
    pub expired: Vec<String>,
}

impl Report {
    pub fn count(&self, action: Action) -> usize {
        self.items.iter().filter(|item| item.verdict.action == action).count()
    }
}

/// Runs one pass.
pub fn run(options: &Options, store: &Store) -> Result<Report, String> {
    // Housekeeping: every git the pass starts yields to the person at the
    // machine (background CPU and disk priority), on this thread only.
    let _background = cmux_git::run::background();
    // No process list, no action: a worktree some program uses could go.
    let processes = (options.uses)()?;
    let session_dirs: Vec<PathBuf> = options.sessions.iter().map(|s| s.cwd.clone()).collect();
    let repositories = inventory::repositories(&options.roots, &session_dirs);
    let disk = options.roots.first().and_then(|root| disk::usage(root));
    let pressure = options
        .pressure
        .unwrap_or_else(|| options.settings.pressure(disk.map_or(0.0, |d| d.used_fraction())));
    let mut report = Report {
        disk,
        pressure,
        applied: options.apply,
        items: Vec::new(),
        freed: 0,
        reclaimable: 0,
        errors: Vec::new(),
        expired: Vec::new(),
    };
    let now = now_ms();
    let measure_until = options.measure_budget.map(|budget| std::time::Instant::now() + budget);
    let finished = Arc::new(inventory::FinishedMemo::load(store.finished_path()));
    for common in repositories {
        let repo = match inventory::scan_with_memo(&common, &[], Arc::clone(&finished)) {
            Ok(repo) => repo,
            Err(error) => {
                report.errors.push(format!("{}: {error}", common.display()));
                continue;
            }
        };
        let mut pruned = false;
        for worktree in &repo.worktrees {
            if !options.only.is_empty() && !options.only.iter().any(|p| p == &worktree.path) {
                continue;
            }
            if worktree.prunable {
                // A stale-only pass touches only the folders it was given:
                // `git worktree prune` is repository-wide.
                if options.apply && !pruned && !options.stale_only {
                    pruned = true;
                    let _ = crate::git::user_git(
                        repo.main_root.as_deref().unwrap_or(&repo.common_dir),
                        // git gc's own wait: a folder on an unmounted
                        // volume, or moved by hand, keeps its HEAD,
                        // index and reflog.
                        &["worktree", "prune", "--expire=3.months.ago"],
                        crate::git::READ,
                    );
                }
                continue;
            }
            let verdict = policy::decide(
                worktree,
                repo.main_root.as_deref(),
                &options.sessions,
                &processes,
                pressure,
                &options.settings,
                now,
            );
            let facts = worktree.facts.as_ref().ok();
            let stale = policy::stale(&verdict, facts);
            let acts = verdict.action != Action::Keep && (stale || !options.stale_only);
            let in_budget = measure_until.is_none_or(|until| std::time::Instant::now() < until);
            let bytes = (options.measure && acts && in_budget)
                .then(|| measure(worktree, verdict.action, facts, measure_until));
            report.reclaimable += bytes.unwrap_or(0);
            let outcome = (options.apply && acts)
                .then(|| outcome(act(&repo, &worktree.path, &verdict, options, pressure, store)));
            if let Some(outcome) = &outcome {
                report.freed += outcome.freed;
            }
            report.items.push(Item {
                path: worktree.path.clone(),
                repository: repo.main_root.clone().unwrap_or_else(|| repo.common_dir.clone()),
                branch: worktree.branch.clone(),
                verdict,
                facts: facts.cloned(),
                bytes,
                outcome,
                stale,
            });
        }
    }
    finished.flush();
    if options.apply && options.only.is_empty() {
        let keep = options.settings.keep_archive_days * 24 * 60 * 60 * 1000;
        match archive::expire(store, now, keep) {
            Ok(ids) => report.expired = ids,
            Err(error) => report.errors.push(format!("archive expiry: {error}")),
        }
    }
    Ok(report)
}

/// Acts on a verdict with the worktree's facts and what works where read
/// again now, and the verdict decided again from them: the scan may be
/// minutes old, and a worktree whose verdict changed meanwhile stays.
fn act(
    repo: &inventory::Repo,
    path: &std::path::Path,
    planned: &Verdict,
    options: &Options,
    pressure: Pressure,
    store: &Store,
) -> Result<(u64, Option<String>), String> {
    let processes = (options.uses)()?;
    let fresh = inventory::rescan(repo, path)?;
    let mut sessions = options.sessions.clone();
    if let Some(now) = &options.sessions_now {
        sessions.extend(now());
    }
    let verdict = policy::decide(
        &fresh,
        repo.main_root.as_deref(),
        &sessions,
        &processes,
        pressure,
        &options.settings,
        now_ms(),
    );
    if verdict.action != planned.action {
        return Err(format!("it changed since the scan ({}); it stays", verdict.reason));
    }
    let facts = fresh.facts.as_ref().map_err(Clone::clone)?;
    if options.stale_only && !policy::stale(&verdict, Some(facts)) {
        return Err(format!("it is no longer stale ({}); it stays", verdict.reason));
    }
    match verdict.action {
        Action::Keep => Ok((0, None)),
        Action::Trim => archive::trim(&fresh, facts, &*options.uses).map(|freed| (freed, None)),
        Action::Reclaim | Action::Archive => archive::reclaim(
            repo,
            &fresh,
            facts,
            verdict.action,
            &verdict.reason,
            store,
            &*options.uses,
            &*options.open,
        )
        .map(|manifest| (manifest.freed, Some(manifest.id))),
    }
}

/// What acting on a worktree frees: its whole folder, or its build output
/// for a trim.
fn measure(
    worktree: &inventory::Worktree,
    action: Action,
    facts: Option<&inventory::Facts>,
    until: Option<std::time::Instant>,
) -> u64 {
    let own = std::time::Instant::now() + MEASURE;
    let deadline = until.map_or(own, |until| until.min(own));
    let parts: Vec<PathBuf> = facts
        .map(|f| f.build_output.iter().map(|p| PathBuf::from(p.trim_end_matches('/'))).collect())
        .unwrap_or_default();
    let sizes = disk::sizes(&worktree.path, &parts, deadline);
    match action {
        Action::Trim => sizes.parts.values().sum(),
        _ => sizes.total,
    }
}

fn outcome(result: Result<(u64, Option<String>), String>) -> Outcome {
    match result {
        Ok((freed, archive)) => Outcome { ok: true, freed, archive, error: None },
        Err(error) => Outcome { ok: false, freed: 0, archive: None, error: Some(error) },
    }
}
