use std::ffi::OsString;

use serde_json::json;

use super::*;

fn parse(text: &str) -> Value {
    jsonc::parse(text).unwrap()
}

#[test]
fn scoped_keys_are_the_cmux_tools_answer_and_every_computer_use_key() {
    for key in ["agents.cmuxMcp", "agents.cmuxMcpClaude", "computerUse", "computerUse.mode"] {
        assert!(is_scoped_key(key), "{key}");
    }
    for key in
        ["agents.cmuxMcpX", "agents.defaultPermissionMode", "computerUseX", "appearance.density"]
    {
        assert!(!is_scoped_key(key), "{key}");
    }
}

#[test]
fn the_build_file_applies_only_to_the_shared_settings_file() {
    let env = |pairs: &'static [(&'static str, &'static str)]| {
        move |name: &str| {
            pairs.iter().find(|(key, _)| *key == name).map(|(_, value)| OsString::from(*value))
        }
    };
    assert_eq!(build_file_from(env(&[])), None);
    assert_eq!(
        build_file_from(env(&[(BUILD_SETTINGS_ENV, "/b/build-settings.json")])),
        Some(PathBuf::from("/b/build-settings.json"))
    );
    assert_eq!(
        build_file_from(env(&[(BUILD_SETTINGS_ENV, "~/b.json"), ("HOME", "/h")])),
        Some(PathBuf::from("/h/b.json"))
    );
    // A build on its own settings file (a DEV build, a test launch): that file is already its own.
    assert_eq!(
        build_file_from(env(&[(BUILD_SETTINGS_ENV, "/b.json"), (CONFIG_OVERRIDE, "/own.json")])),
        None
    );
    // The shared file named explicitly (the agent shims always name the settings file) is still
    // the shared file.
    assert_eq!(
        build_file_from(env(&[
            (BUILD_SETTINGS_ENV, "/b.json"),
            (CONFIG_OVERRIDE, "/h/.config/cmux/cmux-next.json"),
            ("HOME", "/h")
        ])),
        Some(PathBuf::from("/b.json"))
    );
    // A relative name is no file of the build's.
    assert_eq!(build_file_from(env(&[(BUILD_SETTINGS_ENV, "b.json")])), None);
}

#[test]
fn extract_takes_flat_and_nested_forms_and_off_wins() {
    let root = parse(
        r#"{"agents": {"cmuxMcp": "on", "defaultPermissionMode": "plan"}, "agents.cmuxMcp": "off",
            "computerUse": {"mode": "fullAccess"}, "computerUse.deniedApps": ["Mail"],
            "appearance": {"density": "compact"}}"#,
    );
    assert_eq!(
        extract(&root),
        json!({"agents": {"cmuxMcp": "off"},
               "computerUse": {"mode": "fullAccess", "deniedApps": ["Mail"]}})
    );
}

#[test]
fn the_overlay_replaces_only_build_scoped_members_and_keeps_the_rest_byte_for_byte() {
    let shared = "{\n  // mine\n  \"appearance\": {\"density\": \"compact\"},\n  \"agents\": {\"cmuxMcp\": \"off\", \"defaultPermissionMode\": \"plan\"},\n  \"computerUse.mode\": \"fullAccess\"\n}\n";
    let merged = overlaid_source(shared, &json!({"computerUse": {"mode": "askEveryTime"}}));
    assert!(merged.contains("// mine"), "{merged}");
    let root = parse(&merged);
    assert_eq!(root.pointer("/appearance/density"), Some(&json!("compact")));
    assert_eq!(root.pointer("/agents/defaultPermissionMode"), Some(&json!("plan")));
    // The shared file's answer is not this build's: no value here, the default.
    assert_eq!(root.pointer("/agents/cmuxMcp"), None);
    assert_eq!(root.get("computerUse.mode"), None);
    assert_eq!(root.pointer("/computerUse/mode"), Some(&json!("askEveryTime")));
    // A missing shared file and no values stays missing.
    assert_eq!(overlaid_source("", &json!({})), "");
    assert_eq!(
        parse(&overlaid_source("", &json!({"agents": {"cmuxMcp": "off"}}))),
        json!({"agents": {"cmuxMcp": "off"}})
    );
}

#[test]
fn the_first_read_copies_the_shared_values_once_then_builds_part() {
    let root = tempfile::tempdir().unwrap();
    let shared_path = root.path().join("cmux-next.json");
    let nightly = root.path().join("builds/com.cmuxterm.app.nightly/build-settings.json");
    let release = root.path().join("builds/com.cmuxterm.app/build-settings.json");
    std::fs::write(
        &shared_path,
        r#"{"agents": {"cmuxMcp": "off"}, "computerUse": {"mode": "fullAccess"}, "x": 1}"#,
    )
    .unwrap();
    // Each build's first read migrates what the person chose before the split.
    for file in [&nightly, &release] {
        let text = effective_text_with(&shared_path, Some(file)).unwrap();
        assert_eq!(parse(&text).pointer("/computerUse/mode"), Some(&json!("fullAccess")));
        assert_eq!(parse(&text).pointer("/agents/cmuxMcp"), Some(&json!("off")));
        assert!(file.is_file());
    }
    // NIGHTLY turns Computer Use to ask and cmux tools on: Release keeps its own.
    std::fs::write(&nightly, render(&json!({"computerUse": {"mode": "askEveryTime"}}))).unwrap();
    let nightly_text = effective_text_with(&shared_path, Some(&nightly)).unwrap();
    let release_text = effective_text_with(&shared_path, Some(&release)).unwrap();
    assert_eq!(parse(&nightly_text).pointer("/computerUse/mode"), Some(&json!("askEveryTime")));
    assert_eq!(parse(&nightly_text).pointer("/agents/cmuxMcp"), None);
    assert_eq!(parse(&release_text).pointer("/computerUse/mode"), Some(&json!("fullAccess")));
    assert_eq!(parse(&release_text).pointer("/agents/cmuxMcp"), Some(&json!("off")));
    // A later change of the shared file's own copy (an older build) reaches neither.
    std::fs::write(&shared_path, r#"{"computerUse": {"mode": "off"}, "x": 2}"#).unwrap();
    let release_text = effective_text_with(&shared_path, Some(&release)).unwrap();
    assert_eq!(parse(&release_text).pointer("/computerUse/mode"), Some(&json!("fullAccess")));
    assert_eq!(parse(&release_text).get("x"), Some(&json!(2)));
    // Without a build file the shared file reads as it is.
    assert_eq!(
        effective_text_with(&shared_path, None).unwrap(),
        std::fs::read_to_string(&shared_path).unwrap()
    );
}

#[test]
fn split_sends_build_values_to_the_build_and_leaves_the_shared_file_alone() {
    let disk = "{\n  // mine\n  \"computerUse\": {\"mode\": \"fullAccess\"},\n  \"x\": 1\n}\n";
    // A write of a build-scoped key only.
    let merged = overlaid_source(disk, &json!({"computerUse": {"mode": "askEveryTime"}}));
    let (values, shared) = split(&merged, disk).unwrap();
    assert_eq!(values, json!({"computerUse": {"mode": "askEveryTime"}}));
    assert_eq!(shared, None, "the shared file was rewritten for a build-scoped change");
    // A write of an ordinary key: the shared file gets it, with its own Computer Use copy kept.
    let edited = jsonc::set(&merged, &["x".to_string()], &json!(5)).unwrap();
    let (values, shared) = split(&edited, disk).unwrap();
    assert_eq!(values, json!({"computerUse": {"mode": "askEveryTime"}}));
    let shared = shared.expect("the ordinary change was not published");
    assert!(shared.contains("// mine"));
    assert_eq!(parse(&shared), json!({"computerUse": {"mode": "fullAccess"}, "x": 5}));
}

#[test]
fn a_broken_shared_file_at_the_first_read_writes_nothing_and_the_next_good_read_migrates() {
    let root = tempfile::tempdir().unwrap();
    let shared_path = root.path().join("cmux-next.json");
    let build = root.path().join("builds/com.cmuxterm.app/build-settings.json");
    // A save half done: the person's denied apps must not be lost to it.
    std::fs::write(&shared_path, r#"{"computerUse": {"deniedApps": ["Mail"]"#).unwrap();
    let _ = effective_text_with(&shared_path, Some(&build));
    assert!(!build.exists(), "a broken moment of the shared file became the build's values");
    std::fs::write(&shared_path, r#"{"computerUse": {"deniedApps": ["Mail"]}}"#).unwrap();
    let text = effective_text_with(&shared_path, Some(&build)).unwrap();
    assert_eq!(parse(&text).pointer("/computerUse/deniedApps"), Some(&json!(["Mail"])));
    assert_eq!(
        parse(&std::fs::read_to_string(&build).unwrap()),
        json!({"computerUse": {"deniedApps": ["Mail"]}})
    );
}

#[test]
fn every_copy_of_a_repeated_scoped_key_goes_and_a_set_one_stays_in_place() {
    let shared = "{\n  \"computerUse\": {\"mode\": \"off\"},\n  \"x\": 1,\n  \"computerUse\": {\"mode\": \"fullAccess\"}\n}\n";
    // No Computer Use values of the build's: no copy of another build's shows through.
    assert_eq!(parse(&overlaid_source(shared, &json!({}))).get("computerUse"), None);
    // A value the build sets replaces the member where it is, with the comment above it.
    let commented = "{\n  // grants\n  \"computerUse\": {\"mode\": \"off\"},\n  \"x\": 1\n}\n";
    let merged = overlaid_source(commented, &json!({"computerUse": {"mode": "approvedApps"}}));
    assert!(merged.contains("// grants\n  \"computerUse\""), "{merged}");
    assert!(merged.find("computerUse").unwrap() < merged.find("\"x\"").unwrap(), "{merged}");
}

#[test]
fn a_broken_build_file_is_reported_and_never_replaced() {
    let root = tempfile::tempdir().unwrap();
    let build = root.path().join("build-settings.json");
    assert!(!build_file_is_broken(&build), "a missing file is not broken");
    std::fs::write(&build, "{\"computerUse\": ").unwrap();
    assert!(build_file_is_broken(&build));
    std::fs::write(&build, "{}").unwrap();
    assert!(!build_file_is_broken(&build));
}
