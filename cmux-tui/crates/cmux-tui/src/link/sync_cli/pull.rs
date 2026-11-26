//! `cmux link sync pull --socket PATH LOCAL REMOTE`: brings a folder that
//! `cmux link sync push` copied to a Cloud machine back (Bring Back Local,
//! cmuxterm-hq#1874 slice 4), by a three-way merge against what the push
//! left there (its manifest).
//!
//! For each file of the push or of the machine's folder now:
//!
//! - the machine's still as pushed: this Mac's stays;
//! - this Mac's still as pushed: the machine's comes back (written, or
//!   deleted when the machine deleted it);
//! - both changed the same way: nothing to do;
//! - both changed differently: a text file is merged by line against the
//!   last sync's version ([`merge`]); edits on the same lines, and any
//!   other file, are a conflict;
//! - one side deleted what the other edited: a conflict, in both
//!   directions; neither the delete nor the edit is applied.
//!
//! The decision is the three-tree rule, [`cmux_sync::three_tree::decide`]
//! (RFD 0140), over the base this Mac kept, this Mac's file and the machine's.
//!
//! The machine's `.git` never comes back as files: its branch and staged
//! changes take the git leg ([`super::git_back`]). New files of the machine
//! come back, except ones this working copy's ignore rules match, untracked
//! `.env*` files, special files and symlinks that do not stay inside the
//! folder by their own text ([`super::links`]): those are named as skipped.
//! A symlink comes back as a symlink, its text its content. Outside git every file of the
//! machine's folder counts.
//!
//! The machine is not trusted. The base is the copy of the push's record
//! this Mac kept ([`super::base`]), never the machine's; a listing that
//! names anything but plain names is refused; no path that reaches a
//! repository folder under any spelling (`.GIT`, `git~1`, ...: see
//! [`super::names`]) comes back, and no folder holding one (a nested
//! repository) as part of the folder. Files are read with their revision
//! checked before and after, streamed to disk.
//!
//! A repository inside the folder that both sides have as a `.git` folder
//! (a folder of repositories such as `~/Projects`, RFD 0007 hard case 12)
//! comes back by a pull of its own, under its ignore rules and through its
//! own git leg against the base recorded for it (`Manifest::repos`). Every
//! one is planned before anything here changes, so a conflict in any one,
//! named under its folder, leaves all of them as they were; the files of
//! all of them then move as one transaction, and the branches in order, a
//! branch that can't move putting back the ones before it.
//!
//! On any conflict none of this Mac's files change: the answer is
//! `{"ok":false,"error_code":"sync_conflict","conflicts":[paths],
//! "merge_files":[paths]}`, the second list naming the merges with conflict
//! markers written beside the files whose edits overlapped. Otherwise every
//! file the machine changed is first copied into a staging folder of this
//! command (in the repository's git folder, else a hidden folder at the top
//! of the folder) and the machine's commits are fetched; this Mac's files
//! are checked again, and only then do files move into place, as one
//! transaction ([`super::place`]): through folder handles that follow no
//! symlink, regular files only, each renamed over its target (which is
//! moved aside first), with 0644, 0755, 0600 or 0700 permissions. The
//! branch and index move last. Any failure puts back what changed.
//! The records then hold the merged state as the next base.

use std::collections::{BTreeMap, BTreeSet};
use std::io::Write;
use std::os::unix::fs::{DirBuilderExt as _, OpenOptionsExt as _, PermissionsExt as _};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use anyhow::{Context as _, bail};
use cmux_sync::three_tree::{self, Decision};
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};

use super::git_back::{self, GitPlan};
use super::history::{self, Held};
use super::local::{self, GitDirs};
use super::merge;
use super::place::{self, Dir, Entry, Expected, Transaction};
use super::remote::{self, Remote};
use super::skips::Skips;
use super::{Linked, Manifest, Pushed, base, links, names};

/// What a pull did, or the paths that stopped it.
pub(super) enum Pulled {
    Done(Value),
    /// The conflicting paths, why (the git leg's and overlapping edits),
    /// and the merge files with conflict markers written beside this Mac's
    /// files ([`merge`]).
    Conflict(Vec<String>, Vec<String>, Vec<String>),
}

/// One side's file at a path.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Side {
    Missing,
    File {
        sha256: String,
        permissions: u32,
    },
    /// A symlink, by its text.
    Link(String),
    /// A folder, special file, or a symlink that is not synced.
    Other,
}

/// What happens to one path.
enum Step {
    /// The machine's file replaces this Mac's: staged copy, permissions.
    Write {
        staged: String,
        permissions: u32,
        revision: String,
        sha256: String,
    },
    Delete,
    /// The machine's symlink replaces what is here: its text.
    Link(String),
    /// Both sides already agree; only the manifest moves.
    Settle(Option<Pushed>),
    /// Both sides have this symlink.
    SettleLink(String),
    /// Both changed a text file on different lines: the merge (staged, its
    /// SHA-256 and permissions in `machine`'s) goes here; the record keeps
    /// the machine's file, so the next push sends the merge.
    Merged {
        staged: String,
        sha256: String,
        permissions: u32,
        machine: Pushed,
    },
}

struct Planned {
    relative: String,
    local: Side,
    step: Step,
}

pub(super) fn pull(socket: &Path, local: &Path, remote_root: &str) -> anyhow::Result<Pulled> {
    pull_kept(socket, local, remote_root, &|_| true, true)
}

/// A pull that also leaves on the machine (and counts as skipped) every new
/// file of the machine `keep_new` refuses, by its path relative to the
/// folder: `cmux link access` never takes secret files back. Without
/// `links_ok` a symlink is never made here (that copy pushed files only).
pub(super) fn pull_kept(
    socket: &Path,
    local: &Path,
    remote_root: &str,
    keep_new: &dyn Fn(&str) -> bool,
    links_ok: bool,
) -> anyhow::Result<Pulled> {
    pull_based(socket, local, remote_root, keep_new, links_ok, None)
}

/// A pull into a folder this Mac never pushed (Transfer to This Mac,
/// `cmux link seed fetch`): `fresh` is the base, standing for "nothing was
/// pushed" (no files; in git, this Mac's empty repository on the machine's
/// branch), never the machine's record. Only a new, empty folder may take
/// it: every file the machine has is new here, so nothing of this Mac's is
/// overwritten. With `adopt` (the chat moves here) the records are kept on
/// both sides, so the move's last pull and a later Bring Back build on this
/// one; without it (a copy, the chat stays) nothing on the machine changes
/// and its record stays the one its own pusher's pulls trust.
pub(super) fn pull_fresh(
    socket: &Path,
    local: &Path,
    remote_root: &str,
    keep_new: &dyn Fn(&str) -> bool,
    fresh: Manifest,
    adopt: bool,
) -> anyhow::Result<Pulled> {
    pull_based(socket, local, remote_root, keep_new, true, Some((fresh, adopt)))
}

fn pull_based(
    socket: &Path,
    local: &Path,
    remote_root: &str,
    keep_new: &dyn Fn(&str) -> bool,
    links_ok: bool,
    fresh: Option<(Manifest, bool)>,
) -> anyhow::Result<Pulled> {
    let local =
        std::fs::canonicalize(local).with_context(|| format!("cannot open {}", local.display()))?;
    if !std::fs::metadata(&local)?.is_dir() {
        bail!("{} is not a folder", local.display());
    }
    let git = GitDirs::of(&local)?;
    let mut remote = Remote::connect(socket)?;
    // A fresh base (Transfer to This Mac, seed fetch) stands for "nothing was pushed"; otherwise the
    // machine's record, the plain one included for a git folder's first pass past the copy's limits.
    let keeps_record = fresh.as_ref().is_none_or(|(_, adopt)| *adopt);
    let (manifest_path, manifest, plain_in_git) = match fresh {
        Some((fresh, _)) => {
            let name = if git.is_some() { ".git/cmux-sync.json" } else { ".cmux-sync.json" };
            (format!("{remote_root}/{name}"), fresh, false)
        }
        None => base::machine_record(&mut remote, &local, remote_root, git.is_some())?,
    };
    let staging = Staging::make(git.as_ref().map_or(&local, |dirs| &dirs.own))?;
    let root = Dir::open(&local)?;

    // The folder, then each repository inside it (RFD 0007 hard case 12: a folder of
    // repositories such as `~/Projects`), each by its own rules and git leg. All of them are
    // planned before anything here changes: a conflict in any one leaves every one as it was.
    let mut skips = Skips::new(&local);
    let (mut skipped, mut unchanged) = (0u64, 0u64);
    let mut conflicts: Vec<String> = Vec::new();
    let mut reasons: Vec<String> = Vec::new();
    // Text files both sides changed on the same lines: their merge.
    let mut overlaps: Vec<(String, Vec<u8>)> = Vec::new();
    // Projected files both sides changed: the machine's version, staged, to go beside this Mac's.
    let mut beside: Vec<(String, PathBuf)> = Vec::new();
    let mut planned: Vec<Planned> = Vec::new();
    // Each repository's git leg, by its folder ("" for the top), in the order they move.
    let mut git_plans: Vec<(String, PathBuf, GitPlan)> = Vec::new();
    // The repositories inside, by folder: each one's conflicts are named under it.
    let mut repositories: Vec<String> = Vec::new();
    let mut scopes = std::collections::VecDeque::from([Scope {
        prefix: String::new(),
        local: local.clone(),
        remote_root: remote_root.to_owned(),
        manifest: std::borrow::Cow::Borrowed(&manifest),
        git,
        plain_in_git,
    }]);
    while let Some(scope) = scopes.pop_front() {
        let quarantine = if scope.prefix.is_empty() {
            staging.0.clone()
        } else {
            let dir = staging.0.join(format!("repository-{}", repositories.len()));
            std::fs::DirBuilder::new().mode(0o700).create(&dir)?;
            dir
        };
        let plan =
            plan_scope(&mut remote, &scope, &staging, &quarantine, keep_new, links_ok, &mut skips)?;
        let prefix = scope.prefix.as_str();
        let full = |relative: &String| format!("{prefix}{relative}");
        let name = prefix.trim_end_matches('/').to_owned();
        if !plan.conflicts.is_empty() && !name.is_empty() {
            reasons.push(format!("{name}: this repository conflicts, so no repository changed"));
        }
        skipped += plan.skipped;
        unchanged += plan.unchanged;
        conflicts.extend(plan.conflicts.iter().map(full));
        reasons.extend(plan.reasons.iter().map(full));
        overlaps
            .extend(plan.overlaps.into_iter().map(|(relative, bytes)| (full(&relative), bytes)));
        beside.extend(plan.beside.into_iter().map(|(relative, staged)| (full(&relative), staged)));
        planned.extend(
            plan.planned.into_iter().map(|step| Planned { relative: full(&step.relative), ..step }),
        );
        if let Some(git_plan) = plan.git_plan {
            git_plans.push((name.clone(), scope.local.clone(), git_plan));
        }
        if !name.is_empty() {
            repositories.push(name);
        }
        for dir in plan.repositories {
            let at = scope.local.join(&dir);
            // Its own working copy's top, or it stays fenced off as before.
            match GitDirs::of(&at) {
                Ok(Some(dirs)) => scopes.push_back(Scope {
                    prefix: format!("{prefix}{dir}/"),
                    local: at,
                    remote_root: format!("{}/{dir}", scope.remote_root),
                    manifest: std::borrow::Cow::Owned(within(&scope.manifest, &dir)),
                    git: Some(dirs),
                    plain_in_git: false,
                }),
                Ok(None) | Err(_) => skipped += 1,
            }
        }
    }

    if !conflicts.is_empty() {
        conflicts.sort();
        conflicts.dedup();
        // Only now, with nothing of this Mac's changed: each overlapping
        // merge goes beside its file.
        let mut merge_files = Vec::new();
        for (relative, bytes) in overlaps {
            match merge::write_conflict(&root, &relative, &bytes) {
                Ok(side) => {
                    reasons.push(format!(
                        "{relative}: both changed the same lines; the merge is in {side}"
                    ));
                    merge_files.push(side);
                }
                Err(error) => reasons.push(format!("{relative}: {error:#}")),
            }
        }
        for (relative, staged) in beside {
            let written = std::fs::read(&staged)
                .map_err(anyhow::Error::from)
                .and_then(|bytes| merge::write_conflict(&root, &relative, &bytes));
            match written {
                Ok(side) => {
                    reasons.push(format!(
                        "{relative}: changed on this Mac since it was projected, and the machine \
                         changed it too; the machine's is in {side}"
                    ));
                    merge_files.push(side);
                }
                Err(error) => reasons.push(format!("{relative}: {error:#}")),
            }
        }
        return Ok(Pulled::Conflict(conflicts, reasons, merge_files));
    }
    // This Mac's files are as planned, or nothing moves.
    for step in &planned {
        if local_side(&root, &step.relative)? != step.local {
            return Ok(Pulled::Conflict(vec![step.relative.clone()], Vec::new(), Vec::new()));
        }
    }
    // Only objects so far: the branches and indexes move last.
    for (_, folder, plan) in &git_plans {
        plan.fetch(folder)?;
    }

    // What this pull changes here, before and after, for the snapshots
    // `cmux link sync undo` puts back ([`history`]). This Mac's files keep
    // their blobs before they are replaced or deleted.
    let changing: Vec<(String, Option<Held>, Option<Held>)> = planned
        .iter()
        .filter(|step| !matches!(step.step, Step::Settle(_) | Step::SettleLink(_)))
        .map(|step| (step.relative.clone(), held(&step.local), held_after(&step.step)))
        .collect();
    let snapshots = !changing.is_empty() || !git_plans.is_empty();
    let before = if snapshots {
        for (relative, now, _) in &changing {
            if let Some(Held::File { sha256, .. }) = now {
                history::keep_blob(&root, relative, sha256);
            }
        }
        let paths = history::on_top(
            &local,
            remote_root,
            &manifest,
            changing.iter().map(|(relative, now, _)| (relative.clone(), now.clone())),
        );
        Some((paths, history::git_now(&local)))
    } else {
        None
    };

    let mut next = manifest;
    let mut transaction = Transaction::new(&local, &staging.0)?;
    let applied = apply(&mut transaction, &staging, planned, &mut next);
    let (written, deleted, bytes) = match applied {
        Ok(counts) => counts,
        Err(error) => return undone(transaction, &staging, error),
    };
    // Each repository's branch and index, in order; one that can't move puts back every one
    // before it, then the files.
    let mut fast_forwarded = Vec::new();
    for (done, (name, folder, plan)) in git_plans.iter().enumerate() {
        match plan.commit(folder) {
            Ok(moved) => {
                if moved {
                    fast_forwarded.push(name.clone());
                }
            }
            Err(error) => {
                for (_, folder, plan) in git_plans.iter().take(done).rev() {
                    let _ = plan.undo(folder);
                }
                let error = if name.is_empty() {
                    error
                } else {
                    error.context(format!("in the repository {name}"))
                };
                return undone(transaction, &staging, error);
            }
        }
    }
    transaction.finish();
    if let Some((paths, git_before)) = before {
        let mut after = paths.clone();
        for (relative, _, then) in &changing {
            if !history::is_worktree_path(relative) {
                continue;
            }
            match then {
                Some(held) => {
                    if let Held::File { sha256, .. } = held {
                        history::keep_blob(&root, relative, sha256);
                    }
                    after.insert(relative.clone(), held.clone());
                }
                None => {
                    after.remove(relative);
                }
            }
        }
        // A snapshot that could not be kept never undoes the pull.
        let touched: BTreeSet<String> =
            changing.iter().map(|(relative, _, _)| relative.clone()).collect();
        let git_after = history::git_now(&local);
        let _ = history::record(
            &local,
            remote_root,
            "before_pull",
            paths,
            git_before,
            None,
            history::Changed::default(),
        );
        let _ = history::record(
            &local,
            remote_root,
            "pull",
            after,
            git_after,
            None,
            history::Changed { paths: touched, git: !git_plans.is_empty() },
        );
    }
    let (skipped_files, skipped_counts) = skips.json();
    let mut head = None;
    for (name, _, plan) in git_plans {
        if name.is_empty() {
            head = plan.settled.head.clone();
            next.git = Some(plan.settled);
        } else {
            next.repos.insert(name, plan.settled);
        }
    }
    // The next base, on the machine and here: a pull that ran again finds
    // nothing new. This Mac's copy moves only once the machine's did, so
    // the two stay equal when the machine's write fails.
    let saved = keeps_record
        && serde_json::to_vec(&next)
            .ok()
            .and_then(|manifest| remote.write(&manifest_path, &mut manifest.as_slice(), 0o600).ok())
            .is_some()
        && base::save(&local, remote_root, &next).is_ok();
    Ok(Pulled::Done(json!({
        "ok": true,
        "written": written,
        "deleted": deleted,
        "unchanged": unchanged,
        "skipped": skipped + skips.total(),
        "skipped_files": skipped_files,
        "skipped_counts": skipped_counts,
        "bytes": bytes,
        "fast_forwarded": !fast_forwarded.is_empty(),
        "head": head,
        "repositories": repositories,
        "fast_forwarded_repositories": fast_forwarded,
        "manifest_saved": saved,
    })))
}

/// One working copy a pull brings back: the folder, or a repository inside it.
struct Scope<'a> {
    /// Its folder from the top, ending in `/` (empty for the top).
    prefix: String,
    local: PathBuf,
    remote_root: String,
    /// The part of the record under it, by paths from it ([`within`]): the record itself for
    /// the top.
    manifest: std::borrow::Cow<'a, Manifest>,
    git: Option<GitDirs>,
    plain_in_git: bool,
}

/// What a pull would do in one [`Scope`], by paths from it.
struct ScopePlan {
    planned: Vec<Planned>,
    conflicts: Vec<String>,
    reasons: Vec<String>,
    overlaps: Vec<(String, Vec<u8>)>,
    beside: Vec<(String, PathBuf)>,
    git_plan: Option<GitPlan>,
    unchanged: u64,
    skipped: u64,
    /// The repositories inside it that come back each by its own pull ([`own_repository`]).
    repositories: Vec<String>,
}

/// The part of `manifest` under the folder `dir`, by paths from it: its files, links, git state
/// and the repositories inside it.
fn within(manifest: &Manifest, dir: &str) -> Manifest {
    let prefix = format!("{dir}/");
    fn under<T: Clone>(map: &BTreeMap<String, T>, prefix: &str) -> BTreeMap<String, T> {
        map.range(prefix.to_owned()..)
            .take_while(|(path, _)| path.starts_with(prefix))
            .filter_map(|(path, value)| {
                path.strip_prefix(prefix).map(|path| (path.to_owned(), value.clone()))
            })
            .collect()
    }
    Manifest {
        version: manifest.version,
        files: under(&manifest.files, &prefix),
        git: manifest.repos.get(dir).cloned(),
        links: under(&manifest.links, &prefix),
        projected: manifest.projected,
        repos: under(&manifest.repos, &prefix),
    }
}

/// Whether the fenced folder `dir` is a repository both sides have, which comes back by a pull of
/// its own: a `.git` folder (not a link or a file) here and on the machine, under that very name
/// on this Mac, no hooks folder, nothing of git's own above it.
fn own_repository(
    remote: &mut Remote,
    local: &Path,
    remote_root: &str,
    dir: &str,
    hooks: &[String],
) -> anyhow::Result<bool> {
    if dir.is_empty()
        || !names::safe_relative(dir)
        || hooks.iter().any(|folder| names::folded_within(folder, dir))
    {
        return Ok(false);
    }
    let (parent, name) = dir.rsplit_once('/').unwrap_or(("", dir));
    if !local_names(local, parent).iter().any(|here| here == name) {
        return Ok(false);
    }
    let at = local.join(dir);
    let plain_dir = |path: &Path| std::fs::symlink_metadata(path).is_ok_and(|meta| meta.is_dir());
    if !plain_dir(&at) || !plain_dir(&at.join(".git")) {
        return Ok(false);
    }
    let machine = remote.stat(&format!("{remote_root}/{dir}/.git"))?;
    Ok(machine.is_some_and(|stat| stat.get("kind").and_then(Value::as_str) == Some("dir")))
}

/// Plans the pull of one [`Scope`]: nothing here changes. New paths are named to `keep_new` and
/// `skips` by their path from the top.
fn plan_scope(
    remote: &mut Remote,
    scope: &Scope<'_>,
    staging: &Staging,
    quarantine: &Path,
    keep_new: &dyn Fn(&str) -> bool,
    links_ok: bool,
    skips: &mut Skips,
) -> anyhow::Result<ScopePlan> {
    let Scope { prefix, local, remote_root, manifest, git, plain_in_git } = scope;
    let (local, remote_root, plain_in_git) = (local.as_path(), remote_root.as_str(), *plain_in_git);
    let manifest: &Manifest = manifest;
    let root = Dir::open(local)?;
    let hooks = if git.is_some() { hook_folders(local)? } else { Vec::new() };
    let MachineFiles { found, mut skipped, mut fenced } =
        machine_files(remote, remote_root, local, git.is_some(), manifest, &hooks)?;
    let mut symlinks_served = true;
    // A repository here in a folder the push sent, whether or not the
    // machine still lists it: nothing in it is deleted.
    for dir in pushed_folders(manifest) {
        if !fenced.iter().any(|folder| names::folded_within(&dir, folder))
            && local_names(local, &dir)
                .iter()
                .any(|name| names::is_dotgit(name) || names::is_repository_marker(name))
        {
            fenced.insert(dir);
        }
    }
    let mut conflicts = Vec::new();
    let mut reasons = Vec::new();
    // Text files both sides changed on the same lines: their merge.
    let mut overlaps: Vec<(String, Vec<u8>)> = Vec::new();
    // Projected files both sides changed: the machine's version, staged, to go beside this Mac's.
    let mut beside: Vec<(String, PathBuf)> = Vec::new();
    let mut planned = Vec::new();
    let mut unchanged = 0u64;
    let mut paths: BTreeSet<&String> = manifest
        .files
        .keys()
        .filter(|path| is_tree_path(path))
        .filter(|path| !fenced.iter().any(|folder| names::folded_within(path, folder)))
        .collect();
    paths.extend(
        manifest
            .links
            .keys()
            .filter(|path| is_tree_path(path))
            .filter(|path| !fenced.iter().any(|folder| names::folded_within(path, folder))),
    );
    paths.extend(found.keys());
    // Every symlink of the machine's, read once: a text is checked through
    // these and this Mac's own, so a chain of links never climbs out.
    let mut machine_links: BTreeMap<String, Option<String>> = BTreeMap::new();
    if links_ok {
        for (relative, kind) in &found {
            if matches!(kind, Found::Link) {
                let target = format!("{remote_root}/{relative}");
                let text = machine_link(remote, &target, &mut symlinks_served)?;
                machine_links.insert(relative.clone(), text);
            }
        }
    }
    // Looked up as this Mac's disk compares names: `d/UP` is `d/up` here.
    let mut folded_links: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for (relative, text) in &machine_links {
        if let Some(text) = text {
            folded_links.entry(names::folded_path(relative)).or_default().push(text.clone());
        }
    }
    let links_at = |path: &str| -> Vec<String> {
        let mut texts: Vec<String> =
            folded_links.get(&names::folded_path(path)).cloned().unwrap_or_default();
        let here = local.join(path);
        if std::fs::symlink_metadata(&here).is_ok_and(|meta| meta.file_type().is_symlink())
            && let Some(text) =
                std::fs::read_link(&here).ok().and_then(|text| text.to_str().map(str::to_string))
        {
            texts.push(text);
        }
        texts
    };
    // Every name of the base and the machine, and each folder above one, as the Mac's disk compares
    // names: made when the machine has a new path.
    let mut folded_names: Option<BTreeMap<String, BTreeSet<&str>>> = None;
    for relative in paths {
        let listed = manifest.files.get(relative);
        // A projected folder's file the machine changed or deleted: its base is this Mac's file
        // while it is still as projected, else unknown (both changed).
        let resolved = match (listed, found.get(relative)) {
            (Some(pushed), Some(Found::File(revision)))
                if revision.as_ref() == Some(&pushed.revision) =>
            {
                None
            }
            (Some(pushed), _) if super::project::is_stand_in(&pushed.sha256) => {
                Some(projected_base(&root, relative, pushed)?)
            }
            _ => None,
        };
        let base = resolved.as_ref().or(listed);
        let pushed_link = manifest.links.get(relative);
        let pushed_side = match (base, pushed_link) {
            (Some(pushed), _) => {
                Side::File { sha256: pushed.sha256.clone(), permissions: pushed.permissions }
            }
            (None, Some(linked)) => Side::Link(linked.target.clone()),
            (None, None) => Side::Missing,
        };
        // This Mac's own text of a link the push wrote relative.
        let pushed_here = match pushed_link.and_then(|linked| linked.here.clone()) {
            Some(text) if base.is_none() => Side::Link(text),
            _ => pushed_side.clone(),
        };
        let target = format!("{remote_root}/{relative}");
        let (machine, staged) = match found.get(relative) {
            None => (Side::Missing, None),
            Some(Found::Other) => (Side::Other, None),
            Some(Found::Link) if !links_ok => (Side::Other, None),
            // A link at a hooks folder or above one would hand git hooks
            // the machine chose.
            Some(Found::Link)
                if hooks.iter().any(|folder| {
                    names::folded_path(folder) == names::folded_path(relative)
                        || names::folded_path(folder)
                            .starts_with(&format!("{}/", names::folded_path(relative)))
                }) =>
            {
                skips
                    .note(&format!("{prefix}{relative}"), super::skips::Why::SymlinkIntoRepository);
                continue;
            }
            Some(Found::Link) => match machine_links.get(relative).cloned().flatten() {
                // Only a text that stays inside, through every link on its
                // way on either side, comes back.
                Some(text)
                    if links::resolve(links::parent_of(relative), &text).is_some()
                        && links::reaches_inside(links::parent_of(relative), &text, &links_at) =>
                {
                    (Side::Link(text), None)
                }
                Some(text) => {
                    skips.note(&format!("{prefix}{relative}"), links::refused(&text));
                    continue;
                }
                None => (Side::Other, None),
            },
            Some(Found::File(revision)) => {
                if base.is_some_and(|pushed| Some(&pushed.revision) == revision.as_ref()) {
                    unchanged += 1;
                    continue;
                }
                let staged = staging.stage(remote, &target)?;
                let side =
                    Side::File { sha256: staged.sha256.clone(), permissions: staged.permissions };
                (side, Some(staged))
            }
        };
        if machine == pushed_side {
            unchanged += 1;
            continue;
        }
        let new = base.is_none() && pushed_link.is_none();
        if new
            && (is_new_and_kept_out(relative, &machine)
                || !keep_new(&format!("{prefix}{relative}")))
        {
            skipped += 1;
            continue;
        }
        // A new name that a Mac's disk reads as another one (`Readme.md` beside `README.md`, or
        // below `SRC/` beside `src/`) would land on it there: a conflict, never an overwrite.
        if new {
            let names = folded_names.get_or_insert_with(|| {
                folded_index(manifest.files.keys().chain(manifest.links.keys()).chain(found.keys()))
            });
            if let Some(other) = folds_onto(names, relative) {
                reasons.push(format!(
                    "{relative}: a Mac's disk reads it as {other}, so it can't come back beside it"
                ));
                conflicts.push(relative.clone());
                continue;
            }
        }
        let here = local_side(&root, relative)?;
        // The three-tree rule (RFD 0140, [`cmux_sync::three_tree`]): the base this Mac kept, this
        // Mac's and the machine's.
        let side = |side: &Side| (*side != Side::Missing).then(|| side.clone());
        let decision = three_tree::decide(
            side(&pushed_here).as_ref(),
            side(&here).as_ref(),
            side(&machine).as_ref(),
        );
        let step = match decision {
            Decision::Nothing | Decision::RecordSynced(_) => match &machine {
                Side::Link(text) => Step::SettleLink(text.clone()),
                _ => Step::Settle(staged.map(|staged| staged.pushed())),
            },
            // Only this Mac changed it: this Mac's stays, and the next push sends it.
            Decision::Push(_) => {
                unchanged += 1;
                continue;
            }
            // Both changed it, or one side deleted what the other edited: a conflict, named and
            // never decided here. Two text edits are merged by line when they do not overlap.
            Decision::Conflict(_) => {
                let merged = match (&pushed_side, &here, &machine, &staged) {
                    (
                        Side::File { sha256: base_sha, permissions: base_mode },
                        Side::File { sha256: here_sha, permissions: here_mode },
                        Side::File { sha256: machine_sha, permissions: machine_mode },
                        Some(staged),
                    ) => merge::merge(
                        &root,
                        relative,
                        &merge::Version { sha256: base_sha, permissions: *base_mode },
                        &merge::Version { sha256: here_sha, permissions: *here_mode },
                        &merge::Version { sha256: machine_sha, permissions: *machine_mode },
                        &staging.0.join(&staged.name),
                    )?,
                    _ => merge::Merged::Whole,
                };
                match (merged, staged) {
                    (merge::Merged::Clean { bytes, permissions }, Some(staged)) => {
                        let (name, sha256) = staging.stage_bytes(&bytes, permissions)?;
                        Step::Merged { staged: name, sha256, permissions, machine: staged.pushed() }
                    }
                    (merge::Merged::Overlap(bytes), _) => {
                        overlaps.push((relative.clone(), bytes));
                        conflicts.push(relative.clone());
                        continue;
                    }
                    (_, staged) => {
                        // A projected file both sides changed has no base to merge against: the
                        // machine's version goes beside this Mac's, never over it.
                        if base.is_some_and(|pushed| super::project::is_stand_in(&pushed.sha256)) {
                            match staged {
                            Some(staged) => {
                                beside.push((relative.clone(), staging.0.join(&staged.name)));
                            }
                            None => reasons.push(format!(
                                "{relative}: changed on this Mac since it was projected, and the \
                                 machine changed it too"
                            )),
                        }
                        }
                        conflicts.push(relative.clone());
                        continue;
                    }
                }
            }
            // Only the machine changed it: the machine's comes back.
            Decision::Apply(_) => match (machine, staged) {
                (Side::File { .. }, Some(staged)) => Step::Write {
                    permissions: staged.permissions,
                    revision: staged.revision,
                    sha256: staged.sha256,
                    staged: staged.name,
                },
                (Side::Missing, _) => Step::Delete,
                (Side::Link(text), _) => Step::Link(text),
                _ => {
                    conflicts.push(relative.clone());
                    continue;
                }
            },
        };
        planned.push(Planned { relative: relative.clone(), local: here, step });
    }
    drop(folded_names);

    let mut git_plan: Option<GitPlan> = None;
    if let Some(dirs) = git.as_ref().filter(|_| !plain_in_git) {
        let at = git_back::Where { folder: local, common_dir: &dirs.common, staging: quarantine };
        match git_back::plan(remote, remote_root, &at, manifest, &hooks)? {
            Ok(plan) => git_plan = plan,
            Err(git_conflicts) => {
                for (path, why) in git_conflicts {
                    reasons.push(format!("{path}: {why}"));
                    conflicts.push(path);
                }
            }
        }
    }
    let mut repositories = Vec::new();
    for dir in &fenced {
        if own_repository(remote, local, remote_root, dir, &hooks)? {
            repositories.push(dir.clone());
        }
    }
    Ok(ScopePlan {
        planned,
        conflicts,
        reasons,
        overlaps,
        beside,
        git_plan,
        unchanged,
        skipped,
        repositories,
    })
}

/// Puts back what `transaction` changed after `error`. A file that changed
/// here during the pull is a conflict; what could not be put back stays in
/// the staging folder, which the answer names.
fn undone(
    transaction: Transaction,
    staging: &Staging,
    error: anyhow::Error,
) -> anyhow::Result<Pulled> {
    if let Err(left) = transaction.roll_back() {
        staging.keep();
        return Err(error.context(format!(
            "cmux could not put back {}; what it moved aside is in {}",
            left.join(", "),
            staging.0.display()
        )));
    }
    if let Some(changed) = error.downcast_ref::<place::Changed>() {
        return Ok(Pulled::Conflict(vec![changed.0.clone()], Vec::new(), Vec::new()));
    }
    Err(error)
}

/// Applies the planned steps through `transaction`, recording each in
/// `next`: written, deleted and bytes written.
fn apply(
    transaction: &mut Transaction,
    staging: &Staging,
    planned: Vec<Planned>,
    next: &mut Manifest,
) -> anyhow::Result<(u64, u64, u64)> {
    let (mut written, mut deleted, mut bytes) = (0u64, 0u64, 0u64);
    for step in planned {
        match step.step {
            Step::Write { staged, permissions, revision, sha256 } => {
                bytes += std::fs::metadata(staging.0.join(&staged))?.len();
                if let Side::Link(text) = &step.local {
                    transaction.remove_link(&step.relative, text)?;
                }
                transaction.write(&step.relative, &staged, expected(&step.local).as_ref())?;
                written += 1;
                next.links.remove(&step.relative);
                next.files.insert(step.relative, Pushed { sha256, permissions, revision });
            }
            Step::Delete => {
                match (&step.local, expected(&step.local)) {
                    (Side::Link(text), _) => transaction.remove_link(&step.relative, text)?,
                    (_, Some(expected)) => transaction.delete(&step.relative, &expected)?,
                    (_, None) => bail!("{} here is not a file", step.relative),
                }
                deleted += 1;
                next.files.remove(&step.relative);
                next.links.remove(&step.relative);
            }
            Step::Link(text) => {
                match (&step.local, expected(&step.local)) {
                    (Side::Link(old), _) => transaction.remove_link(&step.relative, old)?,
                    (_, Some(expected)) => transaction.delete(&step.relative, &expected)?,
                    (_, None) => {}
                }
                transaction.link(&step.relative, &text)?;
                written += 1;
                next.files.remove(&step.relative);
                next.links.insert(step.relative, Linked { target: text, here: None });
            }
            Step::Merged { staged, machine, .. } => {
                bytes += std::fs::metadata(staging.0.join(&staged))?.len();
                transaction.write(&step.relative, &staged, expected(&step.local).as_ref())?;
                written += 1;
                next.links.remove(&step.relative);
                next.files.insert(step.relative, machine);
            }
            Step::Settle(Some(pushed)) => {
                next.links.remove(&step.relative);
                next.files.insert(step.relative, pushed);
            }
            Step::Settle(None) => {
                next.files.remove(&step.relative);
                next.links.remove(&step.relative);
            }
            Step::SettleLink(text) => {
                next.files.remove(&step.relative);
                next.links.insert(step.relative, Linked { target: text, here: None });
            }
        }
    }
    Ok((written, deleted, bytes))
}

/// One side's path as a snapshot holds it.
fn held(side: &Side) -> Option<Held> {
    match side {
        Side::File { sha256, permissions } => {
            Some(Held::File { sha256: sha256.clone(), permissions: *permissions })
        }
        Side::Link(text) => Some(Held::Link { text: text.clone() }),
        Side::Missing | Side::Other => None,
    }
}

/// What a step leaves here.
fn held_after(step: &Step) -> Option<Held> {
    match step {
        Step::Write { sha256, permissions, .. } => {
            Some(Held::File { sha256: sha256.clone(), permissions: *permissions })
        }
        Step::Link(text) | Step::SettleLink(text) => Some(Held::Link { text: text.clone() }),
        Step::Settle(Some(pushed)) => {
            Some(Held::File { sha256: pushed.sha256.clone(), permissions: pushed.permissions })
        }
        Step::Merged { sha256, permissions, .. } => {
            Some(Held::File { sha256: sha256.clone(), permissions: *permissions })
        }
        Step::Delete | Step::Settle(None) => None,
    }
}

/// What this Mac's file must still be when it is replaced or deleted.
fn expected(side: &Side) -> Option<Expected> {
    match side {
        Side::File { sha256, permissions } => {
            Some(Expected { sha256: sha256.clone(), permissions: *permissions })
        }
        Side::Missing | Side::Link(_) | Side::Other => None,
    }
}

/// A working-tree path of the record: no repository folder under any
/// spelling, not a part file.
fn is_tree_path(relative: &str) -> bool {
    names::safe_relative(relative)
        && relative != ".cmux-sync.json"
        && !relative.ends_with(".cmux-sync-part")
        && !merge::is_conflict_file(relative)
}

/// A new file of the machine that does not come back: an `.env*` file
/// (shared only on purpose) or a special file or symlink that is not synced
/// (a synced symlink was checked to stay inside the folder).
fn is_new_and_kept_out(relative: &str, machine: &Side) -> bool {
    let name = relative.rsplit('/').next().unwrap_or_default();
    name.starts_with(".env") || !matches!(machine, Side::File { .. } | Side::Link(_))
}

/// The text of the machine's symlink at `target`; None once the machine
/// shows it has no `fs-symlink-v1` (its symlinks then stay, as before).
fn machine_link(
    remote: &mut Remote,
    target: &str,
    served: &mut bool,
) -> anyhow::Result<Option<String>> {
    if !*served {
        return Ok(None);
    }
    match remote.readlink(target) {
        Ok(text) => Ok(text),
        Err(error) if remote::refusal_code(&error).is_some() => {
            *served &= !remote::lacks_symlinks(&error);
            Ok(None)
        }
        Err(error) => Err(error),
    }
}

/// What the machine's listing says about a path.
enum Found {
    /// A regular file, with its revision.
    File(Option<String>),
    Link,
    Other,
}

/// What [`machine_files`] found: the files by path, how many entries were
/// left out, and the paths fenced off (nothing at or below them comes back
/// or is deleted here).
struct MachineFiles {
    found: BTreeMap<String, Found>,
    skipped: u64,
    fenced: BTreeSet<String>,
}

/// The machine's working-tree files, by path, from its folder's listings,
/// level by level. Folders this working copy ignores are not entered
/// (unless the push had files there). No name that reads as `.git` comes
/// back. Fenced off: a folder below the top that is a repository on either
/// side (a `.git`, a `HEAD` or a `commondir`), a top folder's repository
/// names when it has a repository's shape, and `hook_folders`.
fn machine_files(
    remote: &mut Remote,
    remote_root: &str,
    local: &Path,
    git: bool,
    manifest: &Manifest,
    hook_folders: &[String],
) -> anyhow::Result<MachineFiles> {
    let pushed_dirs = pushed_folders(manifest);
    let mut found = BTreeMap::new();
    let mut skipped = 0u64;
    let mut fenced = BTreeSet::new();
    let mut level = vec![String::new()];
    while !level.is_empty() {
        let mut children: Vec<(String, bool, Found)> = Vec::new();
        for dir in level.drain(..) {
            let path =
                if dir.is_empty() { remote_root.into() } else { format!("{remote_root}/{dir}") };
            // Every listed name is one plain component (`Remote::list`).
            let Some(entries) = remote.list(&path)? else { continue };
            let here = local_names(local, &dir);
            // A repository below the top, on either side (a `.git`, or a
            // bare repository's or linked worktree's shape): nothing in it
            // comes back or is deleted here.
            if !dir.is_empty()
                && entries
                    .keys()
                    .chain(&here)
                    .any(|name| names::is_dotgit(name) || names::is_repository_marker(name))
            {
                skipped += 1;
                fenced.insert(dir);
                continue;
            }
            // The top with a repository's shape: its repository names stay.
            let top_shaped = dir.is_empty()
                && entries.keys().chain(&here).any(|name| names::is_repository_marker(name));
            for (name, entry) in entries {
                if names::is_dotgit(&name) {
                    // The top's own `.git` is the repository, never a file.
                    if !(dir.is_empty() && name == ".git") {
                        skipped += 1;
                    }
                    continue;
                }
                let lower = name.to_ascii_lowercase();
                if lower.starts_with(".cmux-sync")
                    || lower.ends_with(".cmux-sync-part")
                    || (merge::is_conflict_file(&lower) && entry.kind != "dir")
                {
                    continue;
                }
                let relative = if dir.is_empty() { name.clone() } else { format!("{dir}/{name}") };
                let hooks =
                    hook_folders.iter().any(|folder| names::folded_within(&relative, folder));
                if (top_shaped && names::is_repository_part(&name)) || hooks {
                    skipped += 1;
                    fenced.insert(relative);
                    continue;
                }
                if !names::safe_relative(&relative) || !local::holdable(&relative) {
                    skipped += 1;
                    continue;
                }
                match entry.kind.as_str() {
                    "dir" => children.push((relative, true, Found::Other)),
                    "file" => children.push((relative, false, Found::File(entry.revision))),
                    "symlink" => children.push((relative, false, Found::Link)),
                    _ => children.push((relative, false, Found::Other)),
                }
            }
        }
        let ignored = if git { ignored(local, &children)? } else { BTreeSet::new() };
        for (relative, is_dir, kind) in children {
            if ignored.contains(&relative) && !pushed_dirs.contains(&relative) {
                continue;
            }
            if is_dir {
                level.push(relative);
            } else {
                found.insert(relative, kind);
            }
        }
    }
    Ok(MachineFiles { found, skipped, fenced })
}

/// The folders the push sent files in, relative to the top.
fn pushed_folders(manifest: &Manifest) -> BTreeSet<String> {
    manifest
        .files
        .keys()
        .filter(|path| is_tree_path(path))
        .flat_map(|path| {
            let parts: Vec<&str> = path.split('/').collect();
            (1..parts.len()).map(move |end| parts[..end].join("/"))
        })
        .collect()
}

/// The names in this Mac's folder `dir` (relative to `local`); none when it
/// can't be read.
fn local_names(local: &Path, dir: &str) -> Vec<String> {
    let path = if dir.is_empty() { local.to_path_buf() } else { local.join(dir) };
    std::fs::read_dir(path)
        .map(|entries| {
            entries
                .filter_map(Result::ok)
                .map(|entry| entry.file_name().to_string_lossy().into_owned())
                .collect()
        })
        .unwrap_or_default()
}

/// The working-tree folders whose files this working copy's git runs as
/// hooks: `core.hooksPath` when it is inside the folder, and the folder
/// above it for husky's `.husky/_` (whose hooks call `.husky/<hook>`).
pub(super) fn hook_folders(local: &Path) -> anyhow::Result<Vec<String>> {
    let Some(path) = git_back::hooks_path(local)? else { return Ok(Vec::new()) };
    let home = std::env::var_os("HOME").map(PathBuf::from);
    let path = match (path.strip_prefix("~/"), home) {
        (Some(rest), Some(home)) => home.join(rest),
        _ => PathBuf::from(&path),
    };
    let inside = if path.is_absolute() {
        // `local` is canonical; so is the hooks folder when it exists.
        let path = std::fs::canonicalize(&path).unwrap_or(path);
        let Ok(inside) = path.strip_prefix(local) else { return Ok(Vec::new()) };
        inside.to_path_buf()
    } else {
        path
    };
    let mut parts: Vec<String> = Vec::new();
    for part in inside.components() {
        match part {
            std::path::Component::Normal(name) => parts.push(name.to_string_lossy().into_owned()),
            std::path::Component::CurDir => {}
            // `..`, `~` and the like point outside the folder.
            _ => return Ok(Vec::new()),
        }
    }
    if parts.first().is_some_and(|first| first.starts_with('~')) || parts.is_empty() {
        return Ok(Vec::new());
    }
    let mut folders = vec![parts.join("/")];
    if parts.len() > 1 && parts.last().is_some_and(|last| last == "_") {
        folders.push(parts[..parts.len() - 1].join("/"));
    }
    Ok(folders)
}

/// Which of `paths` this working copy's ignore rules match (tracked files
/// never). Folders are asked with a trailing slash.
fn ignored(local: &Path, paths: &[(String, bool, Found)]) -> anyhow::Result<BTreeSet<String>> {
    if paths.is_empty() {
        return Ok(BTreeSet::new());
    }
    let mut child = Command::new("git")
        .arg("-C")
        .arg(local)
        .args(["check-ignore", "--stdin", "-z"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .context("cannot run git")?;
    let mut input = Vec::new();
    for (relative, is_dir, _) in paths {
        input.extend_from_slice(relative.as_bytes());
        if *is_dir {
            input.push(b'/');
        }
        input.push(0);
    }
    let mut stdin = child.stdin.take().context("no stdin")?;
    let writer = std::thread::spawn(move || stdin.write_all(&input));
    let output = child.wait_with_output()?;
    let _ = writer.join();
    // 0: some are ignored; 1: none is.
    if !matches!(output.status.code(), Some(0 | 1)) {
        bail!("git check-ignore failed");
    }
    Ok(output
        .stdout
        .split(|byte| *byte == 0)
        .filter(|path| !path.is_empty())
        .map(|path| String::from_utf8_lossy(path).trim_end_matches('/').to_string())
        .collect())
}

/// The base of a projected file ([`super::project::stand_in`]): this Mac's file, hashed, while it
/// still has the size and mtime it was projected with; else the stand-in, which matches nothing
/// (this Mac changed it since).
fn projected_base(root: &Dir, relative: &str, pushed: &Pushed) -> anyhow::Result<Pushed> {
    Ok(match stand_in_hash(root, relative, &pushed.sha256)? {
        Some(sha256) => Pushed { sha256, ..pushed.clone() },
        None => pushed.clone(),
    })
}

/// The hash of this Mac's file at `relative` while it is still the one `stand_in` names: checked
/// on the opened file before and after it is read, so a save landing between the check and the
/// read never becomes the base (it would let a later machine edit overwrite that save).
fn stand_in_hash(root: &Dir, relative: &str, stand_in: &str) -> anyhow::Result<Option<String>> {
    let Ok(Some((dir, name))) = place::parent_of(root, relative) else { return Ok(None) };
    if !matches!(dir.entry(&name)?, Entry::File { .. }) {
        return Ok(None);
    }
    let mut file = dir.open_file(&name)?;
    let matches = |file: &std::fs::File| {
        file.metadata().is_ok_and(|meta| super::project::stand_in_matches(stand_in, &meta))
    };
    if !matches(&file) {
        return Ok(None);
    }
    let mut hasher = Sha256::new();
    std::io::copy(&mut file, &mut hasher)?;
    Ok(matches(&file).then(|| hex(&hasher.finalize())))
}

/// Every path of `paths` and every folder above one, by its name as a Mac's disk compares names
/// ([`names::folded_path`]).
fn folded_index<'a>(
    paths: impl Iterator<Item = &'a String>,
) -> BTreeMap<String, BTreeSet<&'a str>> {
    let mut index: BTreeMap<String, BTreeSet<&'a str>> = BTreeMap::new();
    for path in paths {
        for prefix in prefixes(path) {
            index.entry(names::folded_path(prefix)).or_default().insert(prefix);
        }
    }
    index
}

/// `a`, `a/b` and `a/b/c` of `a/b/c`.
fn prefixes(path: &str) -> impl Iterator<Item = &str> {
    path.match_indices('/')
        .map(|(cut, _)| path.get(..cut).unwrap_or(path))
        .chain(std::iter::once(path))
}

/// Another name of `index` that `relative`, or a folder above it, reads as on a Mac's disk.
fn folds_onto<'a>(index: &BTreeMap<String, BTreeSet<&'a str>>, relative: &str) -> Option<&'a str> {
    prefixes(relative).find_map(|prefix| {
        index
            .get(&names::folded_path(prefix))
            .and_then(|known| known.iter().copied().find(|other| *other != prefix))
    })
}

/// This Mac's file at `relative`, read through folder handles. A path
/// through a symlink or anything but a folder is [`Side::Other`]: nothing
/// is written or deleted through it.
fn local_side(root: &Dir, relative: &str) -> anyhow::Result<Side> {
    let (dir, name) = match place::parent_of(root, relative) {
        Ok(Some(found)) => found,
        Ok(None) => return Ok(Side::Missing),
        Err(error) if matches!(error.raw_os_error(), Some(libc::ENOTDIR | libc::ELOOP)) => {
            return Ok(Side::Other);
        }
        Err(error) => return Err(error.into()),
    };
    match dir.entry(&name)? {
        Entry::Missing => Ok(Side::Missing),
        Entry::File { mode } => {
            let mut file = dir.open_file(&name)?;
            let mut hasher = Sha256::new();
            std::io::copy(&mut file, &mut hasher)?;
            Ok(Side::File {
                sha256: hex(&hasher.finalize()),
                permissions: local::permissions_of(mode),
            })
        }
        // A text that is not UTF-8 is never synced.
        Entry::Link => Ok(dir.read_link(&name).map_or(Side::Other, Side::Link)),
        Entry::Dir | Entry::Other => Ok(Side::Other),
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// A machine file copied into the staging folder, by its name there.
struct Staged {
    name: String,
    sha256: String,
    permissions: u32,
    revision: String,
}

impl Staged {
    fn pushed(self) -> Pushed {
        Pushed { sha256: self.sha256, permissions: self.permissions, revision: self.revision }
    }
}

/// This pull's own folder, removed when the pull ends, unless it holds a
/// file a failed pull could not put back (or the pull panicked).
pub(super) struct Staging(pub(super) PathBuf, std::cell::Cell<u64>, std::cell::Cell<bool>);

impl Staging {
    pub(super) fn make(parent: &Path) -> anyhow::Result<Self> {
        // A name of its own: a folder a failed pull kept is never reused.
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |since| since.as_nanos());
        let path = parent.join(format!(".cmux-sync-pull-{}-{nanos}", std::process::id()));
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(&path)
            .with_context(|| format!("cannot make {}", path.display()))?;
        Ok(Self(path, std::cell::Cell::new(0), std::cell::Cell::new(false)))
    }

    /// Keeps the folder when the pull ends.
    pub(super) fn keep(&self) {
        self.2.set(true);
    }

    /// Writes `bytes` here with `permissions`; its name and SHA-256.
    pub(super) fn stage_bytes(
        &self,
        bytes: &[u8],
        permissions: u32,
    ) -> anyhow::Result<(String, String)> {
        let number = self.1.get() + 1;
        self.1.set(number);
        let name = format!("file-{number}");
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(self.0.join(&name))?;
        file.write_all(bytes)?;
        file.set_permissions(std::fs::Permissions::from_mode(permissions))?;
        file.sync_all()?;
        Ok((name, hex(&Sha256::digest(bytes))))
    }

    /// Copies this Mac's blob at `blob` here with `permissions`, checked
    /// against `sha256`; its name here.
    pub(super) fn copy_in(
        &self,
        blob: &Path,
        sha256: &str,
        permissions: u32,
    ) -> anyhow::Result<String> {
        let number = self.1.get() + 1;
        self.1.set(number);
        let name = format!("file-{number}");
        let path = self.0.join(&name);
        let mut source = std::fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(blob)
            .with_context(|| format!("cannot read {}", blob.display()))?;
        let file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&path)?;
        let mut out = Hashing { file, hasher: Sha256::new() };
        std::io::copy(&mut source, &mut out)?;
        if hex(&out.hasher.finalize()) != sha256 {
            bail!("{} is not the file it names", blob.display());
        }
        out.file.set_permissions(std::fs::Permissions::from_mode(permissions))?;
        out.file.sync_all()?;
        Ok(name)
    }

    /// Copies the machine's file at `target` here, with its hash, synced
    /// permissions and revision, streamed to disk. Its revision is read
    /// before and after; a file that changed meanwhile is read again.
    fn stage(&self, remote: &mut Remote, target: &str) -> anyhow::Result<Staged> {
        for _ in 0..3 {
            let stat = remote.stat(target)?.with_context(|| format!("{target} went away"))?;
            if stat["kind"] != "file" {
                bail!("{target} is no longer a file");
            }
            let revision = stat["revision"].as_str().unwrap_or_default().to_string();
            let mode = stat["mode_display"].as_str().map_or(0o644, mode_bits);
            let permissions = local::permissions_of(mode);
            let number = self.1.get() + 1;
            self.1.set(number);
            let name = format!("file-{number}");
            let path = self.0.join(&name);
            let file = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW)
                .open(&path)?;
            let mut out = Hashing { file, hasher: Sha256::new() };
            remote.read_into(target, &mut out)?.with_context(|| format!("{target} went away"))?;
            let after = remote.stat(target)?;
            if after.as_ref().and_then(|stat| stat["revision"].as_str()) != Some(revision.as_str())
            {
                drop(out);
                let _ = std::fs::remove_file(&path);
                continue;
            }
            out.file.set_permissions(std::fs::Permissions::from_mode(permissions))?;
            out.file.sync_all()?;
            let sha256 = hex(&out.hasher.finalize());
            return Ok(Staged { name, sha256, permissions, revision });
        }
        bail!("{target} kept changing while it was read")
    }
}

/// A file that hashes what is written to it.
struct Hashing {
    file: std::fs::File,
    hasher: Sha256,
}

impl Write for Hashing {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        let written = self.file.write(bytes)?;
        self.hasher.update(&bytes[..written]);
        Ok(written)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.file.flush()
    }
}

impl Drop for Staging {
    fn drop(&mut self) {
        if self.2.get() || std::thread::panicking() {
            return;
        }
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// `rwxr-xr-x` back to its bits.
fn mode_bits(display: &str) -> u32 {
    display.chars().take(9).fold(0, |mode, c| (mode << 1) | u32::from(c != '-'))
}

/// The error code of a pull failure.
pub(super) fn failure_code(error: &anyhow::Error) -> String {
    if error.downcast_ref::<base::NoBase>().is_some() {
        return "sync_no_base".into();
    }
    if error.downcast_ref::<base::Mismatch>().is_some() {
        return "sync_base_mismatch".into();
    }
    if error.downcast_ref::<remote::UnsafeName>().is_some() {
        return "sync_unsafe_name".into();
    }
    remote::refusal_code(error).unwrap_or("sync_failed").to_string()
}
