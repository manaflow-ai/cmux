//! `cmux agents` through a real daemon: an action prints its receipt (the
//! result, the idempotency key and a fresh composed snapshot) with exit 0, a
//! usage error exits 2 and an owner's refusal exits 3.

use std::process::Command;

use super::super::*;

#[test]
fn agents_cli_actions_print_a_receipt_and_owner_exit_codes_through_a_real_daemon() {
    let server = HeadlessServer::start("agents-cli-receipt");
    // No app answers here, so the receipt's app source is unavailable.
    let no_app = server.dir.join("no-app.sock");
    let agents = |args: &[&str]| {
        Command::new(bin())
            .args(["--json", "--socket"])
            .arg(&server.socket)
            .arg("--app-socket")
            .arg(&no_app)
            .arg("agents")
            .args(args)
            .env_remove("CMUX_TUI_SOCKET")
            .output()
            .unwrap()
    };

    let created = agents(&["workspace", "create", "--name", "pinned", "--empty"]);
    assert_eq!(created.status.code(), Some(0), "{}", String::from_utf8_lossy(&created.stderr));
    let receipt = json_output(&created);
    assert_eq!(receipt["schema_version"], 1, "{receipt}");
    assert_eq!(receipt["action"], "workspace.create");
    assert!(
        receipt["idempotency_key"].as_str().is_some_and(|key| key.starts_with("mutation_")),
        "{receipt}"
    );
    let state = &receipt["state"];
    assert_eq!(state["schema_version"], 1);
    assert_eq!(state["sources"]["daemon"]["available"], true, "{state}");
    assert_eq!(state["sources"]["app"]["available"], false, "{state}");
    let pinned = state["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|workspace| workspace["name"] == "pinned")
        .unwrap_or_else(|| panic!("the new workspace is in the receipt: {state}"));
    let id = pinned["id"].as_str().unwrap();
    assert!(id.starts_with("ws_"), "{id}");
    assert!(receipt["result"].to_string().contains(id), "the result names {id}: {receipt}");

    let usage = agents(&["terminal", "split", "diagonal"]);
    assert_eq!(usage.status.code(), Some(2));
    assert_eq!(json_error(&usage)["code"], "usage.invalid");

    let missing = agents(&["workspace", "select", "ws_00000000000000000000000000000000"]);
    assert_eq!(missing.status.code(), Some(3), "{}", String::from_utf8_lossy(&missing.stdout));
    let error = json_error(&missing);
    assert!(error["code"].as_str().is_some(), "{error}");
    assert_eq!(error["details"]["state"], "rejected", "{error}");
}
