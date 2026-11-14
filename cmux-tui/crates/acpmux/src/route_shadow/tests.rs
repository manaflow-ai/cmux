use super::*;

#[test]
fn a_shadow_keeps_its_login_and_shares_the_rest() {
    let root = std::env::temp_dir().join(format!("acpmux-shadow-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    let (base, shadow, other) = (root.join("base"), root.join("shadow"), root.join("other"));
    std::fs::create_dir_all(&base).unwrap();
    // A folder already there, open to others, is closed when it becomes a shadow.
    std::fs::create_dir_all(&shadow).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&shadow, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    std::fs::write(base.join("auth.json"), "base login").unwrap();
    std::fs::write(base.join("config.toml"), "model = 'x'").unwrap();
    link(&shadow, &base).unwrap();
    assert!(!shadow.join("auth.json").exists(), "the login stays the base's");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&shadow).unwrap().permissions().mode();
        assert_eq!(mode & 0o077, 0, "a shadow home is owner-only");
    }
    assert_eq!(std::fs::read_to_string(shadow.join("config.toml")).unwrap(), "model = 'x'");
    assert!(shares_conversations(&base, &shadow));
    // An entry the base gains later is linked at the next refresh; the shadow's own stay.
    std::fs::write(shadow.join("auth.json"), "shadow login").unwrap();
    std::fs::write(base.join("AGENTS.md"), "shared").unwrap();
    link(&shadow, &base).unwrap();
    assert_eq!(std::fs::read_to_string(shadow.join("AGENTS.md")).unwrap(), "shared");
    assert_eq!(std::fs::read_to_string(shadow.join("auth.json")).unwrap(), "shadow login");
    // A folder with conversations of its own is never made a shadow.
    let own = root.join("own");
    std::fs::create_dir_all(own.join("sessions")).unwrap();
    assert!(link(&own, &base).is_err());
    // A separate account home keeps its own conversations.
    std::fs::create_dir_all(other.join("sessions")).unwrap();
    assert!(!shares_conversations(&base, &other));
    let _ = std::fs::remove_dir_all(&root);
}
