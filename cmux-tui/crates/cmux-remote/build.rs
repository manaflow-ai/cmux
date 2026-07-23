use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

const BUILD_COMMIT_ENV: &str = "CMUX_TUI_BUILD_COMMIT";
const BUILD_IDENTITY_ENV: &str = "CMUX_TUI_BUILD_IDENTITY";

fn main() {
    println!("cargo:rerun-if-env-changed={BUILD_COMMIT_ENV}");

    let manifest_dir =
        PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR is unset"));
    let identity = env::var(BUILD_COMMIT_ENV)
        .ok()
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| source_revision(&manifest_dir));
    if identity.bytes().any(|byte| byte.is_ascii_control()) {
        panic!("{BUILD_COMMIT_ENV} contains a control character");
    }
    println!("cargo:rustc-env={BUILD_IDENTITY_ENV}={identity}");
}

fn source_revision(manifest_dir: &Path) -> String {
    track_git_revision(manifest_dir);
    git(manifest_dir, &["rev-parse", "--verify", "HEAD^{commit}"]).unwrap_or_else(|| {
        panic!(
            "could not determine the cmux-tui source revision; set {BUILD_COMMIT_ENV} when building outside a Git checkout"
        )
    })
}

fn track_git_revision(manifest_dir: &Path) {
    track_git_path(manifest_dir, "HEAD");
    track_git_path(manifest_dir, "packed-refs");
    if let Some(reference) = git(manifest_dir, &["symbolic-ref", "-q", "HEAD"]) {
        track_git_path(manifest_dir, &reference);
    }
}

fn track_git_path(manifest_dir: &Path, path: &str) {
    if let Some(path) = git(manifest_dir, &["rev-parse", "--git-path", path])
        && Path::new(&path).exists()
    {
        println!("cargo:rerun-if-changed={path}");
    }
}

fn git(manifest_dir: &Path, arguments: &[&str]) -> Option<String> {
    let output = Command::new("git").current_dir(manifest_dir).args(arguments).output().ok()?;
    if !output.status.success() {
        return None;
    }
    let value = String::from_utf8(output.stdout).ok()?;
    let value = value.trim();
    (!value.is_empty()).then(|| value.to_owned())
}
