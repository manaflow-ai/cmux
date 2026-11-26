use super::*;

#[test]
fn the_public_half_of_a_generated_identity() {
    let private = [9_u8; 32];
    let expected = PublicKey::from(&StaticSecret::from(private));
    let text = format!(r#"{{"version": 1, "private_key": "{}"}}"#, URL_SAFE_NO_PAD.encode(private));
    assert_eq!(public_key(&text), Some(URL_SAFE_NO_PAD.encode(expected.as_bytes())));
}

#[test]
fn anything_else_gives_no_key() {
    for text in [
        "",
        "{}",
        r#"{"version": 2, "private_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}"#,
        r#"{"version": 1, "private_key": "short"}"#,
        r#"{"version": 1}"#,
    ] {
        assert_eq!(public_key(text), None, "{text}");
    }
}

/// #37199 review F1: an image laid out for root keeps the session host's
/// state under /root, so its key is read there, not under /home/cmux.
#[test]
fn a_root_layout_reads_the_identity_under_root() {
    let home = session_home(Some("root\n")).unwrap();
    assert_eq!(
        identity_path(&home, "cloud"),
        Path::new("/root/.local/state/cmux/remote/sessions/Y2xvdWQ/auth/identity.json")
    );
}

#[test]
fn a_user_layout_reads_the_identity_under_the_work_home() {
    let home = session_home(Some("user\n")).unwrap();
    assert_eq!(
        identity_path(&home, "cloud"),
        Path::new("/home/cmux/.local/state/cmux/remote/sessions/Y2xvdWQ/auth/identity.json")
    );
}

#[test]
fn no_or_an_unknown_marker_names_no_home() {
    for marker in [None, Some(""), Some("admin\n")] {
        assert_eq!(session_home(marker), None, "{marker:?}");
    }
}

/// The wait keeps looking until the bind token's lifetime is over, then
/// stops; it never ends in a bind without the key.
#[test]
fn the_key_wait_is_bounded_by_the_bind_token_lifetime() {
    assert_eq!(wait_after(0), Some(500));
    assert_eq!(wait_after(14_999), Some(500));
    assert_eq!(wait_after(15_000), Some(5_000));
    assert_eq!(wait_after(WAIT_DEADLINE_MS - 1_000), Some(1_000));
    assert_eq!(wait_after(WAIT_DEADLINE_MS), None);
    assert_eq!(wait_after(u64::MAX), None);
}

#[test]
fn the_cloud_session_identity_lives_under_its_encoded_name() {
    assert_eq!(
        identity_path(Path::new("/home/cmux"), "cloud"),
        Path::new("/home/cmux/.local/state/cmux/remote/sessions/Y2xvdWQ/auth/identity.json")
    );
}
