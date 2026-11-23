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
//!
//! A folder in no repository lists too, from the disk alone
//! ([`list_folder`]): git status is extra to a file tree, never its
//! condition.

use std::collections::BTreeMap;
use std::path::Path;

use serde_json::{Value, json};

use super::Repository;
use super::files::{Folders, folder, spelled};
use super::read_cache;
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
    let limit = limit(fields);
    let below = folder(repository, directory, OPERATION)?;
    // The repository's cached listing: one `ls-files` answers every folder.
    let paths = read_cache::listed(repository, directory, &below, OPERATION)?;
    let cut = paths.truncated();
    // A symlink is a leaf, as git records it: following one could list a folder
    // outside the repository. Only a real folder (a submodule) is a directory.
    let mut folders = Folders::of(repository, &below);
    let children = children(paths.iter(), |path| folders.kind(path));
    let total = children.len();
    Ok(json!({
        "root": repository.root.to_string_lossy(),
        "folder": spelled(repository, &below),
        "entries": entries(children.into_iter().collect(), limit),
        "truncated": cut || total > limit,
    }))
}

/// Most names read from a folder in no repository. The reply is sorted, so
/// every name is read before the first is sent; past this many the rest are
/// not read and the reply says it is cut.
const MAX_FOLDER_NAMES: usize = 50_000;

/// `git.files.list` of `directory`, a folder in no repository (a person's
/// `~/Projects`): its children from one read of the folder, no walk below it.
/// Git status is extra to a listing, never its condition. Names that start
/// with `.` are left out, as Finder leaves them out, since no ignore rule says
/// what is noise here. A symlink is a leaf, as in a repository: the entry's
/// type follows no link, so the tree never lists a folder through one. A name
/// that is not UTF-8 is left out, since the page names a child by its text.
pub(super) fn list_folder(
    directory: &Path,
    fields: &serde_json::Map<String, Value>,
) -> Result<Value, ResourceError> {
    let limit = limit(fields);
    let unreadable = |error: std::io::Error| {
        ResourceError::operation_failed(
            OPERATION,
            format!("{} could not be listed: {error}", directory.display()),
            json!({"code":"unreadable","path":directory.to_string_lossy()}),
        )
    };
    let mut names: Vec<(String, bool)> = Vec::new();
    let mut cut = false;
    for entry in std::fs::read_dir(directory).map_err(unreadable)? {
        // An entry gone or unreadable since the folder was opened is not listed.
        let Ok(entry) = entry else { continue };
        let Ok(name) = entry.file_name().into_string() else { continue };
        if name.starts_with('.') {
            continue;
        }
        if names.len() == MAX_FOLDER_NAMES {
            cut = true;
            break;
        }
        let is_folder = entry.file_type().is_ok_and(|kind| kind.is_dir());
        names.push((name, is_folder));
    }
    let total = names.len();
    let children = names.iter().map(|(name, is_folder)| (name.as_str(), *is_folder)).collect();
    let folder = directory.to_string_lossy();
    Ok(json!({
        "root": folder,
        "folder": folder,
        "entries": entries(children, limit),
        "truncated": cut || total > limit,
    }))
}

fn limit(fields: &serde_json::Map<String, Value>) -> usize {
    fields
        .get("limit")
        .and_then(Value::as_u64)
        .map_or(DEFAULT_LIMIT, |limit| usize::try_from(limit).unwrap_or(MAX_LIMIT))
        .clamp(1, MAX_LIMIT)
}

/// The first `limit` of `children` (name, is a directory) as reply entries:
/// directories first, then names case-insensitively.
fn entries(mut children: Vec<(&str, bool)>, limit: usize) -> Vec<Value> {
    children.sort_by(|left, right| {
        right
            .1
            .cmp(&left.1)
            .then_with(|| left.0.to_lowercase().cmp(&right.0.to_lowercase()))
            .then_with(|| left.0.cmp(right.0))
    });
    children
        .iter()
        .take(limit)
        .map(|(name, directory)| {
            json!({"name": name, "kind": if *directory { "directory" } else { "file" }})
        })
        .collect()
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
fn children<'a>(
    paths: impl IntoIterator<Item = &'a str>,
    mut kind: impl FnMut(&str) -> Option<Kind>,
) -> BTreeMap<&'a str, bool> {
    let mut children: BTreeMap<&str, Child> = BTreeMap::new();
    for path in paths {
        let (name, nested) = match path.split_once('/') {
            Some((name, _)) => (name, true),
            None => (path, false),
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
