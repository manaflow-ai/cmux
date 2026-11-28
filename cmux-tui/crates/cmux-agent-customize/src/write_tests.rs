use super::*;

fn store(dir: &Path) -> Store {
    Store::new(dir.join("state/agent-config"))
}

#[test]
fn replaces_with_a_backup_and_through_a_symlink() {
    let dir = tempfile::tempdir().unwrap();
    let store = store(dir.path());
    let real = fs::canonicalize(dir.path()).unwrap().join("real.json");
    fs::write(&real, "old").unwrap();
    #[cfg(unix)]
    {
        let link = dir.path().join("link.json");
        std::os::unix::fs::symlink(&real, &link).unwrap();
        store.replace(&link, "new").unwrap();
        assert!(fs::symlink_metadata(&link).unwrap().file_type().is_symlink());
    }
    #[cfg(not(unix))]
    store.replace(&real, "new").unwrap();
    assert_eq!(fs::read_to_string(&real).unwrap(), "new");
    assert_eq!(fs::read_to_string(store.backup_path(&real)).unwrap(), "old");
    // A second write keeps the original's backup and records the text it replaced.
    store.replace(&real, "newer").unwrap();
    assert_eq!(fs::read_to_string(store.backup_path(&real)).unwrap(), "old");
    assert_eq!(fs::read_to_string(store.last_backup_path(&real)).unwrap(), "new");
    let fresh = dir.path().join("sub/fresh.json");
    store.replace(&fresh, "{}").unwrap();
    assert_eq!(fs::read_to_string(&fresh).unwrap(), "{}");
    assert!(!store.backup_path(&fresh).exists());
    // Two folders' files of the same name never share a backup.
    assert_ne!(store.backup_path(&real), store.backup_path(&dir.path().join("x/real.json")));
    // Nothing but the files themselves is left beside them.
    let mut names: Vec<String> = fs::read_dir(dir.path())
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    let mut expected = vec!["real.json", "state", "sub"];
    if cfg!(unix) {
        expected.insert(0, "link.json");
    }
    assert_eq!(names, expected);
}

/// Something may already sit where a backup goes; writing a backup must replace a link there,
/// never write through it to the file it points at.
#[cfg(unix)]
#[test]
fn backups_never_write_through_a_planted_symlink() {
    let dir = tempfile::tempdir().unwrap();
    let store = store(dir.path());
    let outside = dir.path().join("outside.txt");
    fs::write(&outside, "keep me").unwrap();
    let project = fs::canonicalize(dir.path()).unwrap().join("project");
    fs::create_dir(&project).unwrap();
    let settings = project.join("settings.json");
    fs::write(&settings, "old").unwrap();
    fs::create_dir_all(store.dir().join("backups")).unwrap();
    std::os::unix::fs::symlink(&outside, store.backup_path(&settings)).unwrap();
    std::os::unix::fs::symlink(&outside, store.last_backup_path(&settings)).unwrap();
    store.replace(&settings, "new").unwrap();
    assert_eq!(fs::read_to_string(&outside).unwrap(), "keep me");
    assert_eq!(fs::read_to_string(&settings).unwrap(), "new");
    // Both backups are real files holding the prior text: a planted link is replaced, never
    // followed and never left standing in place of the first restore point.
    for backup in [store.backup_path(&settings), store.last_backup_path(&settings)] {
        assert!(!fs::symlink_metadata(&backup).unwrap().file_type().is_symlink());
        assert_eq!(fs::read_to_string(&backup).unwrap(), "old");
    }
}

/// A world-readable file stays world-readable after a write: its mode is put back once the new
/// text is in place.
#[cfg(unix)]
#[test]
fn a_shared_file_keeps_its_mode_through_a_write() {
    use std::os::unix::fs::PermissionsExt as _;
    let dir = tempfile::tempdir().unwrap();
    let store = store(dir.path());
    let shared = fs::canonicalize(dir.path()).unwrap().join("settings.json");
    fs::write(&shared, "{}").unwrap();
    fs::set_permissions(&shared, fs::Permissions::from_mode(0o644)).unwrap();
    store.replace(&shared, "{\"a\":1}").unwrap();
    assert_eq!(fs::metadata(&shared).unwrap().permissions().mode() & 0o777, 0o644);
    assert_eq!(fs::read_to_string(&shared).unwrap(), "{\"a\":1}");
}

/// The new text of a private (0600) file is never readable by others, not even while it is
/// being written, and neither are its backups or their folder.
#[cfg(unix)]
#[test]
fn private_files_stay_private_through_a_write() {
    use std::os::unix::fs::PermissionsExt as _;
    let dir = tempfile::tempdir().unwrap();
    let store = store(dir.path());
    let secret = fs::canonicalize(dir.path()).unwrap().join("config.toml");
    fs::write(&secret, "token = \"s3cret\"").unwrap();
    fs::set_permissions(&secret, fs::Permissions::from_mode(0o600)).unwrap();
    let mode = |p: &Path| fs::metadata(p).unwrap().permissions().mode() & 0o777;
    let probe = dir.path().join("probe");
    create_private(&probe).unwrap();
    assert_eq!(mode(&probe), 0o600);
    // Exclusive: never opens what is already there, a symlink included.
    assert!(create_private(&probe).is_err());
    store.replace(&secret, "token = \"other\"").unwrap();
    assert_eq!(mode(&secret), 0o600);
    assert_eq!(mode(&store.backup_path(&secret)), 0o600);
    assert_eq!(mode(&store.last_backup_path(&secret)), 0o600);
    assert_eq!(mode(&store.dir().join("backups")), 0o700);
}

/// A file's lock is the same before and after the file exists, and a second holder waits.
#[test]
fn one_file_has_one_lock() {
    let dir = tempfile::tempdir().unwrap();
    let store = store(dir.path());
    let missing = dir.path().join("a/b/settings.json");
    let before = store.lock_path(&resolved(&missing));
    fs::create_dir_all(missing.parent().unwrap()).unwrap();
    fs::write(&missing, "{}").unwrap();
    assert_eq!(store.lock_path(&resolved(&missing)), before);
    let held = store.lock(&missing).unwrap();
    let other = fs::OpenOptions::new().append(true).open(&before).unwrap();
    assert!(matches!(other.try_lock(), Err(fs::TryLockError::WouldBlock)));
    drop(held);
    assert!(other.try_lock().is_ok());
}
