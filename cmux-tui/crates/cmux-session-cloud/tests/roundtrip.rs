use cmux_session_cloud::store::FsStore;
use cmux_session_cloud::{Cloud, fetch, offload, seal::Key, stub};

fn cloud(dir: &std::path::Path) -> Cloud {
    Cloud {
        store: Box::new(FsStore::new(dir.join("store")).unwrap()),
        key: Key::generate().unwrap(),
        root_prefix: String::new(),
    }
}

#[test]
fn a_file_goes_to_the_store_and_comes_back_byte_for_byte() {
    let dir = tempfile::tempdir().unwrap();
    let cloud = cloud(dir.path());
    let file = dir.path().join("cold.zst");
    let bytes: Vec<u8> = (0..300_000u32).flat_map(|i| i.to_le_bytes()).collect();
    std::fs::write(&file, &bytes).unwrap();

    let record = offload::upload(&file, &cloud).unwrap();
    assert!(file.exists(), "upload changes nothing on the disk");
    assert_eq!(offload::commit(&file, &record).unwrap(), Some(bytes.len() as u64));
    assert!(!file.exists());
    let stub_path = stub::stub_path(&file);
    assert_eq!(stub::read(&stub_path).unwrap(), record);

    assert_eq!(fetch::fetch_file(&stub_path, &cloud).unwrap(), bytes.len() as u64);
    assert_eq!(std::fs::read(&file).unwrap(), bytes);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&file).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "a fetched file is owner-only");
    }
}

#[test]
fn a_file_that_changed_after_the_upload_is_kept() {
    let dir = tempfile::tempdir().unwrap();
    let cloud = cloud(dir.path());
    let file = dir.path().join("cold.zst");
    std::fs::write(&file, b"first").unwrap();
    let record = offload::upload(&file, &cloud).unwrap();
    std::fs::write(&file, b"second").unwrap();
    assert_eq!(offload::commit(&file, &record).unwrap(), None);
    assert!(file.exists());
    assert!(!stub::stub_path(&file).exists());
}

#[test]
fn a_blob_from_another_key_or_a_tampered_store_does_not_open() {
    let dir = tempfile::tempdir().unwrap();
    let cloud = cloud(dir.path());
    let file = dir.path().join("cold.zst");
    std::fs::write(&file, b"history").unwrap();
    let record = offload::upload(&file, &cloud).unwrap();
    offload::commit(&file, &record).unwrap();
    let other = Cloud {
        store: Box::new(FsStore::new(dir.path().join("store")).unwrap()),
        key: Key::generate().unwrap(),
        root_prefix: String::new(),
    };
    assert!(fetch::fetch_file(&stub::stub_path(&file), &other).is_err());
    assert!(!file.exists(), "a failed fetch writes nothing");
    let blob = dir.path().join("store").join(&record.blob[..2]).join(&record.blob);
    let mut sealed = std::fs::read(&blob).unwrap();
    sealed[40] ^= 1;
    std::fs::write(&blob, sealed).unwrap();
    assert!(fetch::fetch_file(&stub::stub_path(&file), &cloud).is_err());
}

#[derive(Default)]
struct Reads {
    blobs: Vec<String>,
    drop_at: Option<String>,
}

struct CountingStore {
    files: FsStore,
    reads: std::sync::Arc<std::sync::Mutex<Reads>>,
}

impl cmux_session_cloud::store::BlobStore for CountingStore {
    fn put(&self, id: &str, bytes: &[u8]) -> anyhow::Result<()> {
        self.files.put(id, bytes)
    }

    fn get(&self, id: &str) -> anyhow::Result<Vec<u8>> {
        let mut reads = self.reads.lock().unwrap();
        reads.blobs.push(id.to_owned());
        if reads.drop_at.as_deref() == Some(id) {
            reads.drop_at = None;
            anyhow::bail!("connection dropped");
        }
        self.files.get(id)
    }

    fn has(&self, id: &str) -> anyhow::Result<bool> {
        self.files.has(id)
    }

    fn set_root(&self, pair: &str, hashes: &[String]) -> anyhow::Result<()> {
        self.files.set_root(pair, hashes)
    }

    fn describe(&self) -> String {
        self.files.describe()
    }
}

#[test]
fn tail_opens_in_one_response_and_backfill_resumes_by_verified_id() -> anyhow::Result<()> {
    use cmux_session_pack::{Params, Store, hex, pack, unhex};
    use std::sync::{Arc, Mutex};

    let dir = tempfile::tempdir()?;
    let reads = Arc::new(Mutex::new(Reads::default()));
    let cloud = Cloud {
        store: Box::new(CountingStore {
            files: FsStore::new(dir.path().join("cloud"))?,
            reads: reads.clone(),
        }),
        key: Key::generate()?,
        root_prefix: String::new(),
    };
    let shared = "from the first turn ".repeat(80);
    let lines: Vec<_> = (0..8u64)
        .map(|i| {
            let body = if i == 0 || i == 7 { shared.clone() } else { format!("older turn {i}") };
            format!(r#"{{"seq":{i},"at":{i},"dir":"in","kind":"turn_started","text":"{body}"}}"#)
        })
        .collect();
    let log = lines.join("\n"); // Also preserve a last record without a newline.
    let file = dir.path().join("events.ndjson");
    std::fs::write(&file, &log)?;
    let source = Store::new(dir.path().join("source"));
    let params = Params { segment_bytes: 1, level: 1, ..Default::default() };
    let (manifest, _) = pack(&source, "chat", &[file], &params, true).unwrap();
    let record = offload::upload_pack(&source, "chat", 1, &cloud)?;
    let path = dir.path().join("cold.zst.cloud");
    std::fs::write(&path, serde_json::to_vec(&record)?)?;
    let stub::History::Pack(record) = stub::history(&path)? else { panic!("expected v2") };

    let cache_path = dir.path().join("receiver");
    let cache = Store::new(&cache_path);
    let opened = fetch::open_pack(&record, &cache, &cloud)?;
    assert_eq!(opened.manifest, manifest);
    assert_eq!(record.first_line, 7);
    assert_eq!(opened.read_lines(7..8).unwrap(), [lines[7].as_bytes()]);
    assert_eq!(reads.lock().unwrap().blobs, std::slice::from_ref(&record.tail.blob));
    let (blob, table) = manifest.segments[0].blob_chunks.as_ref().unwrap();
    assert!(cache.has(&unhex(blob).unwrap()) && cache.has(&unhex(table).unwrap()));
    assert!(!cache.has(&unhex(&manifest.segments[0].events).unwrap()));
    let ids = manifest.chunk_ids().unwrap();
    let older: Vec<_> = ids
        .iter()
        .filter_map(|id| record.older.get(&hex(id)).map(|part| (*id, part.clone())))
        .collect();
    assert!(older.len() > 2);
    reads.lock().unwrap().drop_at = Some(older[1].1.blob.clone());
    assert!(fetch::backfill(&record, &cache, &ids, &cloud).is_err());
    assert!(cache.verified(&older[0].0).unwrap());
    assert!(!cache.has(&older[1].0));
    drop(opened);
    drop(cache);

    // A new process has only the on-disk cache and the stub.
    let cache = Store::new(&cache_path);
    reads.lock().unwrap().blobs.clear();
    let resumed = fetch::open_pack(&record, &cache, &cloud)?;

    // A valid sealed blob containing a different valid chunk still fails the pack id check.
    let mut swapped = record.clone();
    swapped.older.insert(hex(&older[1].0), older[2].1.clone());
    assert!(fetch::backfill(&swapped, &cache, &[older[1].0], &cloud).is_err());
    assert!(!cache.has(&older[1].0));
    fetch::backfill(&record, &cache, &ids, &cloud)?;
    let fetched = reads.lock().unwrap().blobs.clone();
    assert!(!fetched.contains(&record.tail.blob));
    assert!(!fetched.contains(&older[0].1.blob));
    assert_eq!(fetched[1..], older[1..].iter().map(|(_, p)| p.blob.clone()).collect::<Vec<_>>());
    let mut restored = Vec::new();
    resumed.cat(&mut restored).unwrap();
    assert_eq!(restored, log.as_bytes());

    // Even a correctly named file on disk must still verify on resume.
    let id = hex(&older[0].0);
    std::fs::write(cache_path.join("chunks").join(&id[..2]).join(id), b"cut short")?;
    reads.lock().unwrap().blobs.clear();
    fetch::backfill(&record, &cache, &ids, &cloud)?;
    assert_eq!(reads.lock().unwrap().blobs, [older[0].1.blob.clone()]);
    assert!(cache.verified(&older[0].0).unwrap());
    Ok(())
}

#[test]
fn malformed_blob_addresses_are_errors_without_panicking() {
    use cmux_session_cloud::store::BlobStore;
    let dir = tempfile::tempdir().unwrap();
    let store = FsStore::new(dir.path()).unwrap();
    for address in ["", "a", "☃", "../outside", &"g".repeat(64)] {
        assert_eq!(store.get(address).unwrap_err().to_string(), "sync.invalid_digest");
        assert_eq!(store.has(address).unwrap_err().to_string(), "sync.invalid_digest");
    }
}
