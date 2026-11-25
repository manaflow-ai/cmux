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
use std::os::unix::fs::MetadataExt as _;
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
}

impl Default for Options {
    fn default() -> Self {
        Self { sample_every: 32, zstd_level: 3, threads: 8 }
    }
}

fn key(bytes: &[u8]) -> Key {
    let mut k = [0u8; 16];
    k.copy_from_slice(&blake3::hash(bytes).as_bytes()[..16]);
    k
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
    let mut buf: Vec<u8> = Vec::with_capacity(cdc::MAX * 4);
    let mut whole = blake3::Hasher::new();
    let mut out = Vec::new();
    let mut eof = false;
    let mut first = Vec::new();
    loop {
        while !eof && buf.len() < cdc::MAX * 2 {
            let at = buf.len();
            buf.resize(at + cdc::MAX * 2, 0);
            let n = f.read(&mut buf[at..])?;
            buf.truncate(at + n);
            eof = n == 0;
        }
        if buf.is_empty() {
            break;
        }
        let mut at = 0;
        while at < buf.len() && (eof || buf.len() - at >= cdc::MAX) {
            let len = cdc::cut(&buf[at..]);
            let piece = &buf[at..at + len];
            whole.update(piece);
            if out.is_empty() {
                first = piece.to_vec();
            }
            out.push((key(piece), u32::try_from(len).unwrap_or(u32::MAX)));
            at += len;
        }
        buf.drain(..at);
        if eof && buf.is_empty() {
            break;
        }
    }
    let mut k = [0u8; 16];
    k.copy_from_slice(&whole.finalize().as_bytes()[..16]);
    Ok(Cut { chunks: out, whole: k, first })
}

/// Measure ROOTS (label, folder); a root's index is its bit, so roots past the 64th are ignored.
pub fn measure(roots: &[(String, PathBuf)], opts: &Options) -> Report {
    let roots = &roots[..roots.len().min(64)];
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
                    let Ok(Cut { chunks, whole, first }) = got else {
                        st.totals.skipped += 1;
                        continue;
                    };
                    let bit = 1u64 << i;
                    let size = meta.len();
                    st.totals.files += 1;
                    st.totals.logical += size;
                    if st.inodes.insert((meta.dev(), meta.ino()), ()).is_none() {
                        st.totals.allocated += meta.blocks() * 512;
                    }
                    if let Entry::Vacant(e) = st.files.entry(whole) {
                        e.insert(size);
                        st.totals.whole_file_physical += size;
                    }
                    st.per_root[i].files += 1;
                    st.per_root[i].logical += size;
                    st.totals.chunks += chunks.len() as u64;
                    for (n, (k, len)) in chunks.into_iter().enumerate() {
                        let len64 = u64::from(len);
                        match st.chunks.entry(k) {
                            Entry::Vacant(e) => {
                                e.insert(Chunk { len, roots: bit });
                                st.totals.physical += len64;
                                st.totals.distinct_chunks += 1;
                                let sample = opts.sample_every > 0
                                    && st.totals.distinct_chunks.is_multiple_of(opts.sample_every)
                                    && n == 0;
                                if sample && !first.is_empty() {
                                    let z = zstd::bulk::compress(&first, opts.zstd_level)
                                        .map_or(first.len(), |z| z.len().min(first.len()));
                                    st.sample_raw += first.len() as u64;
                                    st.sample_z += z as u64;
                                }
                            }
                            Entry::Occupied(mut e) => {
                                let c = e.get_mut();
                                c.roots |= bit;
                            }
                        }
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
        for i in 0..roots.len() {
            if c.roots & (1 << i) != 0 {
                st.per_root[i].distinct += len;
                if c.roots & !(1 << i) != 0 {
                    st.per_root[i].shared += len;
                }
            }
        }
    }
    let mut r = st.totals;
    r.roots = st.per_root;
    r.physical_over_logical =
        if r.logical == 0 { 0.0 } else { r.physical as f64 / r.logical as f64 };
    r.zstd_level = opts.zstd_level;
    r.zstd_sampled_bytes = st.sample_raw;
    r.zstd_ratio = if st.sample_raw == 0 { 1.0 } else { st.sample_z as f64 / st.sample_raw as f64 };
    r.physical_compressed = (r.physical as f64 * r.zstd_ratio) as u64;
    r.seconds = started.elapsed().as_secs_f64();
    r
}
