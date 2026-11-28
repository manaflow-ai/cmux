//! `app_agents_*` through the C ABI, in the wire shapes the app decodes
//! (cmux-app-agents holds the rules and their cases).

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};
use std::ffi::CStr;

fn call(operation: &CStr, request: &Value) -> (i32, Value) {
    let request = serde_json::to_vec(request).unwrap();
    let mut output = vec![0u8; 1 << 17];
    let mut len = 0usize;
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            operation.as_ptr(),
            output.as_mut_ptr(),
            output.len(),
            &mut len,
        )
    };
    let body =
        if code == OK { serde_json::from_slice(&output[..len]).unwrap() } else { Value::Null };
    (code, body)
}

fn ok(operation: &CStr, request: Value) -> Value {
    let (code, body) = call(operation, &request);
    assert_eq!(code, OK, "{operation:?} {request}");
    body
}

#[test]
fn subagent_params_read_set_and_clear() {
    assert_eq!(
        ok(c"app_agents_subagent_params", json!({"sessionId": "s"})),
        json!({"sessionId": "s"})
    );
    assert_eq!(
        ok(c"app_agents_subagent_params", json!({"sessionId": "s", "change": {"set": 4}})),
        json!({"sessionId": "s", "maxRunning": 4})
    );
    assert_eq!(
        ok(c"app_agents_subagent_params", json!({"sessionId": "s", "change": "useDefault"})),
        json!({"sessionId": "s", "maxRunning": null})
    );
}

#[test]
fn subagent_current_fills_the_dialog() {
    let own = ok(
        c"app_agents_subagent_current",
        json!({"reply": {"subsessionLimits": {"maxRunning": 3, "maxRunningSource": "session", "running": 2, "queued": 1}}, "setting": 8}),
    );
    assert_eq!(own["current"], json!({"own": 3, "effective": 3, "running": 2, "queued": 1}));
    assert_eq!(own["placeholder"], "3");
    assert_eq!(own["initial"], "3");
    assert_eq!(own["status"], json!({"running": 2, "queued": 1}));
    let none = ok(c"app_agents_subagent_current", json!({"reply": {}, "setting": 8}));
    assert_eq!(none["current"], Value::Null);
    assert_eq!(none["placeholder"], "8");
    assert_eq!(none["initial"], "");
    assert_eq!(none["status"], Value::Null);
}

#[test]
fn subagent_decide_every_answer() {
    let decide = |answer: Value| ok(c"app_agents_subagent_decide", json!({"answer": answer}));
    assert_eq!(
        decide(json!({"button": "set", "text": " 12 "})),
        json!({"decision": "set", "value": 12})
    );
    assert_eq!(decide(json!({"button": "set", "text": ""})), json!({"decision": "useDefault"}));
    assert_eq!(
        decide(json!({"button": "useDefault", "text": "7"})),
        json!({"decision": "useDefault"})
    );
    assert_eq!(decide(json!({"button": "set", "text": "0"})), json!({"decision": "invalid"}));
    assert_eq!(
        decide(json!({"button": "set", "text": "3", "dismissal": true})),
        json!({"decision": "cancelled"})
    );
    assert_eq!(decide(json!({"cancel": true})), json!({"decision": "cancelled"}));
    assert_eq!(
        ok(
            c"app_agents_subagent_decide",
            json!({"answer": {"button": "set", "text": "20"}, "max": 10})
        ),
        json!({"decision": "invalid"})
    );
}

#[test]
fn closed_rows_title_and_kind() {
    let rows = ok(
        c"app_agents_closed_rows",
        json!({"home": "/Users/me", "entries": [
            {"id": "old", "time": 1.0, "title": "/Users/me/a", "item": {"kind": "terminalTab", "cwd": "/Users/me/a"}},
            {"id": "visit", "time": 9.0, "title": "Visit"},
            {"id": "new", "time": 5.0, "title": "https://a.com/p", "item": {"kind": "browserTab", "url": "https://a.com/p"}},
        ]}),
    );
    assert_eq!(
        rows,
        json!([
            {"id": "new", "kind": "browser", "title": "a.com/p", "detail": "https://a.com/p"},
            {"id": "old", "kind": "terminal", "title": "a", "detail": "~/a"},
        ])
    );
    let limited = ok(
        c"app_agents_closed_rows",
        json!({"limit": 1, "entries": [
            {"id": "a", "time": 1.0, "title": "t", "item": {"kind": "screen"}},
            {"id": "b", "time": 2.0, "title": "t", "item": {"kind": "workspace"}},
        ]}),
    );
    assert_eq!(limited, json!([{"id": "b", "kind": "workspace", "title": "t", "detail": null}]));
    assert_eq!(
        ok(c"app_agents_closed_title", json!({"title": "https://x.io/", "url": "https://x.io/"})),
        json!("x.io")
    );
    assert_eq!(
        ok(c"app_agents_closed_kind", json!({"kind": "browserTab", "agentSession": true})),
        json!("agent")
    );
    assert_eq!(ok(c"app_agents_closed_kind", json!({"kind": "conversationTab"})), json!("agent"));
}

#[test]
fn new_tab_plans_through_the_abi() {
    assert_eq!(ok(c"app_agents_new_tab_plan", json!({})), json!({"plan": "page"}));
    assert_eq!(
        ok(c"app_agents_new_tab_plan", json!({"intent": {"kind": "terminal", "command": "ls"}})),
        json!({"plan": "terminal", "command": "ls"})
    );
    assert_eq!(
        ok(
            c"app_agents_new_tab_plan",
            json!({"intent": {"kind": "prompt", "text": "hi"}, "agent": "codex"})
        ),
        json!({"plan": "chat", "prompt": "hi", "harness": "codex"})
    );
    let terminal = ok(
        c"app_agents_new_tab_native",
        json!({"kind": "terminal", "text": " ls ", "search": false}),
    );
    assert_eq!(terminal["plans"], json!(false));
    assert_eq!(
        terminal["open"],
        json!({"kind": "terminal", "text": "ls", "search": false, "run": true})
    );
    let browser = ok(
        c"app_agents_new_tab_native",
        json!({"kind": "browser", "text": "x", "search": false, "plan": {"plan": "refused"}}),
    );
    assert_eq!(browser["plans"], json!(true));
    assert_eq!(browser["open"], Value::Null);
    let beside = ok(
        c"app_agents_new_tab_beside",
        json!({"plan": {"plan": "browser", "url": "https://a.com"}, "byPerson": true}),
    );
    assert!(beside.is_boolean());
}

#[test]
fn control_names_through_the_abi() {
    let names = ok(
        c"app_agents_control_names",
        json!({"defaults": [], "candidates": [{"isLocal": true}, {"machine": "box", "session": "dev", "ssh": true}]}),
    );
    assert_eq!(names.as_array().unwrap().len(), 2);
    assert_eq!(names[0]["transport"], "local");
    assert_eq!(names[1]["transport"], "ssh");
}

#[test]
fn apps_reach_and_refusal_through_the_abi() {
    let reach = ok(
        c"app_agents_apps_reaches",
        json!({"origin": "user", "apps": [{"presented": true}, {}]}),
    );
    assert_eq!(reach.as_array().unwrap().len(), 2);
    assert!(reach[0].is_boolean());
    let next = ok(
        c"app_agents_apps_after_refusal",
        json!({"refused": "bad-request", "families": ["files", "memory"]}),
    );
    assert_eq!(next, json!({"next": "register", "families": ["files"], "dropped": "memory"}));
    let stop =
        ok(c"app_agents_apps_after_refusal", json!({"refused": "denied", "families": ["files"]}));
    assert!(stop["next"].is_string());
}

#[test]
fn chat_keys_split_like_swift() {
    assert_eq!(
        ok(c"app_agents_chat_key", json!({"key": "codex:abc"})),
        json!({"harness": "codex", "session": "abc"})
    );
    assert_eq!(
        ok(c"app_agents_chat_key", json!({"key": ":abc"})),
        json!({"harness": "abc", "session": null})
    );
}

#[test]
fn bad_requests_are_invalid() {
    assert_eq!(call(c"app_agents_chat_key", &json!({})).0, ERR_INVALID);
    assert_eq!(call(c"app_agents_unknown", &json!({})).0, ERR_INVALID);
    assert_eq!(call(c"app_agents_closed_kind", &json!({"kind": "nope"})).0, ERR_INVALID);
}
