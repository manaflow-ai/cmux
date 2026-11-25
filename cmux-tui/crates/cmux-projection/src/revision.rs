//! A revision (RFD 0007, open question 3): the manifest split into pieces, each a stored blob
//! named by the SHA-256 of its bytes, so a second session or a resume fetches the listing from the
//! store at data-center speed instead of from the Mac over its uplink.
//!
//! A piece is a folder's listing with the listings of its small subfolders folded in (the same
//! layout as a [`Manifest`], rooted at that folder); a subfolder too big to fold in is a stub that
//! names its own piece by hash. A folder's piece depends on nothing above it, so two revisions
//! share every piece whose subtree did not change, and one changed file rewrites the pieces on the
//! path from it to the root. The root piece's hash names the revision.
//!
//! The pieces of one revision are listed by its tree blob ([`Split::tree`]): the store's GC root
//! format (`cmux-sync-tree 1`, then one hash per line), with the root piece first.

use std::collections::{HashMap, VecDeque};
use std::io::Read as _;
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use sha2::{Digest as _, Sha256};

use crate::manifest::{Entry, Kind, MAX_ENTRIES, Manifest, ROOT};
use crate::peers::{Answer, Get};

/// The first line of a tree blob (cmux-platform `TREE_HEADER`).
pub const TREE_HEADER: &str = "cmux-sync-tree 1";
/// About how many bytes of listing a piece holds before its biggest subfolders become pieces of
/// their own (a folder with more than this in one listing is one piece, however big).
const PIECE_TARGET: usize = 256 * 1024;
/// The most bytes one piece decodes to.
const MAX_PIECE_BYTES: u64 = 1024 * 1024 * 1024;
/// The largest blob the store takes (cmux-platform `MAX_BLOB_BYTES`).
pub const MAX_BLOB_BYTES: usize = 64 * 1024 * 1024;
/// Pieces fetched at once.
const PARALLEL: usize = 32;
/// Tries per piece.
const TRIES: u32 = 3;
/// How long one GET of a piece may take.
const GET_DEADLINE: Duration = Duration::from_secs(60);

/// One piece as stored.
#[derive(Serialize, Deserialize)]
struct Wire {
    entries: Vec<Entry>,
    /// Folders of `entries` whose listing is another piece: entry index and its hash.
    stubs: Vec<(u32, [u8; 32])>,
}

/// One stored piece of a revision.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Piece {
    /// The SHA-256 of `bytes`, 64 lowercase hexadecimal characters.
    pub sha256: String,
    pub bytes: Vec<u8>,
}

/// A manifest split into pieces.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Split {
    /// The hash of the root piece: the revision's name.
    pub root: String,
    /// Every distinct piece, the root first.
    pub pieces: Vec<Piece>,
}

impl Split {
    /// The tree blob that lists every piece (what a GC root registers): its header, the root's
    /// hash, then the others in hash order.
    #[must_use]
    pub fn tree(&self) -> Vec<u8> {
        let mut rest: Vec<&str> = self
            .pieces
            .iter()
            .map(|piece| piece.sha256.as_str())
            .filter(|sha| *sha != self.root)
            .collect();
        rest.sort_unstable();
        let mut text = format!("{TREE_HEADER}\n{}\n", self.root);
        for sha in rest {
            text.push_str(sha);
            text.push('\n');
        }
        text.into_bytes()
    }

    /// The root hash a tree blob names (its first hash).
    pub fn root_of_tree(tree: &[u8]) -> anyhow::Result<String> {
        let text = std::str::from_utf8(tree)?;
        let mut lines = text.lines();
        anyhow::ensure!(lines.next() == Some(TREE_HEADER), "not a tree blob");
        let root = lines.next().ok_or_else(|| anyhow::anyhow!("the tree names no revision"))?;
        anyhow::ensure!(is_sha(root), "the tree's first hash is malformed");
        Ok(root.to_owned())
    }
}

/// The SHA-256 of `bytes`, as the store names a blob.
#[must_use]
pub fn sha256_hex(bytes: &[u8]) -> String {
    hex(&Sha256::digest(bytes))
}

fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write as _;
    bytes.iter().fold(String::with_capacity(bytes.len() * 2), |mut out, byte| {
        let _ = write!(out, "{byte:02x}");
        out
    })
}

/// Whether `text` is a hash as the store spells one.
#[must_use]
pub fn is_sha(text: &str) -> bool {
    text.len() == 64 && text.bytes().all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

fn cost(entry: &Entry) -> usize {
    40 + entry.name.len() + entry.link.as_ref().map_or(0, String::len)
}

/// Splits `manifest` into pieces. The same listing always splits into the same pieces.
pub fn split(manifest: &Manifest) -> anyhow::Result<Split> {
    let entries = manifest.entries();
    let count = entries.len();
    // Bottom up (a child sits after its folder): how many bytes of listing a folder holds when
    // every folder below it that is not a piece of its own is folded in.
    let mut folded = vec![0usize; count];
    let mut apart = vec![false; count];
    for index in (0..count).rev() {
        let Some(folder) = entries.get(index).filter(|entry| entry.kind == Kind::Dir) else {
            continue;
        };
        let first = folder.first_child as usize;
        let children = entries.get(first..first + folder.children as usize).unwrap_or(&[]);
        let mut total = 0usize;
        let mut open: Vec<usize> = Vec::new();
        for (at, child) in children.iter().enumerate() {
            total += cost(child);
            if child.kind == Kind::Dir {
                total += folded.get(first + at).copied().unwrap_or(0);
                open.push(first + at);
            }
        }
        if total > PIECE_TARGET {
            // The biggest first, so a few pieces carry the weight; ties by position.
            open.sort_by_key(|child| {
                (std::cmp::Reverse(folded.get(*child).copied().unwrap_or(0)), *child)
            });
            for child in open {
                if total <= PIECE_TARGET {
                    break;
                }
                let own = folded.get(child).copied().unwrap_or(0);
                if own == 0 {
                    continue;
                }
                if let Some(flag) = apart.get_mut(child) {
                    *flag = true;
                }
                // The child's listing leaves this piece; a stub (a hash) stays.
                total = total.saturating_sub(own) + 32;
            }
        }
        if let Some(slot) = folded.get_mut(index) {
            *slot = total;
        }
    }
    if let Some(root) = apart.get_mut(ROOT as usize) {
        *root = true;
    }

    // Deepest piece first, so a stub's hash is known when its folder's piece is written.
    let mut hashes: HashMap<usize, [u8; 32]> = HashMap::new();
    let mut pieces: Vec<Piece> = Vec::new();
    let mut seen: HashMap<String, ()> = HashMap::new();
    let mut root = String::new();
    for index in (0..count).rev() {
        if !apart.get(index).copied().unwrap_or(false) {
            continue;
        }
        let wire = piece_of(entries, &apart, &hashes, index)?;
        let raw = bincode::serialize(&wire)?;
        let bytes = zstd::encode_all(raw.as_slice(), 3)?;
        anyhow::ensure!(
            bytes.len() <= MAX_BLOB_BYTES,
            "a folder's listing is too big for one blob"
        );
        let sha256 = sha256_hex(&bytes);
        hashes.insert(index, Sha256::digest(&bytes).into());
        if index == ROOT as usize {
            root.clone_from(&sha256);
        }
        if seen.insert(sha256.clone(), ()).is_none() {
            pieces.push(Piece { sha256, bytes });
        }
    }
    // The root was written last: move it to the front.
    let at = pieces
        .iter()
        .position(|piece| piece.sha256 == root)
        .ok_or_else(|| anyhow::anyhow!("no root piece"))?;
    pieces.swap(0, at);
    Ok(Split { root, pieces })
}

/// The piece rooted at folder `top`: its listing and every folded subfolder's, in layout order.
fn piece_of(
    entries: &[Entry],
    apart: &[bool],
    hashes: &HashMap<usize, [u8; 32]>,
    top: usize,
) -> anyhow::Result<Wire> {
    let head = entries.get(top).ok_or_else(|| anyhow::anyhow!("no folder {top}"))?;
    let mut out =
        Entry { name: String::new(), parent: ROOT, first_child: 0, children: 0, ..head.clone() };
    if top != ROOT as usize {
        // Its own attributes live in the folder above's entry, so they never change this piece.
        out.mode = 0;
        out.mtime_ns = 0;
        out.size = 0;
        out.link = None;
    }
    let mut local = vec![out];
    let mut stubs = Vec::new();
    let mut queue: VecDeque<(usize, usize)> = VecDeque::from([(top, 0)]);
    while let Some((global, at)) = queue.pop_front() {
        let Some(folder) = entries.get(global) else { continue };
        let first = folder.first_child as usize;
        let children = entries.get(first..first + folder.children as usize).unwrap_or(&[]);
        let start = u32::try_from(local.len())?;
        if let Some(entry) = local.get_mut(at) {
            entry.first_child = start;
            entry.children = u32::try_from(children.len())?;
        }
        for (offset, child) in children.iter().enumerate() {
            let child_global = first + offset;
            let here = u32::try_from(local.len())?;
            let mut copy = child.clone();
            copy.parent = u32::try_from(at)?;
            copy.first_child = 0;
            copy.children = 0;
            local.push(copy);
            if child.kind == Kind::Dir {
                if apart.get(child_global).copied().unwrap_or(false) {
                    let hash = hashes
                        .get(&child_global)
                        .ok_or_else(|| anyhow::anyhow!("a piece below was not written"))?;
                    stubs.push((here, *hash));
                } else {
                    queue.push_back((child_global, here as usize));
                }
            }
        }
    }
    Ok(Wire { entries: local, stubs })
}

/// Where a revision's pieces are read from.
pub trait Blobs: Sync {
    /// The blob named `sha256`, unverified.
    fn get(&self, sha256: &str) -> anyhow::Result<Vec<u8>>;
}

/// The store over HTTP: `GET {origin}/v1/sync/blobs/{sha}` with a read grant.
pub struct Store<'a> {
    pub origin: String,
    pub grant: String,
    pub http: &'a dyn Get,
}

impl Blobs for Store<'_> {
    fn get(&self, sha256: &str) -> anyhow::Result<Vec<u8>> {
        let url = format!("{}/v1/sync/blobs/{sha256}", self.origin.trim_end_matches('/'));
        let mut last = anyhow::anyhow!("the store did not answer");
        for attempt in 0..TRIES {
            if attempt > 0 {
                std::thread::sleep(Duration::from_millis(200 << attempt));
            }
            match self.http.get(&url, Some(&self.grant), GET_DEADLINE) {
                Answer::Found(bytes) => return Ok(bytes),
                Answer::Absent => anyhow::bail!("the store holds no piece {sha256}"),
                Answer::Busy | Answer::Failed => last = anyhow::anyhow!("the store failed a read"),
            }
        }
        Err(last)
    }
}

/// One piece fetched and checked.
struct Parsed {
    manifest: Manifest,
    stubs: HashMap<u32, String>,
}

fn parse(sha256: &str, bytes: &[u8]) -> anyhow::Result<Parsed> {
    anyhow::ensure!(sha256_hex(bytes) == sha256, "piece {sha256}: its bytes do not hash to it");
    let mut raw = Vec::new();
    zstd::Decoder::new(bytes)?.take(MAX_PIECE_BYTES + 1).read_to_end(&mut raw)?;
    anyhow::ensure!(raw.len() as u64 <= MAX_PIECE_BYTES, "piece {sha256} is too large");
    let wire: Wire = bincode::deserialize(&raw)?;
    let manifest = Manifest::from_entries(wire.entries)?;
    let mut stubs = HashMap::new();
    for (at, hash) in wire.stubs {
        let folder =
            manifest.entry(at).filter(|entry| entry.kind == Kind::Dir && entry.children == 0);
        anyhow::ensure!(
            folder.is_some() && at != ROOT,
            "piece {sha256}: a stub is not an empty folder"
        );
        stubs.insert(at, hex(&hash));
    }
    Ok(Parsed { manifest, stubs })
}

/// Fetches `wanted` (each checked against its hash) with [`PARALLEL`] reads at once.
fn fetch_all(
    blobs: &dyn Blobs,
    wanted: &[String],
    into: &mut HashMap<String, Parsed>,
) -> anyhow::Result<()> {
    let next = AtomicUsize::new(0);
    let done: Mutex<Vec<anyhow::Result<(String, Parsed)>>> = Mutex::new(Vec::new());
    std::thread::scope(|scope| {
        for _ in 0..PARALLEL.min(wanted.len()) {
            scope.spawn(|| {
                loop {
                    let at = next.fetch_add(1, Ordering::Relaxed);
                    let Some(sha) = wanted.get(at) else { return };
                    let got = blobs
                        .get(sha)
                        .and_then(|bytes| parse(sha, &bytes))
                        .map(|parsed| (sha.clone(), parsed));
                    let failed = got.is_err();
                    done.lock().unwrap_or_else(std::sync::PoisonError::into_inner).push(got);
                    if failed {
                        // The revision is unusable: stop taking more.
                        next.store(wanted.len(), Ordering::Relaxed);
                        return;
                    }
                }
            });
        }
    });
    for result in done.into_inner().unwrap_or_else(std::sync::PoisonError::into_inner) {
        let (sha, parsed) = result?;
        into.insert(sha, parsed);
    }
    Ok(())
}

/// The manifest of revision `root`, its pieces read from `blobs` (a level of the piece tree at a
/// time, each level in parallel) and checked against their hashes.
pub fn assemble(root: &str, blobs: &dyn Blobs) -> anyhow::Result<Manifest> {
    anyhow::ensure!(is_sha(root), "a revision is named by a SHA-256");
    let mut have: HashMap<String, Parsed> = HashMap::new();
    let mut level = vec![root.to_owned()];
    while !level.is_empty() {
        fetch_all(blobs, &level, &mut have)?;
        let mut next: Vec<String> = Vec::new();
        for sha in &level {
            let Some(parsed) = have.get(sha) else { continue };
            for stub in parsed.stubs.values() {
                if !have.contains_key(stub) && !next.contains(stub) {
                    next.push(stub.clone());
                }
            }
        }
        level = next;
    }

    let top = have.get(root).ok_or_else(|| anyhow::anyhow!("the root piece is missing"))?;
    let first =
        top.manifest.entry(ROOT).ok_or_else(|| anyhow::anyhow!("the root piece is empty"))?;
    let mut out: Vec<Entry> = vec![Entry { first_child: 0, children: 0, ..first.clone() }];
    // (the folder's index in `out`, its piece, its entry in that piece)
    let mut queue: VecDeque<(u32, &Parsed, u32)> = VecDeque::from([(ROOT, top, ROOT)]);
    while let Some((global, piece, at)) = queue.pop_front() {
        // A stub's listing is its own piece's root.
        let (piece, at) = match piece.stubs.get(&at) {
            Some(sha) => {
                (have.get(sha).ok_or_else(|| anyhow::anyhow!("piece {sha} is missing"))?, ROOT)
            }
            None => (piece, at),
        };
        let (first_local, children) = piece.manifest.children(at);
        let start = u32::try_from(out.len())?;
        if let Some(folder) = out.get_mut(global as usize) {
            folder.first_child = start;
            folder.children = u32::try_from(children.len())?;
        }
        for (offset, child) in children.iter().enumerate() {
            let here = u32::try_from(out.len())?;
            out.push(Entry { parent: global, first_child: 0, children: 0, ..child.clone() });
            if child.kind == Kind::Dir {
                queue.push_back((here, piece, first_local + u32::try_from(offset)?));
            }
        }
        anyhow::ensure!(out.len() <= MAX_ENTRIES, "more than {MAX_ENTRIES} paths");
    }
    Manifest::from_entries(out)
}

#[cfg(test)]
#[path = "revision_tests.rs"]
mod tests;
