//! A source the scan cannot read fails the scan and names the path (#41523 F1): a directory,
//! file, Cargo.toml or nextest config it could not read never reads as a clean scan. Each row runs
//! the binary, so it judges what CI and a person running the check by hand see: exit 2 and the
//! path on stderr, where a skipped source used to give exit 0.
//!
//! The rows take read permission away (mode 000). Root reads anything, so when the OS still lets
//! this process read a mode-000 path, a row says why on stderr and checks nothing.

#![cfg(unix)]

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};

const BIN: &str = env!("CARGO_BIN_EXE_cmux-source-scan");

/// A scratch tree under the temp dir; on drop it gives back the permissions it took and is
/// removed.
struct Tree {
    root: PathBuf,
    locked: Vec<PathBuf>,
}

impl Tree {
    fn new(name: &str) -> Tree {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let n = NEXT.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir()
            .join(format!("cmux-source-scan-unreadable-{name}-{}-{n}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).expect("make the tree");
        Tree { root, locked: Vec::new() }
    }

    fn write(&self, rel: &str, text: &str) {
        let path = self.root.join(rel);
        std::fs::create_dir_all(path.parent().expect("a parent")).expect("make the dir");
        std::fs::write(path, text).expect("write");
    }

    /// Takes every permission from `rel`. False, after saying why on stderr, when this process
    /// can still read it (root, or CAP_DAC_READ_SEARCH): the row then has nothing to check.
    fn lock(&mut self, rel: &str) -> bool {
        let path = self.root.join(rel);
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o000)).expect("chmod 000");
        self.locked.push(path.clone());
        let still_readable = if path.is_dir() {
            std::fs::read_dir(&path).is_ok()
        } else {
            std::fs::File::open(&path).is_ok()
        };
        if still_readable {
            eprintln!(
                "skipped: {} is mode 000 and still readable here (uid {}): this process reads anything, as root does, so no read can fail",
                path.display(),
                uid()
            );
        }
        !still_readable
    }
}

impl Drop for Tree {
    fn drop(&mut self) {
        for path in self.locked.iter().rev() {
            let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755));
        }
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

/// This process's real uid, from /proc where there is one.
fn uid() -> String {
    std::fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|s| {
            s.lines().find_map(|l| {
                l.strip_prefix("Uid:")
                    .map(|u| u.split_whitespace().next().unwrap_or("?").to_string())
            })
        })
        .unwrap_or_else(|| "unknown".to_string())
}

/// Runs the binary; asserts it exits 2 and that stderr names `names` (a path's tail, so the
/// row holds whether or not the temp dir is canonical).
fn assert_fails_naming(args: &[&Path], names: &str) {
    let out = Command::new(BIN).args(args).output().expect("run cmux-source-scan");
    let stdout = String::from_utf8_lossy(&out.stdout);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        out.status.code() == Some(2) && stderr.contains(names),
        "want exit 2 naming {names}; got {:?}\nstdout:\n{stdout}\nstderr:\n{stderr}",
        out.status.code()
    );
}

/// A checkout with crate `demo` (a Cargo.toml and src/lib.rs) that scans clean.
fn checkout(name: &str) -> Tree {
    let tree = Tree::new(name);
    tree.write(
        "cmux-tui/crates/demo/Cargo.toml",
        "[package]\nname = \"demo\"\nversion = \"0.1.0\"\n",
    );
    tree.write("cmux-tui/crates/demo/src/lib.rs", "pub fn work() {}\n");
    tree
}

/// An acpmux-shaped crate whose src/lib.rs holds no test hook.
fn crate_dir(name: &str) -> Tree {
    let tree = Tree::new(name);
    tree.write("src/lib.rs", "pub fn work() {}\n");
    tree
}

#[test]
fn the_clean_trees_scan_clean() {
    let co = checkout("clean");
    let out = Command::new(BIN)
        .args([Path::new("timing-ratio"), &co.root])
        .output()
        .expect("run cmux-source-scan");
    assert_eq!(out.status.code(), Some(0), "{}", String::from_utf8_lossy(&out.stderr));
    let krate = crate_dir("clean");
    let out = Command::new(BIN)
        .args([Path::new("test-hooks"), &krate.root])
        .output()
        .expect("run cmux-source-scan");
    assert_eq!(out.status.code(), Some(0), "{}", String::from_utf8_lossy(&out.stderr));
}

#[test]
fn timing_ratio_an_unreadable_dir_fails_naming_it() {
    let mut co = checkout("tr-dir");
    co.write("cmux-tui/crates/demo/src/locked/inner.rs", "pub fn hidden() {}\n");
    if !co.lock("cmux-tui/crates/demo/src/locked") {
        return;
    }
    assert_fails_naming(&[Path::new("timing-ratio"), &co.root], "demo/src/locked");
}

#[test]
fn timing_ratio_an_unreadable_file_fails_naming_it() {
    let mut co = checkout("tr-file");
    co.write("cmux-tui/crates/demo/src/secret.rs", "pub fn hidden() {}\n");
    if !co.lock("cmux-tui/crates/demo/src/secret.rs") {
        return;
    }
    assert_fails_naming(&[Path::new("timing-ratio"), &co.root], "demo/src/secret.rs");
}

#[test]
fn timing_ratio_an_unreadable_cargo_toml_fails_naming_it() {
    let mut co = checkout("tr-cargo");
    if !co.lock("cmux-tui/crates/demo/Cargo.toml") {
        return;
    }
    assert_fails_naming(&[Path::new("timing-ratio"), &co.root], "demo/Cargo.toml");
}

#[test]
fn timing_ratio_an_unreadable_nextest_config_fails_naming_it() {
    // Lock the file, not `.config`: a locked directory fails the source walk first, naming `.config` alone
    // (cmux#42109 review F1). A locked file still stats, so this reaches the config read.
    let mut co = checkout("tr-nextest");
    co.write("cmux-tui/.config/nextest.toml", "[profile.default]\n");
    if !co.lock("cmux-tui/.config/nextest.toml") {
        return;
    }
    assert_fails_naming(&[Path::new("timing-ratio"), &co.root], ".config/nextest.toml");
}

#[test]
fn test_hooks_an_unreadable_dir_fails_naming_it() {
    let mut krate = crate_dir("th-dir");
    krate.write("src/locked/mod.rs", "pub fn hidden() {}\n");
    if !krate.lock("src/locked") {
        return;
    }
    assert_fails_naming(&[Path::new("test-hooks"), &krate.root], "src/locked");
}

#[test]
fn test_hooks_an_unreadable_file_fails_naming_it() {
    let mut krate = crate_dir("th-file");
    krate.write("src/secret.rs", "pub fn hidden() {}\n");
    if !krate.lock("src/secret.rs") {
        return;
    }
    assert_fails_naming(&[Path::new("test-hooks"), &krate.root], "src/secret.rs");
}

/// No `src` at all is no scan, not a clean one. Needs no permission taken, so root runs it too.
#[test]
fn test_hooks_a_crate_without_src_fails_naming_it() {
    let krate = Tree::new("th-nosrc");
    assert_fails_naming(&[Path::new("test-hooks"), &krate.root], "th-nosrc");
}
