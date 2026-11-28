//! `cmux-shotdiff key` against a real git repository: the key moves with a family's files and with nothing
//! else.

use std::path::{Path, PathBuf};
use std::process::Command;

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("cmux-shotdiff-key-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn git(repo: &Path, args: &[&str]) {
    let out = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"])
        .args(args)
        .output()
        .unwrap();
    assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
}

fn write(repo: &Path, path: &str, text: &str) {
    let p = repo.join(path);
    std::fs::create_dir_all(p.parent().unwrap()).unwrap();
    std::fs::write(p, text).unwrap();
}

fn commit(repo: &Path, msg: &str) {
    git(repo, &["add", "-A"]);
    git(repo, &["commit", "-q", "--allow-empty", "-m", msg]);
}

/// The CLI binary: compile-time on cargo versions that set it then, run-time on ones that set it in the
/// test's environment, else beside the test binary's `deps/` folder.
fn bin() -> PathBuf {
    option_env!("CARGO_BIN_EXE_cmux-shotdiff")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("CARGO_BIN_EXE_cmux-shotdiff").map(PathBuf::from))
        .unwrap_or_else(|| {
            let exe = std::env::current_exe().unwrap();
            exe.parent().unwrap().parent().unwrap().join("cmux-shotdiff")
        })
}

fn key(repo: &Path, extra: &[&str]) -> Result<serde_json::Value, String> {
    let out = Command::new(bin())
        .arg("key")
        .args(["--inputs", "inputs.json", "--family", "gate", "--repo"])
        .arg(repo)
        .args(extra)
        .current_dir(repo)
        .output()
        .unwrap();
    if out.status.success() {
        Ok(serde_json::from_slice(&out.stdout).unwrap())
    } else {
        Err(format!("{:?}: {}", out.status.code(), String::from_utf8_lossy(&out.stderr)))
    }
}

#[test]
fn key_follows_the_family_files() {
    let repo = scratch("follows");
    git(&repo, &["init", "-q"]);
    write(
        &repo,
        "inputs.json",
        r#"{"version": 1, "families": {"gate": {"variants": ["iphone", "ipad"],
            "paths": ["app/**", "!**/*.md", "!app/Tests/**"]}}}"#,
    );
    write(&repo, "app/View.swift", "v1");
    write(&repo, "app/README.md", "doc");
    write(&repo, "app/Tests/ViewTests.swift", "t");
    write(&repo, "other/x.rs", "x");
    commit(&repo, "one");

    let one = key(&repo, &["--variant", "iphone"]).unwrap();
    assert_eq!(one["schema"], "cmux-shotdiff.key/v1");
    assert_eq!(one["files"], 1, "only app/View.swift feeds the key: {one}");
    assert_eq!(one["key"].as_str().unwrap().len(), 64);
    let ipad = key(&repo, &["--variant", "ipad"]).unwrap();
    assert_ne!(one["key"], ipad["key"], "each variant has its own key");

    write(&repo, "app/README.md", "doc 2");
    write(&repo, "app/Tests/ViewTests.swift", "t 2");
    write(&repo, "other/x.rs", "x 2");
    commit(&repo, "outside the family");
    assert_eq!(key(&repo, &["--variant", "iphone"]).unwrap()["key"], one["key"]);

    write(&repo, "app/View.swift", "v2");
    commit(&repo, "inside the family");
    let two = key(&repo, &["--variant", "iphone"]).unwrap();
    assert_ne!(two["key"], one["key"]);
    let back = key(&repo, &["--variant", "iphone", "--rev", "HEAD~1"]).unwrap();
    assert_eq!(back["key"], one["key"], "--rev keys an older tree");

    write(&repo, "app/Run.sh", "x");
    commit(&repo, "a new file");
    assert_ne!(key(&repo, &["--variant", "iphone"]).unwrap()["key"], two["key"]);
    git(&repo, &["update-index", "--chmod=+x", "app/Run.sh"]);
    let before_mode = key(&repo, &["--variant", "iphone"]).unwrap()["key"].clone();
    git(&repo, &["commit", "-q", "-m", "mode change"]);
    assert_ne!(
        key(&repo, &["--variant", "iphone"]).unwrap()["key"],
        before_mode,
        "the mode is in the key"
    );

    assert!(key(&repo, &["--variant", "duo"]).unwrap_err().contains("not in"));
    assert!(key(&repo, &[]).unwrap_err().contains("--variant"));
    let _ = std::fs::remove_dir_all(&repo);
}

#[test]
fn key_refuses_an_empty_family() {
    let repo = scratch("empty");
    git(&repo, &["init", "-q"]);
    write(&repo, "inputs.json", r#"{"families": {"gate": {"paths": ["nothing/**"]}}}"#);
    write(&repo, "app/View.swift", "v1");
    commit(&repo, "one");
    let err = key(&repo, &[]).unwrap_err();
    assert!(err.starts_with("Some(2)") && err.contains("no file matches"), "{err}");
    let _ = std::fs::remove_dir_all(&repo);
}

#[test]
fn desktop_reference_stores() {
    let script = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/desktop_goldens.py");
    let status = Command::new("python3").arg(script).env("CMUX_SHOTDIFF", bin()).status().unwrap();
    assert!(status.success());
}
