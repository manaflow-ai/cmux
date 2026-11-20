//! A staged build swaps in only when it runs, is cmux-tui and is newer; the
//! TUI notice names an older session server or a staged build that waits.

use std::os::unix::fs::PermissionsExt;
use std::path::Path;

use cmux_remote::update_need::BuildFacts;
use serde_json::json;

use super::{Outcome, previous_path, promote, staged_path, stale_notice};

fn current() -> BuildFacts {
    BuildFacts {
        commit: Some("a".repeat(40)),
        time: 1_000,
        capabilities: Some(["fs-v1".to_owned()].into_iter().collect()),
    }
}

/// A staged "binary" that answers `remote-probe` with `probe` (exit `status`).
fn stage(binary: &Path, probe: &serde_json::Value, status: i32) -> String {
    let script = format!("#!/bin/sh\nprintf '%s\\n' '{probe}'\nexit {status}\n");
    let staged = staged_path(binary);
    std::fs::write(&staged, &script).unwrap();
    std::fs::set_permissions(&staged, std::fs::Permissions::from_mode(0o644)).unwrap();
    script
}

fn probe(commit: char, time: u64, capabilities: &[&str]) -> serde_json::Value {
    json!({
        "app": "cmux-tui",
        "build_identity": commit.to_string().repeat(40),
        "build_time": time,
        "daemon_capabilities": capabilities,
    })
}

fn binary_in(dir: &tempfile::TempDir) -> std::path::PathBuf {
    let binary = dir.path().join("cmux");
    std::fs::write(&binary, "old build").unwrap();
    binary
}

#[test]
fn a_newer_staged_build_replaces_the_binary_and_keeps_the_old_one() {
    let dir = tempfile::tempdir().unwrap();
    let binary = binary_in(&dir);
    let script = stage(&binary, &probe('b', 2_000, &["fs-v1"]), 0);
    assert_eq!(promote(&binary, &current()), Outcome::Promoted { build: Some("b".repeat(40)) });
    assert_eq!(std::fs::read_to_string(&binary).unwrap(), script);
    assert_eq!(std::fs::read_to_string(previous_path(&binary)).unwrap(), "old build");
    assert!(!staged_path(&binary).exists());
    let mode = std::fs::metadata(&binary).unwrap().permissions().mode();
    assert_eq!(mode & 0o111, 0o111, "the installed build is executable");
}

#[test]
fn a_build_with_more_capabilities_is_newer_even_with_an_earlier_time() {
    let dir = tempfile::tempdir().unwrap();
    let binary = binary_in(&dir);
    stage(&binary, &probe('b', 500, &["fs-v1", "detached-terminals-v1"]), 0);
    assert!(matches!(promote(&binary, &current()), Outcome::Promoted { .. }));
}

#[test]
fn an_older_or_same_staged_build_is_removed_and_never_moves_the_binary_back() {
    for staged in
        [probe('b', 500, &["fs-v1"]), probe('a', 2_000, &["fs-v1"]), probe('b', 2_000, &[])]
    {
        let dir = tempfile::tempdir().unwrap();
        let binary = binary_in(&dir);
        stage(&binary, &staged, 0);
        assert!(
            matches!(promote(&binary, &current()), Outcome::Discarded { .. }),
            "{staged} must not replace the binary"
        );
        assert_eq!(std::fs::read_to_string(&binary).unwrap(), "old build");
        assert!(!staged_path(&binary).exists());
        assert!(!previous_path(&binary).exists());
    }
}

#[test]
fn a_staged_file_that_fails_or_is_not_cmux_tui_is_removed() {
    let mut other = probe('b', 2_000, &["fs-v1"]);
    other["app"] = json!("something-else");
    for (staged, status) in [(probe('b', 2_000, &["fs-v1"]), 3), (other, 0)] {
        let dir = tempfile::tempdir().unwrap();
        let binary = binary_in(&dir);
        stage(&binary, &staged, status);
        assert!(matches!(promote(&binary, &current()), Outcome::Discarded { .. }));
        assert_eq!(std::fs::read_to_string(&binary).unwrap(), "old build");
        assert!(!staged_path(&binary).exists());
    }
}

#[test]
fn no_staged_file_changes_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let binary = binary_in(&dir);
    assert_eq!(promote(&binary, &current()), Outcome::NoStaged);
    assert_eq!(std::fs::read_to_string(&binary).unwrap(), "old build");
}

#[test]
fn the_notice_names_an_older_session_server() {
    let client = current();
    let older = json!({"build_commit": "c".repeat(40), "build_time": 900});
    let notice = stale_notice(&older, &client, false).expect("an older server gets a notice");
    assert!(notice.contains("ccccccc") && notice.contains("aaaaaaa"), "{notice}");
    // A server from before build_time in identify counts as older.
    assert!(stale_notice(&json!({"build_commit": "c".repeat(40)}), &client, false).is_some());
    // The same build or a newer server: nothing to say.
    assert_eq!(stale_notice(&json!({"build_commit": "a".repeat(40)}), &client, false), None);
    let newer = json!({"build_commit": "c".repeat(40), "build_time": 2_000});
    assert_eq!(stale_notice(&newer, &client, false), None);
}

#[test]
fn the_notice_says_when_a_staged_build_waits() {
    let same = json!({"build_commit": "a".repeat(40), "build_time": 1_000});
    let notice = stale_notice(&same, &current(), true).expect("a staged build gets a notice");
    assert_eq!(notice, crate::localization::catalog().update_notice.staged_waiting);
}
