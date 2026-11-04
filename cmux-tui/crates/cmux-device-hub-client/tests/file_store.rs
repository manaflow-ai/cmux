//! The headless key file store.

use cmux_device_hub_client::{Assurance, FileKeyStore, IdentityError, KeyStore, Platform};

#[test]
fn creates_once_and_loads_the_same_identity() {
    let dir = tempfile::tempdir().unwrap();
    let store = FileKeyStore::new(dir.path().join("hub"), Platform::Linux);
    let first = store.load_or_create().unwrap();
    let again = store.load_or_create().unwrap();
    assert_eq!(first.id(), again.id());
    assert_eq!(first.signing_key_base64(), again.signing_key_base64());
    assert_eq!(first.agreement_key_base64(), again.agreement_key_base64());
    assert_eq!(first.assurance(), Assurance::File);
    assert_eq!(first.platform(), Platform::Linux);
    assert_eq!(first.id(), first.id().to_ascii_lowercase());
    assert!(uuid_is_valid(first.id()));

    store.reset().unwrap();
    let fresh = store.load_or_create().unwrap();
    assert_ne!(fresh.id(), first.id());
    assert_ne!(fresh.signing_key_base64(), first.signing_key_base64());
}

fn uuid_is_valid(id: &str) -> bool {
    id.len() == 36 && id.chars().all(|c| c == '-' || c.is_ascii_hexdigit())
}

#[test]
fn a_malformed_file_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let store = FileKeyStore::new(dir.path(), Platform::Linux);
    write_private(store.path(), b"{\"v\":1}");
    assert!(matches!(store.load_or_create(), Err(IdentityError::Corrupt(_))));
}

#[cfg(unix)]
fn write_private(path: &std::path::Path, data: &[u8]) {
    use std::io::Write as _;
    use std::os::unix::fs::OpenOptionsExt as _;
    let mut file =
        std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(path).unwrap();
    file.write_all(data).unwrap();
}

#[cfg(not(unix))]
fn write_private(path: &std::path::Path, data: &[u8]) {
    std::fs::write(path, data).unwrap();
}

#[cfg(unix)]
mod unix {
    use super::*;
    use std::os::unix::fs::PermissionsExt as _;

    #[test]
    fn the_file_is_created_0600_in_a_0700_directory() {
        let dir = tempfile::tempdir().unwrap();
        let store = FileKeyStore::new(dir.path().join("state"), Platform::Linux);
        store.load_or_create().unwrap();
        let mode = std::fs::metadata(store.path()).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
        let dir_mode =
            std::fs::metadata(dir.path().join("state")).unwrap().permissions().mode() & 0o777;
        assert_eq!(dir_mode, 0o700);
        // No temporary file is left next to it.
        let names: Vec<_> = std::fs::read_dir(dir.path().join("state"))
            .unwrap()
            .map(|entry| entry.unwrap().file_name().into_string().unwrap())
            .collect();
        assert_eq!(names, [FileKeyStore::FILE_NAME]);
    }

    #[test]
    fn a_file_others_can_read_is_refused() {
        for mode in [0o640, 0o604, 0o644, 0o660, 0o666] {
            let dir = tempfile::tempdir().unwrap();
            let store = FileKeyStore::new(dir.path(), Platform::Linux);
            let identity = store.load_or_create().unwrap();
            std::fs::set_permissions(store.path(), std::fs::Permissions::from_mode(mode)).unwrap();
            match store.load_or_create() {
                Err(IdentityError::InsecureKeyFile { mode: seen, .. }) => assert_eq!(seen, mode),
                other => panic!("mode {mode:o} loaded: {other:?}"),
            }
            // It is not replaced by a new identity either.
            std::fs::set_permissions(store.path(), std::fs::Permissions::from_mode(0o600)).unwrap();
            assert_eq!(store.load_or_create().unwrap().id(), identity.id());
        }
    }

    #[test]
    fn a_symlinked_key_file_is_refused() {
        let dir = tempfile::tempdir().unwrap();
        let elsewhere = tempfile::tempdir().unwrap();
        let real = FileKeyStore::new(elsewhere.path(), Platform::Linux);
        real.load_or_create().unwrap();
        let store = FileKeyStore::new(dir.path(), Platform::Linux);
        std::os::unix::fs::symlink(real.path(), store.path()).unwrap();
        assert!(store.load_or_create().is_err());
    }
}
