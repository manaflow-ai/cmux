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
