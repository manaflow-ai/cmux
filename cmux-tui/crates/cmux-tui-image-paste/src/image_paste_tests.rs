use super::*;
use std::fs;
use std::sync::Arc;
use std::sync::mpsc;

const ID: &str = "0123456789abcdef0123456789abcdef";
const PNG: &[u8] = b"\x89PNG\r\n\x1a\nimage-paste-fixture";
/// A declared size far above any old per-image or per-daemon byte budget.
const LARGE: usize = 1 << 30;

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
    assert!(store.begin(owner(), ID, "image/png", 0).is_err());
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
fn cloud_image_paste_reservations_are_bounded_by_count_not_size() {
    let store = ImagePasteStore::with_recovery(None);
    for id in 0..8 {
        store.begin(owner(), &format!("{id:032x}"), "image/png", LARGE).unwrap();
    }
    assert_eq!(
        store.begin(owner(), ID, "image/png", 1).unwrap_err().to_string(),
        "image-capacity-limit"
    );
    store.disconnect(1);
    store.begin(owner(), ID, "image/png", LARGE).unwrap();
}

/// An image over the old 20 MiB per-image limit arrives whole in sequential
/// chunks and is pasted by path; it was refused at begin with image-size-limit.
#[test]
fn cloud_image_paste_accepts_an_image_over_twenty_mebibytes() {
    let store = ImagePasteStore::with_recovery(None);
    let mut image = PNG.to_vec();
    image.resize(20 * 1024 * 1024 + 1, 0x5a);
    store.begin(owner(), ID, "image/png", image.len()).unwrap();
    let mut offset = 0;
    for chunk in image.chunks(MAX_CHUNK_BYTES) {
        let encoded = base64::engine::general_purpose::STANDARD.encode(chunk);
        store.append(&owner(), ID, offset, &encoded).unwrap();
        offset += chunk.len();
    }
    let path = store.shared.state.lock().unwrap().uploads[&(1, ID.into())].file.path().unwrap();
    let mut pasted = String::new();
    store
        .commit(&owner(), ID, |text| {
            pasted = text.into();
            Ok(())
        })
        .unwrap();
    assert_eq!(pasted, format!("'{}'", path.display()));
    assert!(fs::read(&path).unwrap() == image, "the pasted file holds the whole image");
    store.close_terminal("term_1");
    assert!(!path.exists());
}

/// A large upload that keeps sending chunks is not expired by the transfer
/// deadline: each accepted chunk restarts it, so slow links finish big images.
#[test]
fn cloud_image_paste_chunk_progress_extends_the_upload_deadline() {
    let store = ImagePasteStore::with_recovery(None);
    store.begin(owner(), ID, "image/png", LARGE).unwrap();
    let begun = store.shared.state.lock().unwrap().uploads[&(1, ID.into())].deadline;
    std::thread::sleep(Duration::from_millis(5));
    store.append(&owner(), ID, 0, &base64::engine::general_purpose::STANDARD.encode(PNG)).unwrap();
    ImagePasteStore::reap(&mut store.shared.state.lock().unwrap(), begun);
    store
        .append(&owner(), ID, PNG.len(), &base64::engine::general_purpose::STANDARD.encode(PNG))
        .unwrap();
    store.cancel(&owner(), ID).unwrap();
}

#[test]
fn cloud_image_paste_failed_cleanup_keeps_its_reservation_and_cannot_commit() {
    let store = ImagePasteStore::with_recovery(None);
    let mut blockers = Vec::new();
    for index in 0..8 {
        let id = format!("{index:032x}");
        store.begin(owner(), &id, "image/png", LARGE).unwrap();
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
    assert_eq!(store.shared.state.lock().unwrap().uploads.len(), 8);
    assert!(store.begin(owner(), ID, "image/png", 1).is_err());
    for blocker in blockers {
        fs::remove_file(blocker).unwrap();
    }
    ImagePasteStore::reap(
        &mut store.shared.state.lock().unwrap(),
        Instant::now() + Duration::from_secs(2),
    );
    assert!(store.shared.state.lock().unwrap().uploads.is_empty());
    store.begin(owner(), ID, "image/png", LARGE).unwrap();
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

/// A private temporary directory holding one per-UID image storage, shared by
/// the daemons of a test the way every daemon of a user shares the real one.
struct SharedStorage {
    temporary: std::path::PathBuf,
}

impl SharedStorage {
    fn new() -> Self {
        use std::os::unix::fs::DirBuilderExt;
        let mut random = [0u8; 16];
        getrandom::fill(&mut random).unwrap();
        let suffix: String = random.iter().map(|b| format!("{b:02x}")).collect();
        let temporary = std::env::temp_dir().join(format!("image-shared-test-{suffix}"));
        fs::DirBuilder::new().mode(0o700).create(&temporary).unwrap();
        Self { temporary }
    }

    /// Another daemon's recovery sweeper over the same storage and clock.
    fn sweeper(&self, clock: &WallClock) -> crate::image_paste_recovery::ImagePasteRecovery {
        let storage = ImagePasteStorage::at(&self.temporary).unwrap();
        crate::image_paste_recovery::ImagePasteRecovery::with_storage(storage, clock.clone())
    }

    /// Runs a full recovery pass, as another daemon's worker would.
    fn sweep(&self, clock: &WallClock) {
        let mut sweeper = self.sweeper(clock);
        assert_eq!(sweeper.scan(&HashSet::new()), Duration::from_secs(30));
        assert!(sweeper.ready);
    }
}

impl Drop for SharedStorage {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.temporary);
    }
}

fn receipt(path: &std::path::Path) -> (u64, u64) {
    use std::os::unix::fs::MetadataExt;
    let receipt = path.parent().unwrap().join(".receipt");
    let value: serde_json::Value = serde_json::from_slice(&fs::read(&receipt).unwrap()).unwrap();
    (value["expires"].as_u64().unwrap(), fs::metadata(&receipt).unwrap().ino())
}

fn chunk(store: &ImagePasteStore, offset: usize, bytes: &[u8]) {
    store
        .append(&owner(), ID, offset, &base64::engine::general_purpose::STANDARD.encode(bytes))
        .unwrap();
}

/// Daemon A's upload keeps sending chunks for fifteen minutes, past the 720 s
/// its receipt was created with. Daemon B shares the per-UID storage and runs
/// its recovery sweep; it must leave the live upload alone, and A's commit
/// then pastes the whole image.
#[test]
fn cloud_image_paste_another_daemons_sweep_keeps_a_long_running_upload() {
    let shared = SharedStorage::new();
    let clock = WallClock::manual(1_000_000);
    let daemon_a = ImagePasteStore::with_storage(&shared.temporary, clock.clone());
    let image = [PNG, &[0x5a; 15]].concat();
    daemon_a.begin(owner(), ID, "image/png", image.len()).unwrap();
    let path = daemon_a.shared.state.lock().unwrap().uploads[&(1, ID.into())].file.path().unwrap();
    // One byte a minute: slow, but never 120 s without an accepted chunk.
    for (offset, byte) in image.iter().enumerate() {
        clock.advance(60);
        chunk(&daemon_a, offset, std::slice::from_ref(byte));
        shared.sweep(&clock);
        assert!(
            path.exists(),
            "daemon B removed A's live upload {}s after begin",
            60 * (offset + 1)
        );
    }
    let mut pasted = String::new();
    daemon_a
        .commit(&owner(), ID, |text| {
            pasted = text.into();
            Ok(())
        })
        .unwrap();
    assert_eq!(pasted, format!("'{}'", path.display()));
    assert_eq!(fs::read(&path).unwrap(), image);
}

/// After a long transfer commits and its daemon crashes, a recovery sweep
/// keeps the image for the ten minutes of reading measured from the commit,
/// not from upload creation, and removes it once they pass.
#[test]
fn cloud_image_paste_recovery_keeps_a_committed_image_for_retention_after_commit() {
    let shared = SharedStorage::new();
    let clock = WallClock::manual(1_000_000);
    let daemon_a = ImagePasteStore::with_storage(&shared.temporary, clock.clone());
    let image = [PNG, &[0x5a; 15]].concat();
    daemon_a.begin(owner(), ID, "image/png", image.len()).unwrap();
    let path = daemon_a.shared.state.lock().unwrap().uploads[&(1, ID.into())].file.path().unwrap();
    for (offset, byte) in image.iter().enumerate() {
        clock.advance(60);
        chunk(&daemon_a, offset, std::slice::from_ref(byte));
    }
    daemon_a.commit(&owner(), ID, |_| Ok(())).unwrap();
    // Model a crash: the daemon's descriptors close but nothing is unlinked.
    let upload = daemon_a.shared.state.lock().unwrap().uploads.remove(&(1, ID.into())).unwrap();
    upload.file.abandon_for_test();
    drop(daemon_a);
    clock.advance(IMAGE_TTL.as_secs() - 1);
    shared.sweep(&clock);
    assert!(path.exists(), "recovery removed a committed image before its retention ended");
    assert_eq!(fs::read(&path).unwrap(), image);
    clock.advance(2);
    shared.sweep(&clock);
    assert!(!path.exists(), "recovery kept a committed image past its retention");
    assert!(!path.parent().unwrap().exists());
}

/// A fast upload rewrites its receipt at most once per RECEIPT_REFRESH of the
/// clock, not once per chunk: many chunks inside one window leave the receipt
/// file (its inode) and expiry untouched, and the first chunk after the
/// window moves the expiry to that chunk's time plus the full twelve minutes.
#[test]
fn cloud_image_paste_receipt_refresh_is_throttled() {
    let shared = SharedStorage::new();
    let clock = WallClock::manual(1_000_000);
    let daemon_a = ImagePasteStore::with_storage(&shared.temporary, clock.clone());
    daemon_a.begin(owner(), ID, "image/png", LARGE).unwrap();
    let path = daemon_a.shared.state.lock().unwrap().uploads[&(1, ID.into())].file.path().unwrap();
    let created = receipt(&path);
    assert_eq!(created.0, 1_000_000 + 720);
    let refresh = RECEIPT_REFRESH.as_secs();
    let mut offset = 0;
    for _ in 0..64 {
        chunk(&daemon_a, offset, PNG);
        offset += PNG.len();
    }
    clock.advance(refresh - 1);
    chunk(&daemon_a, offset, PNG);
    offset += PNG.len();
    assert_eq!(receipt(&path), created, "a chunk inside the refresh window rewrote the receipt");
    clock.advance(1);
    chunk(&daemon_a, offset, PNG);
    offset += PNG.len();
    let refreshed = receipt(&path);
    assert_eq!(refreshed.0, 1_000_000 + refresh + 720);
    for _ in 0..64 {
        chunk(&daemon_a, offset, PNG);
        offset += PNG.len();
    }
    assert_eq!(receipt(&path), refreshed, "chunks inside the next window rewrote the receipt");
    daemon_a.cancel(&owner(), ID).unwrap();
    assert!(!path.parent().unwrap().exists());
}

/// The receipt is only a crash fallback; a live upload is protected by its
/// owner's lock. Daemon A's wall clock jumps far past its receipt's expiry (a
/// stepped clock, or a machine that slept), and daemon B sweeps with that
/// clock and also holds a stale recovery handle taken while the receipt read
/// as expired. B removes nothing while A owns the upload, A finishes and
/// pastes, and once A is gone (a crash) the leftover is removed as before.
#[test]
fn cloud_image_paste_a_live_upload_survives_an_expired_receipt() {
    let shared = SharedStorage::new();
    let clock = WallClock::manual(1_000_000);
    let daemon_a = ImagePasteStore::with_storage(&shared.temporary, clock.clone());
    let image = [PNG, &[0x5a; 4]].concat();
    daemon_a.begin(owner(), ID, "image/png", image.len()).unwrap();
    let path = daemon_a.shared.state.lock().unwrap().uploads[&(1, ID.into())].file.path().unwrap();
    chunk(&daemon_a, 0, &image[..PNG.len()]);
    clock.advance(10 * (UPLOAD_TTL + IMAGE_TTL).as_secs());
    let (deadline, stale) =
        ImagePasteFile::recover_one(path.parent().unwrap().to_owned(), clock.now()).unwrap();
    assert!(deadline <= Instant::now(), "B should read A's receipt as expired");
    assert!(!stale.claim_for_removal(), "B claimed a file A still owns");
    shared.sweep(&clock);
    assert!(path.exists(), "B's sweep removed A's live upload");
    // A refreshes the receipt; B's stale handle still cannot claim the file.
    chunk(&daemon_a, PNG.len(), &image[PNG.len()..]);
    assert!(!stale.claim_for_removal(), "B claimed a file A still owns after a refresh");
    drop(stale);
    let mut pasted = String::new();
    daemon_a
        .commit(&owner(), ID, |text| {
            pasted = text.into();
            Ok(())
        })
        .unwrap();
    assert_eq!(pasted, format!("'{}'", path.display()));
    assert_eq!(fs::read(&path).unwrap(), image);
    // Model A's crash: its descriptors close (releasing the lock) but nothing
    // is unlinked. Past the retention its receipt records, B removes it.
    let upload = daemon_a.shared.state.lock().unwrap().uploads.remove(&(1, ID.into())).unwrap();
    upload.file.abandon_for_test();
    drop(daemon_a);
    shared.sweep(&clock);
    assert!(path.exists(), "recovery removed a committed image before its retention ended");
    clock.advance(IMAGE_TTL.as_secs() + 1);
    shared.sweep(&clock);
    assert!(!path.exists(), "recovery kept a crashed daemon's image past its retention");
    assert!(!path.parent().unwrap().exists());
}
