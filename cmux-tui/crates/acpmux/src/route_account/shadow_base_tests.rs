use super::*;

#[test]
fn a_shadows_base_is_the_login_folder_even_when_its_sessions_live_elsewhere() {
    let root = std::env::temp_dir().join(format!("acpmux-shadow-base-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    let (base, store, shadow) = (root.join("base"), root.join("store"), root.join("shadow"));
    std::fs::create_dir_all(store.join("sessions")).unwrap();
    std::fs::create_dir_all(&base).unwrap();
    std::fs::write(base.join("auth.json"), "{}").unwrap();
    std::os::unix::fs::symlink(store.join("sessions"), base.join("sessions")).unwrap();
    crate::route_shadow::link(&shadow, &base).unwrap();
    assert_eq!(base_of_shadow(&shadow), Some(base.clone()));
    assert_eq!(base_of_shadow(&base), None, "a login with its sessions elsewhere is no shadow");
    let _ = std::fs::remove_dir_all(&root);
}
