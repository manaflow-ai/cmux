use super::*;
use std::fs;

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
