use super::cmux_vm_at;

/// A fresh machine root with these markers (removed by the caller).
fn root(kind: Option<&str>, team: bool) -> std::path::PathBuf {
    use std::sync::atomic::{AtomicU32, Ordering};
    static N: AtomicU32 = AtomicU32::new(0);
    let n = N.fetch_add(1, Ordering::SeqCst);
    let d = std::env::temp_dir().join(format!("acpmux-vm-marker-{}-{n}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    if let Some(kind) = kind {
        std::fs::create_dir_all(d.join("etc/cmux")).unwrap();
        std::fs::write(d.join("etc/cmux/vm-kind"), format!("{kind}\n")).unwrap();
    }
    if team {
        std::fs::create_dir_all(d.join("srv/team")).unwrap();
    }
    d
}

fn admits(kind: Option<&str>, team: bool) -> bool {
    let d = root(kind, team);
    let admitted = cmux_vm_at(&d);
    let _ = std::fs::remove_dir_all(&d);
    admitted
}

#[test]
fn only_an_owner_vm_without_team_files_is_cmux_created() {
    assert!(admits(Some("owner"), false));
    assert!(!admits(Some("owner"), true), "team files: shared");
    assert!(!admits(Some("team"), false), "a team VM");
    assert!(!admits(None, false), "a personal or SSH-added machine");
    assert!(!admits(Some("ownerx"), false));
}

/// A team files root this user cannot see into (a root-only `/srv`) is not "absent".
#[cfg(unix)]
#[test]
fn a_team_files_root_that_cannot_be_checked_counts_as_there() {
    use std::os::unix::fs::PermissionsExt;
    let d = root(Some("owner"), true);
    std::fs::set_permissions(d.join("srv"), std::fs::Permissions::from_mode(0o000)).unwrap();
    // Root reads through a 000 folder: this check means nothing there.
    let blocked = std::fs::symlink_metadata(d.join("srv/team")).is_err();
    let admitted = cmux_vm_at(&d);
    std::fs::set_permissions(d.join("srv"), std::fs::Permissions::from_mode(0o755)).unwrap();
    let _ = std::fs::remove_dir_all(&d);
    if blocked {
        assert!(!admitted, "an unreadable /srv/team must refuse");
    }
}
