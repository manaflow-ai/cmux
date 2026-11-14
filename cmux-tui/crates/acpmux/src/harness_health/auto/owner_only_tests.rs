use super::*;

/// `harness-auto-update.json` is owner-only whatever the umask, like the rest of the acpmux
/// home (ergo-walk2, 2026-10-25), and a temporary file a crashed run left changes nothing.
#[test]
fn the_auto_update_list_is_saved_owner_only() {
    use std::os::unix::fs::PermissionsExt;
    let dir = std::env::temp_dir().join(format!("acpmux-auto-mode-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("harness-auto-update.json");
    let stale = path.with_extension("json.tmp");
    std::fs::write(&stale, "[]").unwrap();
    std::fs::set_permissions(&stale, std::fs::Permissions::from_mode(0o666)).unwrap();
    let service = HealthService::new();
    service.attach(super::super::Settings {
        auto_update: Some(path.clone()),
        home: dir.clone(),
        ..Default::default()
    });
    service.set_auto_update("codex", true).unwrap();
    let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o600);
    assert!(std::fs::read_to_string(&path).unwrap().contains("codex"));
    let _ = std::fs::remove_dir_all(&dir);
}
