use super::*;
use serde_json::json;

/// The old cmux app answers identify without `app` (0.64) or with
/// `"app": "cmux"` (later), always with its bundle and CLI paths.
#[test]
fn the_old_app_is_named_with_its_cli() {
    let identify = json!({
        "app_bundle_path": "/Applications/cmux.app",
        "app_cli_path": "/Applications/cmux.app/Contents/Resources/bin/cmux",
        "socket_path": "/Users/u/.local/state/cmux/cmux.sock",
    });
    let peer = Peer::from_identify(&identify).unwrap();
    assert!(peer.classic);
    let text = message(
        "action.run",
        &peer,
        Some(Path::new("/Applications/cmux NEXT.app/Contents/Resources/bin/cmux")),
    )
    .unwrap();
    assert!(text.contains("action.run"), "{text}");
    assert!(text.contains(env!("CARGO_PKG_VERSION")), "{text}");
    assert!(text.contains("/Users/u/.local/state/cmux/cmux.sock"), "{text}");
    assert!(text.contains("/Applications/cmux.app/Contents/Resources/bin/cmux"), "{text}");

    let versioned =
        Peer::from_identify(&json!({ "app": "cmux", "version": "0.66.0", "build": "110",
        "app_bundle_path": "/Applications/cmux.app" }))
        .unwrap();
    assert!(versioned.classic);
    assert_eq!(versioned.version.as_deref(), Some("0.66.0 (110)"));
}

#[test]
fn an_older_cmux_next_is_told_to_update() {
    let peer = Peer::from_identify(&json!({ "app": "cmux-next", "version": "0.1.0", "build": "7",
        "socket_path": "/tmp/cmux-debug-x.sock" }))
    .unwrap();
    assert!(!peer.classic);
    let text = message("browser.page.state", &peer, None).unwrap();
    assert!(text.contains("cmux-next 0.1.0 (7)"), "{text}");
    assert!(text.contains("browser.page.state"), "{text}");
}

/// The app whose bundled CLI is this binary: a real unknown method, no skew.
#[test]
fn this_clis_own_app_is_not_skew() {
    let me = std::env::current_exe().unwrap();
    let peer = Peer::from_identify(
        &json!({ "app": "cmux-next", "version": "1", "app_cli_path": me.to_str().unwrap() }),
    )
    .unwrap();
    assert_eq!(message("nope", &peer, Some(&me)), None);
}

#[test]
fn an_unidentified_answer_is_left_alone() {
    assert_eq!(Peer::from_identify(&json!({ "focused": null })), None);
}
