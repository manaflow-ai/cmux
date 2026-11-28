//! The automation ops end to end through [`crate::ops::call`].

use crate::ops::{OpError, call};
use serde_json::{Value, json};

fn waits_step(waits: &Value, mut body: Value) -> Value {
    if !waits.is_null() {
        body["waits"] = waits.clone();
    }
    call("browser_rules_automation_load_waits", body).unwrap()
}

#[test]
fn load_waits_op_carries_the_machine_between_calls() {
    let snap = waits_step(&Value::Null, json!({"do": "snapshot"}));
    let mut ticket = snap["ticket"].clone();
    ticket["navigation"] = json!(1);
    let reach =
        waits_step(&snap["waits"], json!({"do": "reach", "target": "load", "ticket": ticket}));
    assert_eq!(reach["reach"], json!({"kind": "pending", "wait": 0}));
    let started = waits_step(
        &reach["waits"],
        json!({"do": "navigationEvent", "event": {"kind": "started", "id": 1}}),
    );
    let done = waits_step(
        &started["waits"],
        json!({"do": "navigationEvent", "event": {"kind": "finished", "id": 1}}),
    );
    assert_eq!(done["resolved"], json!([{"wait": 0}]));
}

#[test]
fn simple_automation_ops() {
    let run = |op: &str, request: Value| {
        call(&format!("browser_rules_automation_{op}"), request).unwrap()
    };
    assert_eq!(run("load_state", json!({"name": "networkidle"})), json!("load"));
    assert_eq!(
        run("cookie_in_scope", json!({"domain": ".example.com", "host": "a.example.com"})),
        json!(true)
    );
    assert_eq!(run("backup_expired", json!({"expires": 5, "now": 6})), json!(true));
    assert_eq!(
        run("backup_file_name", json!({"restoreId": "x"})),
        json!({"error": "x is not an app cookie restore id (app:<32 hex>)"})
    );
    assert_eq!(
        run(
            "tab_url_changed",
            json!({"lastUrl": "https://a/", "url": "https://a/#f", "loading": true})
        ),
        json!({"lastUrl": "https://a/#f", "sameDocument": true})
    );
    assert_eq!(
        run("tab_process_exit_is_new", json!({"exit": {"r": 1}, "last": null})),
        json!(true)
    );
    assert!(matches!(call("browser_rules_automation_nope", json!({})), Err(OpError::UnknownOp(_))));
}

#[test]
fn driver_ops() {
    let run = |op: &str, request: Value| {
        call(&format!("browser_rules_automation_{op}"), request).unwrap()
    };
    let reads = json!([
        {"key": "selector", "read": "string"},
        {"key": "force", "read": "bool", "default": true},
        {"key": "missing", "read": "optionalNumber"},
        {"read": "timeout"},
    ]);
    assert_eq!(
        run(
            "driver_params",
            json!({"method": "page.click", "params": {"selector": "#a"}, "reads": reads})
        ),
        json!({"values": ["#a", true, null, 30000]})
    );
    assert_eq!(
        run(
            "driver_params",
            json!({"method": "page.click", "params": {}, "reads": [{"key": "selector", "read": "string"}]})
        ),
        json!({"error": "page.click: selector: expected a string"})
    );
    assert_eq!(
        run("call_deadline", json!({"what": "page.goto", "timeoutMs": 1500})),
        json!({"milliseconds": 1500, "message": "page.goto: Timeout 1.5 seconds exceeded"})
    );
    assert_eq!(
        run("tab_place", json!({"callerWorkspace": "w", "callerTerminal": "term_1"})),
        json!({"workspace": "w", "terminal": "term_1"})
    );
    assert_eq!(
        run(
            "frame_tree",
            json!({"root": {"frameId": "1", "url": "u", "children": [{"frameId": "2"}]}})
        ),
        json!([
            {"frameId": "1", "parentFrameId": null, "url": "u", "isMain": true},
            {"frameId": "2", "parentFrameId": "1", "url": "", "isMain": false},
        ])
    );
    assert_eq!(run("frame_tree", json!({})), json!([]));
}
