//! `cloud_hybrid_*` through the C ABI: the app sends the start's state, one event and its clock,
//! and runs the effects the answer lists (cmux-cloud-start-core `hybrid` holds the rules).

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

fn step(state: &Value, event: Value, now: u64) -> Value {
    let (code, reply) =
        call(c"cloud_hybrid_step", &json!({"state": state, "event": event, "now": now}));
    assert_eq!(code, OK);
    reply
}

#[test]
fn a_pro_account_gets_it_and_another_plan_hears_why_not() {
    let pro = json!({"plan": "next_pro", "signedIn": true});
    assert_eq!(call(c"cloud_hybrid_enabled", &pro), (OK, json!({"enabled": true})));
    let plus = json!({"plan": "next_plus", "signedIn": true});
    assert_eq!(
        call(c"cloud_hybrid_enabled", &plus),
        (OK, json!({"enabled": false, "off": "plan"}))
    );
    let flagged = json!({"plan": "next_pro", "signedIn": true, "flag": false});
    assert_eq!(call(c"cloud_hybrid_enabled", &flagged).1["off"], "flag");
    assert_eq!(call(c"cloud_hybrid_enabled", &json!({"plan": "next_pro"})).1["off"], "no-cloud");
}

#[test]
fn a_start_answers_here_at_once_and_goes_on_on_its_machine() {
    let begun = step(&Value::Null, json!({"on": "begin"}), 0);
    assert_eq!(
        begun["effects"],
        json!([
            {"do": "startHere"},
            {"do": "createMachine"},
            {"do": "show", "cloud": "booting"}
        ])
    );
    let first = step(&begun["state"], json!({"on": "prompt", "id": "p1"}), 1);
    assert_eq!(first["effects"], json!([{"do": "deliver", "id": "p1", "to": "here"}]));
    let running = step(&first["state"], json!({"on": "turnStarted"}), 2);
    let ready = step(&running["state"], json!({"on": "machineReady"}), 4_000);
    assert_eq!(ready["state"]["cloud"], "ready");
    let moving = step(&ready["state"], json!({"on": "turnEnded"}), 5_000);
    assert_eq!(moving["effects"][1], json!({"do": "move"}));
    let held = step(&moving["state"], json!({"on": "prompt", "id": "p2"}), 5_100);
    assert_eq!(held["effects"], json!([{"do": "hold", "id": "p2"}]));
    let live = step(&held["state"], json!({"on": "moveCommitted"}), 5_600);
    assert_eq!(live["state"]["home"], "cloud");
    assert_eq!(
        live["effects"],
        json!([
            {"do": "log", "line": "hybrid start step: live 5600 ms"},
            {"do": "show", "cloud": "live"},
            {"do": "deliver", "id": "p2", "to": "cloud"}
        ])
    );
}

#[test]
fn an_unknown_op_or_event_is_invalid() {
    assert_eq!(call(c"cloud_hybrid_nothing", &json!({})).0, ERR_INVALID);
    let bad = json!({"event": {"on": "nothing"}, "now": 0});
    assert_eq!(call(c"cloud_hybrid_step", &bad).0, ERR_INVALID);
}
