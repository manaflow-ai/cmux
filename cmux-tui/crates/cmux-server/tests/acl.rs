//! macOS extended ACLs on the LaunchAgent log (Codex R-004): what cmux
//! strips from its own log folder and log as it opens them.

#![cfg(target_os = "macos")]

use std::path::Path;

/// Adds a macOS ACL entry (`chmod +a`) to `path`.
fn add_acl(path: &Path, entry: &str) {
    let status =
        std::process::Command::new("/bin/chmod").arg("+a").arg(entry).arg(path).status().unwrap();
    assert!(status.success(), "chmod +a {entry} {}", path.display());
}

/// macOS: what cmux strips from its own log folder and log as it opens them:
/// ACL entries that allow writing, never a deny entry.
#[test]
fn the_launchagent_log_loses_acl_write_grants_and_keeps_denies() {
    let tmp = tempfile::tempdir().unwrap();
    let log = tmp.path().join("server.log");
    std::fs::write(&log, b"").unwrap();
    add_acl(&log, "group:everyone deny delete");
    add_acl(&log, "group:everyone allow write,append");
    assert!(cmux_server::acl::write_grants(&log).unwrap());
    let file = std::fs::OpenOptions::new().append(true).open(&log).unwrap();
    assert!(cmux_server::acl::strip_write_grants(&file).unwrap());
    assert!(!cmux_server::acl::write_grants(&log).unwrap());
    let listing = std::process::Command::new("/bin/ls").arg("-le").arg(&log).output().unwrap();
    let listing = String::from_utf8_lossy(&listing.stdout);
    assert!(listing.contains("deny delete"), "{listing}");
    assert!(!listing.contains("allow"), "{listing}");
}
