use super::*;
use crate::image_paste_file::ImagePasteFile;
use crate::image_paste_recovery::{ImagePasteRecovery, RESCAN_AFTER};
use crate::image_paste_storage::ImagePasteStorage;
use std::fs;
use std::os::unix::fs::DirBuilderExt;
use std::sync::Arc;
use std::sync::mpsc;

const ID: &str = "0123456789abcdef0123456789abcdef";
const PNG: &[u8] = b"\x89PNG\r\n\x1a\nimage-paste-fixture";

fn owner() -> ImagePasteOwner {
    ImagePasteOwner {
        client: 1,
        surface: 17,
        terminal: "term_1".into(),
        workspace: "workspace-1".into(),
        lease: "lease-1".into(),
    }
}

fn prepared(store: &ImagePasteStore) -> std::path::PathBuf {
    store.begin(owner(), ID, "image/png", PNG.len()).unwrap();
    store.append(&owner(), ID, 0, &base64::engine::general_purpose::STANDARD.encode(PNG)).unwrap();
    store.shared.state.lock().unwrap().uploads[&(1, ID.into())].file.path().unwrap()
}

#[test]
fn cloud_image_paste_remote_file_is_readable_and_only_pasted_once() {
    let store = ImagePasteStore::with_recovery(None);
    let path = prepared(&store);
    let mut pasted = String::new();
    store
        .commit(&owner(), ID, |text| {
            pasted = text.into();
            Ok(())
        })
        .unwrap();
    assert_eq!(pasted, format!("'{}'", path.display()));
    assert_eq!(fs::read(&path).unwrap(), PNG);
    assert!(store.commit(&owner(), ID, |_| panic!("must not double paste")).is_err());
    store.disconnect(1);
    assert!(path.exists(), "a reconnect must not remove an attachment an agent may be reading");
    store.close_terminal("term_1");
    assert!(!path.exists());
}

#[test]
fn cloud_image_paste_cleanup_waits_for_blocking_delivery() {
    let store = Arc::new(ImagePasteStore::with_recovery(None));
    let path = prepared(&store);
    let (entered_tx, entered_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let worker_store = Arc::clone(&store);
    let worker = std::thread::spawn(move || {
        worker_store
            .commit(&owner(), ID, |_| {
                entered_tx.send(()).unwrap();
                release_rx.recv().unwrap();
                Ok(())
            })
            .unwrap();
    });
    entered_rx.recv().unwrap();

    let cleanup_store = Arc::clone(&store);
    let cleanup = std::thread::spawn(move || cleanup_store.close_terminal("term_1"));
    cleanup.join().unwrap();
    assert!(path.exists(), "cleanup must not race the in-flight terminal write");

    release_tx.send(()).unwrap();
    worker.join().unwrap();
    assert!(!path.exists(), "deferred terminal cleanup should run after delivery");
}

#[test]
fn cloud_image_paste_cancellation_and_connection_end_remove_unpublished_bytes() {
    let store = ImagePasteStore::with_recovery(None);
    let path = prepared(&store);
    store.cancel(&owner(), ID).unwrap();
    assert!(!path.exists());
    store.cancel(&owner(), ID).unwrap();
    assert!(store.commit(&owner(), ID, |_| panic!("cancelled paste")).is_err());
    let path = prepared(&store);
    store.disconnect(1);
    assert!(!path.exists());
}

#[test]
fn cloud_image_paste_rejects_foreign_identity_and_out_of_order_chunks() {
    let store = ImagePasteStore::with_recovery(None);
    let path = prepared(&store);
    for foreign in [
        ImagePasteOwner { client: 2, ..owner() },
        ImagePasteOwner { surface: 18, ..owner() },
        ImagePasteOwner { terminal: "term_2".into(), ..owner() },
        ImagePasteOwner { workspace: "workspace-2".into(), ..owner() },
        ImagePasteOwner { lease: "retired-lease".into(), ..owner() },
    ] {
        assert!(store.commit(&foreign, ID, |_| panic!("foreign paste")).is_err());
    }
    assert!(path.exists());
    assert!(store.append(&owner(), ID, 0, "eA==").is_err());
    assert!(store.append(&owner(), ID, PNG.len(), "eA==").is_err());
}

#[test]
fn cloud_image_paste_rejects_size_type_bad_data_and_incomplete_upload() {
    let store = ImagePasteStore::with_recovery(None);
    for size in [0, MAX_IMAGE_BYTES + 1, usize::MAX] {
        assert!(store.begin(owner(), ID, "image/png", size).is_err());
    }
    assert!(store.begin(owner(), ID, "image/svg+xml", 20).is_err());
    assert!(store.begin(owner(), "../../user-file", "image/png", 20).is_err());
    store.begin(owner(), ID, "image/png", 20).unwrap();
    assert!(store.append(&owner(), ID, 0, "not base64").is_err());
    assert!(store.append(&owner(), ID, 0, &"A".repeat(MAX_CHUNK_BYTES * 2)).is_err());
    assert!(store.commit(&owner(), ID, |_| panic!("incomplete paste")).is_err());
    store
        .append(&owner(), ID, 0, &base64::engine::general_purpose::STANDARD.encode([b'x'; 20]))
        .unwrap();
    assert!(store.commit(&owner(), ID, |_| panic!("mislabelled image")).is_err());
}

#[test]
fn cloud_image_paste_expiry_and_drop_cleanup_preserve_user_files() {
    let store = ImagePasteStore::with_recovery(None);
    let path = prepared(&store);
    let directory = path.parent().unwrap().to_owned();
    let unrelated = directory.join("user-notes.txt");
    fs::write(&unrelated, "keep me").unwrap();
    store.commit(&owner(), ID, |_| Ok(())).unwrap();
    ImagePasteStore::reap(&mut store.shared.state.lock().unwrap(), Instant::now() + IMAGE_TTL);
    assert!(!path.exists());
    assert_eq!(fs::read_to_string(&unrelated).unwrap(), "keep me");
    fs::remove_file(&unrelated).unwrap();
    fs::remove_dir(directory).unwrap();

    let path = prepared(&store);
    let directory = path.parent().unwrap().to_owned();
    let original = directory.join("retained-original.png");
    fs::rename(&path, &original).unwrap();
    fs::write(&path, "replacement user file").unwrap();
    drop(store);
    assert_eq!(fs::read_to_string(&path).unwrap(), "replacement user file");
    assert_eq!(fs::read(&original).unwrap(), PNG);
    fs::remove_file(path).unwrap();
    fs::remove_file(original).unwrap();
    fs::remove_dir(directory).unwrap();
}

#[test]
fn cloud_image_paste_cleanup_does_not_follow_a_replacement_symlink() {
    use std::os::unix::fs::symlink;
    let store = ImagePasteStore::with_recovery(None);
    let path = prepared(&store);
    let directory = path.parent().unwrap().to_owned();
    let user_file = directory.join("user-file");
    fs::write(&user_file, "user bytes").unwrap();
    fs::remove_file(&path).unwrap();
    symlink(&user_file, &path).unwrap();
    drop(store);
    assert_eq!(fs::read_to_string(&user_file).unwrap(), "user bytes");
    assert!(fs::symlink_metadata(&path).unwrap().file_type().is_symlink());
    fs::remove_file(path).unwrap();
    fs::remove_file(user_file).unwrap();
    fs::remove_dir(directory).unwrap();
}

#[test]
fn cloud_image_paste_reservations_are_bounded_before_receiving_bytes() {
    let store = ImagePasteStore::with_recovery(None);
    for id in 0..6 {
        store.begin(owner(), &format!("{id:032x}"), "image/png", MAX_IMAGE_BYTES).unwrap();
    }
    assert!(store.begin(owner(), ID, "image/png", MAX_IMAGE_BYTES).is_err());
    store.disconnect(1);
    store.begin(owner(), ID, "image/png", MAX_IMAGE_BYTES).unwrap();
}

#[test]
fn cloud_image_paste_failed_cleanup_keeps_its_reservation_and_cannot_commit() {
    let store = ImagePasteStore::with_recovery(None);
    let mut blockers = Vec::new();
    for index in 0..6 {
        let id = format!("{index:032x}");
        store.begin(owner(), &id, "image/png", MAX_IMAGE_BYTES).unwrap();
        let directory = store.shared.state.lock().unwrap().uploads[&(1, id.clone())]
            .file
            .directory()
            .to_owned();
        let blocker = directory.join(".cleanup-image");
        fs::write(&blocker, "user file must not be replaced").unwrap();
        store.cancel(&owner(), &id).unwrap();
        assert_eq!(
            store
                .commit(&owner(), &id, |_| panic!("cancelled upload committed"))
                .unwrap_err()
                .to_string(),
            "image-upload-expired"
        );
        assert_eq!(fs::read_to_string(&blocker).unwrap(), "user file must not be replaced");
        blockers.push(blocker);
    }
    assert_eq!(store.shared.state.lock().unwrap().uploads.len(), 6);
    assert!(store.begin(owner(), ID, "image/png", MAX_IMAGE_BYTES).is_err());
    for blocker in blockers {
        fs::remove_file(blocker).unwrap();
    }
    ImagePasteStore::reap(
        &mut store.shared.state.lock().unwrap(),
        Instant::now() + Duration::from_secs(2),
    );
    assert!(store.shared.state.lock().unwrap().uploads.is_empty());
    store.begin(owner(), ID, "image/png", MAX_IMAGE_BYTES).unwrap();
}

#[test]
fn cloud_image_paste_already_removed_file_does_not_hold_storage_forever() {
    let store = ImagePasteStore::with_recovery(None);
    let path = prepared(&store);
    fs::remove_file(&path).unwrap();
    store.cancel(&owner(), ID).unwrap();
    assert!(store.shared.state.lock().unwrap().uploads.is_empty());
    assert!(!path.parent().unwrap().exists());
}

/// A private temporary parent for a recovery namespace, removed on drop.
struct RecoveryRoot(std::path::PathBuf);

impl RecoveryRoot {
    fn new() -> Self {
        let mut random = [0u8; 16];
        getrandom::fill(&mut random).unwrap();
        let suffix: String = random.iter().map(|b| format!("{b:02x}")).collect();
        let path = std::env::temp_dir().join(format!("image-store-recovery-test-{suffix}"));
        fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
        Self(path)
    }

    fn storage(&self) -> ImagePasteStorage {
        ImagePasteStorage::at(&self.0).unwrap()
    }
}

impl Drop for RecoveryRoot {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// Waits (bounded) until the worker's recovery state satisfies `done`.
fn recovery_reaches(store: &ImagePasteStore, done: impl Fn(&ImagePasteRecovery) -> bool) -> bool {
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        if store.shared.state.lock().unwrap().recovery.as_ref().is_some_and(&done) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    false
}

/// p14-energy-077m: a namespace that could not be opened at start and opens
/// later is used at once: the refused paste starts the scan, not the open
/// retry's backoff (30 s doubling to 10 min).
#[test]
fn a_paste_retries_a_namespace_that_could_not_be_opened() {
    let root = RecoveryRoot::new();
    let storage = root.storage();
    let namespace = storage.root().to_owned();
    fs::remove_dir(&namespace).unwrap();
    let store = ImagePasteStore::with_recovery(Some(ImagePasteRecovery::at(storage)));
    assert!(!store.shared.state.lock().unwrap().recovery.as_ref().unwrap().ready);
    fs::DirBuilder::new().mode(0o700).create(&namespace).unwrap();
    assert_eq!(
        store.begin(owner(), ID, "image/png", PNG.len()).unwrap_err().to_string(),
        "image-storage-unavailable"
    );
    assert!(recovery_reaches(&store, |recovery| recovery.ready), "the paste did not start a scan");
    store.begin(owner(), ID, "image/png", PNG.len()).unwrap();
}

/// p14-energy-077m: while a kept receipt schedules the next scan far ahead, a
/// paste after RESCAN_AFTER still scans at once and counts the leftovers of a
/// process that died since.
#[test]
fn a_paste_after_rescan_after_counts_new_leftovers_while_a_receipt_is_kept() {
    let root = RecoveryRoot::new();
    let kept = ImagePasteFile::create_in(&root.storage(), "png").unwrap();
    kept.abandon_for_test();
    let store = ImagePasteStore::with_recovery(Some(ImagePasteRecovery::at(root.storage())));
    {
        let state = store.shared.state.lock().unwrap();
        assert_eq!(state.recovery.as_ref().unwrap().retained_count, 1);
        assert!(state.next_recovery.unwrap() > Instant::now() + RESCAN_AFTER);
    }
    let leftover = ImagePasteFile::create_in(&root.storage(), "png").unwrap();
    leftover.abandon_for_test();
    store.shared.state.lock().unwrap().recovery.as_mut().unwrap().age(RESCAN_AFTER);
    store.begin(owner(), ID, "image/png", PNG.len()).unwrap();
    assert!(
        recovery_reaches(&store, |recovery| recovery.retained_count == 2),
        "the paste did not rescan while a receipt was kept"
    );
}
