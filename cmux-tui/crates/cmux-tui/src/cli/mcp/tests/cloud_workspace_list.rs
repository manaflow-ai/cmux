//! `workspace_list` lists the app's Cloud machines' workspaces after the
//! daemon's (cli/cloud_workspaces.rs).

use super::*;

const LOCAL: &str = "ws_1a2b3c";

/// A daemon with one workspace and an app with two Cloud machines.
fn fake() -> Fake {
    Fake {
        resource_result: Some(json!({"id": LOCAL, "name": "Home", "index": 0})),
        cloud_machines: Some(json!({"loaded": true, "machines": [
            {"id": "vm-aaa", "title": "build-box", "daemon": "connected", "workspaces": [
                {"id": "a40723c3", "name": "workspace-1", "resource_id": "ws_d0e6"},
                {"id": "bf156a1d", "name": "workspace-2", "resource_id": "ws_9e2a"},
            ]},
            {"id": "vm-bbb", "title": "review-box", "daemon": "connected", "workspaces": [
                {"id": "a40723c3", "name": "workspace-1", "resource_id": "ws_d0e6"},
            ]},
        ]})),
        ..Fake::default()
    }
}

fn items(result: &Value) -> Vec<Value> {
    assert_eq!(result["isError"], false, "{result}");
    result["structuredContent"]["items"].as_array().cloned().expect("items")
}

#[test]
fn workspace_list_adds_each_cloud_machines_workspaces_marked_with_the_machine() {
    let mut server = Server::new(fake(), None);
    let listed = items(&call(&mut server, "workspace_list", json!({})));
    let ids: Vec<_> = listed.iter().map(|row| row["id"].clone()).collect();
    assert_eq!(ids, [json!(LOCAL), json!("ws_d0e6"), json!("ws_9e2a"), json!("ws_d0e6")]);
    assert!(listed[0].get("machine_id").is_none(), "the daemon's rows stay as they were");
    // The workspace `cloud new-workspace` answered (machine_id, workspace_id) is found.
    let opened = listed
        .iter()
        .find(|row| row["machine_id"] == "vm-aaa" && row["workspace_id"] == "bf156a1d")
        .expect("the new Cloud workspace");
    assert_eq!(opened["target"], "machine:vm-aaa");
    assert_eq!(opened["machine_name"], "build-box");
    assert_eq!(opened["origin"], "cloud");
    assert_eq!(listed[3]["machine_id"], "vm-bbb");

    // The daemon was asked as before; the app answered the Cloud rows.
    let request = &server.backend.last("resource")["request"];
    assert_eq!(request["operation"], "workspace.list");
    assert_eq!(request["params"]["machine"], "current");
    assert_eq!(server.backend.last("app")["method"], "cloud.machines");
}

#[test]
fn the_cloud_rows_page_with_the_daemons() {
    let mut server = Server::new(fake(), None);
    let page = call(&mut server, "workspace_list", json!({"offset": 1, "limit": 2}));
    let content = &page["structuredContent"];
    assert_eq!(content["total"], 4);
    assert_eq!(content["next_offset"], 3);
    assert_eq!(content["items"][0]["machine_id"], "vm-aaa");
}

#[test]
fn machine_lists_one_cloud_machines_workspaces_without_the_daemon() {
    for selector in ["vm-aaa", "machine:vm-aaa", "build-box"] {
        let mut server = Server::new(fake(), None);
        let listed = items(&call(&mut server, "workspace_list", json!({"machine": selector})));
        assert_eq!(listed.len(), 2, "{selector}");
        assert!(listed.iter().all(|row| row["machine_id"] == "vm-aaa"), "{selector}");
        assert!(sent_of(&server, "resource").is_empty(), "{selector}: no daemon read");
    }
    let mut server = Server::new(fake(), None);
    let page = call(&mut server, "workspace_list", json!({"machine": "vm-aaa", "limit": 1}));
    assert_eq!(page["structuredContent"]["next_offset"], 1);
}

#[test]
fn machine_local_lists_only_this_macs_workspaces() {
    let mut server = Server::new(fake(), None);
    let listed = items(&call(&mut server, "workspace_list", json!({"machine": "local"})));
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0]["id"], LOCAL);
    assert!(sent_of(&server, "app").is_empty(), "no Cloud read");
    let params = &server.backend.last("resource")["request"]["params"];
    assert_eq!(params["machine"], "current", "machine is no daemon selector here");
}

#[test]
fn an_unknown_machine_or_a_bad_argument_says_how_to_find_one() {
    let mut server = Server::new(fake(), None);
    let unknown = call(&mut server, "workspace_list", json!({"machine": "vm-zzz"}));
    assert_eq!(unknown["isError"], true);
    let error = &unknown["structuredContent"]["error"];
    assert_eq!(error["code"], "selector.not_found");
    assert!(error["message"].as_str().unwrap().contains("app_cloud_list_machines"), "{error}");

    for arguments in [
        json!({"machine": ""}),
        json!({"machine": 3}),
        json!({"machine": "vm-aaa", "order": "session"}),
        json!({"machine": "vm-aaa", "limit": 0.5}),
    ] {
        let refused = call(&mut server, "workspace_list", arguments.clone());
        assert_eq!(refused["isError"], true, "{arguments}");
        assert_eq!(refused["structuredContent"]["state"], "not_run", "{arguments}");
        assert_eq!(refused["structuredContent"]["error"]["code"], "validation.invalid");
    }
}

#[test]
fn without_the_apps_cloud_machines_the_daemons_list_stands_alone() {
    // An app that answers no machines (older, Cloud off) and an app that is down.
    for fake in [Fake { cloud_machines: None, ..fake() }, Fake { fail_apps: true, ..fake() }] {
        let mut server = Server::new(fake, None);
        let listed = items(&call(&mut server, "workspace_list", json!({})));
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0]["id"], LOCAL);
    }
}

#[test]
fn a_named_session_is_listed_alone() {
    let mut server = Server::new(fake(), None);
    let listed = items(&call(&mut server, "workspace_list", json!({"session": "build-box"})));
    assert_eq!(listed.len(), 1);
    assert!(sent_of(&server, "app").is_empty());

    // A server started on another session (`cmux --session X mcp serve`) too.
    let mut server = Server::new(Fake { other_session: true, ..fake() }, None);
    let listed = items(&call(&mut server, "workspace_list", json!({})));
    assert_eq!(listed.len(), 1);
    assert!(sent_of(&server, "app").is_empty());
}

#[test]
fn workspace_list_documents_the_machine_argument() {
    let tool = v2_tools::find("workspace_list").expect("workspace_list");
    let schema = tool.input_schema();
    assert_eq!(schema["properties"]["machine"]["type"], "string");
    assert!(!schema["required"].as_array().unwrap().contains(&json!("machine")));
    let description = tool.descriptor_json()["description"].as_str().unwrap().to_owned();
    assert!(description.contains("machine_id"), "{description}");
    assert!(
        v2_tools::find("workspace_get").unwrap().input_schema()["properties"]["machine"].is_null()
    );
}
