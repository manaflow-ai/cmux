//! The lower layer an overlay reads: a manifest, and once the Mac sent the whole folder after a
//! small head (`projection-extend-v1`), that fuller manifest in the head's place.
//!
//! A path's number in the overlay (its "id") must not change when the full manifest arrives:
//! the kernel holds inodes, handles hold entries, the cache holds blobs, all by id. So an id is
//! an index of the head manifest for every path the head has, and `head.len() + i` for a path
//! only the full manifest (index `i`) has. The full manifest is laid out as the Mac made it, so
//! the wire (the Mac answers an ask by an index of the manifest it holds) speaks its indices:
//! [`Ext::wire_of`] turns an id into one, per stream ([`crate::link::Link::serve_with`]).
//!
//! The extension is set once ([`Lower::extend`]); until then every id is a head index and
//! nothing differs from a plain manifest.

use std::sync::{Arc, OnceLock};

use crate::manifest::{Entry, Manifest, ROOT};

/// An id no entry has: what an unknown id turns into on the wire (the Mac refuses it).
pub const NO_ENTRY: u32 = u32::MAX;

/// Why a full manifest does not extend the mounted one.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ExtendError {
    /// A path of the mounted manifest is missing from the full one, or is another kind there.
    NotSuperset { path: String, why: &'static str },
    /// The overlay was extended already.
    Done,
}

impl std::fmt::Display for ExtendError {
    fn fmt(&self, out: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotSuperset { path, why } => write!(out, "{path:?} {why} in the full manifest"),
            Self::Done => write!(out, "the projection was extended already"),
        }
    }
}

impl std::error::Error for ExtendError {}

/// The full manifest and how its indices and ids map to each other.
pub struct Ext {
    full: Arc<Manifest>,
    /// How many entries the head has: the first id only the full manifest's entries have.
    base: u32,
    /// The full manifest's index of each head entry.
    to_full: Vec<u32>,
    /// The id of each full-manifest entry.
    from_full: Vec<u32>,
}

impl Ext {
    /// The full manifest's index of `id`; [`NO_ENTRY`] when no entry has it.
    #[must_use]
    pub fn wire_of(&self, id: u32) -> u32 {
        if id < self.base {
            self.to_full.get(id as usize).copied().unwrap_or(NO_ENTRY)
        } else {
            let index = id - self.base;
            if (index as usize) < self.full.len() { index } else { NO_ENTRY }
        }
    }

    /// The id of the full manifest's entry `index`.
    #[must_use]
    pub fn id_of(&self, index: u32) -> Option<u32> {
        self.from_full.get(index as usize).copied()
    }

    /// The full manifest.
    #[must_use]
    pub fn full(&self) -> &Arc<Manifest> {
        &self.full
    }

    /// The head entries (their ids) whose entry in the full manifest differs: a changed size,
    /// time, mode or link text, or a folder with another number of children. In id order.
    #[must_use]
    pub fn changed(&self, head: &Manifest) -> Vec<u32> {
        let mut changed = Vec::new();
        for (id, was) in head.entries().iter().enumerate() {
            let Some(now) = self.to_full.get(id).and_then(|index| self.full.entry(*index)) else {
                continue;
            };
            let same = was.kind == now.kind
                && was.mode == now.mode
                && was.size == now.size
                && was.mtime_ns == now.mtime_ns
                && was.link == now.link
                && was.children == now.children;
            if !same && let Ok(id) = u32::try_from(id) {
                changed.push(id);
            }
        }
        changed
    }
}

/// The manifest an overlay reads, with ids as the module docs say.
pub struct Lower {
    head: Arc<Manifest>,
    ext: OnceLock<Arc<Ext>>,
}

impl Lower {
    #[must_use]
    pub fn new(head: Arc<Manifest>) -> Self {
        Self { head, ext: OnceLock::new() }
    }

    /// The manifest the overlay was opened on.
    #[must_use]
    pub fn head(&self) -> &Arc<Manifest> {
        &self.head
    }

    /// The extension, once there is one.
    #[must_use]
    pub fn extended(&self) -> Option<&Arc<Ext>> {
        self.ext.get()
    }

    /// Makes `full` the lower layer, every id the same. Refused when a path of the head is not in
    /// `full` as the same kind of entry, and when there was an extension already.
    pub fn extend(&self, full: Arc<Manifest>) -> Result<Arc<Ext>, ExtendError> {
        if self.ext.get().is_some() {
            return Err(ExtendError::Done);
        }
        let base = u32::try_from(self.head.len())
            .map_err(|_| ExtendError::NotSuperset { path: String::new(), why: "is too large" })?;
        let total = (base as usize).checked_add(full.len());
        if total.is_none_or(|total| u32::try_from(total).is_err()) {
            return Err(ExtendError::NotSuperset { path: String::new(), why: "is too large" });
        }
        // Parents come before their children (breadth-first), so a parent's index is known.
        let mut to_full = Vec::with_capacity(self.head.len());
        for (id, entry) in self.head.entries().iter().enumerate() {
            let found = if id == ROOT as usize {
                Some(ROOT)
            } else {
                to_full.get(entry.parent as usize).and_then(|at| full.lookup(*at, &entry.name))
            };
            let Some(index) = found else {
                return Err(ExtendError::NotSuperset {
                    path: self.head.path_of(u32::try_from(id).unwrap_or(0)),
                    why: "is missing",
                });
            };
            if full.entry(index).map(|now| now.kind) != Some(entry.kind) {
                return Err(ExtendError::NotSuperset {
                    path: self.head.path_of(u32::try_from(id).unwrap_or(0)),
                    why: "is another kind",
                });
            }
            to_full.push(index);
        }
        let mut from_full: Vec<u32> = (0..full.len() as u32).map(|index| base + index).collect();
        for (id, index) in to_full.iter().enumerate() {
            if let (Some(slot), Ok(id)) = (from_full.get_mut(*index as usize), u32::try_from(id)) {
                *slot = id;
            }
        }
        let ext = Arc::new(Ext { full, base, to_full, from_full });
        match self.ext.set(ext.clone()) {
            Ok(()) => Ok(ext),
            Err(_) => Err(ExtendError::Done),
        }
    }

    /// How many ids there are: the head's entries, and with an extension the full manifest's.
    #[must_use]
    pub fn len(&self) -> usize {
        self.head.len() + self.ext.get().map_or(0, |ext| ext.full.len())
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// The ids below this are the head's indices (the overlay hands out `id + 1` as their inode).
    #[must_use]
    pub fn head_len(&self) -> usize {
        self.head.len()
    }

    /// The full manifest's entry for `id` (`parent` and `first_child` are in its own indices).
    #[must_use]
    pub fn entry(&self, id: u32) -> Option<&Entry> {
        match self.ext.get() {
            Some(ext) => ext.full.entry(ext_index(ext, id)?),
            None => self.head.entry(id),
        }
    }

    /// Why file `id` is kept on the Mac, when it is (the full manifest's record once extended).
    #[must_use]
    pub fn kept(&self, id: u32) -> Option<&str> {
        match self.ext.get() {
            Some(ext) => ext.full.kept(ext_index(ext, id)?),
            None => self.head.kept(id),
        }
    }

    /// The id of the folder holding `id` ([`ROOT`] for the folder itself).
    #[must_use]
    pub fn parent(&self, id: u32) -> Option<u32> {
        match self.ext.get() {
            Some(ext) => {
                let parent = ext.full.entry(ext_index(ext, id)?)?.parent;
                ext.id_of(parent)
            }
            None => self.head.entry(id).map(|entry| entry.parent),
        }
    }

    /// The children of folder `id` in name order, with their ids.
    #[must_use]
    pub fn children(&self, id: u32) -> Children<'_> {
        match self.ext.get() {
            Some(ext) => {
                let (first, entries) = match ext_index(ext, id) {
                    Some(index) => ext.full.children(index),
                    None => (0, &[][..]),
                };
                Children { entries, first, at: 0, ext: Some(ext) }
            }
            None => {
                let (first, entries) = self.head.children(id);
                Children { entries, first, at: 0, ext: None }
            }
        }
    }

    /// The child of folder `parent` named `name`.
    #[must_use]
    pub fn lookup(&self, parent: u32, name: &str) -> Option<u32> {
        match self.ext.get() {
            Some(ext) => ext.id_of(ext.full.lookup(ext_index(ext, parent)?, name)?),
            None => self.head.lookup(parent, name),
        }
    }

    /// The id of `path` (relative, `/`-separated; empty for the folder itself).
    #[must_use]
    pub fn resolve(&self, path: &str) -> Option<u32> {
        match self.ext.get() {
            Some(ext) => ext.id_of(ext.full.resolve(path)?),
            None => self.head.resolve(path),
        }
    }

    /// The relative path of `id` (empty for the folder itself).
    #[must_use]
    pub fn path_of(&self, id: u32) -> String {
        match self.ext.get() {
            Some(ext) => {
                ext_index(ext, id).map_or_else(String::new, |index| ext.full.path_of(index))
            }
            None => self.head.path_of(id),
        }
    }
}

/// The full manifest's index of `id`, when an entry has it.
fn ext_index(ext: &Ext, id: u32) -> Option<u32> {
    Some(ext.wire_of(id)).filter(|index| *index != NO_ENTRY)
}

/// The children of a folder with their ids ([`Lower::children`]).
pub struct Children<'a> {
    entries: &'a [Entry],
    first: u32,
    at: usize,
    ext: Option<&'a Arc<Ext>>,
}

impl<'a> Iterator for Children<'a> {
    type Item = (u32, &'a Entry);

    fn next(&mut self) -> Option<Self::Item> {
        let entry = self.entries.get(self.at)?;
        let index = self.first.checked_add(u32::try_from(self.at).ok()?)?;
        self.at += 1;
        let id = match self.ext {
            Some(ext) => ext.id_of(index)?,
            None => index,
        };
        Some((id, entry))
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        let left = self.entries.len().saturating_sub(self.at);
        (left, Some(left))
    }
}

impl ExactSizeIterator for Children<'_> {}
