//! `closed_ids` over a real daemon socket (GPUI Undo of a bulk close, with
//! hq-6d's version-skew conditions). Each close names the closed groups it
//! stored, so `closed.reopen` of those ids restores exactly that close. For
//! every verb: (a) a replay names the same ids, (b) a cascaded close (a
//! workspace the close emptied) is in the list, where the verb can cascade,
//! and (c) a client that does not ask gets the result shape an older client
//! decodes.

use serde_json::{Value, json};

use super::*;

/// One request line on a new connection; the whole response.
fn send(server: &HeadlessServer, request: &Value) -> Value {
    let stream = transport::connect(&server.socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{request}").unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap_or_else(|error| panic!("{error}: {line}"))
}

/// A raw command's `data`.
fn ok(server: &HeadlessServer, request: Value) -> Value {
    let response = send(server, &request);
    assert_eq!(response["ok"], true, "{request} failed: {response}\n{}", server.stderr_tail());
    response["data"].clone()
}

/// A `cmux.protocol/2` request's `result`.
fn v2(server: &HeadlessServer, operation: &str, params: Value, key: Option<&str>) -> Value {
    let mut fields = json!({"machine": "current", "session": "current"});
    fields.as_object_mut().unwrap().extend(params.as_object().unwrap().clone());
    let mut request = json!({"protocol": "cmux.protocol/2", "type": "request",
                             "id": format!("closed-ids-{operation}"), "operation": operation,
                             "params": fields});
    if let Some(key) = key {
        request["idempotency_key"] = json!(key);
    }
    let response = send(server, &request);
    assert_eq!(response["ok"], true, "{request} failed: {response}\n{}", server.stderr_tail());
    response["result"].clone()
}

/// The closed groups, newest first.
fn closed(server: &HeadlessServer) -> Vec<Value> {
    v2(server, "closed.list", json!({}), None).as_array().unwrap().clone()
}

fn ids(items: &[Value]) -> Vec<Value> {
    items.iter().map(|item| item["id"].clone()).collect()
}

fn keys(value: &Value) -> Vec<String> {
    let mut keys = value.as_object().unwrap().keys().cloned().collect::<Vec<_>>();
    keys.sort();
    keys
}

/// A raw workspace named `name` with one `/bin/cat` terminal: its key and
/// the terminal's surface.
fn workspace_with_tab(server: &HeadlessServer, name: &str) -> (String, u64) {
    let created = ok(server, json!({"id": 1, "cmd": "create-workspace", "name": name}));
    let key = created["key"].as_str().unwrap().to_string();
    let terminal =
        ok(server, json!({"id": 2, "cmd": "create-terminal", "key": key, "argv": ["/bin/cat"]}));
    (key, terminal["surface"].as_u64().unwrap_or_else(|| panic!("no surface: {terminal}")))
}

/// Public `workspace.close`: with `report_closed_ids` each close names its
/// group, also for two workspaces of the same name, and reopening those ids
/// restores exactly them; a replay names the same ids; without the flag the
/// value stays `{}` (older SDKs decode it as an empty object). A workspace
/// close cannot cascade: nothing above a workspace closes with it.
#[test]
fn workspace_close_reports_its_groups_on_request() {
    let server = HeadlessServer::start("closed-ids-workspace");
    ok(&server, json!({"id": 0, "cmd": "create-workspace", "name": "stays"}));
    let create = |name: &str, key: &str| {
        let created = v2(
            &server,
            "workspace.create",
            json!({"name": name, "initial_content": "empty"}),
            Some(key),
        );
        created["value"]["workspace_id"].as_str().unwrap().to_string()
    };
    let first = create("same", "create-1");
    let second = create("same", "create-2");
    let plain = create("plain", "create-3");
    let report = |workspace: &str| json!({"workspace": workspace, "report_closed_ids": true});

    let closed_first = v2(&server, "workspace.close", report(&first), Some("close-1"));
    let closed_second = v2(&server, "workspace.close", report(&second), Some("close-2"));
    let listed = ids(&closed(&server));
    assert_eq!(listed.len(), 2, "{listed:?}");
    assert_eq!(closed_first["value"], json!({"closed_ids": [listed[1]]}), "{closed_first}");
    assert_eq!(closed_second["value"], json!({"closed_ids": [listed[0]]}), "{closed_second}");

    // (a) A retry with the same key answers the same ids.
    let replay = v2(&server, "workspace.close", report(&second), Some("close-2"));
    assert_eq!(replay["replayed"], true, "{replay}");
    assert_eq!(replay["value"], closed_second["value"]);

    // (c) No flag: the value an older SDK decodes.
    let closed_plain = v2(&server, "workspace.close", json!({"workspace": plain}), Some("close-3"));
    assert_eq!(closed_plain["value"], json!({}), "{closed_plain}");

    let items = closed(&server);
    assert_eq!(items[1]["members"][0]["kind"], "workspace", "{items:?}");

    for (index, closed_one) in [&closed_first, &closed_second].into_iter().enumerate() {
        let id = closed_one["value"]["closed_ids"][0].clone();
        let reopened =
            v2(&server, "closed.reopen", json!({"closed": id}), Some(&format!("reopen-{index}")));
        assert_eq!(reopened["value"]["closed_id"], id, "{reopened}");
    }
    assert_eq!(ids(&closed(&server)), vec![items[0]["id"].clone()], "only the plain close stays");
}

/// Raw `close-workspace` with `end_terminals`: `report_closed_ids` names the
/// group, a replay names it again, and without the flag the result has
/// exactly the fields it had before (raw decoders refuse unknown fields).
#[test]
fn raw_close_workspace_reports_its_group_on_request() {
    let server = HeadlessServer::start("closed-ids-raw-workspace");
    ok(&server, json!({"id": 0, "cmd": "create-workspace", "name": "stays"}));
    let (reported, _) = workspace_with_tab(&server, "same");
    let (plain, _) = workspace_with_tab(&server, "same");
    let close = json!({"id": 3, "cmd": "close-workspace", "key": reported, "end_terminals": true,
                       "report_closed_ids": true, "origin": "closed-ids",
                       "mutation_id": "close-1"});
    let closed_one = ok(&server, close.clone());
    assert_eq!(closed_one["closed_ids"], json!([ids(&closed(&server))[0]]), "{closed_one}");
    // (a)
    let replay = ok(&server, close);
    assert_eq!(replay["replayed"], true, "{replay}");
    assert_eq!(replay["closed_ids"], closed_one["closed_ids"]);
    // (c)
    let closed_plain = ok(
        &server,
        json!({"id": 4, "cmd": "close-workspace", "key": plain, "end_terminals": true}),
    );
    assert_eq!(
        keys(&closed_plain),
        [
            "changed",
            "generation",
            "index",
            "key",
            "registry_id",
            "replayed",
            "workspace",
            "workspace_revision"
        ],
        "{closed_plain}"
    );
    assert_eq!(closed(&server).len(), 2);
}

/// Raw `close-tabs` of a workspace's only tab: the emptied workspace closes
/// in the same commit and joins its group, whose id the result names (b); a
/// replay names it again (a); the fields an older client reads keep their
/// types (c: the result is a free JSON object in every raw SDK).
#[test]
fn close_tabs_reports_the_group_its_cascade_joined() {
    let server = HeadlessServer::start("closed-ids-close-tabs");
    ok(&server, json!({"id": 0, "cmd": "create-workspace", "name": "stays"}));
    let (_, surface) = workspace_with_tab(&server, "cascade");
    let close = json!({"id": 5, "cmd": "close-tabs", "surfaces": [surface],
                       "end_terminals": true, "origin": "closed-ids", "mutation_id": "tabs-1"});
    let closed_tabs = ok(&server, close.clone());
    let items = closed(&server);
    assert_eq!(items.len(), 1, "{items:?}");
    assert_eq!(items[0]["kind"], "workspace", "the emptied workspace joins the group");
    assert_eq!(closed_tabs["closed_ids"], json!([items[0]["id"]]), "{closed_tabs}");
    assert_eq!(closed_tabs["closed"], json!([surface]));
    assert!(closed_tabs["terminals"].is_array() && closed_tabs["resource_revision"].is_u64());
    let replay = ok(&server, close);
    assert_eq!(replay["replayed"], true, "{replay}");
    assert_eq!(replay["closed_ids"], closed_tabs["closed_ids"]);
}

/// `layout.bulk` closing every tab of a workspace's only pane: the emptied
/// workspace joins the call's one group (b), whose id `closed_ids` names; a
/// replay names it again (a); the old fields are unchanged (c: no SDK has a
/// typed `layout.bulk` decoder).
#[test]
fn layout_bulk_reports_the_group_its_cascade_joined() {
    let server = HeadlessServer::start("closed-ids-bulk");
    ok(&server, json!({"id": 0, "cmd": "create-workspace", "name": "stays"}));
    workspace_with_tab(&server, "cascade");
    let workspace = v2(&server, "workspace.list", json!({}), None)
        .as_array()
        .unwrap()
        .iter()
        .find(|workspace| workspace["name"] == "cascade")
        .unwrap()["id"]
        .clone();
    let tab = v2(&server, "tab.list", json!({"workspace": workspace}), None)[0]["id"].clone();
    let request = json!({"verb": "close", "level": "tab", "selector": "all", "anchor": tab,
                         "end_terminals": true});
    let bulk = v2(&server, "layout.bulk", request.clone(), Some("bulk-1"));
    let items = closed(&server);
    assert_eq!(items.len(), 1, "{items:?}");
    assert_eq!(items[0]["kind"], "workspace", "the emptied workspace joins the group");
    assert_eq!(bulk["value"]["closed_ids"], json!([items[0]["id"]]), "{bulk}");
    assert_eq!(bulk["value"]["tab_ids"], json!([tab]));
    let replay = v2(&server, "layout.bulk", request, Some("bulk-1"));
    assert_eq!(replay["replayed"], true, "{replay}");
    assert_eq!(replay["value"], bulk["value"]);
}
