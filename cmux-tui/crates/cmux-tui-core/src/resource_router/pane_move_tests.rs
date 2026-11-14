//! `pane.move` (W5-P): one daemon operation moves a whole pane, every tab in
//! order, in one journaled commit. The pane keeps its id when it goes beside
//! another pane or to a new screen (in its workspace or another); its tabs
//! keep their ids when they merge into another pane. The focus stays where
//! it is (W4-J), unless `focus: true` or the moved pane had it. A retry
//! with the same idempotency key replays the result and moves nothing again.
//! Before, the CLI sent one `tab.move` per tab, and the pane got a new id.

use serde_json::{Value, json};

use super::*;
use crate::SurfaceOptions;
use crate::resource_api::public_session_snapshot;

fn request(mux: &Arc<Mux>, operation: &str, fields: Value, key: Option<&str>) -> Value {
    let mut params = json!({"machine":"current","session":"current"});
    params.as_object_mut().unwrap().extend(fields.as_object().unwrap().clone());
    let mut envelope = json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":format!("pane-move-{operation}"),
        "operation":operation,
        "params":params,
    });
    if let Some(key) = key {
        envelope["idempotency_key"] = json!(key);
    }
    handle_resource_message(mux, &serde_json::to_string(&envelope).unwrap())
        .unwrap_or_else(|error| panic!("{operation} failed: {error:?}"))
}

fn send(mux: &Arc<Mux>, operation: &str, fields: Value, key: Option<&str>) -> Value {
    let response = request(mux, operation, fields, key);
    assert_eq!(response["ok"], true, "{operation} failed: {response}");
    response["result"].clone()
}

/// `pane.move`'s result value.
fn move_pane(mux: &Arc<Mux>, fields: Value, key: &str) -> Value {
    send(mux, "pane.move", fields, Some(key))["value"].clone()
}

fn mux() -> Arc<Mux> {
    Mux::new_for_test("pane-move", SurfaceOptions::default())
}

fn snapshot(mux: &Arc<Mux>) -> Value {
    public_session_snapshot(mux).unwrap()
}

fn rows<'a>(snapshot: &'a Value, key: &str) -> &'a [Value] {
    snapshot[key].as_array().map(Vec::as_slice).unwrap_or_default()
}

/// A focused workspace with one terminal pane: (workspace id, pane id).
fn focused_workspace(mux: &Arc<Mux>, key: &str) -> (String, String) {
    let created =
        send(mux, "workspace.create", json!({"initial_content":"terminal","name":key}), Some(key));
    let workspace = created["value"]["workspace_id"].as_str().unwrap().to_string();
    send(mux, "workspace.focus", json!({"workspace":workspace}), Some(&format!("{key}-focus")));
    (workspace, created["value"]["pane_id"].as_str().unwrap().to_string())
}

/// A new pane right of `pane` (the focus stays) with `tabs` terminal tabs.
fn split_with_tabs(mux: &Arc<Mux>, pane: &str, tabs: usize, key: &str) -> String {
    let split = send(mux, "pane.split", json!({"pane":pane,"direction":"right"}), Some(key));
    let created = split["value"]["pane_id"].as_str().unwrap().to_string();
    for index in 1..tabs {
        send(
            mux,
            "tab.create_terminal",
            json!({"pane":created}),
            Some(&format!("{key}-tab-{index}")),
        );
    }
    created
}

fn focused_pane(mux: &Arc<Mux>) -> String {
    let snapshot = snapshot(mux);
    let focused = rows(&snapshot, "panes")
        .iter()
        .filter(|pane| pane["focused"] == true)
        .map(|pane| pane["id"].as_str().unwrap().to_string())
        .collect::<Vec<_>>();
    assert_eq!(focused.len(), 1, "exactly one pane is focused: {snapshot}");
    focused[0].clone()
}

/// The tab ids of `pane`, in order.
fn tabs_of(mux: &Arc<Mux>, pane: &str) -> Vec<String> {
    let snapshot = snapshot(mux);
    let mut tabs = rows(&snapshot, "tabs")
        .iter()
        .filter(|tab| tab["pane_id"] == pane)
        .map(|tab| (tab["index"].as_u64().unwrap(), tab["id"].as_str().unwrap().to_string()))
        .collect::<Vec<_>>();
    tabs.sort();
    tabs.into_iter().map(|(_, id)| id).collect()
}

/// The screen and workspace of `pane`, or `None` when it is gone.
fn place_of(mux: &Arc<Mux>, pane: &str) -> Option<(String, String)> {
    let snapshot = snapshot(mux);
    let screen = rows(&snapshot, "panes").iter().find(|row| row["id"] == pane)?["screen_id"]
        .as_str()?
        .to_string();
    let workspace =
        rows(&snapshot, "screens").iter().find(|row| row["id"] == screen.as_str())?["workspace_id"]
            .as_str()?
            .to_string();
    Some((screen, workspace))
}

fn screen_count(mux: &Arc<Mux>) -> usize {
    rows(&snapshot(mux), "screens").len()
}

#[test]
fn w5p_pane_move_to_a_new_screen_and_back_keeps_the_pane_id_and_its_tabs() {
    let mux = mux();
    let (workspace, home) = focused_workspace(&mux, "w5p-keep");
    let moved = split_with_tabs(&mux, &home, 2, "w5p-keep-split");
    let tabs = tabs_of(&mux, &moved);
    assert_eq!(tabs.len(), 2);
    let (home_screen, _) = place_of(&mux, &home).unwrap();
    let screens = screen_count(&mux);

    let result = move_pane(&mux, json!({"pane":moved,"new_screen":true}), "w5p-keep-out");
    assert_eq!(result["pane_id"], moved.as_str(), "{result}");
    assert_eq!(result["moved_pane_id"], moved.as_str());
    assert_eq!(result["pane_kept"], true);
    assert_eq!(result["tab_ids"], json!(tabs));
    let created = result["created_screen_id"].as_str().unwrap().to_string();
    assert_eq!(result["screen_id"], created.as_str());
    assert_eq!(place_of(&mux, &moved), Some((created.clone(), workspace.clone())));
    assert_eq!(tabs_of(&mux, &moved), tabs);
    assert_eq!(screen_count(&mux), screens + 1);
    assert_eq!(focused_pane(&mux), home, "the move took the focus");

    // Back beside the home pane: the emptied screen closes; same pane id.
    let back = move_pane(
        &mux,
        json!({"pane":moved,"destination_pane":home,"split":"left"}),
        "w5p-keep-back",
    );
    assert_eq!(back["pane_id"], moved.as_str(), "{back}");
    assert_eq!(back["pane_kept"], true);
    assert_eq!(back["closed_screen_id"], created.as_str());
    assert_eq!(place_of(&mux, &moved), Some((home_screen, workspace)));
    assert_eq!(tabs_of(&mux, &moved), tabs);
    assert_eq!(screen_count(&mux), screens);
    assert_eq!(focused_pane(&mux), home);
}

#[test]
fn w5p_pane_move_into_a_pane_merges_the_tabs_in_order_and_closes_the_pane() {
    let mux = mux();
    let (_, home) = focused_workspace(&mux, "w5p-merge");
    let home_tabs = tabs_of(&mux, &home);
    let moved = split_with_tabs(&mux, &home, 3, "w5p-merge-split");
    let tabs = tabs_of(&mux, &moved);

    let result = move_pane(&mux, json!({"pane":moved,"destination_pane":home}), "w5p-merge-in");
    assert_eq!(result["pane_id"], home.as_str(), "{result}");
    assert_eq!(result["moved_pane_id"], moved.as_str());
    assert_eq!(result["pane_kept"], false);
    assert_eq!(result["tab_ids"], json!(tabs));
    assert_eq!(result["index"], home_tabs.len());
    assert_eq!(place_of(&mux, &moved), None, "the merged pane is closed");
    let expected = home_tabs.iter().chain(&tabs).cloned().collect::<Vec<_>>();
    assert_eq!(tabs_of(&mux, &home), expected);
    assert_eq!(focused_pane(&mux), home);

    // `destination_tab` puts the tabs after that tab.
    let again = split_with_tabs(&mux, &home, 1, "w5p-merge-split-2");
    let one = tabs_of(&mux, &again);
    let after = &home_tabs[0];
    let result =
        move_pane(&mux, json!({"pane":again,"destination_tab":after}), "w5p-merge-after-tab");
    assert_eq!(result["index"], 1, "{result}");
    assert_eq!(tabs_of(&mux, &home).get(1), one.first());
}

#[test]
fn w5p_pane_move_replays_with_the_same_key_and_moves_once() {
    let mux = mux();
    let (_, home) = focused_workspace(&mux, "w5p-replay");
    let moved = split_with_tabs(&mux, &home, 1, "w5p-replay-split");
    let screens = screen_count(&mux);
    let fields = json!({"pane":moved,"new_screen":true,"name":"logs"});
    let first = send(&mux, "pane.move", fields.clone(), Some("w5p-replay-move"));
    let second = send(&mux, "pane.move", fields, Some("w5p-replay-move"));
    assert_eq!(first["value"], second["value"]);
    assert_eq!(second["replayed"], true, "{second}");
    assert_eq!(screen_count(&mux), screens + 1, "the retry moved the pane again");
    let snapshot = snapshot(&mux);
    let screen = first["value"]["screen_id"].as_str().unwrap();
    let named = rows(&snapshot, "screens").iter().find(|row| row["id"] == screen).unwrap();
    assert_eq!(named["name"], "logs", "{named}");
}

#[test]
fn w5p_pane_move_keeps_the_focus_unless_asked_or_the_pane_had_it() {
    let mux = mux();
    let (_, home) = focused_workspace(&mux, "w5p-focus");
    let moved = split_with_tabs(&mux, &home, 1, "w5p-focus-split");
    let result = move_pane(&mux, json!({"pane":moved,"new_screen":true}), "w5p-focus-out");
    assert_eq!(focused_pane(&mux), home);
    assert_eq!(result["focused_pane_id"], home.as_str(), "{result}");

    // `focus: true` follows the pane.
    move_pane(
        &mux,
        json!({"pane":moved,"destination_pane":home,"split":"right","focus":true}),
        "w5p-focus-true",
    );
    assert_eq!(focused_pane(&mux), moved);

    // The focused pane keeps the focus where it goes.
    let result = move_pane(&mux, json!({"pane":moved,"new_screen":true}), "w5p-focus-own");
    assert_eq!(focused_pane(&mux), moved);
    let snapshot = snapshot(&mux);
    let focused_screen = rows(&snapshot, "screens")
        .iter()
        .find(|row| row["focused"] == true && row["workspace_id"] == result["workspace_id"])
        .map(|row| row["id"].clone());
    assert_eq!(focused_screen, Some(result["screen_id"].clone()), "{snapshot}");
}

#[test]
fn w5p_pane_move_to_another_workspace_keeps_the_id_and_the_users_place() {
    let mux = mux();
    let (home_workspace, home) = focused_workspace(&mux, "w5p-cross");
    let moved = split_with_tabs(&mux, &home, 2, "w5p-cross-split");
    let tabs = tabs_of(&mux, &moved);
    let other = send(
        &mux,
        "workspace.create",
        json!({"initial_content":"terminal","name":"other"}),
        Some("w5p-cross-other"),
    )["value"]["workspace_id"]
        .as_str()
        .unwrap()
        .to_string();

    let result = move_pane(
        &mux,
        json!({"pane":moved,"new_screen":true,"destination_workspace":other}),
        "w5p-cross-move",
    );
    assert_eq!(result["pane_id"], moved.as_str(), "{result}");
    assert_eq!(result["workspace_id"], other.as_str());
    let (_, workspace) = place_of(&mux, &moved).unwrap();
    assert_eq!(workspace, other);
    assert_eq!(tabs_of(&mux, &moved), tabs);
    assert_eq!(focused_pane(&mux), home);
    let snapshot = snapshot(&mux);
    let focused_workspace = rows(&snapshot, "workspaces")
        .iter()
        .find(|row| row["focused"] == true)
        .map(|row| row["id"].clone());
    assert_eq!(focused_workspace, Some(json!(home_workspace)), "the move switched workspaces");
}

/// The source and every destination go through the one resolver: a tab name
/// (an agent's name), a unique prefix, a bare id and `focused` select what
/// they select in every other command. A pane cannot move into itself.
#[test]
fn w5p_pane_move_resolves_names_prefixes_bare_ids_and_focused() {
    let mux = mux();
    let (_, home) = focused_workspace(&mux, "w5p-select");
    let moved = split_with_tabs(&mux, &home, 1, "w5p-select-split");
    let tab = tabs_of(&mux, &moved).remove(0);
    send(&mux, "tab.rename", json!({"tab":tab,"name":"alpha"}), Some("w5p-select-rename"));

    // The agent's name selects its pane; `focused` is the user's pane.
    let current = |value: &str| json!({"workspace":"current","screen":"current","pane":value});
    let mut fields = current("alpha");
    fields["new_screen"] = json!(true);
    let result = move_pane(&mux, fields, "w5p-select-name");
    assert_eq!(result["pane_id"], moved.as_str(), "{result}");
    let mut fields = current("alpha");
    fields["destination_pane"] = json!("focused");
    fields["split"] = json!("down");
    let result = move_pane(&mux, fields, "w5p-select-focused");
    assert_eq!(result["pane_id"], moved.as_str(), "{result}");
    assert_eq!(place_of(&mux, &moved).map(|place| place.0), place_of(&mux, &home).map(|p| p.0));

    // A unique prefix and a bare id.
    let prefix = &moved[..moved.len() - 20];
    let result = move_pane(&mux, json!({"pane":prefix,"new_screen":true}), "w5p-select-prefix");
    assert_eq!(result["pane_id"], moved.as_str(), "{result}");
    let bare = home.trim_start_matches("pane_");
    let result = move_pane(
        &mux,
        json!({"pane":moved,"destination_pane":bare,"split":"up"}),
        "w5p-select-bare",
    );
    assert_eq!(result["pane_id"], moved.as_str(), "{result}");
    assert_eq!(place_of(&mux, &moved).map(|place| place.0), place_of(&mux, &home).map(|p| p.0));

    // Into itself: refused, nothing moves.
    for (field, value) in [("destination_pane", moved.clone()), ("destination_tab", tab)] {
        let response = request(
            &mux,
            "pane.move",
            json!({"pane": moved, (field): value}),
            Some(&format!("w5p-select-self-{field}")),
        );
        assert_eq!(response["ok"], false, "{response}");
        assert_eq!(response["error"]["code"], "validation.invalid", "{response}");
    }
    assert_eq!(focused_pane(&mux), home);
}
