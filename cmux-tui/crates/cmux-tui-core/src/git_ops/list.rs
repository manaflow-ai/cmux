//! `git.files.list`: the immediate children of one folder of a repository,
//! for a file explorer tree.
//!
//! The candidates are the ones `git.files.search` ranks: tracked files still
//! in the working tree and untracked files no ignore rule hides. Each is
//! folded into its first path component; a component with more below it is a
//! directory, and so is a lone component that is a real folder on disk (a
//! submodule). A symlink is never one at the look at the candidates: the
//! daemon reaches each candidate through real folders only, so no candidate
//! is below a link, and a link stays a leaf. Directories come first, then
//! names case-insensitively. The daemon's look stops at the first path of a
//! child it reaches, so a listing looks at the folder's children, not at
//! every path below it ([`children`]).

use std::collections::BTreeMap;
use std::path::Path;

use serde_json::{Value, json};

use super::Repository;
use super::files::{Folders, folder, listed, spelled};
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
    let below = folder(repository, directory, OPERATION)?;
    let (paths, cut) = listed(repository, directory, OPERATION)?;
    // A symlink is a leaf, as git records it: following one could list a folder
    // outside the repository. Only a real folder (a submodule) is a directory.
    let mut folders = Folders::of(repository, &below);
    let children = children(&paths, |path| folders.kind(path));
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
        "folder": spelled(repository, &below),
        "entries": entries,
        "truncated": cut || total > limit,
    }))
}

/// What one first component of the listed paths is, as far as the looks went.
#[derive(Default)]
struct Child {
    /// `Some(is a directory)` once a look reached a path of it.
    found: Option<bool>,
    /// A path below it was not reached and the name is no real folder: no
    /// other path below it can be reached either.
    no_folder: bool,
    /// The name itself was looked at (for `no_folder`), one time.
    name_looked: bool,
}

/// The children of the listed folder, name -> is a directory: each first
/// component of `paths` that a look (`kind`, [`Folders::kind`]) reaches.
///
/// A child is shown when one of its paths is reached; a path below it makes
/// it a directory (the daemon reached that path through it as a real folder),
/// and so does a lone name that is a real folder. The looks stop at the
/// first path reached, so a child costs one or two looks, not one per path
/// below it: listing a folder costs what it holds, not its whole subtree
/// (`files_stress_tests`). Only paths that are gone cost a look each.
fn children(paths: &[String], mut kind: impl FnMut(&str) -> Option<Kind>) -> BTreeMap<&str, bool> {
    let mut children: BTreeMap<&str, Child> = BTreeMap::new();
    for path in paths {
        let (name, nested) = match path.split_once('/') {
            Some((name, _)) => (name, true),
            None => (path.as_str(), false),
        };
        if name.is_empty() {
            continue;
        }
        let child = children.entry(name).or_default();
        if child.found.is_some() {
            continue;
        }
        if nested {
            if child.no_folder {
                continue;
            }
            if kind(path).is_some() {
                child.found = Some(true);
            } else if !child.name_looked {
                child.name_looked = true;
                child.no_folder = kind(name) != Some(Kind::Folder);
            }
        } else if let Some(found) = kind(name) {
            child.found = Some(found == Kind::Folder);
        }
    }
    children.into_iter().filter_map(|(name, child)| Some((name, child.found?))).collect()
}
