//! `cloud_state_*` through the C ABI: the app sends a state and one action, keeps the state the
//! answer returns and runs the effects it lists (cmux-cloud-start-core's `app_state` holds the
//! rules and their cases).

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};
use std::ffi::CStr;

fn call(operation: &CStr, request: &Value) -> (i32, Value) {
    let request = serde_json::to_vec(request).unwrap();
    let mut output = vec![0u8; 1 << 14];
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
    let (code, reply) = call(operation, &request);
    assert_eq!(code, OK, "{operation:?} {request}");
    reply
}

#[test]
fn a_creation_starts_shown_fails_and_retries() {
    let creation =
        ok(c"cloud_state_creation_new", json!({"id": "c1", "windowId": "w1", "nowMs": 10}));
    let creation = creation["creation"].clone();
    assert_eq!(creation["phase"], json!({"phase": "requesting"}));
    let reply =
        ok(c"cloud_state_creations", json!({"action": {"do": "start", "creation": creation}}));
    assert_eq!(reply["shown"], json!({"clearPage": true, "cloudCreation": "c1"}));
    let creations = reply["creations"].clone();
    let reply = ok(
        c"cloud_state_creations",
        json!({"creations": creations, "action": {"do": "runEnded", "id": "c1", "taskCancelled": false,
            "startedByPerson": true, "error": {"error": "failed", "message": "no",
            "source": {"kind": "appServerPlanRequired", "plan": "max"}}}}),
    );
    assert_eq!(reply["runEnd"]["end"], "failed");
    assert_eq!(reply["runEnd"]["offer"]["plan"], "max");
    assert!(reply["runEnd"].get("lingerMs").is_none(), "a window shows it");
    let creations = reply["creations"].clone();
    assert_eq!(creations["all"][0]["phase"]["phase"], "failed");
    let reply = ok(
        c"cloud_state_creations",
        json!({"creations": creations, "action": {"do": "retry", "id": "c1", "nowMs": 50}}),
    );
    assert_eq!(reply["effects"]["cancelRun"], true);
    assert_eq!(reply["creations"]["all"][0]["startedAtMs"], 50);
    let reply = ok(
        c"cloud_state_creations",
        json!({"creations": reply["creations"], "action": {"do": "dismiss", "id": "c1", "shown": "c1"}}),
    );
    assert_eq!(reply["clearWindow"], true);
    assert_eq!(reply["creations"]["all"], json!([]));
}

#[test]
fn an_unknown_creation_or_a_bad_action_says_so() {
    let reply = ok(
        c"cloud_state_creations",
        json!({"action": {"do": "apply", "id": "x", "event": {"event": "tearDown"}}}),
    );
    assert_eq!(reply["missing"], true);
    assert_eq!(call(c"cloud_state_creations", &json!({"action": {"do": "fly"}})).0, ERR_INVALID);
    assert_eq!(call(c"cloud_state_nothing", &json!({})).0, ERR_INVALID);
}

#[test]
fn a_bootstrap_end_reads_as_a_completion() {
    let reply = ok(
        c"cloud_state_completion",
        json!({"run": {"run": "finished", "repoPath": "/home/cmux/work/x"}}),
    );
    assert_eq!(reply["completion"], json!({"end": "finished", "repoPath": "/home/cmux/work/x"}));
    let reply = ok(c"cloud_state_completion", json!({"run": {"run": "runnerNeverCame"}}));
    assert_eq!(reply["completion"]["reason"]["why"], "runnerNeverCame");
}

#[test]
fn the_run_and_its_scope() {
    assert_eq!(
        ok(c"cloud_state_run_plan", json!({"hasSession": false, "needsBootstrap": true})),
        json!({"create": true, "bootstrap": true})
    );
    let holds = ok(c"cloud_state_scope_holds", json!({"expectedUser": "u", "currentUser": "u"}));
    assert_eq!(holds["holds"], true);
    assert_eq!(ok(c"cloud_state_scope_holds", json!({}))["holds"], false);
}

#[test]
fn a_continuation_resumes_once() {
    let reply = ok(c"cloud_state_continuation", json!({"action": {"do": "reserve"}}));
    let expected = reply["expected"].clone();
    assert_eq!(reply["pending"], true);
    let reply = ok(
        c"cloud_state_continuation",
        json!({"continuation": reply["continuation"], "action": {"do": "begin", "expected": expected}}),
    );
    assert_eq!(reply["go"], true);
    let reply = ok(
        c"cloud_state_continuation",
        json!({"continuation": reply["continuation"], "action": {"do": "finish", "expected": expected, "succeeded": true}}),
    );
    assert_eq!(reply["signedIn"], "resume");
    assert_eq!(reply["pending"], false);
}

#[test]
fn a_front_is_kept_and_its_mac_tab_closing_ends_it() {
    let mac = json!({"machine": "local", "key": "mac-tab"});
    let front = json!({"machine": "vm-1", "key": "cloud-tab", "workspace": "cloud-ws"});
    let reply =
        ok(c"cloud_state_fronted", json!({"action": {"do": "hold", "workspace": "cloud-ws"}}));
    assert_eq!(reply["workspaceIds"], json!(["cloud-ws"]));
    assert_eq!(reply["persisted"], Value::Null);
    let reply = ok(
        c"cloud_state_fronted",
        json!({"fronted": reply["fronted"], "action": {"do": "front", "mac": mac, "front": front}}),
    );
    assert_eq!(reply["persisted"], json!([{"machine": "local", "key": "mac-tab", "front": front}]));
    let reply = ok(
        c"cloud_state_fronted",
        json!({"fronted": reply["fronted"], "action": {"do": "gone", "tab": mac}}),
    );
    assert_eq!(reply["gone"], json!({"do": "closeCloud", "front": front}));
    assert_eq!(reply["persisted"], Value::Null);
}

#[test]
fn a_failing_revoke_backs_off() {
    let chat = json!({"machineId": "m", "session": "s"});
    let reply = ok(c"cloud_state_revokes", json!({"action": {"do": "add", "chat": chat}}));
    assert_eq!(reply["empty"], false);
    let reply = ok(
        c"cloud_state_revokes",
        json!({"revokes": reply["revokes"], "action": {"do": "runStarted", "chat": chat}}),
    );
    let reply = ok(
        c"cloud_state_revokes",
        json!({"revokes": reply["revokes"], "action": {"do": "runEnded", "chat": chat, "ok": false, "nowMs": 0}}),
    );
    let revokes = reply["revokes"].clone();
    let reply = ok(
        c"cloud_state_revokes",
        json!({"revokes": revokes, "action": {"do": "mayRun", "chat": chat, "nowMs": 2_999}}),
    );
    assert_eq!(reply["mayRun"], false);
    let reply = ok(
        c"cloud_state_revokes",
        json!({"revokes": revokes, "action": {"do": "due", "nowMs": 3_000}}),
    );
    assert_eq!(reply["due"], json!([chat]));
}

#[test]
fn asks_triage_and_cards() {
    let reply = ok(
        c"cloud_state_asks",
        json!({"action": {"do": "machine", "machineId": "m", "nowMs": 0, "syncMs": 60_000}}),
    );
    assert_eq!(reply["machine"], json!({"do": "triage", "sync": true}));
    let reply = ok(
        c"cloud_state_asks",
        json!({"asks": reply["asks"], "action": {"do": "triageFailed", "machineId": "m", "code": "access_request.unavailable", "nowMs": 0, "pollMs": 3_000}}),
    );
    assert_eq!(reply["delayMs"], 600_000);
    let reply = ok(
        c"cloud_state_asks",
        json!({"asks": reply["asks"], "action": {"do": "answerStarted", "id": "r2"}}),
    );
    let reply = ok(
        c"cloud_state_asks",
        json!({"asks": reply["asks"], "action": {"do": "cards", "listed": [{"id": "r1", "live": true}, {"id": "r2", "live": true}], "failures": ["f1"]}}),
    );
    assert_eq!(reply["cards"], json!(["r1", "f1"]));
    let poll = ok(
        c"cloud_state_poll",
        json!({"hasCli": true, "movedChats": 0, "revokesEmpty": false, "pollMs": 3_000}),
    );
    assert_eq!(poll, json!({"do": "clear", "waitMs": 3_000}));
    assert_eq!(
        ok(c"cloud_state_answer_failure_shows", json!({"ok": false, "code": "request_gone"}))["shows"],
        false
    );
    assert_eq!(
        ok(c"cloud_state_constants", json!({}))["frontedDefaultsKey"],
        "cmux.cloud.frontedChats"
    );
}
