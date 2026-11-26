use super::*;

fn file(path: &str, size: u64) -> Item {
    Item { path: path.into(), kind: Kind::File, mode: 0o644, size, mtime_ns: 7, link: None }
}

#[test]
fn a_manifest_resolves_every_path_and_lists_folders_in_name_order() {
    let manifest = Manifest::build(
        1,
        vec![
            file("src/b.rs", 3),
            file("src/a.rs", 2),
            file("README.md", 10),
            Item {
                path: "link".into(),
                kind: Kind::Link,
                mode: 0o777,
                size: 0,
                mtime_ns: 1,
                link: Some("README.md".into()),
            },
        ],
    )
    .unwrap();
    let src = manifest.resolve("src").unwrap();
    assert_eq!(manifest.entry(src).unwrap().kind, Kind::Dir);
    let (_, children) = manifest.children(src);
    let names: Vec<&str> = children.iter().map(|entry| entry.name.as_str()).collect();
    assert_eq!(names, ["a.rs", "b.rs"]);
    let b = manifest.resolve("src/b.rs").unwrap();
    assert_eq!(manifest.path_of(b), "src/b.rs");
    assert_eq!(manifest.entry(b).unwrap().size, 3);
    assert_eq!(manifest.entry(manifest.resolve("link").unwrap()).unwrap().size, 9);
    assert_eq!(manifest.resolve("src/c.rs"), None);
    assert_eq!(manifest.totals(), (3, 15));
}

#[test]
fn a_manifest_survives_the_wire_and_a_tampered_one_is_refused() {
    let manifest = Manifest::build(1, vec![file("a/b/c", 1), file("a/d", 2)]).unwrap();
    let bytes = manifest.encode().unwrap();
    assert_eq!(Manifest::decode(&bytes).unwrap(), manifest);

    let mut bad = manifest.clone();
    bad.entries[1].children = 99;
    assert!(Manifest::decode(&bad.encode().unwrap()).is_err());
    let mut bad = manifest.clone();
    bad.entries.last_mut().unwrap().name = "..".into();
    assert!(Manifest::decode(&bad.encode().unwrap()).is_err());
    let mut bad = manifest;
    bad.entries[2].parent = 0;
    assert!(Manifest::decode(&bad.encode().unwrap()).is_err());
}

#[test]
fn a_bad_or_doubled_path_is_refused() {
    assert!(Manifest::build(1, vec![file("../x", 1)]).is_err());
    assert!(Manifest::build(1, vec![file("a//b", 1)]).is_err());
    assert!(Manifest::build(1, vec![file("a", 1), file("a", 1)]).is_err());
    assert!(Manifest::build(1, vec![file("a", 1), file("a/b", 1)]).is_err());
    assert!(Manifest::build(1, vec![file("a/b", 1), file("a", 1)]).is_err());
}

/// RFD 0007, "Tracked files the skip rules keep home": a kept file is listed with its stat and
/// why, and the mark crosses the wire both ways between builds.
#[test]
fn a_file_kept_on_the_mac_keeps_its_stat_and_reason_across_the_wire_and_builds() {
    let mut manifest =
        Manifest::build(1, vec![file("k8s/test/key.pem", 1704), file("k8s/a", 2)]).unwrap();
    let key = manifest.resolve("k8s/test/key.pem").unwrap();
    manifest.keep_home(key, "secret: key files are shared only on purpose").unwrap();
    assert!(manifest.keep_home(manifest.resolve("k8s").unwrap(), "x").is_err(), "a folder");
    assert!(manifest.keep_home(key, "").is_err(), "no reason");
    assert_eq!(manifest.entry(key).unwrap().size, 1704);

    let decoded = Manifest::decode(&manifest.encode().unwrap()).unwrap();
    assert_eq!(decoded, manifest);
    assert_eq!(decoded.kept(key), Some("secret: key files are shared only on purpose"));
    assert_eq!(decoded.kept(manifest.resolve("k8s/a").unwrap()), None);
    assert_eq!(decoded.kept_count(), 1);

    // An older Mac sends the entries alone: they decode, nothing kept.
    #[derive(Serialize, Deserialize)]
    struct Older {
        entries: Vec<Entry>,
    }
    let older = Older { entries: manifest.entries.clone() };
    let raw = bincode::serialize(&older).unwrap();
    let decoded = Manifest::decode(&zstd::encode_all(raw.as_slice(), 3).unwrap()).unwrap();
    assert_eq!(decoded.entries, manifest.entries);
    assert_eq!(decoded.kept_count(), 0);
    // An older machine reads a newer manifest's entries and leaves the rest.
    let raw = bincode::serialize(&manifest).unwrap();
    let older: Older = bincode::deserialize(&raw).unwrap();
    assert_eq!(older.entries, manifest.entries);

    // A kept mark on a folder is refused at decode.
    let mut bad = manifest;
    bad.kept.insert(ROOT, "x".into());
    assert!(Manifest::decode(&bad.encode().unwrap()).is_err());
}

#[test]
fn case_collisions_follow_the_source_filesystem() {
    let mac = Manifest::build_with(
        1,
        vec![file("Foo", 1), file("foo", 2), file("Dir/a", 3), file("dir/a", 4)],
        Case::Insensitive,
    );
    assert!(mac.is_err());
    let linux = Manifest::build_with(
        1,
        vec![file("Foo", 1), file("foo", 2), file("Dir/a", 3), file("dir/a", 4)],
        Case::Sensitive,
    )
    .unwrap();
    for (path, size) in [("Foo", 1), ("foo", 2), ("Dir/a", 3), ("dir/a", 4)] {
        let entry = linux.entry(linux.resolve(path).unwrap()).unwrap();
        assert_eq!(entry.size, size, "{path}");
    }
}
