//! The phone's read-first store: keyed, bounded, atomic, cleared on sign-out.

use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime};

use cmux_mobile_core::read_store::{ReadKey, ReadStore, ReadStoreError, ReadStoreLimits};

/// A fresh directory per test, removed when the guard drops.
struct TempDir(PathBuf);

impl TempDir {
    fn new() -> Self {
        static N: AtomicU64 = AtomicU64::new(0);
        let n = N.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!("cmux-read-store-{}-{n}", std::process::id()));
        let _ = fs::remove_dir_all(&path);
        Self(path)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn chats(account: &str, mac: &str) -> ReadKey {
    ReadKey::new(account, mac, "agent_chats")
}

#[test]
fn a_value_reads_back_after_the_store_opens_again() {
    let dir = TempDir::new();
    let store = ReadStore::open(&dir.0, ReadStoreLimits::default()).unwrap();
    assert_eq!(store.get(&chats("user_1", "mac-1")), None);
    store.put(&chats("user_1", "mac-1"), b"page one").unwrap();
    drop(store);

    // A cold launch: a new store on the same directory reads what the last run kept.
    let again = ReadStore::open(&dir.0, ReadStoreLimits::default()).unwrap();
    assert_eq!(again.get(&chats("user_1", "mac-1")).as_deref(), Some(&b"page one"[..]));
    again.put(&chats("user_1", "mac-1"), b"page two").unwrap();
    assert_eq!(again.get(&chats("user_1", "mac-1")).as_deref(), Some(&b"page two"[..]));
    assert_eq!(again.len(), 1);
}

#[test]
fn another_account_mac_or_kind_reads_nothing() {
    let dir = TempDir::new();
    let store = ReadStore::open(&dir.0, ReadStoreLimits::default()).unwrap();
    store.put(&chats("user_1", "mac-1"), b"mine").unwrap();
    assert_eq!(store.get(&chats("user_2", "mac-1")), None);
    assert_eq!(store.get(&chats("user_1", "mac-2")), None);
    assert_eq!(store.get(&ReadKey::new("user_1", "mac-1", "home_rows")), None);
    // Field boundaries are part of the key: "ab"+"c" is not "a"+"bc".
    store.put(&ReadKey::new("ab", "c", "k"), b"x").unwrap();
    assert_eq!(store.get(&ReadKey::new("a", "bc", "k")), None);
}

#[test]
fn file_names_carry_no_account_or_mac_id() {
    let dir = TempDir::new();
    let store = ReadStore::open(&dir.0, ReadStoreLimits::default()).unwrap();
    store.put(&chats("user_secret", "mac-secret"), b"v").unwrap();
    for entry in fs::read_dir(&dir.0).unwrap() {
        let name = entry.unwrap().file_name().into_string().unwrap();
        assert!(!name.contains("secret"), "{name}");
        assert!(name.ends_with(".entry"), "{name}");
    }
}

#[test]
fn a_value_over_the_limit_is_refused_and_the_old_one_stays() {
    let dir = TempDir::new();
    let limits = ReadStoreLimits { max_entries: 4, max_value_bytes: 8 };
    let store = ReadStore::open(&dir.0, limits).unwrap();
    store.put(&chats("u", "m"), b"12345678").unwrap();
    let refused = store.put(&chats("u", "m"), b"123456789");
    assert!(matches!(refused, Err(ReadStoreError::TooLarge { size: 9, limit: 8 })), "{refused:?}");
    assert_eq!(store.get(&chats("u", "m")).as_deref(), Some(&b"12345678"[..]));
}

#[test]
fn past_the_entry_limit_the_oldest_writes_leave() {
    let dir = TempDir::new();
    let limits = ReadStoreLimits { max_entries: 3, max_value_bytes: 64 };
    let store = ReadStore::open(&dir.0, limits).unwrap();
    let base = SystemTime::now() - Duration::from_secs(3600);
    for (i, mac) in ["mac-0", "mac-1", "mac-2"].iter().enumerate() {
        store.put(&chats("u", mac), mac.as_bytes()).unwrap();
        // Spread the write times so the order does not depend on the filesystem's clock grain.
        let path = fs::read_dir(&dir.0)
            .unwrap()
            .flatten()
            .map(|e| e.path())
            .find(|p| store_value_is(p, mac))
            .unwrap();
        let file = fs::File::options().write(true).open(path).unwrap();
        file.set_modified(base + Duration::from_secs(60 * i as u64)).unwrap();
    }
    store.put(&chats("u", "mac-3"), b"mac-3").unwrap();
    assert_eq!(store.len(), 3);
    assert_eq!(store.get(&chats("u", "mac-0")), None, "the oldest write left");
    for mac in ["mac-1", "mac-2", "mac-3"] {
        assert_eq!(store.get(&chats("u", mac)).as_deref(), Some(mac.as_bytes()), "{mac}");
    }
    // Writing many more keeps the bound.
    for i in 0..50 {
        store.put(&chats("u", &format!("more-{i}")), b"v").unwrap();
    }
    assert_eq!(store.len(), 3);
}

fn store_value_is(path: &std::path::Path, value: &str) -> bool {
    fs::read(path).is_ok_and(|bytes| bytes.ends_with(value.as_bytes()))
}

#[test]
fn remove_all_clears_every_entry_and_leaves_other_files() {
    let dir = TempDir::new();
    let store = ReadStore::open(&dir.0, ReadStoreLimits::default()).unwrap();
    store.put(&chats("u1", "m1"), b"a").unwrap();
    store.put(&chats("u2", "m2"), b"b").unwrap();
    fs::write(dir.0.join("not-ours.json"), b"{}").unwrap();
    fs::write(dir.0.join("0123456789abcdef.entry.1.2.tmp"), b"half").unwrap();
    store.remove_all().unwrap();
    assert!(store.is_empty());
    assert_eq!(store.get(&chats("u1", "m1")), None);
    assert!(dir.0.join("not-ours.json").exists());
    assert!(!dir.0.join("0123456789abcdef.entry.1.2.tmp").exists());
    // The store keeps working after a sign-out, even with its directory gone.
    fs::remove_dir_all(&dir.0).unwrap();
    store.remove_all().unwrap();
    store.put(&chats("u3", "m3"), b"c").unwrap();
    assert_eq!(store.get(&chats("u3", "m3")).as_deref(), Some(&b"c"[..]));
}

#[test]
fn remove_forgets_one_key() {
    let dir = TempDir::new();
    let store = ReadStore::open(&dir.0, ReadStoreLimits::default()).unwrap();
    store.put(&chats("u", "m1"), b"a").unwrap();
    store.put(&chats("u", "m2"), b"b").unwrap();
    store.remove(&chats("u", "m1")).unwrap();
    store.remove(&chats("u", "missing")).unwrap();
    assert_eq!(store.get(&chats("u", "m1")), None);
    assert_eq!(store.get(&chats("u", "m2")).as_deref(), Some(&b"b"[..]));
}

#[test]
fn a_corrupt_or_foreign_file_reads_as_nothing() {
    let dir = TempDir::new();
    let store = ReadStore::open(&dir.0, ReadStoreLimits::default()).unwrap();
    store.put(&chats("u", "m"), b"good").unwrap();
    let path = fs::read_dir(&dir.0).unwrap().flatten().next().unwrap().path();
    fs::write(&path, b"garbage").unwrap();
    assert_eq!(store.get(&chats("u", "m")), None);
    fs::write(&path, b"").unwrap();
    assert_eq!(store.get(&chats("u", "m")), None);
}

#[test]
fn writes_leave_no_temp_files() {
    let dir = TempDir::new();
    let store = ReadStore::open(&dir.0, ReadStoreLimits::default()).unwrap();
    for i in 0..10 {
        store.put(&chats("u", "m"), format!("v{i}").as_bytes()).unwrap();
    }
    let names: Vec<String> = fs::read_dir(&dir.0)
        .unwrap()
        .flatten()
        .map(|e| e.file_name().into_string().unwrap())
        .collect();
    assert_eq!(names.len(), 1, "{names:?}");
}
