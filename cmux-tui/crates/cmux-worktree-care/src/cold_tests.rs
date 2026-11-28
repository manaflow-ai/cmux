//! Evict only on a verified cloud copy; recall byte for byte (`cold.rs`).

use super::*;
use std::collections::HashMap;
use std::sync::Mutex;

/// A cloud copy in memory whose chunks a test can drop or damage.
#[derive(Default)]
struct Memory(Mutex<HashMap<Id, Vec<u8>>>);

impl CloudCopy for Memory {
    fn get(&self, id: &Id) -> Result<Vec<u8>, String> {
        self.0.lock().unwrap().get(id).cloned().ok_or_else(|| "missing".to_owned())
    }

    fn put(&self, id: &Id, bytes: &[u8]) -> Result<(), String> {
        self.0.lock().unwrap().insert(*id, bytes.to_vec());
        Ok(())
    }
}

fn noise(n: usize, seed: u64) -> Vec<u8> {
    let mut s = seed | 1;
    (0..n)
        .map(|_| {
            s ^= s << 13;
            s ^= s >> 7;
            s ^= s << 17;
            s as u8
        })
        .collect()
}

/// A folder with a big file (several chunks), a small one, a nested executable and an empty
/// folder.
fn sample(root: &Path) -> PathBuf {
    let dir = root.join("chat-or-worktree");
    std::fs::create_dir_all(dir.join("src/deep")).unwrap();
    std::fs::create_dir_all(dir.join("empty")).unwrap();
    std::fs::write(dir.join("big.bin"), noise(3 << 20, 7)).unwrap();
    std::fs::write(dir.join("notes.md"), b"hello\n").unwrap();
    std::fs::write(dir.join("src/deep/run.sh"), b"#!/bin/sh\necho hi\n").unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        let p = dir.join("src/deep/run.sh");
        std::fs::set_permissions(p, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    dir
}

/// Every file's bytes and mode, and every folder, under `dir`.
type Contents = (Vec<(String, Vec<u8>, bool)>, Vec<String>);

fn contents(dir: &Path) -> Contents {
    let mut files = Vec::new();
    let mut dirs = Vec::new();
    walk(dir, dir, &mut dirs, &mut |rel, bytes, exec| {
        files.push((rel.to_owned(), bytes, exec));
        Ok(())
    })
    .unwrap();
    files.sort();
    dirs.sort();
    (files, dirs)
}

#[test]
fn cold_evict_refuses_when_the_cloud_copy_is_missing() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = sample(tmp.path());
    let before = contents(&dir);
    let records = tmp.path().join("records");
    let cloud = Memory::default();
    let err = evict(&dir, &cloud, Path::new("/cloud"), &records).unwrap_err();
    assert!(err.contains("lacks chunk"), "{err}");
    assert_eq!(contents(&dir), before, "the folder stays whole");
    assert!(!record_path(&records, &dir).exists(), "no record is written");
}

#[test]
fn cold_evict_refuses_when_one_chunk_is_missing_or_damaged() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = sample(tmp.path());
    let before = contents(&dir);
    let records = tmp.path().join("records");
    let cloud = Memory::default();
    let snap = upload(&dir, &cloud).unwrap();
    let victim = snap.manifest.files.iter().find(|f| f.path == "big.bin").unwrap().chunks[1].id;

    // Damaged: same id, other bytes.
    let mut bad = cloud.get(&victim).unwrap();
    bad[0] ^= 1;
    cloud.0.lock().unwrap().insert(victim, bad);
    let err = evict(&dir, &cloud, Path::new("/cloud"), &records).unwrap_err();
    assert!(err.contains("differs"), "{err}");
    assert_eq!(contents(&dir), before);

    // Missing.
    cloud.0.lock().unwrap().remove(&victim);
    let err = evict(&dir, &cloud, Path::new("/cloud"), &records).unwrap_err();
    assert!(err.contains("lacks chunk"), "{err}");
    assert_eq!(contents(&dir), before);
    assert!(!record_path(&records, &dir).exists());
}

#[test]
fn cold_evict_refuses_a_file_changed_after_the_upload() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = sample(tmp.path());
    let records = tmp.path().join("records");
    let cloud = Memory::default();
    upload(&dir, &cloud).unwrap();
    std::fs::write(dir.join("notes.md"), b"hello, changed\n").unwrap();
    let before = contents(&dir);
    let err = evict(&dir, &cloud, Path::new("/cloud"), &records).unwrap_err();
    assert!(err.contains("notes.md"), "{err}");
    assert_eq!(contents(&dir), before);
}

#[cfg(unix)]
#[test]
fn cold_evict_refuses_what_the_copy_cannot_carry() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = sample(tmp.path());
    std::os::unix::fs::symlink("notes.md", dir.join("link")).unwrap();
    let records = tmp.path().join("records");
    let cloud = Memory::default();
    assert!(upload(&dir, &cloud).is_err());
    let err = evict(&dir, &cloud, Path::new("/cloud"), &records).unwrap_err();
    assert!(err.contains("cannot carry"), "{err}");
    assert!(dir.join("link").exists());
}

#[test]
fn cold_evict_then_recall_is_byte_identical() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = sample(tmp.path());
    let before = contents(&dir);
    let records = tmp.path().join("records");
    let cloud = Memory::default();
    upload(&dir, &cloud).unwrap();
    let record = evict(&dir, &cloud, Path::new("/cloud"), &records).unwrap();
    assert!(!dir.exists(), "the folder is gone locally");
    assert_eq!(record.bytes, (3 << 20) + 6 + 18);
    assert!(record_path(&records, &dir).exists());
    // Nothing is left beside it.
    let left: Vec<_> =
        std::fs::read_dir(tmp.path()).unwrap().map(|e| e.unwrap().file_name()).collect();
    assert_eq!(left, vec![std::ffi::OsString::from("records")]);

    recall(&dir, &records, &cloud).unwrap();
    assert_eq!(contents(&dir), before, "every byte, mode and folder is back");
    assert!(!record_path(&records, &dir).exists(), "the record goes once it is back");
}

#[test]
fn cold_recall_refuses_a_damaged_cloud_copy_and_leaves_nothing_half_built() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = sample(tmp.path());
    let records = tmp.path().join("records");
    let cloud = Memory::default();
    let snap = upload(&dir, &cloud).unwrap();
    evict(&dir, &cloud, Path::new("/cloud"), &records).unwrap();
    let victim = snap.manifest.files.iter().find(|f| f.path == "big.bin").unwrap().chunks[0].id;
    let good = cloud.get(&victim).unwrap();
    let mut bad = good.clone();
    bad[10] ^= 0xff;
    cloud.0.lock().unwrap().insert(victim, bad);
    assert!(recall(&dir, &records, &cloud).is_err());
    assert!(!dir.exists(), "no half folder in its place");
    assert!(record_path(&records, &dir).exists(), "the record stays for another try");
    cloud.0.lock().unwrap().insert(victim, good);
    recall(&dir, &records, &cloud).unwrap();
    assert!(dir.join("big.bin").exists());
}

#[test]
fn cold_recall_for_brings_the_folder_back_when_a_path_inside_is_needed() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = sample(tmp.path());
    let before = contents(&dir);
    let records = tmp.path().join("records");
    let cloud_root = tmp.path().join("cloud");
    let cloud = cmux_cas::Store::new(&cloud_root);
    upload(&dir, &cloud).unwrap();
    evict(&dir, &cloud, &cloud_root, &records).unwrap();

    // A session whose folder is a subfolder of the evicted one starts.
    let back = recall_for(&dir.join("src/deep"), &records).unwrap().expect("recalled");
    assert_eq!(back.path, dir);
    assert_eq!(contents(&dir), before);
    // Present now: nothing to do, and an unrelated missing path finds no record.
    assert!(recall_for(&dir.join("src/deep"), &records).unwrap().is_none());
    assert!(recall_for(&tmp.path().join("elsewhere/x"), &records).unwrap().is_none());
}

#[test]
fn cold_evict_refuses_a_folder_already_evicted_or_a_relative_one() {
    let tmp = tempfile::tempdir().unwrap();
    let records = tmp.path().join("records");
    let cloud = Memory::default();
    assert!(evict(Path::new("relative"), &cloud, Path::new("/cloud"), &records).is_err());
    let dir = sample(tmp.path());
    upload(&dir, &cloud).unwrap();
    evict(&dir, &cloud, Path::new("/cloud"), &records).unwrap();
    // Put back by hand: a second evict must not overwrite the first record.
    std::fs::create_dir_all(&dir).unwrap();
    let err = evict(&dir, &cloud, Path::new("/cloud"), &records).unwrap_err();
    assert!(err.contains("already evicted"), "{err}");
    // And recall does not overwrite what is there.
    assert!(recall(&dir, &records, &cloud).unwrap_err().contains("not overwritten"));
}
