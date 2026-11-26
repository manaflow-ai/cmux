use super::*;

fn mac_user(legacy: bool) -> Layout {
    let env = LayoutEnv {
        home: Some("/Users/ana".to_owned()),
        uid: Some(501),
        mac_legacy_install: legacy,
        ..LayoutEnv::default()
    };
    layout(InstallMode::User, Platform::MacOs, &env).unwrap()
}

#[test]
fn macos_user_new_install_uses_cmux_next_roots() {
    let l = mac_user(false);
    assert_eq!(l.root.as_str(), "/Users/ana/Library/Application Support/cmux-next");
    assert_eq!(l.state.as_str(), "/Users/ana/Library/Application Support/cmux-next/server");
    assert_eq!(l.config_file.as_str(), "/Users/ana/.config/cmux-next/server.json");
}

#[test]
fn macos_user_legacy_install_keeps_its_layout() {
    let l = mac_user(true);
    assert_eq!(l.root.as_str(), "/Users/ana/Library/Application Support/cmux");
    assert_eq!(l.config_file.as_str(), "/Users/ana/.config/cmux/server.json");
}

#[test]
fn legacy_layout_is_kept_only_while_cmux_next_has_no_config() {
    let home = std::env::temp_dir().join(format!("cmux-layout-legacy-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    assert!(!macos_user_keeps_legacy_layout(&home));
    let old = home.join(".config/cmux");
    std::fs::create_dir_all(&old).unwrap();
    std::fs::write(old.join("server.json"), "{}").unwrap();
    assert!(macos_user_keeps_legacy_layout(&home));
    let new = home.join(".config/cmux-next");
    std::fs::create_dir_all(&new).unwrap();
    std::fs::write(new.join("server.json"), "{}").unwrap();
    assert!(!macos_user_keeps_legacy_layout(&home));
    std::fs::remove_dir_all(&home).unwrap();
}

#[test]
fn layout_detects_an_old_install_without_the_caller_flag() {
    let home = std::env::temp_dir().join(format!("cmux-layout-detect-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    let old = home.join(".config/cmux");
    std::fs::create_dir_all(&old).unwrap();
    std::fs::write(old.join("server.json"), "{}").unwrap();
    let env = LayoutEnv {
        home: Some(home.to_str().unwrap().to_owned()),
        uid: Some(501),
        ..LayoutEnv::default()
    };
    let l = layout(InstallMode::User, Platform::MacOs, &env).unwrap();
    let config = home.join(".config/cmux/server.json");
    assert_eq!(l.config_file.as_str(), config.to_str().unwrap());
    assert!(l.root.as_str().ends_with("Library/Application Support/cmux"));
    std::fs::remove_dir_all(&home).unwrap();
    let l = layout(InstallMode::User, Platform::MacOs, &env).unwrap();
    assert!(l.root.as_str().ends_with("Library/Application Support/cmux-next"));
}
