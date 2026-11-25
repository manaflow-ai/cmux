use super::*;

const TOKEN: &str = "sk-ant-oat01-not-a-real-token";

#[test]
fn a_login_on_stdin_goes_to_the_finish_as_its_env() {
    let stdin = format!(r#"{{"env":{{"CLAUDE_CODE_OAUTH_TOKEN":"{TOKEN}"}}}}"#);
    let login = read(stdin.as_bytes()).expect("a login");
    assert_eq!(login.wire(), json!({"env": {"CLAUDE_CODE_OAUTH_TOKEN": TOKEN}}));
}

#[test]
fn a_logins_debug_and_every_refusal_never_hold_the_value() {
    let stdin = format!(r#"{{"env":{{"CLAUDE_CODE_OAUTH_TOKEN":"{TOKEN}"}}}}"#);
    let login = read(stdin.as_bytes()).expect("a login");
    let shown = format!("{login:?}");
    assert!(shown.contains("CLAUDE_CODE_OAUTH_TOKEN"), "{shown}");
    assert!(!shown.contains(TOKEN), "{shown}");
    for refusal in [Refusal::Unreadable, Refusal::NotOwner, Refusal::Outdated] {
        assert!(!refusal.message().contains(TOKEN));
        assert!(!refusal.code().contains(TOKEN));
    }
    // A malformed stdin that holds the value: the refusal is the fixed text, not serde's echo.
    let bad = format!(r#"{{"env":{{"CLAUDE_CODE_OAUTH_TOKEN":["{TOKEN}"]}}}}"#);
    let refused = read(bad.as_bytes()).expect_err("a value that is no string");
    assert_eq!(refused, Refusal::Unreadable);
    assert!(!format!("{refused:?}").contains(TOKEN));
    // A field a newer app adds is ignored: the login reads the same.
    let newer = format!(r#"{{"env":{{"CLAUDE_CODE_OAUTH_TOKEN":"{TOKEN}"}},"later":1}}"#);
    assert_eq!(read(newer.as_bytes()), Ok(login));
}

#[test]
fn stdin_that_is_not_one_env_object_is_unreadable() {
    for stdin in [
        &b""[..],
        b"not json",
        b"{}",
        br#"{"env":{}}"#,
        br#"{"env":{"A":""}}"#,
        br#"{"env":{"":"v"}}"#,
        br#"{"env":{"A":1}}"#,
    ] {
        assert_eq!(read(stdin), Err(Refusal::Unreadable), "{}", String::from_utf8_lossy(stdin));
    }
    let huge = vec![b' '; MAX_STDIN_BYTES + 1];
    assert_eq!(read(&huge), Err(Refusal::Unreadable));
}

#[test]
fn only_the_owners_machine_with_the_capability_takes_the_login() {
    let new: &[&str] = &["agent-transfer-v1", CAPABILITY];
    let old: &[&str] = &["agent-transfer-v1"];
    assert_eq!(gate(Some("owner"), Some(new)), Ok(()));
    assert_eq!(gate(Some("team"), Some(new)), Err(Refusal::NotOwner));
    assert_eq!(gate(None, Some(new)), Err(Refusal::NotOwner));
    assert_eq!(gate(Some("owner"), Some(old)), Err(Refusal::Outdated));
    assert_eq!(gate(Some("owner"), None), Err(Refusal::Outdated));
    assert_eq!(Refusal::Outdated.side(), Some("target"));
    assert_eq!(Refusal::NotOwner.side(), None);
}

#[test]
fn the_capability_is_the_daemons() {
    assert_eq!(CAPABILITY, "agent-transfer-credentials-v1");
}
