//! The lower layer replaced in place by the whole folder's manifest, after a mount that started
//! from a small head (`projection-extend-v1`, [`crate::lower`]).
//!
//! Every number the kernel, an open handle, the cache or a pin holds stays what it was: the ids of
//! the head's paths are not touched, the upper layer and the whiteouts are not read or written,
//! and a path only the full manifest has gets a number from the counter on its first lookup. What
//! the kernel may have cached of a head entry that differs now (a folder that gained children, a
//! file that changed on the Mac) is returned, so the mount can drop it.

use std::collections::HashSet;

use super::{Arc, Kind, Manifest, Overlay};
use crate::lower::{Ext, ExtendError};

/// What [`Overlay::extend`] did.
pub struct Extended {
    /// The extension: the Mac's asks on a stream of the full manifest go through it
    /// ([`crate::link::Link::serve_with`]).
    pub ext: Arc<Ext>,
    /// The numbers of the head's entries that differ in the full manifest: the kernel's cached
    /// attributes of them, their pages, and a folder's listing, are stale.
    pub changed: Vec<u64>,
    /// How many entries the full manifest adds to the head's.
    pub added: usize,
}

impl Overlay {
    /// Makes `full` the lower layer, with every number the same. `full` must hold every path of
    /// the manifest the overlay opened on, as the same kind of entry ([`ExtendError`]); nothing
    /// changes when it does not. Once only.
    pub fn extend(&self, full: Arc<Manifest>) -> Result<Extended, ExtendError> {
        let head_len = self.manifest.head_len();
        let ext = self.manifest.extend(full)?;
        let changed = ext.changed(self.manifest.head());
        // Bytes cached of a file that is not the one the head listed would be served as its own.
        let files: HashSet<u32> = changed
            .iter()
            .copied()
            .filter(|id| self.manifest.head().entry(*id).is_some_and(|e| e.kind == Kind::File))
            .collect();
        if !files.is_empty() {
            self.drop_cached(&files);
        }
        let numbers = {
            let mut inner = self.lock();
            changed
                .iter()
                .map(|id| {
                    let path = self.manifest.head().path_of(*id);
                    self.name_ino(&mut inner, &path)
                })
                .collect()
        };
        Ok(Extended { added: ext.full().len().saturating_sub(head_len), ext, changed: numbers })
    }

    /// Forgets every cached blob of `files`, on disk too.
    fn drop_cached(&self, files: &HashSet<u32>) {
        let mut index = self.cache_lock();
        let keys: Vec<_> = index
            .blobs
            .keys()
            .chain(index.kept.keys())
            .filter(|key| files.contains(&key.0))
            .copied()
            .collect();
        for key in keys {
            index.remove(key);
            let _ = std::fs::remove_file(self.cache_path(key));
        }
    }
}
