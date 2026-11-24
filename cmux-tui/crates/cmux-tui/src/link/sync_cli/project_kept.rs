//! Tracked files the copy's rules keep on this Mac, for a projection's manifest (RFD 0007,
//! "Tracked files the skip rules keep home": "the manifest lists such a tracked path with its real
//! stat and no bytes; opening it fails with `EACCES` and a named reason, so `git status` is clean
//! and the boundary holds").
//!
//! A folder that is not itself a repository (`~/Projects`) is walked plainly, and the walk leaves
//! out secrets, credential folders and heavy folders at any depth, whether or not a repository
//! below tracks them: kubernetes' 79 committed test keys stayed here, so `git status` on the
//! machine listed each as deleted. Each repository the walk sent (its `.git` is in the listing) is
//! asked what it tracks; a tracked regular file the walk left out by one of those rules goes in the
//! manifest with this Mac's stat and why, and nothing is served for it ([`super::project`]'s
//! source refuses any entry it has no file for). A repository folder itself lists every tracked
//! file (tracked secrets were committed on purpose), so it has none to add.
//!
//! Leo, 2026-11-22: "THE WHOLE POINT OF PROJECTIONFS IS FOR AGENTS TO BE ABLE TO DO THIS".

use std::collections::HashSet;
use std::os::unix::fs::MetadataExt as _;
use std::path::Path;

use cmux_projection::manifest::{Item, Kind};

use super::local::{self, LocalSet};
use super::skips::{self, Why};

/// One tracked file kept here: its manifest item (this Mac's stat) and why it stays.
pub(super) struct Kept {
    pub item: Item,
    pub why: Why,
}

/// Every file a repository below `folder` tracks that the plain walk `set` left out by a skip rule,
/// with its stat. None for a repository folder (`set.git`): its listing holds every tracked file.
pub(super) fn tracked_kept(folder: &Path, set: &LocalSet) -> Vec<Kept> {
    if set.git {
        return Vec::new();
    }
    let listed = |path: &str| set.files.contains_key(path) || set.links.contains_key(path);
    let mut seen: HashSet<String> = HashSet::new();
    let mut dirs: HashSet<String> = HashSet::new();
    let mut kept = Vec::new();
    for repo in repositories(set) {
        let Ok(names) = local::git_bytes(&folder.join(&repo), &["ls-files", "-z", "--cached"])
        else {
            continue;
        };
        for name in names.split(|byte| *byte == 0).filter(|name| !name.is_empty()) {
            let Ok(name) = std::str::from_utf8(name) else { continue };
            // A crafted index can name a file anywhere: only a plain path below its repository.
            if !local::below(name) {
                continue;
            }
            let path = if repo.is_empty() { name.to_owned() } else { format!("{repo}/{name}") };
            if listed(&path) || !local::holdable(&path) || !seen.insert(path.clone()) {
                continue;
            }
            let Some(why) = why_kept(folder, &path) else { continue };
            let Some(item) = stat_beneath(folder, &path, &mut dirs) else { continue };
            kept.push(Kept { item, why });
        }
    }
    kept
}

/// The repositories the walk sent, by their folder in `set` (its `.git` folder or file listed).
fn repositories(set: &LocalSet) -> Vec<String> {
    let mut repos: Vec<String> = set
        .files
        .keys()
        .filter_map(|path| {
            let dotgit = path.strip_suffix("/HEAD").unwrap_or(path);
            if dotgit == ".git" {
                Some(String::new())
            } else {
                dotgit.strip_suffix("/.git").map(str::to_owned)
            }
        })
        .collect();
    repos.sort();
    repos.dedup();
    repos
}

/// Which skip rule of the plain walk keeps `relative` here, in the walk's own order: a credential
/// or heavy folder on its way, then the file's own name. None when no rule does (gone, or left out
/// for another reason): such a file is not listed.
fn why_kept(folder: &Path, relative: &str) -> Option<Why> {
    let names: Vec<&str> = relative.split('/').collect();
    // Every folder on the way: each name but the last, with the path above it.
    let mut parent = String::new();
    for name in names.iter().zip(names.iter().skip(1)).map(|(name, _)| *name) {
        let dir = if parent.is_empty() { name.to_owned() } else { format!("{parent}/{name}") };
        if let Some(why) = skips::credential(&dir, true) {
            return Some(why);
        }
        if skips::heavy(&folder.join(&parent), name) {
            return Some(Why::Heavy);
        }
        parent = dir;
    }
    skips::secret_at(folder, relative).or_else(|| skips::credential(relative, false))
}

/// `relative`'s stat as a manifest file, when it is a regular file reached through real folders
/// only (no symlink on its way, so no stat from outside `folder`). `dirs` caches the folders
/// already checked.
fn stat_beneath(folder: &Path, relative: &str, dirs: &mut HashSet<String>) -> Option<Item> {
    let mut at = String::new();
    let mut parts = relative.split('/').peekable();
    while let Some(name) = parts.next() {
        if parts.peek().is_none() {
            break;
        }
        at = if at.is_empty() { name.to_owned() } else { format!("{at}/{name}") };
        if dirs.contains(&at) {
            continue;
        }
        if !std::fs::symlink_metadata(folder.join(&at)).is_ok_and(|meta| meta.is_dir()) {
            return None;
        }
        dirs.insert(at.clone());
    }
    let meta =
        std::fs::symlink_metadata(folder.join(relative)).ok().filter(|meta| meta.is_file())?;
    Some(Item {
        path: relative.to_owned(),
        kind: Kind::File,
        mode: local::permissions_of(meta.mode()),
        size: meta.len(),
        mtime_ns: meta.mtime().saturating_mul(1_000_000_000).saturating_add(meta.mtime_nsec()),
        link: None,
    })
}
