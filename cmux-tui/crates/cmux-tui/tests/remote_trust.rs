#![cfg(unix)]

use std::path::Path;
use std::process::{Command, Output};

const PEER: &str = "AAAAAAAAAAAAAAAAAAAAAA";

fn trust(state: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["remote", "trust"])
        .args(args)
        .arg("--state-dir")
        .arg(state)
        .env("LC_ALL", "C")
        .env("LC_MESSAGES", "C")
        .env("LANG", "C")
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_MUX_SOCKET")
        .output()
        .unwrap()
}

fn json(output: &Output) -> serde_json::Value {
    assert!(output.status.success(), "{output:?}");
    serde_json::from_slice(&output.stdout).unwrap()
}

#[test]
fn remote_trust_set_list_and_forget_round_trip() {
    let state = tempfile::tempdir().unwrap();
    let project = tempfile::tempdir().unwrap();
    let folder = project.path().to_str().unwrap();

    let set = json(&trust(
        state.path(),
        &["set", PEER, "--tier", "folders", "--folder", folder, "--agent", "claude", "--json"],
    ));
    assert_eq!(set["tier"], "folders", "{set}");

    let listed = json(&trust(state.path(), &["list", "--json"]));
    assert_eq!(listed[0]["fingerprint"], PEER, "{listed}");
    assert_eq!(listed[0]["agents"][0], "claude", "{listed}");
    assert_eq!(
        listed[0]["folders"][0],
        std::fs::canonicalize(project.path()).unwrap().to_str().unwrap(),
        "{listed}"
    );

    assert!(trust(state.path(), &["forget", PEER]).status.success());
    assert_eq!(json(&trust(state.path(), &["list", "--json"])), serde_json::json!([]));
    assert!(!trust(state.path(), &["forget", PEER]).status.success());
}

#[test]
fn remote_trust_refuses_a_grant_without_scope_or_for_the_filesystem_root() {
    let state = tempfile::tempdir().unwrap();

    assert!(!trust(state.path(), &["set", PEER, "--tier", "ask"]).status.success());
    assert!(
        !trust(state.path(), &["set", PEER, "--tier", "ask", "--folder", "/", "--agent", "codex"])
            .status
            .success()
    );
    assert_eq!(json(&trust(state.path(), &["list", "--json"])), serde_json::json!([]));
}

#[test]
fn remote_trust_audit_is_empty_before_any_request() {
    let state = tempfile::tempdir().unwrap();

    assert_eq!(json(&trust(state.path(), &["audit", "--json"])), serde_json::json!([]));
}
