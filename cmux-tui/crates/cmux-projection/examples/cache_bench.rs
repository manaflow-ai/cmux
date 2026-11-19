//! The overlay cache's two numbers, from an in-memory Mac:
//!
//! 1. remount: read a tree, then open the same state with a new manifest in which one file
//!    changed, read the tree again, and count the bytes fetched from the Mac the second time;
//! 2. bound: read a tree bigger than the cache's bound and measure the cache's size on disk.
//!
//! `cargo run --release -p cmux-projection --example cache_bench`

use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;

use cmux_projection::manifest::{Item, Kind, Manifest};
use cmux_projection::overlay::Overlay;
use cmux_projection::{Fetch, FetchError};

const MIB: u64 = 1024 * 1024;

/// Serves every file's bytes by entry from memory.
struct Mac(HashMap<u32, Vec<u8>>);

impl Fetch for Mac {
    fn read(&self, entry: u32, offset: u64, len: u32) -> Result<Vec<u8>, FetchError> {
        let bytes = self.0.get(&entry).ok_or(FetchError::Failed)?;
        let start = (offset as usize).min(bytes.len());
        let end = (start + len as usize).min(bytes.len());
        Ok(bytes[start..end].to_vec())
    }

    fn batch(&self, entries: &[u32]) -> Vec<Result<Vec<u8>, FetchError>> {
        entries.iter().map(|entry| self.0.get(entry).cloned().ok_or(FetchError::Failed)).collect()
    }
}

/// `count` files of `size` bytes in 8 folders; file `changed` (if any) has another version.
fn tree(count: usize, size: u64, changed: Option<usize>) -> (Arc<Manifest>, Arc<Mac>) {
    let mut items = Vec::new();
    let mut bytes = Vec::new();
    for at in 0..count {
        let path = format!("d{}/f{at}.bin", at % 8);
        let edited = changed == Some(at);
        let fill = if edited { 0xee } else { (at % 251) as u8 };
        items.push(Item {
            path: path.clone(),
            kind: Kind::File,
            mode: 0o644,
            size,
            mtime_ns: if edited { 2_000_000_000_000_000_000 } else { 1_700_000_000_000_000_000 },
            link: None,
        });
        bytes.push((path, vec![fill; size as usize]));
    }
    let manifest = Arc::new(Manifest::build(1, items).unwrap());
    let mac: HashMap<u32, Vec<u8>> =
        bytes.into_iter().map(|(path, bytes)| (manifest.resolve(&path).unwrap(), bytes)).collect();
    (manifest, Arc::new(Mac(mac)))
}

/// Reads every file of the overlay whole, 128 KiB at a time (as the kernel asks).
fn read_all(overlay: &Overlay, manifest: &Manifest) {
    for index in 0..manifest.len() as u32 {
        let Some(entry) = manifest.entry(index) else { continue };
        if entry.kind != Kind::File {
            continue;
        }
        let mut at = 0;
        while at < entry.size {
            let got = overlay.read(u64::from(index) + 1, at, 128 * 1024).unwrap();
            assert!(!got.is_empty());
            at += got.len() as u64;
        }
    }
}

/// Bytes of every file under `dir`, except the upper layer.
fn disk_bytes(dir: &Path) -> u64 {
    let mut total = 0;
    for entry in std::fs::read_dir(dir).unwrap().flatten() {
        let meta = entry.metadata().unwrap();
        if meta.is_dir() {
            if entry.file_name() != "upper" {
                total += disk_bytes(&entry.path());
            }
        } else {
            total += meta.len();
        }
    }
    total
}

/// Opens the overlay; `bound` is the cache's bound in bytes when the overlay has one.
fn open(manifest: &Arc<Manifest>, state: &Path, mac: &Arc<Mac>, bound: Option<u64>) -> Overlay {
    match bound {
        Some(bound) => {
            Overlay::open_bounded(manifest.clone(), state, mac.clone(), (1000, 1000), bound)
        }
        None => Overlay::open(manifest.clone(), state, mac.clone(), (1000, 1000)),
    }
    .unwrap()
}

fn main() {
    // 1. A remount with a new manifest where 1 of 200 files (256 KiB each, 50 MiB) changed.
    let state = tempfile::tempdir().unwrap();
    let (first, mac) = tree(200, 256 * 1024, None);
    read_all(&open(&first, state.path(), &mac, None), &first);
    let (second, mac) = tree(200, 256 * 1024, Some(17));
    let overlay = open(&second, state.path(), &mac, None);
    read_all(&overlay, &second);
    let refetched = overlay.stats().remote_bytes;
    println!(
        "remount, 1 of 200 files changed: {refetched} bytes fetched again ({:.2} MiB)",
        refetched as f64 / MIB as f64
    );

    // 2. A 200 MiB tree (50 files of 4 MiB) read through a cache bound to 64 MiB.
    let bound = 64 * MIB;
    let state = tempfile::tempdir().unwrap();
    let (manifest, mac) = tree(50, 4 * MIB, None);
    let overlay = open(&manifest, state.path(), &mac, Some(bound));
    read_all(&overlay, &manifest);
    let held = disk_bytes(state.path());
    println!(
        "200 MiB tree, 64 MiB bound: cache holds {held} bytes on disk ({:.1} MiB)",
        held as f64 / MIB as f64
    );
}
