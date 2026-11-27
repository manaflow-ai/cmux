//! Physical over logical: what a set of folders would store as `cas/1` chunks, against the bytes
//! they hold today. The measurement under the cold tier and the shared tier (hq
//! `docs/design/cold-storage-and-shared-tier.md`): a customer is billed the logical bytes, we keep
//! the distinct chunks.
//!
//! Every regular file under each root is cut with [`cdc`](crate::cdc) and hashed. A chunk is kept
//! once however many roots hold it, so `physical` is the distinct bytes, `shared` per root the
//! bytes of its chunks another root also holds, and `whole_file_physical` what dedup by whole
//! file (hardlinks, a file-level CAS) would reach. Symlinks are not followed; unreadable files are
//! counted in `skipped`. Ids are BLAKE3 truncated to 128 bits: a measurement, not a store.

use crate::cdc;
use std::collections::HashMap;
use std::collections::hash_map::Entry;
use std::fs::File;
use std::io::Read as _;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, PoisonError, mpsc};

/// A chunk's measurement id.
pub type Key = [u8; 16];

/// One root's numbers.
#[derive(Debug, Default, Clone, serde::Serialize)]
pub struct Root {
    pub label: String,
    pub files: u64,
    /// The bytes its files hold (apparent size).
    pub logical: u64,
    /// Its distinct chunks' bytes, each counted once within the root.
    pub distinct: u64,
    /// Of `distinct`, the bytes whose chunk another root also holds.
    pub shared: u64,
}

/// The whole measurement.
#[derive(Debug, Default, Clone, serde::Serialize)]
pub struct Report {
    pub roots: Vec<Root>,
    pub files: u64,
    pub skipped: u64,
    pub logical: u64,
    /// Disk blocks the files use today, a hardlinked inode counted once.
    pub allocated: u64,
    pub chunks: u64,
    pub distinct_chunks: u64,
    /// The distinct chunks' bytes: what a chunk store keeps.
    pub physical: u64,
    /// The distinct whole files' bytes: what a file-level dedup keeps.
    pub whole_file_physical: u64,
    /// `physical / logical`.
    pub physical_over_logical: f64,
    /// zstd (level `zstd_level`) of a sample of distinct chunks, compressed over raw.
    pub zstd_ratio: f64,
    pub zstd_level: i32,
    pub zstd_sampled_bytes: u64,
    /// `physical * zstd_ratio`: the chunk store's bytes at rest.
    pub physical_compressed: u64,
    /// Of `physical`, the bytes of distinct chunks the public tier holds (0 without a public
    /// index): kept once for every tenant, so a cold pass stores a ref instead of a copy.
    pub public_chunk_bytes: u64,
    /// Files whose every chunk is public: stored as a ref.
    pub public_ref_files: u64,
    pub public_ref_file_bytes: u64,
    /// `physical - public_chunk_bytes`: what a tenant's cold pass physically keeps.
    pub physical_after_public: u64,
    pub seconds: f64,
}

struct Chunk {
    len: u32,
    roots: u64,
}

#[derive(Default)]
struct State {
    chunks: HashMap<Key, Chunk>,
    files: HashMap<Key, u64>,
    inodes: HashMap<(u64, u64), ()>,
    totals: Report,
    per_root: Vec<Root>,
    sample_raw: u64,
    sample_z: u64,
}

/// Options for [`measure`].
pub struct Options {
    /// Compress one distinct chunk in this many for the zstd ratio (0: none).
    pub sample_every: u64,
    pub zstd_level: i32,
    pub threads: usize,
    /// Prefixes of the public tier's chunk ids ([`crate::public::PublicIndex::prefixes`]).
    pub public: Option<std::collections::HashSet<Key>>,
}

impl Default for Options {
    fn default() -> Self {
        Self { sample_every: 32, zstd_level: 3, threads: 8, public: None }
    }
}

fn key16(hash: &blake3::Hash) -> Key {
    hash.as_bytes().first_chunk::<16>().copied().unwrap_or_default()
}

fn key(bytes: &[u8]) -> Key {
    key16(&blake3::hash(bytes))
}

/// Root `i`'s bit; 0 past the 64th (callers keep at most 64 roots).
fn bit(i: usize) -> u64 {
    u32::try_from(i).ok().and_then(|s| 1u64.checked_shl(s)).unwrap_or(0)
}

fn as_u64(n: usize) -> u64 {
    u64::try_from(n).unwrap_or(u64::MAX)
}

fn add(total: &mut u64, n: u64) {
    *total = total.saturating_add(n);
}

/// Return the platform's stable file identity and allocated-byte count when available.
///
/// Unix exposes inode and block counts through `MetadataExt`; Windows does not expose
/// those fields in `std::fs::Metadata`, so the portable fallback counts apparent bytes
/// for each file and skips hardlink de-duplication.
#[cfg(unix)]
fn allocation(meta: &std::fs::Metadata) -> (Option<(u64, u64)>, u64) {
    use std::os::unix::fs::MetadataExt as _;
    (Some((meta.dev(), meta.ino())), meta.blocks().saturating_mul(512))
}

#[cfg(not(unix))]
fn allocation(meta: &std::fs::Metadata) -> (Option<(u64, u64)>, u64) {
    (None, meta.len())
}

fn walk(root: &Path, out: &mut dyn FnMut(PathBuf, std::fs::Metadata)) {
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else { continue };
        for e in entries.flatten() {
            let path = e.path();
            let Ok(meta) = std::fs::symlink_metadata(&path) else { continue };
            if meta.is_dir() {
                stack.push(path);
            } else if meta.is_file() {
                out(path, meta);
            }
        }
    }
}

/// One file cut: its chunks `(key, len)` in order, the whole file's key, and its first chunk's bytes.
struct Cut {
    chunks: Vec<(Key, u32)>,
    whole: Key,
    first: Vec<u8>,
}

/// The chunks of one file, streamed.
fn chunk_file(path: &Path) -> std::io::Result<Cut> {
    let mut f = File::open(path)?;
    let window = cdc::MAX.saturating_mul(2);
    let mut buf: Vec<u8> = Vec::with_capacity(window.saturating_mul(2));
    let mut whole = blake3::Hasher::new();
    let mut out = Vec::new();
    let mut eof = false;
    let mut first = Vec::new();
    loop {
        while !eof && buf.len() < window {
            let at = buf.len();
            buf.resize(at.saturating_add(window), 0);
            let n = match buf.get_mut(at..) {
                Some(tail) => f.read(tail)?,
                None => 0,
            };
            buf.truncate(at.saturating_add(n));
            eof = n == 0;
        }
        if buf.is_empty() {
            break;
        }
        let mut rest: &[u8] = &buf;
        while !rest.is_empty() && (eof || rest.len() >= cdc::MAX) {
            let len = cdc::cut(rest).clamp(1, rest.len());
            let Some((piece, tail)) = rest.split_at_checked(len) else { break };
            whole.update(piece);
            if out.is_empty() {
                first = piece.to_vec();
            }
            out.push((key(piece), u32::try_from(len).unwrap_or(u32::MAX)));
            rest = tail;
        }
        let used = buf.len().saturating_sub(rest.len());
        buf.drain(..used);
        if eof && buf.is_empty() {
            break;
        }
    }
    Ok(Cut { chunks: out, whole: key16(&whole.finalize()), first })
}

/// Add one cut file of root `i` to the totals.
fn record(st: &mut State, i: usize, meta: &std::fs::Metadata, cut: Cut, opts: &Options) {
    let Cut { chunks, whole, first } = cut;
    let bit = bit(i);
    let size = meta.len();
    add(&mut st.totals.files, 1);
    add(&mut st.totals.logical, size);
    let (identity, allocated) = allocation(meta);
    match identity {
        Some(identity) => {
            if st.inodes.insert(identity, ()).is_none() {
                add(&mut st.totals.allocated, allocated);
            }
        }
        None => add(&mut st.totals.allocated, allocated),
    }
    if let Entry::Vacant(e) = st.files.entry(whole) {
        e.insert(size);
        add(&mut st.totals.whole_file_physical, size);
    }
    if let Some(root) = st.per_root.get_mut(i) {
        add(&mut root.files, 1);
        add(&mut root.logical, size);
    }
    add(&mut st.totals.chunks, as_u64(chunks.len()));
    if let Some(public) = &opts.public
        && !chunks.is_empty()
        && chunks.iter().all(|(k, _)| public.contains(k))
    {
        add(&mut st.totals.public_ref_files, 1);
        add(&mut st.totals.public_ref_file_bytes, size);
    }
    for (n, (k, len)) in chunks.into_iter().enumerate() {
        match st.chunks.entry(k) {
            Entry::Vacant(e) => {
                e.insert(Chunk { len, roots: bit });
                add(&mut st.totals.physical, u64::from(len));
                add(&mut st.totals.distinct_chunks, 1);
                let sample = opts.sample_every > 0
                    && st.totals.distinct_chunks.is_multiple_of(opts.sample_every)
                    && n == 0;
                if sample && !first.is_empty() {
                    let z = zstd::bulk::compress(&first, opts.zstd_level)
                        .map_or(first.len(), |z| z.len().min(first.len()));
                    add(&mut st.sample_raw, as_u64(first.len()));
                    add(&mut st.sample_z, as_u64(z));
                }
            }
            Entry::Occupied(mut e) => {
                e.get_mut().roots |= bit;
            }
        }
    }
}

#[allow(
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss,
    clippy::cast_precision_loss,
    reason = "an estimate of bytes at rest: a non-negative f64 product saturates into u64"
)]
fn scaled(bytes: u64, ratio: f64) -> u64 {
    (bytes as f64 * ratio) as u64
}

#[allow(clippy::cast_precision_loss, reason = "a ratio of byte counts, reported as f64")]
fn ratio(num: u64, den: u64, empty: f64) -> f64 {
    if den == 0 { empty } else { num as f64 / den as f64 }
}

/// Measure ROOTS (label, folder); a root's index is its bit, so roots past the 64th are ignored.
pub fn measure(roots: &[(String, PathBuf)], opts: &Options) -> Report {
    let roots = roots.get(..64).unwrap_or(roots);
    let started = std::time::Instant::now();
    let state = Mutex::new(State {
        per_root: roots.iter().map(|(l, _)| Root { label: l.clone(), ..Root::default() }).collect(),
        ..State::default()
    });
    let (tx, rx) = mpsc::sync_channel::<(usize, PathBuf, std::fs::Metadata)>(4096);
    let rx = Mutex::new(rx);
    std::thread::scope(|s| {
        for _ in 0..opts.threads.max(1) {
            s.spawn(|| {
                loop {
                    let Ok((i, path, meta)) =
                        rx.lock().unwrap_or_else(PoisonError::into_inner).recv()
                    else {
                        break;
                    };
                    let got = chunk_file(&path);
                    let mut st = state.lock().unwrap_or_else(PoisonError::into_inner);
                    match got {
                        Ok(cut) => record(&mut st, i, &meta, cut, opts),
                        Err(_) => add(&mut st.totals.skipped, 1),
                    }
                }
            });
        }
        for (i, (_, root)) in roots.iter().enumerate() {
            walk(root, &mut |p, m| {
                let _ = tx.send((i, p, m));
            });
        }
        drop(tx);
    });
    let mut st = state.into_inner().unwrap_or_else(PoisonError::into_inner);
    for c in st.chunks.values() {
        let len = u64::from(c.len);
        for (i, root) in st.per_root.iter_mut().enumerate() {
            let b = bit(i);
            if c.roots & b != 0 {
                add(&mut root.distinct, len);
                if c.roots & !b != 0 {
                    add(&mut root.shared, len);
                }
            }
        }
    }
    if let Some(public) = &opts.public {
        let held: u64 = st
            .chunks
            .iter()
            .filter(|(k, _)| public.contains(*k))
            .map(|(_, c)| u64::from(c.len))
            .sum();
        st.totals.public_chunk_bytes = held;
    }
    let mut r = st.totals;
    r.physical_after_public = r.physical.saturating_sub(r.public_chunk_bytes);
    r.roots = st.per_root;
    r.physical_over_logical = ratio(r.physical, r.logical, 0.0);
    r.zstd_level = opts.zstd_level;
    r.zstd_sampled_bytes = st.sample_raw;
    r.zstd_ratio = ratio(st.sample_z, st.sample_raw, 1.0);
    r.physical_compressed = scaled(r.physical, r.zstd_ratio);
    r.seconds = started.elapsed().as_secs_f64();
    r
}
