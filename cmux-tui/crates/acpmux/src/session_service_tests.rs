use super::*;

const ME: Option<&str> = Some("user-1");

fn status(signed_in: &str, answered: bool) -> Value {
    let mut consent =
        json!({"screen": "none", "control": "granted", "signedInMachines": signed_in});
    if answered {
        consent["signedInMachinesAnsweredAt"] = json!("1");
        consent["signedInMachinesUser"] = json!("user-1");
    }
    json!({"consentRequired": true, "consent": consent, "lastRefusal": null})
}

#[test]
fn off_by_default_and_the_first_refusal_is_the_one_ask() {
    // A machine signing in made: nothing granted, nothing answered.
    match decide(&status("none", false), ME, false) {
        Decision::Refuse { refusal, ask } => {
            assert_eq!(refusal.reason, CONSENT_REQUIRED);
            assert!(ask, "the first refusal asks the person on that machine");
        }
        Decision::Admit => panic!("signing in alone admitted a workspace"),
    }
    // Control from elsewhere is another grant: it does not open workspaces for the account.
    assert_ne!(decide(&status("none", false), ME, false), Decision::Admit);
    // An ask already pending is not recorded again.
    let mut pending = status("none", false);
    pending["lastRefusal"] = json!({"surface": "signedInMachines"});
    assert!(matches!(decide(&pending, ME, false), Decision::Refuse { ask: false, .. }));
}

#[test]
fn after_not_now_no_new_ask_and_after_allow_admitted() {
    match decide(&status("none", true), ME, false) {
        Decision::Refuse { refusal, ask } => {
            assert_eq!(refusal.reason, CONSENT_DECLINED);
            assert!(!ask, "asked once");
        }
        Decision::Admit => panic!("Not now admitted"),
    }
    assert_eq!(decide(&status("granted", true), ME, false), Decision::Admit);
}

#[test]
fn a_grant_holds_only_for_the_account_it_was_given_for() {
    let granted = status("granted", true);
    // Signed in as another account now: nothing granted, and it asks again.
    match decide(&granted, Some("user-2"), false) {
        Decision::Refuse { refusal, ask } => {
            assert_eq!(refusal.reason, CONSENT_REQUIRED);
            assert!(ask);
        }
        Decision::Admit => panic!("a grant for another account admitted"),
    }
    // Not joined to any account: refused.
    assert_ne!(decide(&granted, None, false), Decision::Admit);
    // A grant with no account recorded (written by hand, or by an older build): refused.
    let mut unnamed = granted.clone();
    unnamed["consent"].as_object_mut().unwrap().remove("signedInMachinesUser");
    assert_ne!(decide(&unnamed, ME, false), Decision::Admit);
}

#[test]
fn an_unreadable_or_odd_status_refuses() {
    for odd in [json!({}), json!({"consent": {"signedInMachines": true}}), json!(null)] {
        assert_ne!(decide(&odd, ME, false), Decision::Admit, "{odd}");
    }
    // consentRequired false (a machine never joined) still needs the grant itself.
    let unjoined = json!({"consentRequired": false, "consent": {"signedInMachines": "none"}});
    assert_ne!(decide(&unjoined, ME, false), Decision::Admit);
}

#[test]
fn a_join_from_another_device_is_the_consent_until_the_person_answers() {
    // A Cloud VM or a lane VM joined by a join line: nobody asked, nobody answered: admitted.
    assert_eq!(decide(&status("none", false), ME, true), Decision::Admit);
    // The person's own Not now (or a later Off) on that machine still wins.
    match decide(&status("none", true), ME, true) {
        Decision::Refuse { refusal, ask } => {
            assert_eq!(refusal.reason, CONSENT_DECLINED);
            assert!(!ask);
        }
        Decision::Admit => panic!("a join overrode the person's Not now"),
    }
    // Not joined to any account: the join proves nothing.
    assert_ne!(decide(&status("none", false), None, true), Decision::Admit);
    // An answer given for another account does not hold for this one: the join admits.
    let mut other = status("none", true);
    other["consent"]["signedInMachinesUser"] = json!("user-2");
    assert_eq!(decide(&other, ME, true), Decision::Admit);
    // An unreadable status could hide the person's Off: refused even on a joined machine.
    assert_ne!(decide(&json!({}), ME, true), Decision::Admit);
    assert_ne!(decide(&json!(null), ME, true), Decision::Admit);
}

#[test]
fn the_ensured_session_socket_is_read_from_cmux_daemon_ensure() {
    let started = r#"{"generation":"g","message":"local server started","pid":1,"session":"main","socket":"/run/user/1005/cmux-tui-1005/main.sock","status":"started"}"#;
    assert_eq!(
        ensured_socket(started),
        Some(PathBuf::from("/run/user/1005/cmux-tui-1005/main.sock"))
    );
    let running = r#"{"status":"running","socket":"/tmp/s.sock"}"#;
    assert_eq!(ensured_socket(running), Some(PathBuf::from("/tmp/s.sock")));
    for odd in [
        r#"{"code":"server.unavailable","message":"x"}"#,
        r#"{"status":"failed","socket":"/tmp/s.sock"}"#,
        r#"{"status":"running","socket":""}"#,
        "not json",
        "",
    ] {
        assert_eq!(ensured_socket(odd), None, "{odd}");
    }
}

#[cfg(unix)]
#[test]
fn only_an_own_socket_is_reached() {
    let dir = tempfile::tempdir().unwrap();
    assert_eq!(session_socket(None).unwrap_err().reason, "service.off");
    assert_eq!(session_socket(Some(Path::new("relative.sock"))).unwrap_err().reason, "service.off");
    let missing = dir.path().join("missing.sock");
    assert_eq!(session_socket(Some(&missing)).unwrap_err().reason, "service.unreachable");
    let file = dir.path().join("file.sock");
    std::fs::write(&file, b"").unwrap();
    assert_eq!(session_socket(Some(&file)).unwrap_err().reason, "service.unreachable");
    let socket = dir.path().join("tui.sock");
    let _listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
    assert_eq!(session_socket(Some(&socket)).unwrap(), socket);
    let link = dir.path().join("link.sock");
    std::os::unix::fs::symlink(&socket, &link).unwrap();
    assert_eq!(
        session_socket(Some(&link)).unwrap_err().reason,
        "service.unreachable",
        "a symlink is never followed to a socket"
    );
}
