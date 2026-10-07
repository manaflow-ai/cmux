use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};

use super::{VisitStores, parse_page_id, profile_file_name, profile_from_file_name};
use crate::entry::HistoryKind;
use crate::query::{HistoryQuery, HistoryRange};
use crate::visits::NewVisit;

const T0: i64 = 1_800_000_000_000;

/// A fresh directory under the system temp dir, removed on drop.
struct TempDir(PathBuf);

impl TempDir {
    fn new(label: &str) -> Self {
        static COUNTER: AtomicU32 = AtomicU32::new(0);
        let n = COUNTER.fetch_add(1, Ordering::Relaxed);
        let path =
            std::env::temp_dir().join(format!("cmux-history-{label}-{}-{n}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        Self(path)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn visit(url: &str, at_ms: i64) -> NewVisit {
    NewVisit { url: url.to_owned(), title: None, tab: None, at_ms }
}

#[test]
fn file_names_are_safe_and_reversible() {
    for profile in ["default", "work", "a/b", "a_b", "..", ".hidden", "ü", "", "x.y", "p:1"] {
        let name = profile_file_name(profile);
        assert!(!name.contains('/'), "{name}");
        assert!(profile.is_empty() || !name.starts_with('.'), "{name}");
        assert_eq!(profile_from_file_name(&name).as_deref(), Some(profile), "{name}");
    }
    assert_ne!(profile_file_name("a/b"), profile_file_name("a_b"));
    assert_eq!(profile_file_name("default"), "default.sqlite");
    assert_eq!(profile_from_file_name("default.sqlite-wal"), None);
    assert_eq!(profile_from_file_name("_zz.sqlite"), None);
    assert_eq!(profile_from_file_name("a_2.sqlite"), None);
}

#[test]
fn page_ids_parse_with_colons_in_the_profile() {
    assert_eq!(parse_page_id("page:default:7"), Some(("default", 7)));
    assert_eq!(parse_page_id("page:p:1:7"), Some(("p:1", 7)));
    assert_eq!(parse_page_id("agent:x/y/z"), None);
    assert_eq!(parse_page_id("page:default:x"), None);
}

#[test]
fn stores_round_trip_through_the_directory() {
    let dir = TempDir::new("round-trip");
    let id = {
        let mut stores = VisitStores::new(&dir.0);
        stores.record("default", &visit("https://kept/", T0)).unwrap();
        stores.record("work/2", &visit("https://work/", T0 + 1)).unwrap()
    };
    let mut reopened = VisitStores::new(&dir.0);
    assert_eq!(reopened.profiles().unwrap(), ["default", "work/2"]);
    let query = HistoryQuery { kinds: vec![HistoryKind::Page], ..HistoryQuery::default() };
    let entries = reopened.entries(&query, T0, T0).unwrap();
    assert_eq!(entries.len(), 2);
    assert!(
        entries.iter().any(|entry| entry.id == id && entry.profile.as_deref() == Some("work/2"))
    );
    assert_eq!(reopened.remove_ids(&[id.as_str(), "agent:a/b/c", "page:nope"]).unwrap().removed, 1);
    assert_eq!(reopened.entries(&query, T0, T0).unwrap().len(), 1);
}

#[test]
fn host_clear_and_prune_cover_every_profile() {
    let dir = TempDir::new("all-profiles");
    let mut stores = VisitStores::new(&dir.0);
    stores.record("a", &visit("https://x.example/", T0)).unwrap();
    stores.record("b", &visit("https://example/", T0)).unwrap();
    stores.record("b", &visit("https://keep.org/", T0)).unwrap();
    assert_eq!(stores.remove_host("x.example", Some("b")).unwrap().removed, 0);
    assert_eq!(stores.remove_host("x.example", None).unwrap().removed, 1);
    stores.record("a", &visit("https://late/", T0 + 10)).unwrap();
    assert_eq!(stores.clear(HistoryRange::Hour.start(T0 + 10, T0), Some("a")).unwrap().removed, 1);
    assert_eq!(stores.clear(Some(T0), None).unwrap().removed, 2);
    assert_eq!(stores.prune(T0).unwrap(), 0);
}

#[test]
fn a_missing_directory_has_no_profiles() {
    let dir = TempDir::new("missing");
    let stores = VisitStores::new(dir.0.join("absent"));
    assert!(stores.profiles().unwrap().is_empty());
}

/// Every removal returns the id that restores it, across profiles; nothing
/// removed, no id. Ids are unguessable and distinct per removal.
#[test]
fn every_removal_returns_its_restore_id() {
    let dir = TempDir::new("restore");
    let mut stores = VisitStores::new(&dir.0);
    stores.record("a", &visit("https://x.example/a", T0)).unwrap();
    stores.record("b", &visit("https://x.example/b", T0 + 1)).unwrap();
    let none = stores.remove_host("nothing.example", None).unwrap();
    assert_eq!(none, super::Removal { removed: 0, restore_id: None });
    let first = stores.remove_host("x.example", None).unwrap();
    assert_eq!(first.removed, 2);
    let id = first.restore_id.expect("a removal has a restore id");
    assert!(id.starts_with("history:") && id.len() == "history:".len() + 32, "{id}");
    let query = HistoryQuery { kinds: vec![HistoryKind::Page], ..HistoryQuery::default() };
    assert!(stores.entries(&query, T0, T0).unwrap().is_empty());
    assert_eq!(stores.restore(&id).unwrap(), 2);
    assert_eq!(stores.entries(&query, T0, T0).unwrap().len(), 2);
    let second = stores.clear(None, Some("a")).unwrap().restore_id.unwrap();
    assert_ne!(second, id, "each removal has its own id");
    assert_eq!(stores.purge(&second).unwrap(), 1);
    assert_eq!(stores.restore(&second).unwrap(), 0);
}
