//! A kept listing brought up to date by a patch instead of sent again (RFD 0065, piece 7).
//!
//! The Mac keeps a change journal of the paths that changed under the folder (an FSEvents
//! watcher), numbered by a sequence. A machine that holds the listing at sequence `from` asks
//! for what changed since ([`crate::wire::Ask::Listing`]); the Mac answers with a [`Patch`] to
//! the sequence it is at now, or says it cannot (the journal no longer reaches back that far, or
//! it never kept one), and the machine takes the whole listing as before. A patch names paths,
//! not entry numbers, so it applies to a listing laid out any way: [`Manifest::patched`] makes
//! the new listing, and [`Patch::paths`] names what a mount must drop from the kernel's cache.
//! One day of commits in cmux is a 244 KB patch against a 1.98 MB listing (RFD 0065).

use std::collections::BTreeMap;
use std::io::Read as _;

use serde::{Deserialize, Serialize};

use crate::manifest::{Item, Kind, Manifest, ROOT};

/// The most changes a patch decodes to (a decode refuses more); a Mac past it sends the listing.
pub const MAX_CHANGES: usize = 4_000_000;
const MAX_DECODED_BYTES: u64 = 1024 * 1024 * 1024;

/// One path's new state.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Change {
    /// The path now has this stat (a new path, or a changed one); a folder's own children are
    /// their own changes.
    Put {
        path: String,
        kind: Kind,
        mode: u32,
        size: u64,
        mtime_ns: i64,
        link: Option<String>,
        /// SHA-256 of a file's bytes, when the Mac has hashed it.
        hash: Option<[u8; 32]>,
        /// Why a file is kept on the Mac ([`Manifest::keep_home`]).
        kept: Option<String>,
    },
    /// The path is gone, with everything below it.
    Remove { path: String },
}

impl Change {
    #[must_use]
    pub fn path(&self) -> &str {
        match self {
            Self::Put { path, .. } | Self::Remove { path } => path,
        }
    }
}

/// What changed in a folder's listing between two points of the Mac's journal.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Patch {
    /// The journal sequence the listing it applies to is at.
    pub from: u64,
    /// The sequence the patched listing is at.
    pub to: u64,
    pub changes: Vec<Change>,
}

impl Patch {
    /// The paths the patch touches.
    pub fn paths(&self) -> impl Iterator<Item = &str> {
        self.changes.iter().map(Change::path)
    }

    /// The patch as the wire carries it (bincode, then zstd).
    pub fn encode(&self) -> anyhow::Result<Vec<u8>> {
        Ok(zstd::encode_all(bincode::serialize(self)?.as_slice(), 3)?)
    }

    /// A patch from [`Patch::encode`]'s bytes, checked.
    pub fn decode(bytes: &[u8]) -> anyhow::Result<Self> {
        let mut raw = Vec::new();
        zstd::Decoder::new(bytes)?.take(MAX_DECODED_BYTES + 1).read_to_end(&mut raw)?;
        anyhow::ensure!(raw.len() as u64 <= MAX_DECODED_BYTES, "the patch is too large");
        let patch: Self = bincode::deserialize(&raw)?;
        anyhow::ensure!(patch.changes.len() <= MAX_CHANGES, "more than {MAX_CHANGES} changes");
        anyhow::ensure!(patch.to >= patch.from, "the patch goes back");
        Ok(patch)
    }
}

impl Manifest {
    /// The patch that takes the listing `self` (at journal sequence `from`) to the one `newer`
    /// (at `to`) is, by comparing them: a path in `newer` that `self` lacks or lists differently
    /// is a put, and a path only `self` has is a remove (of the topmost one gone). The Mac's
    /// journal gives [`Manifest::patch_for`] the paths instead, with no comparison.
    #[must_use]
    pub fn diff(&self, newer: &Manifest, from: u64, to: u64) -> Patch {
        let old = self.by_path();
        let new = newer.by_path();
        let mut changes = Vec::new();
        for (path, now) in &new {
            if old.get(path) != Some(now) {
                changes.push(put(newer, path));
            }
        }
        for path in old.keys().filter(|path| !new.contains_key(*path)) {
            let above_gone =
                path.rsplit_once('/').is_some_and(|(parent, _)| !new.contains_key(parent));
            if !above_gone {
                changes.push(Change::Remove { path: path.clone() });
            }
        }
        Patch { from, to, changes }
    }

    /// The patch for the journal's `paths`, from this (current) listing: a path it lists is a
    /// put, one it does not is a remove.
    #[must_use]
    pub fn patch_for(&self, paths: &[String], from: u64, to: u64) -> Patch {
        let changes = paths
            .iter()
            .filter(|path| !path.is_empty())
            .map(|path| match self.resolve(path) {
                Some(_) => put(self, path),
                None => Change::Remove { path: path.clone() },
            })
            .collect();
        Patch { from, to, changes }
    }

    /// The listing with `patch` applied. Refuses a bad path, and a put below a file.
    pub fn patched(&self, patch: &Patch) -> anyhow::Result<Manifest> {
        let mut items: BTreeMap<String, Item> = BTreeMap::new();
        let mut hashes: BTreeMap<String, [u8; 32]> = BTreeMap::new();
        let mut kept: BTreeMap<String, String> = BTreeMap::new();
        for index in 1..u32::try_from(self.len())? {
            let (Some(entry), path) = (self.entry(index), self.path_of(index)) else { continue };
            if let Some(hash) = self.hash(index) {
                hashes.insert(path.clone(), *hash);
            }
            if let Some(why) = self.kept(index) {
                kept.insert(path.clone(), why.to_owned());
            }
            items.insert(
                path.clone(),
                Item {
                    path,
                    kind: entry.kind,
                    mode: entry.mode,
                    size: entry.size,
                    mtime_ns: entry.mtime_ns,
                    link: entry.link.clone(),
                },
            );
        }
        for change in &patch.changes {
            match change {
                Change::Remove { path } => remove_tree(&mut items, path),
                Change::Put { path, kind, mode, size, mtime_ns, link, hash, kept: why } => {
                    if *kind != Kind::Dir {
                        remove_below(&mut items, path);
                    }
                    items.insert(
                        path.clone(),
                        Item {
                            path: path.clone(),
                            kind: *kind,
                            mode: *mode,
                            size: *size,
                            mtime_ns: *mtime_ns,
                            link: link.clone(),
                        },
                    );
                    match hash {
                        Some(hash) => hashes.insert(path.clone(), *hash),
                        None => hashes.remove(path),
                    };
                    match why {
                        Some(why) => kept.insert(path.clone(), why.clone()),
                        None => kept.remove(path),
                    };
                }
            }
        }
        let root = self.entry(ROOT).map_or(0, |root| root.mtime_ns);
        let mut next = Manifest::build(root, items.into_values().collect())?;
        for (path, hash) in hashes {
            if let Some(index) = next
                .resolve(&path)
                .filter(|index| next.entry(*index).is_some_and(|entry| entry.kind == Kind::File))
            {
                next.set_hash(index, hash)?;
            }
        }
        for (path, why) in kept {
            if let Some(index) = next
                .resolve(&path)
                .filter(|index| next.entry(*index).is_some_and(|entry| entry.kind == Kind::File))
            {
                next.keep_home(index, &why)?;
            }
        }
        Ok(next)
    }

    fn by_path(
        &self,
    ) -> BTreeMap<String, (Kind, u32, u64, i64, Option<&str>, Option<[u8; 32]>, Option<&str>)> {
        (1..self.len() as u32)
            .filter_map(|index| {
                let entry = self.entry(index)?;
                Some((
                    self.path_of(index),
                    (
                        entry.kind,
                        entry.mode,
                        entry.size,
                        entry.mtime_ns,
                        entry.link.as_deref(),
                        self.hash(index).copied(),
                        self.kept(index),
                    ),
                ))
            })
            .collect()
    }
}

fn put(listing: &Manifest, path: &str) -> Change {
    let index = listing.resolve(path);
    let entry = index.and_then(|index| listing.entry(index));
    Change::Put {
        path: path.to_owned(),
        kind: entry.map_or(Kind::Dir, |entry| entry.kind),
        mode: entry.map_or(0o755, |entry| entry.mode),
        size: entry.map_or(0, |entry| entry.size),
        mtime_ns: entry.map_or(0, |entry| entry.mtime_ns),
        link: entry.and_then(|entry| entry.link.clone()),
        hash: index.and_then(|index| listing.hash(index).copied()),
        kept: index.and_then(|index| listing.kept(index)).map(str::to_owned),
    }
}

fn remove_below(items: &mut BTreeMap<String, Item>, path: &str) {
    let prefix = format!("{path}/");
    items.retain(|key, _| !key.starts_with(&prefix));
}

fn remove_tree(items: &mut BTreeMap<String, Item>, path: &str) {
    items.remove(path);
    remove_below(items, path);
}

#[cfg(test)]
#[path = "listing_patch_tests.rs"]
mod tests;
