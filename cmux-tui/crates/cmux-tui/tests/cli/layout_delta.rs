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
