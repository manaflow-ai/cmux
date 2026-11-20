//! The chunk cache: version-keyed chunks, corruption, eviction and reopening (from Austin's
//! `cmux-projfs` cache tests).

use super::*;

const HEADED: u64 = 1000 + HEADER;

fn bytes(seed: u8, len: usize) -> Vec<u8> {
    (0..len).map(|at| (at as u8).wrapping_add(seed)).collect()
}

fn all_files(dir: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    for sub in fs::read_dir(dir).unwrap() {
        let sub = sub.unwrap().path();
        if sub.is_dir() {
            for file in fs::read_dir(&sub).unwrap() {
                out.push(file.unwrap().path());
            }
        }
    }
    out
}

#[test]
fn a_new_version_or_another_file_never_hits() {
    let dir = tempfile::tempdir().unwrap();
    let cache = ChunkCache::open(dir.path(), Some(1 << 30)).unwrap();
    let a = ChunkKey::new("a.txt", 5, 100, 0);
    cache.put(&a, b"hello").unwrap();
    assert_eq!(cache.read(&a, 5, 0, 5).as_deref(), Some(&b"hello"[..]));
    for other in [
        ChunkKey::new("a.txt", 5, 101, 0),
        ChunkKey::new("a.txt", 6, 100, 0),
        ChunkKey::new("b.txt", 5, 100, 0),
        ChunkKey::new("a.txt", 5, 100, 1),
    ] {
        assert_ne!(other, a);
        assert_eq!(cache.read(&other, 5, 0, 5), None);
    }
    // Paths that would collide if joined naively stay apart.
    assert_ne!(ChunkKey::new("ab", 1, 2, 3), ChunkKey::new("a", 1, 2, 3));
    assert_eq!(ChunkKey::from_hex(&a.hex()), Some(a));
}

#[test]
fn ranges_and_wrong_length_expectations() {
    let dir = tempfile::tempdir().unwrap();
    let cache = ChunkCache::open(dir.path(), Some(1 << 30)).unwrap();
    let data = bytes(3, 1000);
    let key = ChunkKey::new("f", 1000, 1, 0);
    cache.put(&key, &data).unwrap();
    assert_eq!(cache.read(&key, 1000, 10, 20).unwrap(), &data[10..30]);
    assert_eq!(cache.read(&key, 1000, 990, 50).unwrap(), &data[990..], "clamped at the end");
    // A caller expecting another length treats it as a miss, and the chunk is dropped.
    assert_eq!(cache.read(&key, 999, 0, 10), None);
    assert!(!cache.contains(&key));
}

#[test]
fn short_or_corrupt_chunk_files_are_misses_and_removed() {
    let dir = tempfile::tempdir().unwrap();
    let short = ChunkKey::new("short", 100, 1, 0);
    let flipped = ChunkKey::new("flipped", 100, 1, 0);
    {
        let cache = ChunkCache::open(dir.path(), Some(1 << 30)).unwrap();
        cache.put(&short, &bytes(1, 100)).unwrap();
        cache.put(&flipped, &bytes(2, 100)).unwrap();
    }
    for file in all_files(dir.path()) {
        let name = file.file_name().unwrap().to_str().unwrap().to_owned();
        let mut raw = fs::read(&file).unwrap();
        if name == short.hex() {
            raw.truncate(raw.len() - 1);
        } else if name == flipped.hex() {
            *raw.last_mut().unwrap() ^= 0xff;
        }
        fs::write(&file, raw).unwrap();
    }
    let cache = ChunkCache::open(dir.path(), Some(1 << 30)).unwrap();
    assert_eq!(cache.read(&short, 100, 0, 100), None);
    assert_eq!(cache.read(&flipped, 100, 0, 100), None);
    assert!(!cache.contains(&short) && !cache.contains(&flipped));
    assert!(all_files(dir.path()).is_empty(), "bad chunk files are deleted");
}

#[test]
fn eviction_keeps_the_cache_under_its_bound_least_recently_used_first() {
    let dir = tempfile::tempdir().unwrap();
    // Room for three 1000-byte chunks with their headers, not four.
    let cache = ChunkCache::open(dir.path(), Some(3 * HEADED + 100)).unwrap();
    let keys: Vec<ChunkKey> =
        (0..4).map(|at| ChunkKey::new(&format!("f{at}"), 1000, 1, 0)).collect();
    for key in &keys[..3] {
        cache.put(key, &bytes(0, 1000)).unwrap();
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
    let huge = ChunkKey::new("huge", 5000, 1, 0);
    assert!(!cache.put(&huge, &bytes(0, 5000)).unwrap());
}

#[test]
fn survives_reopen_and_shrinks_to_a_smaller_bound() {
    let dir = tempfile::tempdir().unwrap();
    let keys: Vec<ChunkKey> =
        (0..3).map(|at| ChunkKey::new(&format!("f{at}"), 1000, 1, 0)).collect();
    {
        let cache = ChunkCache::open(dir.path(), Some(1 << 30)).unwrap();
        for (at, key) in keys.iter().enumerate() {
            cache.put(key, &bytes(at as u8, 1000)).unwrap();
        }
    }
    // A stray temporary file from a crash mid-write is cleaned up.
    let stray_dir = all_files(dir.path())[0].parent().unwrap().to_owned();
    fs::write(stray_dir.join("deadbeef.tmp"), b"partial").unwrap();
    let cache = ChunkCache::open(dir.path(), Some(1 << 30)).unwrap();
    for (at, key) in keys.iter().enumerate() {
        assert_eq!(cache.read(key, 1000, 0, 1000).unwrap(), bytes(at as u8, 1000));
    }
    assert!(!stray_dir.join("deadbeef.tmp").exists());
    drop(cache);
    let small = ChunkCache::open(dir.path(), Some(2 * HEADED)).unwrap();
    assert_eq!(small.usage().chunks, 2);
    assert!(small.usage().bytes <= 2 * HEADED);
    assert_eq!(all_files(dir.path()).len(), 2);
}

#[test]
fn the_default_bound_is_at_most_8_gib_and_a_quarter_of_the_free_disk() {
    let dir = tempfile::tempdir().unwrap();
    let cache = ChunkCache::open(dir.path(), None).unwrap();
    assert!(cache.max_bytes() <= DEFAULT_MAX_BYTES);
    if let Some(free) = available_bytes(dir.path()) {
        // The disk may have freed a little between the two reads.
        assert!(cache.max_bytes() <= free / 4 + 64 * 1024 * 1024);
        assert!(cache.max_bytes() > 0);
    }
}

#[test]
fn a_full_chunk_round_trips() {
    let dir = tempfile::tempdir().unwrap();
    let cache = ChunkCache::open(dir.path(), Some(1 << 30)).unwrap();
    let data = bytes(9, CHUNK as usize);
    let key = ChunkKey::new("big", CHUNK * 2, 1, 1);
    cache.put(&key, &data).unwrap();
    assert_eq!(cache.read(&key, CHUNK, CHUNK - 10, 100).unwrap(), &data[(CHUNK - 10) as usize..]);
}
