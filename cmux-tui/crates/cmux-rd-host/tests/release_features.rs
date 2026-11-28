//! What a released cmux-rd links. The channel build (scripts/build-channel.sh, run by
//! cmux-tui-build-package.yml's Linux legs) and cmux-rd-release.yml build it with
//! `--no-default-features --features openh264,link`. Under those features:
//!
//! - no linked crate may be GPL, LGPL or AGPL only, or declare no license, unless it is this
//!   repository's own (release.py OWN_CRATES, by name and from a path). `release.py
//!   license-gate` judges the crates `cargo metadata` resolves for each Linux target, and
//!   `release.py notices` documents exactly the list that gate passed;
//! - no H.264 codec may be compiled in (Cisco's OpenH264 is downloaded by the machine).
//!
//! Needs only cargo and python3.

use std::collections::BTreeSet;
use std::path::PathBuf;
use std::process::{Command, Output};

const RELEASE_FEATURES: &str = "openh264,link";
const TARGETS: [&str; 2] = ["x86_64-unknown-linux-gnu", "aarch64-unknown-linux-gnu"];

fn crate_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn cargo() -> String {
    std::env::var("CARGO").unwrap_or_else(|_| "cargo".into())
}

fn release_py(args: &[&str]) -> Output {
    Command::new("python3")
        .arg(crate_dir().join("scripts/release.py"))
        .args(args)
        .env("CARGO", cargo())
        .output()
        .expect("run python3 scripts/release.py")
}

fn text(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

/// `name vVERSION` lines as a set.
fn crate_set(lines: &str) -> BTreeSet<String> {
    lines
        .lines()
        .filter_map(|line| {
            let mut parts = line.split_whitespace();
            Some(format!("{} {}", parts.next()?, parts.next()?))
        })
        .collect()
}

#[test]
fn release_builds_use_the_release_features() {
    let script = std::fs::read_to_string(crate_dir().join("scripts/build-channel.sh")).unwrap();
    assert!(
        script.lines().any(|line| line.trim() == format!("FEATURES={RELEASE_FEATURES}")),
        "scripts/build-channel.sh must build with FEATURES={RELEASE_FEATURES}"
    );
    let release = std::fs::read_to_string(crate_dir().join("scripts/release.py")).unwrap();
    assert!(
        release
            .lines()
            .any(|line| line.trim() == format!("RELEASE_FEATURES = \"{RELEASE_FEATURES}\"")),
        "scripts/release.py must judge RELEASE_FEATURES = \"{RELEASE_FEATURES}\""
    );
    let workflow = crate_dir().join("../../../.github/workflows/cmux-rd-release.yml");
    if let Ok(text) = std::fs::read_to_string(&workflow) {
        assert!(
            text.lines().any(|line| line.trim() == format!("FEATURES: {RELEASE_FEATURES}")),
            "cmux-rd-release.yml must build with FEATURES: {RELEASE_FEATURES}"
        );
    }
}

/// The channel binary ships without DWARF (32.8 MB to 6.0 MB on x86_64, CMUX-570) and keeps
/// its symbol table; the release profile's `debug = 1` stays for cmux-rd-release.yml.
#[test]
fn channel_build_drops_debuginfo() {
    let script = std::fs::read_to_string(crate_dir().join("scripts/build-channel.sh")).unwrap();
    assert!(
        script
            .lines()
            .any(|line| line.trim_start().starts_with("CARGO_PROFILE_RELEASE_STRIP=debuginfo ")
                && line.contains("cargo zigbuild")),
        "scripts/build-channel.sh must build with CARGO_PROFILE_RELEASE_STRIP=debuginfo"
    );
}

#[test]
fn release_crates_pass_the_license_gate() {
    for target in TARGETS {
        let gate = release_py(&["license-gate", "--target", target]);
        eprintln!("{target}:\n{}{}", text(&gate.stdout), text(&gate.stderr));
        assert!(
            gate.status.success(),
            "release.py license-gate stops cmux-rd for {target}:\n{}{}",
            text(&gate.stdout),
            text(&gate.stderr)
        );
    }
}

/// The notices document exactly the crates the gate judged, and those cover every crate
/// `cargo tree` says the binary links: the gate and the notices cannot drift apart, and
/// neither can miss a linked crate.
#[test]
fn notices_and_gate_read_one_crate_list_that_covers_cargo_tree() {
    for target in TARGETS {
        let gated = release_py(&["crates", "--target", target]);
        assert!(gated.status.success(), "release.py crates for {target}:\n{}", text(&gated.stderr));
        let noticed = release_py(&["notices", "--list", "--target", target]);
        assert!(
            noticed.status.success(),
            "release.py notices --list for {target}:\n{}",
            text(&noticed.stderr)
        );
        let gated = crate_set(&text(&gated.stdout));
        assert!(
            gated.len() > 50,
            "release.py crates listed only {} crates for {target}",
            gated.len()
        );
        assert_eq!(
            gated,
            crate_set(&text(&noticed.stdout)),
            "the notices for {target} document other crates than the gate judged"
        );

        let tree = Command::new(cargo())
            .arg("tree")
            .args(["--locked", "--manifest-path"])
            .arg(crate_dir().join("Cargo.toml"))
            .args(["--no-default-features", "--features", RELEASE_FEATURES])
            .args([
                "-e",
                "normal,no-proc-macro",
                "--target",
                target,
                "--prefix",
                "none",
                "-f",
                "{p}",
            ])
            .output()
            .expect("run cargo tree");
        assert!(tree.status.success(), "cargo tree for {target}:\n{}", text(&tree.stderr));
        let linked = crate_set(&text(&tree.stdout));
        let missed: Vec<&String> = linked.difference(&gated).collect();
        assert!(
            missed.is_empty(),
            "cargo tree links crates for {target} that the gate and notices miss: {missed:?}"
        );
    }
}

/// One dependency edge: (name, license, source, dep kind).
type Dep<'a> = (&'a str, Option<&'a str>, Option<&'a str>, Option<&'a str>);

/// A fabricated `cargo metadata`: cmux-rd-host, from a path, and `deps`, each
/// (name, license, source, dep kind) one edge from the root.
fn fabricated_metadata(deps: &[Dep]) -> String {
    let id = |name: &str| format!("{name} 1.0.0");
    let mut packages = vec![serde_json::json!({
        "id": id("cmux-rd-host"), "name": "cmux-rd-host", "version": "1.0.0",
        "license": "GPL-3.0-or-later", "source": null, "targets": [{"kind": ["lib"]}],
    })];
    let mut edges = Vec::new();
    let mut nodes = Vec::new();
    for (name, license, source, kind) in deps {
        packages.push(serde_json::json!({
            "id": id(name), "name": name, "version": "1.0.0", "license": license,
            "source": source, "targets": [{"kind": ["lib"]}],
        }));
        edges.push(serde_json::json!({
            "name": name, "pkg": id(name), "dep_kinds": [{"kind": kind, "target": null}],
        }));
        nodes.push(serde_json::json!({"id": id(name), "deps": [], "features": []}));
    }
    nodes.push(serde_json::json!({"id": id("cmux-rd-host"), "deps": edges, "features": []}));
    serde_json::json!({
        "packages": packages,
        "resolve": {"root": id("cmux-rd-host"), "nodes": nodes},
    })
    .to_string()
}

fn gate_on(name: &str, deps: &[Dep]) -> Output {
    let dir =
        std::env::temp_dir().join(format!("cmux-rd-license-gate-{}-{name}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("metadata.json");
    std::fs::write(&file, fabricated_metadata(deps)).unwrap();
    let out = release_py(&["license-gate", "--metadata", file.to_str().unwrap()]);
    let _ = std::fs::remove_dir_all(&dir);
    out
}

const REGISTRY: Option<&str> = Some("registry+https://github.com/rust-lang/crates.io-index");

#[test]
fn the_license_gate_stops_a_third_party_gpl_or_unlicensed_crate() {
    for (case, deps) in [
        ("gpl", vec![("gpl-thing", Some("GPL-2.0-only"), REGISTRY, None)]),
        ("lgpl", vec![("lgpl-thing", Some("LGPL-2.1-or-later"), REGISTRY, None)]),
        ("agpl-and-mit", vec![("agpl-thing", Some("MIT AND AGPL-3.0"), REGISTRY, None)]),
        ("no-license", vec![("bare-thing", None, REGISTRY, None)]),
        // An own crate's name from a registry is not our crate.
        (
            "own-name-from-registry",
            vec![("cmux-rd-core", Some("GPL-3.0-or-later"), REGISTRY, None)],
        ),
        (
            "device-kind-from-registry",
            vec![("cmux-device-kind", Some("GPL-3.0-or-later"), REGISTRY, None)],
        ),
    ] {
        let out = gate_on(case, &deps);
        assert!(!out.status.success(), "{case}: the gate passed:\n{}", text(&out.stdout));
        assert!(text(&out.stdout).contains("STOP"), "{case}: no STOP row:\n{}", text(&out.stdout));
    }
}

#[test]
fn the_license_gate_passes_own_permissive_and_unlinked_crates() {
    let deps = [
        ("cmux-rd-core", Some("GPL-3.0-or-later"), None, None),
        ("cmux-device-kind", Some("GPL-3.0-or-later"), None, None),
        ("serde", Some("MIT OR Apache-2.0"), REGISTRY, None),
        ("either-thing", Some("GPL-3.0-or-later OR MIT"), REGISTRY, None),
        ("mpl-thing", Some("MPL-2.0"), REGISTRY, None),
        // Not linked: a dev-only and a build-only dependency.
        ("gpl-test-helper", Some("GPL-3.0-only"), REGISTRY, Some("dev")),
        ("gpl-build-helper", Some("GPL-3.0-only"), REGISTRY, Some("build")),
    ];
    let out = gate_on("pass", &deps);
    assert!(out.status.success(), "the gate stopped:\n{}{}", text(&out.stdout), text(&out.stderr));
    let report = text(&out.stdout);
    assert!(report.contains("| mpl-thing | 1.0.0 | MPL-2.0 | listed, no stop"), "{report}");
    assert!(
        !report.contains("gpl-test-helper") && !report.contains("gpl-build-helper"),
        "{report}"
    );
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
        text(&tree.stderr)
    );
    let mut findings: Vec<String> = Vec::new();
    for line in text(&tree.stdout).lines() {
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
