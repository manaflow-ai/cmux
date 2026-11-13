//! `git.files.list`: the immediate children of one folder of a repository,
//! for a file explorer tree.
//!
//! The candidates are the ones `git.files.search` ranks: tracked files still
//! in the working tree and untracked files no ignore rule hides. Each is
//! folded into its first path component; a component with more below it is a
//! directory, and so is a lone component that is a real folder on disk (a
//! submodule). A symlink is never one, also when git still lists tracked
//! paths below its name. Directories come first, then names
//! case-insensitively.

use std::collections::{BTreeMap, HashSet};
use std::path::Path;

use serde_json::{Value, json};

use super::Repository;
use super::files::{Folders, candidates, folder};
use super::work_tree_entry::Kind;
use crate::resource::ResourceError;

const OPERATION: &str = "git.files.list";
pub(super) const DEFAULT_LIMIT: usize = 2000;
pub(super) const MAX_LIMIT: usize = 5000;

pub(super) fn list(
    repository: &Repository,
    directory: &Path,
    fields: &serde_json::Map<String, Value>,
) -> Result<Value, ResourceError> {
    let limit = fields
        .get("limit")
        .and_then(Value::as_u64)
        .map_or(DEFAULT_LIMIT, |limit| usize::try_from(limit).unwrap_or(MAX_LIMIT))
        .clamp(1, MAX_LIMIT);
    let listed = folder(repository, directory, OPERATION)?;
    let (paths, cut) = candidates(repository, directory, OPERATION)?;
    // A symlink is a leaf, as git records it: following one could list a folder
    // outside the repository. Only a real folder (a submodule) is a directory.
    let mut folders = Folders::of(repository, &listed);
    // name -> is a directory
    let mut children: BTreeMap<&str, bool> = BTreeMap::new();
    // The names with listed paths below them that are a link in the work tree.
    let mut links: HashSet<&str> = HashSet::new();
    for path in &paths {
        let (name, nested) = match path.split_once('/') {
            Some((name, _)) => (name, true),
            None => (path.as_str(), false),
        };
        if name.is_empty() {
            continue;
        }
        let directory = children.entry(name).or_insert(false);
        if *directory || links.contains(name) {
            continue;
        }
        match (nested, folders.kind(name)) {
            // A link stays a leaf when git still lists tracked paths below its name.
            (true, Some(Kind::Link)) => {
                links.insert(name);
            }
            // Paths below the name: a folder, also one that is not on disk.
            (true, _) | (false, Some(Kind::Folder)) => *directory = true,
            (false, _) => {}
        }
    }
    let total = children.len();
    let mut children: Vec<(&str, bool)> = children.into_iter().collect();
    children.sort_by(|left, right| {
        right
            .1
            .cmp(&left.1)
            .then_with(|| left.0.to_lowercase().cmp(&right.0.to_lowercase()))
            .then_with(|| left.0.cmp(right.0))
    });
    let entries: Vec<Value> = children
        .iter()
        .take(limit)
        .map(|(name, directory)| {
            json!({"name": name, "kind": if *directory { "directory" } else { "file" }})
        })
        .collect();
    Ok(json!({
        "root": repository.root.to_string_lossy(),
        "folder": listed,
        "entries": entries,
        "truncated": cut || total > limit,
    }))
}
