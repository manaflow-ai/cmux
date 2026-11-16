use super::*;

fn helper() -> Installed {
    Installed {
        app: "/h/.acpmux/screen-sharing/com.cmuxterm.app.nightly.screen-sharing/cmux NIGHTLY Screen Sharing.app".into(),
        bundle_id: "com.cmuxterm.app.nightly.screen-sharing".into(),
        name: "cmux NIGHTLY Screen Sharing".into(),
        digest: "d".into(),
        source: "/Applications/cmux NIGHTLY.app".into(),
    }
}

fn mac(probe: Option<Result<Permissions, String>>) -> Facts {
    Facts {
        mac: true,
        installed: Some(helper()),
        probe,
        session: Some(Session::ThisUser),
        os_version: Some("26.1 (25B78)".into()),
        now_ms: 7,
        ..Facts::default()
    }
}

fn granted(screen_recording: bool, accessibility: bool) -> Option<Result<Permissions, String>> {
    Some(Ok(Permissions { screen_recording, accessibility }))
}

#[test]
fn both_grants_held_is_granted_and_names_the_helper() {
    let status = classify(mac(granted(true, true)));
    assert_eq!(status.state, State::Granted);
    assert!(status.missing.is_empty());
    assert_eq!(status.holder.as_deref(), Some("cmux NIGHTLY Screen Sharing"));
    assert_eq!(status.schema, SCHEMA);
}

#[test]
fn a_missing_grant_is_needs_grant_and_names_the_helper_never_cmux_remote() {
    let status = classify(mac(granted(false, true)));
    assert_eq!(status.state, State::NeedsGrant);
    assert_eq!(status.missing, vec![Grant::ScreenRecording]);
    assert_eq!(
        status.detail,
        "allow cmux NIGHTLY Screen Sharing under Privacy & Security > Screen Recording"
    );
    let both = classify(mac(granted(false, false)));
    assert_eq!(both.missing, vec![Grant::ScreenRecording, Grant::Accessibility]);
    assert!(both.detail.ends_with("Screen Recording and Accessibility"), "{}", both.detail);
    for status in [status, both] {
        assert!(!status.detail.contains("cmux Remote"), "{}", status.detail);
    }
}

#[test]
fn no_helper_is_not_installed_with_the_reason() {
    let status = classify(Facts {
        installed: None,
        install_error: Some("no cmux app here carries it (install cmux NIGHTLY)".into()),
        ..mac(None)
    });
    assert_eq!(status.state, State::NotInstalled);
    assert!(status.detail.contains("install cmux NIGHTLY"), "{}", status.detail);
    assert_eq!(status.holder, None);
}

#[test]
fn a_helper_that_does_not_answer_is_not_installed_never_a_guessed_grant() {
    let status = classify(mac(Some(Err("it gave no answer within 10 s".into()))));
    assert_eq!(status.state, State::NotInstalled);
    assert!(status.missing.is_empty());
    assert!(status.detail.contains("did not answer"), "{}", status.detail);
}

#[test]
fn not_a_mac_is_unsupported() {
    let status = classify(Facts { mac: false, now_ms: 1, ..Facts::default() });
    assert_eq!(status.state, State::Unsupported);
    assert_eq!(status.session, Session::Unknown);
}

#[test]
fn nobody_logged_in_is_said() {
    let status = classify(Facts { session: Some(Session::Nobody), ..mac(granted(true, true)) });
    assert_eq!(status.state, State::Granted);
    assert_eq!(status.session, Session::Nobody);
    assert!(status.detail.contains("nobody is logged in"), "{}", status.detail);
}

#[test]
fn the_wire_shape_is_the_schema() {
    let status = classify(mac(granted(false, true)));
    let value = serde_json::to_value(&status).unwrap();
    assert_eq!(value["schema"], "cmux.screen-share.status/1");
    assert_eq!(value["state"], "needs_grant");
    assert_eq!(value["missing"], serde_json::json!(["screen_recording"]));
    assert_eq!(value["session"], "this_user");
    assert_eq!(value["checkedAtMs"], 7);
    assert_eq!(value["osVersion"], "26.1 (25B78)");
    let back: Status = serde_json::from_value(value).unwrap();
    assert_eq!(back, status);
}

#[test]
fn a_kept_status_holds_only_on_the_os_version_it_was_read_on() {
    let status = classify(mac(granted(true, true)));
    assert!(still_holds(&status, Some("26.1 (25B78)")));
    assert!(!still_holds(&status, Some("26.2 (25C5)")));
    assert!(!still_holds(&status, None));
}

#[test]
fn the_kept_status_and_helper_record_round_trip_on_disk() {
    let home = tempfile::tempdir().unwrap();
    assert_eq!(cached(home.path()), None);
    let status = classify(mac(granted(true, false)));
    keep(home.path(), &status).unwrap();
    assert_eq!(cached(home.path()), Some(status));
    // A record whose bundle is gone is no installed helper.
    let folder = dir(home.path());
    std::fs::write(folder.join(HELPER_RECORD), serde_json::to_vec(&helper()).unwrap()).unwrap();
    assert_eq!(installed(home.path()), None);
}

#[test]
fn the_permissions_line_parses_and_anything_else_is_refused() {
    assert_eq!(
        parse_permissions(b"{\"screen_recording\":true,\"accessibility\":false}\n"),
        Ok(Permissions { screen_recording: true, accessibility: false })
    );
    assert!(parse_permissions(b"").is_err());
    assert!(parse_permissions(b"{\"screen_recording\":true}\n").is_err());
    assert!(parse_permissions(b"error: not macOS\n").is_err());
}

#[test]
fn only_cmux_helper_bundle_ids_are_installed() {
    for id in [
        "com.cmuxterm.app.screen-sharing",
        "com.cmuxterm.app.nightly.screen-sharing",
        "com.cmuxterm.app.debug.my-tag.screen-sharing",
    ] {
        assert!(is_helper_bundle_id(id), "{id}");
    }
    for id in [
        "com.cmuxterm.remote",
        "com.cmuxterm.app.nightly",
        "com.evil.app.screen-sharing",
        "com.cmuxterm.appx.screen-sharing",
        "com.cmuxterm.app.nightly.screen-sharing\n",
        "",
    ] {
        assert!(!is_helper_bundle_id(id), "{id:?}");
    }
}

#[test]
fn helpers_are_found_in_an_apps_library_and_its_bundle_from_the_binary() {
    let root = tempfile::tempdir().unwrap();
    let app = root.path().join("cmux NIGHTLY.app");
    let helper = app.join("Contents/Library/cmux NIGHTLY Screen Sharing.app");
    std::fs::create_dir_all(helper.join("Contents/MacOS")).unwrap();
    std::fs::write(helper.join("Contents/MacOS").join(EXECUTABLE), b"").unwrap();
    // Not a helper: wrong suffix, or no executable.
    std::fs::create_dir_all(app.join("Contents/Library/cmux Remote.app/Contents/MacOS")).unwrap();
    std::fs::create_dir_all(app.join("Contents/Library/x Screen Sharing.app")).unwrap();
    assert_eq!(helpers_in(&app), vec![helper]);
    assert_eq!(helpers_in(&root.path().join("missing.app")), Vec::<PathBuf>::new());
    let bin = app.join("Contents/Resources/bin/acpmux");
    assert_eq!(app_of(&bin), Some(app));
    assert_eq!(app_of(Path::new("/home/u/.local/bin/acpmux")), None);
}

#[test]
fn a_join_from_another_device_asks_for_sharing_and_a_plain_sign_in_never_does() {
    // A join line, a pair code or `cmux device add` (no joined_by), or any other join.
    assert!(share_by_join(None, false));
    assert!(share_by_join(Some("pair"), false));
    // Signing in to cmux here enrolled it: that is no join, its switch stays off.
    assert!(!share_by_join(Some("sign-in"), false));
    // ...unless the person set it up from another device (`cmux device setup`).
    assert!(share_by_join(Some("sign-in"), true));
}

#[test]
fn no_join_record_asks_for_nothing_and_the_mark_is_kept() {
    let home = tempfile::tempdir().unwrap();
    assert!(!share_by_join_here(home.path()));
    mark_joined(home.path()).unwrap();
    // Still no join record: nothing to sign in with, so nothing asks.
    assert!(!share_by_join_here(home.path()));
    assert!(dir(home.path()).join(JOINED_MARK).is_file());
}
