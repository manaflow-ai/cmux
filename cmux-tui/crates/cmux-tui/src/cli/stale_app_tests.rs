use serde_json::json;

use super::*;

fn running(build: &str, version: &str) -> RunningApp {
    RunningApp { build: build.into(), version: Some(version.into()), pid: Some(1) }
}

fn installed(build: &str, version: &str) -> InstalledApp {
    InstalledApp { build: build.into(), version: Some(version.into()) }
}

#[test]
fn an_older_running_app_gets_the_one_line() {
    let line = notice(
        &running("4400000000000", "1.0.0-nightly.4400000000000"),
        &installed("4487759453601", "1.0.0-nightly.4487759453601"),
        Some("2026-11-16"),
    );
    assert_eq!(
        line.as_deref(),
        Some(
            "cmux: the running app is build 1.0.0-nightly.4400000000000 from 2026-11-16; \
             build 1.0.0-nightly.4487759453601 is installed. Restart cmux to use it."
        )
    );
}

#[test]
fn an_unknown_start_date_leaves_out_the_from() {
    let line = notice(&running("100", "100"), &installed("101", "101"), None).unwrap();
    assert_eq!(
        line,
        "cmux: the running app is build 100; build 101 is installed. Restart cmux to use it."
    );
}

#[test]
fn the_same_build_says_nothing() {
    assert_eq!(
        notice(&running("4487759453601", "x"), &installed("4487759453601", "x"), None),
        None
    );
}

#[test]
fn a_running_app_newer_than_this_cli_says_nothing() {
    // The line would claim an installed build the person would then step back to.
    assert_eq!(notice(&running("102", "a"), &installed("101", "b"), Some("2026-11-16")), None);
}

#[test]
fn builds_compare_as_numbers_not_text() {
    assert!(is_newer("1235", "1234"));
    assert!(is_newer("100", "99"));
    assert!(!is_newer("99", "100"));
    assert!(is_newer("1.2.10", "1.2.9"));
    assert!(is_newer("1.0.1", "1.0"));
    assert!(!is_newer("1.0", "1.0.0"));
    assert!(is_newer("99999999999999999999999", "9999999999999999999999"));
    assert!(!is_newer("0100", "100"));
    assert!(is_newer("1.0.0-nightly.4487759453601", "1.0.0-nightly.4400000000000"));
}

#[test]
fn blank_builds_are_never_newer() {
    assert!(!is_newer("", "100"));
    assert!(!is_newer("100", "  "));
    assert!(!is_newer(" 100 ", "100"));
}

#[test]
fn the_apps_identity_names_its_build() {
    let identity =
        json!({"build": "4400000000000", "version": "1.0.0-nightly.4400000000000", "pid": 4242});
    assert_eq!(
        RunningApp::from_identity(&identity),
        Some(RunningApp {
            build: "4400000000000".into(),
            version: Some("1.0.0-nightly.4400000000000".into()),
            pid: Some(4242),
        })
    );
    assert_eq!(RunningApp::from_identity(&json!({"version": "1"})), None);
    assert_eq!(RunningApp::from_identity(&json!({"build": " "})), None);
}

#[test]
fn start_times_read_as_local_dates() {
    // Noon UTC is the same calendar day in every zone within 11 hours of it.
    let date = local_date(1_794_916_800).unwrap();
    assert_eq!(date.len(), 10);
    assert!(date.starts_with("2026-11-1"), "{date}");
}
