use super::*;
use std::fs;
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
