use super::*;

#[test]
fn values() {
    for v in ["0", "off", "OFF", "false", "no"] {
        assert!(off_value(v.as_bytes()), "{v}");
    }
    for v in ["1", "", "on", "yes"] {
        assert!(!off_value(v.as_bytes()), "{v}");
    }
}

#[test]
fn markers_round_trip() {
    assert_eq!(classify(None), Caller::Unasked);
    assert_eq!(classify(Some(OFF_AUTHORIZATION.as_bytes())), Caller::Off);
    assert_eq!(classify(Some(ANON_AUTHORIZATION.as_bytes())), Caller::Anon);
    assert_eq!(classify(Some(b"Basic Z29vZDp0b2tlbg==")), Caller::Credential);
    assert!(names_marker("protocol=http\nusername=cmux-git-cache-off\npassword=x\n"));
    assert!(!names_marker("protocol=https\nusername=octocat\n"));
    assert_eq!(marker(OFF_USER), "username=cmux-git-cache-off\npassword=x\n");
}

#[test]
fn off_carries_the_credential() {
    use base64::Engine as _;
    let b64 = base64::engine::general_purpose::STANDARD;
    let answer = off_answer(Some("username=octo\npassword=tok:en\n"));
    assert_eq!(answer, "username=cmux-git-cache-off\npassword=octo:tok:en\n");
    let sent = format!("Basic {}", b64.encode("cmux-git-cache-off:octo:tok:en"));
    assert_eq!(classify(Some(sent.as_bytes())), Caller::Off);
    assert_eq!(off_upstream(sent.as_bytes()), Some(format!("Basic {}", b64.encode("octo:tok:en"))));
    assert_eq!(off_answer(None), marker(OFF_USER));
    assert_eq!(off_upstream(OFF_AUTHORIZATION.as_bytes()), None);
}
