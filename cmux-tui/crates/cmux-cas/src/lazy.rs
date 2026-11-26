//! Lazy restore over a `cas/1` manifest (cold storage slice C2). Opt-in: nothing calls it unless
//! a caller builds a [`Lazy`].
//!
//! A restored tree is *present* the moment its manifest is: [`Lazy::list`] and [`Lazy::stat`]
//! answer from the manifest with no fetch. The first [`Lazy::read`] of a byte range fetches only
//! the chunk frames covering it, as one coalesced Range GET per run of adjacent frames
//! ([`pack::ranges`]) from a [`Source`] (R2 packs; a peer fits the same trait and the
//! [`Source::chunk`] hook). [`Lazy::prefetch`] walks the manifest in order and fetches the rest
//! in the background. Every frame goes through [`Store::receive`], which refuses bytes that do
//! not hash to the chunk id, and a whole file is checked against its manifest hash by
//! [`Lazy::verify`], so nothing unverified is ever served or kept.
//!
//! Chunk ids here are public ids (`BLAKE3(bytes)`): this layer neither dedups nor shares across
//! tenants, and it never deletes.

use crate::manifest::{Chunk, File, Manifest};
use crate::pack::{self, Index};
use crate::store::Store;
use crate::{Id, Result};
use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

/// Where frames come from.
pub trait Source: Send + Sync {
    /// Bytes `start..end` of pack `pack` (one Range GET).
    fn range(&self, pack: &Id, start: u64, end: u64) -> Result<Vec<u8>>;

    /// One chunk file by id, from a peer that holds it outside any pack. `None` when this source
    /// has no such path; the caller then fails the read.
    fn chunk(&self, _id: &Id) -> Result<Option<Vec<u8>>> {
        Ok(None)
    }
}

/// Packs in a directory as `<pack hex>.pack`, read by seek: the local stand-in for R2.
pub struct DirSource {
    /// The directory.
    pub dir: PathBuf,
    /// A pause per request, to model a round trip (0 for none).
    pub rtt: std::time::Duration,
    /// Bytes a second one request moves, to model a link (0 for unlimited).
    pub bytes_per_s: u64,
}

impl Source for DirSource {
    fn range(&self, pack: &Id, start: u64, end: u64) -> Result<Vec<u8>> {
        use std::io::{Read as _, Seek as _, SeekFrom};
        if !self.rtt.is_zero() {
            std::thread::sleep(self.rtt);
        }
        let mut f = std::fs::File::open(self.dir.join(format!("{}.pack", pack.hex())))?;
        f.seek(SeekFrom::Start(start))?;
        let len = end.checked_sub(start).ok_or("range ends before it starts")?;
        let mut buf = vec![0u8; usize::try_from(len)?];
        f.read_exact(&mut buf)?;
        if self.bytes_per_s > 0 {
            std::thread::sleep(std::time::Duration::from_secs_f64(
                buf.len() as f64 / self.bytes_per_s as f64,
            ));
        }
        Ok(buf)
    }
}

/// What a path is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Node {
    /// A directory.
    Dir,
    /// A file of `size` bytes.
    File {
        /// Its length.
        size: u64,
        /// Whether it is executable.
        exec: bool,
    },
}

/// One name in a directory listing.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DirEntry {
    /// The last path component.
    pub name: String,
    /// What it is.
    pub node: Node,
}

/// Counters, all monotonic.
#[derive(Debug, Default)]
pub struct Stats {
    /// Range GETs issued.
    pub requests: AtomicU64,
    /// Bytes those moved.
    pub wire_bytes: AtomicU64,
    /// Chunks stored.
    pub chunks: AtomicU64,
}

/// A manifest tree restored on demand into `store`.
pub struct Lazy<S> {
    manifest: Manifest,
    by_path: HashMap<String, usize>,
    dirs: BTreeMap<String, BTreeMap<String, Node>>,
    indexes: Vec<Index>,
    store: Store,
    source: S,
    gap: u64,
    stats: Stats,
}

impl<S: Source> Lazy<S> {
    /// The lazy tree of `manifest`, whose chunks `indexes` locate in the packs `source` serves.
    pub fn new(manifest: Manifest, indexes: Vec<Index>, store: Store, source: S) -> Self {
        let mut by_path = HashMap::new();
        let mut dirs: BTreeMap<String, BTreeMap<String, Node>> = BTreeMap::new();
        dirs.entry(String::new()).or_default();
        for (i, f) in manifest.files.iter().enumerate() {
            by_path.insert(f.path.clone(), i);
            let mut parent = String::new();
            let mut parts = f.path.split('/').peekable();
            while let Some(part) = parts.next() {
                let node = if parts.peek().is_none() {
                    Node::File { size: f.size, exec: f.exec }
                } else {
                    Node::Dir
                };
                dirs.entry(parent.clone()).or_default().insert(part.to_owned(), node);
                if node == Node::Dir {
                    parent = if parent.is_empty() {
                        part.to_owned()
                    } else {
                        format!("{parent}/{part}")
                    };
                    dirs.entry(parent.clone()).or_default();
                }
            }
        }
        Self {
            manifest,
            by_path,
            dirs,
            indexes,
            store,
            source,
            gap: pack::GAP,
            stats: Stats::default(),
        }
    }

    /// The counters.
    pub fn stats(&self) -> &Stats {
        &self.stats
    }

    /// The manifest.
    pub fn manifest(&self) -> &Manifest {
        &self.manifest
    }

    /// What `path` is (`""` is the root), from the manifest alone.
    pub fn stat(&self, path: &str) -> Option<Node> {
        if let Some(f) = self.by_path.get(path).and_then(|&i| self.manifest.files.get(i)) {
            return Some(Node::File { size: f.size, exec: f.exec });
        }
        self.dirs.contains_key(path).then_some(Node::Dir)
    }

    /// The names under directory `dir` (`""` is the root), sorted, from the manifest alone.
    pub fn list(&self, dir: &str) -> Option<Vec<DirEntry>> {
        let d = self.dirs.get(dir)?;
        Some(d.iter().map(|(name, node)| DirEntry { name: name.clone(), node: *node }).collect())
    }

    fn file(&self, path: &str) -> Result<&File> {
        let f = self.by_path.get(path).and_then(|&i| self.manifest.files.get(i));
        f.ok_or_else(|| format!("no file {path:?} in the tree").into())
    }

    /// Fetch the chunks of `want` the store lacks, coalesced into Range GETs, each frame checked
    /// against its id as it lands.
    fn fetch(&self, want: &[Chunk]) -> Result<()> {
        let need: Vec<Chunk> = want.iter().filter(|c| !self.store.has(&c.id)).copied().collect();
        if need.is_empty() {
            return Ok(());
        }
        let (ranges, missing) = pack::ranges(&self.indexes, &need, self.gap);
        for id in missing {
            let file = self
                .source
                .chunk(&id)?
                .ok_or_else(|| format!("chunk {id} is in no pack and no peer has it"))?;
            self.store.receive(&id, &file)?;
            self.stats.chunks.fetch_add(1, Ordering::Relaxed);
        }
        for r in &ranges {
            let bytes = self.source.range(&r.pack, r.start, r.end)?;
            self.stats.requests.fetch_add(1, Ordering::Relaxed);
            self.stats.wire_bytes.fetch_add(bytes.len() as u64, Ordering::Relaxed);
            pack::receive(&self.store, r, &bytes)?;
            self.stats.chunks.fetch_add(r.entries.len() as u64, Ordering::Relaxed);
        }
        Ok(())
    }

    /// Up to `len` bytes of `path` from `offset` (fewer at the end of the file), fetching just
    /// the chunks that cover them.
    pub fn read(&self, path: &str, offset: u64, len: u64) -> Result<Vec<u8>> {
        let f = self.file(path)?;
        let end = offset.saturating_add(len).min(f.size);
        if offset >= end {
            return Ok(Vec::new());
        }
        let mut cover = Vec::new();
        let mut at = 0u64;
        for c in &f.chunks {
            let next = at.saturating_add(u64::from(c.len));
            if next > offset && at < end {
                cover.push((at, *c));
            }
            at = next;
            if at >= end {
                break;
            }
        }
        let chunks: Vec<Chunk> = cover.iter().map(|(_, c)| *c).collect();
        self.fetch(&chunks)?;
        let mut out = Vec::with_capacity(usize::try_from(end.saturating_sub(offset))?);
        for (start, c) in cover {
            let bytes = self.store.get(&c.id)?;
            let from = usize::try_from(offset.saturating_sub(start))?;
            let to = usize::try_from(end.saturating_sub(start).min(u64::from(c.len)))?;
            out.extend_from_slice(
                bytes.get(from..to).ok_or("chunk shorter than its manifest length")?,
            );
        }
        Ok(out)
    }

    /// Fetch whole files in manifest order from file `*cursor` until about `budget` wire-sized
    /// bytes of chunks are requested; advances `cursor`. Returns whether the tree is done.
    pub fn prefetch(&self, cursor: &mut usize, budget: u64) -> Result<bool> {
        let mut batch: Vec<Chunk> = Vec::new();
        let mut bytes = 0u64;
        while bytes < budget {
            let Some(f) = self.manifest.files.get(*cursor) else { break };
            for c in &f.chunks {
                bytes = bytes.saturating_add(u64::from(c.len));
            }
            batch.extend_from_slice(&f.chunks);
            *cursor = cursor.saturating_add(1);
        }
        self.fetch(&batch)?;
        Ok(*cursor >= self.manifest.files.len())
    }

    /// Fetch the whole tree on `streams` threads, each taking the next run of whole files in
    /// manifest order worth about `batch` bytes. Two streams wanting the same chunk both may
    /// fetch it; the store keeps one (writes are rename-into-place).
    pub fn prefetch_all(&self, streams: usize, batch: u64) -> Result<()> {
        let files = &self.manifest.files;
        let total = self.manifest.size().max(1);
        let per = batch.saturating_mul(u64::try_from(files.len())?).checked_div(total).unwrap_or(0);
        let step = usize::try_from(per.max(1))?;
        let next = std::sync::atomic::AtomicUsize::new(0);
        let failed: std::sync::Mutex<Option<crate::Error>> = std::sync::Mutex::new(None);
        std::thread::scope(|s| {
            for _ in 0..streams.max(1) {
                s.spawn(|| {
                    loop {
                        let from = next.fetch_add(step, Ordering::Relaxed);
                        if from >= files.len() {
                            return;
                        }
                        let to = from.saturating_add(step).min(files.len());
                        let run = files.get(from..to).unwrap_or_default();
                        let want: Vec<Chunk> =
                            run.iter().flat_map(|f| f.chunks.iter().copied()).collect();
                        if let Err(e) = self.fetch(&want) {
                            failed.lock().unwrap_or_else(|p| p.into_inner()).get_or_insert(e);
                            return;
                        }
                    }
                });
            }
        });
        match failed.into_inner().unwrap_or_else(|p| p.into_inner()) {
            Some(e) => Err(e),
            None => Ok(()),
        }
    }

    /// Check `path` end to end: every chunk present and decoding to its id, the whole file
    /// hashing to the manifest entry.
    pub fn verify(&self, path: &str) -> Result<()> {
        let f = self.file(path)?;
        let mut h = blake3::Hasher::new();
        for c in &f.chunks {
            h.update(&self.store.get(&c.id)?);
        }
        if Id(*h.finalize().as_bytes()) != f.hash {
            return Err(format!("{path} does not hash to its manifest entry").into());
        }
        Ok(())
    }
}
