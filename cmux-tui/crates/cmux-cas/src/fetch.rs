//! The reader's half of `cas/1` over plain HTTPS: given the manifest and pack a signed pointer
//! names, and the trees this machine already holds, fetch only the chunks it lacks, by Range
//! GETs on the pack, and assemble the new tree bit-exact.
//!
//! The I/O is the caller's [`Source`] (an HTTPS client, or a folder in tests and the replay), so
//! this module decides everything and touches no network itself. Nothing fetched is trusted
//! before its id is checked: the manifest against the id the pointer named, every chunk file
//! against its BLAKE3, the assembled files against the manifest's file hashes.

use crate::manifest::{File, Manifest};
use crate::patch::{self, List};
use crate::publish::{index_path, manifest_path, pack_path, parse_index};
use crate::{Id, Result, Store, assemble, pack, plan};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

/// A manifest is a few hundred KiB for a 50 MB tree; reading more is refused.
pub const MAX_MANIFEST: usize = 16 << 20;
/// An index is about 100 bytes a chunk.
pub const MAX_INDEX: usize = 16 << 20;

/// Where the objects of [`crate::publish`] are read from.
pub trait Source {
    /// The whole object at `path`, no larger than `max`.
    fn get(&mut self, path: &str, max: usize) -> Result<Vec<u8>>;
    /// Bytes `start..end` of the object at `path`: exactly `end - start` of them.
    fn range(&mut self, path: &str, start: u64, end: u64) -> Result<Vec<u8>>;
}

/// A folder laid out as [`crate::publish`] writes it.
pub struct DirSource(pub PathBuf);

impl Source for DirSource {
    fn get(&mut self, path: &str, max: usize) -> Result<Vec<u8>> {
        let bytes = std::fs::read(self.0.join(path))?;
        if bytes.len() > max {
            return Err(format!("{path} is larger than {max} bytes").into());
        }
        Ok(bytes)
    }

    fn range(&mut self, path: &str, start: u64, end: u64) -> Result<Vec<u8>> {
        use std::io::{Read as _, Seek as _};
        let mut f = std::fs::File::open(self.0.join(path))?;
        f.seek(std::io::SeekFrom::Start(start))?;
        let mut out = vec![0; usize::try_from(end - start)?];
        f.read_exact(&mut out)?;
        Ok(out)
    }
}

/// What [`fetch`] did.
#[derive(Clone, Debug, Default, PartialEq, Eq, serde::Serialize)]
pub struct Report {
    /// The new tree's bytes.
    pub tree_bytes: u64,
    /// Its distinct chunks.
    pub chunks: usize,
    /// Chunks found in the store or the trees held.
    pub reused: usize,
    /// Range GETs made on the pack.
    pub ranges: usize,
    /// Bytes those ranges read.
    pub range_bytes: u64,
    /// Bytes of the manifest, index and patch list.
    pub meta_bytes: u64,
    /// Files rebuilt from a `zstd --patch-from` patch against a file held ([`crate::patch`]).
    pub patches: usize,
    /// Bytes those patches read.
    pub patch_bytes: u64,
    /// Patches read that did not rebuild their file (the chunks were fetched instead).
    pub patch_misses: usize,
}

/// Fetch the tree of `manifest` into `out` (which must not exist), reading chunks from `store`,
/// then from the files of the trees in `have`, then from `pack` over `source`.
pub fn fetch(
    source: &mut dyn Source,
    store: &Store,
    manifest: &Id,
    pack_id: &Id,
    have: &[PathBuf],
    out: &Path,
) -> Result<Report> {
    let bytes = source.get(&manifest_path(manifest), MAX_MANIFEST)?;
    let m = Manifest::from_bytes(&bytes, manifest)?;
    let mut report = Report {
        tree_bytes: m.size(),
        chunks: m.distinct_chunks().len(),
        meta_bytes: bytes.len() as u64,
        ..Report::default()
    };
    let mut want = plan::want(&m, |id| store.has(id));
    let mut held = HashMap::new();
    if !want.is_empty() && !have.is_empty() {
        held = seed(store, have, &want.iter().map(|c| c.id).collect())?;
        want.retain(|c| !store.has(&c.id));
    }
    report.reused = report.chunks - want.len();
    if !want.is_empty() {
        let idx_bytes = source.get(&index_path(pack_id), MAX_INDEX)?;
        report.meta_bytes += idx_bytes.len() as u64;
        let index = parse_index(&idx_bytes, pack_id)?;
        if !held.is_empty() {
            patch_in(source, store, &m, manifest, &index, &held, &mut report)?;
            want.retain(|c| !store.has(&c.id));
        }
        let (ranges, missing) = pack::ranges(&[index], &want, pack::GAP);
        if let Some(id) = missing.first() {
            return Err(format!("chunk {id} is in no pack the pointer names").into());
        }
        for r in &ranges {
            let got = source.range(&pack_path(&r.pack), r.start, r.end)?;
            pack::receive(store, r, &got)?;
            report.ranges += 1;
            report.range_bytes += r.len();
        }
    }
    assemble::assemble(store, &m, out)?;
    Ok(report)
}

/// Put into `store` every chunk of `want` that a file under one of the `have` trees holds, and
/// say where each file held is, by its hash. The trees are cut with the same FastCDC, so an
/// unchanged run of bytes yields the same chunk.
fn seed(store: &Store, have: &[PathBuf], want: &HashSet<Id>) -> Result<HashMap<Id, PathBuf>> {
    let mut found = HashSet::new();
    let mut held = HashMap::new();
    for root in have {
        if !root.is_dir() {
            continue;
        }
        let m = Manifest::of_dir(root, |id, bytes| {
            if want.contains(&id) && found.insert(id) {
                store.put(&id, bytes)?;
            }
            Ok(())
        })?;
        for f in m.files {
            held.entry(f.hash).or_insert_with(|| root.join(&f.path));
        }
    }
    Ok(held)
}

/// Rebuild from a patch, against a file held, every file of `m` whose missing chunks cost more
/// by Range GET than its smallest patch, and put its chunks into `store`. No patch list, or a
/// patch that does not rebuild its file, leaves the chunks to the pack.
fn patch_in(
    source: &mut dyn Source,
    store: &Store,
    m: &Manifest,
    manifest: &Id,
    index: &pack::Index,
    held: &HashMap<Id, PathBuf>,
    report: &mut Report,
) -> Result<()> {
    let Ok(bytes) = source.get(&patch::list_path(manifest), patch::MAX_LIST) else {
        return Ok(());
    };
    report.meta_bytes += bytes.len() as u64;
    let Ok(list) = List::from_bytes(&bytes) else {
        return Ok(());
    };
    let cost: HashMap<Id, u64> = index.entries.iter().map(|e| (e.id, u64::from(e.len))).collect();
    let mut done = HashSet::new();
    for f in &m.files {
        if !done.insert(f.hash) {
            continue;
        }
        let missing: HashSet<Id> =
            f.chunks.iter().map(|c| c.id).filter(|id| !store.has(id)).collect();
        let by_chunks: u64 = missing.iter().filter_map(|id| cost.get(id)).sum();
        let best = list
            .patches
            .iter()
            .filter(|p| p.to == f.hash && p.len < by_chunks && held.contains_key(&p.from))
            .min_by_key(|p| p.len);
        let Some(p) = best else { continue };
        let Some(base_path) = held.get(&p.from) else { continue };
        match patch_file(source, store, f, p, base_path) {
            Ok(()) => {
                report.patches += 1;
                report.patch_bytes += p.len;
            }
            Err(_) => report.patch_misses += 1,
        }
    }
    Ok(())
}

fn patch_file(
    source: &mut dyn Source,
    store: &Store,
    f: &File,
    p: &patch::Entry,
    base_path: &Path,
) -> Result<()> {
    let base = std::fs::read(base_path)?;
    if Id::of(&base) != p.from {
        return Err(format!("{} changed on disk", base_path.display()).into());
    }
    let body = source.get(&patch::patch_path(&p.to, &p.from), usize::try_from(p.len)?)?;
    let bytes = patch::apply(&base, &body, &f.hash, f.size)?;
    let mut at = 0usize;
    for c in &f.chunks {
        let end = at.checked_add(c.len as usize).ok_or("chunk offset overflow")?;
        let piece = bytes.get(at..end).ok_or("chunk outside file")?;
        store.put(&c.id, piece)?;
        at = end;
    }
    Ok(())
}
