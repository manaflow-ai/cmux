//! The manifest of a projected folder: every path the Mac shares, with its kind, permission bits,
//! size, modification time and link text, and no bytes. Nothing is read or hashed to make one.
//!
//! The entries are laid out breadth-first from the folder itself (entry 0), so the children of a
//! folder are contiguous and sorted by name: a lookup is a binary search, a listing a slice. The
//! machine answers every `stat`, `readdir` and `readlink` from it without asking the Mac.
//!
//! What goes in is decided by the Mac (the copy's own rules, `sync_cli/local.rs`): a path that is
//! not in the manifest can never be asked for. A file git tracks but those rules keep on the Mac
//! (a committed test key below a folder of repositories) is listed with its real stat and no
//! bytes, [`Manifest::keep_home`] naming why: the machine refuses to open it (`EACCES`), so
//! `git status` there sees it unchanged, not deleted, and no byte of it ever leaves the Mac (RFD
//! 0007, "Tracked files the skip rules keep home").

use std::collections::{BTreeMap, VecDeque};
use std::io::Read as _;

use serde::{Deserialize, Serialize};

/// The index of the folder itself.
pub const ROOT: u32 = 0;

/// The most entries a manifest holds (a decode refuses more).
pub const MAX_ENTRIES: usize = 20_000_000;
/// The most bytes a manifest decodes to (a decode refuses more).
const MAX_DECODED_BYTES: u64 = 4 * 1024 * 1024 * 1024;
/// The longest name the manifest takes (Linux's own limit).
const MAX_NAME_BYTES: usize = 255;
/// The longest reason a file kept on the Mac carries.
pub const MAX_REASON_BYTES: usize = 512;

/// What an entry is.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Kind {
    File,
    Dir,
    Link,
}

/// One path of the folder.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Entry {
    /// The last component (empty for the folder itself).
    pub name: String,
    /// The folder holding it ([`ROOT`] for the folder itself).
    pub parent: u32,
    pub kind: Kind,
    /// Permission bits (`0o7777` at most).
    pub mode: u32,
    /// Bytes of a file; 0 for a folder; the link text's length for a link.
    pub size: u64,
    /// Modification time, nanoseconds since the epoch.
    pub mtime_ns: i64,
    /// The first child of a folder (an index), and how many it has.
    pub first_child: u32,
    pub children: u32,
    /// A link's text.
    pub link: Option<String>,
}

/// One path as the Mac lists it, for [`Manifest::build`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Item {
    /// Relative to the folder, `/`-separated, with no `.`, `..` or empty component.
    pub path: String,
    pub kind: Kind,
    pub mode: u32,
    pub size: u64,
    pub mtime_ns: i64,
    pub link: Option<String>,
}

/// A folder's manifest.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Manifest {
    entries: Vec<Entry>,
    /// Files listed with their stat but kept on the Mac, by entry, with why. Last on the wire:
    /// a machine from before it reads the entries and leaves the rest, and the Mac refuses their
    /// bytes either way.
    kept: BTreeMap<u32, String>,
}

#[derive(Default)]
struct Node {
    kind: Option<Kind>,
    mode: u32,
    size: u64,
    mtime_ns: i64,
    link: Option<String>,
    children: BTreeMap<String, Node>,
}

impl Manifest {
    /// The manifest of `items`. A folder above an item that is not itself listed is added (mode
    /// 0755, the folder's own `root_mtime_ns`). Refuses a bad path, a path listed twice, and an
    /// item below a file or a link.
    pub fn build(root_mtime_ns: i64, items: Vec<Item>) -> anyhow::Result<Self> {
        let mut root =
            Node { kind: Some(Kind::Dir), mode: 0o755, mtime_ns: root_mtime_ns, ..Node::default() };
        for item in items {
            let names = split(&item.path)?;
            let (last, above) = names.split_last().ok_or_else(|| anyhow::anyhow!("empty path"))?;
            let mut at = &mut root;
            for name in above {
                anyhow::ensure!(
                    matches!(at.kind, None | Some(Kind::Dir)),
                    "{} is below a file",
                    item.path
                );
                at = at.children.entry((*name).to_owned()).or_insert_with(|| Node {
                    mode: 0o755,
                    mtime_ns: root_mtime_ns,
                    ..Node::default()
                });
            }
            anyhow::ensure!(
                matches!(at.kind, None | Some(Kind::Dir)),
                "{} is below a file",
                item.path
            );
            let node = at.children.entry((*last).to_owned()).or_default();
            anyhow::ensure!(
                node.kind.is_none() || (node.kind == Some(Kind::Dir) && item.kind == Kind::Dir),
                "{} is listed twice",
                item.path
            );
            anyhow::ensure!(
                item.kind == Kind::Dir || node.children.is_empty(),
                "{} has paths below it but is not a folder",
                item.path
            );
            node.kind = Some(item.kind);
            node.mode = item.mode & 0o7777;
            node.size = match item.kind {
                Kind::File => item.size,
                Kind::Dir => 0,
                Kind::Link => item.link.as_ref().map_or(0, |text| text.len() as u64),
            };
            node.mtime_ns = item.mtime_ns;
            node.link = if item.kind == Kind::Link { item.link } else { None };
        }
        let mut entries = Vec::new();
        let mut queue: VecDeque<(u32, BTreeMap<String, Node>)> = VecDeque::new();
        let children = std::mem::take(&mut root.children);
        entries.push(entry(String::new(), ROOT, root));
        queue.push_back((ROOT, children));
        while let Some((index, children)) = queue.pop_front() {
            let first = u32::try_from(entries.len())?;
            let count = u32::try_from(children.len())?;
            if let Some(folder) = entries.get_mut(index as usize) {
                folder.first_child = first;
                folder.children = count;
            }
            for (name, mut node) in children {
                let at = u32::try_from(entries.len())?;
                let below = std::mem::take(&mut node.children);
                let dir = node.kind.unwrap_or(Kind::Dir) == Kind::Dir;
                entries.push(entry(name, index, node));
                if dir {
                    queue.push_back((at, below));
                }
            }
        }
        anyhow::ensure!(entries.len() <= MAX_ENTRIES, "more than {MAX_ENTRIES} paths");
        Ok(Self { entries, kept: BTreeMap::new() })
    }

    /// Marks file `index` as kept on the Mac for `reason`: listed with its stat, its bytes never
    /// asked for, an open of it refused (`EACCES`) with `reason` named.
    pub fn keep_home(&mut self, index: u32, reason: &str) -> anyhow::Result<()> {
        anyhow::ensure!(
            self.entry(index).is_some_and(|entry| entry.kind == Kind::File),
            "entry {index} is not a file"
        );
        anyhow::ensure!(!reason.is_empty(), "a file kept on the Mac needs a reason");
        anyhow::ensure!(
            reason.len() <= MAX_REASON_BYTES,
            "a reason is longer than {MAX_REASON_BYTES} bytes"
        );
        self.kept.insert(index, reason.to_owned());
        Ok(())
    }

    /// Why file `index` is kept on the Mac, when it is.
    #[must_use]
    pub fn kept(&self, index: u32) -> Option<&str> {
        self.kept.get(&index).map(String::as_str)
    }

    /// How many files are kept on the Mac.
    #[must_use]
    pub fn kept_count(&self) -> usize {
        self.kept.len()
    }

    /// How many entries, the folder itself included.
    #[must_use]
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// Whether it holds nothing at all (never true of a built or decoded manifest).
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// The entry at `index`.
    #[must_use]
    pub fn entry(&self, index: u32) -> Option<&Entry> {
        self.entries.get(index as usize)
    }

    /// The children of the folder at `index` (none for anything else), in name order, with the
    /// index of the first.
    #[must_use]
    pub fn children(&self, index: u32) -> (u32, &[Entry]) {
        let Some(folder) = self.entry(index).filter(|entry| entry.kind == Kind::Dir) else {
            return (0, &[]);
        };
        let start = folder.first_child as usize;
        let end = start + folder.children as usize;
        (folder.first_child, self.entries.get(start..end).unwrap_or(&[]))
    }

    /// The child of folder `parent` named `name`.
    #[must_use]
    pub fn lookup(&self, parent: u32, name: &str) -> Option<u32> {
        let (first, children) = self.children(parent);
        let at = children.binary_search_by(|entry| entry.name.as_str().cmp(name)).ok()?;
        first.checked_add(u32::try_from(at).ok()?)
    }

    /// The entry at `path` (relative, `/`-separated; empty for the folder itself).
    #[must_use]
    pub fn resolve(&self, path: &str) -> Option<u32> {
        let mut at = ROOT;
        for name in path.split('/').filter(|name| !name.is_empty() && *name != ".") {
            at = self.lookup(at, name)?;
        }
        Some(at)
    }

    /// The relative path of `index` (empty for the folder itself).
    #[must_use]
    pub fn path_of(&self, index: u32) -> String {
        let mut names = Vec::new();
        let mut at = index;
        while at != ROOT {
            let Some(entry) = self.entry(at) else { break };
            names.push(entry.name.as_str());
            at = entry.parent;
        }
        names.reverse();
        names.join("/")
    }

    /// Files and their total bytes.
    #[must_use]
    pub fn totals(&self) -> (u64, u64) {
        self.entries
            .iter()
            .filter(|entry| entry.kind == Kind::File)
            .fold((0, 0), |(files, bytes), entry| (files + 1, bytes + entry.size))
    }

    /// The manifest as the wire carries it (bincode, then zstd).
    pub fn encode(&self) -> anyhow::Result<Vec<u8>> {
        let raw = bincode::serialize(self)?;
        Ok(zstd::encode_all(raw.as_slice(), 3)?)
    }

    /// A manifest from [`Manifest::encode`]'s bytes, checked: every parent and child range is in
    /// bounds and agrees, every name is one component, and a folder's children are sorted.
    pub fn decode(bytes: &[u8]) -> anyhow::Result<Self> {
        let mut raw = Vec::new();
        zstd::Decoder::new(bytes)?.take(MAX_DECODED_BYTES + 1).read_to_end(&mut raw)?;
        anyhow::ensure!(raw.len() as u64 <= MAX_DECODED_BYTES, "the manifest is too large");
        // A Mac from before [`Manifest::keep_home`] sends the entries alone.
        let manifest: Self = match bincode::deserialize(&raw) {
            Ok(manifest) => manifest,
            Err(error) => bincode::deserialize::<Vec<Entry>>(&raw)
                .map(|entries| Self { entries, kept: BTreeMap::new() })
                .map_err(|_| error)?,
        };
        manifest.check()?;
        Ok(manifest)
    }

    /// Every entry, in layout order.
    pub(crate) fn entries(&self) -> &[Entry] {
        &self.entries
    }

    /// A manifest of `entries` already laid out as [`Manifest::build`] lays them, checked as a
    /// decode checks them.
    pub(crate) fn from_entries(entries: Vec<Entry>) -> anyhow::Result<Self> {
        let manifest = Self { entries, kept: BTreeMap::new() };
        manifest.check()?;
        Ok(manifest)
    }

    fn check(&self) -> anyhow::Result<()> {
        anyhow::ensure!(!self.entries.is_empty(), "the manifest has no folder");
        anyhow::ensure!(self.entries.len() <= MAX_ENTRIES, "more than {MAX_ENTRIES} paths");
        let root =
            self.entries.first().ok_or_else(|| anyhow::anyhow!("the manifest has no folder"))?;
        anyhow::ensure!(
            root.kind == Kind::Dir && root.name.is_empty(),
            "entry 0 is not the folder"
        );
        let mut seen = vec![false; self.entries.len()];
        if let Some(first) = seen.first_mut() {
            *first = true;
        }
        for (index, entry) in self.entries.iter().enumerate() {
            if index != 0 {
                anyhow::ensure!(seen.get(index) == Some(&true), "entry {index} has no folder");
                check_name(&entry.name)?;
            }
            if entry.kind != Kind::Dir {
                anyhow::ensure!(entry.children == 0, "entry {index} is not a folder");
                continue;
            }
            let start = entry.first_child as usize;
            let end = start
                .checked_add(entry.children as usize)
                .filter(|end| *end <= self.entries.len())
                .ok_or_else(|| anyhow::anyhow!("entry {index}'s children are out of range"))?;
            anyhow::ensure!(entry.children == 0 || start > index, "entry {index} loops");
            let mut before: Option<&Entry> = None;
            for ((child, seen), node) in seen
                .iter_mut()
                .enumerate()
                .take(end)
                .skip(start)
                .zip(self.entries.iter().take(end).skip(start))
            {
                anyhow::ensure!(!*seen, "entry {child} has two folders");
                *seen = true;
                anyhow::ensure!(node.parent as usize == index, "entry {child}'s folder disagrees");
                if let Some(before) = before {
                    anyhow::ensure!(
                        before.name < node.name,
                        "entry {index}'s children are not sorted"
                    );
                }
                before = Some(node);
            }
        }
        for (index, reason) in &self.kept {
            anyhow::ensure!(
                self.entry(*index).is_some_and(|entry| entry.kind == Kind::File),
                "kept entry {index} is not a file"
            );
            anyhow::ensure!(
                !reason.is_empty() && reason.len() <= MAX_REASON_BYTES,
                "kept entry {index}'s reason is empty or too long"
            );
        }
        Ok(())
    }
}

fn entry(name: String, parent: u32, node: Node) -> Entry {
    Entry {
        name,
        parent,
        kind: node.kind.unwrap_or(Kind::Dir),
        mode: node.mode,
        size: node.size,
        mtime_ns: node.mtime_ns,
        first_child: 0,
        children: 0,
        link: node.link,
    }
}

fn split(path: &str) -> anyhow::Result<Vec<&str>> {
    let names: Vec<&str> = path.split('/').collect();
    for name in &names {
        check_name(name).map_err(|error| anyhow::anyhow!("{path}: {error}"))?;
    }
    Ok(names)
}

fn check_name(name: &str) -> anyhow::Result<()> {
    anyhow::ensure!(
        !name.is_empty() && name != "." && name != ".." && !name.contains(['/', '\0']),
        "bad name {name:?}"
    );
    anyhow::ensure!(name.len() <= MAX_NAME_BYTES, "name longer than {MAX_NAME_BYTES} bytes");
    Ok(())
}

#[cfg(test)]
#[path = "manifest_tests.rs"]
mod tests;
