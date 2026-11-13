use std::path::{Path, PathBuf};
use std::process::Command;

use cargo_lock_new_versions::{allowed, base_set, new_versions, parse_lock, Finding};

const BASE_A: &str = include_str!("fixtures/base-a.lock");
const BASE_B: &str = include_str!("fixtures/base-b.lock");
const HEAD_A: &str = include_str!("fixtures/head-a.lock");

fn finding(lock: &str, name: &str, version: &str) -> Finding {
    Finding {
        lock: lock.into(),
        name: name.into(),
        version: version.into(),
    }
}

#[test]
fn parses_packages_and_sources() {
    let pkgs = parse_lock(HEAD_A);
    let names: Vec<_> = pkgs
        .iter()
        .map(|p| (p.name.as_str(), p.version.as_str(), p.source.is_some()))
        .collect();
    assert_eq!(
        names,
        [
            ("app", "0.2.0", false),
            ("libc", "0.2.170", true),
            ("serde", "1.0.201", true),
            ("tiny-git", "0.3.0", true)
        ]
    );
}

#[test]
fn flags_only_versions_absent_from_every_base_lock() {
    let known = base_set([BASE_A, BASE_B]);
    let found = new_versions(&known, &[("a/Cargo.lock".into(), HEAD_A.into())]);
    // libc 0.2.170 is in another base lock: not new. app is a path package: skipped.
    assert_eq!(
        found,
        [
            finding("a/Cargo.lock", "serde", "1.0.201"),
            finding("a/Cargo.lock", "tiny-git", "0.3.0")
        ]
    );
}

#[test]
fn an_unchanged_lock_has_nothing_new() {
    let known = base_set([BASE_A, BASE_B]);
    assert!(new_versions(&known, &[("a/Cargo.lock".into(), BASE_A.into())]).is_empty());
}

#[test]
fn allow_line_needs_a_reason() {
    assert_eq!(
        allowed("Summary\ncargo-lock-new-versions: bumps serde for a CVE\n"),
        Some("bumps serde for a CVE".into())
    );
    assert_eq!(allowed("Cargo-Lock-New-Versions:   \n"), None);
    assert_eq!(allowed("This adds no Cargo-Lock-New-Versions: x"), None);
    assert_eq!(allowed(""), None);
}

fn sh(dir: &Path, args: &[&str]) {
    let st = Command::new("git")
        .args(args)
        .current_dir(dir)
        .status()
        .unwrap();
    assert!(st.success(), "git {args:?}");
}

fn write(dir: &Path, rel: &str, text: &str) {
    let p = dir.join(rel);
    std::fs::create_dir_all(p.parent().unwrap()).unwrap();
    std::fs::write(p, text).unwrap();
}

fn repo() -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "cargo-lock-new-versions-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    sh(&dir, &["init", "-q"]);
    sh(&dir, &["config", "user.email", "t@example.invalid"]);
    sh(&dir, &["config", "user.name", "t"]);
    sh(&dir, &["config", "commit.gpgsign", "false"]);
    write(&dir, "a/Cargo.lock", BASE_A);
    write(&dir, "b/Cargo.lock", BASE_B);
    sh(&dir, &["add", "-A"]);
    sh(&dir, &["commit", "-qm", "base"]);
    sh(&dir, &["tag", "base"]);
    write(&dir, "a/Cargo.lock", HEAD_A);
    sh(&dir, &["commit", "-qam", "head"]);
    dir
}

fn run(dir: &Path, body: &str) -> (i32, String) {
    let out = Command::new(env!("CARGO_BIN_EXE_cargo-lock-new-versions"))
        .args(["--base", "base"])
        .env("PR_BODY", body)
        .current_dir(dir)
        .output()
        .unwrap();
    (
        out.status.code().unwrap(),
        String::from_utf8_lossy(&out.stdout).into_owned(),
    )
}

#[test]
fn binary_fails_a_change_adding_versions_unless_the_body_says_so() {
    let dir = repo();
    let (code, out) = run(&dir, "lock alignment, adds no versions");
    assert_eq!(code, 1, "{out}");
    assert!(
        out.contains("::error file=a/Cargo.lock::serde 1.0.201 is in no base Cargo.lock"),
        "{out}"
    );
    assert!(out.contains("Cargo-Lock-New-Versions: <why>"), "{out}");
    assert!(!out.contains("libc"), "{out}");

    let (code, out) = run(
        &dir,
        "Cargo-Lock-New-Versions: serde 1.0.201 fixes a parse bug",
    );
    assert_eq!(code, 0, "{out}");
    assert!(out.contains("allowed by the pull request body"), "{out}");
    std::fs::remove_dir_all(&dir).unwrap();
}
