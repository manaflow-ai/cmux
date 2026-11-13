//! The readers `browser_import.read` names: every one answers, replies are the app's `Codable`
//! shapes, and a path under a folder macOS protects is refused before it is opened.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::indexing_slicing)]

mod common;

use base64::Engine as _;
use cmux_browser_import::ops::{OPS, OpError, call, protected};
use serde_json::{Value, json};

fn read(op: &str, request: Value) -> Value {
    call(op, &request, None).unwrap()
}

fn encode(bytes: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

#[test]
fn refusals() {
    assert_eq!(call("nope", &json!({}), None), Err(OpError::Unknown));
    assert_eq!(call("chromium.bookmarks", &json!({}), None), Err(OpError::Invalid));
    assert_eq!(call("chromium.bookmarks", &json!({"base64": "!!"}), None), Err(OpError::Invalid));
    assert_eq!(
        call("firefox.history", &json!({"path": "places.sqlite"}), None),
        Err(OpError::Refused)
    );
    assert_eq!(
        call("firefox.history", &json!({"path": "/tmp/a/../b/places.sqlite"}), None),
        Err(OpError::Refused)
    );
}

#[test]
fn protected_folders_are_refused_as_written_and_through_a_link() {
    let home = tempfile::tempdir().unwrap();
    let safari = home.path().join("Library/Safari");
    std::fs::create_dir_all(&safari).unwrap();
    common::write(&safari, "History.db", b"");
    let history = safari.join("History.db");
    let request = json!({"path": history.to_string_lossy()});
    assert_eq!(call("safari.history", &request, Some(home.path())), Err(OpError::Refused));
    let shouting = home.path().join("LIBRARY/safari/History.db");
    assert!(protected(&shouting, home.path()), "the Mac's volume ignores case");
    assert!(protected(&home.path().join("Library/Containers/x/Data"), home.path()));
    assert!(protected(&home.path().join("Library/Group Containers/g"), home.path()));
    assert!(!protected(&home.path().join("Library/Application Support/Google"), home.path()));
    #[cfg(unix)]
    {
        let link = home.path().join("elsewhere");
        std::os::unix::fs::symlink(&safari, &link).unwrap();
        assert!(protected(&link.join("History.db"), home.path()));
        let request = json!({"path": link.join("History.db").to_string_lossy()});
        assert_eq!(call("safari.history", &request, Some(home.path())), Err(OpError::Refused));
    }
    // Outside the home's protected folders the same reader answers.
    let other = home.path().join("Library/Application Support/x");
    std::fs::create_dir_all(&other).unwrap();
    let reply = call(
        "safari.history",
        &json!({"path": other.join("History.db").to_string_lossy()}),
        Some(home.path()),
    )
    .unwrap();
    assert!(reply["error"]["kind"].is_string(), "{reply}");
}

#[test]
fn every_op_answers_on_an_empty_profile() {
    let profile = tempfile::tempdir().unwrap();
    let dir = profile.path().to_string_lossy().into_owned();
    let missing = profile.path().join("missing").to_string_lossy().into_owned();
    let engine = json!({"name": "Kagi", "search": "https://kagi.com/search?q={searchTerms}"});
    for op in OPS {
        let request = json!({
            "path": missing, "profile": dir, "sessions": dir, "profileDirectory": "Default",
            "head": "{\"history\"", "services": null, "engine": engine, "builtIn": {}, "limit": 5,
        });
        let reply = read(op, request);
        assert!(reply.get("ok").is_some() || reply["error"]["kind"].is_string(), "{op}: {reply}");
    }
}

#[test]
fn replies_are_the_swift_codable_shapes() {
    let data = br#"{"roots":{"bookmark_bar":{"name":"Bar","children":[{"type":"url","name":"A","url":"https://a.example/","date_added":"13300000000000000"},{"type":"url","name":"B","url":"https://b.example/"}]}}}"#;
    let reply = common::ok(read("chromium.bookmarks", json!({ "base64": encode(data) })));
    assert_eq!(reply[0]["title"], "A");
    assert_eq!(reply[0]["url"], "https://a.example/");
    assert_eq!(reply[0]["folderPath"], json!(["Bar"]));
    assert!(reply[0]["dateAdded"].is_f64());
    assert!(reply[1].get("dateAdded").is_none(), "nil is a missing key");

    let folder = tempfile::tempdir().unwrap();
    common::write(folder.path(), "Bookmarks", b"[]");
    let path = folder.path().join("Bookmarks").to_string_lossy().into_owned();
    let error = read("chromium.bookmarks", json!({ "path": path }));
    assert_eq!(error["error"]["kind"], "notBookmarks");
    let none = folder.path().join("none");
    let missing = read("chromium.bookmarks", json!({ "path": none.to_string_lossy() }));
    assert_eq!(missing["error"]["kind"], "read");

    let session =
        common::moz_lz4(r#"{"windows":[{"tabs":[{"entries":[{"url":"https://a.example/"}]}]}]}"#);
    let tabs = common::ok(read("firefox.session", json!({ "base64": encode(&session) })));
    assert_eq!(tabs, json!([{"url": "https://a.example/", "window": 0, "pinned": false}]));

    let setting = common::ok(read(
        "search_engine.setting",
        json!({"engine": {"name": "DDG", "search": "https://duckduckgo.com/?q={searchTerms}"},
               "builtIn": {"duckduckgo": "https://duckduckgo.com/?q={searchTerms}"}}),
    ));
    assert_eq!(setting, json!({"engine": "duckduckgo"}));
    let custom = common::ok(read(
        "search_engine.setting",
        json!({"engine": {"name": "K", "search": "https://kagi.com/?q={searchTerms}", "suggest": "https://kagi.com/s?q={searchTerms}"},
               "builtIn": {"duckduckgo": "https://duckduckgo.com/?q={searchTerms}"}}),
    ));
    assert_eq!(
        custom,
        json!({"engine": "custom", "search": "https://kagi.com/?q={searchTerms}", "suggest": "https://kagi.com/s?q={searchTerms}"})
    );
    let exported = common::ok(read(
        "exported_history.parse",
        json!({"base64": encode(br#"{"history":[{"url":"https://a.example/","time_usec":978307200000000}]}"#)}),
    ));
    assert_eq!(
        exported,
        json!({"format": "safari", "entries": [{"url": "https://a.example/", "visitCount": 1, "lastVisit": 0.0}]})
    );
    assert_eq!(
        common::ok(read("exported_history.looks_like", json!({"head": "[]"}))),
        json!(false)
    );
    let safari = common::ok(read(
        "safari.search_engine",
        json!({"services": {"NSWebServicesProviderWebSearch": {"NSDefaultDisplayName": "DuckDuckGo", "NSProviderIdentifier": "com.duckduckgo"}}}),
    ));
    assert_eq!(safari["name"], "DuckDuckGo");
    assert_eq!(read("safari.search_engine", json!({})), json!({"ok": null}));
}
