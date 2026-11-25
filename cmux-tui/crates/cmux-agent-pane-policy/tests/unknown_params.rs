//! P0, the strip before the params rule (`params::stripping_unknown_params`):
//! a key this host's lists do not name is dropped, not refused, so a page
//! newer than its host keeps its chats (cmux#46563: `initialize`
//! `_meta.acpmux.peerRowBatches`, refused 737 times on one NIGHTLY).

use cmux_agent_pane_policy::check::{Checked, FrameState, check_frame};
use cmux_agent_pane_policy::gesture::{Gesture, PermissionOptions};
use cmux_agent_pane_policy::params::{breaks_params_rule, stripping_unknown_params};
use serde_json::{Map, Value, json};
use std::collections::BTreeSet;
use std::path::Path;

fn object(v: Value) -> Map<String, Value> {
    v.as_object().cloned().unwrap()
}

fn strip(frame: Value, modes: &[&str]) -> Option<(Value, Vec<String>)> {
    let modes: BTreeSet<String> = modes.iter().map(|s| (*s).to_owned()).collect();
    stripping_unknown_params(&object(frame), Some(&modes)).map(|(o, d)| (Value::Object(o), d))
}

/// The incident's frame: a page that asks for peer row batches, and a key no
/// host knows yet, on the first frame. Both go; the chat opens.
#[test]
fn an_initialize_with_fields_the_host_never_heard_of_opens_the_chat() {
    let frame = json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": 1, "futureTopLevel": {"x": 1},
        "_meta": {"acpmux": {"peerRowBatches": true, "someFutureFlag": true}, "otherVendor": {}},
    }});
    let (stripped, dropped) = strip(frame.clone(), &[]).expect("a strip");
    assert_eq!(dropped, ["_meta.acpmux.someFutureFlag", "_meta.otherVendor", "futureTopLevel"]);
    assert!(!breaks_params_rule(stripped.as_object().unwrap(), None), "{stripped}");
    assert_eq!(stripped["params"]["_meta"]["acpmux"]["peerRowBatches"], true);

    let scope = cmux_agent_pane_policy::PaneSessions::new();
    let options = PermissionOptions::new();
    let state = FrameState {
        is_first: true,
        local_app_token: None,
        mode_fields: None,
        remote_wire: false,
        gesture: Gesture::None,
        scope: &scope,
        options: &options,
    };
    match check_frame(&frame.to_string(), &state) {
        Checked::Frame { frame, facts } => {
            assert!(frame["params"].get("futureTopLevel").is_none());
            assert_eq!(facts.dropped, dropped);
        }
        other => panic!("the first frame was refused: {other:?}"),
    }
}

/// An attach with a key from a newer page (`pinned`; cmux#42185 `settled`
/// and cmux#42460 `hold` once failed every chat's open this way).
#[test]
fn an_attach_with_a_newer_key_goes_without_it() {
    let frame = json!({"method": "_acpmux/attach", "params": {"sessionId": "s", "pinned": true}});
    let (stripped, dropped) = strip(frame, &[]).expect("a strip");
    assert_eq!(dropped, ["pinned"]);
    assert!(stripped["params"].get("pinned").is_none());
    assert_eq!(stripped["params"]["sessionId"], "s");
}

/// What the params rule refuses on purpose stays for it to refuse.
#[test]
fn what_the_rule_refuses_on_purpose_is_not_stripped() {
    // A daemon mode field outside the setting methods.
    let f = json!({"method": "session/new", "params": {"cwd": "/t", "mcpServers": [],
        "permissionMode": "bypassPermissions",
        "_meta": {"acpmux": {"permissionMode": "bypassPermissions"}}}});
    assert!(strip(f.clone(), &["permissionMode"]).is_none());
    assert!(breaks_params_rule(&object(f), Some(&BTreeSet::from(["permissionMode".to_owned()]))));
    // Shapes: params, _meta and _meta.acpmux that are not objects.
    for f in [
        json!({"method": "session/new", "params": ["x"]}),
        json!({"method": "session/new", "params": {"cwd": "/t", "_meta": 1}}),
        json!({"method": "session/new", "params": {"cwd": "/t", "_meta": {"acpmux": 1}}}),
    ] {
        let after = strip(f.clone(), &[]).map(|(o, _)| o).unwrap_or(f.clone());
        assert!(breaks_params_rule(&object(after), None), "{f}");
    }
    // A gesture redemption's _meta (R1) holds the ticket and nothing else.
    let f = json!({"method": "session/set_mode", "params": {"sessionId": "s", "modeId": "m",
        "_meta": {"cmuxGesture": "t", "other": 1}}});
    let after = strip(f.clone(), &[]).map(|(o, _)| o).unwrap_or(f);
    assert!(breaks_params_rule(&object(after), None));
    let f = json!({"method": "_acpmux/permission_respond", "params": {"sessionId": "s",
        "requestId": "r", "optionId": "o", "_meta": {"cmuxGesture": "t", "acpmux": {}}}});
    let after = strip(f.clone(), &[]).map(|(o, _)| o).unwrap_or(f);
    assert!(breaks_params_rule(&object(after), None));
}

/// Over every shared params case: a frame the rule passes goes unchanged, and
/// a frame it refuses is either refused after the strip too (a rule kept on
/// purpose) or passes with only keys removed, never one added or changed.
#[test]
fn the_strip_only_removes_and_never_touches_a_passing_frame() {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/cases/params.json");
    let cases: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    let (mut kept, mut stripped) = (0, 0);
    for c in cases.as_array().unwrap() {
        let modes: Option<BTreeSet<String>> = c["mode_fields"]
            .as_array()
            .map(|a| a.iter().map(|v| v.as_str().unwrap().to_owned()).collect());
        let frame = object(c["frame"].clone());
        let name = c["name"].as_str().unwrap();
        let out = stripping_unknown_params(&frame, modes.as_ref());
        if !c["breaks"].as_bool().unwrap() {
            assert!(out.is_none(), "{name}: a passing frame was changed: {out:?}");
            continue;
        }
        match out {
            None => kept += 1,
            Some((after, dropped)) => {
                assert!(!dropped.is_empty(), "{name}");
                assert!(subset(&Value::Object(after.clone()), &c["frame"]), "{name}: {after:?}");
                if breaks_params_rule(&after, modes.as_ref()) {
                    kept += 1;
                } else {
                    stripped += 1;
                }
            }
        }
    }
    // Both kinds are in the file: refusals kept on purpose and keys dropped.
    assert!(kept > 0 && stripped > 0, "kept {kept}, stripped {stripped}");
}

/// Whether `a` is `b` with only object keys removed.
fn subset(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Object(a), Value::Object(b)) => {
            a.iter().all(|(k, v)| b.get(k).is_some_and(|w| subset(v, w)))
        }
        _ => a == b,
    }
}

/// A request's W3C trace context (cmux#55505, one trace id per user action)
/// passes the strip and the params rule; a malformed one is refused, not
/// passed on to the daemon's trace.
#[test]
fn a_traceparent_rides_any_request_and_must_be_w3c_shaped() {
    let tp = "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01";
    let prompt = json!({"method": "session/prompt", "params": {
        "sessionId": "s", "prompt": [], "_meta": {"acpmux": {"promptId": "p"}, "traceparent": tp},
    }});
    assert!(strip(prompt.clone(), &[]).is_none(), "nothing to strip");
    assert!(!breaks_params_rule(prompt.as_object().unwrap(), None));
    let new =
        json!({"method": "session/new", "params": {"cwd": "/", "_meta": {"traceparent": tp}}});
    assert!(!breaks_params_rule(new.as_object().unwrap(), None));
    for bad in [json!("00-xyz-0123456789abcdef-01"), json!(7), json!(tp.to_uppercase())] {
        let frame =
            json!({"method": "session/new", "params": {"cwd": "/", "_meta": {"traceparent": bad}}});
        assert!(breaks_params_rule(frame.as_object().unwrap(), None), "{frame}");
    }
    // A ticket frame still carries nothing but its ticket (R1).
    let answer = json!({"method": "_acpmux/permission_respond", "params": {
        "sessionId": "s", "_meta": {"cmuxGesture": "t", "traceparent": tp},
    }});
    assert!(breaks_params_rule(answer.as_object().unwrap(), None));
}
