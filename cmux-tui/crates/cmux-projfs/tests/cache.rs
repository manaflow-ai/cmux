//! The chunk cache: version-keyed chunks, corruption, eviction and reopening.

mod common;

use cmux_projfs::cache::{chunk_count, chunk_len};
use cmux_projfs::{CHUNK, ChunkCache, ChunkKey};
use common::{TempDir, bytes, version};

fn all_files(dir: &std::path::Path) -> Vec<std::path::PathBuf> {
    let mut out = Vec::new();
    for sub in std::fs::read_dir(dir).unwrap() {
        let sub = sub.unwrap().path();
        if sub.is_dir() {
            for f in std::fs::read_dir(&sub).unwrap() {
                out.push(f.unwrap().path());
            }
        }
    }
    out
}

#[test]
fn chunk_geometry() {
    assert_eq!(chunk_count(0), 1);
    assert_eq!(chunk_count(1), 1);
    assert_eq!(chunk_count(CHUNK), 1);
    assert_eq!(chunk_count(CHUNK + 1), 2);
    assert_eq!(chunk_len(0, 0), 0);
    assert_eq!(chunk_len(CHUNK + 5, 0), CHUNK);
    assert_eq!(chunk_len(CHUNK + 5, 1), 5);
    assert_eq!(chunk_len(CHUNK + 5, 2), 0);
}

/// F1: the key covers path and version, so a changed file or another file never hits.
#[test]
fn a_new_version_or_another_file_never_hits() {
    let dir = TempDir::new("cache-f1");
    let cache = ChunkCache::open(dir.path(), 1 << 30).unwrap();
    let v1 = version(5, 100);
    let a_v1 = ChunkKey::new("a.txt", v1, 0);
    cache.put(&a_v1, b"hello").unwrap();
    assert_eq!(cache.read(&a_v1, 5, 0, 5).as_deref(), Some(&b"hello"[..]));

    for other in [
        ChunkKey::new("a.txt", version(5, 101), 0),
        ChunkKey::new("a.txt", cmux_projfs::Version { ctime_ns: 7, ..v1 }, 0),
        ChunkKey::new("a.txt", version(6, 100), 0),
        ChunkKey::new("b.txt", v1, 0),
        ChunkKey::new("a.txt", v1, 1),
    ] {
        assert_ne!(other, a_v1);
        assert_eq!(cache.read(&other, 5, 0, 5), None);
    }

    let b = ChunkKey::new("b.txt", v1, 0);
    cache.put(&b, b"world").unwrap();
    assert_eq!(cache.read(&a_v1, 5, 0, 5).as_deref(), Some(&b"hello"[..]));
    assert_eq!(cache.read(&b, 5, 0, 5).as_deref(), Some(&b"world"[..]));
    // Paths that would collide if joined naively stay apart.
    let k1 = ChunkKey::new("ab", version(1, 2), 3);
    let k2 = ChunkKey::new("a", version(1, 2), 3);
    assert_ne!(k1, k2);
}

#[test]
fn ranges_and_wrong_length_expectations() {
    let dir = TempDir::new("cache-range");
    let cache = ChunkCache::open(dir.path(), 1 << 30).unwrap();
    let data = bytes(3, 1000);
    let k = ChunkKey::new("f", version(1000, 1), 0);
    cache.put(&k, &data).unwrap();
    assert_eq!(cache.read(&k, 1000, 10, 20).unwrap(), &data[10..30]);
    assert_eq!(cache.read(&k, 1000, 990, 50).unwrap(), &data[990..], "clamped at the end");
    // A caller expecting another length treats it as a miss, and the chunk is dropped.
    assert_eq!(cache.read(&k, 999, 0, 10), None);
    assert!(!cache.contains(&k));
}

#[test]
fn short_or_corrupt_chunk_files_are_misses_and_removed() {
    let dir = TempDir::new("cache-corrupt");
    let short = ChunkKey::new("short", version(100, 1), 0);
    let flipped = ChunkKey::new("flipped", version(100, 1), 0);
    {
        let cache = ChunkCache::open(dir.path(), 1 << 30).unwrap();
        cache.put(&short, &bytes(1, 100)).unwrap();
        cache.put(&flipped, &bytes(2, 100)).unwrap();
    }
    for f in all_files(dir.path()) {
        let name = f.file_name().unwrap().to_str().unwrap().to_owned();
        let mut raw = std::fs::read(&f).unwrap();
        if name == short.hex() {
            raw.truncate(raw.len() - 1);
        } else if name == flipped.hex() {
            let last = raw.len() - 1;
            raw[last] ^= 0xff;
        }
        std::fs::write(&f, raw).unwrap();
    }
    let cache = ChunkCache::open(dir.path(), 1 << 30).unwrap();
    assert_eq!(cache.read(&short, 100, 0, 100), None);
    assert_eq!(cache.read(&flipped, 100, 0, 100), None);
    assert!(!cache.contains(&short) && !cache.contains(&flipped));
    assert!(all_files(dir.path()).is_empty(), "bad chunk files are deleted");
}

#[test]
fn eviction_keeps_the_cache_under_its_bound_least_recently_used_first() {
    let dir = TempDir::new("cache-evict");
    // Room for three 1000-byte chunks with their headers, not four.
    let cache = ChunkCache::open(dir.path(), 3 * 1048 + 100).unwrap();
    let keys: Vec<ChunkKey> =
        (0..4).map(|i| ChunkKey::new(&format!("f{i}"), version(1000, 1), 0)).collect();
    for k in &keys[..3] {
        cache.put(k, &bytes(0, 1000)).unwrap();
    }
    // Touch the first so the second is the least recently used.
    assert!(cache.read(&keys[0], 1000, 0, 1).is_some());
    cache.put(&keys[3], &bytes(0, 1000)).unwrap();
    assert!(cache.contains(&keys[0]));
    assert!(!cache.contains(&keys[1]), "least recently used is evicted");
    assert!(cache.contains(&keys[2]) && cache.contains(&keys[3]));
    assert!(cache.usage().bytes <= cache.max_bytes());
    assert_eq!(all_files(dir.path()).len(), 3);
    // A chunk bigger than the whole cache is not stored.
    let huge = ChunkKey::new("huge", version(5000, 1), 0);
    assert!(!cache.put(&huge, &bytes(0, 5000)).unwrap());
}

#[test]
fn survives_reopen_and_shrinks_to_a_smaller_bound() {
    let dir = TempDir::new("cache-reopen");
    let keys: Vec<ChunkKey> =
        (0..3).map(|i| ChunkKey::new(&format!("f{i}"), version(1000, 1), 0)).collect();
    {
        let cache = ChunkCache::open(dir.path(), 1 << 30).unwrap();
        for (i, k) in keys.iter().enumerate() {
            cache.put(k, &bytes(i as u8, 1000)).unwrap();
        }
    }
    // A stray temporary file from a crash mid-write is cleaned up.
    let stray_dir = all_files(dir.path())[0].parent().unwrap().to_owned();
    std::fs::write(stray_dir.join("deadbeef.tmp"), b"partial").unwrap();
    let cache = ChunkCache::open(dir.path(), 1 << 30).unwrap();
    for (i, k) in keys.iter().enumerate() {
        assert_eq!(cache.read(k, 1000, 0, 1000).unwrap(), bytes(i as u8, 1000));
    }
    assert!(!stray_dir.join("deadbeef.tmp").exists());
    drop(cache);
    let small = ChunkCache::open(dir.path(), 2 * 1048).unwrap();
    assert_eq!(small.usage().chunks, 2);
    assert!(small.usage().bytes <= 2 * 1048);
}

#[test]
fn a_full_chunk_round_trips() {
    let dir = TempDir::new("cache-full");
    let cache = ChunkCache::open(dir.path(), 1 << 30).unwrap();
    let data = bytes(9, CHUNK as usize);
    let k = ChunkKey::new("big", version(CHUNK * 2, 1), 1);
    cache.put(&k, &data).unwrap();
    assert_eq!(cache.read(&k, CHUNK, CHUNK - 10, 100).unwrap(), &data[(CHUNK - 10) as usize..]);
}
