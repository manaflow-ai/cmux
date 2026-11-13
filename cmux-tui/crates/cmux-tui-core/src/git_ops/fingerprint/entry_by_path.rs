//! One entry of a work tree, where the system has no call that reads a name
//! through an open folder. Each folder above the entry is looked at, by its
//! path, at each entry: a link, a file or nothing in a folder's place gives
//! no entry. A folder that becomes a link between that look and the read is
//! not seen here; `entry.rs` has the form that closes it.

use std::fs::{File, Metadata};
use std::marker::PhantomData;
use std::path::{Component, Path, PathBuf};

/// Folders above one entry; a path with more has no entry.
const MAX_DEPTH: usize = 128;

/// What the system says of an entry or of an open file.
pub(super) type Stat = Metadata;

/// A work tree, as its top folder.
pub(super) struct Tree {
    root: PathBuf,
}

/// A path under the work tree's top folder.
pub(super) struct Entry<'a> {
    path: PathBuf,
    tree: PhantomData<&'a Tree>,
}

impl Tree {
    /// The work tree at `root`, the folder that the caller names.
    pub(super) fn open(root: &Path) -> Option<Self> {
        root.is_dir().then(|| Self { root: root.to_path_buf() })
    }

    /// The entry that `relative` names, a path of the listing; `None` when a
    /// folder above it is not a real folder.
    pub(super) fn entry(&mut self, relative: &Path) -> Option<Entry<'_>> {
        let mut parts = Vec::new();
        for component in relative.components() {
            let Component::Normal(part) = component else { return None };
            parts.push(part);
        }
        let name = parts.pop()?;
        if parts.len() > MAX_DEPTH {
            return None;
        }
        let mut path = self.root.clone();
        for part in parts {
            path.push(part);
            if !std::fs::symlink_metadata(&path).is_ok_and(|folder| folder.file_type().is_dir()) {
                return None;
            }
        }
        path.push(name);
        Some(Entry { path, tree: PhantomData })
    }
}

impl Entry<'_> {
    /// What the system says of the entry itself: a link is not followed.
    pub(super) fn stat(&self) -> Option<Stat> {
        std::fs::symlink_metadata(&self.path).ok()
    }

    /// The target text of the entry, a link.
    pub(super) fn link_target(&self) -> Option<Vec<u8>> {
        let target = std::fs::read_link(&self.path).ok()?;
        Some(target.as_os_str().as_encoded_bytes().to_vec())
    }

    /// The entry, open for a read.
    pub(super) fn open(&self) -> Option<File> {
        File::open(&self.path).ok()
    }
}

/// What the system says of an open file.
pub(super) fn stat_of(file: &File) -> Option<Stat> {
    file.metadata().ok()
}
