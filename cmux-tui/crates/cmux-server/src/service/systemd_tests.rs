use std::path::Path;

use super::{procs_in, unquote_env_value};

/// What `systemctl show-environment` prints (systemd 255
/// `shell_maybe_quote`, POSIX): plain values as they are, others in
/// `$'...'` with C escapes.
#[test]
fn show_environment_values_are_read_as_systemd_quotes_them() {
    assert_eq!(unquote_env_value("/srv/state").as_deref(), Some("/srv/state"));
    assert_eq!(
        unquote_env_value(r"$'/srv/a b\'s \\x\t\x41\101'").as_deref(),
        Some("/srv/a b's \\x\tAA")
    );
    assert_eq!(unquote_env_value(r"$'caf\xc3\xa9'").as_deref(), Some("café"));
    // Not what systemd prints: refused, never guessed.
    for raw in ["'/srv/a b'", "\"/srv\"", "$'/srv\\q'", "$'/srv", "a$b"] {
        assert_eq!(unquote_env_value(raw), None, "{raw}");
    }
}

/// `root` as a mounted hierarchy (its marker file) with `group`'s
/// `cgroup.procs` listing `pids` (no file when None).
fn hierarchy(root: &Path, marker: &str, group: &str, pids: Option<&str>) {
    std::fs::create_dir_all(root).unwrap();
    std::fs::write(root.join(marker), "").unwrap();
    if let Some(pids) = pids {
        let dir = root.join(group);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("cgroup.procs"), pids).unwrap();
    }
}

/// Hybrid layout: the v2 mount has no processes of the unit, the v1
/// `systemd` hierarchy (where systemd tracks them) has two. They count.
#[test]
fn every_mounted_hierarchy_is_read() {
    let tmp = tempfile::tempdir().unwrap();
    let group = "user.slice/app.slice/cmux-server.service";
    let (unified, systemd) = (tmp.path().join("unified"), tmp.path().join("systemd"));
    hierarchy(&unified, "cgroup.controllers", group, Some(""));
    hierarchy(&systemd, "cgroup.procs", group, Some("41\n42\n"));
    let roots = [(unified.as_path(), "cgroup.controllers"), (systemd.as_path(), "cgroup.procs")];
    assert_eq!(procs_in(&roots, group), Ok(Some(2)));
    // Gone from one hierarchy, still listed in the other.
    std::fs::remove_dir_all(unified.join(group)).unwrap();
    assert_eq!(procs_in(&roots, group), Ok(Some(2)));
    // Gone from both: none left.
    std::fs::remove_dir_all(systemd.join(group)).unwrap();
    assert_eq!(procs_in(&roots, group), Ok(None));
}

/// No hierarchy mounted: cmux cannot tell, which is never "none".
#[test]
fn no_mounted_hierarchy_is_an_error() {
    let tmp = tempfile::tempdir().unwrap();
    let roots = [(tmp.path(), "cgroup.controllers")];
    assert!(procs_in(&roots, "/a.service").is_err());
}
