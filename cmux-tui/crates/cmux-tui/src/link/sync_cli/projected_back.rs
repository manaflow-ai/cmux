//! A projected folder's way back (`cmux link start-chat project-pull`): what the machine wrote,
//! deleted or renamed over the projection comes back to this Mac in time proportional to those
//! edits, never to the folder's size, and never over an edit made on this Mac meanwhile.
//!
//! The set to bring back is exactly the overlay's upper layer (`projfs.upper`): nothing else of
//! the folder is listed, stat'ed or read. Each change is checked against its base, the version
//! the machine was shown: this Mac's manifest copy (as `project-serve`'s `changed` answers
//! updated it), or, for a path an earlier pull brought back, what that pull left here (the
//! [`Ledger`]). This Mac's entry "still equals" its base when a file has the base's size, mtime
//! and ctime (looked at with `lstat`, never through a symlink), a symlink its text.
//!
//! - `file`: the machine's bytes are read from the merged folder (`fs.read` in parts) into a file
//!   of this pull beside the target, then: no file here and no base, a create; this Mac's file
//!   still the base, a replace (the old one moved aside and checked first); otherwise a conflict:
//!   this Mac's file stays and the machine's goes beside it as `NAME.cmux-sync-conflict` (today's
//!   pull's name). No three-way merge: the base's bytes are not on this Mac, and reading them on
//!   the machine would fault them from this Mac's changed file, so the conflict is named.
//! - `delete`: this Mac's entry still the base, deleted; a folder only of what the manifest
//!   listed under it and still equals its base (anything else stays, and the folder with it,
//!   named as a conflict). Otherwise a conflict and nothing is deleted.
//! - `dir`: made. `opaque_dir`: the lower entries it hides are deletes by that rule, then its
//!   upper entries apply as usual.
//! - `symlink`: as a file, its text used as it is (never resolved), and only a text that stays
//!   inside the folder by its words, as the walker keeps links.
//! - `metadata`: the machine's permissions (as today's pull writes them: 0644, 0755, 0600 or
//!   0700; never ownership) when this Mac's file is still the base.
//! - `redirect` (a moved folder): a delete of the old path (its whiteout, by the delete rule) and
//!   the new one brought as created: its upper entries as usual, and every entry the projection
//!   lists under the old path that the upper layer does not replace, read from the merged
//!   folder. These are brought first, while the old path is still on this Mac to serve them. A
//!   move this Mac cannot map (from a path the projection has no folder at, or below another
//!   move) refuses the whole pull before anything changes (`redirect_unmapped`).
//! - `unsupported`: named under `refused`.
//! - A path this pull brought back that the upper layer no longer lists (the machine deleted a
//!   file it made) is deleted by the delete rule, with what this pull left as its base.
//!
//! Git's own files never come back (hard case 13): every path in a `.git` folder, under any
//! spelling, is skipped and counted (`skipped_git`); the repository here is left whole.
//!
//! The machine is the peer. Every path must be plain and relative (no `..`, `.`, empty part or
//! NUL); no folder on the way here may be a symlink; writes are a file of this pull renamed into
//! place in the same folder, never a partial file; nothing is written outside the folder. A path
//! the walker would not have listed (a secret, a credential folder, a dependency or build
//! folder, an ignored file, a name the sync keeps) is never written or deleted, and is named. A
//! new name that folds (as a Mac's disk compares names) onto a different name here is a conflict.

#[path = "projected_back_apply.rs"]
mod apply;
#[path = "projected_back_disk.rs"]
mod disk;
#[path = "projected_back_rules.rs"]
mod rules;

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;
use std::time::Instant;

use cmux_projfs::manifest::ROOT;
use cmux_projfs::{Entry, Index, Kind, Manifest};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::link::sync_cli::remote::{self, Remote};
use crate::link::sync_cli::stat_walk::Times;
use disk::{Disk, Mac};
use rules::{join, parent};

/// What earlier pulls of a mount brought back (`pulled.json`), by path.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub(in crate::link) struct Ledger {
    pub version: u32,
    pub paths: BTreeMap<String, Pulled>,
}

/// One path an earlier pull settled: the machine's version it saw, and what it left here.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(in crate::link) struct Pulled {
    pub machine: String,
    pub mac: Left,
}

/// What a pull left at a path of this Mac's folder.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(in crate::link) enum Left {
    File {
        size: u64,
        mtime_ns: i64,
        ctime_ns: i64,
        mode: u32,
    },
    Link {
        text: String,
    },
    Dir,
    Missing,
    /// This Mac's own version stands against the machine's: every later machine version of the
    /// path goes beside it.
    Conflict,
}

/// Why a pull stopped, in the command's failure line.
#[derive(Debug)]
pub(in crate::link) struct Failure {
    pub code: String,
    pub message: String,
}

impl Failure {
    fn new(code: &str, message: impl std::fmt::Display) -> Failure {
        Failure { code: code.to_owned(), message: message.to_string() }
    }
}

/// A transport failure, or the machine's refusal, as the pull's failure.
fn fatal(error: &anyhow::Error) -> Failure {
    Failure::new(remote::refusal_code(error).unwrap_or("pull_failed"), format!("{error:#}"))
}

fn io_failure(error: &std::io::Error) -> Failure {
    Failure::new("pull_failed", format!("this Mac's folder: {error}"))
}

/// One pull.
pub(in crate::link) struct Back<'a> {
    /// This Mac's folder.
    pub root: &'a Path,
    /// The merged (mounted) folder on the machine, which the change paths are relative to.
    pub machine_folder: &'a str,
    /// The mount helper's state folder on the machine.
    pub state_dir: &'a str,
    /// This Mac's manifest copy.
    pub manifest: &'a Manifest,
    /// Decide and report only: nothing is read from the machine's files or changed here.
    pub dry_run: bool,
}

/// One change of the upper layer.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Change {
    File,
    Metadata,
    Symlink(String),
    Dir,
    OpaqueDir,
    Redirect(String),
    Delete,
    Unsupported(String),
}

/// What one path of the work list does.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Work {
    File,
    Metadata,
    Link(String),
    Dir,
    Delete,
    /// A path an earlier pull brought back that the machine no longer has.
    Vanished,
    Refused(String),
}

#[derive(Clone, Debug)]
struct Item {
    path: String,
    work: Work,
}

/// Items that go together: an opaque folder and the deletes of what it hides, or a moved
/// folder and what it brings. `tag` is the machine version of `head` that settles the whole
/// group (one an earlier pull settled is skipped whole).
struct Group {
    head: String,
    tag: Option<String>,
    items: Vec<Item>,
}

/// What the pull did.
#[derive(Default)]
struct Out {
    applied: u64,
    created: u64,
    deleted: u64,
    unchanged: u64,
    conflicts: Vec<Value>,
    refused: Vec<Value>,
    skipped_git: u64,
    bytes: u64,
}

/// The base of a path: what the machine was shown there.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Base {
    Shown(Mac),
    /// A file whose bytes stay on this Mac (a secret rule): never written or deleted.
    Withheld,
    /// An earlier pull kept this Mac's own version against the machine's.
    Conflicted,
}

struct Run<'a, 'l> {
    back: &'a Back<'a>,
    remote: Remote,
    disk: Disk,
    ledger: &'l mut Ledger,
    out: Out,
    upper: BTreeMap<String, Change>,
    ignored: BTreeSet<String>,
}

fn ms(since: Instant) -> u64 {
    u64::try_from(since.elapsed().as_millis()).unwrap_or(u64::MAX)
}

/// Runs one pull through the machine daemon at `socket`, taking `ledger` along (the caller keeps
/// it, also after a failure: what was applied is in it). Its summary line without the mount.
pub(in crate::link) fn pull(
    back: &Back<'_>,
    socket: &Path,
    ledger: &mut Ledger,
) -> Result<Value, Failure> {
    let started = Instant::now();
    let mut remote = Remote::connect(socket)
        .map_err(|error| Failure::new("unreachable", format!("{error:#}")))?;
    let data = remote.call("projfs.upper", json!({ "state": back.state_dir }));
    let changes = parse(&data.map_err(|error| fatal(&error))?)?;
    let t_upper = ms(started);
    let applying = Instant::now();
    let disk = Disk::open(back.root).map_err(|error| {
        Failure::new("folder_missing", format!("cannot open {}: {error:#}", back.root.display()))
    })?;
    let mut run = Run {
        back,
        remote,
        disk,
        ledger,
        out: Out::default(),
        upper: BTreeMap::new(),
        ignored: BTreeSet::new(),
    };
    run.all(changes)?;
    let out = run.out;
    Ok(json!({
        "ok": true,
        "dry_run": back.dry_run,
        "applied": out.applied,
        "created": out.created,
        "deleted": out.deleted,
        "unchanged": out.unchanged,
        "conflicts": out.conflicts,
        "refused": out.refused,
        "skipped_git": out.skipped_git,
        "bytes": out.bytes,
        "ms": { "upper": t_upper, "apply": ms(applying), "total": ms(started) },
    }))
}

/// The helper's `upper` line as changes by path; its refusal as the pull's failure.
fn parse(data: &Value) -> Result<Vec<(String, Change)>, Failure> {
    let text = |value: &Value, key: &str| value.get(key).and_then(Value::as_str).map(str::to_owned);
    if data.get("ok").and_then(Value::as_bool) != Some(true) {
        let code = text(data, "code").unwrap_or_else(|| "upper_failed".into());
        let message =
            text(data, "message").unwrap_or_else(|| "the upper layer was not read".into());
        return Err(Failure::new(&code, message));
    }
    let list = data
        .get("changes")
        .and_then(Value::as_array)
        .ok_or_else(|| Failure::new("upper_failed", "the machine answered no change list"))?;
    let changes = list.iter().map(|change| {
        let path = text(change, "path").unwrap_or_default();
        let kind = match change.get("kind").and_then(Value::as_str) {
            Some("file") => Change::File,
            Some("metadata") => Change::Metadata,
            Some("symlink") => text(change, "link").map_or_else(
                || Change::Unsupported("a symlink with no text".into()),
                Change::Symlink,
            ),
            Some("dir") => Change::Dir,
            Some("opaque_dir") => Change::OpaqueDir,
            Some("redirect") => text(change, "from").map_or_else(
                || Change::Unsupported("a move with no origin".into()),
                Change::Redirect,
            ),
            Some("delete") => Change::Delete,
            Some("unsupported") => Change::Unsupported(text(change, "reason").unwrap_or_default()),
            other => Change::Unsupported(format!("an unknown change {other:?}")),
        };
        (path, kind)
    });
    Ok(changes.collect())
}

/// The manifest entry at `path`, gone ones included (a path this Mac changed during the session
/// keeps its last version, so a machine edit of it is checked against that).
fn find<'m>(manifest: &'m Manifest, path: &str) -> Option<(Index, &'m Entry)> {
    let mut at = ROOT;
    for part in path.split('/') {
        let range = manifest.children(at);
        let start = usize::try_from(range.start).ok()?;
        let end = usize::try_from(range.end).ok()?;
        let children = manifest.entries().get(start..end)?;
        let found = children.binary_search_by(|entry| entry.name.as_str().cmp(part)).ok()?;
        at = range.start.checked_add(Index::try_from(found).ok()?)?;
    }
    Some((at, manifest.entry(at)?))
}

/// Every entry below `top`, parents first, gone ones left out (a gone folder's whole subtree is).
fn below(manifest: &Manifest, top: Index) -> Vec<Index> {
    let mut out = Vec::new();
    let mut stack: Vec<Index> = manifest.children(top).rev().collect();
    while let Some(at) = stack.pop() {
        if manifest.entry(at).is_none_or(|entry| entry.gone) {
            continue;
        }
        out.push(at);
        stack.extend(manifest.children(at).rev());
    }
    out
}

/// What the machine was shown for a manifest entry.
fn shown(entry: &Entry) -> Base {
    let stat = &entry.stat;
    match stat.kind {
        Kind::File if stat.withheld => Base::Withheld,
        Kind::File => Base::Shown(Mac::File(Times {
            mode: stat.mode,
            size: stat.size,
            mtime_ns: stat.mtime_ns,
            ctime_ns: stat.ctime_ns,
        })),
        Kind::Symlink => Base::Shown(Mac::Link(stat.link.clone().unwrap_or_default())),
        Kind::Dir => Base::Shown(Mac::Dir),
    }
}

impl Left {
    fn of(mac: &Mac) -> Left {
        match mac {
            Mac::File(t) => Left::File {
                size: t.size,
                mtime_ns: t.mtime_ns,
                ctime_ns: t.ctime_ns,
                mode: t.mode,
            },
            Mac::Link(text) => Left::Link { text: text.clone() },
            Mac::Dir => Left::Dir,
            Mac::Missing | Mac::Other | Mac::Blocked => Left::Missing,
        }
    }

    fn base(&self) -> Base {
        match self {
            Left::File { size, mtime_ns, ctime_ns, mode } => Base::Shown(Mac::File(Times {
                mode: *mode,
                size: *size,
                mtime_ns: *mtime_ns,
                ctime_ns: *ctime_ns,
            })),
            Left::Link { text } => Base::Shown(Mac::Link(text.clone())),
            Left::Dir => Base::Shown(Mac::Dir),
            Left::Missing => Base::Shown(Mac::Missing),
            Left::Conflict => Base::Conflicted,
        }
    }
}

impl Run<'_, '_> {
    /// The whole pull: the work list, then each item.
    fn all(&mut self, changes: Vec<(String, Change)>) -> Result<(), Failure> {
        for (path, change) in changes {
            if rules::plain(&path) {
                self.upper.insert(path, change);
            } else {
                self.refuse(&path, "unsafe_path");
            }
        }
        let groups = self.groups()?;
        let mut covered: BTreeSet<String> = self.upper.keys().cloned().collect();
        covered.extend(groups.iter().flat_map(|g| g.items.iter().map(|item| item.path.clone())));
        // Paths an earlier pull brought that the machine no longer has: deleted first, children
        // before their folders, so a delete of a folder above finds them gone.
        let vanished: Vec<Item> = self
            .ledger
            .paths
            .iter()
            .rev()
            .filter(|(path, pulled)| {
                !covered.contains(*path) && !matches!(pulled.machine.as_str(), "delete" | "gone")
            })
            .map(|(path, _)| Item { path: path.clone(), work: Work::Vanished })
            .collect();
        self.ignored = self.ignored_of(&groups);
        for item in &vanished {
            self.item(item)?;
        }
        for group in &groups {
            if let Some(tag) = &group.tag
                && self.settled(&group.head, tag)
            {
                continue;
            }
            for item in &group.items {
                self.item(item)?;
            }
            if let Some(tag) = &group.tag
                && !self.back.dry_run
                && let Some(pulled) = self.ledger.paths.get_mut(&group.head)
            {
                pulled.machine.clone_from(tag);
            }
        }
        Ok(())
    }

    /// The work list: moved folders first (while what they bring is still here to serve), then
    /// every other change in path order, an opaque folder followed by the deletes it means.
    fn groups(&self) -> Result<Vec<Group>, Failure> {
        let mut first = Vec::new();
        let mut rest = Vec::new();
        for (path, change) in &self.upper {
            let one = |work: Work| Group {
                head: path.clone(),
                tag: None,
                items: vec![Item { path: path.clone(), work }],
            };
            match change {
                Change::Redirect(from) => first.push(self.moved(path, from)?),
                Change::OpaqueDir => {
                    let mut items = vec![Item { path: path.clone(), work: Work::Dir }];
                    items.extend(self.hidden(path));
                    rest.push(Group { head: path.clone(), tag: Some("opaque".into()), items });
                }
                Change::File => rest.push(one(Work::File)),
                Change::Metadata => rest.push(one(Work::Metadata)),
                Change::Symlink(text) => rest.push(one(Work::Link(text.clone()))),
                Change::Dir => rest.push(one(Work::Dir)),
                Change::Delete => rest.push(one(Work::Delete)),
                Change::Unsupported(why) => {
                    rest.push(one(Work::Refused(format!("unsupported: {why}"))));
                }
            }
        }
        first.extend(rest);
        Ok(first)
    }

    /// A moved folder (or file) at `path` from `from`, mapped as a create of everything it holds.
    fn moved(&self, path: &str, from: &str) -> Result<Group, Failure> {
        let unmapped = |why: &str| {
            let message = format!(
                "{path} was moved on the machine from {from:?}, which this Mac cannot map ({why}); \
                 nothing was brought back"
            );
            Failure::new("redirect_unmapped", message)
        };
        if rules::ancestors(path)
            .any(|above| matches!(self.upper.get(above), Some(Change::Redirect(_))))
        {
            return Err(unmapped("a folder above it was moved too"));
        }
        let lower = from.strip_prefix('/').map_or_else(|| join(parent(path), from), str::to_owned);
        if !rules::plain(&lower) {
            return Err(unmapped("its origin is not a plain path"));
        }
        let manifest = self.back.manifest;
        let Some((top, entry)) = find(manifest, &lower) else {
            return Err(unmapped("the projection has nothing there"));
        };
        let tag = Some(format!("redirect:{from}"));
        let head = path.to_owned();
        match entry.stat.kind {
            Kind::File => {
                let items = vec![Item { path: head.clone(), work: Work::File }];
                Ok(Group { head, tag, items })
            }
            Kind::Symlink => Err(unmapped("a symlink")),
            Kind::Dir => {
                let mut items = vec![Item { path: head.clone(), work: Work::Dir }];
                for at in below(manifest, top) {
                    let (Some(entry), Some(full)) = (manifest.entry(at), manifest.path_of(at))
                    else {
                        continue;
                    };
                    let Some(rel) = full.strip_prefix(&lower).and_then(|r| r.strip_prefix('/'))
                    else {
                        continue;
                    };
                    let new = join(path, rel);
                    if self.replaced_below(path, &new) {
                        continue;
                    }
                    let work = match (&shown(entry), entry.stat.kind) {
                        (Base::Withheld, _) => Work::Refused("secret".into()),
                        (_, Kind::File) => Work::File,
                        (_, Kind::Symlink) => {
                            Work::Link(entry.stat.link.clone().unwrap_or_default())
                        }
                        (_, Kind::Dir) => Work::Dir,
                    };
                    items.push(Item { path: new, work });
                }
                Ok(Group { head, tag, items })
            }
        }
    }

    /// Whether the upper layer replaces `path` below the moved folder `top`: something other
    /// than a plain folder at it or at a folder between.
    fn replaced_below(&self, top: &str, path: &str) -> bool {
        let replaces = |at: &str| self.upper.get(at).is_some_and(|change| *change != Change::Dir);
        replaces(path)
            || rules::ancestors(path)
                .filter(|above| above.len() > top.len() && above.starts_with(top))
                .any(replaces)
    }

    /// The deletes an opaque folder at `path` means: every entry the projection lists below it
    /// that the upper layer does not have, at the top of what is hidden (a hidden folder's delete
    /// takes what is below it).
    fn hidden(&self, path: &str) -> Vec<Item> {
        let manifest = self.back.manifest;
        let Some((top, entry)) = find(manifest, path) else { return Vec::new() };
        if entry.stat.kind != Kind::Dir {
            return Vec::new();
        }
        below(manifest, top)
            .into_iter()
            .filter_map(|at| manifest.path_of(at))
            .filter(|lower| {
                !self.upper.contains_key(lower)
                    && (parent(lower) == path || self.upper.contains_key(parent(lower)))
            })
            .map(|lower| Item { path: lower, work: Work::Delete })
            .collect()
    }

    /// Which new paths of the work list this working copy's ignore rules match (the walker
    /// leaves them out); none outside git.
    fn ignored_of(&self, groups: &[Group]) -> BTreeSet<String> {
        if !crate::link::sync_cli::in_git(self.back.root) {
            return BTreeSet::new();
        }
        let new: Vec<(String, bool)> = groups
            .iter()
            .flat_map(|group| &group.items)
            .filter(|item| {
                matches!(item.work, Work::File | Work::Metadata | Work::Link(_) | Work::Dir)
            })
            .filter(|item| !rules::in_dotgit(&item.path))
            .filter(|item| self.base(&item.path) == Base::Shown(Mac::Missing))
            .map(|item| (item.path.clone(), item.work == Work::Dir))
            .collect();
        rules::ignored(self.back.root, &new)
    }

    /// The base of `path`: what an earlier pull left, else what the manifest showed.
    fn base(&self, path: &str) -> Base {
        if let Some(pulled) = self.ledger.paths.get(path) {
            return pulled.mac.base();
        }
        find(self.back.manifest, path).map_or(Base::Shown(Mac::Missing), |(_, entry)| shown(entry))
    }

    /// Whether an earlier pull settled `path` at the machine version `tag` (then it is skipped).
    fn settled(&mut self, path: &str, tag: &str) -> bool {
        let settled = self.ledger.paths.get(path).is_some_and(|pulled| pulled.machine == tag);
        if settled {
            self.out.unchanged = self.out.unchanged.saturating_add(1);
        }
        settled
    }

    fn record(&mut self, path: &str, tag: &str, mac: Left) {
        if !self.back.dry_run {
            self.ledger.paths.insert(path.to_owned(), Pulled { machine: tag.to_owned(), mac });
        }
    }

    fn refuse(&mut self, path: &str, reason: &str) {
        self.out.refused.push(json!({ "path": path, "reason": reason }));
    }

    fn conflict(&mut self, path: &str, kept: Option<&str>, beside: Option<&str>) {
        self.out.conflicts.push(json!({ "path": path, "kept": kept, "beside": beside }));
    }
}
