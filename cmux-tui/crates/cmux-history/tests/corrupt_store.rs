//! A profile's visit log that SQLite cannot read (a torn write, a disk error, a file another tool
//! overwrote) is moved aside, byte for byte, and the profile starts a new log. Before this the open
//! failed on every visit, so that profile's history stayed off until someone deleted the file by hand.

use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use cmux_history::{VisitStore, VisitStores};

struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let path = std::fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!("cmux-history-{name}-{}-{stamp}", std::process::id()));
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
    }

    fn path(&self, name: &str) -> PathBuf {
        self.0.join(name)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

const GARBAGE: &[u8] = b"this is not a sqlite database, it is what a torn write left behind\n";

/// The files beside `path` whose name starts with `path`'s name and `.corrupt-`.
fn moved_aside(path: &Path) -> Vec<PathBuf> {
    let name = path.file_name().unwrap().to_str().unwrap().to_owned();
    let mut found: Vec<PathBuf> = std::fs::read_dir(path.parent().unwrap())
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|candidate| {
            candidate
                .file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.starts_with(&format!("{name}.corrupt-")))
        })
        .collect();
    found.sort();
    found
}

#[test]
fn an_unreadable_log_is_moved_aside_and_a_new_one_opens() {
    let scratch = Scratch::new("corrupt-open");
    let path = scratch.path("profile.sqlite");
    std::fs::write(&path, GARBAGE).unwrap();

    let store = VisitStore::open(&path).expect("a log SQLite cannot read opens fresh");
    assert_eq!(store.count().unwrap(), 0);

    let kept = moved_aside(&path);
    assert_eq!(kept.len(), 1, "the unreadable file is kept beside the new log: {kept:?}");
    assert_eq!(std::fs::read(&kept[0]).unwrap(), GARBAGE, "kept byte for byte, never deleted");
}

#[test]
fn a_second_unreadable_log_never_replaces_the_first_one_kept() {
    let scratch = Scratch::new("corrupt-twice");
    let path = scratch.path("profile.sqlite");
    std::fs::write(&path, GARBAGE).unwrap();
    drop(VisitStore::open(&path).unwrap());
    let other: &[u8] = b"a second, different torn file\n";
    std::fs::write(&path, other).unwrap();
    // Any WAL left by the fresh log belongs to it, not to the new garbage.
    let _ = std::fs::remove_file(scratch.path("profile.sqlite-wal"));
    let _ = std::fs::remove_file(scratch.path("profile.sqlite-shm"));

    VisitStore::open(&path).expect("opens fresh again");

    let kept: Vec<Vec<u8>> = moved_aside(&path).iter().map(|p| std::fs::read(p).unwrap()).collect();
    assert_eq!(kept.len(), 2, "both unreadable files are kept");
    assert!(kept.contains(&GARBAGE.to_vec()) && kept.contains(&other.to_vec()));
}

#[test]
fn a_profile_whose_log_was_unreadable_records_again_and_lists_once() {
    let scratch = Scratch::new("corrupt-stores");
    let mut stores = VisitStores::new(scratch.path("visits"));
    std::fs::create_dir_all(scratch.path("visits")).unwrap();
    let path = stores.path("default");
    std::fs::write(&path, GARBAGE).unwrap();

    assert_eq!(stores.store("default").expect("the profile's log opens").count().unwrap(), 0);
    assert_eq!(
        stores.profiles().unwrap(),
        vec!["default".to_owned()],
        "the kept file is not a profile"
    );
}

#[test]
fn a_readable_log_is_opened_in_place_and_nothing_is_moved() {
    let scratch = Scratch::new("readable");
    let path = scratch.path("profile.sqlite");
    drop(VisitStore::open(&path).unwrap());
    VisitStore::open(&path).unwrap();
    assert!(moved_aside(&path).is_empty());
}
