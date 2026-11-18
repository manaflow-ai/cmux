//! Demand reads before prefetch (RFD 0007, open question 7): with prefetch sharing the Mac's link,
//! the prototype's first-turn demand faults had p95 527 ms, against 100 ms without it. The Mac
//! here answers one ask at a time at a fixed rate, like one stream over a slow uplink, while a
//! prefetch streams a big folder; the agent's reads go on beside it.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use crate::Fetch as _;
use crate::link::{Link, Source};
use crate::manifest::{Item, Kind, Manifest};
use crate::offline_tests::attach;
use crate::overlay::Overlay;
use crate::wire::{self, Part};

/// The Mac's uplink.
const RATE_BYTES_PER_S: u64 = 20 * 1024 * 1024;
/// What each answered file costs besides its bytes.
const PER_FILE: Duration = Duration::from_millis(1);
/// One prefetched file.
const BULK_FILE: usize = 256 * 1024;
/// What an unprioritized prefetch asks for at once (the overlay's directory readahead size).
const PLAIN_BATCH_FILES: usize = 64;

/// A Mac whose every answered byte takes its time on the link; bytes made from the entry.
struct SlowMac {
    sizes: HashMap<u32, usize>,
}

impl SlowMac {
    fn bytes(&self, entry: u32) -> Option<Vec<u8>> {
        let size = *self.sizes.get(&entry)?;
        std::thread::sleep(
            PER_FILE + Duration::from_secs_f64(size as f64 / RATE_BYTES_PER_S as f64),
        );
        Some(vec![(entry % 251) as u8; size])
    }
}

impl Source for SlowMac {
    fn read(&self, entry: u32, offset: u64, len: u32) -> Part {
        match self.bytes(entry) {
            Some(bytes) => {
                let start = (offset as usize).min(bytes.len());
                let end = (start + len as usize).min(bytes.len());
                Part::ok(bytes[start..end].to_vec())
            }
            None => Part::status(wire::REFUSED),
        }
    }

    fn whole(&self, entry: u32) -> Part {
        self.bytes(entry).map_or(Part::status(wire::REFUSED), Part::ok)
    }
}

struct Run {
    p50: Duration,
    p95: Duration,
    prefetched: u64,
}

/// `reads` demand reads of small files, each in a folder of its own, while a prefetch streams
/// `bulk_files` files of 256 KiB: through [`Overlay::prefetch`] (`prioritized`) or straight
/// through the link's plain batches, as a prefetch with no priority would.
fn run(reads: usize, bulk_files: usize, prioritized: bool) -> Run {
    let mut items = Vec::new();
    for index in 0..reads {
        items.push(item(&format!("demand/d{index:04}/f.rs"), 4096));
    }
    for index in 0..bulk_files {
        items.push(item(&format!("bulk/b{:03}/f{index:05}.bin", index / 50), BULK_FILE));
    }
    let manifest = Arc::new(Manifest::build(1, items).unwrap());
    let mut sizes = HashMap::new();
    let mut demand = Vec::new();
    let mut bulk = Vec::new();
    for index in 1..manifest.len() as u32 {
        let entry = manifest.entry(index).unwrap();
        if entry.kind == Kind::File {
            sizes.insert(index, entry.size as usize);
            if manifest.path_of(index).starts_with("demand/") {
                demand.push(manifest.path_of(index));
            } else {
                bulk.push(index);
            }
        }
    }
    let mac: Arc<dyn Source + Send + Sync> = Arc::new(SlowMac { sizes });
    let link = Arc::new(Link::new(Duration::from_secs(5)));
    let _stream = attach(&link, &mac);
    let state = tempfile::tempdir().unwrap();
    let overlay =
        Arc::new(Overlay::open(manifest, state.path(), link.clone(), (1000, 1000)).unwrap());

    let done = Arc::new(AtomicBool::new(false));
    let prefetch = {
        let (overlay, done) = (overlay.clone(), done.clone());
        std::thread::spawn(move || {
            let mut brought = 0u64;
            for part in bulk.chunks(PLAIN_BATCH_FILES) {
                if done.load(Ordering::Relaxed) {
                    break;
                }
                if prioritized {
                    brought += overlay.prefetch(part);
                } else {
                    brought += link
                        .batch(part)
                        .into_iter()
                        .filter_map(Result::ok)
                        .map(|bytes| bytes.len() as u64)
                        .sum::<u64>();
                }
            }
            brought
        })
    };
    // Let the prefetch get going before the agent's first read.
    std::thread::sleep(Duration::from_millis(100));
    let mut took = Vec::with_capacity(reads);
    for path in &demand {
        let ino =
            path.split('/').fold(overlay.root(), |at, name| overlay.lookup(at, name).unwrap().ino);
        let start = Instant::now();
        assert_eq!(overlay.read(ino, 0, 4096).unwrap().len(), 4096);
        took.push(start.elapsed());
        // The agent's own time between reads.
        std::thread::sleep(Duration::from_millis(20));
    }
    done.store(true, Ordering::Relaxed);
    let prefetched = prefetch.join().unwrap();
    took.sort();
    let at = |q: f64| {
        took[((took.len() as f64 * q).ceil() as usize).saturating_sub(1).min(took.len() - 1)]
    };
    Run { p50: at(0.50), p95: at(0.95), prefetched }
}

fn item(path: &str, size: usize) -> Item {
    Item {
        path: path.into(),
        kind: Kind::File,
        mode: 0o644,
        size: size as u64,
        mtime_ns: 1,
        link: None,
    }
}

#[test]
fn demand_reads_go_before_a_prefetch_that_shares_the_link() {
    let after = run(40, 2000, true);
    eprintln!(
        "prioritized: demand p50 {:?} p95 {:?}, prefetched {} bytes",
        after.p50, after.p95, after.prefetched
    );
    assert!(after.prefetched > 0, "the prefetch ran beside the reads");
    // RFD 0007's P1 gate is a demand-fault p95 of at most 150 ms.
    assert!(after.p95 < Duration::from_millis(150), "p95 {:?}", after.p95);
}

#[test]
#[ignore = "a bench: cargo test -p cmux-projection --release -- --ignored a_bench_of_demand_reads --nocapture"]
fn a_bench_of_demand_reads_under_prefetch() {
    let before = run(200, 8000, false);
    let after = run(200, 8000, true);
    println!("| prefetch | demand p50 | demand p95 | prefetched |\n|---|---|---|---|");
    for (name, run) in [("plain batches (before)", &before), ("demand first (after)", &after)] {
        println!(
            "| {name} | {} ms | {} ms | {} MB |",
            run.p50.as_millis(),
            run.p95.as_millis(),
            run.prefetched / (1024 * 1024)
        );
    }
    println!(
        "link {} MB/s, one ask answered at a time; 200 demand reads of 4 KiB, 20 ms apart",
        RATE_BYTES_PER_S / (1024 * 1024)
    );
    assert!(after.p95 < before.p95);
}

/// `folders` folders of `per_folder` files of 64 KiB (each folder one directory readahead's worth
/// at most); the agent reads one file in each, 20 ms apart, every read the first in its folder.
/// `old_readahead` fetches each read's file with its folder's others in one batch, as the overlay
/// did; otherwise the overlay's own read runs, its readahead on the readahead thread.
fn first_reads_in_folders(folders: usize, per_folder: usize, old_readahead: bool) -> Run {
    const SIZE: usize = 64 * 1024;
    let mut items = Vec::new();
    for folder in 0..folders {
        for index in 0..per_folder {
            items.push(item(&format!("src/m{folder:03}/f{index:03}.rs"), SIZE));
        }
    }
    let manifest = Arc::new(Manifest::build(1, items).unwrap());
    let sizes: HashMap<u32, usize> = (1..manifest.len() as u32)
        .filter(|index| manifest.entry(*index).unwrap().kind == Kind::File)
        .map(|index| (index, SIZE))
        .collect();
    let mac: Arc<dyn Source + Send + Sync> = Arc::new(SlowMac { sizes });
    let link = Arc::new(Link::new(Duration::from_secs(5)));
    let _stream = attach(&link, &mac);
    let state = tempfile::tempdir().unwrap();
    let overlay = Arc::new(
        Overlay::open(manifest.clone(), state.path(), link.clone(), (1000, 1000)).unwrap(),
    );
    if !old_readahead {
        Overlay::start_readahead(&overlay);
    }
    let mut took = Vec::with_capacity(folders);
    for folder in 0..folders {
        let path = format!("src/m{folder:03}/f000.rs");
        let start = Instant::now();
        if old_readahead {
            let entry = manifest.resolve(&path).unwrap();
            let (first, siblings) = manifest.children(manifest.entry(entry).unwrap().parent);
            let batch: Vec<u32> = (first..first + siblings.len() as u32).collect();
            assert!(link.batch(&batch).into_iter().all(|answer| answer.is_ok()));
        } else {
            let ino = path
                .split('/')
                .fold(overlay.root(), |at, name| overlay.lookup(at, name).unwrap().ino);
            assert_eq!(overlay.read(ino, 0, 4096).unwrap().len(), 4096);
        }
        took.push(start.elapsed());
        std::thread::sleep(Duration::from_millis(20));
    }
    took.sort();
    let at = |q: f64| {
        took[((took.len() as f64 * q).ceil() as usize).saturating_sub(1).min(took.len() - 1)]
    };
    let prefetched = overlay.stats().prefetched_bytes;
    Run { p50: at(0.50), p95: at(0.95), prefetched }
}

#[test]
fn a_folders_readahead_never_holds_up_the_read_that_started_it() {
    let after = first_reads_in_folders(20, 64, false);
    eprintln!(
        "first read in a folder: p50 {:?} p95 {:?}, read ahead {} bytes",
        after.p50, after.p95, after.prefetched
    );
    // A whole folder's 4 MiB at 20 MB/s is 200 ms: the read waits for its own 64 KiB only.
    assert!(after.p95 < Duration::from_millis(150), "p95 {:?}", after.p95);
    assert!(after.prefetched > 0, "the folders were read ahead behind the reads");
}

#[test]
#[ignore = "a bench: cargo test -p cmux-projection --release -- --ignored a_bench_of_first_reads --nocapture"]
fn a_bench_of_first_reads_in_folders() {
    let before = first_reads_in_folders(40, 256, true);
    let after = first_reads_in_folders(40, 256, false);
    println!("| folder readahead | first read p50 | first read p95 |\n|---|---|---|");
    for (name, run) in [("with the read (before)", &before), ("after the read (after)", &after)] {
        println!("| {name} | {} ms | {} ms |", run.p50.as_millis(), run.p95.as_millis());
    }
    println!(
        "link {} MB/s; 40 folders of 256 files of 64 KiB (16 MiB, one readahead), one read each, 20 ms apart",
        RATE_BYTES_PER_S / (1024 * 1024)
    );
    assert!(after.p95 < before.p95);
}
