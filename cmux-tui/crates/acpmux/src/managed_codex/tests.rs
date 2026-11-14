use super::*;

#[test]
fn binary_without_a_matching_ready_marker_is_not_ready() {
    let dir = tempfile::tempdir().unwrap();
    let binary = dir.path().join("codex");
    let marker = dir.path().join("ready.json");
    std::fs::write(&binary, b"partial").unwrap();
    assert!(!is_ready_at(&binary, &marker, "abc"), "no marker");
    std::fs::write(&marker, b"not json").unwrap();
    assert!(!is_ready_at(&binary, &marker, "abc"), "corrupt marker");
    std::fs::write(&marker, br#"{"version":"0.0.1","sha256":"abc"}"#).unwrap();
    assert!(!is_ready_at(&binary, &marker, "abc"), "other version");
    std::fs::write(&marker, format!(r#"{{"version":"{VERSION}","sha256":"zzz"}}"#)).unwrap();
    assert!(!is_ready_at(&binary, &marker, "abc"), "other hash");
    std::fs::write(&marker, format!(r#"{{"version":"{VERSION}","sha256":"abc"}}"#)).unwrap();
    assert!(is_ready_at(&binary, &marker, "abc"));
    std::fs::remove_file(&binary).unwrap();
    assert!(!is_ready_at(&binary, &marker, "abc"), "marker without binary");
    assert!(!is_ready_at(&binary, &marker, ""), "unsupported platform");
}

#[cfg(unix)]
fn install(dir: &Path, body: &str) {
    std::fs::create_dir_all(dir).unwrap();
    std::fs::write(dir.join("codex"), body).unwrap();
    std::fs::write(dir.join("ready.json"), "{}").unwrap();
}

#[cfg(unix)]
fn current(base: &Path) -> String {
    std::fs::read_to_string(base.join(CURRENT).join("codex")).unwrap()
}

#[cfg(unix)]
#[test]
fn activation_swaps_the_current_link_and_prunes_the_old_install() {
    let base = tempfile::tempdir().unwrap();
    let (old, new) =
        (base.path().join(format!("{VERSION}-1-1")), base.path().join(format!("{VERSION}-2-2")));
    install(&old, "old");
    activate(base.path(), &old).unwrap();
    assert_eq!(current(base.path()), "old");
    install(&new, "new");
    age(&old);
    activate(base.path(), &new).unwrap();
    assert_eq!(current(base.path()), "new");
    assert!(!old.exists(), "the superseded install is removed");
    assert!(!base.path().join(format!(".current-{}", std::process::id())).exists());
}

#[cfg(unix)]
#[test]
fn an_unfinished_install_changes_nothing() {
    let base = tempfile::tempdir().unwrap();
    let old = base.path().join(format!("{VERSION}-1-1"));
    install(&old, "old");
    activate(base.path(), &old).unwrap();
    // No ready marker: not a finished install, so the link is never touched.
    let half = base.path().join(format!("{VERSION}-2-2"));
    std::fs::create_dir_all(&half).unwrap();
    std::fs::write(half.join("codex"), "half").unwrap();
    assert!(activate(base.path(), &half).is_err());
    assert_eq!(current(base.path()), "old");
    assert!(old.exists());
}

#[cfg(unix)]
fn age(dir: &Path) {
    let old = std::time::SystemTime::now() - PRUNE_GRACE * 2;
    std::fs::File::open(dir).unwrap().set_modified(old).unwrap();
}

#[cfg(unix)]
#[test]
fn prune_never_removes_what_current_names_even_when_another_installer_swapped() {
    let base = tempfile::tempdir().unwrap();
    let (a, b) =
        (base.path().join(format!("{VERSION}-1-1")), base.path().join(format!("{VERSION}-2-2")));
    install(&a, "a");
    install(&b, "b");
    // Installer A activated, then B swapped before A pruned: A's prune must keep B's runtime.
    activate(base.path(), &a).unwrap();
    activate(base.path(), &b).unwrap();
    age(&a);
    age(&b);
    prune(base.path());
    assert_eq!(current(base.path()), "b");
    assert!(b.exists());
    // And one that is not named, and is old, goes.
    assert!(!a.exists());
}

#[cfg(unix)]
#[test]
fn prune_leaves_a_recent_install_another_installer_has_not_linked_yet() {
    let base = tempfile::tempdir().unwrap();
    let (live, pending) =
        (base.path().join(format!("{VERSION}-1-1")), base.path().join(format!("{VERSION}-2-2")));
    install(&live, "live");
    install(&pending, "pending");
    activate(base.path(), &live).unwrap();
    prune(base.path());
    assert!(pending.exists(), "a fresh directory may be mid-install elsewhere");
    activate(base.path(), &pending).unwrap();
    assert_eq!(current(base.path()), "pending");
}
