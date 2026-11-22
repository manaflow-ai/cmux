use super::*;
use serde_json::json;

#[test]
fn settings_keys_map_to_the_policy_and_missing_keys_keep_defaults() {
    let config = from_settings(
        &json!({"computerUse": {
            "mode": "approvedApps", "deniedApps": ["com.example.*"], "allowForeground": true,
            "showCursor": false
        }}),
        PolicyConfig::default(),
    );
    assert_eq!(config.mode, Mode::ApprovedApps);
    assert_eq!(config.denied_apps, ["com.example.*"]);
    assert!(config.allow_foreground && !config.show_cursor);
    assert!(config.pause_on_takeover && config.allow_own_machines);
    // computerUse.whileLocked is off unless the settings say so.
    assert!(!config.while_locked);
    let locked =
        from_settings(&json!({"computerUse": {"whileLocked": true}}), PolicyConfig::default());
    assert!(locked.while_locked);
    assert_eq!(from_settings(&json!({}), PolicyConfig::default()), PolicyConfig::default());
    // An unknown mode keeps the default, never something wider than asked.
    assert_eq!(
        from_settings(&json!({"computerUse": {"mode": "god"}}), PolicyConfig::default()).mode,
        Mode::FullAccess
    );
}

#[test]
fn menus_setting_maps_in_any_case_and_an_unknown_value_refuses() {
    use cmux_computer_use::menus::MenuMode;
    assert_eq!(PolicyConfig::default().menus, MenuMode::Open);
    let menus = |v: Value| {
        from_settings(&json!({"computerUse": {"menus": v}}), PolicyConfig::default()).menus
    };
    assert_eq!(menus(json!("refuse")), MenuMode::Refuse);
    assert_eq!(menus(json!("open")), MenuMode::Open);
    assert_eq!(menus(json!("Refuse")), MenuMode::Refuse);
    assert_eq!(menus(json!(" OPEN ")), MenuMode::Open);
    assert_eq!(menus(json!("sometimes")), MenuMode::Refuse);
    assert_eq!(menus(json!("Refsue")), MenuMode::Refuse);
    // Present but not a string: menus stay closed.
    assert_eq!(menus(json!(3)), MenuMode::Refuse);
    assert_eq!(menus(json!(null)), MenuMode::Refuse);
    assert_eq!(menus(json!(false)), MenuMode::Refuse);
    // Absent: the default stays.
    assert_eq!(
        from_settings(&json!({"computerUse": {}}), PolicyConfig::default()).menus,
        MenuMode::Open
    );
    // The owner file and the app push use the camelCase key.
    let owner: PolicyConfig = serde_json::from_value(json!({"menus": "refuse"})).unwrap();
    assert_eq!(owner.menus, MenuMode::Refuse);
    // A value in another case, or a typo, keeps the rest of the owner
    // policy (its deny list) and keeps menus closed.
    let owner: PolicyConfig =
        serde_json::from_value(json!({"menus": "Refsue", "deniedApps": ["com.example.x"]}))
            .unwrap();
    assert_eq!(owner.menus, MenuMode::Refuse);
    assert_eq!(owner.denied_apps, vec!["com.example.x".to_string()]);
    for odd in [json!(null), json!(false), json!(0)] {
        let owner: PolicyConfig =
            serde_json::from_value(json!({"menus": odd, "deniedApps": ["com.example.x"]})).unwrap();
        assert_eq!(owner.menus, MenuMode::Refuse);
        assert_eq!(owner.denied_apps, vec!["com.example.x".to_string()]);
    }
}

#[test]
fn a_cloud_vm_starts_unrestricted_and_the_settings_still_apply() {
    // No settings: the cloud VM default (no deny list, foreground input).
    let cloud = from_settings(&json!({}), PolicyConfig::cloud_vm());
    assert_eq!(cloud, PolicyConfig::cloud_vm());
    assert!(cloud.denied_apps.is_empty() && cloud.allow_foreground && cloud.cloud_vm);
    // The person can still narrow it from their settings.
    let narrowed =
        from_settings(&json!({"computerUse": {"mode": "lookOnly"}}), PolicyConfig::cloud_vm());
    assert_eq!(narrowed.mode, Mode::LookOnly);
}

#[cfg(unix)]
#[test]
fn a_stamp_the_user_could_write_is_not_a_cloud_vm() {
    let dir = std::env::temp_dir().join(format!("cu-stamp-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let stamp = dir.join("image-stamp");
    std::fs::write(&stamp, "cmux-vm inputs=abc\n").unwrap();
    // SAFETY: plain call.
    if unsafe { libc::geteuid() } != 0 {
        assert!(!cloud_stamp(&stamp), "a user-owned stamp must not widen access");
    }
    assert!(!cloud_stamp(&dir.join("absent")));
    std::fs::remove_dir_all(dir).unwrap();
}

#[cfg(unix)]
#[test]
fn an_owner_file_the_user_can_write_is_refused() {
    let dir = std::env::temp_dir().join(format!("cu-owner-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("computer-use.json");
    std::fs::write(&path, serde_json::to_vec(&PolicyConfig::cloud_vm()).unwrap()).unwrap();
    // SAFETY: plain call.
    if unsafe { libc::geteuid() } != 0 {
        let error = read_owner(&path).unwrap_err();
        assert!(error.contains("not owned by root"), "{error}");
    }
    assert_eq!(read_owner(&dir.join("absent.json")), Ok(None));
    std::fs::remove_dir_all(dir).unwrap();
}
