use super::*;

#[test]
fn transfer_shows_only_for_a_machine_chat_no_move_put_there() {
    assert!(!transfer_hidden(Some("registry:m"), Some("s"), false));
    assert!(transfer_hidden(Some("registry:m"), Some("s"), true));
    assert!(transfer_hidden(Some("registry:m"), None, false));
    assert!(transfer_hidden(Some("local"), Some("s"), false));
    assert!(transfer_hidden(None, None, false));
}

#[test]
fn a_transfer_path_expands_its_tilde_and_must_be_absolute() {
    assert_eq!(transfer_folder(None, "/Users/me"), Folder::New);
    assert_eq!(transfer_folder(Some(""), "/Users/me"), Folder::New);
    assert_eq!(transfer_folder(Some("~"), "/Users/me"), Folder::At { path: "/Users/me".into() });
    assert_eq!(
        transfer_folder(Some("~/code/x/"), "/Users/me/"),
        Folder::At { path: "/Users/me/code/x".into() }
    );
    assert_eq!(transfer_folder(Some("/tmp/a"), "/h"), Folder::At { path: "/tmp/a".into() });
    assert_eq!(transfer_folder(Some("/"), "/h"), Folder::At { path: "/".into() });
    assert_eq!(transfer_folder(Some("code"), "/h"), Folder::Relative { path: "code".into() });
    // Another user's tilde is not this user's home.
    assert_eq!(transfer_folder(Some("~bob/x"), "/h"), Folder::Relative { path: "~bob/x".into() });
}

#[test]
fn a_pane_owns_only_its_recorded_session() {
    assert!(owns_session(Some("s"), "s"));
    assert!(!owns_session(Some("s"), "t"));
    assert!(!owns_session(Some(""), ""));
    assert!(!owns_session(None, "s"));
}

#[test]
fn a_hand_off_refuses_in_order() {
    assert_eq!(refusal(false, false, false), Some("cloud_disabled"));
    assert_eq!(refusal(true, false, true), Some("not_signed_in"));
    assert_eq!(refusal(true, true, false), Some("machines_unread"));
    assert_eq!(refusal(true, true, true), None);
}

#[test]
fn only_a_store_code_reaches_the_page() {
    assert_eq!(store_code(Some("handoff.closed")), Some("handoff.closed"));
    assert_eq!(store_code(Some("rate_limited")), Some("rate_limited"));
    assert_eq!(store_code(Some("Bad Code")), None);
    assert_eq!(store_code(Some("")), None);
    assert_eq!(store_code(Some(&"a".repeat(65))), None);
    assert_eq!(store_code(Some(&"a".repeat(64))).map(str::len), Some(64));
    assert_eq!(store_code(None), None);
}
