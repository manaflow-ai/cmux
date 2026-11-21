use super::*;

fn identity(bundle: Option<&str>, tag: Option<&str>) -> AppIdentity {
    AppIdentity::new(bundle.map(str::to_owned), tag, None)
}

#[test]
fn control_socket_matches_the_app_table() {
    let home = Path::new("/Users/a");
    let cases = [
        // Not the reload.sh form, the untagged DEV build and a tagged RC
        // build: names of their build key (S3).
        (
            Some("com.cmuxterm.app.debug.Feat_X"),
            None,
            "/Users/a/.local/state/cmux/cmux-debug--ec0e7410.sock",
        ),
        (
            Some("com.cmuxterm.app.debug"),
            Some("clic"),
            "/Users/a/.local/state/cmux/cmux-debug-clic.sock",
        ),
        (
            Some("com.cmuxterm.app.debug"),
            None,
            "/Users/a/.local/state/cmux/cmux-debug--650e93e3.sock",
        ),
        (None, Some("nx9"), "/Users/a/.local/state/cmux/cmux-debug-nx9.sock"),
        (Some("com.cmuxterm.app.nightly"), None, "/Users/a/.local/state/cmux/cmux-nightly.sock"),
        (
            Some("com.cmuxterm.app.rc.try2"),
            None,
            "/Users/a/.local/state/cmux/cmux-rc--36529c0e.sock",
        ),
        (Some("com.cmuxterm.app"), None, "/Users/a/.local/state/cmux/cmux.sock"),
    ];
    for (bundle, tag, expected) in cases {
        assert_eq!(
            identity(bundle, tag).control_socket(home),
            PathBuf::from(expected),
            "{bundle:?} {tag:?}"
        );
    }
}

#[test]
fn daemon_session_matches_the_app_launcher() {
    assert_eq!(
        identity(Some("com.cmuxterm.app"), None).daemon_session().as_deref(),
        Some("cmux-app")
    );
    assert_eq!(
        identity(Some("com.cmuxterm.app.debug.nx9"), None).daemon_session().as_deref(),
        Some("cmux-app-nx9")
    );
}

#[test]
fn an_adopted_legacy_session_is_the_channel_apps_daemon() {
    let root = std::env::temp_dir().join(format!("cmux-adopted-session-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    let nightly = identity(Some("com.cmuxterm.app.nightly"), None);
    assert_eq!(nightly.daemon_session_in(&root).as_deref(), Some("cmux-app-nightly"));
    let marker = nightly.build().legacy_session_marker(&root).unwrap();
    std::fs::create_dir_all(marker.parent().unwrap()).unwrap();
    std::fs::write(&marker, br#"{"session":"cmux-app","state_root":"/x"}"#).unwrap();
    assert_eq!(
        nightly.daemon_session_in(&root).as_deref(),
        Some("cmux-app"),
        "the NIGHTLY app runs the adopted cmux-app session"
    );
    assert_eq!(
        identity(Some("com.cmuxterm.app.rc"), None).daemon_session_in(&root).as_deref(),
        Some("cmux-app-rc"),
        "another channel's record is not this one's"
    );
    assert_eq!(
        identity(Some("com.cmuxterm.app.debug.nx9"), None).daemon_session_in(&root).as_deref(),
        Some("cmux-app-nx9")
    );
    // A marker still where builds before the folder move kept it (classic's folder) counts too.
    std::fs::remove_file(&marker).unwrap();
    assert_eq!(nightly.daemon_session_in(&root).as_deref(), Some("cmux-app-nightly"));
    let before = nightly.build().legacy_session_marker_before_move(&root).unwrap();
    assert_ne!(before, marker, "the marker before the move sits in classic's folder");
    std::fs::create_dir_all(before.parent().unwrap()).unwrap();
    std::fs::write(&before, br#"{"session":"cmux-app","state_root":"/x"}"#).unwrap();
    assert_eq!(nightly.daemon_session_in(&root).as_deref(), Some("cmux-app"));
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn terminal_environment_wins_over_the_bundle() {
    let env = |key: &str| match key {
        "CMUX_SOCKET_PATH" => Some("/tmp/cmux-debug-own.sock".to_owned()),
        "CMUX_TAG" => Some("own".to_owned()),
        _ => None,
    };
    let found = AppIdentity::detect(env, None).unwrap();
    assert_eq!(found.control_socket(Path::new("/h")), PathBuf::from("/tmp/cmux-debug-own.sock"));
    assert_eq!(found.daemon_session().as_deref(), Some("cmux-app-own"));
    assert_eq!(AppIdentity::detect(|_| None, None), None);
}

/// A `cmux` bundled in a DEV app with only `CMUX_SOCKET_PATH` set (the Cloud matrix's CLI, a
/// Chief brain's turn) is that DEV build, on that socket: its acpmux home, and so its trust
/// record, is the one the app reads, never NIGHTLY's shared `~/.acpmux`.
#[test]
fn a_socket_only_environment_keeps_the_bundled_build() {
    let root = std::env::temp_dir().join(format!("cmux-socket-only-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    let contents = root.join("cmux DEV mx.app/Contents");
    std::fs::create_dir_all(contents.join("Resources/bin")).unwrap();
    let mut info = plist::Dictionary::new();
    info.insert("CFBundleIdentifier".into(), "com.cmuxterm.app.debug.mx".into());
    plist::Value::Dictionary(info).to_file_xml(contents.join("Info.plist")).unwrap();
    let exe = contents.join("Resources/bin/cmux");
    let socket_only =
        |key: &str| (key == "CMUX_SOCKET_PATH").then(|| "/tmp/cmux-debug-mx.sock".to_owned());
    let found = AppIdentity::detect(socket_only, Some(&exe)).unwrap();
    let bundled = AppIdentity::detect(|_| None, Some(&exe)).unwrap();
    assert_eq!(found.bundle_id.as_deref(), Some("com.cmuxterm.app.debug.mx"));
    assert_eq!(found.build().key(), bundled.build().key());
    let home = Path::new("/Users/a");
    assert_eq!(found.build().acpmux_home(home), bundled.build().acpmux_home(home));
    let nightly = identity(Some("com.cmuxterm.app.nightly"), None).build();
    assert_ne!(found.build().acpmux_home(home), nightly.acpmux_home(home));
    assert_eq!(found.control_socket(home), PathBuf::from("/tmp/cmux-debug-mx.sock"));
    // Outside any bundle the environment still decides.
    assert_eq!(AppIdentity::detect(socket_only, None).unwrap().bundle_id, None);
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn app_bundle_is_found_from_the_bundled_cli() {
    assert_eq!(
        containing_app_bundle(Path::new("/A/cmux DEV x.app/Contents/Resources/bin/cmux")),
        Some(PathBuf::from("/A/cmux DEV x.app"))
    );
    assert_eq!(containing_app_bundle(Path::new("/usr/local/bin/cmux")), None);
}
