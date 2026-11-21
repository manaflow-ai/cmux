//! `cmux carrier key --public` of a build with no Team ID (this test binary
//! is ad-hoc signed by the linker, as a tagged DEV build's helper is): the
//! key lasts in the build's 0600 file, the same on every run, with no
//! Keychain call (a Keychain read here would raise an access prompt).
#![cfg(target_os = "macos")]

use std::os::unix::fs::MetadataExt as _;
use std::path::Path;
use std::process::Command;

const BIN: &str = env!("CARGO_BIN_EXE_cmux-tui");

fn key_public(home: &Path) -> String {
    // A Keychain read here would ask to approve the item (and, with prompts off, fail): this run
    // must succeed without one. nextest's slow-timeout ends a run that blocks.
    let out = Command::new(BIN)
        .args(["carrier", "key", "--public"])
        .env_clear()
        .env("HOME", home)
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(0), "{}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8(out.stdout).unwrap()
}

#[test]
fn an_ad_hoc_build_keeps_its_carrier_key_in_its_own_file() {
    let home = tempfile::tempdir().unwrap();
    let first = key_public(home.path());
    assert_eq!(first.trim_end().len(), 43, "{first:?}");
    assert_eq!(key_public(home.path()), first, "the key lasts across runs");
    let builds = home.path().join("Library/Application Support/cmux-next/builds");
    let file = builds.join("unbundled/carrier/noise-key");
    let meta = std::fs::symlink_metadata(&file).unwrap();
    assert!(meta.is_file());
    assert_eq!(meta.mode() & 0o777, 0o600);
    assert_eq!(meta.len(), 32);
    let folder = std::fs::symlink_metadata(file.parent().unwrap()).unwrap();
    assert_eq!(folder.mode() & 0o777, 0o700);
    // Another home is another key: nothing outside the build's folder held it.
    let other = tempfile::tempdir().unwrap();
    assert_ne!(key_public(other.path()), first);
}
