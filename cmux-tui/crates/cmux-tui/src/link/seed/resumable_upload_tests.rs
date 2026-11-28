use std::sync::atomic::{AtomicUsize, Ordering};

use super::*;

/// A store that cuts off after `allow` puts, as a dropped connection does.
struct CutOff<'a> {
    inner: &'a DirPartStore,
    allow: AtomicUsize,
    puts: AtomicUsize,
}

impl PartStore for CutOff<'_> {
    fn put(&self, upload: &str, index: u32, bytes: &[u8]) -> anyhow::Result<()> {
        if self
            .allow
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| n.checked_sub(1))
            .is_err()
        {
            bail!("connection reset");
        }
        self.puts.fetch_add(1, Ordering::SeqCst);
        self.inner.put(upload, index, bytes)
    }
    fn list(&self, upload: &str) -> anyhow::Result<Vec<Part>> {
        self.inner.list(upload)
    }
    fn complete(
        &self,
        upload: &str,
        key: &str,
        parts: &[Part],
        digest: &str,
    ) -> anyhow::Result<()> {
        self.inner.complete(upload, key, parts, digest)
    }
}

fn file(dir: &Path, len: usize) -> (PathBuf, Vec<u8>) {
    let bytes: Vec<u8> = (0..len).map(|i| (i * 31 % 251) as u8).collect();
    let path = dir.join("snap.bundle");
    std::fs::write(&path, &bytes).unwrap();
    (path, bytes)
}

#[test]
fn whole_upload_assembles_the_object() {
    let dir = tempfile::tempdir().unwrap();
    let (path, bytes) = file(dir.path(), 10_500);
    let store = DirPartStore(dir.path().join("store"));
    let out = upload(&store, "u/me/snap.bundle", &path, 1000, 3).unwrap();
    assert_eq!((out.parts, out.resumed, out.sent), (11, 0, 11));
    assert_eq!(std::fs::read(dir.path().join("store/u/me/snap.bundle")).unwrap(), bytes);
}

#[test]
fn cut_off_upload_resumes_from_the_parts_the_store_holds() {
    let dir = tempfile::tempdir().unwrap();
    let (path, bytes) = file(dir.path(), 10_500);
    let real = DirPartStore(dir.path().join("store"));
    let cut = CutOff { inner: &real, allow: AtomicUsize::new(4), puts: AtomicUsize::new(0) };
    let error = upload(&cut, "k/snap.bundle", &path, 1000, 1).unwrap_err();
    assert!(format!("{error:#}").contains("cut off"), "{error:#}");
    assert!(!dir.path().join("store/k/snap.bundle").exists(), "no partial object");

    let out = upload(&real, "k/snap.bundle", &path, 1000, 4).unwrap();
    assert_eq!((out.resumed, out.sent), (4, 7), "kept 4, sent the other 7");
    assert_eq!(out.bytes_sent, 6_500 + 500, "7 parts: six of 1000 and the 500 tail");
    assert_eq!(std::fs::read(dir.path().join("store/k/snap.bundle")).unwrap(), bytes);
}

#[test]
fn a_torn_or_wrong_part_is_sent_again() {
    let dir = tempfile::tempdir().unwrap();
    let (path, bytes) = file(dir.path(), 3_000);
    let store = DirPartStore(dir.path().join("store"));
    let id = upload_id("k/b", 3_000, mtime(&path), 1000);
    // A half-written part (tmp name) and a part whose digest is not this file's.
    store.put(&id, 0, &bytes[..1000]).unwrap();
    store.put(&id, 1, &[9u8; 1000]).unwrap();
    std::fs::write(store.dir(&id).join("2-1000-abc.2.tmp"), b"half").unwrap();
    let out = upload(&store, "k/b", &path, 1000, 2).unwrap();
    assert_eq!((out.resumed, out.sent), (1, 2));
    assert_eq!(std::fs::read(dir.path().join("store/k/b")).unwrap(), bytes);
}

fn mtime(path: &Path) -> u128 {
    std::fs::metadata(path)
        .unwrap()
        .modified()
        .unwrap()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos()
}

#[test]
fn an_edited_file_does_not_resume_into_old_parts() {
    let dir = tempfile::tempdir().unwrap();
    let (path, _) = file(dir.path(), 2_000);
    let real = DirPartStore(dir.path().join("store"));
    let cut = CutOff { inner: &real, allow: AtomicUsize::new(1), puts: AtomicUsize::new(0) };
    assert!(upload(&cut, "k/b", &path, 1000, 1).is_err());
    std::fs::write(&path, vec![7u8; 2_000]).unwrap();
    let out = upload(&real, "k/b", &path, 1000, 1).unwrap();
    assert_eq!(std::fs::read(dir.path().join("store/k/b")).unwrap(), vec![7u8; 2_000]);
    assert_eq!(out.sent + out.resumed, 2);
}

#[test]
fn a_finished_upload_repeated_sends_nothing_new() {
    let dir = tempfile::tempdir().unwrap();
    let (path, bytes) = file(dir.path(), 2_500);
    let store = DirPartStore(dir.path().join("store"));
    let first = upload(&store, "k/b", &path, 1000, 2).unwrap();
    let again = upload(&store, "k/b", &path, 1000, 2).unwrap();
    assert_eq!(first.digest, again.digest);
    assert_eq!(std::fs::read(dir.path().join("store/k/b")).unwrap(), bytes);
}

#[test]
fn empty_file_and_zero_part_size() {
    let dir = tempfile::tempdir().unwrap();
    let (path, _) = file(dir.path(), 0);
    let store = DirPartStore(dir.path().join("store"));
    assert!(upload(&store, "k/b", &path, 0, 1).is_err());
    let out = upload(&store, "k/b", &path, 1000, 1).unwrap();
    assert_eq!(out.parts, 0);
    assert_eq!(std::fs::read(dir.path().join("store/k/b")).unwrap().len(), 0);
}

#[test]
fn switch_is_off_by_default() {
    if std::env::var(ENV).is_err() {
        assert!(!enabled());
    }
}
