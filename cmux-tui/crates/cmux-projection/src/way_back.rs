//! The way back (RFD 0007, "Edits round-trip in O(edits)" and hard cases 4, 6 and 13): what Bring
//! Back does to the Mac's folder, planned from the projection's upper layer, its whiteouts, the
//! manifest the session started from, and the Mac's stat now of each path they touch. Pure: no
//! file is read or written here, so the plan costs O(edits), never O(folder).
//!
//! The rules, one per case:
//! - A path the machine changed (in the upper layer, its bytes or kind differ from the manifest's)
//!   is written to the Mac when the Mac's file still matches the manifest (kind, size and
//!   modification time; a link's text). When it does not, the Mac's file stays as it is and the
//!   machine's version is a named conflict, written beside it ([`Conflict::beside`]).
//! - A copy-up the machine never wrote (same size and modification time as the manifest: a
//!   `chmod`, or a file only opened for writing) is no write; a changed mode alone is a
//!   [`Chmod`], applied only where the Mac did not change the mode too.
//! - A whiteout is a delete when the Mac's file still matches the manifest, else a named conflict
//!   (the Mac's file is kept). A whiteout of a folder deletes the manifest's paths below it the
//!   same way, then the folder when nothing is left in it.
//! - A rename is a delete plus a create (no rename detection), as today's pull.
//! - A new name that folds (as a Mac's disk compares names) onto a name the Mac keeps is a named
//!   conflict, never an overwrite; one that folds onto a name this plan deletes (a case-only
//!   rename) is a plain write.
//! - Anything under a repository's `.git` is never copied as a file: those paths are grouped by
//!   repository ([`Plan::git`]) for the caller's HEAD and index three-way (`git_back.rs` in the
//!   app), and their whiteouts are ignored. A `.git` the manifest did not have (a repository made
//!   on the machine) is left out with everything below it ([`Plan::left_out`]).

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

use crate::manifest::{Entry, Kind, Manifest};

/// One path of the upper layer as the machine left it (the folder itself is never listed).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Upper {
    /// Relative to the folder, `/`-separated.
    pub path: String,
    pub kind: Kind,
    /// Bytes of a file (0 for a folder, the text's length for a link).
    pub size: u64,
    /// Permission bits.
    pub mode: u32,
    /// Modification time, nanoseconds since the epoch.
    pub mtime_ns: i64,
    /// A link's text.
    pub link: Option<String>,
}

/// What the Mac has at a path now.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MacStat {
    pub kind: Kind,
    pub size: u64,
    pub mode: u32,
    pub mtime_ns: i64,
    /// A link's text.
    pub link: Option<String>,
}

/// Write the upper layer's `path` to the Mac.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Write {
    pub path: String,
    pub kind: Kind,
    /// The mode it gets: the machine's when the machine changed it, else the Mac's.
    pub mode: u32,
    /// A link's text.
    pub link: Option<String>,
    /// What the Mac has there that this write replaces (it matched the manifest); None when the
    /// Mac has nothing there.
    pub replaces: Option<Kind>,
}

/// Delete the Mac's `path` (it matched the manifest). A folder goes only when empty.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Delete {
    pub path: String,
    pub kind: Kind,
}

/// Set the Mac's `path` to `mode`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Chmod {
    pub path: String,
    pub mode: u32,
}

/// Why a path is a conflict.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Why {
    /// The machine changed it and the Mac changed it too since the manifest.
    ChangedOnMac,
    /// The machine changed it and the Mac deleted it since the manifest.
    GoneOnMac,
    /// The machine made it new and the Mac has something there too.
    MadeOnBoth,
    /// The machine made a new name that folds onto `mac`, a name the Mac keeps.
    CaseFold { mac: String },
    /// The machine deleted it and the Mac changed it since the manifest: the Mac's stays.
    DeletedHereChangedThere,
    /// Both changed its mode, to different modes: the Mac's stays.
    ModeOnBoth,
}

impl Why {
    /// The reason in words, for the summary.
    #[must_use]
    pub fn text(&self) -> String {
        match self {
            Self::ChangedOnMac => "changed both on this Mac and on the machine".into(),
            Self::GoneOnMac => "deleted on this Mac and changed on the machine".into(),
            Self::MadeOnBoth => "made both on this Mac and on the machine".into(),
            Self::CaseFold { mac } => format!("the machine's name differs only by case from {mac}"),
            Self::DeletedHereChangedThere => {
                "deleted on the machine and changed on this Mac; this Mac's is kept".into()
            }
            Self::ModeOnBoth => "permissions changed differently on both".into(),
        }
    }
}

/// A path neither side's version of wins.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Conflict {
    pub path: String,
    pub why: Why,
    /// Whether the machine's version (an upper file or link) is to be written beside the Mac's
    /// path under a conflict name; false when the machine has nothing to keep (a delete, a mode).
    pub beside: bool,
}

/// What Bring Back does.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Plan {
    /// Folders before what they hold.
    pub writes: Vec<Write>,
    /// What a folder holds before the folder.
    pub deletes: Vec<Delete>,
    pub modes: Vec<Chmod>,
    pub conflicts: Vec<Conflict>,
    /// By repository (its folder, empty for the folder itself): the upper paths under its
    /// `.git`, for the HEAD and index three-way.
    pub git: BTreeMap<String, Vec<String>>,
    /// Upper paths that never come back, with why (a repository made on the machine).
    pub left_out: Vec<(String, String)>,
    /// Upper paths that are the manifest's own, unchanged (copy-ups).
    pub unchanged: u64,
}

impl Plan {
    /// Whether nothing changes on the Mac's files (the git leg aside).
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.writes.is_empty()
            && self.deletes.is_empty()
            && self.modes.is_empty()
            && self.conflicts.is_empty()
    }
}

/// Where a path sits with respect to repositories.
enum Place {
    /// An ordinary path.
    Plain,
    /// Under the `.git` of the repository at this folder.
    Git(String),
}

/// `path`'s place: the first component named `.git` (any case) makes it git's.
fn place(path: &str) -> Place {
    let mut root = Vec::new();
    for name in path.split('/') {
        if name.eq_ignore_ascii_case(".git") {
            return Place::Git(root.join("/"));
        }
        root.push(name);
    }
    Place::Plain
}

/// Whether the repository at `root` was the Mac's (the manifest has its `.git`).
fn known_repository(manifest: &Manifest, root: &str) -> bool {
    let dotgit = if root.is_empty() { ".git".to_owned() } else { format!("{root}/.git") };
    manifest.resolve(&dotgit).is_some()
}

/// The paths whose stat on the Mac [`plan`] needs: every plain upper path and every manifest path
/// a whiteout hides (a folder's included), sorted.
#[must_use]
pub fn touched(manifest: &Manifest, upper: &[Upper], whiteouts: &[String]) -> Vec<String> {
    let mut paths: BTreeSet<String> = upper
        .iter()
        .filter(|entry| matches!(place(&entry.path), Place::Plain))
        .map(|entry| entry.path.clone())
        .collect();
    for path in hidden(manifest, whiteouts) {
        paths.insert(path);
    }
    paths.into_iter().collect()
}

/// Every plain manifest path a whiteout hides: the whited-out path and everything below it.
fn hidden(manifest: &Manifest, whiteouts: &[String]) -> BTreeSet<String> {
    let mut out = BTreeSet::new();
    for whiteout in whiteouts {
        if !matches!(place(whiteout), Place::Plain) {
            continue;
        }
        let Some(index) = manifest.resolve(whiteout) else { continue };
        let mut stack = vec![(index, whiteout.clone())];
        while let Some((index, path)) = stack.pop() {
            let (first, children) = manifest.children(index);
            for (offset, child) in children.iter().enumerate() {
                let child_path = format!("{path}/{}", child.name);
                if matches!(place(&child_path), Place::Plain) {
                    stack.push((first + offset as u32, child_path));
                }
            }
            out.insert(path);
        }
    }
    out
}

/// Whether the Mac's path is still what the manifest listed: same kind, and a file's size and
/// modification time, a link's text. A folder always is (its time moves with what it holds).
fn unchanged(entry: &Entry, mac: &MacStat) -> bool {
    if entry.kind != mac.kind {
        return false;
    }
    match entry.kind {
        Kind::File => entry.size == mac.size && entry.mtime_ns == mac.mtime_ns,
        Kind::Link => entry.link == mac.link,
        Kind::Dir => true,
    }
}

/// Whether the upper path still holds the manifest's bytes: a copy-up keeps the manifest's size and
/// modification time until something writes it.
fn same_as_lower(entry: &Entry, upper: &Upper) -> bool {
    if entry.kind != upper.kind {
        return false;
    }
    match entry.kind {
        Kind::File => entry.size == upper.size && entry.mtime_ns == upper.mtime_ns,
        Kind::Link => entry.link == upper.link,
        Kind::Dir => true,
    }
}

/// The plan (module docs). `mac` holds the Mac's stat of [`touched`]'s paths (a path absent from
/// it is absent on the Mac). `fold` is how the Mac's disk compares a path (case and
/// normalization ignored); new names are checked with it.
#[must_use]
pub fn plan(
    manifest: &Manifest,
    upper: &[Upper],
    whiteouts: &[String],
    mac: &BTreeMap<String, MacStat>,
    fold: &dyn Fn(&str) -> String,
) -> Plan {
    let mut plan = Plan::default();
    let mut left_out_roots: BTreeSet<String> = BTreeSet::new();
    let mut plain: Vec<&Upper> = Vec::new();
    for entry in upper {
        match place(&entry.path) {
            Place::Plain => plain.push(entry),
            Place::Git(root) if known_repository(manifest, &root) => {
                plan.git.entry(root).or_default().push(entry.path.clone());
            }
            Place::Git(root) => {
                left_out_roots.insert(root);
            }
        }
    }
    // A repository made on the machine stays there, with its working files.
    let below_new_repository = |path: &str| {
        left_out_roots.iter().any(|root| {
            root.is_empty() || path == root.as_str() || path.starts_with(&format!("{root}/"))
        })
    };
    for root in &left_out_roots {
        let why = "a repository made on the machine stays there".to_owned();
        plan.left_out.push((if root.is_empty() { ".".into() } else { root.clone() }, why));
    }
    plain.retain(|entry| !below_new_repository(&entry.path));
    let in_upper: BTreeSet<&str> = plain.iter().map(|entry| entry.path.as_str()).collect();

    // Deletes first: what they free is what a case-only rename writes.
    let mut deleted_folded: BTreeMap<String, String> = BTreeMap::new();
    let hidden = hidden(manifest, whiteouts);
    for path in hidden.iter().rev() {
        if in_upper.contains(path.as_str()) || below_new_repository(path) {
            continue;
        }
        let Some(entry) = manifest.resolve(path).and_then(|index| manifest.entry(index)) else {
            continue;
        };
        let Some(now) = mac.get(path) else { continue };
        if entry.kind == Kind::Dir {
            if now.kind == Kind::Dir && !upper_below(&in_upper, path) {
                plan.deletes.push(Delete { path: path.clone(), kind: Kind::Dir });
            }
            continue;
        }
        if unchanged(entry, now) {
            plan.deletes.push(Delete { path: path.clone(), kind: entry.kind });
            deleted_folded.insert(fold(path), path.clone());
        } else {
            plan.conflicts.push(Conflict {
                path: path.clone(),
                why: Why::DeletedHereChangedThere,
                beside: false,
            });
        }
    }

    // The names the Mac keeps, folded: the manifest's (less what this plan deletes) and the new
    // names this plan writes, as it goes.
    let mut kept_folded: BTreeMap<String, String> = BTreeMap::new();
    let mut new_folded: BTreeMap<String, String> = BTreeMap::new();
    for entry in &plain {
        let path = entry.path.as_str();
        let lower = manifest.resolve(path).and_then(|index| manifest.entry(index));
        let now = mac.get(path);
        match lower {
            Some(lower) => changed_lower(&mut plan, entry, lower, now),
            None => {
                let folded = fold(path);
                if entry.kind != Kind::Dir {
                    let keeps = kept_folded
                        .entry(folded.clone())
                        .or_insert_with(|| {
                            folded_manifest_name(manifest, &deleted_folded, &folded, path, fold)
                        })
                        .clone();
                    let twin = new_folded.get(&folded).cloned();
                    if let Some(mac_name) = (!keeps.is_empty()).then_some(keeps).or(twin) {
                        plan.conflicts.push(Conflict {
                            path: path.to_owned(),
                            why: Why::CaseFold { mac: mac_name },
                            beside: true,
                        });
                        continue;
                    }
                    new_folded.insert(folded.clone(), path.to_owned());
                }
                new_path(&mut plan, entry, now, deleted_folded.contains_key(&folded));
            }
        }
    }
    plan.writes.sort_by(|a, b| a.path.cmp(&b.path));
    plan.deletes.sort_by(|a, b| b.path.cmp(&a.path));
    plan.modes.sort_by(|a, b| a.path.cmp(&b.path));
    plan.conflicts.sort_by(|a, b| a.path.cmp(&b.path));
    plan
}

/// Whether the upper layer holds anything below `folder`.
fn upper_below(in_upper: &BTreeSet<&str>, folder: &str) -> bool {
    let prefix = format!("{folder}/");
    in_upper.range(prefix.as_str()..).next().is_some_and(|path| path.starts_with(&prefix))
}

/// The manifest name (another spelling of `path`) that `folded` lands on and the Mac keeps; empty
/// when none. Looks up the folder's listing once per new name: O(names in that folder).
fn folded_manifest_name(
    manifest: &Manifest,
    deleted_folded: &BTreeMap<String, String>,
    folded: &str,
    path: &str,
    fold: &dyn Fn(&str) -> String,
) -> String {
    if deleted_folded.contains_key(folded) {
        return String::new();
    }
    let (parent, _) = path.rsplit_once('/').unwrap_or(("", path));
    // The parent may itself be spelled differently on the Mac: look it up folded too.
    let Some(parent_index) = resolve_folded(manifest, parent, fold) else { return String::new() };
    let parent_path = manifest.path_of(parent_index);
    let (_, children) = manifest.children(parent_index);
    children
        .iter()
        .map(|child| {
            if parent_path.is_empty() {
                child.name.clone()
            } else {
                format!("{parent_path}/{}", child.name)
            }
        })
        .find(|candidate| candidate != path && fold(candidate) == folded)
        .unwrap_or_default()
}

/// The manifest folder that `path` names under the Mac's comparison of names.
fn resolve_folded(manifest: &Manifest, path: &str, fold: &dyn Fn(&str) -> String) -> Option<u32> {
    if let Some(index) = manifest.resolve(path) {
        return Some(index);
    }
    let mut at = crate::manifest::ROOT;
    for name in path.split('/').filter(|name| !name.is_empty()) {
        if let Some(index) = manifest.lookup(at, name) {
            at = index;
            continue;
        }
        let want = fold(name);
        let (first, children) = manifest.children(at);
        let offset = children.iter().position(|child| fold(&child.name) == want)?;
        at = first + offset as u32;
    }
    Some(at)
}

/// An upper path the manifest has too.
fn changed_lower(plan: &mut Plan, entry: &Upper, lower: &Entry, now: Option<&MacStat>) {
    let path = entry.path.clone();
    if same_as_lower(lower, entry) {
        // A copy-up: only its mode may have changed (a folder's mode is left alone: copy-ups of
        // folders above a write gain the owner's bits).
        if entry.kind != Kind::File || entry.mode == lower.mode {
            plan.unchanged += 1;
            return;
        }
        let Some(now) = now else { return };
        if now.mode == lower.mode {
            plan.modes.push(Chmod { path, mode: entry.mode });
        } else if now.mode != entry.mode {
            plan.conflicts.push(Conflict { path, why: Why::ModeOnBoth, beside: false });
        }
        return;
    }
    let Some(now) = now else {
        plan.conflicts.push(Conflict {
            path,
            why: Why::GoneOnMac,
            beside: entry.kind != Kind::Dir,
        });
        return;
    };
    if !unchanged(lower, now) {
        plan.conflicts.push(Conflict {
            path,
            why: Why::ChangedOnMac,
            beside: entry.kind != Kind::Dir,
        });
        return;
    }
    let kept = entry.kind == lower.kind && entry.mode == lower.mode;
    let mode = if kept { now.mode } else { entry.mode };
    let replaces = Some(now.kind);
    plan.writes.push(Write { path, kind: entry.kind, mode, link: entry.link.clone(), replaces });
}

/// An upper path the manifest does not have. `frees` says this plan deletes a name it folds onto
/// (so the Mac's stat at `path` may be that name's, on a disk that ignores case).
fn new_path(plan: &mut Plan, entry: &Upper, now: Option<&MacStat>, frees: bool) {
    let path = entry.path.clone();
    match (entry.kind, now) {
        (Kind::Dir, None) => plan.writes.push(Write {
            path,
            kind: Kind::Dir,
            mode: entry.mode,
            link: None,
            replaces: None,
        }),
        (Kind::Dir, Some(now)) if now.kind == Kind::Dir => plan.unchanged += 1,
        (Kind::Dir, Some(_)) => {
            plan.conflicts.push(Conflict { path, why: Why::MadeOnBoth, beside: false });
        }
        (_, Some(_)) if !frees => {
            plan.conflicts.push(Conflict { path, why: Why::MadeOnBoth, beside: true });
        }
        (kind, _) => plan.writes.push(Write {
            path,
            kind,
            mode: entry.mode,
            link: entry.link.clone(),
            replaces: None,
        }),
    }
}

#[cfg(test)]
#[path = "way_back_tests.rs"]
mod tests;
