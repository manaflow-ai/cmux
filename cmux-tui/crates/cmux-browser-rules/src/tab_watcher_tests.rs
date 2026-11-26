//! The watcher's same-document rule, pinned to `TabWatcher.urlChanged`.

use crate::ops;
use crate::tab_watcher::*;
use serde_json::json;

#[test]
fn a_fragment_change_is_same_document_even_during_a_load() {
    let mut watch = UrlWatch { last_url: Some("https://a.test/p".into()) };
    assert!(watch.url_changed(Some("https://a.test/p#x"), true, true));
    assert_eq!(watch.last_url.as_deref(), Some("https://a.test/p#x"));
}

#[test]
fn a_url_change_outside_a_load_is_push_state() {
    let mut watch = UrlWatch { last_url: Some("https://a.test/p".into()) };
    assert!(watch.url_changed(Some("https://a.test/q"), false, false));
    // Inside a load (provisional or loading), it is the load's own URL.
    assert!(!watch.url_changed(Some("https://a.test/r"), true, false));
    assert!(!watch.url_changed(Some("https://a.test/s"), false, true));
    assert_eq!(watch.last_url.as_deref(), Some("https://a.test/s"));
}

#[test]
fn no_change_and_changes_from_or_to_no_url_are_none() {
    let mut watch = UrlWatch::default();
    assert!(!watch.url_changed(Some("https://a.test/"), false, false));
    assert!(!watch.url_changed(Some("https://a.test/"), false, false));
    assert!(!watch.url_changed(None, false, false));
    assert_eq!(watch.last_url, None);
    // macOS 26 shows a fragment's `#` as `%23`: not a fragment change.
    assert!(!differ_only_in_fragment("https://a.test/p", "https://a.test/p%23x"));
}

#[test]
fn url_change_op_answers_the_next_watch() {
    let reply = ops::call(
        "browser_rules_automation_url_change",
        json!({"lastUrl": "https://a.test/", "url": "https://a.test/#top", "provisional": false, "loading": true}),
    )
    .unwrap();
    assert_eq!(reply, json!({"lastUrl": "https://a.test/#top", "sameDocument": true}));
}
