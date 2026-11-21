use std::os::unix::fs::{PermissionsExt, symlink};

use super::*;

struct TestStateRoot {
    path: PathBuf,
}

impl TestStateRoot {
    fn create(label: &str) -> Self {
        let path = std::env::temp_dir().join(format!(
            "cmux-provider-notice-identity-{label}-{}-{}",
            std::process::id(),
            random_hex(8).unwrap()
        ));
        let mut builder = DirBuilder::new();
        builder.mode(0o700).create(&path).unwrap();
        Self { path }
    }
}

impl Drop for TestStateRoot {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

fn load_once(state_root: &Path) -> anyhow::Result<OpaqueId> {
    let lease = acquire(state_root)?;
    Ok(lease.consumer_id().clone())
}

#[test]
fn identity_is_stable_and_private() {
    let state = TestStateRoot::create("private");
    let first = load_once(&state.path).unwrap();
    let second = load_once(&state.path).unwrap();
    let path = identity_path(&state.path);
    let parent = path.parent().unwrap();
    let lock = parent.join(LOCK_FILE);

    assert_eq!(second, first);
    assert_eq!(fs::metadata(parent).unwrap().permissions().mode() & 0o777, 0o700);
    assert_eq!(fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
    assert_eq!(fs::metadata(&path).unwrap().nlink(), 1);
    assert_eq!(fs::metadata(&lock).unwrap().permissions().mode() & 0o777, 0o600);
    assert_eq!(fs::metadata(&lock).unwrap().nlink(), 1);
}

#[test]
fn identity_rejects_permissive_hardlinked_or_symlinked_state() {
    let state = TestStateRoot::create("file-safety");
    load_once(&state.path).unwrap();
    let path = identity_path(&state.path);
    fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
    assert!(load_once(&state.path).is_err());
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();

    let second_link = path.with_file_name("second-link.json");
    fs::hard_link(&path, &second_link).unwrap();
    assert!(load_once(&state.path).is_err());
    fs::remove_file(second_link).unwrap();

    let target = path.with_file_name("target.json");
    fs::rename(&path, &target).unwrap();
    symlink(&target, &path).unwrap();
    assert!(load_once(&state.path).is_err());
}

#[test]
fn identity_rejects_permissive_or_symlinked_parent() {
    let state = TestStateRoot::create("parent-safety");
    let path = identity_path(&state.path);
    let parent = path.parent().unwrap();
    DirBuilder::new().mode(0o755).create(parent).unwrap();
    assert!(load_once(&state.path).is_err());
    fs::remove_dir(parent).unwrap();

    let real = state.path.join("real");
    DirBuilder::new().mode(0o700).create(&real).unwrap();
    symlink(&real, parent).unwrap();
    assert!(load_once(&state.path).is_err());
}

#[test]
fn identity_rejects_permissive_hardlinked_or_symlinked_lock() {
    let state = TestStateRoot::create("lock-safety");
    load_once(&state.path).unwrap();
    let lock = identity_path(&state.path).parent().unwrap().join(LOCK_FILE);

    fs::set_permissions(&lock, fs::Permissions::from_mode(0o644)).unwrap();
    assert!(load_once(&state.path).is_err());
    fs::set_permissions(&lock, fs::Permissions::from_mode(0o600)).unwrap();

    let second_link = lock.with_file_name("second-lock");
    fs::hard_link(&lock, &second_link).unwrap();
    assert!(load_once(&state.path).is_err());
    fs::remove_file(second_link).unwrap();

    let target = lock.with_file_name("target-lock");
    fs::rename(&lock, &target).unwrap();
    symlink(&target, &lock).unwrap();
    assert!(load_once(&state.path).is_err());
}

#[test]
fn identity_parser_is_bounded() {
    let state = TestStateRoot::create("bounded");
    load_once(&state.path).unwrap();
    let path = identity_path(&state.path);
    fs::write(&path, vec![b'x'; MAX_STATE_BYTES as usize + 1]).unwrap();
    let error = load_once(&state.path).unwrap_err();
    assert!(error.to_string().contains("too large"));
}

#[test]
fn identity_rejects_unsupported_version() {
    let state = TestStateRoot::create("unsupported-version");
    let consumer_id = load_once(&state.path).unwrap();
    let path = identity_path(&state.path);
    let future = StoredIdentity { version: STATE_VERSION + 1, consumer_id };
    fs::write(&path, serde_json::to_vec(&future).unwrap()).unwrap();

    let error = load_once(&state.path).unwrap_err();
    assert!(error.to_string().contains("unsupported provider notice identity version"));
}

#[test]
fn identity_lease_is_exclusive_and_reuses_the_cursor_after_release() {
    let state = TestStateRoot::create("exclusive");
    let first = acquire(&state.path).unwrap();
    let first_id = first.consumer_id().clone();
    let error = acquire(&state.path).err().unwrap();
    assert!(error.downcast_ref::<ProviderNoticeIdentityInUse>().is_some());

    drop(first);
    let restarted = acquire(&state.path).unwrap();
    assert_eq!(restarted.consumer_id(), &first_id);

    let path = identity_path(&state.path);
    assert_eq!(fs::metadata(&path).unwrap().nlink(), 1);
    let temporary_prefix = format!(".{IDENTITY_FILE}.");
    assert!(
        fs::read_dir(path.parent().unwrap())
            .unwrap()
            .filter_map(Result::ok)
            .all(|entry| !entry.file_name().to_string_lossy().starts_with(&temporary_prefix))
    );
}
