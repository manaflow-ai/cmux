//! Adapt the existing agent chat detectors to the import catalog. A chat's
//! folder is a hint, never proof of a worktree: git must still list it.
//! Transcripts stay at their source. Only their identities and paths leave
//! this adapter; titles, messages, credentials and environment values do not.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

pub use cmux_chat_index::AdapterKind;
use cmux_chat_index::IndexedChat;
use serde::Serialize;

use crate::catalog::{Catalog, Repo, Workspace};
use crate::git;

/// A bound on git inspections for one explicitly requested import scan.
pub const MAX_FOLDERS: usize = 1_000;

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize)]
pub struct ChatSource {
    pub tool: AdapterKind,
    pub session_id: String,
    pub path: PathBuf,
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct ToolCatalog {
    pub catalog: Catalog,
    /// Chat references by import workspace id, including existing Conductor ids.
    pub chats: BTreeMap<String, Vec<ChatSource>>,
    /// Tool provenance by workspace id, even when the caller only has the
    /// chat index's grouped project-folder rows.
    pub tools: BTreeMap<String, BTreeSet<AdapterKind>>,
    /// Folders git could not inspect. Never report subprocess output here:
    /// a repository's diagnostic may contain private configuration.
    pub unreadable: Vec<PathBuf>,
    /// One listing per canonical repository root, bounded across this scan.
    #[serde(skip)]
    listings: BTreeMap<PathBuf, Vec<git::ListEntry>>,
}

impl From<Catalog> for ToolCatalog {
    fn from(catalog: Catalog) -> Self {
        Self { catalog, ..Self::default() }
    }
}

impl ToolCatalog {
    /// Build plan facts using the listings this scan already verified. Scripts
    /// and environment names still use the existing Conductor settings reader.
    pub fn inspect(&self, home: &Path) -> crate::inspect::Facts {
        crate::inspect::inspect_cached(&self.catalog, home, &self.listings)
    }
}

/// Extend an existing catalog with worktrees found by any of the chat index's
/// supported tools. Callers supply the merged index so this neither rereads
/// transcripts nor creates another watcher. `admit` is the caller's path
/// policy, checked before filesystem access and again after resolving aliases.
///
/// The complete input is checked against the bound before running git; at
/// the bound this fails by name rather than presenting a truncated import.
pub fn catalog<'a>(
    existing: Catalog,
    chats: impl IntoIterator<Item = &'a IndexedChat>,
    admit: &dyn Fn(&Path) -> bool,
) -> Result<ToolCatalog, String> {
    let candidates = chats.into_iter().filter_map(|chat| {
        let entry = &chat.entry;
        Some(Candidate {
            cwd: PathBuf::from(entry.cwd.as_deref()?),
            tool: entry.harness,
            chat: Some(ChatSource {
                tool: entry.harness,
                session_id: entry.session_id.clone(),
                path: entry.source_path.clone(),
            }),
        })
    });
    collect(existing, candidates, admit)
}

/// The grouped `_acpmux/chat_projects` rows already relayed into the daemon's
/// project registry. No chat content or invented session references are needed.
pub fn folders<'a>(
    existing: Catalog,
    folders: impl IntoIterator<Item = &'a (AdapterKind, PathBuf)>,
    admit: &dyn Fn(&Path) -> bool,
) -> Result<ToolCatalog, String> {
    collect(
        existing,
        folders.into_iter().map(|(tool, cwd)| Candidate {
            cwd: cwd.clone(),
            tool: *tool,
            chat: None,
        }),
        admit,
    )
}

struct Candidate {
    cwd: PathBuf,
    tool: AdapterKind,
    chat: Option<ChatSource>,
}

#[derive(Default)]
struct Sources {
    tools: BTreeSet<AdapterKind>,
    chats: BTreeSet<ChatSource>,
}

fn collect(
    existing: Catalog,
    candidates: impl IntoIterator<Item = Candidate>,
    admit: &dyn Fn(&Path) -> bool,
) -> Result<ToolCatalog, String> {
    let started = Instant::now();
    let mut folders: BTreeMap<PathBuf, Sources> = BTreeMap::new();
    for (index, candidate) in candidates.into_iter().enumerate() {
        if index >= crate::catalog::MAX_ROWS {
            return Err(format!(
                "agent import has more than {} source rows",
                crate::catalog::MAX_ROWS
            ));
        }
        deadline(started)?;
        let cwd = &candidate.cwd;
        if !cwd.is_absolute() || !admit(cwd) {
            continue;
        }
        let Ok(folder) = std::fs::canonicalize(cwd) else { continue };
        if !folder.is_dir() || !admit(&folder) {
            continue;
        }
        let sources = folders.entry(folder).or_default();
        sources.tools.insert(candidate.tool);
        sources.chats.extend(candidate.chat);
        if folders.len() > MAX_FOLDERS {
            return Err(format!("agent import has more than {MAX_FOLDERS} folders"));
        }
    }

    let mut out = ToolCatalog { catalog: existing, ..ToolCatalog::default() };
    let mut roots = BTreeMap::new();
    let mut workspaces = BTreeMap::new();
    for repo in &out.catalog.repos {
        if let Some(path) = repo.root_path.as_deref().and_then(|path| resolve(path, admit)) {
            roots.insert(path, repo.id.clone());
        }
    }
    for workspace in &out.catalog.workspaces {
        if let Some(path) = workspace.path.as_deref().and_then(|path| resolve(path, admit)) {
            workspaces.insert(path, workspace.id.clone());
        }
    }
    let mut linked: BTreeMap<String, BTreeSet<ChatSource>> = BTreeMap::new();
    let mut cached_entries = 0;
    for (folder, sources) in folders {
        let listing = match git::worktrees_within(&folder, remaining(started)?) {
            Ok(listing) => listing,
            Err(_) => {
                out.unreadable.push(folder);
                continue;
            }
        };
        let Some(main) = listing.first() else { continue };
        let Some(root) = resolve(&main.path, admit) else { continue };
        // A chat can run in a subfolder. The longest matching linked worktree
        // owns it; the main checkout is never an additional workspace.
        let candidate = listing
            .iter()
            .skip(1)
            .filter(|entry| !entry.prunable)
            .filter_map(|entry| resolve(&entry.path, admit).map(|path| (entry, path)))
            .filter(|(_, path)| folder.starts_with(path))
            .max_by_key(|(_, path)| path.components().count());
        let Some((entry, path)) = candidate else { continue };
        if !out.listings.contains_key(&root) {
            if listing.len() > crate::catalog::MAX_ROWS - cached_entries {
                return Err(format!(
                    "agent import has more than {} cached worktree entries",
                    crate::catalog::MAX_ROWS
                ));
            }
            cached_entries += listing.len();
            out.listings.insert(root.clone(), listing.clone());
        }
        let repo_id = roots.entry(root.clone()).or_insert_with(|| {
            let id = identity(&root);
            out.catalog.repos.push(Repo {
                id: id.clone(),
                name: name(&root),
                root_path: Some(root),
                ..Repo::default()
            });
            id
        });
        let workspace_id = workspaces.entry(path.clone()).or_insert_with(|| {
            let id = identity(&path);
            out.catalog.workspaces.push(Workspace {
                id: id.clone(),
                repo_id: repo_id.clone(),
                branch: entry.branch.clone(),
                state: "ready".into(),
                path: Some(path),
                archive_commit: None,
            });
            id
        });
        linked.entry(workspace_id.clone()).or_default().extend(sources.chats);
        out.tools.entry(workspace_id.clone()).or_default().extend(sources.tools);
    }
    deadline(started)?;
    out.chats =
        linked.into_iter().map(|(id, sources)| (id, sources.into_iter().collect())).collect();
    Ok(out)
}

fn deadline(started: Instant) -> Result<(), String> {
    remaining(started).map(|_| ())
}

fn remaining(started: Instant) -> Result<Duration, String> {
    Duration::from_secs(30)
        .checked_sub(started.elapsed())
        .filter(|remaining| !remaining.is_zero())
        .ok_or_else(|| "agent import exceeded its 30 second inspection budget".into())
}

fn resolve(path: &Path, admit: &dyn Fn(&Path) -> bool) -> Option<PathBuf> {
    if !path.is_absolute() || !admit(path) {
        return None;
    }
    let resolved = std::fs::canonicalize(path).ok()?;
    admit(&resolved).then_some(resolved)
}

fn identity(path: &Path) -> String {
    format!("agent-worktree:{}", path.to_string_lossy())
}

fn name(path: &Path) -> String {
    path.file_name().unwrap_or_default().to_string_lossy().into_owned()
}
