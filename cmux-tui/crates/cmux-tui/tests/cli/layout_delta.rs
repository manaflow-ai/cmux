//! `layout-delta-v1` through a real daemon: a divider drag's
//! `set-split-ratio` comes back on the subscription as one `layout-changed`
//! that carries that screen's new layout and the request's transaction, and
//! no panes, so a frontend patches one screen instead of re-fetching the tree.

use super::*;

#[test]
fn a_split_ratio_commit_emits_its_screen_layout_and_transaction() {
    let server = HeadlessServer::start("layout-delta");
    state_cli(&server, None, &["workspace", "create", "--name", "delta"]);
    let tree = raw_json(&server, serde_json::json!({"id": "tree", "cmd": "list-workspaces"}));
    let pane = tree["workspaces"][0]["screens"][0]["active_pane"].as_u64().expect("a pane");
    raw_json(
        &server,
        serde_json::json!({"id": "split", "cmd": "split", "pane": pane, "dir": "right", "cols": 80, "rows": 24}),
    );
    let tree = raw_json(&server, serde_json::json!({"id": "tree", "cmd": "list-workspaces"}));
    let workspace = &tree["workspaces"][0];
    let screen = &workspace["screens"][0];
    let split = screen["layout"]["split"].as_u64().unwrap_or_else(|| panic!("no split: {screen}"));

    let stream = transport::connect(&server.socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(writer, r#"{{"id":1,"cmd":"subscribe","tree_events":"deltas"}}"#).unwrap();
    writer.flush().unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    assert_eq!(serde_json::from_str::<serde_json::Value>(&line).unwrap()["ok"], true, "{line}");

    let set = serde_json::json!({"id": "ratio", "cmd": "set-split-ratio", "split": split, "ratio": 0.3, "transaction": 4242});
    raw_json(&server, set);
    let event = loop {
        line.clear();
        assert!(reader.read_line(&mut line).unwrap() > 0, "the subscription ended");
        let message: serde_json::Value = serde_json::from_str(&line).unwrap();
        if message["event"] == "layout-changed" {
            break message;
        }
    };
    assert_eq!(event["screen"], screen["id"], "{event}");
    assert_eq!(event["workspace"], workspace["id"], "{event}");
    assert_eq!(event["transaction"], "4242", "the echo names the request's transaction: {event}");
    assert_eq!(event["active_pane"], screen["active_pane"], "{event}");
    assert_eq!(event["layout"]["split"].as_u64(), Some(split), "{event}");
    let ratio = event["layout"]["ratio"].as_f64().unwrap_or_else(|| panic!("no ratio: {event}"));
    assert!((ratio - 0.3).abs() < 1e-6, "the event carries the new ratio: {event}");
    assert!(event.get("panes").is_none(), "a layout delta carries no panes: {event}");
}

/// `split-client-split-id-v1` through a real daemon: the split a `split`
/// makes is named by the client-minted `split_id` in the first
/// `layout-changed` that holds it and in the tree; a split without one gets
/// a daemon-minted id there too; a taken or malformed id is refused and
/// nothing is created. This is what lets the app's optimistic split and the
/// daemon's echo share one id (plans/cmux-next/perf-speed-of-light.md, I3).
#[test]
fn a_split_is_named_by_its_client_minted_split_id() {
    let server = HeadlessServer::start("split-client-id");
    let identify = raw_json(&server, serde_json::json!({"id": "identify", "cmd": "identify"}));
    assert!(
        identify["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|c| c == "split-client-split-id-v1"),
        "{identify}"
    );
    state_cli(&server, None, &["workspace", "create", "--name", "split-ids"]);
    let tree = raw_json(&server, serde_json::json!({"id": "tree", "cmd": "list-workspaces"}));
    let pane = tree["workspaces"][0]["screens"][0]["active_pane"].as_u64().expect("a pane");

    let stream = transport::connect(&server.socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(writer, r#"{{"id":1,"cmd":"subscribe","tree_events":"deltas"}}"#).unwrap();
    writer.flush().unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    assert_eq!(serde_json::from_str::<serde_json::Value>(&line).unwrap()["ok"], true, "{line}");

    let minted = "split_52000000000000000000000000000001";
    raw_json(
        &server,
        serde_json::json!({"id": "split", "cmd": "split", "pane": pane, "dir": "right",
                           "cols": 80, "rows": 24, "split_id": minted}),
    );
    let event = loop {
        line.clear();
        assert!(reader.read_line(&mut line).unwrap() > 0, "the subscription ended");
        let message: serde_json::Value = serde_json::from_str(&line).unwrap();
        if message["event"] == "layout-changed" {
            break message;
        }
    };
    assert_eq!(event["layout"]["type"], "split", "{event}");
    assert_eq!(event["layout"]["split_id"], minted, "the first layout names the split: {event}");

    // A split without split_id is named by the daemon from its first layout on.
    let new_pane = event["active_pane"].as_u64().expect("the new pane is active");
    raw_json(
        &server,
        serde_json::json!({"id": "split2", "cmd": "split", "pane": new_pane, "dir": "down", "cols": 80, "rows": 24}),
    );
    let event = loop {
        line.clear();
        assert!(reader.read_line(&mut line).unwrap() > 0, "the subscription ended");
        let message: serde_json::Value = serde_json::from_str(&line).unwrap();
        if message["event"] == "layout-changed" {
            break message;
        }
    };
    let inner = event["layout"]["b"]["split_id"].as_str().unwrap_or_else(|| panic!("{event}"));
    assert!(inner.starts_with("split_") && inner != minted, "{event}");
    assert_eq!(event["layout"]["split_id"], minted, "the outer split keeps its id: {event}");

    let tree = raw_json(&server, serde_json::json!({"id": "tree", "cmd": "list-workspaces"}));
    let screen = &tree["workspaces"][0]["screens"][0];
    assert_eq!(screen["layout"]["split_id"], minted, "{screen}");
    assert_eq!(screen["layout"]["b"]["split_id"], inner, "{screen}");
    let panes = screen["panes"].as_array().map_or(0, Vec::len);

    // A taken id and a malformed id are refused before anything is created.
    for (n, split_id) in [minted, "split_xyz"].into_iter().enumerate() {
        let output = raw_cli(
            &server,
            serde_json::json!({"id": format!("bad{n}"), "cmd": "split", "pane": pane, "dir": "right",
                               "split_id": split_id}),
        );
        assert!(!output.status.success(), "{split_id} was accepted");
        let error = String::from_utf8_lossy(&output.stderr).to_string();
        let expected = if n == 0 { "split_id_exists" } else { "split_id" };
        assert!(error.contains(expected), "{split_id}: {error}");
    }
    let tree = raw_json(&server, serde_json::json!({"id": "tree", "cmd": "list-workspaces"}));
    assert_eq!(tree["workspaces"][0]["screens"][0]["panes"].as_array().map_or(0, Vec::len), panes);
}
