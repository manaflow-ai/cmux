//! Shared fixtures (`cmux-app-host/schema/v2/fixtures`): every valid manifest
//! passes; every invalid one fails at (or under) the expected JSON pointer.

use cmux_app_manifest::{Issue, is_valid, validate_manifest, validate_package};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};

fn fixtures(kind: &str) -> Vec<PathBuf> {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../cmux-app-host/schema/v2/fixtures")
        .join(kind);
    let mut out: Vec<PathBuf> = std::fs::read_dir(dir)
        .expect("fixture dir")
        .map(|e| e.expect("entry").path())
        .filter(|p| {
            p.extension().is_some_and(|e| e == "json")
                && !p.to_string_lossy().ends_with(".expect.json")
        })
        .collect();
    out.sort();
    out
}

fn load(p: &Path) -> Value {
    serde_json::from_str(&std::fs::read_to_string(p).expect("read")).expect("json")
}

#[test]
fn valid_fixtures_pass() {
    let all = fixtures("valid");
    assert!(all.len() >= 4);
    for p in all {
        let issues = validate_manifest(&load(&p));
        assert!(is_valid(&issues), "{}: {issues:?}", p.display());
    }
}

#[test]
fn invalid_fixtures_fail_at_the_expected_path() {
    let all = fixtures("invalid");
    assert!(all.len() >= 5);
    for p in all {
        let expect = load(&p.with_extension("expect.json"));
        let want = expect["path"].as_str().expect("path");
        let issues = validate_manifest(&load(&p));
        assert!(!is_valid(&issues), "{} should be invalid", p.display());
        // Schema errors for unknown keys and oneOf point at the parent object; accept the expected path or a parent of it.
        assert!(
            issues.iter().any(|i: &Issue| want == i.path
                || want.starts_with(&format!("{}/", i.path))
                || i.path.is_empty()),
            "{}: no issue at {want}: {issues:?}",
            p.display()
        );
    }
}

fn manifest(extra: Value) -> Value {
    let mut m = json!({ "manifestVersion": 2, "id": "local/x", "name": "X", "version": "1.0.0", "description": "d", "engines": { "cmux": "^2.0" }, "icon": "assets/icon.png" });
    for (k, v) in extra.as_object().expect("object") {
        m[k] = v.clone();
    }
    m
}

fn codes(m: &Value) -> Vec<&'static str> {
    validate_manifest(m).into_iter().map(|i| i.code).collect()
}

#[test]
fn native_code_is_first_party_only() {
    let third = manifest(json!({ "id": "octo/x", "repository": "https://github.com/octo/x",
        "server": { "kind": "native", "binaries": { "linux-x64": "x" }, "instances": "user", "hosts": ["local"] },
        "implements": { "cmux.pane/1": { "native": "x.view" } } }));
    assert_eq!(codes(&third), vec!["tier.native", "tier.native", "tier.nativeReview"]);
    let first = manifest(
        json!({ "id": "cmux/x", "repository": "https://github.com/manaflow-ai/cmux",
        "server": { "kind": "native", "binaries": { "linux-x64": "x" }, "instances": "user", "hosts": ["local"] },
        "implements": { "cmux.pane/1": { "native": "x.view" } } }),
    );
    assert!(codes(&first).is_empty());
}

#[test]
fn publisher_rules() {
    assert_eq!(
        codes(&manifest(json!({ "id": "alice/x", "repository": "https://github.com/bob/x" }))),
        vec!["publisher.mismatch"]
    );
    assert_eq!(
        codes(&manifest(json!({ "id": "cmux/x", "repository": "https://github.com/mallory/x" }))),
        vec!["publisher.reserved"]
    );
    assert_eq!(codes(&manifest(json!({ "id": "alice/x" }))), vec!["repository.required"]);
}

#[test]
fn interfaces_and_runtimes_must_match() {
    let m = manifest(
        json!({ "implements": { "cmux.nope/1": { "export": "x" }, "cmux.editor/1": { "web": "w.html" } }, "consumes": { "interfaces": ["cmux.nope/2"] } }),
    );
    assert_eq!(
        codes(&m),
        vec![
            "runtime.web.required",
            "interface.unknown",
            "runtime.main.required",
            "interface.unknown"
        ]
    );
}

#[test]
fn variant_default_is_one_of_its_values() {
    let m = manifest(
        json!({ "variants": [{ "id": "layout", "title": "Layout", "values": ["grid", "list"], "default": "split" }] }),
    );
    assert_eq!(codes(&m), vec!["variant.default"]);
}

#[test]
fn package_paths_are_checked() {
    let dir = std::env::temp_dir().join(format!("cmux-app-manifest-{}", std::process::id()));
    std::fs::create_dir_all(dir.join("src")).expect("mkdir");
    std::fs::write(dir.join("src/main.js"), "var __cmuxAppExports = {}").expect("write");
    let m = manifest(
        json!({ "runtime": { "main": "src/main.js" }, "catalog": "catalog.json", "files": ["dist/"], "icon": { "symbol": "app" } }),
    );
    std::fs::write(dir.join("cmux-app.json"), m.to_string()).expect("write");
    let report = validate_package(&dir);
    let got: Vec<_> = report
        .issues
        .iter()
        .filter(|i| i.code != "icon.noImage")
        .map(|i| (i.path.as_str(), i.code))
        .collect();
    assert_eq!(got, vec![("/runtime/main", "path.notInFiles"), ("/catalog", "path.missing")]);
    std::fs::remove_dir_all(&dir).ok();
}

/// Step 11 (extensibility-DESIGN.md 12.1 item 12): an app whose script or
/// manifest strings carry a character that hides what it does is refused at
/// load and install, naming file, line and column, never the text.
#[test]
fn a_script_or_manifest_string_with_a_hidden_character_is_refused() {
    let dir = std::env::temp_dir().join(format!("cmux-app-manifest-hidden-{}", std::process::id()));
    std::fs::create_dir_all(dir.join("dist")).expect("mkdir");
    std::fs::write(
        dir.join("dist/main.js"),
        "let ok = 1;\nlet admin = \"user\u{202E} \u{2066}// x\";\n",
    )
    .expect("write");
    let m = manifest(json!({ "runtime": { "main": "dist/main.js" }, "icon": { "symbol": "app" } }));
    std::fs::write(dir.join("cmux-app.json"), m.to_string()).expect("write");
    let report = validate_package(&dir);
    let hidden: Vec<_> = report.issues.iter().filter(|i| i.code == "text.hidden").collect();
    assert_eq!(hidden.len(), 1, "{:?}", report.issues);
    assert_eq!(hidden[0].path, "/runtime/main");
    assert!(hidden[0].message.starts_with("dist/main.js:2:18 "), "{}", hidden[0].message);
    assert!(hidden[0].message.contains("U+202E"));
    assert!(!report.is_valid());

    std::fs::write(dir.join("dist/main.js"), "text.replace(/^\u{FEFF}/, '');\n").expect("write");
    assert!(!validate_package(&dir).issues.iter().any(|i| i.code == "text.hidden"));
    std::fs::remove_dir_all(&dir).ok();

    let named = manifest(json!({ "description": "Shows the time\u{200B}" }));
    let issues = validate_manifest(&named);
    assert!(
        issues.iter().any(|i| i.code == "text.hidden" && i.path == "/description"),
        "{issues:?}"
    );
}

#[test]
fn sidebar_sections_accept_all_three_regions_including_bottom() {
    for region in ["top", "middle", "bottom"] {
        let value =
            manifest(json!({"runtime": {"main": "main.js"}, "implements": {"cmux.section/1": {
                "export": "render", "options": {"defaultRegion": region}
            }}}));
        assert!(codes(&value).is_empty(), "{region}: {:?}", codes(&value));
    }
}
