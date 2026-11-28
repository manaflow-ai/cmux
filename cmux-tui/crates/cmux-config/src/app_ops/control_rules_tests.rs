//! `control.validate`, pinned to Swift `ControlRouter.validatedRequest` and
//! `ControlRouter.target(from:)` as they answered before the move.

use serde_json::{Value, json};

use crate::app_ops::call;

fn action() -> Value {
    json!({
        "id": "tab.rename",
        "targets": ["tab", "pane"],
        "arguments": [
            {"name": "title", "kind": "string", "required": true},
            {"name": "count", "kind": "int", "required": false, "min": 1, "max": 5},
            {"name": "pinned", "kind": "bool", "required": false},
            {"name": "mode", "kind": "enum", "required": false, "choices": ["Left", "right"]},
            {"name": "promptId", "kind": "string", "required": false},
            {"name": "space", "kind": "target", "required": false, "target_kind": "workspace-group"},
        ],
    })
}

fn validate_with(action: Value, params: Value) -> Value {
    call("control.validate", &json!({"action": action, "params": params, "known_kinds": ["tab", "pane", "workspace", "workspace-group"]}))
        .expect("control.validate answers")
}

fn validate(params: Value) -> Value {
    validate_with(action(), params)
}

fn request(params: Value) -> Value {
    let answer = validate(params);
    answer.get("request").cloned().unwrap_or_else(|| panic!("refused: {answer}"))
}

fn refusal(params: Value) -> Value {
    let answer = validate(params);
    answer.get("error").cloned().unwrap_or_else(|| panic!("accepted: {answer}"))
}

#[test]
fn a_full_request_validates() {
    let got = request(json!({
        "target": "tab:tab_1",
        "focus": true,
        "beside_chat": true,
        "args": {"title": "Build", "count": "3", "pinned": "yes", "mode": " LEFT ", "space": "workspace-group:g1"},
    }));
    assert_eq!(
        got,
        json!({
            "focus": true,
            "beside_chat": true,
            "target": {"kind": "tab", "id": "tab_1"},
            "arguments": {
                "title": {"string": "Build"},
                "count": {"int": 3},
                "pinned": {"bool": true},
                "mode": {"string": "Left"},
                "space": {"target": {"kind": "workspace-group", "id": "g1"}},
            },
        })
    );
}

#[test]
fn arguments_alias_args_and_null_is_none() {
    assert_eq!(
        request(json!({"arguments": {"title": "x"}}))["arguments"],
        json!({"title": {"string": "x"}})
    );
    assert_eq!(refusal(json!({"args": null}))["id"], "missing_arguments");
    assert_eq!(refusal(json!({"args": [1]})), json!({"id": "args_shape", "args": []}));
}

#[test]
fn focus_and_background_must_be_flags() {
    assert_eq!(
        refusal(json!({"focus": "yes", "args": {"title": "x"}})),
        json!({"id": "focus_shape", "args": []})
    );
    assert_eq!(
        refusal(json!({"background": 1, "args": {"title": "x"}})),
        json!({"id": "background_shape", "args": []})
    );
    let got = request(json!({"focus": null, "background": false, "args": {"title": "x"}}));
    assert_eq!(got.get("focus"), None);
    assert_eq!(got["background"], false);
    assert_eq!(got["beside_chat"], false);
}

#[test]
fn spellings_fold_to_the_schema_name() {
    for spelled in ["promptId", "prompt-id", "prompt_id", "PROMPTID"] {
        let got = request(json!({"args": {"title": "x", spelled: "p1"}}));
        assert_eq!(got["arguments"]["promptId"], json!({"string": "p1"}), "{spelled}");
    }
    // Rooms became Spaces.
    let got = request(json!({"args": {"title": "x", "room": "g2"}}));
    assert_eq!(
        got["arguments"]["space"],
        json!({"target": {"kind": "workspace-group", "id": "g2"}})
    );
}

#[test]
fn two_spellings_of_one_argument_are_refused() {
    assert_eq!(
        refusal(json!({"args": {"title": "x", "promptId": "a", "prompt-id": "b"}})),
        json!({
            "id": "argument_given_twice",
            "args": ["tab.rename", "promptId", "prompt-id", "promptId"],
            "data": {"argument": "promptId", "given": ["prompt-id", "promptId"]},
        })
    );
}

#[test]
fn an_unknown_argument_lists_the_valid_ones() {
    assert_eq!(
        refusal(json!({"args": {"nope": 1}})),
        json!({
            "id": "no_such_argument",
            "args": ["tab.rename", "nope"],
            "data": {"valid": ["title", "count", "pinned", "mode", "promptId", "space"]},
        })
    );
}

#[test]
fn missing_required_arguments_unless_interactive() {
    assert_eq!(
        refusal(json!({})),
        json!({"id": "missing_arguments", "args": ["tab.rename", "--title"], "data": {"missing": ["title"]}})
    );
    assert_eq!(request(json!({"interactive": true}))["arguments"], json!({}));
}

#[test]
fn a_target_supplies_its_argument() {
    let action = json!({
        "id": "space.switch",
        "targets": ["room"],
        "arguments": [{"name": "space", "kind": "string", "required": true, "target_kind": "room", "supplied_by_target": true}],
    });
    let got = validate_with(action.clone(), json!({"target": "room:Work"}));
    assert_eq!(got["request"]["target"], json!({"kind": "room", "id": "Work"}));
    let refused = validate_with(action, json!({}));
    assert_eq!(refused["error"]["id"], "missing_arguments");
}

#[test]
fn value_kinds_coerce_as_before() {
    let arg =
        |value: Value| request(json!({"args": {"title": value}}))["arguments"]["title"].clone();
    assert_eq!(arg(json!(5)), json!({"string": "5"}));
    assert_eq!(arg(json!(1.5)), json!({"string": "1.5"}));
    assert_eq!(arg(json!(true)), json!({"string": "true"}));
    assert_eq!(
        refusal(json!({"args": {"title": [1]}}))["args"],
        json!(["tab.rename", "title", "a string"])
    );

    let count = |value: Value| validate(json!({"args": {"title": "x", "count": value}}));
    assert_eq!(count(json!(2))["request"]["arguments"]["count"], json!({"int": 2}));
    assert_eq!(count(json!(" 4 "))["request"]["arguments"]["count"], json!({"int": 4}));
    assert_eq!(count(json!(2.0))["request"]["arguments"]["count"], json!({"int": 2}));
    assert_eq!(count(json!(2.5))["error"]["args"], json!(["tab.rename", "count", "an integer"]));
    assert_eq!(
        count(json!(9))["error"],
        json!({"id": "argument_expects", "args": ["tab.rename", "count", "an integer in 1...5"], "data": {"argument": "count"}})
    );

    let pinned = |value: Value| validate(json!({"args": {"title": "x", "pinned": value}}));
    for (given, flag) in [
        (json!("ON"), true),
        (json!("0"), false),
        (json!(1), true),
        (json!("no"), false),
        (json!(false), false),
    ] {
        assert_eq!(
            pinned(given.clone())["request"]["arguments"]["pinned"],
            json!({"bool": flag}),
            "{given}"
        );
    }
    assert_eq!(pinned(json!(" yes "))["error"]["args"][2], "true or false");
    assert_eq!(pinned(json!(2))["error"]["args"][2], "true or false");

    let mode = |value: Value| validate(json!({"args": {"title": "x", "mode": value}}));
    assert_eq!(mode(json!("RIGHT"))["request"]["arguments"]["mode"], json!({"string": "right"}));
    assert_eq!(mode(json!("up"))["error"]["args"][2], "one of Left, right");
    assert_eq!(mode(json!(1))["error"]["args"][2], "one of Left, right");
}

fn target(raw: Value, allowed: &[&str]) -> Value {
    let action = json!({"id": "x", "targets": allowed, "arguments": []});
    validate_with(action, json!({"target": raw}))
}

#[test]
fn target_forms() {
    let ok = |raw: Value, allowed: &[&str]| target(raw, allowed)["request"]["target"].clone();
    assert_eq!(ok(json!("tab:a:b"), &["tab"]), json!({"kind": "tab", "id": "a:b"}));
    assert_eq!(ok(json!(" tab_9 "), &["pane", "tab"]), json!({"kind": "tab", "id": "tab_9"}));
    assert_eq!(
        ok(json!("ws_1"), &["pane", "workspace"]),
        json!({"kind": "workspace", "id": "ws_1"})
    );
    assert_eq!(ok(json!("abc"), &["pane", "tab"]), json!({"kind": "pane", "id": "abc"}));
    // An unknown prefix is part of the id.
    assert_eq!(ok(json!("http://x"), &["tab"]), json!({"kind": "tab", "id": "http://x"}));
    assert_eq!(
        ok(json!({"kind": "WorkspaceGroup", "id": "g"}), &["workspace-group"]),
        json!({"kind": "workspace-group", "id": "g"})
    );
    assert_eq!(
        ok(json!("workspace_group:g"), &["workspace-group"]),
        json!({"kind": "workspace-group", "id": "g"})
    );
}

#[test]
fn target_refusals() {
    let error = |raw: Value, allowed: &[&str]| target(raw, allowed)["error"].clone();
    assert_eq!(error(json!("tab:"), &["tab"]), json!({"id": "target_id_empty", "args": []}));
    assert_eq!(
        error(json!({"kind": "tab"}), &["tab"]),
        json!({"id": "target_id_empty", "args": []})
    );
    assert_eq!(error(json!(3), &["tab"]), json!({"id": "target_shape", "args": []}));
    assert_eq!(error(json!("tab_1"), &[]), json!({"id": "no_target", "args": ["x"]}));
    assert_eq!(
        error(json!("workspace:w"), &["tab", "pane"]),
        json!({"id": "wrong_target_kind", "args": ["x", "tab|pane", "workspace"], "data": {"targets": ["tab", "pane"]}})
    );
}

#[test]
fn normalized_kind_folds_case_and_separators() {
    let kind = |text: &str| {
        call("control.normalized_kind", &json!({"kind": text})).unwrap()["kind"].clone()
    };
    assert_eq!(kind("Workspace_Group-X"), "workspacegroupx");
}

#[test]
fn a_bad_request_is_invalid() {
    assert!(call("control.validate", &json!({})).is_err());
    assert!(
        call("control.validate", &json!({"action": {"id": "x", "arguments": [{"name": "a"}]}}))
            .is_err()
    );
}
