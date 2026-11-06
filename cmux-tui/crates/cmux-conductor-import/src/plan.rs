//! The dry run: what an import would make, before anything is made. Pure:
//! the catalog, the facts [`crate::inspect`] gathered, the ledger and the
//! cmux workspaces open now go in, the plan comes out.
//!
//! - Each repository becomes a project (hidden ones and folders that are no
//!   longer a repository are skipped, with the reason).
//! - A `ready` workspace whose folder `git worktree list` still lists is
//!   adopted in place, checked. A folder that is not one of the
//!   repository's worktrees is never adopted.
//! - An `archived` workspace (or a ready one whose folder is gone) whose
//!   commit or branch still exists is recoverable, unchecked.
//! - A workspace the ledger has as done stays done while its cmux workspace
//!   is open; one closed since is offered again, unchecked. One the ledger
//!   has as pending was cut off: its half-made workspace is closed first.
//! - Setup and archive scripts become the project's workspace setup and
//!   teardown, shown as written; `CONDUCTOR_*` variables are set as aliases
//!   of cmux's. "Files to copy" become `.worktreeinclude` lines.

use std::collections::BTreeSet;
use std::path::PathBuf;

use serde::Serialize;

use crate::catalog::Catalog;
use crate::chats::ChatLink;
use crate::inspect::Facts;
use crate::ledger::{Ledger, Stage};
use crate::settings::{Note, RunScript};

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct Plan {
    /// The database (or workspaces folder) read.
    pub source: PathBuf,
    pub cloud_read_only: &'static str,
    pub cloud_shutdown: &'static str,
    pub projects: Vec<ProjectPlan>,
    /// cmux workspaces a cut-off run half made, closed before they are made again.
    pub cleanup: Vec<String>,
    pub warnings: Vec<Warning>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct ProjectPlan {
    pub repo_id: String,
    pub name: String,
    pub path: Option<PathBuf>,
    /// Why it is not imported; none when it is.
    pub skipped: Option<String>,
    /// Shown as written before it is saved.
    pub setup: Option<String>,
    pub teardown: Option<String>,
    pub run: Vec<RunScript>,
    /// `CONDUCTOR_*` name and the cmux variable it is set from.
    pub aliases: Vec<(String, String)>,
    /// Lines the repository's `.worktreeinclude` gains.
    pub worktreeinclude: Vec<String>,
    /// Variables Conductor set: names only. cmux does not bring the values.
    pub env_names: Vec<String>,
    pub notes: Vec<Note>,
    pub workspaces: Vec<WorkspacePlan>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct WorkspacePlan {
    pub id: String,
    /// The folder's name (Conductor's workspace name).
    pub name: String,
    pub branch: Option<String>,
    pub path: Option<PathBuf>,
    pub disposition: Disposition,
    /// Selected in the plan the person confirms.
    pub checked: bool,
    pub chats: Option<ChatLink>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum Disposition {
    /// Opened as a cmux workspace at its folder and branch.
    Adopt,
    /// Can be brought back as a worktree from this commit or branch.
    Recoverable {
        from: String,
    },
    /// An earlier import made it and it is still open.
    AlreadyImported {
        cmux_workspace: String,
    },
    Skip {
        reason: SkipReason,
    },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum SkipReason {
    /// Its project is skipped.
    Project,
    /// Conductor Cloud's own clone.
    Cloud,
    /// The folder is there but is not one of the repository's worktrees.
    NotAWorktree,
    /// No folder, and no commit or branch to bring it back from.
    Gone,
    /// A state this build does not know.
    UnknownState,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Warning {
    pub code: &'static str,
    pub detail: String,
}

/// Archiving in Conductor deletes the worktree folder, which cmux now uses.
pub const ARCHIVE_DELETES_FOLDER: &str = "archive-deletes-folder";
/// A workspace whose repository Conductor no longer lists.
pub const ORPHAN_WORKSPACE: &str = "orphan-workspace";

pub fn plan(catalog: &Catalog, facts: &Facts, ledger: &Ledger, live: &BTreeSet<String>) -> Plan {
    let mut out = Plan {
        source: catalog.database.clone(),
        cloud_read_only: crate::CLOUD_READ_ONLY,
        cloud_shutdown: crate::CLOUD_SHUTDOWN,
        ..Plan::default()
    };
    for repo in &catalog.repos {
        let repo_facts = facts.repos.get(&repo.id).cloned().unwrap_or_default();
        let skipped = if repo.hidden {
            Some("hidden in Conductor".to_string())
        } else {
            repo_facts.unusable.clone()
        };
        let settings = &repo_facts.settings;
        let mut project = ProjectPlan {
            repo_id: repo.id.clone(),
            name: repo.name.clone(),
            path: repo.root_path.clone(),
            skipped: skipped.clone(),
            ..ProjectPlan::default()
        };
        if skipped.is_none() {
            project.setup = settings.setup.clone();
            project.teardown = settings.teardown.clone();
            project.run = settings.run.clone();
            project.aliases = crate::VARIABLE_ALIASES
                .iter()
                .filter(|(conductor, _)| {
                    settings.conductor_variables.iter().any(|used| used == conductor)
                })
                .map(|(conductor, cmux)| ((*conductor).to_string(), (*cmux).to_string()))
                .collect();
            project.worktreeinclude = settings
                .files_to_copy
                .iter()
                .filter(|glob| {
                    !repo_facts.worktreeinclude.iter().any(|line| line.trim() == glob.as_str())
                })
                .cloned()
                .collect();
            project.env_names = settings.env_names.clone();
            project.notes = settings.notes.clone();
        }
        for workspace in catalog.workspaces.iter().filter(|w| w.repo_id == repo.id) {
            let ws_facts = facts.workspaces.get(&workspace.id).cloned().unwrap_or_default();
            let entry = ledger.workspaces.get(&workspace.id);
            let open =
                entry.and_then(|e| e.cmux_workspace.as_ref()).filter(|id| live.contains(*id));
            if let (Some(entry), Some(open)) = (entry, open)
                && entry.stage == Stage::Pending
            {
                out.cleanup.push(open.clone());
            }
            let recover_from = workspace
                .archive_commit
                .clone()
                .filter(|_| ws_facts.commit_exists)
                .or_else(|| workspace.branch.clone().filter(|_| ws_facts.branch_exists));
            let (disposition, checked) = if skipped.is_some() {
                (Disposition::Skip { reason: SkipReason::Project }, false)
            } else if ws_facts.cloud {
                (Disposition::Skip { reason: SkipReason::Cloud }, false)
            } else if let (Some(entry), Some(open)) = (entry, open)
                && entry.stage == Stage::Done
            {
                (Disposition::AlreadyImported { cmux_workspace: open.clone() }, false)
            } else {
                // Done but closed in cmux since: offered again, unchecked.
                let again = entry.is_some_and(|e| e.stage == Stage::Done);
                match workspace.state.as_str() {
                    "ready" if ws_facts.listed.is_some() => (Disposition::Adopt, !again),
                    "ready" if ws_facts.folder_exists => {
                        (Disposition::Skip { reason: SkipReason::NotAWorktree }, false)
                    }
                    "ready" | "archived" => match recover_from {
                        Some(from) => (Disposition::Recoverable { from }, false),
                        None => (Disposition::Skip { reason: SkipReason::Gone }, false),
                    },
                    _ => (Disposition::Skip { reason: SkipReason::UnknownState }, false),
                }
            };
            let branch = ws_facts
                .listed
                .as_ref()
                .and_then(|listed| listed.branch.clone())
                .or_else(|| workspace.branch.clone());
            project.workspaces.push(WorkspacePlan {
                id: workspace.id.clone(),
                name: workspace
                    .path
                    .as_deref()
                    .and_then(|path| path.file_name())
                    .map(|name| name.to_string_lossy().into_owned())
                    .unwrap_or_else(|| workspace.id.clone()),
                branch,
                path: workspace.path.clone(),
                disposition,
                checked,
                chats: ws_facts.chats.clone(),
            });
        }
        out.projects.push(project);
    }
    for workspace in &catalog.workspaces {
        if !catalog.repos.iter().any(|repo| repo.id == workspace.repo_id) {
            out.warnings.push(Warning {
                code: ORPHAN_WORKSPACE,
                detail: format!(
                    "workspace {} belongs to no repository Conductor lists",
                    workspace.id
                ),
            });
        }
    }
    let adopting = out
        .projects
        .iter()
        .flat_map(|project| &project.workspaces)
        .any(|workspace| workspace.disposition == Disposition::Adopt);
    if adopting {
        out.warnings.push(Warning {
            code: ARCHIVE_DELETES_FOLDER,
            detail: "Archiving one of these workspaces in Conductor deletes its folder, which cmux now uses. \
                     Archive it in cmux instead."
                .into(),
        });
    }
    out
}
