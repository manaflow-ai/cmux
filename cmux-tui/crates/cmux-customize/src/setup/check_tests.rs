use std::fs;
use std::path::Path;

use super::*;

fn options() -> CheckOptions<'static> {
    CheckOptions { owner: None, running: "0.0.0", history: &NoHistory }
}

/// A setup folder: `cmux-setup.json` from `settings` (JSON object text) and
/// the files given by repo path.
fn repo(root: &Path, settings: &str, files: &[(&str, &str)]) {
    fs::write(
        root.join(SETUP_FILE),
        format!(
            r#"{{
  // JSONC, as cmux-next.json is.
  "cmuxSetup": 1,
  "id": "leo/night",
  "name": "Night",
  "description": "A dark theme and compact rows.",
  "repository": "https://github.com/leo/cmux-night",
  "cmuxProfile": 1,
  "settings": {settings}
}}"#
        ),
    )
    .unwrap();
    for (path, text) in files {
        let file = root.join(path);
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        fs::write(file, text).unwrap();
    }
}

const THEME: &str = r##"{ "name": "Night", "appearance.theme": "Builtin Dark", "colors": { "background": "#101014", "foreground": "#e4e4e7" } }"##;

fn codes_of(report: &Report) -> Vec<&'static str> {
    report.findings.iter().map(|finding| finding.code).collect()
}

#[test]
fn a_good_setup_has_no_findings() {
    let dir = tempfile::tempdir().unwrap();
    repo(
        dir.path(),
        r#"{ "appearance.themeFile": "night", "appearance.density": "compact" }"#,
        &[("themes/night.json", THEME), ("keybindings.json", "[]")],
    );
    let report = check_dir(dir.path(), &options());
    assert_eq!(report.findings, Vec::new());
    assert!(report.ok);
    assert_eq!(report.setup_id.as_deref(), Some("leo/night"));
    // What install reads from the folder is the same setup the check passed.
    assert!(crate::setup::read_dir(dir.path()).is_ok());
}

#[test]
fn an_unknown_key_is_an_error_that_names_the_key_and_the_near_one() {
    let dir = tempfile::tempdir().unwrap();
    repo(dir.path(), r#"{ "appearance.densty": "compact" }"#, &[]);
    let report = check_dir(dir.path(), &options());
    assert!(!report.ok);
    let [finding] = &report.findings[..] else { panic!("{:?}", report.findings) };
    assert_eq!(finding.code, codes::SETTING_UNKNOWN);
    assert_eq!(finding.key.as_deref(), Some("appearance.densty"));
    assert_eq!(finding.path, SETUP_FILE);
    assert_eq!(finding.fix.as_deref(), Some("did you mean appearance.density?"));
}

#[test]
fn a_bad_value_is_an_error_that_never_quotes_the_value() {
    let dir = tempfile::tempdir().unwrap();
    repo(dir.path(), r#"{ "appearance.density": "private-value-42" }"#, &[]);
    let report = check_dir(dir.path(), &options());
    assert_eq!(codes_of(&report), [codes::SETTING_VALUE]);
    assert_eq!(report.findings[0].key.as_deref(), Some("appearance.density"));
    let json = serde_json::to_string(&report).unwrap();
    assert!(!json.contains("private-value-42"), "{json}");
}

#[test]
fn every_error_is_reported_and_install_still_refuses_on_the_first() {
    let dir = tempfile::tempdir().unwrap();
    repo(
        dir.path(),
        r#"{ "appearance.densty": "compact", "appearance.density": 42 }"#,
        &[("themes/broken.json", "{ \"name\": ")],
    );
    let report = check_dir(dir.path(), &options());
    let codes = codes_of(&report);
    assert!(codes.contains(&codes::SETTING_UNKNOWN), "{codes:?}");
    assert!(codes.contains(&codes::SETTING_VALUE), "{codes:?}");
    assert!(codes.contains(&codes::FILE_INVALID), "{codes:?}");
    assert_eq!(report.errors(), 3, "{:?}", report.findings);
    // Install's refusal is the first of them, in the same words.
    let read = crate::setup::read_dir(dir.path()).unwrap();
    let customize = crate::Customize::open(Roots::under(dir.path()));
    let Err(Error::Profile(why)) = customize.check_setup(&read) else { panic!() };
    assert_eq!(why, report.findings[0].message);
}

#[test]
fn a_header_and_its_actions_report_together() {
    let dir = tempfile::tempdir().unwrap();
    fs::write(
        dir.path().join(SETUP_FILE),
        r#"{ "cmuxSetup": 1, "id": "Leo/Night", "name": "N", "engines": { "cmux": "latest" },
             "extensions": ["not a reference"],
             "actions": { "a b": { "command": "x" }, "shell": { "type": "shell", "command": "x" } } }"#,
    )
    .unwrap();
    let report = check_dir(dir.path(), &options());
    let codes = codes_of(&report);
    for code in [codes::SETUP_ID, codes::EXTENSION, codes::ACTION_INVALID] {
        assert!(codes.contains(&code), "{code} in {codes:?}");
    }
    assert_eq!(codes.iter().filter(|code| **code == codes::ACTION_INVALID).count(), 2);
    // An engines line no cmux reads installs everywhere: a warning.
    let engines = report.findings.iter().find(|f| f.code == codes::SETUP_ENGINES).unwrap();
    assert_eq!(engines.severity, Severity::Warning);
}

#[test]
fn theme_files_are_read_by_the_theme_reader() {
    let dir = tempfile::tempdir().unwrap();
    repo(
        dir.path(),
        r#"{ "appearance.themeFile": "gone" }"#,
        &[("themes/night.json", r#"{ "name": "Night", "appearance.nope": 1 }"#)],
    );
    let report = check_dir(dir.path(), &options());
    let codes = codes_of(&report);
    assert!(codes.contains(&codes::THEME_MISSING), "{codes:?}");
    let value = report.findings.iter().find(|f| f.code == codes::THEME_VALUE);
    let value = value.unwrap_or_else(|| panic!("{:?}", report.findings));
    assert_eq!(value.path, "themes/night.json");
    assert_eq!(value.key.as_deref(), Some("appearance.nope"));
}

#[test]
fn the_views_manifest_is_held_to_the_app_validator() {
    let dir = tempfile::tempdir().unwrap();
    repo(
        dir.path(),
        "{}",
        &[(
            "customize/cmux-app.json",
            r#"{ "manifestVersion": 2, "id": "local/customize", "name": "Mine", "version": "1.0.0",
                 "engines": { "cmux": "^2.0" }, "runtime": { "main": "main.js" }, "description": "x",
                 "implements": { "cmux.section/1": { "export": "renderSection", "title": "Mine", "symbol": "sparkles" } } }"#,
        )],
    );
    let report = check_dir(dir.path(), &options());
    let missing = report.findings.iter().find(|f| f.message.contains("runtime.main"));
    assert!(missing.is_some_and(|f| f.path == "customize/cmux-app.json"), "{:?}", report.findings);
}

#[test]
fn a_missing_header_is_one_error() {
    let dir = tempfile::tempdir().unwrap();
    let report = check_dir(dir.path(), &options());
    assert_eq!(codes_of(&report), [codes::SETUP_UNREADABLE]);
    assert_eq!(report.setup_id, None);
    assert!(!report.ok);
}

#[test]
fn a_settings_history_adds_a_deprecated_warning_and_a_fix() {
    struct Renamed;
    impl SettingsHistory for Renamed {
        fn deprecated(&self, key: &str) -> Option<Deprecated> {
            (key == "appearance.oldDensity").then(|| Deprecated {
                replacement: Some("appearance.density".to_owned()),
                note: "renamed".to_owned(),
            })
        }
    }
    let dir = tempfile::tempdir().unwrap();
    repo(dir.path(), r#"{ "appearance.oldDensity": "compact" }"#, &[]);
    let report = check_dir(dir.path(), &CheckOptions { history: &Renamed, ..options() });
    let deprecated = report.findings.iter().find(|f| f.code == codes::SETTING_DEPRECATED).unwrap();
    assert_eq!(deprecated.severity, Severity::Warning);
    assert_eq!(deprecated.fix.as_deref(), Some("set appearance.density instead"));
    let unknown = report.findings.iter().find(|f| f.code == codes::SETTING_UNKNOWN).unwrap();
    assert_eq!(unknown.fix.as_deref(), Some("set appearance.density instead"));
}

#[test]
fn the_report_has_the_documented_shape() {
    let dir = tempfile::tempdir().unwrap();
    repo(dir.path(), r#"{ "appearance.density": 42 }"#, &[]);
    let value = serde_json::to_value(check_dir(dir.path(), &options())).unwrap();
    assert_eq!(value["schema_version"], 1);
    assert_eq!(value["setup_id"], "leo/night");
    assert_eq!(value["ok"], false);
    let finding = &value["findings"][0];
    assert_eq!(finding["severity"], "error");
    assert_eq!(finding["code"], "setting.value");
    assert_eq!(finding["path"], SETUP_FILE);
    assert_eq!(finding["key"], "appearance.density");
}

#[test]
fn a_retired_key_is_a_deprecated_warning_whose_fix_is_the_row_that_replaced_it() {
    let dir = tempfile::tempdir().unwrap();
    repo(dir.path(), r#"{ "remote.ultraMode": true, "tabs.newTabKind": "terminal" }"#, &[]);
    let report = check_dir(dir.path(), &CheckOptions { history: &RetiredKeys, ..options() });
    let deprecated: Vec<_> =
        report.findings.iter().filter(|f| f.code == codes::SETTING_DEPRECATED).collect();
    assert_eq!(deprecated.len(), 2, "{:?}", report.findings);
    let renamed = deprecated.iter().find(|f| f.key.as_deref() == Some("remote.ultraMode")).unwrap();
    assert_eq!(renamed.severity, Severity::Warning);
    assert_eq!(renamed.fix.as_deref(), Some("set remote.ultra instead"));
    let gone = deprecated.iter().find(|f| f.key.as_deref() == Some("tabs.newTabKind")).unwrap();
    assert_eq!(gone.fix.as_deref(), Some("take tabs.newTabKind out"));
    // Install still refuses a key this cmux does not read; the error says what replaced it.
    let unknown = report
        .findings
        .iter()
        .find(|f| f.code == codes::SETTING_UNKNOWN && f.key.as_deref() == Some("remote.ultraMode"))
        .unwrap();
    assert_eq!(unknown.fix.as_deref(), Some("set remote.ultra instead"));
}
