use std::fs;

use super::store::{apply, load_state, principals};
use super::test_support::{ca_line, krl, snapshot};
use super::trust::{STALE_AFTER_SECS, TrustState};
use super::{CA_FILE, KRL_FILE, PRINCIPALS_DIR, TRUST_FILE};
use crate::config::Paths;

fn root() -> (tempfile::TempDir, Paths) {
    let dir = tempfile::tempdir().expect("tempdir");
    let paths = Paths::new(dir.path());
    (dir, paths)
}

fn read(paths: &Paths, file: &str) -> Vec<u8> {
    fs::read(paths.at(file)).expect("read")
}

#[test]
fn apply_writes_the_krl_ca_keys_and_state_that_sshd_reads() {
    let (_dir, paths) = root();
    let applied = apply(&paths, &snapshot(3, 1), 1_000).expect("apply");
    assert!(applied.krl_changed);
    assert_eq!(read(&paths, KRL_FILE), krl(3));
    assert_eq!(String::from_utf8(read(&paths, CA_FILE)).expect("utf8"), format!("{}\n", ca_line(1)));
    assert_eq!(load_state(&paths), Some(TrustState { krl_version: 3, generation: 1, synced_at: 1_000 }));
}

#[test]
fn a_newer_krl_replaces_the_old_one_in_place() {
    let (_dir, paths) = root();
    apply(&paths, &snapshot(3, 1), 1_000).expect("apply");
    let applied = apply(&paths, &snapshot(4, 1), 1_010).expect("apply newer");
    assert!(applied.krl_changed);
    assert_eq!(read(&paths, KRL_FILE), krl(4));
    let refresh = apply(&paths, &snapshot(4, 1), 1_020).expect("refresh");
    assert!(!refresh.krl_changed, "same version is a refresh");
    assert_eq!(load_state(&paths).map(|s| s.synced_at), Some(1_020));
}

#[test]
fn an_older_snapshot_is_refused_and_changes_no_file() {
    let (_dir, paths) = root();
    apply(&paths, &snapshot(5, 2), 1_000).expect("apply");
    let before = (read(&paths, KRL_FILE), read(&paths, CA_FILE), read(&paths, TRUST_FILE));
    assert!(apply(&paths, &snapshot(4, 2), 1_050).is_err(), "older KRL");
    assert!(apply(&paths, &snapshot(6, 1), 1_050).is_err(), "older CA generation");
    let after = (read(&paths, KRL_FILE), read(&paths, CA_FILE), read(&paths, TRUST_FILE));
    assert_eq!(before, after);
}

#[test]
fn a_machine_that_only_gets_old_snapshots_refuses_new_logins_after_the_bound() {
    let (_dir, paths) = root();
    fs::create_dir_all(paths.at(PRINCIPALS_DIR)).expect("dir");
    fs::write(paths.at(PRINCIPALS_DIR).join("cmux"), "alice\n").expect("principals");
    assert_eq!(principals(&paths, "cmux", 1_000), "", "nothing applied yet");
    apply(&paths, &snapshot(5, 1), 1_000).expect("apply");
    assert_eq!(principals(&paths, "cmux", 1_000 + STALE_AFTER_SECS), "alice\n");
    // A replayed older snapshot does not refresh the sync time.
    assert!(apply(&paths, &snapshot(4, 1), 1_100).is_err());
    assert_eq!(principals(&paths, "cmux", 1_000 + STALE_AFTER_SECS + 1), "");
    // The next good sync opens logins again.
    apply(&paths, &snapshot(6, 1), 1_200).expect("apply");
    assert_eq!(principals(&paths, "cmux", 1_200), "alice\n");
    assert_eq!(principals(&paths, "../cmux", 1_200), "", "no path traversal");
}

#[test]
fn a_corrupt_state_file_fails_closed() {
    let (_dir, paths) = root();
    fs::create_dir_all(paths.at(PRINCIPALS_DIR)).expect("dir");
    fs::write(paths.at(PRINCIPALS_DIR).join("cmux"), "alice\n").expect("principals");
    apply(&paths, &snapshot(5, 1), 1_000).expect("apply");
    fs::write(paths.at(TRUST_FILE), "{not json").expect("corrupt");
    assert_eq!(principals(&paths, "cmux", 1_000), "");
}
