use super::*;

const SID: &str = "01a2043e-aaaa-bbbb-cccc-111122223333";

fn put(path: &Path, text: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
}

/// The finding's case: notes-first's state of a session goes with it, and the moved session's
/// hook finds the pages and Decided lines it sent under the same name on the target.
#[test]
fn a_moved_sessions_hook_state_lands_under_its_own_name() {
    let src = tempfile::tempdir().unwrap();
    let state = r#"{"scopes":["landing"],"whole_pages":["landing"],"decided":["a.md"]}"#;
    put(&src.path().join("notes-first/sessions").join(format!("{SID}.json")), state);
    // Another session's state, and a file of another shape, stay.
    put(&src.path().join("notes-first/sessions/other-session-0000.json"), "{}");
    put(&src.path().join("notes-first/sessions").join(format!("{SID}.json.tmp")), "{}");
    put(&src.path().join("notes-first").join(format!("{SID}.json")), "{}");

    let bundle = tempfile::tempdir().unwrap();
    assert_eq!(bundle(src.path(), Some(SID), bundle.path()).unwrap(), 1);
    let rel = format!("{BUNDLE_DIR}/notes-first/{SID}.json");
    assert!(is_bundle_path(&rel));

    let dst = tempfile::tempdir().unwrap();
    assert_eq!(restore(bundle.path(), dst.path(), Some(SID)).unwrap(), 1);
    let landed = dst.path().join("notes-first/sessions").join(format!("{SID}.json"));
    assert_eq!(std::fs::read_to_string(&landed).unwrap(), state);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(std::fs::metadata(&landed).unwrap().permissions().mode() & 0o777, 0o600);
    }
    assert_eq!(std::fs::read_dir(dst.path().join("notes-first/sessions")).unwrap().count(), 1);
}

/// A target that holds the session's state already (the chat ran there before) keeps its own.
#[test]
fn a_state_file_the_target_holds_is_kept() {
    let bundle = tempfile::tempdir().unwrap();
    put(&bundle.path().join(BUNDLE_DIR).join("notes-first").join(format!("{SID}.json")), "new");
    let dst = tempfile::tempdir().unwrap();
    let here = dst.path().join("notes-first/sessions").join(format!("{SID}.json"));
    put(&here, "mine");
    assert_eq!(restore(bundle.path(), dst.path(), Some(SID)).unwrap(), 0);
    assert_eq!(std::fs::read_to_string(&here).unwrap(), "mine");
}

/// Only the session's own file of a plain tool folder is placed; nothing climbs out of the cache.
#[test]
fn a_bundle_cannot_place_other_files() {
    let bundle = tempfile::tempdir().unwrap();
    let dir = bundle.path().join(BUNDLE_DIR);
    put(&dir.join("notes-first/someone-else-1234.json"), "{}");
    put(&dir.join(".hidden").join(format!("{SID}.json")), "{}");
    let dst = tempfile::tempdir().unwrap();
    assert_eq!(restore(bundle.path(), dst.path(), Some(SID)).unwrap(), 0);
    assert_eq!(restore(bundle.path(), dst.path(), Some("../../x")).unwrap(), 0);
    assert_eq!(restore(bundle.path(), dst.path(), None).unwrap(), 0);
    for bad in [
        "hook-state/notes-first/../x.json",
        "hook-state/.hidden/x.json",
        "hook-state/notes-first/x.txt",
        "hook-state/x.json",
        "hook-state/a/b/x.json",
    ] {
        assert!(!is_bundle_path(bad), "{bad}");
    }
}

/// A state file past the cap, or a symlink, does not travel.
#[test]
fn an_oversized_or_linked_state_file_stays() {
    let src = tempfile::tempdir().unwrap();
    let big = "x".repeat(MAX_FILE as usize + 1);
    put(&src.path().join("big/sessions").join(format!("{SID}.json")), &big);
    #[cfg(unix)]
    {
        let target = src.path().join("elsewhere.json");
        put(&target, "{}");
        std::fs::create_dir_all(src.path().join("linked/sessions")).unwrap();
        std::os::unix::fs::symlink(
            &target,
            src.path().join("linked/sessions").join(format!("{SID}.json")),
        )
        .unwrap();
    }
    assert!(locate_in(src.path(), SID).is_empty());
}
