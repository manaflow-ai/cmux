//! The facts the plan needs, gathered from disk and git: whether each
//! repository is still a repository, its worktrees (`git worktree list`),
//! its settings, and for each workspace whether its folder is one of those
//! worktrees, whether its archive commit or branch still exists, and its
//! linked chats. Read-only.

use std::borrow::Cow;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::catalog::{Catalog, Repo, Workspace};
use crate::chats::{self, ChatLink};
use crate::git;
use crate::settings::{self, RepoSettings};

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct Facts {
    /// By repo id.
    pub repos: BTreeMap<String, RepoFacts>,
    /// By workspace id.
    pub workspaces: BTreeMap<String, WorkspaceFacts>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct RepoFacts {
    /// Why the root is not a usable repository; none when it is.
    pub unusable: Option<String>,
    pub settings: RepoSettings,
    /// Lines of the repository's `.worktreeinclude`, when it has one.
    pub worktreeinclude: Vec<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct WorkspaceFacts {
    pub folder_exists: bool,
    /// `git worktree list` of its repository lists the folder (and does not
    /// call it prunable); the branch it has checked out, if any.
    pub listed: Option<Listed>,
    /// Its archive commit still exists in the repository.
    pub commit_exists: bool,
    /// Its recorded branch is still a local branch.
    pub branch_exists: bool,
    /// Under `~/conductor/cloud-workspaces`: Conductor Cloud's own clone.
    pub cloud: bool,
    pub chats: Option<ChatLink>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Listed {
    pub branch: Option<String>,
}

pub fn inspect(catalog: &Catalog, home: &Path) -> Facts {
    inspect_cached(catalog, home, &BTreeMap::new())
}

/// Reuse listings verified during this import's discovery. Only the tool
/// adapter can provide this cache; the public Conductor path remains uncached.
pub(crate) fn inspect_cached(
    catalog: &Catalog,
    home: &Path,
    verified: &BTreeMap<PathBuf, Vec<git::ListEntry>>,
) -> Facts {
    let mut facts = Facts::default();
    let cloud_root = crate::detect::cloud_workspaces_path(home);
    let mut listings: BTreeMap<&str, Cow<'_, [git::ListEntry]>> = BTreeMap::new();
    let mut cached = BTreeMap::new();
    for repo in &catalog.repos {
        let listing = repo
            .root_path
            .as_deref()
            .and_then(|root| std::fs::canonicalize(root).ok())
            .and_then(|root| verified.get(&root));
        cached.insert(repo.id.as_str(), listing.is_some());
        let (repo_facts, listing) = inspect_repo(repo, listing.map(Vec::as_slice));
        listings.insert(&repo.id, listing);
        facts.repos.insert(repo.id.clone(), repo_facts);
    }
    for workspace in &catalog.workspaces {
        let root = catalog
            .repos
            .iter()
            .find(|repo| repo.id == workspace.repo_id)
            .and_then(|repo| repo.root_path.as_deref())
            .filter(|_| facts.repos.get(&workspace.repo_id).is_some_and(|r| r.unusable.is_none()));
        let listing =
            listings.get(workspace.repo_id.as_str()).map(|rows| rows.as_ref()).unwrap_or(&[]);
        facts.workspaces.insert(
            workspace.id.clone(),
            inspect_workspace(
                workspace,
                root,
                listing,
                home,
                &cloud_root,
                cached.get(workspace.repo_id.as_str()).copied().unwrap_or(false),
            ),
        );
    }
    facts
}

fn inspect_repo<'a>(
    repo: &Repo,
    cached: Option<&'a [git::ListEntry]>,
) -> (RepoFacts, Cow<'a, [git::ListEntry]>) {
    let Some(root) = repo.root_path.as_deref() else {
        return (
            RepoFacts { unusable: Some("no folder recorded".into()), ..RepoFacts::default() },
            Cow::Borrowed(&[]),
        );
    };
    if !root.is_dir() {
        let reason = format!("{} no longer exists", root.display());
        return (RepoFacts { unusable: Some(reason), ..RepoFacts::default() }, Cow::Borrowed(&[]));
    }
    let listing = match cached
        .map_or_else(|| git::worktrees(root).map(Cow::Owned), |listing| Ok(Cow::Borrowed(listing)))
    {
        Ok(listing) => listing,
        Err(reason) => {
            let reason = format!("{} is not a git repository ({reason})", root.display());
            return (
                RepoFacts { unusable: Some(reason), ..RepoFacts::default() },
                Cow::Borrowed(&[]),
            );
        }
    };
    let worktreeinclude = std::fs::read_to_string(root.join(".worktreeinclude"))
        .map(|text| text.lines().map(str::to_string).collect())
        .unwrap_or_default();
    let facts = RepoFacts { unusable: None, settings: settings::read(repo, root), worktreeinclude };
    (facts, listing)
}

fn inspect_workspace(
    workspace: &Workspace,
    root: Option<&Path>,
    listing: &[git::ListEntry],
    home: &Path,
    cloud_root: &Path,
    cached: bool,
) -> WorkspaceFacts {
    let path = workspace.path.as_deref();
    let folder_exists = path.is_some_and(Path::is_dir);
    // The main worktree is the repository itself, never a workspace to adopt.
    let listed = path.filter(|_| folder_exists).and_then(|path| {
        listing
            .iter()
            .skip(1)
            .find(|entry| !entry.prunable && git::same_path(&entry.path, path))
            .map(|entry| Listed { branch: entry.branch.clone() })
    });
    let commit_exists = match (root, workspace.archive_commit.as_deref()) {
        (Some(root), Some(commit)) => git::has_commit(root, commit),
        _ => false,
    };
    let branch_exists = match (root, workspace.branch.as_deref()) {
        (Some(_), Some(branch))
            if cached
                && listed.as_ref().is_some_and(|entry| entry.branch.as_deref() == Some(branch)) =>
        {
            true
        }
        (Some(root), Some(branch)) => git::has_branch(root, branch),
        _ => false,
    };
    WorkspaceFacts {
        folder_exists,
        listed,
        commit_exists,
        branch_exists,
        cloud: path.is_some_and(|path| path.starts_with(cloud_root)),
        chats: path.and_then(|path| chats::claude_chats(home, path)),
    }
}

/// A catalog from Conductor's workspaces folder alone, for a machine whose
/// `conductor.db` is gone: each `<repo>/<workspace>` folder that is a linked
/// worktree, under the repository `git worktree list` names first.
pub fn catalog_from_folder(workspaces: &Path) -> Catalog {
    let mut catalog = Catalog { database: workspaces.to_path_buf(), ..Catalog::default() };
    let mut roots: BTreeMap<PathBuf, String> = BTreeMap::new();
    let Ok(repo_dirs) = std::fs::read_dir(workspaces) else { return catalog };
    let mut folders: Vec<PathBuf> = repo_dirs
        .filter_map(Result::ok)
        .filter(|entry| entry.path().is_dir())
        .flat_map(|entry| {
            std::fs::read_dir(entry.path()).into_iter().flatten().filter_map(Result::ok)
        })
        .map(|entry| entry.path())
        .filter(|path| path.join(".git").is_file())
        .collect();
    folders.sort();
    for folder in folders {
        let Ok(listing) = git::worktrees(&folder) else { continue };
        let Some(main) = listing.first() else { continue };
        let Some(entry) = listing.iter().skip(1).find(|entry| git::same_path(&entry.path, &folder))
        else {
            continue;
        };
        let repo_id = roots.entry(main.path.clone()).or_insert_with(|| {
            let id = main.path.to_string_lossy().into_owned();
            catalog.repos.push(Repo {
                id: id.clone(),
                name: main
                    .path
                    .file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_default(),
                root_path: Some(main.path.clone()),
                ..Repo::default()
            });
            id
        });
        catalog.workspaces.push(Workspace {
            id: folder.to_string_lossy().into_owned(),
            repo_id: repo_id.clone(),
            branch: entry.branch.clone(),
            state: "ready".into(),
            path: Some(folder),
            archive_commit: None,
        });
    }
    catalog
}
