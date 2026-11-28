//! Per-file `zstd --patch-from` over `cas/1` (RFD 0166, row W1): the layer above chunks for a
//! file that changed a little but everywhere, as a rebuilt minified bundle does. Chunks alone
//! move 24.9% of a web update at p50; a patch from the file the client already holds moves
//! 3.37% (W1 replay).
//!
//! The publisher, holding the last few published trees, writes for each changed file one patch
//! per base it can pair the file with:
//!
//! - `d/<to>.from-<from>.zst`: a zstd frame of the new file (`to`, its BLAKE3) with the base
//!   file (`from`, its BLAKE3) as the reference prefix;
//! - `d/<manifest id>.json`: the [`List`] of those patches with their lengths, so a client asks
//!   only for patches that exist.
//!
//! Names are content ids, so every object is write-once. A patch is never trusted: the client
//! decodes it against the base file it holds and keeps the result only when it hashes to `to`;
//! the list is a hint that can waste a request but never changes a byte. Pairing (same path,
//! else the same path with its build hash taken out) is the publisher's alone, so it can change
//! without a client change: the client finds a base by its hash.

use crate::{Id, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// The list schema this crate writes and reads.
pub const SCHEMA: u64 = 1;
/// The zstd level patches are written at, as `zstd -19` in the W1 replay.
pub const LEVEL: i32 = 19;
/// Files smaller than this go by chunks alone: a patch would save less than its request costs.
pub const MIN_FILE: u64 = 16 << 10;
/// The largest window a patch may need (base plus file), 128 MiB, as `--long=27`. Larger pairs
/// go by chunks.
pub const MAX_WINDOW_LOG: u32 = 27;
/// A list is about 150 bytes a patch.
pub const MAX_LIST: usize = 4 << 20;

/// One patch the publisher wrote.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Entry {
    /// The new file's BLAKE3.
    pub to: Id,
    /// The base file's BLAKE3.
    pub from: Id,
    /// The patch's bytes.
    pub len: u64,
}

/// The patches published for one manifest.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct List {
    /// [`SCHEMA`].
    pub schema: u64,
    /// Sorted by `to`, then `from`.
    pub patches: Vec<Entry>,
}

impl List {
    /// The list `bytes` hold.
    pub fn from_bytes(bytes: &[u8]) -> Result<Self> {
        let list: Self = serde_json::from_slice(bytes)?;
        if list.schema != SCHEMA {
            return Err(format!("unknown patch list schema {}", list.schema).into());
        }
        Ok(list)
    }
}

/// The object path of a patch.
pub fn patch_path(to: &Id, from: &Id) -> String {
    format!("d/{to}.from-{from}.zst")
}

/// The object path of the patch list of a manifest.
pub fn list_path(manifest: &Id) -> String {
    format!("d/{manifest}.json")
}

fn window_log(base: usize, file: usize) -> Option<u32> {
    let need = base.checked_add(file)?.max(1 << 10);
    let log = usize::BITS - (need - 1).leading_zeros();
    (log <= MAX_WINDOW_LOG).then_some(log)
}

/// `file` as a zstd frame with `base` as its reference prefix, or `None` when the pair needs a
/// window over [`MAX_WINDOW_LOG`].
pub fn make(base: &[u8], file: &[u8]) -> Result<Option<Vec<u8>>> {
    use std::io::Write as _;
    use zstd::stream::raw::CParameter;
    let Some(log) = window_log(base.len(), file.len()) else {
        return Ok(None);
    };
    let mut enc = zstd::stream::write::Encoder::with_ref_prefix(Vec::new(), LEVEL, base)?;
    enc.set_parameter(CParameter::WindowLog(log))?;
    enc.set_parameter(CParameter::EnableLongDistanceMatching(true))?;
    enc.set_pledged_src_size(Some(file.len() as u64))?;
    enc.include_checksum(false)?;
    enc.write_all(file)?;
    Ok(Some(enc.finish()?))
}

/// The file `patch` rebuilds from `base`, refused unless it is `size` bytes hashing to `to`.
pub fn apply(base: &[u8], patch: &[u8], to: &Id, size: u64) -> Result<Vec<u8>> {
    use std::io::Read as _;
    use zstd::stream::raw::DParameter;
    let mut dec = zstd::stream::read::Decoder::with_ref_prefix(patch, base)?;
    dec.set_parameter(DParameter::WindowLogMax(MAX_WINDOW_LOG))?;
    let mut out = Vec::new();
    // One byte past `size` tells a too-long frame from an exact one.
    dec.take(size.saturating_add(1)).read_to_end(&mut out)?;
    if out.len() as u64 != size || Id::of(&out) != *to {
        return Err(format!("patch to {to} does not rebuild the file").into());
    }
    Ok(out)
}

/// A path with its build hash taken out, so `chunks/FactsCard-5IPAB2BO.js` (esbuild) pairs with
/// `chunks/FactsCard-5H6R3SI3.js`, and `assets/index-Bx3k9aQz.js` (Vite) with its next build: the
/// last `-` or `.` separated part of the file name, after its first, that is 8 characters of
/// `[A-Za-z0-9_]` holding a digit or a capital becomes `*`. A false match costs only a patch
/// that is not written (too large) or a pairing that is not made (not unique).
pub fn stem(path: &str) -> Option<String> {
    let (dir, name) = path.rsplit_once('/').map_or(("", path), |(d, n)| (d, n));
    let hashy = |s: &str| {
        s.len() == 8
            && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
            && s.bytes().any(|b| b.is_ascii_digit() || b.is_ascii_uppercase())
    };
    // Each separator after the first part, last first; the part after it is the candidate.
    let (head, rest) = name.match_indices(['-', '.']).rev().find_map(|(i, _)| {
        let head = name.get(..i).filter(|h| !h.is_empty())?;
        let after = name.get(i + 1..)?;
        let part = after.split(['-', '.']).next()?;
        hashy(part).then(|| (head, after.get(part.len()..).unwrap_or("")))
    })?;
    let slash = if dir.is_empty() { "" } else { "/" };
    Some(format!("{dir}{slash}{head}-*{rest}"))
}

/// How many same-stem files of one base tree a file is tried against when its stem is not
/// unique (esbuild names every shared chunk `chunk-<hash>.js`).
pub const STEM_TRIES: usize = 2;

/// The base files a new file at `path` (of `len` bytes) pairs with in each base tree: the same
/// path, else the files with the same [`stem`], the [`STEM_TRIES`] nearest in size.
pub fn pair<'a>(path: &str, len: usize, bases: &'a [BTreeMap<String, Vec<u8>>]) -> Vec<&'a [u8]> {
    let want = stem(path);
    let mut out = Vec::new();
    for tree in bases {
        if let Some(b) = tree.get(path) {
            out.push(b.as_slice());
            continue;
        }
        let Some(want) = want.as_deref() else { continue };
        let mut hits: Vec<&[u8]> = tree
            .iter()
            .filter(|(p, _)| stem(p).as_deref() == Some(want))
            .map(|(_, b)| b.as_slice())
            .collect();
        hits.sort_by_key(|b| b.len().abs_diff(len));
        out.extend(hits.into_iter().take(STEM_TRIES));
    }
    out
}

/// Write under `out` a patch for every file of `tree` (path to bytes) that differs from the
/// file it pairs with in each of `bases`, when the patch is smaller than half the file, and
/// return the list (not yet written: [`write_list`]). Patches are made on every core: level 19
/// over a large window is about 30 s for a 7.7 MB bundle.
pub fn publish(
    tree: &BTreeMap<String, Vec<u8>>,
    bases: &[BTreeMap<String, Vec<u8>>],
    out: &std::path::Path,
) -> Result<List> {
    let mut jobs: Vec<(Id, Id, &[u8], &[u8])> = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for (path, bytes) in tree {
        if (bytes.len() as u64) < MIN_FILE {
            continue;
        }
        let to = Id::of(bytes);
        for base in pair(path, bytes.len(), bases) {
            let from = Id::of(base);
            if from != to && seen.insert((to, from)) {
                jobs.push((to, from, base, bytes));
            }
        }
    }
    // Largest first, so the long ones start at once.
    jobs.sort_by_key(|j| std::cmp::Reverse(j.3.len()));
    std::fs::create_dir_all(out.join("d"))?;
    let next = std::sync::atomic::AtomicUsize::new(0);
    let workers =
        std::thread::available_parallelism().map_or(1, |n| n.get()).min(jobs.len().max(1));
    let made: Vec<Result<Vec<Entry>>> = std::thread::scope(|s| {
        let handles: Vec<_> = (0..workers)
            .map(|_| {
                s.spawn(|| -> Result<Vec<Entry>> {
                    let mut done = Vec::new();
                    loop {
                        let i = next.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                        let Some(&(to, from, base, bytes)) = jobs.get(i) else { return Ok(done) };
                        let Some(patch) = make(base, bytes)? else { continue };
                        if patch.len() >= bytes.len() / 2 {
                            continue;
                        }
                        crate::store::write_atomic(out, &out.join(patch_path(&to, &from)), &patch)?;
                        done.push(Entry { to, from, len: patch.len() as u64 });
                    }
                })
            })
            .collect();
        handles
            .into_iter()
            .map(|h| h.join().unwrap_or_else(|_| Err("a patch worker panicked".into())))
            .collect()
    });
    let mut patches = Vec::new();
    for m in made {
        patches.extend(m?);
    }
    patches.sort_by_key(|p| (p.to.hex(), p.from.hex()));
    Ok(List { schema: SCHEMA, patches })
}

/// Write `list` as the patch list of `manifest` under `out`.
pub fn write_list(list: &List, manifest: &Id, out: &std::path::Path) -> Result<()> {
    std::fs::create_dir_all(out.join("d"))?;
    crate::store::write_atomic(out, &out.join(list_path(manifest)), &serde_json::to_vec(list)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stems() {
        assert_eq!(stem("assets/index-Bx3k9aQz.js").as_deref(), Some("assets/index-*.js"));
        assert_eq!(stem("a/b/chunk.4f9a0c12.css").as_deref(), Some("a/b/chunk-*.css"));
        assert_eq!(
            stem("agent-pane/chunks/FactsCard-5IPAB2BO.js").as_deref(),
            Some("agent-pane/chunks/FactsCard-*.js")
        );
        assert_eq!(stem("main-DQOHYIGE.mjs.map").as_deref(), Some("main-*.mjs.map"));
        assert_eq!(stem("index.html"), None);
        assert_eq!(stem("assets/vendor-react.js"), None);
        assert_eq!(stem("-12345678.js"), None);
    }

    #[test]
    fn a_patch_round_trips_and_a_wrong_base_is_refused() {
        let base: Vec<u8> = (0..200_000u32).flat_map(|i| (i * 7).to_le_bytes()).collect();
        let mut file = base.clone();
        file.splice(1000..1000, b"inserted".iter().copied());
        file[500_000] ^= 0xff;
        let patch = make(&base, &file).unwrap().unwrap();
        assert!(patch.len() < 1000, "{}", patch.len());
        let to = Id::of(&file);
        assert_eq!(apply(&base, &patch, &to, file.len() as u64).unwrap(), file);
        let mut other = base.clone();
        other[10] ^= 1;
        assert!(apply(&other, &patch, &to, file.len() as u64).is_err());
        assert!(apply(&base, &patch, &to, file.len() as u64 - 1).is_err());
    }
}
