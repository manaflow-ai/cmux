//! `split-client-keys-v1` over the daemon socket (plans/cmux-next/remote-state-ownership.md S1):
//! `split`, `new-pane` and `new-pane-right` take client-minted `pane_id` and `tab_id`. A retry of
//! the same request returns the first result, the same id with another request is refused, an id
//! that exists is refused, a malformed id is refused before anything is created, and a retry
//! with the same `terminal_id` returns the first split.

use super::super::*;

fn id(prefix: &str, n: u64) -> String {
    format!("{prefix}{:032x}", 0x5100_0000_0000_0000_0000_0000_0000_0000u128 + u128::from(n))
}

fn terminal(n: u64) -> String {
    format!("51000000000040008000{n:012x}")
}

fn pane_count(harness: &RecoveryHarness) -> usize {
    let tree = request(&harness.socket, serde_json::json!({"id": 900, "cmd": "list-workspaces"}));
    tree["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|w| w["screens"].as_array().cloned().unwrap_or_default())
        .map(|s| s["panes"].as_array().map_or(0, Vec::len))
        .sum()
}

fn first_pane(harness: &RecoveryHarness) -> u64 {
    run_cat_workspace(&harness.socket, 1, "split-keys");
    let tree = request(&harness.socket, serde_json::json!({"id": 2, "cmd": "list-workspaces"}));
    tree["workspaces"][0]["screens"][0]["panes"][0]["id"].as_u64().unwrap()
}

fn error_text(response: &serde_json::Value) -> String {
    assert_eq!(response["ok"], false, "request succeeded: {response}");
    format!("{} {}", response["error"], response["error_code"])
}

#[test]
fn split_client_keys_over_the_socket() {
    let harness = RecoveryHarness::start("split-client-keys");
    let identify = request(&harness.socket, serde_json::json!({"id": 1, "cmd": "identify"}));
    assert!(
        identify["capabilities"].as_array().unwrap().iter().any(|c| c == "split-client-keys-v1"),
        "{identify}"
    );
    let pane = first_pane(&harness);

    // The ids the client minted are the new pane's and tab's.
    for (n, mut command) in [
        serde_json::json!({"cmd": "split", "pane": pane, "dir": "right"}),
        serde_json::json!({"cmd": "new-pane", "pane": pane}),
        serde_json::json!({"cmd": "new-pane-right", "pane": pane, "width": 0.5}),
    ]
    .into_iter()
    .enumerate()
    {
        let n = n as u64;
        command["id"] = serde_json::json!(10 + n);
        command["pane_id"] = serde_json::json!(id("pane_", n));
        command["tab_id"] = serde_json::json!(id("tab_", n));
        command["terminal_id"] = serde_json::json!(terminal(n));
        let created = request(&harness.socket, command.clone());
        assert_eq!(created["pane_id"], serde_json::json!(id("pane_", n)), "{command} -> {created}");
        assert_eq!(created["tab_id"], serde_json::json!(id("tab_", n)), "{command} -> {created}");
    }

    // A retry of the same request returns the first split and creates nothing.
    let keyed = serde_json::json!({
        "id": 20, "cmd": "split", "pane": pane, "dir": "down",
        "pane_id": id("pane_", 5), "tab_id": id("tab_", 5), "terminal_id": terminal(5),
    });
    let first = request(&harness.socket, keyed.clone());
    let panes = pane_count(&harness);
    let retry = request(&harness.socket, keyed);
    assert_eq!(retry["surface"], first["surface"], "{retry}");
    assert_eq!(retry["replayed"], serde_json::json!(true), "{retry}");
    assert_eq!(pane_count(&harness), panes);

    // The same pane id with another request is refused.
    let conflict = request_response(
        &harness.socket,
        serde_json::json!({"id": 21, "cmd": "split", "pane": pane, "dir": "right", "pane_id": id("pane_", 5)}),
    );
    assert!(error_text(&conflict).contains("creation.conflict"), "{conflict}");

    // An existing pane id and an existing tab id are refused.
    let existing = request(&harness.socket, serde_json::json!({"id": 22, "cmd": "list-workspaces"}))
        ["workspaces"][0]["screens"][0]["panes"][0]["resource_id"]
        .as_str()
        .unwrap()
        .to_string();
    let taken = request_response(
        &harness.socket,
        serde_json::json!({"id": 23, "cmd": "split", "pane": pane, "dir": "right", "pane_id": existing}),
    );
    assert!(error_text(&taken).contains("pane_id_exists"), "{taken}");
    let taken_tab = request_response(
        &harness.socket,
        serde_json::json!({"id": 24, "cmd": "split", "pane": pane, "dir": "right", "tab_id": id("tab_", 5)}),
    );
    assert!(error_text(&taken_tab).contains("tab_id_exists"), "{taken_tab}");

    // A malformed id is refused before anything is created.
    let panes = pane_count(&harness);
    for (n, (field, value)) in
        [("pane_id", "pane_xyz"), ("tab_id", "pane_00000000000000000000000000000001")].into_iter().enumerate()
    {
        let mut command = serde_json::json!({"id": 30 + n, "cmd": "split", "pane": pane, "dir": "right"});
        command[field] = serde_json::json!(value);
        let refused = request_response(&harness.socket, command);
        assert!(error_text(&refused).contains("bad request"), "{field}: {refused}");
    }
    assert_eq!(pane_count(&harness), panes);

    // A retry with the same terminal id and no pane id returns the first split.
    let by_terminal =
        serde_json::json!({"id": 40, "cmd": "split", "pane": pane, "dir": "right", "terminal_id": terminal(7)});
    let first = request(&harness.socket, by_terminal.clone());
    let retry = request(&harness.socket, by_terminal);
    assert_eq!(retry["surface"], first["surface"], "{retry}");
    assert_eq!(retry["replayed"], serde_json::json!(true), "{retry}");
}
