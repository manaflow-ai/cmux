//! After an update: a library written by an older app is read against this
//! app's own tables, and only the keys that no longer apply are named. The
//! library file is left as it was.

use std::fs;

use cmux_customize::{Customize, Roots};
use serde_json::json;

fn entry(name: &str, on: bool, settings: serde_json::Value) -> serde_json::Value {
    json!({
        "on": on,
        "source": "ask",
        "words": ["make it roomy"],
        "profile": { "cmuxProfile": 1, "name": name, "settings": settings, "files": {} },
    })
}

#[test]
fn an_older_apps_library_names_only_the_keys_this_app_lacks() {
    let dir = tempfile::tempdir().unwrap();
    let customize = Customize::open(Roots::under(dir.path()));
    let library = json!({
        "version": 1,
        "entries": [
            entry("roomy", true, json!({
                "appearance.density": "compact",
                "appearance.noSuchKeyAnyMore": true,
                "remote.ultraMode": true,
            })),
            entry("fine", true, json!({ "appearance.density": "cozy" })),
            entry("asleep", false, json!({ "appearance.noSuchKeyAnyMore": true })),
        ],
        "base": {},
    });
    let path = dir.path().join("state/library.json");
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let text = serde_json::to_string_pretty(&library).unwrap();
    fs::write(&path, &text).unwrap();

    let found = customize.library_no_longer_applies();
    let lines: Vec<String> = found.iter().map(|entry| entry.line()).collect();
    assert_eq!(
        lines,
        [
            "settings layer \"roomy\": 2 keys no longer apply: appearance.noSuchKeyAnyMore (gone), remote.ultraMode (renamed to remote.ultra)"
        ]
    );
    assert_eq!(fs::read_to_string(&path).unwrap(), text, "the check never writes");
    let listing = customize.library().unwrap();
    assert!(listing.entries.iter().find(|e| e.name == "roomy").unwrap().on, "still on");
}

#[test]
fn no_library_says_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let customize = Customize::open(Roots::under(dir.path()));
    assert!(customize.library_no_longer_applies().is_empty());
}
