//! The read path over an in-memory source.

mod common;

use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_projfs::{CHUNK, Config, Core, Got, ReadError};
use common::{MemSource, T0, TempDir, bytes, core_for, file_stat, quiet_config};

fn idx(core: &Core, path: &str) -> u32 {
    core.manifest().resolve(path).unwrap_or_else(|| panic!("{path} not in manifest"))
}

/// Records every invalidated index.
fn record_invalidations(core: &Core) -> Arc<Mutex<Vec<u32>>> {
    let seen = Arc::new(Mutex::new(Vec::new()));
    let sink = seen.clone();
    core.set_invalidate(Some(Arc::new(move |i| sink.lock().unwrap().push(i))));
    seen
}

#[test]
fn concurrent_readers_of_one_chunk_share_one_fetch() {
    let src = MemSource::new();
    let data = bytes(1, 300_000);
    src.put("solo/big.bin", file_stat(data.len(), T0), data.clone());
    let dir = TempDir::new("core-share");
    let core = core_for(&src, dir.path(), quiet_config());
    let i = idx(&core, "solo/big.bin");
    src.close_gate();
    let readers = 8;
    let handles: Vec<_> = (0..readers)
        .map(|n| {
            let core = core.clone();
            std::thread::spawn(move || core.read(i, n * 1000, 5000).unwrap())
        })
        .collect();
    // Bounded wait for every other reader to be parked on the first reader's fetch.
    let deadline = Instant::now() + Duration::from_secs(5);
    while core.stats().shared_waits < readers - 1 && Instant::now() < deadline {
        std::thread::yield_now();
    }
    src.open_gate();
    for (n, h) in handles.into_iter().enumerate() {
        let start = n * 1000;
        assert_eq!(h.join().unwrap(), &data[start..start + 5000]);
    }
    assert_eq!(src.fetches(), 1, "one fetch for all readers");
    assert_eq!(core.stats().shared_waits, readers - 1);
    assert_eq!(core.stats().round_trips, 1);
}

#[test]
fn a_fault_batches_the_directory_within_its_bounds() {
    let src = MemSource::new();
    for n in 0..10u8 {
        src.put(&format!("dir/f{n}.txt"), file_stat(100, T0), bytes(n, 100));
    }
    src.put("dir/big.bin", file_stat(CHUNK as usize + 1, T0), bytes(99, CHUNK as usize + 1));
    src.put("dir/empty", file_stat(0, T0), Vec::new());
    src.put("dir/sub/inner.txt", file_stat(10, T0), bytes(7, 10));
    src.put("other/x.txt", file_stat(10, T0), bytes(8, 10));
    let dir = TempDir::new("core-batch");
    let config = Config { batch_files: 4, ..quiet_config() };
    let core = core_for(&src, dir.path(), config);

    assert_eq!(core.read(idx(&core, "dir/f5.txt"), 0, 4096).unwrap(), bytes(5, 100));
    let wants = src.wants();
    assert_eq!(wants.len(), 1);
    let asked: Vec<&str> = wants[0].iter().map(|w| w.path.as_str()).collect();
    assert_eq!(
        asked,
        ["dir/f5.txt", "dir/f0.txt", "dir/f1.txt", "dir/f2.txt"],
        "faulting file first, bounded count"
    );
    assert!(wants[0].iter().all(|w| w.len == 100));

    // A batched sibling is now a hit; the directory is not batched a second time.
    assert_eq!(core.read(idx(&core, "dir/f1.txt"), 0, 100).unwrap(), bytes(1, 100));
    assert_eq!(src.fetches(), 1);
    assert_eq!(core.read(idx(&core, "dir/f9.txt"), 0, 100).unwrap(), bytes(9, 100));
    assert_eq!(src.wants()[1].len(), 1, "one batch per directory");

    // The byte bound: a directory of 100-byte files with a 250-byte bound asks for two.
    let src2 = MemSource::new();
    for n in 0..5u8 {
        src2.put(&format!("d/f{n}"), file_stat(100, T0), bytes(n, 100));
    }
    let dir2 = TempDir::new("core-batch-bytes");
    let core2 = core_for(&src2, dir2.path(), Config { batch_bytes: 250, ..quiet_config() });
    core2.read(idx(&core2, "d/f0"), 0, 100).unwrap();
    assert_eq!(src2.wants()[0].len(), 2, "bounded by bytes");
}

/// F3: a file changed on the Mac gives the new bytes, not a permanent error.
#[test]
fn a_changed_file_is_read_at_its_new_version() {
    let src = MemSource::new();
    src.put("a.txt", file_stat(5, T0), b"old!!".to_vec());
    let dir = TempDir::new("core-changed");
    let core = core_for(&src, dir.path(), quiet_config());
    let seen = record_invalidations(&core);
    let i = idx(&core, "a.txt");

    let new = b"brand new contents".to_vec();
    src.put("a.txt", file_stat(new.len(), T0 + 1), new.clone());
    assert_eq!(core.read(i, 0, 4096).unwrap(), new);
    assert_eq!(*seen.lock().unwrap(), vec![i], "invalidated once");
    assert_eq!(core.manifest().entry(i).unwrap().stat.size, new.len() as u64);
    assert_eq!(core.stats().changed, 1);
    assert_eq!(src.fetches(), 2, "the stale ask, then the retry");

    // The new version is cached; reading again does not fetch.
    assert_eq!(core.read(i, 6, 3).unwrap(), &new[6..9]);
    assert_eq!(src.fetches(), 2);

    // A delta pushed by the Mac before any fault is applied the same way.
    let newer = b"third".to_vec();
    src.put("a.txt", file_stat(newer.len(), T0 + 2), newer.clone());
    core.apply_delta("a.txt", cmux_projfs::Delta::Stat(file_stat(newer.len(), T0 + 2))).unwrap();
    assert_eq!(seen.lock().unwrap().len(), 2);
    assert_eq!(core.read(i, 0, 100).unwrap(), newer);
    assert_eq!(core.stats().changed, 1, "no stale ask after the delta");
}

#[test]
fn a_file_that_keeps_changing_fails_one_read_only() {
    let src = MemSource::new();
    src.put("a", file_stat(3, T0), b"abc".to_vec());
    let dir = TempDir::new("core-flapping");
    let core = core_for(&src, dir.path(), quiet_config());
    let i = idx(&core, "a");
    src.script("a", Got::Changed(file_stat(4, T0 + 1)));
    src.script("a", Got::Changed(file_stat(5, T0 + 2)));
    src.put("a", file_stat(5, T0 + 2), b"abcde".to_vec());
    assert!(matches!(core.read(i, 0, 10), Err(ReadError::Io(_))));
    assert_eq!(core.read(i, 0, 10).unwrap(), b"abcde");
}

#[test]
fn away_then_back_within_the_bound_succeeds() {
    let src = MemSource::new();
    src.put("a", file_stat(3, T0), b"abc".to_vec());
    let dir = TempDir::new("core-away-back");
    let config = Config {
        away_wait: Duration::from_secs(10),
        away_retry: Duration::from_secs(10),
        ..quiet_config()
    };
    let core = core_for(&src, dir.path(), config);
    let i = idx(&core, "a");
    src.away.store(true, Ordering::SeqCst);
    let reader = {
        let core = core.clone();
        std::thread::spawn(move || core.read(i, 0, 3))
    };
    let deadline = Instant::now() + Duration::from_secs(5);
    while core.stats().away == 0 && Instant::now() < deadline {
        std::thread::yield_now();
    }
    src.away.store(false, Ordering::SeqCst);
    let back = Instant::now();
    core.source_back();
    assert_eq!(reader.join().unwrap().unwrap(), b"abc");
    assert!(back.elapsed() < Duration::from_secs(5), "woken by source_back, not the retry timer");
    assert_eq!(core.stats().away, 1);
}

#[test]
fn away_past_the_bound_is_host_down_then_a_later_read_succeeds() {
    let src = MemSource::new();
    src.put("a", file_stat(3, T0), b"abc".to_vec());
    let dir = TempDir::new("core-away-down");
    let core = core_for(&src, dir.path(), quiet_config());
    let i = idx(&core, "a");
    src.away.store(true, Ordering::SeqCst);
    let started = Instant::now();
    let err = core.read(i, 0, 3).unwrap_err();
    assert_eq!(err, ReadError::HostDown);
    assert_eq!(err.errno(), libc::EHOSTDOWN);
    assert!(started.elapsed() >= Duration::from_millis(300));
    assert!(core.stats().away >= 2, "it asked again while waiting");
    src.away.store(false, Ordering::SeqCst);
    assert_eq!(core.read(i, 0, 3).unwrap(), b"abc");
}

#[test]
fn withheld_gone_and_failed_map_to_their_errors() {
    let src = MemSource::new();
    let mut secret = file_stat(4, T0);
    secret.withheld = true;
    src.put("a/secret.key", secret, b"keys".to_vec());
    src.put("b/later-secret", file_stat(4, T0), b"abcd".to_vec());
    src.put("c/vanishes", file_stat(4, T0), b"abcd".to_vec());
    src.put("d/flaky", file_stat(4, T0), b"abcd".to_vec());
    let dir = TempDir::new("core-errors");
    let core = core_for(&src, dir.path(), quiet_config());
    let seen = record_invalidations(&core);

    let err = core.read(idx(&core, "a/secret.key"), 0, 4).unwrap_err();
    assert_eq!((err.clone(), err.errno()), (ReadError::Withheld, libc::EACCES));
    assert_eq!(src.fetches(), 0, "a withheld file never asks the Mac");

    src.script("b/later-secret", Got::Withheld);
    let later = idx(&core, "b/later-secret");
    assert_eq!(core.read(later, 0, 4), Err(ReadError::Withheld));
    assert!(core.manifest().entry(later).unwrap().stat.withheld);

    let gone = idx(&core, "c/vanishes");
    src.remove("c/vanishes");
    let err = core.read(gone, 0, 4).unwrap_err();
    assert_eq!((err.clone(), err.errno()), (ReadError::NotFound, libc::ENOENT));
    assert_eq!(core.manifest().resolve("c/vanishes"), None, "marked gone");
    assert!(seen.lock().unwrap().contains(&gone));

    src.script("d/flaky", Got::Failed("disk error".into()));
    let flaky = idx(&core, "d/flaky");
    let err = core.read(flaky, 0, 4).unwrap_err();
    assert!(matches!(&err, ReadError::Io(m) if m.contains("disk error")));
    assert_eq!(err.errno(), libc::EIO);
    assert_eq!(core.read(flaky, 0, 4).unwrap(), b"abcd", "the next read asks again");

    src.script("d/flaky", Got::Bytes(b"ab".to_vec()));
    let src_dir = TempDir::new("core-errors-short");
    let fresh = core_for(&src, src_dir.path(), quiet_config());
    assert!(
        matches!(fresh.read(idx(&fresh, "d/flaky"), 0, 4), Err(ReadError::Io(_))),
        "short answer"
    );
}

#[test]
fn eof_zero_length_and_directories() {
    let src = MemSource::new();
    src.put("d/empty", file_stat(0, T0), Vec::new());
    src.put("d/five", file_stat(5, T0), b"12345".to_vec());
    let dir = TempDir::new("core-eof");
    let core = core_for(&src, dir.path(), quiet_config());
    assert_eq!(core.read(idx(&core, "d/empty"), 0, 100).unwrap(), b"");
    assert_eq!(src.fetches(), 0, "an empty file needs no fetch");
    let five = idx(&core, "d/five");
    assert_eq!(core.read(five, 5, 10).unwrap(), b"");
    assert_eq!(core.read(five, 1000, 10).unwrap(), b"");
    assert_eq!(core.read(five, 3, 100).unwrap(), b"45");
    assert_eq!(core.read(five, 0, 0).unwrap(), b"");
    assert_eq!(core.read(idx(&core, "d"), 0, 1), Err(ReadError::NotAFile));
    assert_eq!(core.read(9999, 0, 1), Err(ReadError::NotFound));
}

#[test]
fn a_nine_mib_file_reads_across_chunk_boundaries() {
    let src = MemSource::new();
    let size = 9 << 20;
    let data = bytes(42, size);
    src.put("big.bin", file_stat(size, T0), data.clone());
    let dir = TempDir::new("core-9mib");
    let core = core_for(&src, dir.path(), quiet_config());
    let i = idx(&core, "big.bin");
    let c = CHUNK as usize;
    for (off, len) in
        [(c - 10, 20), (2 * c - 1, 2), (size - 5, 100), (0, c), (c, c), (2 * c, size - 2 * c)]
    {
        let got = core.read(i, off as u64, len as u32).unwrap();
        assert_eq!(got, &data[off..(off + len).min(size)], "read at {off}+{len}");
    }
    assert_eq!(src.fetches(), 3, "each chunk fetched once");
    assert!(src.wants().iter().flatten().all(|w| w.offset % CHUNK == 0));
    assert_eq!(src.wants().iter().flatten().map(|w| w.len as usize).sum::<usize>(), size);
    let all = core.read(i, 0, size as u32).unwrap();
    assert_eq!(all, data);
    assert_eq!(src.fetches(), 3);
    assert!(core.stats().hits >= 2);
}

#[test]
fn a_big_file_reads_two_chunks_ahead() {
    let src = MemSource::new();
    let size = 5 * CHUNK as usize;
    src.put("big.bin", file_stat(size, T0), bytes(3, size));
    let dir = TempDir::new("core-ahead");
    let core = core_for(&src, dir.path(), Config::default());
    let i = idx(&core, "big.bin");
    core.read(i, 0, 10).unwrap();
    // The read-ahead runs on its own thread; a read of chunk 2 either hits or joins its fetch.
    core.read(i, 2 * CHUNK, 10).unwrap();
    let offsets: std::collections::BTreeSet<u64> =
        src.wants().iter().flatten().map(|w| w.offset / CHUNK).collect();
    assert!(offsets.is_superset(&[0, 1, 2].into()), "{offsets:?}");
    let chunk2_asks = src.wants().iter().flatten().filter(|w| w.offset == 2 * CHUNK).count();
    assert_eq!(chunk2_asks, 1, "chunk 2 came from the read-ahead, not a second fetch");
}

#[test]
fn the_cache_outlives_the_core() {
    let src = MemSource::new();
    src.put("a", file_stat(3, T0), b"abc".to_vec());
    let dir = TempDir::new("core-reopen");
    {
        let core = core_for(&src, dir.path(), quiet_config());
        core.read(idx(&core, "a"), 0, 3).unwrap();
    }
    let core = core_for(&src, dir.path(), quiet_config());
    assert_eq!(core.read_cached(idx(&core, "a"), 0, 3).unwrap(), b"abc");
    assert_eq!(src.fetches(), 1, "the second session faulted nothing");
}
