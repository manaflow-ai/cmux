//! A folder of 1.5 M files (RFD 0007's P0 gate names 1.5 M; the prototype reached 1.1 M): how long
//! the manifest takes to build, encode, decode and open as an overlay, how big it is on the wire,
//! and how much memory a decode holds. A bounded run of 200,000 entries is in the regular suite;
//! `a_bench_of_a_one_and_a_half_million_file_manifest` prints the full numbers.

use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::manifest::{Item, Kind, Manifest};
use crate::overlay::Overlay;
use crate::{Fetch, FetchError};

struct Never;

impl Fetch for Never {
    fn read(&self, _entry: u32, _offset: u64, _len: u32) -> Result<Vec<u8>, FetchError> {
        Err(FetchError::Failed)
    }

    fn batch(&self, entries: &[u32]) -> Vec<Result<Vec<u8>, FetchError>> {
        entries.iter().map(|_| Err(FetchError::Failed)).collect()
    }
}

/// A source tree's shape: 40 files to a folder, folders three deep, names like a repo's.
fn items(files: usize) -> Vec<Item> {
    (0..files)
        .map(|index| Item {
            path: format!(
                "pkg{:03}/module_{:04}/src_{:02}/file_{index:07}.rs",
                index / 40_000,
                index / 400,
                (index / 40) % 10
            ),
            kind: Kind::File,
            mode: 0o644,
            size: 1000 + (index as u64 % 9000),
            mtime_ns: 1_700_000_000_000_000_000 + index as i64,
            link: None,
        })
        .collect()
}

struct Numbers {
    build: Duration,
    encode: Duration,
    encoded: usize,
    decode: Duration,
    open: Duration,
}

fn measure(files: usize) -> Numbers {
    let listed = items(files);
    let started = Instant::now();
    let manifest = Manifest::build(1, listed).unwrap();
    let build = started.elapsed();
    let started = Instant::now();
    let encoded = manifest.encode().unwrap();
    let encode = started.elapsed();
    let started = Instant::now();
    let decoded = Manifest::decode(&encoded).unwrap();
    let decode = started.elapsed();
    assert_eq!(decoded.len(), manifest.len());
    assert_eq!(decoded.totals(), manifest.totals());
    drop(manifest);
    let state = tempfile::tempdir().unwrap();
    let started = Instant::now();
    let overlay =
        Overlay::open(Arc::new(decoded), state.path(), Arc::new(Never), (1000, 1000)).unwrap();
    let open = started.elapsed();
    let last = format!("pkg{:03}/module_{:04}/src_{:02}", (files - 1) / 40_000, (files - 1) / 400, ((files - 1) / 40) % 10);
    let folder = last.split('/').fold(overlay.root(), |at, name| overlay.lookup(at, name).unwrap().ino);
    assert_eq!(overlay.readdir(folder).unwrap().len(), 40.min(files));
    Numbers { build, encode, encoded: encoded.len(), decode, open }
}

/// The process's peak resident memory (Linux), in MB.
fn peak_rss_mb() -> Option<u64> {
    let status = std::fs::read_to_string("/proc/self/status").ok()?;
    let line = status.lines().find(|line| line.starts_with("VmHWM:"))?;
    let kb: u64 = line.split_whitespace().nth(1)?.parse().ok()?;
    Some(kb / 1024)
}

#[test]
fn a_200k_file_manifest_encodes_decodes_and_opens_in_bounded_time_and_size() {
    let numbers = measure(200_000);
    eprintln!(
        "200k: build {:?}, encode {:?} ({} bytes), decode {:?}, open {:?}",
        numbers.build, numbers.encode, numbers.encoded, numbers.decode, numbers.open
    );
    // Debug builds on a shared runner: generous, but linear-time work stays far inside them.
    let total = numbers.encode + numbers.decode + numbers.open;
    assert!(total < Duration::from_secs(30), "encode + decode + open took {total:?}");
    // The prototype's 1.17 M entries encoded to 14 MB: about 12 bytes a path.
    assert!(numbers.encoded < 200_000 * 24, "{} bytes", numbers.encoded);
}

#[test]
#[ignore = "a bench: cargo test -p cmux-projection --release -- --ignored a_bench_of_a_one_and_a_half --nocapture"]
fn a_bench_of_a_one_and_a_half_million_file_manifest() {
    let files = std::env::var("CMUX_PROJECTION_BENCH_FILES")
        .ok()
        .and_then(|n| n.parse().ok())
        .unwrap_or(1_500_000);
    let before = peak_rss_mb();
    let numbers = measure(files);
    println!("| files | build | encode | encoded | decode | overlay open | peak RSS |");
    println!("|---|---|---|---|---|---|---|");
    println!(
        "| {files} | {} ms | {} ms | {:.1} MB | {} ms | {} ms | {} MB (from {} MB) |",
        numbers.build.as_millis(),
        numbers.encode.as_millis(),
        numbers.encoded as f64 / 1e6,
        numbers.decode.as_millis(),
        numbers.open.as_millis(),
        peak_rss_mb().unwrap_or(0),
        before.unwrap_or(0),
    );
}
