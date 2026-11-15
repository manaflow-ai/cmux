use std::os::unix::fs::PermissionsExt;
use std::os::unix::fs::symlink;

use super::*;

struct TestState {
    directory: PathBuf,
    path: PathBuf,
}

impl Drop for TestState {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.directory);
    }
}

fn test_state(name: &str) -> TestState {
    let directory = std::env::temp_dir().join(format!(
        "cmux-machine-agent-{name}-{}-{}",
        std::process::id(),
        random_hex(8).unwrap()
    ));
    let mut builder = DirBuilder::new();
    builder.mode(0o700).create(&directory).unwrap();
    let path = directory.join("identity.json");
    TestState { directory, path }
}

#[test]
fn identity_is_stable_private_and_contains_no_pairing_code() {
    let state = test_state("identity");
    let private_directory = state.directory.join("created");
    let path = private_directory.join("identity.json");
    let first = load_or_create(&path).unwrap();
    let second = load_or_create(&path).unwrap();
    assert_eq!(first, second);
    assert_eq!(fs::metadata(&private_directory).unwrap().permissions().mode() & 0o777, 0o700);
    assert_eq!(fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
    assert_eq!(fs::metadata(&path).unwrap().nlink(), 1);
    let contents = fs::read_to_string(&path).unwrap();
    assert!(!contents.contains("pairing"));
    assert!(!contents.contains("ABCD-EFGH"));
}

#[test]
fn identity_rejects_permissive_hardlinked_or_symlinked_state() {
    let state = test_state("permissions");
    let identity = load_or_create(&state.path).unwrap();
    drop(identity);
    fs::set_permissions(&state.path, fs::Permissions::from_mode(0o644)).unwrap();
    assert!(load_or_create(&state.path).is_err());
    fs::set_permissions(&state.path, fs::Permissions::from_mode(0o600)).unwrap();

    let second_link = state.directory.join("second-link.json");
    fs::hard_link(&state.path, &second_link).unwrap();
    assert!(load_or_create(&state.path).is_err());
    fs::remove_file(second_link).unwrap();

    let target = state.directory.join("target.json");
    fs::rename(&state.path, &target).unwrap();
    symlink(&target, &state.path).unwrap();
    assert!(load_or_create(&state.path).is_err());
}

#[test]
fn identity_recovers_only_its_orphaned_temporary_hardlinks() {
    let state = test_state("orphaned-temporary-link");
    let identity = load_or_create(&state.path).unwrap();
    let orphan = state.directory.join(".identity.json.crashed.tmp");
    fs::hard_link(&state.path, &orphan).unwrap();
    assert_eq!(fs::metadata(&state.path).unwrap().nlink(), 2);

    assert_eq!(load_or_create(&state.path).unwrap(), identity);
    assert!(!orphan.exists());
    assert_eq!(fs::metadata(&state.path).unwrap().nlink(), 1);

    let unrelated = state.directory.join(".identity.json.unrelated.tmp");
    OpenOptions::new().write(true).create_new(true).mode(0o600).open(&unrelated).unwrap();
    assert_eq!(load_or_create(&state.path).unwrap(), identity);
    assert!(unrelated.exists());
}

#[test]
fn identity_retries_the_live_two_link_creation_window_once() {
    let state = test_state("live-creation-link");
    let identity = load_or_create(&state.path).unwrap();
    let temporary = state.directory.join(".identity.json.live.tmp");
    fs::hard_link(&state.path, &temporary).unwrap();
    let remover = thread::spawn(move || {
        thread::sleep(Duration::from_millis(1));
        fs::remove_file(temporary).unwrap();
    });

    assert_eq!(load_with_link_retry(&state.path).unwrap(), identity);
    remover.join().unwrap();
}

#[test]
fn identity_rejects_permissive_or_symlinked_parent() {
    let state = test_state("parent");
    fs::set_permissions(&state.directory, fs::Permissions::from_mode(0o755)).unwrap();
    assert!(load_or_create(&state.path).is_err());
    fs::set_permissions(&state.directory, fs::Permissions::from_mode(0o700)).unwrap();

    let real = state.directory.join("real");
    let link = state.directory.join("link");
    DirBuilder::new().mode(0o700).create(&real).unwrap();
    symlink(&real, &link).unwrap();
    assert!(load_or_create(&link.join("identity.json")).is_err());
}

#[test]
fn registration_lock_is_exclusive_per_identity_and_session() {
    let state = test_state("lock");
    let identity = load_or_create(&state.path).unwrap();
    let session = SessionName::new("agents").unwrap();
    let first = acquire_registration_lock(&state.path, &identity, &session).unwrap();
    let error = acquire_registration_lock(&state.path, &identity, &session).err().unwrap();
    assert!(error.downcast_ref::<RegistrationAlreadyRunning>().is_some());
    let other_session = SessionName::new("other").unwrap();
    let other = acquire_registration_lock(&state.path, &identity, &other_session).unwrap();
    drop(other);
    drop(first);
    acquire_registration_lock(&state.path, &identity, &session).unwrap();
}
