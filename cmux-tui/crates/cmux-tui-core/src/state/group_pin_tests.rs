//! `workspace-group-pin-v1` over `cmux.protocol/2`: a pinned (saved)
//! personal workspace group (`workspace_group.update {pinned}`). The pin is
//! the group's durable mark that it stays when its workspaces close; the
//! app keeps an empty pinned group as a saved group.

use serde_json::json;

use super::tests::{Session, changes_after, error_code, mutate, read, revision, send};

fn group_pins(mux: &std::sync::Arc<crate::mux::Mux>) -> Vec<serde_json::Value> {
    read(mux, "workspace_group.list", json!({}))
        .as_array()
        .unwrap()
        .iter()
        .map(|group| group["pinned"].clone())
        .collect()
}

/// A pin sets, shows on the snapshot, the list and `session.events`,
/// survives a restart through the registry file, and unpins.
#[test]
fn a_group_pin_sets_publishes_survives_a_restart_and_unpins() {
    let session = Session::new("group-pin");
    let mux = session.open();
    let created = mutate(&mux, "workspace_group.create", json!({"name": "Work"}), "create-work");
    let group = created["id"].as_str().unwrap().to_string();
    assert_eq!(created["pinned"], false, "a new group is not pinned: {created}");

    let before = revision(&mux);
    let pinned = mutate(
        &mux,
        "workspace_group.update",
        json!({"workspace_group": group, "pinned": true}),
        "pin",
    );
    assert_eq!(pinned["pinned"], true);
    assert_eq!(pinned["name"], "Work", "a pin keeps the name");
    assert!(
        changes_after(&mux, before).iter().any(|change| change["kind"] == "state_upsert"
            && change["resource"] == "workspace_group"
            && change["value"]["pinned"] == true),
        "session.events carries the pin"
    );
    assert_eq!(group_pins(&mux), [json!(true)]);
    drop(mux);

    let mux = session.open();
    assert_eq!(group_pins(&mux), [json!(true)], "the pin is in the registry file");
    let unpinned = mutate(
        &mux,
        "workspace_group.update",
        json!({"workspace_group": group, "pinned": false}),
        "unpin",
    );
    assert_eq!(unpinned["pinned"], false);
    assert_eq!(group_pins(&mux), [json!(false)]);
    mux.shutdown();
}

/// A pinned group keeps its record when every member workspace leaves it,
/// and the pin is not a null: `pinned: null` is refused.
#[test]
fn a_pinned_group_stays_empty_and_a_null_pin_is_refused() {
    let session = Session::new("group-pin-empty");
    let mux = session.open();
    let group = mutate(&mux, "workspace_group.create", json!({"name": "Saved"}), "create")["id"]
        .as_str()
        .unwrap()
        .to_string();
    let pin = json!({"workspace_group": group, "pinned": true});
    mutate(&mux, "workspace_group.update", pin, "pin");
    let workspace = super::tests::empty_workspace(&mux, "member");
    mutate(&mux, "workspace.place", json!({"workspace": workspace, "group": group}), "join");
    mutate(&mux, "workspace.place", json!({"workspace": workspace, "group": null}), "leave");
    let groups = read(&mux, "workspace_group.list", json!({}));
    assert_eq!(groups[0]["id"], group.as_str(), "the emptied group stays");
    assert_eq!(groups[0]["pinned"], true);
    assert_eq!(
        error_code(send(
            &mux,
            "workspace_group.update",
            json!({"workspace_group": group, "pinned": null}),
            Some("null-pin"),
        )),
        "validation.invalid"
    );
    mux.shutdown();
}
