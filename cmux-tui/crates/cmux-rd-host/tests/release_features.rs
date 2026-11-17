//! What a released cmux-rd links: the channel build (scripts/build-channel.sh, run by
//! cmux-tui-build-package.yml's Linux legs) and cmux-rd-release.yml build it with
//! `--no-default-features --features openh264,link`, and under those features no crate may be
//! taken only under the GPL, LGPL or AGPL unless it is this repository's own (GPL-3.0-or-later),
//! and no H.264 codec may be compiled in (Cisco's OpenH264 is downloaded by the machine;
//! release_features_compile_in_no_codec reads `cargo tree`, so it needs no extra tool).
//!
//! The crate check runs `cargo license` (cargo-license 0.7) over the release features for both
//! Linux targets and hands its JSON to `scripts/release.py license-gate`. Without cargo-license
//! it skips with a loud message: `cargo install --locked cargo-license@0.7.0` and run again.

use std::path::{Path, PathBuf};
use std::process::Command;

const RELEASE_FEATURES: &str = "openh264,link";
const TARGETS: [&str; 2] = ["x86_64-unknown-linux-gnu", "aarch64-unknown-linux-gnu"];

fn crate_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn cargo() -> String {
    std::env::var("CARGO").unwrap_or_else(|_| "cargo".into())
}

#[test]
fn release_builds_use_the_release_features() {
    let script = std::fs::read_to_string(crate_dir().join("scripts/build-channel.sh")).unwrap();
    assert!(
        script.lines().any(|line| line.trim() == format!("FEATURES={RELEASE_FEATURES}")),
        "scripts/build-channel.sh must build with FEATURES={RELEASE_FEATURES}"
    );
    let workflow = crate_dir().join("../../../.github/workflows/cmux-rd-release.yml");
    if let Ok(text) = std::fs::read_to_string(&workflow) {
        assert!(
            text.lines().any(|line| line.trim() == format!("FEATURES: {RELEASE_FEATURES}")),
            "cmux-rd-release.yml must build with FEATURES: {RELEASE_FEATURES}"
        );
    }
}

#[test]
fn release_features_link_no_gpl_only_crate() {
    let probe = Command::new(cargo()).args(["license", "--version"]).output();
    if !probe.map(|o| o.status.success()).unwrap_or(false) {
        eprintln!(
            "\n\n==== SKIPPED: release_features_link_no_gpl_only_crate ====\n\
             cargo-license is not installed, so the crates of a release cmux-rd were NOT checked.\n\
             Install it (cargo install --locked cargo-license@0.7.0) and run this test again.\n\
             ====\n"
        );
        return;
    }
    let manifest = crate_dir().join("Cargo.toml");
    let scratch =
        std::env::temp_dir().join(format!("cmux-rd-release-features-{}", std::process::id()));
    std::fs::create_dir_all(&scratch).unwrap();
    for target in TARGETS {
        let listed = Command::new(cargo())
            .arg("license")
            .args(["--json", "--avoid-build-deps", "--avoid-dev-deps", "--manifest-path"])
            .arg(&manifest)
            .args([
                "--no-default-features",
                "--features",
                RELEASE_FEATURES,
                "--filter-platform",
                target,
            ])
            .output()
            .expect("run cargo license");
        assert!(
            listed.status.success(),
            "cargo license for {target} failed:\n{}",
            String::from_utf8_lossy(&listed.stderr)
        );
        let crates: Vec<serde_json::Value> =
            serde_json::from_slice(&listed.stdout).expect("cargo license JSON");
        assert!(
            crates.len() > 50,
            "cargo license listed only {} crates for {target}",
            crates.len()
        );
        let names: Vec<&str> = crates.iter().filter_map(|c| c["name"].as_str()).collect();
        assert!(
            names.contains(&"cmux-rd-host"),
            "cargo license for {target} did not list cmux-rd-host"
        );

        let json = scratch.join(format!("{target}.json"));
        std::fs::write(&json, &listed.stdout).unwrap();
        let gate = Command::new("python3")
            .arg(crate_dir().join("scripts/release.py"))
            .args(["license-gate", "--cargo-license"])
            .arg(&json)
            .output()
            .expect("run python3 scripts/release.py license-gate");
        eprintln!("{target}:\n{}", String::from_utf8_lossy(&gate.stdout));
        assert!(
            gate.status.success(),
            "release.py license-gate stops cmux-rd for {target}:\n{}{}",
            String::from_utf8_lossy(&gate.stdout),
            String::from_utf8_lossy(&gate.stderr)
        );
    }
    let _ = std::fs::remove_dir_all(Path::new(&scratch));
}

/// What would compile an H.264 codec into cmux-rd built with `features` for `target`: the
/// `openh264` crate (the bench's decoder), an OpenH264 crate with its `source` feature (Cisco's
/// C++ built in; the release takes openh264-sys2 with `libloading` only), an x264 crate, or
/// cmux-rd-host's own `x264` or `bench` feature (build.rs links libx264 for `x264`).
fn codec_findings(features: &str, target: &str) -> Vec<String> {
    let tree = Command::new(cargo())
        .arg("tree")
        .args(["--locked", "--manifest-path"])
        .arg(crate_dir().join("Cargo.toml"))
        .args(["--no-default-features", "--features", features, "-e", "normal", "--target", target])
        .args(["--prefix", "none", "-f", "{p} [{f}]"])
        .output()
        .expect("run cargo tree");
    assert!(
        tree.status.success(),
        "cargo tree --features {features} for {target} failed:\n{}",
        String::from_utf8_lossy(&tree.stderr)
    );
    let mut findings: Vec<String> = Vec::new();
    for line in String::from_utf8_lossy(&tree.stdout).lines() {
        let name = line.split_whitespace().next().unwrap_or("");
        let enabled: Vec<&str> = line
            .rsplit_once('[')
            .map(|(_, rest)| rest.trim_end_matches(']').split(',').collect())
            .unwrap_or_default();
        let codec = name == "openh264"
            || name.contains("x264")
            || (name.starts_with("openh264") && enabled.contains(&"source"))
            || (name == "cmux-rd-host"
                && (enabled.contains(&"x264") || enabled.contains(&"bench")));
        if codec && !findings.iter().any(|f| f == line) {
            findings.push(line.to_string());
        }
    }
    findings
}

#[test]
fn release_features_compile_in_no_codec() {
    for target in TARGETS {
        let findings = codec_findings(RELEASE_FEATURES, target);
        assert!(
            findings.is_empty(),
            "a release cmux-rd for {target} would compile in an H.264 codec:\n{}",
            findings.join("\n")
        );
        // The same check sees the bench's OpenH264 built from source.
        assert!(
            !codec_findings("bench", target).is_empty(),
            "the codec check found nothing in a bench build for {target}: it reads nothing"
        );
    }
}
