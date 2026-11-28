use super::*;

fn file(path: &str, size: u64) -> Item {
    Item { path: path.into(), kind: Kind::File, mode: 0o644, size, mtime_ns: 7, link: None }
}

fn base() -> Manifest {
    let mut m = Manifest::build(
        1,
        vec![file("src/a.rs", 2), file("src/b.rs", 3), file("README.md", 10), file("old/x", 1)],
    )
    .unwrap();
    let a = m.resolve("src/a.rs").unwrap();
    m.set_hash(a, [1; 32]).unwrap();
    let b = m.resolve("src/b.rs").unwrap();
    m.keep_home(b, "a key").unwrap();
    m
}

#[test]
fn hashes_survive_the_wire_and_an_older_decoder_still_reads_the_listing() {
    let m = base();
    assert_eq!(m.hashed_count(), 1);
    let back = Manifest::decode(&m.encode().unwrap()).unwrap();
    assert_eq!(back, m);
    assert_eq!(back.hash(back.resolve("src/a.rs").unwrap()), Some(&[1; 32]));
    // What a machine from before hashes reads: the entries and the kept files, then leaves the
    // rest.
    let raw = bincode::serialize(&m).unwrap();
    let old: (Vec<crate::manifest::Entry>, BTreeMap<u32, String>) =
        bincode::deserialize(&raw).unwrap();
    assert_eq!(old.0.len(), m.len());
    assert_eq!(old.1.len(), 1);
    // A Mac from before hashes (entries and kept only) is read by this machine.
    let bytes = zstd::encode_all(bincode::serialize(&old).unwrap().as_slice(), 3).unwrap();
    let from_old = Manifest::decode(&bytes).unwrap();
    assert_eq!(from_old.hashed_count(), 0);
    assert_eq!(from_old.kept_count(), 1);
}

#[test]
fn a_hash_on_a_folder_is_refused() {
    let mut m = base();
    let dir = m.resolve("src").unwrap();
    assert!(m.set_hash(dir, [0; 32]).is_err());
}

#[test]
fn a_patch_turns_the_old_listing_into_the_new_one() {
    let old = base();
    let mut new = Manifest::build(
        1,
        vec![file("src/a.rs", 5), file("src/b.rs", 3), file("README.md", 10), file("new/y/z", 4)],
    )
    .unwrap();
    let a = new.resolve("src/a.rs").unwrap();
    new.set_hash(a, [2; 32]).unwrap();
    let b = new.resolve("src/b.rs").unwrap();
    new.keep_home(b, "a key").unwrap();

    let patch = old.diff(&new, 4, 9);
    let paths: Vec<&str> = patch.paths().collect();
    assert!(paths.contains(&"src/a.rs") && paths.contains(&"new/y/z") && paths.contains(&"old"));
    assert!(!paths.contains(&"README.md") && !paths.contains(&"src/b.rs"));
    assert!(!paths.contains(&"old/x"), "only the topmost path gone");

    let wire = Patch::decode(&patch.encode().unwrap()).unwrap();
    assert_eq!(wire, patch);
    assert_eq!(old.patched(&wire).unwrap(), new);
}

#[test]
fn a_journal_patch_puts_what_exists_and_removes_what_does_not() {
    let old = base();
    let mut items = vec![file("src/a.rs", 2), file("README.md", 99)];
    items.push(file("old/x", 1));
    let new = Manifest::build(1, items).unwrap();
    let patch = new.patch_for(&["README.md".into(), "src/b.rs".into()], 1, 2);
    let out = old.patched(&patch).unwrap();
    assert_eq!(out.entry(out.resolve("README.md").unwrap()).unwrap().size, 99);
    assert_eq!(out.resolve("src/b.rs"), None);
    // The hash of an untouched file is kept.
    assert!(out.hash(out.resolve("src/a.rs").unwrap()).is_some());
}

#[test]
fn a_file_put_over_a_folder_drops_what_was_below() {
    let old = base();
    let patch = Patch {
        from: 0,
        to: 1,
        changes: vec![Change::Put {
            path: "old".into(),
            kind: Kind::File,
            mode: 0o644,
            size: 1,
            mtime_ns: 3,
            link: None,
            hash: None,
            kept: None,
        }],
    };
    let out = old.patched(&patch).unwrap();
    assert_eq!(out.entry(out.resolve("old").unwrap()).unwrap().kind, Kind::File);
    assert_eq!(out.resolve("old/x"), None);
}

#[test]
fn a_backwards_patch_is_refused() {
    let patch = Patch { from: 5, to: 1, changes: Vec::new() };
    assert!(Patch::decode(&patch.encode().unwrap()).is_err());
}
