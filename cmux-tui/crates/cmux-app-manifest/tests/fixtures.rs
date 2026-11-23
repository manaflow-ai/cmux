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

/// `contributes.wallpapers` (live-wallpapers.md): each listed folder passes
/// cmux-wallpaper's manifest and program checks. The program check needs
/// cmux-wallpaper/compile, which the dev-dependency turns on for tests.
#[test]
fn contributed_wallpapers_are_checked_with_the_app_validator() {
    const {
        assert!(
            cmux_wallpaper::CHECKS_PROGRAMS,
            "the dev-dependency turns on cmux-wallpaper/compile"
        );
    };
    let dir =
        std::env::temp_dir().join(format!("cmux-app-manifest-wallpapers-{}", std::process::id()));
    let ok_json = r#"{"id":"glow","name":"Glow","description":"A glow.","shader":"wallpaper.wgsl","fps":30,"scale":0.5,"interactive":true,"still":{"time":1,"pointer":[0.5,0.5]}}"#;
    let ok_wgsl = "fn wallpaper(px: vec2<f32>) -> vec4<f32> { return frame.paper; }\n";
    let folders = [
        ("wallpapers/glow", ok_json.to_string(), ok_wgsl.to_string()),
        // A program that keeps state: refused by the sandbox, with its line.
        (
            "wallpapers/stateful",
            ok_json.replace("glow", "stateful"),
            format!("var<private> n: f32;\n{ok_wgsl}"),
        ),
        // A manifest out of range.
        (
            "wallpapers/fast",
            ok_json.replace("glow", "fast").replace("30", "120"),
            ok_wgsl.to_string(),
        ),
        // The same id twice.
        ("wallpapers/glow-again", ok_json.to_string(), ok_wgsl.to_string()),
    ];
    for (path, json, wgsl) in &folders {
        std::fs::create_dir_all(dir.join(path)).expect("mkdir");
        std::fs::write(dir.join(path).join("wallpaper.json"), json).expect("write");
        std::fs::write(dir.join(path).join("wallpaper.wgsl"), wgsl).expect("write");
    }
    let mut list: Vec<Value> = folders.iter().map(|(p, _, _)| json!({ "path": p })).collect();
    list.push(json!({ "path": "wallpapers/missing" }));
    let m = manifest(json!({ "contributes": { "wallpapers": list }, "icon": { "symbol": "app" } }));
    assert!(is_valid(&validate_manifest(&m)), "{:?}", validate_manifest(&m));
    std::fs::write(dir.join("cmux-app.json"), m.to_string()).expect("write");

    // The missing folder is a path issue first; nothing else runs until paths are good.
    let report = validate_package(&dir);
    let got: Vec<_> = report
        .issues
        .iter()
        .filter(|i| i.code != "icon.noImage")
        .map(|i| (i.path.as_str(), i.code))
        .collect();
    assert_eq!(got, vec![("/contributes/wallpapers/4/path", "path.missing")]);

    list.pop();
    let m = manifest(json!({ "contributes": { "wallpapers": list }, "icon": { "symbol": "app" } }));
    std::fs::write(dir.join("cmux-app.json"), m.to_string()).expect("write");
    let report = validate_package(&dir);
    let got: Vec<_> = report
        .issues
        .iter()
        .filter(|i| i.code != "icon.noImage")
        .map(|i| (i.path.as_str(), i.code, i.message.as_str()))
        .collect();
    assert_eq!(got.len(), 3, "{got:?}");
    assert_eq!(got[0].0, "/contributes/wallpapers/1/path");
    assert_eq!(got[0].1, "wallpaper.program");
    assert!(got[0].2.starts_with("wallpapers/stateful/wallpaper.wgsl:1:"), "{}", got[0].2);
    assert_eq!((got[1].0, got[1].1), ("/contributes/wallpapers/2/path", "wallpaper.manifest"));
    assert!(got[1].2.contains("/fps"), "{}", got[1].2);
    assert_eq!((got[2].0, got[2].1), ("/contributes/wallpapers/3/path", "wallpaper.duplicate"));
    std::fs::remove_dir_all(&dir).ok();
}

/// A wallpaper's files are read only inside the package, as its catalog is: a
/// program symlinked to a file outside the package is refused unread.
#[cfg(unix)]
#[test]
fn a_wallpaper_program_symlinked_out_of_the_package_is_refused() {
    let base = std::env::temp_dir()
        .join(format!("cmux-app-manifest-wallpaper-link-{}", std::process::id()));
    let dir = base.join("pkg");
    let folder = dir.join("wallpapers/glow");
    std::fs::create_dir_all(&folder).expect("mkdir");
    let outside = base.join("outside.wgsl");
    std::fs::write(&outside, "fn wallpaper(px: vec2<f32>) -> vec4<f32> { return frame.paper; }\n")
        .expect("write");
    std::os::unix::fs::symlink(&outside, folder.join("wallpaper.wgsl")).expect("symlink");
    let json = r#"{"id":"glow","name":"Glow","description":"A glow.","shader":"wallpaper.wgsl","fps":30,"scale":0.5,"interactive":true,"still":{"time":1,"pointer":[0.5,0.5]}}"#;
    std::fs::write(folder.join("wallpaper.json"), json).expect("write");
    let m = manifest(json!({
        "contributes": { "wallpapers": [{ "path": "wallpapers/glow" }] },
        "icon": { "symbol": "app" }
    }));
    std::fs::write(dir.join("cmux-app.json"), m.to_string()).expect("write");
    let report = validate_package(&dir);
    let got: Vec<_> = report
        .issues
        .iter()
        .filter(|i| i.code != "icon.noImage")
        .map(|i| (i.path.as_str(), i.code, i.message.as_str()))
        .collect();
    assert_eq!(got.len(), 1, "{got:?}");
    assert_eq!((got[0].0, got[0].1), ("/contributes/wallpapers/0/path", "wallpaper.program"));
    assert!(got[0].2.contains("not a file inside the package"), "{}", got[0].2);
    std::fs::remove_dir_all(&base).ok();
}

#[test]
fn contributed_wallpapers_are_capped_at_16() {
    let list: Vec<Value> = (0..17).map(|i| json!({ "path": format!("w/{i}") })).collect();
    let m = manifest(json!({ "contributes": { "wallpapers": list } }));
    assert!(!is_valid(&validate_manifest(&m)));
    let m = manifest(json!({ "contributes": { "wallpapers": [{ "path": "../w" }] } }));
    assert!(!is_valid(&validate_manifest(&m)));
    let m = manifest(json!({ "contributes": { "wallpapers": [{ "path": "w", "extra": 1 }] } }));
    assert!(!is_valid(&validate_manifest(&m)));
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

/// A text field past the schema's 300-character cap is refused with an issue
/// that names the field and its length (the schema's own answer is a `oneOf`
/// miss that repeats the text and never says why; the daemon then drops the
/// package from the App Store with only that line to show for it).
#[test]
fn a_text_field_over_its_cap_names_the_field_and_its_length() {
    let long = "x".repeat(cmux_app_manifest::TEXT_MAX_CHARS + 112);
    for (m, path) in [
        (manifest(json!({ "description": long })), "/description"),
        (manifest(json!({ "description": { "en": "ok", "de": long } })), "/description/de"),
    ] {
        let issues = validate_manifest(&m);
        let issue = issues.iter().find(|i| i.code == "text.too_long").expect("text.too_long");
        assert_eq!(issue.path, path, "{issues:?}");
        assert_eq!(issue.message, "is 412 characters; the limit is 300");
    }
    let at_cap = "x".repeat(cmux_app_manifest::TEXT_MAX_CHARS);
    assert!(!codes(&manifest(json!({ "description": at_cap }))).contains(&"text.too_long"));
    // Another oneOf with a string past 300 (an icon path, capped lower) keeps its own error.
    let icon = format!("assets/{}.png", "x".repeat(cmux_app_manifest::TEXT_MAX_CHARS));
    let icon_codes = codes(&manifest(json!({ "icon": icon })));
    assert!(!icon_codes.contains(&"text.too_long"), "{icon_codes:?}");
    assert!(icon_codes.contains(&"schema"), "{icon_codes:?}");
}

/// The cap above is the schema's (`$defs/text`), not a second copy that can drift.
#[test]
fn the_text_cap_is_the_schemas() {
    let schema: Value = serde_json::from_str(cmux_app_manifest::SCHEMA).expect("schema");
    let text = &schema["$defs"]["text"]["oneOf"];
    assert_eq!(text[0]["maxLength"], cmux_app_manifest::TEXT_MAX_CHARS);
    assert_eq!(text[1]["additionalProperties"]["maxLength"], cmux_app_manifest::TEXT_MAX_CHARS);
}
