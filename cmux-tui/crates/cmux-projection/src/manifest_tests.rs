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
fn a_compressed_manifest_is_bounded_before_deserialization() {
    let compressed = zstd::encode_all(vec![0_u8; 4097].as_slice(), 1).unwrap();
    assert!(Manifest::decode_with_limit(&compressed, 4096).is_err());
}

#[test]
fn a_bad_or_doubled_path_is_refused() {
    assert!(Manifest::build(1, vec![file("../x", 1)]).is_err());
    assert!(Manifest::build(1, vec![file("a//b", 1)]).is_err());
    assert!(Manifest::build(1, vec![file("a", 1), file("a", 1)]).is_err());
    assert!(Manifest::build(1, vec![file("a", 1), file("a/b", 1)]).is_err());
    assert!(Manifest::build(1, vec![file("a/b", 1), file("a", 1)]).is_err());
    assert!(Manifest::build(1, vec![file("Foo", 1), file("foo", 1)]).is_err());
    assert!(Manifest::build(1, vec![file("Dir/Foo", 1), file("dir/foo", 1)]).is_err());
}

#[test]
fn case_collisions_are_refused_for_a_mac_folder_and_kept_for_a_case_sensitive_source() {
    let mac = |items| Manifest::build_with(1, items, Case::Insensitive);
    let linux = |items| Manifest::build_with(1, items, Case::Sensitive);
    assert!(mac(vec![file("Foo", 1), file("foo", 2)]).is_err());
    assert!(mac(vec![file("Dir/a", 1), file("dir/a", 2)]).is_err());
    let manifest =
        linux(vec![file("Foo", 1), file("foo", 2), file("Dir/a", 3), file("dir/a", 4)]).unwrap();
    for (path, size) in [("Foo", 1), ("foo", 2), ("Dir/a", 3), ("dir/a", 4)] {
        let entry = manifest.entry(manifest.resolve(path).unwrap()).unwrap();
        assert_eq!(entry.size, size, "{path}");
    }
    assert!(linux(vec![file("Foo", 1), file("Foo", 2)]).is_err(), "an exact double still is");
}

#[test]
fn wire_manifests_cannot_bypass_case_collision_checks() {
    let mut manifest = Manifest::build(1, vec![file("A", 1), file("b", 2)]).unwrap();
    manifest.entries[2].name = "a".into();
    assert!(Manifest::decode(&manifest.encode().unwrap()).is_err());
}

#[test]
#[ignore = "large acceptance fixture; run on the Linux fleet"]
fn a_manifest_accepts_one_point_five_million_files() {
    // A flat directory must also scale: case checks used to scan every sibling for each insert.
    for flat in [false, true] {
        let started = std::time::Instant::now();
        let items = (0..1_500_000)
            .map(|index| {
                let path = if flat {
                    format!("{index:07}.dat")
                } else {
                    format!("files/{:04}/{index:07}.dat", index / 150)
                };
                file(&path, 1)
            })
            .collect();
        let manifest = Manifest::build(1, items).unwrap();
        assert_eq!(manifest.totals(), (1_500_000, 1_500_000));
        let encoded = manifest.encode().unwrap();
        let expected = if flat { 1_500_001 } else { 1_510_002 };
        assert_eq!(Manifest::decode(&encoded).unwrap().len(), expected);
        eprintln!("1.5M files flat={flat}: {:?}, {} wire bytes", started.elapsed(), encoded.len());
    }
}
