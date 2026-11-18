//! This Mac's side of the way back ([`super`]): what is at a path of the folder now, and the few
//! changes the pull makes there. Everything goes through folder handles opened one name at a time
//! that follow no symlink ([`place::Dir`]), so nothing is read or written outside the folder or
//! through a symlink on the way, also when one is swapped in meanwhile.
//!
//! A file is replaced or deleted only after it is renamed aside and found to be the very file that
//! was checked (same inode, size and mtime); one that changed meanwhile goes back, and a new file
//! there is never replaced: the answer is [`Swap::Changed`] and the caller keeps this Mac's file.

use std::collections::{BTreeMap, BTreeSet};
use std::fs::File;
use std::io;
use std::path::Path;

use crate::link::sync_cli::merge::CONFLICT_SUFFIX;
use crate::link::sync_cli::names;
use crate::link::sync_cli::place::{self, Dir};
use crate::link::sync_cli::stat_walk::{Times, times_of_stat};

use super::rules::join;

/// What is at a path of this Mac's folder.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum Mac {
    Missing,
    File(Times),
    Link(String),
    Dir,
    /// A special file, or a symlink whose text is not UTF-8.
    Other,
    /// A folder on the way is a symlink or not a folder: nothing is read or written through it.
    Blocked,
}

/// Whether `now` is the version `then` (a file by size, mtime and ctime, as `project-serve`
/// compares; a symlink by its text).
pub(super) fn same(now: &Mac, then: &Mac) -> bool {
    match (now, then) {
        (Mac::File(a), Mac::File(b)) => {
            a.size == b.size && a.mtime_ns == b.mtime_ns && a.ctime_ns == b.ctime_ns
        }
        (Mac::Link(a), Mac::Link(b)) => a == b,
        (Mac::Missing, Mac::Missing) | (Mac::Dir, Mac::Dir) => true,
        _ => false,
    }
}

/// What a guarded change did.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Swap {
    Done,
    /// This Mac's entry was not the one checked (or one came meanwhile): nothing replaced it.
    Changed,
    /// Nothing is there any more.
    Gone,
}

/// A name folding (as a Mac's disk compares names) onto another name of this Mac's folder.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum Fold {
    Clear,
    /// The path's last name is this Mac's own spelling of it (this path).
    Name(String),
    /// A folder on the way is.
    Folder,
}

fn blocked(error: &io::Error) -> bool {
    matches!(error.raw_os_error(), Some(libc::ELOOP | libc::ENOTDIR))
}

/// A folder's names, exactly and folded.
struct Names {
    exact: BTreeSet<String>,
    folded: BTreeMap<String, String>,
}

impl Names {
    fn add(&mut self, name: &str) {
        self.exact.insert(name.to_owned());
        self.folded.insert(names::folded_path(name), name.to_owned());
    }
}

/// This Mac's folder, held open.
pub(super) struct Disk {
    root: Dir,
    names: BTreeMap<String, Option<Names>>,
    next: u64,
}

impl Disk {
    pub(super) fn open(root: &Path) -> anyhow::Result<Disk> {
        Ok(Disk { root: Dir::open(root)?, names: BTreeMap::new(), next: 0 })
    }

    /// What is at `path` now.
    pub(super) fn look(&self, path: &str) -> io::Result<Mac> {
        match place::parent_of(&self.root, path) {
            Ok(Some((dir, name))) => look_in(&dir, &name),
            Ok(None) => Ok(Mac::Missing),
            Err(error) if blocked(&error) => Ok(Mac::Blocked),
            Err(error) => Err(error),
        }
    }

    /// The folder holding `path` and its last name, when that folder is a real one here.
    pub(super) fn holder(&self, path: &str) -> io::Result<Option<(Dir, String)>> {
        match place::parent_of(&self.root, path) {
            Err(error) if blocked(&error) => Ok(None),
            other => other,
        }
    }

    /// The folder holding `path` (made, 0755, where missing) and its last name.
    pub(super) fn make_parent(&mut self, path: &str) -> io::Result<(Dir, String)> {
        let mut parts: Vec<&str> = path.split('/').collect();
        let name = parts.pop().unwrap_or_default().to_owned();
        let mut at = self.root.dup()?;
        let mut done = String::new();
        for part in parts {
            let next = match at.child(part)? {
                Some(next) => next,
                None => {
                    match at.mkdir(part) {
                        Ok(()) => self.noted(&done, part),
                        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
                        Err(error) => return Err(error),
                    }
                    at.child(part)?.ok_or_else(|| io::Error::from(io::ErrorKind::NotFound))?
                }
            };
            done = join(&done, part);
            at = next;
        }
        Ok((at, name))
    }

    /// The folder `dir` (relative), when it is a real folder here.
    fn folder(&self, dir: &str) -> io::Result<Option<Dir>> {
        let mut at = self.root.dup()?;
        for part in dir.split('/').filter(|part| !part.is_empty()) {
            match at.child(part) {
                Ok(Some(next)) => at = next,
                Ok(None) => return Ok(None),
                Err(error) if blocked(&error) => return Ok(None),
                Err(error) => return Err(error),
            }
        }
        Ok(Some(at))
    }

    fn listed(&mut self, dir: &str) -> io::Result<Option<&Names>> {
        if !self.names.contains_key(dir) {
            let names = match self.folder(dir)? {
                None => None,
                Some(folder) => {
                    let mut listed = Names { exact: BTreeSet::new(), folded: BTreeMap::new() };
                    for name in folder.names()? {
                        if let Some(name) = name.to_str() {
                            listed.add(name);
                        }
                    }
                    Some(listed)
                }
            };
            self.names.insert(dir.to_owned(), names);
        }
        Ok(self.names.get(dir).and_then(Option::as_ref))
    }

    /// Notes that `name` is in `dir` now (a folder or file this pull made).
    pub(super) fn noted(&mut self, dir: &str, name: &str) {
        if let Some(Some(names)) = self.names.get_mut(dir) {
            names.add(name);
        }
    }

    /// Whether `path`, a name this Mac's folder does not have, folds onto one it has.
    pub(super) fn fold(&mut self, path: &str) -> io::Result<Fold> {
        let parts: Vec<&str> = path.split('/').collect();
        let mut dir = String::new();
        for (at, part) in parts.iter().enumerate() {
            let Some(listed) = self.listed(&dir)? else { return Ok(Fold::Clear) };
            if !listed.exact.contains(*part) {
                return Ok(match listed.folded.get(&names::folded_path(part)) {
                    Some(own) if at + 1 == parts.len() => Fold::Name(join(&dir, own)),
                    Some(_) => Fold::Folder,
                    None => Fold::Clear,
                });
            }
            dir = join(&dir, part);
        }
        Ok(Fold::Clear)
    }

    fn fresh(&mut self, what: &str) -> String {
        self.next = self.next.saturating_add(1);
        format!(".cmux-pull-{}-{}.{what}", std::process::id(), self.next)
    }

    /// A new private file of this pull in `dir`, for bytes on their way to a name there.
    pub(super) fn temp(&mut self, dir: &Dir) -> io::Result<(String, File)> {
        loop {
            let name = self.fresh("part");
            match dir.create_file(&name, 0o600) {
                Ok(file) => return Ok((name, file)),
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
                Err(error) => return Err(error),
            }
        }
    }

    /// Moves `name` in `dir` aside when it is still `expected` (checked before the move, then
    /// the moved file's inode, size and mtime against that look); its aside name.
    fn take(&mut self, dir: &Dir, name: &str, expected: &Mac) -> io::Result<Result<String, Swap>> {
        let Some((before, inode)) = probe(dir, name)? else { return Ok(Err(Swap::Gone)) };
        if !same(&before, expected) {
            return Ok(Err(Swap::Changed));
        }
        // One atomic step takes whatever is at the name now; the check below says whether it
        // is the version looked at (a rename changes the ctime, so the inode stands in for it).
        let aside = self.fresh("aside");
        match dir.rename(name, dir, &aside) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Err(Swap::Gone)),
            Err(error) => return Err(error),
        }
        let moved = probe(dir, &aside)?;
        let unchanged = moved.as_ref().is_some_and(|(now, at)| {
            *at == inode
                && match (now, &before) {
                    (Mac::File(a), Mac::File(b)) => a.size == b.size && a.mtime_ns == b.mtime_ns,
                    (a, b) => a == b,
                }
        });
        if unchanged {
            return Ok(Ok(aside));
        }
        self.put_back(dir, &aside, name)?;
        Ok(Err(Swap::Changed))
    }

    /// Puts what was moved aside back at `name`, never over anything there: a name taken
    /// meanwhile leaves it under a conflict name beside, or (none free) where it is.
    fn put_back(&self, dir: &Dir, aside: &str, name: &str) -> io::Result<()> {
        if back_at(dir, aside, name)? {
            return Ok(());
        }
        for side in conflict_names(name) {
            if back_at(dir, aside, &side)? {
                return Ok(());
            }
        }
        Ok(())
    }

    /// Replaces the file or symlink `name` in `dir`, still `expected`, with the staged file
    /// `temp` (a file) or the symlink text `link`.
    pub(super) fn replace(
        &mut self,
        dir: &Dir,
        name: &str,
        expected: &Mac,
        with: &With<'_>,
    ) -> io::Result<Swap> {
        let aside = match self.take(dir, name, expected)? {
            Ok(aside) => aside,
            Err(Swap::Gone) => return Ok(Swap::Changed),
            Err(other) => return Ok(other),
        };
        match place_new(dir, with, name) {
            Ok(true) => {
                let _ = dir.unlink(&aside, false);
                Ok(Swap::Done)
            }
            // Something new came meanwhile: it stays. What was aside is the checked version.
            Ok(false) => {
                let _ = dir.unlink(&aside, false);
                Ok(Swap::Changed)
            }
            Err(error) => {
                self.put_back(dir, &aside, name)?;
                Err(error)
            }
        }
    }

    /// Deletes the file or symlink `name` in `dir` when it is still `expected`.
    pub(super) fn delete(&mut self, dir: &Dir, name: &str, expected: &Mac) -> io::Result<Swap> {
        let aside = match self.take(dir, name, expected)? {
            Ok(aside) => aside,
            Err(other) => return Ok(other),
        };
        dir.unlink(&aside, false)?;
        Ok(Swap::Done)
    }

    /// Removes the folder `path` when it is empty; whether it is gone.
    pub(super) fn remove_dir(&self, path: &str) -> io::Result<bool> {
        let Ok(Some((dir, name))) = place::parent_of(&self.root, path) else { return Ok(false) };
        match look_in(&dir, &name)? {
            Mac::Dir => {}
            Mac::Missing => return Ok(true),
            _ => return Ok(false),
        }
        match dir.unlink(&name, true) {
            Ok(()) => Ok(true),
            Err(error) if matches!(error.raw_os_error(), Some(libc::ENOTEMPTY | libc::EEXIST)) => {
                Ok(false)
            }
            Err(error) => Err(error),
        }
    }
}

/// What a write puts at a name: the staged file of that name in the same folder, or a symlink.
pub(super) enum With<'a> {
    Staged(&'a str),
    Link(&'a str),
}

/// Puts `with` at `name` in `dir` only while nothing is there; whether it did.
pub(super) fn place_new(dir: &Dir, with: &With<'_>, name: &str) -> io::Result<bool> {
    let placed = match with {
        With::Staged(temp) => place::link_new(dir, temp, dir, name),
        With::Link(text) => dir.symlink(name, text),
    };
    match placed {
        Ok(()) => Ok(true),
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => Ok(false),
        Err(error) => Err(error),
    }
}

/// Puts `with` beside `name` in `dir` under the first free conflict name; that name, or None
/// when every one is taken.
pub(super) fn place_beside(dir: &Dir, with: &With<'_>, name: &str) -> io::Result<Option<String>> {
    for side in conflict_names(name) {
        if place_new(dir, with, &side)? {
            return Ok(Some(side));
        }
    }
    Ok(None)
}

/// The first conflict name beside `name` that is free now (what a dry run reports).
pub(super) fn free_beside(dir: Option<&Dir>, name: &str) -> io::Result<Option<String>> {
    let Some(dir) = dir else { return Ok(conflict_names(name).next()) };
    for side in conflict_names(name) {
        if dir.lstat(&side)?.is_none() {
            return Ok(Some(side));
        }
    }
    Ok(None)
}

/// The names a conflict copy beside `name` may take, as today's pull names them
/// (`NAME.cmux-sync-conflict`, then `NAME.2.cmux-sync-conflict` up to 9).
pub(super) fn conflict_names(name: &str) -> impl Iterator<Item = String> + '_ {
    (1..=9u32).map(move |n| {
        if n == 1 {
            format!("{name}{CONFLICT_SUFFIX}")
        } else {
            format!("{name}.{n}{CONFLICT_SUFFIX}")
        }
    })
}

/// `aside` back to `name` in `dir` while `name` is free; whether it went.
fn back_at(dir: &Dir, aside: &str, name: &str) -> io::Result<bool> {
    match look_in(dir, aside)? {
        Mac::Link(text) => {
            if !place_new(dir, &With::Link(&text), name)? {
                return Ok(false);
            }
            dir.unlink(aside, false)?;
            Ok(true)
        }
        _ => {
            let placed = place_new(dir, &With::Staged(aside), name)?;
            if placed {
                dir.unlink(aside, false)?;
            }
            Ok(placed)
        }
    }
}

/// What is at `name` in `dir`.
pub(super) fn look_in(dir: &Dir, name: &str) -> io::Result<Mac> {
    Ok(probe(dir, name)?.map_or(Mac::Missing, |(mac, _)| mac))
}

/// What is at `name` in `dir` and its (device, inode); None when nothing is.
fn probe(dir: &Dir, name: &str) -> io::Result<Option<(Mac, (u64, u64))>> {
    let Some(stat) = dir.lstat(name)? else { return Ok(None) };
    let inode = (place::widen_u64(stat.st_dev), place::widen_u64(stat.st_ino));
    let mac = match stat.st_mode & libc::S_IFMT {
        libc::S_IFREG => Mac::File(times_of_stat(&stat)),
        libc::S_IFLNK => dir.read_link(name).map_or(Mac::Other, Mac::Link),
        libc::S_IFDIR => Mac::Dir,
        _ => Mac::Other,
    };
    Ok(Some((mac, inode)))
}

/// The last name of `path`.
pub(super) fn name_of(path: &str) -> &str {
    path.rsplit_once('/').map_or(path, |(_, name)| name)
}
