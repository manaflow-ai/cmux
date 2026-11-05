use serde_json::{Value, json};

use super::{append, find, machine_rows, machines_of, rows};

/// The app's `cloud.machines` machines: two made from one image (the same
/// first workspace id), one of them with a second workspace that
/// `cloud new-workspace` opened, and one without a daemon yet.
fn machines() -> Vec<Value> {
    json!([
        {"id": "vm-aaa", "title": "build-box", "daemon": "connected",
         "machine_id": "machine_1111", "workspaces": [
            {"id": "a40723c3", "name": "workspace-1", "resource_id": "ws_d0e60f13"},
            {"id": "bf156a1d", "name": "workspace-2", "resource_id": "ws_9e2a"},
        ]},
        {"id": "vm-bbb", "title": "build-box-2", "daemon": "connected",
         "machine_id": "machine_1111", "workspaces": [
            {"id": "a40723c3", "name": "workspace-1", "resource_id": "ws_d0e60f13"},
        ]},
        {"id": "vm-ccc", "title": "", "daemon": "connecting", "workspaces": []},
    ])
    .as_array()
    .cloned()
    .unwrap()
}

#[test]
fn every_cloud_workspace_is_a_row_marked_with_its_machine() {
    let listed = rows(&machines());
    assert_eq!(listed.len(), 3);
    assert_eq!(
        listed[1],
        json!({
            "id": "ws_9e2a",
            "workspace_id": "bf156a1d",
            "name": "workspace-2",
            "machine_id": "vm-aaa",
            "machine_name": "build-box",
            "target": "machine:vm-aaa",
            "origin": "cloud",
            "daemon": "connected",
        })
    );
    // One image's machines list the same workspace ids; machine_id tells them apart.
    assert_eq!(listed[0]["id"], listed[2]["id"]);
    assert_ne!(listed[0]["machine_id"], listed[2]["machine_id"]);
    assert_eq!(listed[2]["target"], "machine:vm-bbb");
}

#[test]
fn a_workspace_without_a_ws_id_is_named_by_its_durable_id() {
    // An older app (no resource_id) or a daemon without the registry.
    let machine = json!({"id": "vm-old", "workspaces": [
        {"id": "handle:3", "name": "build"},
        {"id": "", "name": "no id"},
        {"name": "missing id"},
    ]});
    assert_eq!(
        machine_rows(&machine),
        vec![json!({
            "id": "handle:3", "workspace_id": "handle:3", "name": "build",
            "machine_id": "vm-old", "machine_name": "vm-old",
            "target": "machine:vm-old", "origin": "cloud",
        })]
    );
    assert!(machine_rows(&json!({"workspaces": [{"id": "x"}]})).is_empty(), "no machine id");
}

#[test]
fn a_machine_is_found_by_its_id_target_or_unique_title() {
    let machines = machines();
    for selector in ["vm-aaa", "machine:vm-aaa", "build-box", "name:build-box"] {
        let found = find(&machines, selector).unwrap().expect(selector);
        assert_eq!(found["id"], "vm-aaa", "{selector}");
    }
    assert_eq!(find(&machines, "vm-zzz").unwrap(), None);
    assert_eq!(find(&machines, "machine_1111").unwrap(), None, "a catalog id is no Cloud id");

    let mut twins = machines;
    twins[1]["title"] = json!("build-box");
    let ambiguous = find(&twins, "build-box").unwrap_err();
    assert_eq!(ambiguous["code"], "selector.ambiguous");
    assert_eq!(ambiguous["details"]["candidates"], json!(["vm-aaa", "vm-bbb"]));
    // The id still names one.
    assert_eq!(find(&twins, "vm-bbb").unwrap().unwrap()["id"], "vm-bbb");
}

#[test]
fn rows_join_the_daemon_list_in_either_shape() {
    let cloud = rows(&machines());
    let local = json!({"id": "ws_local", "name": "Home"});
    let joined = append(json!([local]), cloud.clone());
    assert_eq!(joined.as_array().unwrap().len(), 4);
    assert_eq!(joined[0], local, "the daemon's rows come first, unchanged");
    assert_eq!(joined[3]["machine_id"], "vm-bbb");

    let paged = append(json!({"items": [local], "next": null}), cloud);
    assert_eq!(paged["items"].as_array().unwrap().len(), 4);
    assert_eq!(paged["next"], Value::Null);

    assert_eq!(append(json!([local]), Vec::new()), json!([local]));
    assert_eq!(append(json!("odd"), rows(&machines())), json!("odd"));
}

#[test]
fn a_reply_without_machines_has_none() {
    assert_eq!(machines_of(&json!({"ran": true})), None);
    assert_eq!(machines_of(&json!({"machines": []})), Some(Vec::new()));
}
