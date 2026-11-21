use serde_json::Value;
use std::{path::Path, process::Command};

fn cli() -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-ci-compute-experiment"));
    command.current_dir(
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .unwrap()
            .parent()
            .unwrap(),
    );
    command
}

#[test]
fn disabled_is_successful_without_reading_missing_files() {
    let output = cli()
        .args([
            "--runners",
            "/missing/runners.json",
            "--labels",
            "/missing/labels.json",
        ])
        .output()
        .unwrap();
    assert!(output.status.success());
    let report: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(report["enabled"], false);
    assert!(report.get("pools").is_none());
}

#[test]
fn opt_in_audits_the_real_repository_pool_file() {
    let output = cli().arg("--enable").output().unwrap();
    assert_eq!(
        output.status.code(),
        Some(2),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let report: Value = serde_json::from_slice(&output.stdout).unwrap();
    let rows = report["pools"].as_array().unwrap();
    let status = |name| {
        rows.iter().find(|row| row["pool"] == name).unwrap()["status"]
            .as_str()
            .unwrap()
    };
    assert_eq!(status("linux"), "owned-member-configured");
    assert_eq!(status("linux_arm64"), "missing-owned");
    assert_eq!(status("promotion"), "owned-member-configured");
    assert_eq!(status("provenance"), "hosted-required");
    assert_eq!(report["findings"], 1);
    assert_eq!(report["linux_pools"], 9);
}

#[test]
fn enabled_missing_input_and_unknown_options_fail() {
    for args in [
        vec!["--enable", "--runners", "/missing/runners.json"],
        vec!["--enable", "--typo"],
    ] {
        let output = cli().args(args).output().unwrap();
        assert_eq!(output.status.code(), Some(1));
        assert!(output.stdout.is_empty());
        assert!(!output.stderr.is_empty());
    }
}
