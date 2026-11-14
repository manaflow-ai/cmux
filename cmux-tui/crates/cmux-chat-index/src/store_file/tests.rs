use super::*;
use std::os::unix::fs::PermissionsExt;

/// The cache folder and file are owner-only whatever the umask: a folder an older build made
/// with the umask (775 under 002) is narrowed, and a temporary file a crashed run left under
/// the same pid (here 666) does not lend the new file its mode (ergo-walk2, 2026-10-25).
#[test]
fn the_cache_is_written_owner_only() {
    let root = std::env::temp_dir().join(format!(
        "chat-index-mode-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    let dir = root.join("chat-index");
    fs::create_dir_all(&dir).unwrap();
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o775)).unwrap();
    let path = dir.join("v1.json");
    let stale = path.with_extension(format!("tmp-{}", std::process::id()));
    fs::write(&stale, "{}").unwrap();
    fs::set_permissions(&stale, fs::Permissions::from_mode(0o666)).unwrap();
    write_json_private(&path, &serde_json::json!({"version": 1})).unwrap();
    let mode = |p: &Path| fs::metadata(p).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode(&dir), 0o700);
    assert_eq!(mode(&path), 0o600);
    let _ = fs::remove_dir_all(&root);
}
