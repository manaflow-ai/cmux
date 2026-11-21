use super::*;

fn kept(read: u64) -> Kept {
    let stamp = Stamp { size: 1, modified: None, node: Node::default() };
    Kept { stamp, hash: [0; 32], settled: true, read }
}

/// Two work trees are checked in turn. Read 3 is of the second one: it used `a1` again,
/// and it will come to `a2`, which its read before (2) hashed. `b1` and `b2` are of the
/// other work tree's read (1), which is longer ago.
#[test]
fn git_fingerprint_drops_the_hashes_of_the_oldest_read_when_its_cache_is_full() {
    let mut cache = Cache::default();
    for (name, read) in [("b1", 1), ("b2", 1), ("a1", 3), ("a2", 2)] {
        cache.keep(Path::new(name), kept(read), 4);
    }
    cache.keep(Path::new("new"), kept(3), 4);
    let mut names: Vec<_> =
        cache.files.keys().map(|path| path.to_string_lossy().into_owned()).collect();
    names.sort();
    assert_eq!(
        names,
        ["a1", "a2", "new"],
        "a full cache must drop the read that is longest ago, and keep the hash that the \
             current read comes to next"
    );
}
