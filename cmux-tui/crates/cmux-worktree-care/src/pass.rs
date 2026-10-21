//! One pass over a machine's worktrees: inventory, a verdict for each, and
//! (with `apply`) the actions. A pass reads the processes once up front and
//! refuses to act without them; every action checks them again.

use std::path::PathBuf;

use serde::Serialize;

use crate::archive;
use crate::disk::{self, Usage};
use crate::inventory::{self, now_ms};
use crate::policy::{self, Action, Pressure, Session, Settings, Verdict};
use crate::procs;
use crate::store::Store;

/// What a pass looks at and may do.
#[derive(Debug, Clone)]
pub struct Options {
    /// Folders whose repositories (the folder and its children) are read.
    pub roots: Vec<PathBuf>,
    /// The agent sessions on this machine.
    pub sessions: Vec<Session>,
    pub settings: Settings,
    /// Act; otherwise only report.
    pub apply: bool,
    /// Decide as if the disk were this full.
    pub pressure: Option<Pressure>,
    /// Only these worktrees (folders); all when empty.
    pub only: Vec<PathBuf>,
}

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
    /// With `apply`: what happened.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub outcome: Option<Outcome>,
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
    /// Repositories that could not be read, with why.
    pub errors: Vec<String>,
}

impl Report {
    pub fn count(&self, action: Action) -> usize {
        self.items.iter().filter(|item| item.verdict.action == action).count()
    }
}

/// Runs one pass.
pub fn run(options: &Options, store: &Store) -> Result<Report, String> {
    // No process list, no action: a worktree some program uses could go.
    let processes = procs::working_folders()?;
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
        errors: Vec::new(),
    };
    let now = now_ms();
    for common in repositories {
        let repo = match inventory::scan(&common, &[]) {
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
                if options.apply && !pruned {
                    pruned = true;
                    let _ = crate::git::user_git(
                        repo.main_root.as_deref().unwrap_or(&repo.common_dir),
                        &["worktree", "prune"],
                        crate::git::READ,
                    );
                }
                continue;
            }
            let verdict = policy::decide(
                worktree,
                &options.sessions,
                &processes,
                pressure,
                &options.settings,
                now,
            );
            let facts = worktree.facts.as_ref().ok();
            let outcome = match (options.apply, verdict.action, facts) {
                (true, Action::Trim, Some(facts)) => {
                    Some(outcome(archive::trim(worktree, facts).map(|f| (f, None))))
                }
                (true, Action::Reclaim | Action::Archive, Some(facts)) => Some(outcome(
                    archive::reclaim(
                        &repo,
                        worktree,
                        facts,
                        verdict.action,
                        &verdict.reason,
                        store,
                    )
                    .map(|m| (m.freed, Some(m.id))),
                )),
                _ => None,
            };
            if let Some(outcome) = &outcome {
                report.freed += outcome.freed;
            }
            report.items.push(Item {
                path: worktree.path.clone(),
                repository: repo.main_root.clone().unwrap_or_else(|| repo.common_dir.clone()),
                branch: worktree.branch.clone(),
                verdict,
                facts: facts.cloned(),
                outcome,
            });
        }
    }
    Ok(report)
}

fn outcome(result: Result<(u64, Option<String>), String>) -> Outcome {
    match result {
        Ok((freed, archive)) => Outcome { ok: true, freed, archive, error: None },
        Err(error) => Outcome { ok: false, freed: 0, archive: None, error: Some(error) },
    }
}
