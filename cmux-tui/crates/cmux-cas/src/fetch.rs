//! The reader's half of `cas/1` over plain HTTPS: given the manifest and pack a signed pointer
//! names, and the trees this machine already holds, fetch only the chunks it lacks, by Range
//! GETs on the pack, and assemble the new tree bit-exact.
//!
//! The I/O is the caller's [`Source`] (an HTTPS client, or a folder in tests and the replay), so
//! this module decides everything and touches no network itself. Nothing fetched is trusted
//! before its id is checked: the manifest against the id the pointer named, every chunk file
//! against its BLAKE3, the assembled files against the manifest's file hashes.

use crate::manifest::Manifest;
use crate::publish::{index_path, manifest_path, pack_path, parse_index};
use crate::{Id, Result, Store, assemble, pack, plan};
use std::collections::HashSet;
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
    /// Bytes of the manifest and index.
    pub meta_bytes: u64,
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
    if !want.is_empty() && !have.is_empty() {
        seed(store, have, &want.iter().map(|c| c.id).collect())?;
        want.retain(|c| !store.has(&c.id));
    }
    report.reused = report.chunks - want.len();
    if !want.is_empty() {
        let idx_bytes = source.get(&index_path(pack_id), MAX_INDEX)?;
        report.meta_bytes += idx_bytes.len() as u64;
        let index = parse_index(&idx_bytes, pack_id)?;
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

/// Put into `store` every chunk of `want` that a file under one of the `have` trees holds. The
/// trees are cut with the same FastCDC, so an unchanged run of bytes yields the same chunk.
fn seed(store: &Store, have: &[PathBuf], want: &HashSet<Id>) -> Result<()> {
    let mut found = HashSet::new();
    for root in have {
        if !root.is_dir() {
            continue;
        }
        Manifest::of_dir(root, |id, bytes| {
            if want.contains(&id) && found.insert(id) {
                store.put(&id, bytes)?;
            }
            Ok(())
        })?;
        if found.len() == want.len() {
            break;
        }
    }
    Ok(())
}
