use super::*;

/// The unattended folder is owner-only whatever the umask, and one an older build made with
/// the umask (775 under 002) is narrowed (ergo-walk2, 2026-10-25).
#[test]
fn the_unattended_folder_is_owner_only() {
    use std::os::unix::fs::PermissionsExt;
    let home = std::env::temp_dir().join(format!("acpmux-unatt-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(home.join("unattended")).unwrap();
    let wide = std::fs::Permissions::from_mode(0o775);
    std::fs::set_permissions(home.join("unattended"), wide).unwrap();
    let dir = unattended_cwd_in(&home, None);
    assert_eq!(dir, home.join("unattended"));
    assert_eq!(std::fs::metadata(&dir).unwrap().permissions().mode() & 0o777, 0o700);
    let _ = std::fs::remove_dir_all(&home);
}
