//! The manifest: a stat-only description of a folder on the Mac.
//!
//! For each path it holds the kind, mode, size, modification and change times, the link text of a
//! symlink, and the content hash when the Mac already has one. Nothing is read or hashed to make
//! it. Entries are stored parent before child, and the children of a directory are contiguous and
//! sorted by name, so a lookup is a binary search and an entry's index works as an inode number
//! inside one process. The index never leaves the process: requests to the Mac and keys in the
//! chunk cache use the path and the version instead.

mod builder;
mod codec;

use std::fmt;
use std::ops::Range;

pub use builder::Builder;
pub use codec::{FORMAT_VERSION, MAGIC, MAX_DECODED_BYTES};

/// The position of an entry in a [`Manifest`]. The root is [`ROOT`].
pub type Index = u32;

/// The index of the folder's root directory.
pub const ROOT: Index = 0;

/// The longest name one path component may have, in bytes (Linux's `NAME_MAX`).
pub const MAX_NAME: usize = 255;

/// The longest symlink text the manifest accepts, in bytes (Linux's `PATH_MAX`).
pub const MAX_LINK: usize = 4096;

/// What kind of filesystem object an entry is.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Kind {
    File,
    Dir,
    Symlink,
}

/// The version of a file the machine believes it has: its size and its two timestamps.
///
/// The Mac compares this with the file's stat before it answers; any difference is a change.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Version {
    pub size: u64,
    pub mtime_ns: i64,
    pub ctime_ns: i64,
}

/// Everything the manifest knows about one path.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Stat {
    pub kind: Kind,
    /// Permission bits (the low 12 bits of `st_mode`); other bits are ignored.
    pub mode: u32,
    /// Size in bytes. Only meaningful for files.
    pub size: u64,
    /// Modification time in nanoseconds since the Unix epoch.
    pub mtime_ns: i64,
    /// Status change time in nanoseconds since the Unix epoch.
    pub ctime_ns: i64,
    /// The link text of a symlink; `None` for anything else.
    pub link: Option<String>,
    /// The SHA-256 of a file's bytes, when the Mac already knows it.
    pub hash: Option<[u8; 32]>,
    /// A file listed with its real stat but whose bytes stay on the Mac (for example a tracked
    /// secret the skip rules keep home). Reading it fails with "permission denied".
    pub withheld: bool,
}

impl Stat {
    /// A regular file.
    pub fn file(mode: u32, size: u64, mtime_ns: i64, ctime_ns: i64) -> Stat {
        Stat {
            kind: Kind::File,
            mode,
            size,
            mtime_ns,
            ctime_ns,
            link: None,
            hash: None,
            withheld: false,
        }
    }

    /// A directory.
    pub fn dir(mode: u32, mtime_ns: i64, ctime_ns: i64) -> Stat {
        Stat { kind: Kind::Dir, size: 0, ..Stat::file(mode, 0, mtime_ns, ctime_ns) }
    }

    /// A symlink with the given link text. Its size is the length of the text.
    pub fn symlink(target: &str, mtime_ns: i64, ctime_ns: i64) -> Stat {
        Stat {
            kind: Kind::Symlink,
            size: target.len() as u64,
            link: Some(target.to_owned()),
            ..Stat::file(0o777, 0, mtime_ns, ctime_ns)
        }
    }

    /// The version a fault for this file names.
    pub fn version(&self) -> Version {
        Version { size: self.size, mtime_ns: self.mtime_ns, ctime_ns: self.ctime_ns }
    }

    /// Checks that the fields fit the kind: only a symlink has link text, only a file has a hash
    /// or is withheld.
    pub(crate) fn check(&self) -> Result<(), String> {
        match (&self.kind, &self.link) {
            (Kind::Symlink, None) => return Err("a symlink has no link text".into()),
            (Kind::Symlink, Some(t)) => {
                if t.is_empty() || t.len() > MAX_LINK || t.contains('\0') {
                    return Err("symlink text is empty, too long, or contains NUL".into());
                }
            }
            (_, Some(_)) => return Err("only a symlink has link text".into()),
            (_, None) => {}
        }
        if self.kind != Kind::File && (self.hash.is_some() || self.withheld) {
            return Err("only a file has a hash or is withheld".into());
        }
        Ok(())
    }
}

/// One path in the manifest.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    /// The last path component; empty for the root.
    pub name: String,
    /// The index of the containing directory; the root is its own parent.
    pub parent: Index,
    pub stat: Stat,
    /// The path no longer exists on the Mac (a delta said so, or a fault found it gone).
    pub gone: bool,
    first_child: Index,
    n_children: u32,
}

impl Entry {
    fn new(name: String, parent: Index, stat: Stat) -> Entry {
        Entry { name, parent, stat, gone: false, first_child: 0, n_children: 0 }
    }

    /// The indexes of this entry's children (empty for anything but a directory).
    pub fn children(&self) -> Range<Index> {
        self.first_child..self.first_child + self.n_children
    }
}

/// A change to one path that arrived after the manifest (from the Mac's watcher, or from a fault
/// that found the file changed).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Delta {
    /// The path now has this stat. A file may become a symlink or back, but a directory cannot
    /// become anything else, or the reverse, without a new manifest.
    Stat(Stat),
    /// The path no longer exists. A directory takes its whole subtree with it.
    Gone,
}

/// Why a manifest could not be built, decoded or changed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ManifestError {
    /// The bytes do not start with the manifest magic.
    NotAManifest,
    /// The manifest was written by a newer format than this build reads.
    NewerVersion { found: u16, supported: u16 },
    /// The bytes are truncated, corrupt, or describe an impossible tree.
    Corrupt(String),
    /// A path given to the builder or a delta is not a clean relative path.
    BadPath { path: String, reason: &'static str },
    /// The builder got the same path twice.
    Duplicate(String),
    /// A path's parent is missing or not a directory.
    MissingParent(String),
    /// A delta names a path the manifest does not have.
    NotInManifest(String),
    /// A stat's fields do not fit its kind, or a delta changes what cannot change in place.
    BadStat { path: String, reason: String },
}

impl fmt::Display for ManifestError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ManifestError::NotAManifest => write!(f, "not a projected-folder manifest"),
            ManifestError::NewerVersion { found, supported } => {
                write!(f, "manifest format {found} is newer than this build reads ({supported})")
            }
            ManifestError::Corrupt(why) => write!(f, "corrupt manifest: {why}"),
            ManifestError::BadPath { path, reason } => write!(f, "bad path {path:?}: {reason}"),
            ManifestError::Duplicate(path) => write!(f, "path {path:?} is listed twice"),
            ManifestError::MissingParent(path) => {
                write!(f, "the parent of {path:?} is not a directory in the manifest")
            }
            ManifestError::NotInManifest(path) => write!(f, "{path:?} is not in the manifest"),
            ManifestError::BadStat { path, reason } => write!(f, "bad stat for {path:?}: {reason}"),
        }
    }
}

impl std::error::Error for ManifestError {}

/// A folder's stat-only manifest, indexed for lookups.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Manifest {
    root: String,
    entries: Vec<Entry>,
    skipped: u64,
}

impl Manifest {
    /// A label for the folder (for example its path on the Mac). Not used for lookups.
    pub fn root_label(&self) -> &str {
        &self.root
    }

    /// How many paths the Mac's walk left out under its skip rules.
    pub fn skipped(&self) -> u64 {
        self.skipped
    }

    /// The number of entries, the root included.
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// Never true: a manifest always has its root.
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// All entries, parent before child.
    pub fn entries(&self) -> &[Entry] {
        &self.entries
    }

    /// One entry, gone or not.
    pub fn entry(&self, idx: Index) -> Option<&Entry> {
        self.entries.get(idx as usize)
    }

    /// The indexes of a directory's children, gone ones included.
    pub fn children(&self, idx: Index) -> Range<Index> {
        self.entry(idx).map_or(0..0, Entry::children)
    }

    /// The child of `parent` called `name`, unless it is gone.
    pub fn lookup(&self, parent: Index, name: &str) -> Option<Index> {
        self.find_child(parent, name).filter(|&i| !self.entries[i as usize].gone)
    }

    fn find_child(&self, parent: Index, name: &str) -> Option<Index> {
        let range = self.children(parent);
        let slice = self.entries.get(range.start as usize..range.end as usize)?;
        slice.binary_search_by(|e| e.name.as_str().cmp(name)).ok().map(|i| range.start + i as Index)
    }

    /// The entry at a relative path (`""` is the root), unless it or a parent is gone.
    pub fn resolve(&self, path: &str) -> Option<Index> {
        let parts = split_path(path).ok()?;
        let mut idx = ROOT;
        for part in parts {
            idx = self.lookup(idx, part)?;
        }
        Some(idx)
    }

    fn resolve_including_gone(&self, path: &str) -> Result<Index, ManifestError> {
        let parts = split_path(path)?;
        let mut idx = ROOT;
        for part in parts {
            idx = self
                .find_child(idx, part)
                .ok_or_else(|| ManifestError::NotInManifest(path.to_owned()))?;
        }
        Ok(idx)
    }

    /// The relative path of an entry, components joined with `/` (`""` for the root).
    pub fn path_of(&self, idx: Index) -> Option<String> {
        let mut parts = Vec::new();
        let mut cur = idx;
        while cur != ROOT {
            let e = self.entry(cur)?;
            parts.push(e.name.as_str());
            cur = e.parent;
        }
        parts.reverse();
        Some(parts.join("/"))
    }

    /// The total size of the files that are not gone.
    pub fn total_bytes(&self) -> u64 {
        self.entries
            .iter()
            .filter(|e| e.stat.kind == Kind::File && !e.gone)
            .map(|e| e.stat.size)
            .sum()
    }

    /// Applies one change to one path. Returns the entry's index when anything changed, or
    /// `None` when the manifest already said so. New paths need a new manifest.
    pub fn apply_delta(
        &mut self,
        path: &str,
        delta: Delta,
    ) -> Result<Option<Index>, ManifestError> {
        let idx = self.resolve_including_gone(path)?;
        match delta {
            Delta::Gone => {
                if idx == ROOT {
                    return Err(ManifestError::BadPath {
                        path: path.to_owned(),
                        reason: "the root cannot be gone",
                    });
                }
                if self.entries[idx as usize].gone {
                    return Ok(None);
                }
                self.mark_gone(idx);
                Ok(Some(idx))
            }
            Delta::Stat(stat) => self.replace_stat(path, idx, stat),
        }
    }

    fn replace_stat(
        &mut self,
        path: &str,
        idx: Index,
        stat: Stat,
    ) -> Result<Option<Index>, ManifestError> {
        let bad = |reason: String| ManifestError::BadStat { path: path.to_owned(), reason };
        stat.check().map_err(bad)?;
        let parent = self.entries[idx as usize].parent;
        if idx != ROOT && self.entries[parent as usize].gone {
            return Err(ManifestError::MissingParent(path.to_owned()));
        }
        let e = &mut self.entries[idx as usize];
        if (e.stat.kind == Kind::Dir) != (stat.kind == Kind::Dir) {
            return Err(
                bad("a directory and a non-directory swap only with a new manifest".into()),
            );
        }
        if e.stat == stat && !e.gone {
            return Ok(None);
        }
        e.stat = stat;
        e.gone = false;
        Ok(Some(idx))
    }

    fn mark_gone(&mut self, idx: Index) {
        let mut stack = vec![idx];
        while let Some(i) = stack.pop() {
            let e = &mut self.entries[i as usize];
            e.gone = true;
            stack.extend(e.children());
        }
    }
}

/// Splits a clean relative path into its components. `""` is the root.
pub(crate) fn split_path(path: &str) -> Result<Vec<&str>, ManifestError> {
    let bad = |reason| ManifestError::BadPath { path: path.to_owned(), reason };
    if path.is_empty() {
        return Ok(Vec::new());
    }
    if path.starts_with('/') {
        return Err(bad("absolute paths are not allowed"));
    }
    path.split('/').map(|part| check_name(part).map(|()| part).map_err(bad)).collect()
}

/// Checks one path component.
pub(crate) fn check_name(name: &str) -> Result<(), &'static str> {
    if name.is_empty() {
        return Err("empty path component");
    }
    if name == "." || name == ".." {
        return Err("`.` and `..` are not allowed");
    }
    if name.contains('\0') {
        return Err("NUL in a name");
    }
    if name.contains('/') {
        return Err("`/` in a name");
    }
    if name.len() > MAX_NAME {
        return Err("name longer than 255 bytes");
    }
    Ok(())
}
