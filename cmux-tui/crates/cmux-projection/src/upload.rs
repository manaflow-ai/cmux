//! The Mac's background upload (RFD 0007 slice 3, "Faults from the store"): the projected folder's
//! files go into the store, keyed by their git blob id ([`crate::peers::blob_id`]), in the order a
//! session would fault them, so once a file is in the store its fault no longer needs the Mac.
//!
//! [`Uploader`] wraps the Mac's [`Source`]: it answers the machine's asks as the source does,
//! remembers which files the machine faulted (their neighbours go up next), and answers
//! [`crate::wire::Ask::Stored`] with what it has put so far, so the machine learns each file's id
//! from the Mac itself and checks the store's bytes against it ([`crate::store_fetch`]). The store
//! is untrusted transport.
//!
//! The order ([`prefetch_order`]): the neighbours of the files the machine faulted most recently,
//! then the top-level files of each project folder (one holding a `Cargo.toml`, `package.json` and
//! the like, the folders a build reads one file of each, as the overlay's read-ahead does), then
//! every other file breadth-first (the manifest's own order: shallow files first). Files over
//! [`MAX_WHOLE`] stay with the Mac.

use std::collections::{HashSet, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use crate::link::Source;
use crate::manifest::{Kind, Manifest};
use crate::wire::{self, Part};

/// The largest file put whole (the store's whole-blob size, RFD 0007); bigger ones stay with the
/// Mac until the store takes chunks.
pub const MAX_WHOLE: u64 = 4 * 1024 * 1024;
/// Recent faults remembered for the order.
const RECENT: usize = 64;
/// Files listed in one [`wire::Ask::Stored`] answer (one part is the epoch).
const PER_ANSWER: usize = wire::MAX_BATCH as usize - 1;
/// Names that make a folder a project folder.
const PROJECT_FILES: [&str; 5] =
    ["Cargo.toml", "package.json", "go.mod", "pyproject.toml", "Package.swift"];

/// Where the upload puts blobs: an S3-compatible bucket (`s3::Bucket` once cmux#51546 lands), the
/// platform's `/v1/sync`, or a fake in tests.
pub trait Store: Send + Sync {
    /// Puts `bytes` as `oid` (a store that already holds it may skip the write).
    fn put(&self, oid: &str, bytes: &[u8]) -> anyhow::Result<()>;
}

/// The files of `manifest` in upload order: the files beside each of `recent` (most recent
/// first), then the top-level files of project folders, then the rest breadth-first. Only files
/// of at most [`MAX_WHOLE`] bytes; each once.
#[must_use]
pub fn prefetch_order(manifest: &Manifest, recent: &[u32]) -> Vec<u32> {
    let mut order = beside(manifest, recent);
    let mut seen: HashSet<u32> = order.iter().copied().collect();
    let mut push = |index: u32, order: &mut Vec<u32>| {
        if small_file(manifest, index) && seen.insert(index) {
            order.push(index);
        }
    };
    for index in 0..manifest.len() as u32 {
        let Some(entry) = manifest.entry(index) else { continue };
        if entry.kind != Kind::Dir {
            continue;
        }
        let (first, children) = manifest.children(index);
        if children.iter().any(|child| PROJECT_FILES.contains(&child.name.as_str())) {
            for index in first..first + children.len() as u32 {
                push(index, &mut order);
            }
        }
    }
    for index in 0..manifest.len() as u32 {
        push(index, &mut order);
    }
    order
}

fn small_file(manifest: &Manifest, index: u32) -> bool {
    manifest.entry(index).is_some_and(|entry| entry.kind == Kind::File && entry.size <= MAX_WHOLE)
}

/// The small files in the folders of `recent` (in that order of faults, each folder's by name),
/// each once.
fn beside(manifest: &Manifest, recent: &[u32]) -> Vec<u32> {
    let mut folders = HashSet::new();
    let mut order = Vec::new();
    for fault in recent {
        let Some(entry) = manifest.entry(*fault) else { continue };
        if !folders.insert(entry.parent) {
            continue;
        }
        let (first, children) = manifest.children(entry.parent);
        order.extend(
            (first..first + children.len() as u32).filter(|index| small_file(manifest, *index)),
        );
    }
    order
}

/// What [`Uploader::run`] did.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Uploaded {
    pub files: usize,
    pub bytes: u64,
    /// Files the source could not read whole, or that changed since the manifest (left to the
    /// Mac).
    pub skipped: usize,
    /// Puts the store refused.
    pub failed: usize,
}

#[derive(Default)]
struct State {
    /// Faults the machine asked for, most recent at the back.
    recent: VecDeque<u32>,
    /// Files tried, put or not.
    done: HashSet<u32>,
    /// What is in the store, in the order it went in.
    stored: Vec<(u32, String)>,
}

/// The Mac's source, uploading to a store as it serves.
pub struct Uploader<S> {
    source: S,
    manifest: Arc<Manifest>,
    epoch: u64,
    state: Mutex<State>,
    stop: AtomicBool,
}

impl<S: Source + Sync> Uploader<S> {
    /// An uploader of `manifest`'s files, read from `source`. `epoch` names this upload (a new
    /// process picks a new one, so the machine starts its list again).
    pub fn new(source: S, manifest: Arc<Manifest>, epoch: u64) -> Self {
        Self {
            source,
            manifest,
            epoch,
            state: Mutex::new(State::default()),
            stop: AtomicBool::new(false),
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn faulted(&self, entry: u32) {
        let mut state = self.lock();
        state.recent.retain(|at| *at != entry);
        state.recent.push_back(entry);
        if state.recent.len() > RECENT {
            state.recent.pop_front();
        }
    }

    /// Ends [`Uploader::run`] after the file it is putting.
    pub fn stop(&self) {
        self.stop.store(true, Ordering::Relaxed);
    }

    /// What is in the store so far, in the order it went in.
    #[must_use]
    pub fn stored_files(&self) -> Vec<(u32, String)> {
        self.lock().stored.clone()
    }

    /// The next file to put: an untried file beside a recent fault (most recent first), so a
    /// session's new folder goes up next, else the next untried file of the base order.
    /// A fault whose folder has nothing left untried is forgotten, so each folder is scanned
    /// to its end once, not once per file put.
    fn next(&self, order: &[u32], at: &mut usize) -> Option<u32> {
        let mut state = self.lock();
        while let Some(fault) = state.recent.back().copied() {
            let pick = beside(&self.manifest, &[fault])
                .into_iter()
                .find(|index| !state.done.contains(index));
            if pick.is_some() {
                return pick;
            }
            state.recent.pop_back();
        }
        while let Some(index) = order.get(*at).copied() {
            *at += 1;
            if !state.done.contains(&index) {
                return Some(index);
            }
        }
        None
    }

    /// Puts every small file of the manifest in the store in prefetch order, then returns. Each
    /// file is read whole from the source (a file that changed since the manifest is left to the
    /// Mac), named by its git blob id and put; a put that fails is left to the Mac too.
    pub fn run(&self, store: &dyn Store) -> Uploaded {
        let order = prefetch_order(&self.manifest, &[]);
        let mut at = 0;
        let mut uploaded = Uploaded::default();
        while !self.stop.load(Ordering::Relaxed) {
            let Some(index) = self.next(&order, &mut at) else { break };
            self.lock().done.insert(index);
            let part = self.source.whole(index);
            let size = self.manifest.entry(index).map_or(u64::MAX, |entry| entry.size);
            if part.status != wire::OK || part.bytes.len() as u64 != size {
                uploaded.skipped += 1;
                continue;
            }
            let oid = crate::peers::blob_id(&part.bytes, 40);
            if store.put(&oid, &part.bytes).is_err() {
                uploaded.failed += 1;
                continue;
            }
            uploaded.files += 1;
            uploaded.bytes += size;
            self.lock().stored.push((index, oid));
        }
        uploaded
    }
}

impl<S: Source + Sync> Source for Uploader<S> {
    fn read(&self, entry: u32, offset: u64, len: u32) -> Part {
        self.faulted(entry);
        self.source.read(entry, offset, len)
    }

    fn whole(&self, entry: u32) -> Part {
        self.faulted(entry);
        self.source.whole(entry)
    }

    fn stored(&self, since: u32) -> Vec<Part> {
        let state = self.lock();
        let mut parts = vec![Part::ok(self.epoch.to_le_bytes().to_vec())];
        parts.extend(state.stored.iter().skip(since as usize).take(PER_ANSWER).map(
            |(entry, oid)| {
                let mut bytes = entry.to_le_bytes().to_vec();
                bytes.extend_from_slice(oid.as_bytes());
                Part::ok(bytes)
            },
        ));
        parts
    }
}
