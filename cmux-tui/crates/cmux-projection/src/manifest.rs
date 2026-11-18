//! The manifest of a projected folder: every path the Mac shares, with its kind, permission bits,
//! size, modification time and link text, and no bytes. Nothing is read or hashed to make one.
//!
//! The entries are laid out breadth-first from the folder itself (entry 0), so the children of a
//! folder are contiguous and sorted by name: a lookup is a binary search, a listing a slice. The
//! machine answers every `stat`, `readdir` and `readlink` from it without asking the Mac.
//!
//! What goes in is decided by the Mac (the copy's own rules, `sync_cli/local.rs`): a path that is
//! not in the manifest can never be asked for.

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
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
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
            insert(&mut root, item, root_mtime_ns)?;
        }
        Self::from_tree(root)
    }

    /// The manifest of the tree `root` (the folder itself), laid out breadth first.
    fn from_tree(mut root: Node) -> anyhow::Result<Self> {
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
        Ok(Self { entries })
    }

    /// The manifest as a tree again, for [`Manifest::apply`].
    fn to_tree(&self) -> Node {
        fn below(manifest: &Manifest, index: u32) -> Node {
            let Some(entry) = manifest.entry(index) else {
                return Node::default();
            };
            let (first, children) = manifest.children(index);
            let mut node = Node {
                kind: Some(entry.kind),
                mode: entry.mode,
                size: entry.size,
                mtime_ns: entry.mtime_ns,
                link: entry.link.clone(),
                children: BTreeMap::new(),
            };
            for (at, child) in children.iter().enumerate() {
                let at = first.saturating_add(u32::try_from(at).unwrap_or(u32::MAX));
                node.children.insert(child.name.clone(), below(manifest, at));
            }
            node
        }
        below(self, ROOT)
    }

    /// Which manifest this is: FNV-1a of its bincode (the machine's cache and a delta's base and
    /// target go by it).
    pub fn id(&self) -> anyhow::Result<u64> {
        Ok(fnv(&bincode::serialize(self)?))
    }

    /// What turns `base` into `new`, for a Mac that sent `base` to the machine before: the paths
    /// gone and the files and links added or changed. Both must come from a Mac's listing (every
    /// folder implied by what is in it, 0755 at the folder's own time), as [`Manifest::apply`]
    /// lays folders out that way.
    #[must_use]
    pub fn delta(base: &Self, new: &Self) -> Delta {
        let mut delta = Delta {
            root_mtime_ns: new.entries.first().map_or(0, |root| root.mtime_ns),
            removed: Vec::new(),
            upserts: Vec::new(),
        };
        diff(base, ROOT, new, ROOT, "", &mut delta);
        delta
    }

    /// `delta` applied to `self` (its base): the new manifest, which the caller checks against the
    /// id the Mac sent.
    pub fn apply(&self, delta: &Delta) -> anyhow::Result<Self> {
        let mut root = self.to_tree();
        for path in &delta.removed {
            remove(&mut root, &split(path)?);
        }
        for item in &delta.upserts {
            remove(&mut root, &split(&item.path)?);
            insert(&mut root, item.clone(), delta.root_mtime_ns)?;
        }
        folders_at(&mut root, delta.root_mtime_ns);
        root.mode = 0o755;
        Self::from_tree(root)
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
        let manifest: Self = bincode::deserialize(&raw)?;
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
        Ok(())
    }
}

/// What a Mac sends instead of a whole manifest the machine has seen the base of
/// ([`Manifest::delta`]).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Delta {
    /// The folder's own modification time (every folder's, as the Mac lists them).
    pub root_mtime_ns: i64,
    /// Paths gone, each a file, a link or a whole folder.
    pub removed: Vec<String>,
    /// Files and links added or changed.
    pub upserts: Vec<Item>,
}

impl Delta {
    /// As the wire carries it (bincode, then zstd).
    pub fn encode(&self) -> anyhow::Result<Vec<u8>> {
        Ok(zstd::encode_all(bincode::serialize(self)?.as_slice(), 3)?)
    }

    pub fn decode(bytes: &[u8]) -> anyhow::Result<Self> {
        let mut raw = Vec::new();
        zstd::Decoder::new(bytes)?.take(MAX_DECODED_BYTES + 1).read_to_end(&mut raw)?;
        anyhow::ensure!(raw.len() as u64 <= MAX_DECODED_BYTES, "the delta is too large");
        Ok(bincode::deserialize(&raw)?)
    }

    /// How many paths it names.
    #[must_use]
    pub fn len(&self) -> usize {
        self.removed.len() + self.upserts.len()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

/// Adds `item` to the tree `root`, with any folder above it that is missing (0755, at
/// `root_mtime_ns`).
fn insert(root: &mut Node, item: Item, root_mtime_ns: i64) -> anyhow::Result<()> {
    let names = split(&item.path)?;
    let (last, above) = names.split_last().ok_or_else(|| anyhow::anyhow!("empty path"))?;
    let mut at = root;
    for name in above {
        anyhow::ensure!(matches!(at.kind, None | Some(Kind::Dir)), "{} is below a file", item.path);
        at = at.children.entry((*name).to_owned()).or_insert_with(|| Node {
            mode: 0o755,
            mtime_ns: root_mtime_ns,
            ..Node::default()
        });
    }
    anyhow::ensure!(matches!(at.kind, None | Some(Kind::Dir)), "{} is below a file", item.path);
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
    Ok(())
}

/// Removes the path `names` from the tree, and each folder above it left empty (a Mac lists no
/// empty folder).
fn remove(root: &mut Node, names: &[&str]) {
    let Some((first, rest)) = names.split_first() else { return };
    if rest.is_empty() {
        root.children.remove(*first);
        return;
    }
    let Some(child) = root.children.get_mut(*first) else { return };
    remove(child, rest);
    if child.children.is_empty() && matches!(child.kind, None | Some(Kind::Dir)) {
        root.children.remove(*first);
    }
}

/// Every folder of the tree at `mtime_ns`, 0755, as a Mac's listing makes them.
fn folders_at(node: &mut Node, mtime_ns: i64) {
    if matches!(node.kind, None | Some(Kind::Dir)) {
        node.mtime_ns = mtime_ns;
        node.mode = 0o755;
        node.size = 0;
    }
    for child in node.children.values_mut() {
        folders_at(child, mtime_ns);
    }
}

/// [`Manifest::delta`] of folder `at` of `base` against folder `now` of `new`, both at `path`.
fn diff(base: &Manifest, at: u32, new: &Manifest, now: u32, path: &str, delta: &mut Delta) {
    let (base_first, before) = base.children(at);
    let (new_first, after) = new.children(now);
    let (mut b, mut n) = (0usize, 0usize);
    let index =
        |first: u32, offset: usize| first.saturating_add(u32::try_from(offset).unwrap_or(u32::MAX));
    loop {
        let (old, fresh) = (before.get(b), after.get(n));
        let order = match (old, fresh) {
            (Some(old), Some(fresh)) => old.name.cmp(&fresh.name),
            (Some(_), None) => std::cmp::Ordering::Less,
            (None, Some(_)) => std::cmp::Ordering::Greater,
            (None, None) => break,
        };
        match (order, old, fresh) {
            (std::cmp::Ordering::Less, Some(old), _) => {
                delta.removed.push(join(path, &old.name));
                b += 1;
            }
            (std::cmp::Ordering::Greater, _, Some(fresh)) => {
                everything(new, index(new_first, n), &join(path, &fresh.name), delta);
                n += 1;
            }
            (_, Some(old), Some(fresh)) => {
                let here = join(path, &fresh.name);
                match (old.kind, fresh.kind) {
                    (Kind::Dir, Kind::Dir) => {
                        diff(base, index(base_first, b), new, index(new_first, n), &here, delta);
                    }
                    (Kind::Dir, _) | (_, Kind::Dir) => {
                        delta.removed.push(here.clone());
                        everything(new, index(new_first, n), &here, delta);
                    }
                    _ if old.mode != fresh.mode
                        || old.size != fresh.size
                        || old.mtime_ns != fresh.mtime_ns
                        || old.kind != fresh.kind
                        || old.link != fresh.link =>
                    {
                        delta.upserts.push(item_of(fresh, here));
                    }
                    _ => {}
                }
                b += 1;
                n += 1;
            }
            // `order` came from these two, so nothing else is left.
            _ => break,
        }
    }
}

/// Every file and link at and below entry `index` of `manifest` (at `path`) as upserts.
fn everything(manifest: &Manifest, index: u32, path: &str, delta: &mut Delta) {
    let Some(entry) = manifest.entry(index) else { return };
    if entry.kind != Kind::Dir {
        delta.upserts.push(item_of(entry, path.to_owned()));
        return;
    }
    let (first, children) = manifest.children(index);
    for (at, child) in children.iter().enumerate() {
        let at = first.saturating_add(u32::try_from(at).unwrap_or(u32::MAX));
        everything(manifest, at, &join(path, &child.name), delta);
    }
}

fn item_of(entry: &Entry, path: String) -> Item {
    Item {
        path,
        kind: entry.kind,
        mode: entry.mode,
        size: entry.size,
        mtime_ns: entry.mtime_ns,
        link: entry.link.clone(),
    }
}

fn join(parent: &str, name: &str) -> String {
    if parent.is_empty() { name.to_owned() } else { format!("{parent}/{name}") }
}

/// FNV-1a over `bytes` (stable across builds and machines).
fn fnv(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
        (hash ^ u64::from(*byte)).wrapping_mul(0x0100_0000_01b3)
    })
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
