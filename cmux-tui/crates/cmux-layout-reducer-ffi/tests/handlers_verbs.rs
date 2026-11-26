//! `handlers_verbs_*` through the C ABI: the verb handlers' small rules, with the
//! cases the Swift handlers held (RemoteHandlers+Ports, +Switch, Open as Pane's
//! folder, WorkspacePullRequestLinks, Duplicate Tab, the tab moves, the group walk).

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};
use std::ffi::CString;

fn call(op: &str, request: Value) -> (i32, Option<Value>) {
    let request = serde_json::to_vec(&request).expect("request");
    let op = CString::new(op).expect("op");
    let mut output = vec![0u8; 4096];
    let mut len = 0usize;
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            op.as_ptr(),
            output.as_mut_ptr(),
            output.len(),
            &mut len,
        )
    };
    let body =
        (code == OK).then(|| serde_json::from_slice(&output[..len]).expect("answer is JSON"));
    (code, body)
}

fn answer(op: &str, request: Value) -> Value {
    let (code, body) = call(op, request);
    assert_eq!(code, OK, "{op}");
    body.expect("body")
}

#[test]
fn a_port_is_an_integer_or_a_string_holding_one_in_range() {
    let port = |value: Value| {
        answer("handlers_verbs_port_argument", json!({"port": value}))["port"].clone()
    };
    assert_eq!(port(json!(8080)), json!(8080));
    assert_eq!(port(json!(" 3000\t")), json!(3000));
    assert_eq!(port(json!(65535)), json!(65535));
    assert_eq!(port(json!(1)), json!(1));
    for refused in [
        json!(0),
        json!(65536),
        json!(-1),
        json!("abc"),
        json!(""),
        json!(true),
        json!(null),
        json!("3000\n"),
    ] {
        assert_eq!(port(refused.clone()), Value::Null, "{refused}");
    }
    assert_eq!(answer("handlers_verbs_port_argument", json!({}))["port"], Value::Null);
}

#[test]
fn the_port_list_is_one_line_per_forward_and_none_for_no_forward() {
    let text = answer(
        "handlers_verbs_port_list_text",
        json!({"forwards": [{"port": 3000, "url": "http://localhost:51000"}, {"port": 8080, "url": "http://localhost:51001"}]}),
    );
    assert_eq!(text["text"], json!("3000 → http://localhost:51000\n8080 → http://localhost:51001"));
    assert_eq!(
        answer("handlers_verbs_port_list_text", json!({"forwards": []}))["text"],
        Value::Null
    );
}

#[test]
fn switch_host_takes_a_machine_target_then_the_argument_and_matches_id_then_name() {
    let rows = json!([{"id": "m1", "name": "box"}, {"id": "box", "name": "other"}, {"id": "m3", "name": "devbox"}]);
    let pick = |request: Value| answer("handlers_verbs_switch_host", request);
    assert_eq!(
        pick(json!({"target": {"kind": "machine", "id": "box"}, "rows": rows})),
        json!({"wanted": "box", "row": 1})
    );
    assert_eq!(
        pick(json!({"target": {"kind": "tab", "id": "t"}, "machineText": "devbox", "rows": rows})),
        json!({"wanted": "devbox", "row": 2})
    );
    assert_eq!(
        pick(json!({"machineTarget": "m1", "machineText": "devbox", "rows": rows})),
        json!({"wanted": "m1", "row": 0})
    );
    assert_eq!(
        pick(json!({"machineText": "nope", "rows": rows})),
        json!({"wanted": "nope", "row": null})
    );
    assert_eq!(pick(json!({"rows": rows})), json!({"wanted": null, "row": null}));
}

#[test]
fn the_pane_folder_takes_the_path_first_then_the_pane() {
    let folder = |request: Value| answer("handlers_verbs_pane_folder", request)["folder"].clone();
    let home = "/Users/me";
    assert_eq!(folder(json!({"paneFolder": "/work", "home": home})), json!("/work"));
    assert_eq!(folder(json!({"path": "  ", "home": home})), Value::Null);
    assert_eq!(
        folder(json!({"path": "~", "paneFolder": "/work", "home": home})),
        json!("/Users/me")
    );
    assert_eq!(folder(json!({"path": "~/src/./a/../b/", "home": home})), json!("/Users/me/src/b"));
    assert_eq!(folder(json!({"path": "/tmp//x/..", "home": home})), json!("/tmp"));
    assert_eq!(
        folder(json!({"path": "sub/dir", "paneFolder": "/work/", "home": home})),
        json!("/work/sub/dir")
    );
    assert_eq!(folder(json!({"path": "../up", "home": home})), json!("/Users/up"));
    assert_eq!(folder(json!({"path": "/..", "home": home})), json!("/"));
}

#[test]
fn pr_links_put_the_pr_entry_first_each_link_once_web_only() {
    let links = answer(
        "handlers_verbs_pr_links",
        json!({"prKey": "pr", "entries": [
            {"key": "ci", "links": ["https://ci.example/1", "mailto:a@b.c", "https://github.com/o/r/pull/1"]},
            {"key": "pr", "links": ["https://github.com/o/r/pull/1", "HTTP://x.example"]},
            {"key": "notes", "links": ["ftp://files", "https://ci.example/1"]}
        ]}),
    );
    assert_eq!(
        links["links"],
        json!(["https://github.com/o/r/pull/1", "HTTP://x.example", "https://ci.example/1"])
    );
}

#[test]
fn duplicate_tab_plans_each_tab_and_refuses_when_nothing_duplicates() {
    let plan = |tabs: Value| answer("handlers_verbs_duplicate_plan", json!({"tabs": tabs}));
    assert_eq!(
        plan(
            json!([{"browser": true}, {"agent": true, "otherHost": true}, {"localPage": true}, {}])
        ),
        json!({"actions": ["browser", "elsewhere", "skip", "terminal"], "refusal": null})
    );
    assert_eq!(plan(json!([{"agent": true}])), json!({"actions": ["agent"], "refusal": null}));
    assert_eq!(
        plan(json!([{"localPage": true}, {"page": true}])),
        json!({"actions": [], "refusal": "pageTabOpensOnce"})
    );
    assert_eq!(
        plan(json!([{"agent": true, "otherHost": true}, {"page": true}])),
        json!({"actions": [], "refusal": "agentTabOtherHost"})
    );
    assert_eq!(plan(json!([])), json!({"actions": [], "refusal": "pageTabOpensOnce"}));
}

#[test]
fn a_tab_move_toward_an_edge_splits_unless_the_tab_is_alone() {
    let split = |action: &str, tabs: usize| {
        answer("handlers_verbs_move_split", json!({"action": action, "tabsInPane": tabs}))["direction"].clone()
    };
    assert_eq!(split("moveSurfaceToPaneLeft", 2), json!("left"));
    assert_eq!(split("moveSurfaceToPaneRight", 3), json!("right"));
    assert_eq!(split("moveSurfaceToPaneUp", 2), json!("up"));
    assert_eq!(split("moveSurfaceToPaneDown", 2), json!("down"));
    assert_eq!(split("moveSurfaceToPaneDown", 1), Value::Null);
    assert_eq!(split("moveSurfaceLeft", 4), Value::Null);
    assert_eq!(split("moveSurfaceToNextPane", 4), Value::Null);
}

#[test]
fn the_group_walk_starts_past_the_active_group_and_wraps() {
    let walk = |request: Value| answer("handlers_verbs_group_walk", request)["order"].clone();
    assert_eq!(walk(json!({"count": 4, "active": 1, "offset": 1})), json!([2, 3, 0, 1]));
    assert_eq!(walk(json!({"count": 4, "active": 1, "offset": -1})), json!([0, 3, 2, 1]));
    assert_eq!(walk(json!({"count": 3, "offset": 1})), json!([0, 1, 2]));
    assert_eq!(walk(json!({"count": 3, "offset": -1})), json!([2, 1, 0]));
    assert_eq!(walk(json!({"count": 0, "offset": 1})), json!([]));
}

#[test]
fn a_group_move_stops_at_its_edge() {
    let edge = |direction: &str| {
        answer("handlers_verbs_group_edge", json!({"direction": direction}))["edge"].clone()
    };
    assert_eq!(edge("top"), json!("alreadyAtTop"));
    assert_eq!(edge("up"), json!("alreadyAtTop"));
    assert_eq!(edge("down"), json!("alreadyAtBottom"));
    assert_eq!(edge("bottom"), json!("alreadyAtBottom"));
    assert_eq!(edge("sideways"), Value::Null);
}

#[test]
fn remove_from_group_puts_workspaces_before_the_groups_or_after_theirs() {
    let index = |request: Value| answer("handlers_verbs_ungroup_index", request)["index"].clone();
    assert_eq!(
        index(
            json!({"ungroupedFirst": true, "firstUnpinnedGroup": 2, "nodeCount": 5, "groupNode": 3})
        ),
        json!(2)
    );
    assert_eq!(index(json!({"ungroupedFirst": true, "nodeCount": 5, "groupNode": 3})), json!(5));
    assert_eq!(
        index(
            json!({"ungroupedFirst": false, "firstUnpinnedGroup": 2, "nodeCount": 5, "groupNode": 3})
        ),
        json!(4)
    );
}

#[test]
fn an_unknown_verbs_op_or_a_bad_request_is_refused() {
    assert_eq!(call("handlers_verbs_nope", json!({})).0, ERR_INVALID);
    assert_eq!(call("handlers_verbs_move_split", json!({"action": 1})).0, ERR_INVALID);
}

#[test]
fn space_moves_insert_past_the_target_and_refuse_at_the_edge() {
    let index = |verb: &str, from: usize, position: Value| {
        answer(
            "handlers_verbs_room_move",
            json!({"verb": verb, "from": from, "count": 4, "position": position}),
        )["index"]
            .clone()
    };
    assert_eq!(index("space.moveLeft", 2, Value::Null), json!(1));
    assert_eq!(index("space.moveLeft", 0, Value::Null), Value::Null);
    assert_eq!(index("space.moveRight", 1, Value::Null), json!(3));
    assert_eq!(index("space.moveRight", 3, Value::Null), Value::Null);
    assert_eq!(index("space.moveToStart", 2, Value::Null), json!(0));
    assert_eq!(index("space.moveToStart", 0, Value::Null), Value::Null);
    assert_eq!(index("space.moveToEnd", 1, Value::Null), json!(4));
    assert_eq!(index("space.move", 1, json!(2)), json!(1));
    assert_eq!(index("space.move", 0, json!(9)), json!(4));
    assert_eq!(index("space.move", 2, json!(-3)), json!(0));
    assert_eq!(index("space.move", 0, Value::Null), Value::Null);
    assert_eq!(index("space.other", 0, Value::Null), Value::Null);
}
