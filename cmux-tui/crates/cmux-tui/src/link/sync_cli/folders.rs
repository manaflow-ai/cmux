//! The folders a push makes on the machine, and what it knows of them without asking.
//!
//! A folder this push made was empty when it was made, and nothing else writes into a
//! push's folder while it runs: what is inside it is what this push put there. So a
//! folder below one this push made needs no `fs.stat` (nothing can be in the way), no
//! `fs.list` (it holds nothing yet) and no symlink check, and it can be made later, with
//! the other new folders, several at once ([`make`]). Before this, a copy into a new
//! folder asked the machine three to five questions one after another for each of its
//! folders before it wrote its first file: 4,706 folders of a cmux checkout sat at
//! "0 of 46,516 files" for over twenty minutes on a Cloud link.

use std::collections::BTreeSet;
use std::path::Path;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};

use super::remote::{self, Remote};

/// The folders a push made or found, and the ones it still has to make.
#[derive(Default)]
pub(super) struct Folders {
    /// Made by this push (now or in [`Self::waiting`]): empty when made.
    made: BTreeSet<String>,
    /// Found on the machine as folders.
    found: BTreeSet<String>,
    /// Below a folder this push made, to make before the writes, parents first.
    waiting: Vec<String>,
}

impl Folders {
    /// Whether `folder` is one this push made, or is below one: nothing of the machine's is
    /// in it or on the way to it below that folder.
    pub(super) fn ours(&self, folder: &str) -> bool {
        self.made_above(folder).is_some()
    }

    /// The folders from `folder` up to (not with) the nearest one this push made, `folder`
    /// first; None when no folder above it, or it, is this push's.
    fn made_above<'a>(&self, folder: &'a str) -> Option<Vec<&'a str>> {
        let mut below = Vec::new();
        let mut at = folder;
        loop {
            if self.made.contains(at) {
                return Some(below);
            }
            below.push(at);
            match remote::split(at) {
                Ok((parent, _)) if parent != at && parent != "/" => at = parent,
                _ => return None,
            }
        }
    }

    /// `folder` was made by this push just now, before any of its files.
    pub(super) fn mark_made(&mut self, folder: &str) {
        self.made.insert(folder.to_owned());
    }

    /// `folder` is there before a write into it: found, made now (its parent is a folder
    /// of the machine's), or noted to make with [`make`] (its parent is this push's).
    pub(super) fn ensure(&mut self, remote: &mut Remote, folder: &str) -> anyhow::Result<()> {
        if self.made.contains(folder) || self.found.contains(folder) {
            return Ok(());
        }
        if let Some(below) = self.made_above(folder) {
            // Parents first, so [`make`] makes each after the folder it is in.
            for missing in below.into_iter().rev() {
                self.made.insert(missing.to_owned());
                self.waiting.push(missing.to_owned());
            }
            return Ok(());
        }
        if remote.kind(folder)?.as_deref() == Some("dir") {
            self.found.insert(folder.to_owned());
            return Ok(());
        }
        let (parent, name) = remote::split(folder)?;
        self.ensure(remote, parent)?;
        if self.made.contains(parent) {
            // Its parent was made (or waits): it waits too, after it.
            self.made.insert(folder.to_owned());
            self.waiting.push(folder.to_owned());
            return Ok(());
        }
        if remote.mkdir(parent, name)? {
            self.made.insert(folder.to_owned());
        } else {
            self.found.insert(folder.to_owned());
        }
        Ok(())
    }

    /// The folders [`ensure`](Self::ensure) left to make, parents before children.
    pub(super) fn take_waiting(&mut self) -> Vec<String> {
        std::mem::take(&mut self.waiting)
    }
}

/// Makes `folders` (each one's parent is in the list before it, or exists) on up to
/// `connections` connections of their own, a depth at a time so a parent is always made
/// before its children. `report(done, total)` hears each one made.
pub(super) fn make(
    socket: &Path,
    folders: &[String],
    connections: usize,
    report: &mut dyn FnMut(u64, u64),
) -> anyhow::Result<()> {
    let total = folders.len() as u64;
    if total == 0 {
        return Ok(());
    }
    let mut by_depth: Vec<Vec<&str>> = Vec::new();
    for folder in folders {
        let depth = folder.matches('/').count();
        if by_depth.len() <= depth {
            by_depth.resize_with(depth + 1, Vec::new);
        }
        by_depth[depth].push(folder);
    }
    let workers = connections.clamp(1, folders.len());
    let mut remotes: Vec<Option<Remote>> = (0..workers).map(|_| None).collect();
    let done = AtomicU64::new(0);
    for level in by_depth.iter().filter(|level| !level.is_empty()) {
        let next = AtomicUsize::new(0);
        let stop = AtomicBool::new(false);
        let failed: Mutex<Option<anyhow::Error>> = Mutex::new(None);
        let (sent, heard) = std::sync::mpsc::channel::<()>();
        std::thread::scope(|scope| {
            for remote in remotes.iter_mut().take(level.len()) {
                let (next, stop, failed, sent) = (&next, &stop, &failed, sent.clone());
                scope.spawn(move || {
                    while !stop.load(Ordering::Relaxed) {
                        let index = next.fetch_add(1, Ordering::Relaxed);
                        let Some(folder) = level.get(index) else { break };
                        let made = make_one(remote, socket, folder);
                        if let Err(error) = made {
                            stop.store(true, Ordering::Relaxed);
                            if let Ok(mut first) = failed.lock() {
                                first.get_or_insert(error);
                            }
                            break;
                        }
                        if sent.send(()).is_err() {
                            break;
                        }
                    }
                });
            }
            drop(sent);
            for () in heard {
                report(done.fetch_add(1, Ordering::Relaxed) + 1, total);
            }
        });
        if let Some(error) = failed.into_inner().ok().flatten() {
            return Err(error);
        }
    }
    Ok(())
}

fn make_one(remote: &mut Option<Remote>, socket: &Path, folder: &str) -> anyhow::Result<()> {
    if remote.is_none() {
        *remote = Some(Remote::connect_negotiated(socket)?);
    }
    let Some(remote) = remote.as_mut() else { anyhow::bail!("no connection to the machine") };
    let (parent, name) = remote::split(folder)?;
    remote.mkdir(parent, name).map(drop)
}
