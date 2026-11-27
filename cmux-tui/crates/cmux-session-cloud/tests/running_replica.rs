use cmux_session_cloud::{
    Cloud, replica, seal, sha256_hex,
    store::{BlobStore, FsStore},
};
use std::fs;
use std::path::Path;
use std::sync::{
    Arc,
    atomic::{AtomicBool, AtomicUsize, Ordering},
};

#[derive(Default)]
struct Control {
    fail_put: AtomicBool,
    fail_root: AtomicBool,
    puts: AtomicUsize,
}

struct ControlledStore {
    inner: FsStore,
    control: Arc<Control>,
}

impl BlobStore for ControlledStore {
    fn put(&self, hash: &str, bytes: &[u8]) -> anyhow::Result<()> {
        if self.control.fail_put.load(Ordering::Relaxed) {
            anyhow::bail!("injected upload failure");
        }
        self.control.puts.fetch_add(1, Ordering::Relaxed);
        self.inner.put(hash, bytes)
    }
    fn get(&self, hash: &str) -> anyhow::Result<Vec<u8>> {
        self.inner.get(hash)
    }
    fn has(&self, hash: &str) -> anyhow::Result<bool> {
        self.inner.has(hash)
    }
    fn set_root(&self, pair: &str, hashes: &[String]) -> anyhow::Result<()> {
        if self.control.fail_root.load(Ordering::Relaxed) {
            anyhow::bail!("injected root failure");
        }
        self.inner.set_root(pair, hashes)
    }
    fn get_root(&self, pair: &str) -> anyhow::Result<Vec<String>> {
        self.inner.get_root(pair)
    }
    fn describe(&self) -> String {
        self.inner.describe()
    }
}

fn cloud(path: &Path) -> Cloud {
    Cloud {
        store: Box::new(FsStore::new(path).unwrap()),
        key: seal::Key::from_bytes([7; 32]),
        root_prefix: "m.test.".to_string(),
    }
}

fn controlled(path: &Path) -> (Cloud, Arc<Control>) {
    let control = Arc::new(Control::default());
    let cloud = Cloud {
        store: Box::new(ControlledStore {
            inner: FsStore::new(path).unwrap(),
            control: control.clone(),
        }),
        key: seal::Key::from_bytes([7; 32]),
        root_prefix: "m.test.".to_string(),
    };
    (cloud, control)
}

#[test]
fn running_replica_recovers_long_journal_and_native_state_after_source_loss() {
    let tmp = tempfile::tempdir().unwrap();
    let source = tmp.path().join("source");
    fs::create_dir_all(source.join("native/empty")).unwrap();
    let journal: String = (0..2048)
        .map(|i| {
            format!(
                "{{\"sequence\":{i},\"kind\":\"tool-start\",\"text\":\"private-running-chat\"}}\n"
            )
        })
        .collect();
    // Exercise more than one bounded chunk, including binary native harness state.
    let native: Vec<u8> = (0..(4 * 1024 * 1024 + 37)).map(|i| (i % 251) as u8).collect();
    fs::write(source.join("journal.jsonl"), &journal).unwrap();
    fs::write(source.join("native/state"), &native).unwrap();
    fs::write(source.join("empty"), []).unwrap();
    let store_path = tmp.path().join("store");
    let key_path = tmp.path().join("surviving-key");
    let mut writer = cloud(&store_path);
    writer.key = seal::Key::load_or_create(&key_path).unwrap();
    let receipt = replica::publish(&source, "private-session-id", &writer).unwrap();
    assert_eq!(receipt.files, 3);
    assert!(!receipt.pair.contains("private-session-id"));
    assert!(receipt.pair.starts_with("m.test.csr."));
    assert_ne!(receipt.pair, writer.root_pair());
    let hashes = writer.store.get_root(&receipt.pair).unwrap();
    assert_eq!(hashes[0], receipt.manifest);
    assert_eq!(hashes.len(), 4); // manifest, journal, and two native state chunks.
    let manifest: serde_json::Value = serde_json::from_slice(
        &seal::open(&writer.key, &writer.store.get(&receipt.manifest).unwrap(), 8 << 20).unwrap(),
    )
    .unwrap();
    assert_eq!(manifest["directories"], serde_json::json!(["native", "native/empty"]));
    assert!(
        manifest["files"].as_array().unwrap().iter().any(|entry| entry["path"] == "native/state")
    );
    for hash in &hashes {
        let encrypted = writer.store.get(hash).unwrap();
        assert!(!encrypted.windows(20).any(|w| w == b"private-running-chat"));
    }
    fs::remove_dir_all(&source).unwrap();
    drop(writer);
    // A new client knows only the receipt, surviving key, and store. A person credential need
    // not have the original machine's root prefix, and recovery must not depend on that prefix.
    let reader = Cloud {
        store: Box::new(FsStore::new(&store_path).unwrap()),
        key: seal::Key::load_or_create(&key_path).unwrap(),
        root_prefix: String::new(),
    };
    let dest = tmp.path().join("recovered");
    let recovered = replica::recover(&receipt.pair, &dest, &reader).unwrap();
    assert_eq!(recovered.bytes, journal.len() as u64 + native.len() as u64);
    assert_eq!(fs::read_to_string(dest.join("journal.jsonl")).unwrap(), journal);
    assert_eq!(fs::read(dest.join("native/state")).unwrap(), native);
    assert!(dest.join("native/empty").is_dir());
    assert_eq!(fs::read(dest.join("empty")).unwrap(), Vec::<u8>::new());
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(fs::metadata(&dest).unwrap().permissions().mode() & 0o777, 0o700);
        assert_eq!(
            fs::metadata(dest.join("journal.jsonl")).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
    assert!(replica::recover(&receipt.pair, &dest, &reader).is_err());
    assert_eq!(fs::read_to_string(dest.join("journal.jsonl")).unwrap(), journal);
}

#[test]
fn running_replica_reuses_unchanged_chunks_and_reuploads_missing_chunks() {
    let tmp = tempfile::tempdir().unwrap();
    let source = tmp.path().join("source");
    fs::create_dir(&source).unwrap();
    let mut bytes = vec![1; 4 * 1024 * 1024];
    bytes.extend_from_slice(b"tail");
    fs::write(source.join("journal"), &bytes).unwrap();
    let store = tmp.path().join("store");
    let (cloud, control) = controlled(&store);
    let one = replica::publish(&source, "session", &cloud).unwrap();
    let root_one = cloud.store.get_root(&one.pair).unwrap();
    assert_eq!(control.puts.load(Ordering::Relaxed), 3);
    let two = replica::publish(&source, "session", &cloud).unwrap();
    let root_two = cloud.store.get_root(&two.pair).unwrap();
    assert_eq!(&root_two[1..], &root_one[1..]);
    assert_eq!(control.puts.load(Ordering::Relaxed), 4); // only the manifest was uploaded.
    bytes.extend_from_slice(b"new tail");
    fs::write(source.join("journal"), &bytes).unwrap();
    let three = replica::publish(&source, "session", &cloud).unwrap();
    let root_three = cloud.store.get_root(&three.pair).unwrap();
    assert_eq!(root_three[1], root_one[1]);
    assert_ne!(root_three[2], root_one[2]);
    assert_eq!(control.puts.load(Ordering::Relaxed), 6); // changed tail plus manifest.
    fs::remove_file(store.join(&root_three[1][..2]).join(&root_three[1])).unwrap();
    let four = replica::publish(&source, "session", &cloud).unwrap();
    assert_eq!(control.puts.load(Ordering::Relaxed), 8); // lost chunk plus manifest.
    let dest = tmp.path().join("recovered");
    replica::recover(&four.pair, &dest, &cloud).unwrap();
    assert_eq!(fs::read(dest.join("journal")).unwrap(), bytes);
}

#[test]
fn running_replica_failed_upload_or_root_commit_preserves_previous_snapshot() {
    let tmp = tempfile::tempdir().unwrap();
    let source = tmp.path().join("source");
    fs::create_dir(&source).unwrap();
    fs::write(source.join("journal"), b"old").unwrap();
    let (cloud, control) = controlled(&tmp.path().join("store"));
    let first = replica::publish(&source, "session", &cloud).unwrap();
    let original = cloud.store.get_root(&first.pair).unwrap();
    fs::write(source.join("journal"), b"new").unwrap();
    control.fail_put.store(true, Ordering::Relaxed);
    assert!(replica::publish(&source, "session", &cloud).is_err());
    assert_eq!(cloud.store.get_root(&first.pair).unwrap(), original);
    control.fail_put.store(false, Ordering::Relaxed);
    control.fail_root.store(true, Ordering::Relaxed);
    assert!(replica::publish(&source, "session", &cloud).is_err());
    assert_eq!(cloud.store.get_root(&first.pair).unwrap(), original);
    let dest = tmp.path().join("recovered");
    replica::recover(&first.pair, &dest, &cloud).unwrap();
    assert_eq!(fs::read(dest.join("journal")).unwrap(), b"old");
}

#[test]
fn running_replica_rejects_tampered_bytes_wrong_keys_and_unretained_chunks() {
    let tmp = tempfile::tempdir().unwrap();
    let source = tmp.path().join("source");
    fs::create_dir(&source).unwrap();
    fs::write(source.join("journal"), b"journal").unwrap();
    let store = tmp.path().join("store");
    let cloud = cloud(&store);
    let receipt = replica::publish(&source, "session", &cloud).unwrap();
    let hashes = cloud.store.get_root(&receipt.pair).unwrap();
    let wrong = Cloud {
        store: Box::new(FsStore::new(&store).unwrap()),
        key: seal::Key::from_bytes([8; 32]),
        root_prefix: String::new(),
    };
    let dest = tmp.path().join("recovered");
    assert!(replica::recover(&receipt.pair, &dest, &wrong).is_err());
    assert!(!dest.exists());
    cloud.store.set_root(&receipt.pair, &hashes[..1]).unwrap();
    assert!(replica::recover(&receipt.pair, &dest, &cloud).is_err());
    assert!(!dest.exists());
    cloud.store.set_root(&receipt.pair, &hashes).unwrap();
    fs::write(store.join(&hashes[1][..2]).join(&hashes[1]), b"tampered").unwrap();
    assert!(replica::recover(&receipt.pair, &dest, &cloud).is_err());
    assert!(!dest.exists(), "partial recovery is removed");
}

#[test]
fn running_replica_rejects_authenticated_unsafe_paths_before_writing() {
    let tmp = tempfile::tempdir().unwrap();
    let source = tmp.path().join("source");
    fs::create_dir(&source).unwrap();
    fs::write(source.join("journal"), b"journal").unwrap();
    let cloud = cloud(&tmp.path().join("store"));
    let receipt = replica::publish(&source, "session", &cloud).unwrap();
    let hashes = cloud.store.get_root(&receipt.pair).unwrap();
    let sealed = cloud.store.get(&hashes[0]).unwrap();
    let original: serde_json::Value =
        serde_json::from_slice(&seal::open(&cloud.key, &sealed, 8 << 20).unwrap()).unwrap();
    let dest = tmp.path().join("recovered");
    for path in
        ["../escaped", "/absolute", "a/../../escaped", "a\\escaped", "a/./b", "a//b", "C:escape"]
    {
        let mut manifest = original.clone();
        manifest["files"][0]["path"] = path.into();
        let sealed = seal::seal(&cloud.key, &serde_json::to_vec(&manifest).unwrap()).unwrap();
        let hash = sha256_hex(&sealed);
        cloud.store.put(&hash, &sealed).unwrap();
        let mut changed = hashes.clone();
        changed[0] = hash;
        cloud.store.set_root(&receipt.pair, &changed).unwrap();
        assert!(replica::recover(&receipt.pair, &dest, &cloud).is_err(), "{path}");
        assert!(!dest.exists());
        assert!(!tmp.path().join("escaped").exists());
    }
}

#[cfg(unix)]
#[test]
fn running_replica_refuses_source_and_destination_symlinks() {
    use std::os::unix::fs::symlink;
    let tmp = tempfile::tempdir().unwrap();
    let source = tmp.path().join("source");
    fs::create_dir(&source).unwrap();
    let secret = tmp.path().join("secret");
    fs::write(&secret, b"private").unwrap();
    symlink(&secret, source.join("link")).unwrap();
    let cloud = cloud(&tmp.path().join("store"));
    assert!(replica::publish(&source, "session", &cloud).is_err());
    fs::remove_file(source.join("link")).unwrap();
    fs::write(source.join("journal"), b"journal").unwrap();
    let receipt = replica::publish(&source, "session", &cloud).unwrap();
    let dest = tmp.path().join("dest");
    symlink(tmp.path().join("absent"), &dest).unwrap();
    assert!(replica::recover(&receipt.pair, &dest, &cloud).is_err());
    assert!(!tmp.path().join("absent").exists());
    let alias = tmp.path().join("source-alias");
    symlink(&source, &alias).unwrap();
    assert!(replica::publish(&alias, "session", &cloud).is_err());
}

#[test]
fn running_replica_store_rejects_unsafe_root_and_hash_names() {
    let tmp = tempfile::tempdir().unwrap();
    let store = FsStore::new(tmp.path()).unwrap();
    for pair in ["../outside", ".", "..", "", "/outside"] {
        assert!(store.get_root(pair).is_err());
        assert!(store.set_root(pair, &[]).is_err());
    }
    for hash in ["a", "../../outside", "", "😎"] {
        assert!(store.get(hash).is_err());
        assert!(store.has(hash).is_err());
        assert!(store.set_root("valid", &[hash.to_string()]).is_err());
    }
}
