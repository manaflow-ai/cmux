use std::collections::HashMap;
use std::sync::Mutex;

use super::*;
use crate::manifest::Item;

fn item(path: &str, kind: Kind, size: u64, mtime: i64) -> Item {
    Item { path: path.into(), kind, mode: 0o644, size, mtime_ns: mtime, link: None }
}

/// `dirs` folders of `files` files each, nested two deep, so the split makes several pieces.
fn big(dirs: usize, files: usize) -> Vec<Item> {
    let mut items = Vec::new();
    for dir in 0..dirs {
        for sub in 0..3 {
            for file in 0..files {
                items.push(item(
                    &format!("d{dir:04}/s{sub}/a-long-enough-file-name-{file:05}.rs"),
                    Kind::File,
                    (file * 7) as u64,
                    (dir + file) as i64,
                ));
            }
        }
    }
    items.push(Item {
        path: "d0000/link".into(),
        kind: Kind::Link,
        mode: 0o777,
        size: 0,
        mtime_ns: 3,
        link: Some("s0".into()),
    });
    items
}

struct Mem {
    blobs: HashMap<String, Vec<u8>>,
    gets: Mutex<usize>,
}

impl Mem {
    fn of(split: &Split) -> Self {
        Self {
            blobs: split
                .pieces
                .iter()
                .map(|piece| (piece.sha256.clone(), piece.bytes.clone()))
                .collect(),
            gets: Mutex::new(0),
        }
    }
}

impl Blobs for Mem {
    fn get(&self, sha256: &str) -> anyhow::Result<Vec<u8>> {
        *self.gets.lock().unwrap() += 1;
        self.blobs.get(sha256).cloned().ok_or_else(|| anyhow::anyhow!("absent"))
    }
}

#[test]
fn a_split_manifest_assembles_to_the_same_manifest() {
    let manifest = Manifest::build(5, big(40, 60)).unwrap();
    let parts = split(&manifest).unwrap();
    assert!(parts.pieces.len() > 3, "{} pieces", parts.pieces.len());
    assert_eq!(parts.pieces[0].sha256, parts.root);
    let blobs = Mem::of(&parts);
    let back = assemble(&parts.root, &blobs).unwrap();
    assert_eq!(back, manifest);
    assert_eq!(*blobs.gets.lock().unwrap(), parts.pieces.len());
}

#[test]
fn a_tiny_manifest_is_one_piece() {
    let manifest = Manifest::build(1, vec![item("a/b", Kind::File, 1, 1)]).unwrap();
    let parts = split(&manifest).unwrap();
    assert_eq!(parts.pieces.len(), 1);
    assert_eq!(assemble(&parts.root, &Mem::of(&parts)).unwrap(), manifest);
    let empty = Manifest::build(1, vec![]).unwrap();
    let parts = split(&empty).unwrap();
    assert_eq!(assemble(&parts.root, &Mem::of(&parts)).unwrap(), empty);
}

#[test]
fn the_same_listing_splits_the_same_and_one_change_rewrites_one_path() {
    let items = big(40, 60);
    let first = split(&Manifest::build(5, items.clone()).unwrap()).unwrap();
    let again = split(&Manifest::build(5, items.clone()).unwrap()).unwrap();
    assert_eq!(first, again);

    let mut edited = items;
    let at = edited
        .iter()
        .position(|it| it.path == "d0007/s1/a-long-enough-file-name-00010.rs")
        .unwrap();
    edited[at].size += 1;
    let second = split(&Manifest::build(5, edited).unwrap()).unwrap();
    assert_ne!(first.root, second.root);
    let old: std::collections::HashSet<&str> =
        first.pieces.iter().map(|p| p.sha256.as_str()).collect();
    let fresh = second.pieces.iter().filter(|p| !old.contains(p.sha256.as_str())).count();
    assert!(fresh >= 1 && fresh <= 4, "{fresh} of {} pieces changed", second.pieces.len());
}

#[test]
fn the_tree_lists_every_piece_with_the_root_first() {
    let parts = split(&Manifest::build(5, big(40, 60)).unwrap()).unwrap();
    let tree = parts.tree();
    let text = String::from_utf8(tree.clone()).unwrap();
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines[0], TREE_HEADER);
    assert_eq!(lines[1], parts.root);
    assert_eq!(lines.len(), 1 + parts.pieces.len());
    assert_eq!(Split::root_of_tree(&tree).unwrap(), parts.root);
    assert!(Split::root_of_tree(b"nope\n").is_err());
}

#[test]
fn a_piece_that_does_not_hash_to_its_name_is_refused() {
    let manifest = Manifest::build(5, big(40, 60)).unwrap();
    let parts = split(&manifest).unwrap();
    let mut blobs = Mem::of(&parts);
    let victim = parts.pieces[1].sha256.clone();
    blobs.blobs.insert(victim, parts.pieces[0].bytes.clone());
    assert!(assemble(&parts.root, &blobs).is_err());
    assert!(assemble("zz", &blobs).is_err());
}

#[test]
fn a_missing_piece_fails_the_whole_revision() {
    let parts = split(&Manifest::build(5, big(40, 60)).unwrap()).unwrap();
    let mut blobs = Mem::of(&parts);
    blobs.blobs.remove(&parts.pieces[2].sha256);
    assert!(assemble(&parts.root, &blobs).is_err());
}
