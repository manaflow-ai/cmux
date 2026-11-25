use super::*;

#[test]
fn session_vars_come_from_the_daemon_first() {
    let own = |name: &str| match name {
        "DISPLAY" => Some(OsString::from(":1")),
        "XDG_RUNTIME_DIR" => Some(OsString::from("/nonexistent-run")),
        "WAYLAND_DISPLAY" => Some(OsString::new()),
        _ => None,
    };
    let env = session_env(own);
    assert!(env.contains(&("DISPLAY".into(), ":1".into())));
    assert!(!env.iter().any(|(k, _)| k == "WAYLAND_DISPLAY"));
    assert_eq!(
        parse_environment("DISPLAY=:0\nBROKEN\nA=b=c\n"),
        [("DISPLAY".to_string(), ":0".to_string()), ("A".into(), "b=c".into())]
    );
}

#[test]
fn the_headless_switch_reaches_the_worker() {
    let own = |name: &str| (name == "CMUX_CU_HEADLESS").then(|| OsString::from("0"));
    assert_eq!(process_env(own), [("CMUX_CU_HEADLESS".to_string(), OsString::from("0"))]);
}
