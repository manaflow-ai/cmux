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

fn link(path: &str, target: &str) -> Item {
    Item {
        path: path.into(),
        kind: Kind::Link,
        mode: 0o777,
        size: 0,
        mtime_ns: 3,
        link: Some(target.into()),
    }
}

/// A second session's manifest goes as a delta of the last one the machine has: applying it to
/// that base gives exactly the Mac's new manifest (by id), with files added, changed, removed,
/// a folder gone, a file turned into a folder and a folder into a file.
#[test]
fn a_delta_applied_to_its_base_is_the_new_manifest() {
    let mut base_items = Vec::new();
    for index in 0..2000u64 {
        base_items.push(file(&format!("repo/src/d{:02}/f{index:04}.rs", index % 40), index));
    }
    base_items.push(file("repo/.git/index", 5000));
    base_items.push(file("gone/a/b.txt", 1));
    base_items.push(file("turns/into_dir", 2));
    base_items.push(file("dir/into_file/x", 3));
    base_items.push(link("repo/README", "src/d00/f0000.rs"));
    let base = Manifest::build(10, base_items.clone()).unwrap();

    let mut items: Vec<Item> = base_items
        .into_iter()
        .filter(|item| {
            !item.path.starts_with("gone/")
                && item.path != "turns/into_dir"
                && !item.path.starts_with("dir/into_file/")
                && item.path != "repo/src/d07/f0007.rs"
        })
        .map(|mut item| {
            if item.path == "repo/.git/index" {
                item.size = 7000;
                item.mtime_ns = 99;
            }
            item
        })
        .collect();
    items.push(file("repo/src/d00/new.rs", 12));
    items.push(file("brand/new/folder/x.rs", 4));
    items.push(file("turns/into_dir/now.rs", 5));
    items.push(file("dir/into_file", 6));
    items.push(link("repo/LINK", "README"));
    let new = Manifest::build(11, items).unwrap();

    let delta = Manifest::delta(&base, &new);
    assert_eq!(delta.removed.len(), 4, "{:?}", delta.removed);
    assert_eq!(delta.upserts.len(), 6, "{:?}", delta.upserts);
    let encoded = delta.encode().unwrap();
    assert!(encoded.len() * 20 < new.encode().unwrap().len(), "a delta of 10 paths is small");
    let applied = base.apply(&Delta::decode(&encoded).unwrap()).unwrap();
    assert_eq!(applied.id().unwrap(), new.id().unwrap());
    assert_eq!(applied, new);
    // An unchanged folder's delta is empty and applies to itself.
    let same = Manifest::delta(&new, &new);
    assert!(same.is_empty());
    assert_eq!(new.apply(&same).unwrap(), new);
}

/// Seeded random edits between two listings: every delta applies to exactly the new manifest.
#[test]
fn random_deltas_always_apply_to_the_new_manifest() {
    let mut seed: u64 = 0x5eed;
    let mut next = move || {
        seed = seed.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut z = seed;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        z ^ (z >> 31)
    };
    for _ in 0..200 {
        let paths: Vec<String> = (0..60)
            .map(|_| {
                let depth = 1 + next() % 3;
                (0..depth).map(|_| format!("n{}", next() % 6)).collect::<Vec<_>>().join("/")
            })
            .collect();
        let pick = |mask: u64, next: &mut dyn FnMut() -> u64| -> Vec<Item> {
            let mut chosen: Vec<Item> = Vec::new();
            for path in &paths {
                if next() % 4 < mask
                    && !chosen.iter().any(|item| {
                        item.path == *path
                            || item.path.starts_with(&format!("{path}/"))
                            || path.starts_with(&format!("{}/", item.path))
                    })
                {
                    chosen.push(file(path, next() % 3));
                }
            }
            chosen
        };
        let before = pick(3, &mut next);
        let after = pick(3, &mut next);
        let (root_before, root_after) = (next() % 2, next() % 2);
        let base = Manifest::build(root_before as i64, before).unwrap();
        let new = Manifest::build(root_after as i64, after).unwrap();
        let applied = base.apply(&Manifest::delta(&base, &new)).unwrap();
        assert_eq!(applied, new);
    }
}
