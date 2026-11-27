use super::*;

use std::collections::HashMap;

use super::super::content::{Content, Name, hash_of};

fn env(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
    let map: HashMap<String, String> =
        pairs.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect();
    move |name: &str| map.get(name).cloned()
}

fn noise(len: usize, seed: u64) -> Vec<u8> {
    let mut state = seed | 1;
    (0..len)
        .map(|_| {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            state.to_le_bytes()[0]
        })
        .collect()
}

fn name(path: &str, size: usize) -> Name {
    Name { path: path.to_owned(), size: size as u64, mtime_ns: 1, part: 0 }
}

/// A machine's disk store reading through to the shared folder `root`.
fn machine(state: &Path, root: &Path, team: &str, publish: bool) -> Content {
    let content = Content::open(state).unwrap();
    content.set_floor(0);
    content.with_shared(Some(Arc::new(Dir::new(root, team, publish))))
}

fn files_under(root: &Path) -> usize {
    let Ok(entries) = fs::read_dir(root) else { return 0 };
    entries
        .filter_map(Result::ok)
        .map(|entry| if entry.path().is_dir() { files_under(&entry.path()) } else { 1 })
        .sum()
}

#[test]
fn the_switch_is_off_by_default() {
    assert!(from_lookup(&env(&[])).unwrap().is_none());
    for off in ["", "0", "off"] {
        assert!(from_lookup(&env(&[(SWITCH, off), (TEAM, "t")])).unwrap().is_none());
    }
    // On: a team is required, the folder is absolute, and it only reads unless told to publish.
    assert!(from_lookup(&env(&[(SWITCH, "dir:/srv/blobs")])).is_err());
    assert!(from_lookup(&env(&[(SWITCH, "dir:/srv/blobs"), (TEAM, "../x")])).is_err());
    assert!(from_lookup(&env(&[(SWITCH, "dir:blobs"), (TEAM, "t")])).is_err());
    let read_only = from_lookup(&env(&[(SWITCH, "dir:/srv/blobs"), (TEAM, "t")])).unwrap().unwrap();
    assert!(!read_only.publishes());
    let publishing =
        from_lookup(&env(&[(SWITCH, "dir:/srv/blobs"), (TEAM, "t"), (PUBLISH, "1")])).unwrap();
    assert!(publishing.unwrap().publishes());
    // A team bucket is a stub that names what it lacks; it never falls back to anything.
    let bucket = from_lookup(&env(&[(SWITCH, "bucket"), (TEAM, "t")])).err().unwrap();
    assert!(bucket.contains("missing") && bucket.contains("team bucket"), "{bucket}");
}

#[test]
fn a_second_machine_reads_a_blob_through_once() {
    let dir = tempfile::tempdir().unwrap();
    let shared = dir.path().join("shared");
    let first = machine(&dir.path().join("a"), &shared, "team", true);
    let bytes = noise(10_000, 1);
    let hash = first.put(name("src/a.rs", bytes.len()), &bytes).unwrap();
    assert_eq!(files_under(&shared.join("team")), 1);

    let second = machine(&dir.path().join("b"), &shared, "team", false);
    assert_eq!(second.fetch(&hash).unwrap(), bytes);
    assert_eq!(second.transfer(), Transfer { hits: 1, fetched: 10_000, reused: 0 });
    // Kept on its disk: the next read fetches nothing.
    assert_eq!(second.fetch(&hash).unwrap(), bytes);
    assert_eq!(second.transfer().fetched, 10_000);
    // Another team's machine finds nothing.
    let other = machine(&dir.path().join("c"), &shared, "other", false);
    assert!(other.fetch(&hash).is_none());
}

#[test]
fn a_read_only_machine_publishes_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let shared = dir.path().join("shared");
    let reader = machine(&dir.path().join("a"), &shared, "team", false);
    let big = noise(2 * 1024 * 1024, 2);
    reader.put(name("big.bin", big.len()), &big).unwrap();
    reader.put(name("small", 3), b"abc").unwrap();
    assert_eq!(files_under(&shared), 0);
    // And with no shared store at all, a miss is a miss.
    let alone = Content::open(&dir.path().join("b")).unwrap();
    assert!(alone.fetch(&hash_of(b"abc")).is_none());
}

/// RFD 0065 pieces 12 and 13 together: a machine a day behind holds yesterday's version of a
/// big file; today's differs by an insert, so it fetches only the chunks around it.
#[test]
fn a_machine_a_day_behind_fetches_only_the_changed_chunks() {
    let dir = tempfile::tempdir().unwrap();
    let shared = dir.path().join("shared");
    let publisher = machine(&dir.path().join("a"), &shared, "team", true);
    let yesterday = noise(4 * 1024 * 1024, 3);
    let mut today = yesterday.clone();
    today.splice(1_500_000..1_500_000, noise(300, 4));
    publisher.put(name("big.bin", yesterday.len()), &yesterday).unwrap();
    let hash = publisher.put(name("big.bin", today.len()), &today).unwrap();

    let behind_state = dir.path().join("b");
    let behind = machine(&behind_state, &shared, "team", false);
    behind.put(name("big.bin", yesterday.len()), &yesterday).unwrap();
    assert_eq!(behind.fetch(&hash).unwrap(), today);
    let moved = behind.transfer();
    assert_eq!(moved.fetched + moved.reused, today.len() as u64);
    assert!(moved.fetched < 512 * 1024, "fetched {} of {}", moved.fetched, today.len());
    eprintln!(
        "a day behind: fetched {} of {} bytes ({:.1}%), reused {}",
        moved.fetched,
        today.len(),
        100.0 * moved.fetched as f64 / today.len() as f64,
        moved.reused
    );

    // The recipes survive a restart: a new daemon on the same disk reuses as much.
    let mut edited = today.clone();
    edited.splice(3_000_000..3_000_000, noise(50, 5));
    let edited_hash = publisher.put(name("big.bin", edited.len()), &edited).unwrap();
    drop(behind);
    let restarted = machine(&behind_state, &shared, "team", false);
    assert_eq!(restarted.fetch(&edited_hash).unwrap(), edited);
    assert!(restarted.transfer().fetched < 512 * 1024);
}

#[test]
fn damaged_shared_bytes_are_never_served() {
    let dir = tempfile::tempdir().unwrap();
    let shared = dir.path().join("shared");
    let publisher = machine(&dir.path().join("a"), &shared, "team", true);
    let small = noise(5_000, 6);
    let small_hash = publisher.put(name("s", small.len()), &small).unwrap();
    let big = noise(2 * 1024 * 1024, 7);
    let big_hash = publisher.put(name("b", big.len()), &big).unwrap();
    // Flip one byte in every object the store holds.
    fn damage(root: &Path) {
        for entry in fs::read_dir(root).unwrap().filter_map(Result::ok) {
            if entry.path().is_dir() {
                damage(&entry.path());
            } else {
                let mut bytes = fs::read(entry.path()).unwrap();
                let last = bytes.len() - 1;
                bytes[last] ^= 1;
                fs::write(entry.path(), bytes).unwrap();
            }
        }
    }
    damage(&shared);
    let reader = machine(&dir.path().join("b"), &shared, "team", false);
    assert!(reader.fetch(&small_hash).is_none());
    assert!(reader.fetch(&big_hash).is_none());
    assert_eq!(reader.transfer().hits, 0);
}

#[test]
fn recipes_round_trip_and_refuse_wrong_sizes() {
    let chunks = vec![([1u8; 32], 10u32), ([2u8; 32], 20u32)];
    let bytes = encode_recipe(30, &chunks);
    assert_eq!(decode_recipe(&bytes), Some((30, chunks.clone())));
    assert_eq!(decode_recipe(&encode_recipe(31, &chunks)), None);
    assert_eq!(decode_recipe(b"not a recipe"), None);
    assert_eq!(decode_recipe(&bytes[..bytes.len() - 1]), None);
}
