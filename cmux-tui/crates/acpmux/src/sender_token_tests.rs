use super::*;

#[cfg(unix)]
fn home() -> tempfile::TempDir {
    tempfile::tempdir().unwrap()
}

// `ensure` makes no token where it cannot check a file's owner and mode (not unix).
#[cfg(unix)]
#[test]
fn the_daemon_makes_one_owner_only_token_and_keeps_it() {
    let dir = home();
    ensure(dir.path()).unwrap();
    let token = read_trusted(&path_in(dir.path())).expect("a trusted token");
    assert_eq!(token.len(), 64);
    use std::os::unix::fs::PermissionsExt;
    let mode = std::fs::metadata(path_in(dir.path())).unwrap().permissions().mode();
    assert_eq!(mode & 0o777, 0o600);
    // A restart keeps it.
    ensure(dir.path()).unwrap();
    assert_eq!(read_trusted(&path_in(dir.path())).as_deref(), Some(token.as_str()));
    // No temporary file is left beside it.
    let names: Vec<_> =
        std::fs::read_dir(dir.path()).unwrap().map(|e| e.unwrap().file_name()).collect();
    assert_eq!(names, vec![std::ffi::OsString::from(FILE)]);
    let presented = Presented::new(&format!("{token}\n")).unwrap();
    assert!(matches(dir.path(), &presented));
    assert!(!matches(dir.path(), &Presented::new(&"0".repeat(64)).unwrap()));
    assert!(!matches(dir.path(), &Presented::new(&token[..63]).unwrap()));
}

#[cfg(unix)]
#[test]
fn a_token_file_anyone_else_could_write_or_a_link_is_never_trusted() {
    use std::os::unix::fs::PermissionsExt;
    let dir = home();
    let path = path_in(dir.path());
    let token = "ab".repeat(32);
    std::fs::write(&path, &token).unwrap();
    for mode in [0o640, 0o604, 0o660] {
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(mode)).unwrap();
        assert_eq!(read_trusted(&path), None, "{mode:o}");
        assert!(!matches(dir.path(), &Presented::new(&token).unwrap()), "{mode:o}");
    }
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    assert_eq!(read_trusted(&path).as_deref(), Some(token.as_str()));
    // A link to an owner-only file is not the file.
    let other = home();
    let link = path_in(other.path());
    std::os::unix::fs::symlink(&path, &link).unwrap();
    assert_eq!(read_trusted(&link), None);
    // `ensure` leaves a file it does not trust alone, and makes none in its place.
    ensure(other.path()).unwrap();
    assert!(std::fs::symlink_metadata(&link).unwrap().file_type().is_symlink());
    // Not a token: too short, not hex.
    std::fs::write(&path, "not-a-token").unwrap();
    assert_eq!(read_trusted(&path), None);
}

#[test]
fn the_token_leaves_the_request_before_anything_reads_it() {
    let mut prompt = json!({"_meta": {"acpmux": {"promptId": "p", "senderToken": "secret"}}});
    assert_eq!(take(&mut prompt), Presented::new("secret"));
    assert_eq!(prompt, json!({"_meta": {"acpmux": {"promptId": "p"}}}));
    let mut queued = json!({"request": {"_meta": {"acpmux": {"senderToken": "secret"}}},
                            "_meta": {"acpmux": {"senderToken": "other"}}});
    assert_eq!(take(&mut queued), Presented::new("other"));
    assert!(!queued.to_string().contains("secret") && !queued.to_string().contains("other"));
    let mut odd = json!({"_meta": {"acpmux": {"senderToken": 7}}});
    assert_eq!(take(&mut odd), None);
    assert_eq!(odd, json!({"_meta": {"acpmux": {}}}));
    assert_eq!(take(&mut json!(null)), None);
    // Never printed.
    assert_eq!(format!("{:?}", Presented::new("secret").unwrap()), "Presented(<redacted>)");
}

#[test]
fn a_named_sender_with_the_token_is_verified_and_nothing_else_is() {
    let named = || crate::prompt_provenance::named_sender("outbox-relay", "s");
    let p = label(named(), true);
    assert_eq!(p["verified"], true);
    assert_eq!(p["verifiedBy"], VERIFIED_BY);
    assert_eq!(p["fromName"], "outbox-relay");
    assert!(verified_by_token(&p));
    // A notice's sender too.
    let notice = crate::prompt_provenance::notice(&json!({"sender": "ci-watch"}), "s");
    assert_eq!(label(notice, true)["verifiedBy"], VERIFIED_BY);
    // A wrong token, or none: as it was.
    assert_eq!(label(named(), false), named());
    // No name: an unverified send stays as it is.
    let unnamed = crate::prompt_provenance::unverified("s", "unix", serde_json::Map::new());
    assert_eq!(label(unnamed.clone(), true), unnamed);
    // A session the daemon proved stays as it was.
    let mut proven = crate::prompt_provenance::session_message("a", "lane", "s");
    proven["verified"] = json!(true);
    assert_eq!(label(proven.clone(), true), proven);
    assert!(!verified_by_token(&proven));
}

#[test]
fn only_the_daemons_verdict_counts() {
    let mut prompt = json!({"_meta": {"acpmux": {"senderTokenChecked": true}}});
    // A client's own verdict is dropped.
    stamp(&mut prompt, None, false);
    assert!(!matched(&prompt));
    stamp(&mut prompt, Some(false), false);
    assert!(!matched(&prompt));
    stamp(&mut prompt, Some(true), false);
    assert!(matched(&prompt));
    // The outbox and a proven peer daemon carry the daemon's verdict on.
    stamp(&mut prompt, None, true);
    assert!(matched(&prompt));
}

#[test]
fn constant_time_compare_agrees_with_eq() {
    assert!(same(b"abc", b"abc"));
    assert!(!same(b"abc", b"abd"));
    assert!(!same(b"abc", b"ab"));
    assert!(same(b"", b""));
}

#[test]
fn a_daemon_that_does_not_take_the_token_is_never_sent_it() {
    let token = "a".repeat(64);
    let sent = || {
        json!({"_meta": {"acpmux": {"fromAgent": "outbox-relay", (META_KEY): token}},
               "request": {"_meta": {"acpmux": {(META_KEY): token}}}})
    };
    let mut old = sent();
    withhold_unless(&mut old, false);
    assert!(!old.to_string().contains(&token), "{old}");
    assert_eq!(old.pointer("/_meta/acpmux/fromAgent"), Some(&json!("outbox-relay")));
    let mut new = sent();
    withhold_unless(&mut new, true);
    assert_eq!(new, sent());
}
