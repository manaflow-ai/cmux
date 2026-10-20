//! Tester rollout (plans/cmux-next/tui-tester-rollout.md): `cmux --version`
//! names the npm/PyPI release a tester installed, not the crate's internal
//! 0.1.0, and `cmux --version --json` gives a bug report every fact a
//! version-skew triage needs in one paste.
//!
//! The published 0.13.4 binary printed `cmux 0.1.0 (...)`, so no tester
//! report could say which release it came from.

#![cfg(unix)]

use std::process::Command;

fn bin() -> &'static str {
    env!("CARGO_BIN_EXE_cmux-tui")
}

fn probe() -> serde_json::Value {
    let output = Command::new(bin()).args(["remote-probe", "--json"]).output().unwrap();
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    serde_json::from_slice(&output.stdout).unwrap()
}

#[test]
fn version_names_the_distribution_release() {
    let probe = probe();
    let distribution = probe["distribution_version"].as_str().unwrap();
    let output = Command::new(bin()).arg("--version").output().unwrap();
    assert!(output.status.success());
    let text = String::from_utf8(output.stdout).unwrap();
    let first = text.lines().next().unwrap_or_default();
    assert!(
        first == format!("cmux {distribution}") || first.starts_with(&format!("cmux {distribution} (")),
        "--version must name the distribution release {distribution}: {first:?}"
    );
}

#[test]
fn version_json_reports_the_rollout_facts() {
    let probe = probe();
    let output = Command::new(bin()).args(["--version", "--json"]).output().unwrap();
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    let report: serde_json::Value = serde_json::from_slice(&output.stdout)
        .unwrap_or_else(|error| panic!("--version --json must print JSON ({error}): {:?}", String::from_utf8_lossy(&output.stdout)));
    assert_eq!(report["app"], "cmux-tui", "{report}");
    assert_eq!(report["version"], probe["distribution_version"], "{report}");
    assert_eq!(report["build_identity"], probe["build_identity"], "{report}");
    assert_eq!(report["build_time"], probe["build_time"], "{report}");
    assert_eq!(report["remote_protocol"], probe["remote_protocol"], "{report}");
    assert_eq!(
        report["protocol"].as_u64(),
        Some(u64::from(cmux_tui_core::server::PROTOCOL_VERSION)),
        "{report}"
    );
    assert_eq!(report["os"], std::env::consts::OS, "{report}");
    assert_eq!(report["arch"], std::env::consts::ARCH, "{report}");
    assert!(report["crate_version"].is_string(), "{report}");
    // A test binary under target/ came from no package manager: nothing to update through.
    assert_eq!(report["install"], "other", "{report}");
    assert!(report["update_command"].is_null(), "{report}");
}
