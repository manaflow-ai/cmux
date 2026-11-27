//! The C ABI the macOS app calls (src/ffi.rs, include/cmux_agent_pane_policy.h)
//! against the shared case corpus: every case of tests/cases/check.json runs
//! through `cmux_agent_pane_policy_check`, with the pane's state fed the way
//! the app feeds it (the `add` op for the sessions, daemon frames through
//! `cmux_agent_pane_policy_observe` for the permissions), and the reply must
//! be the case's `expect` exactly.

use cmux_agent_pane_policy::ffi::{
    CmuxAgentPaneBytes, CmuxAgentPanePolicy, ERR_INVALID, ERR_NULL, ERR_UNKNOWN_OP, NO_SHAPE, OK,
    cmux_agent_pane_policy_abi_version, cmux_agent_pane_policy_bytes_free,
    cmux_agent_pane_policy_call, cmux_agent_pane_policy_check,
    cmux_agent_pane_policy_check_gesture, cmux_agent_pane_policy_filter_reply,
    cmux_agent_pane_policy_free, cmux_agent_pane_policy_new, cmux_agent_pane_policy_observe,
};
use serde_json::{Value, json};
use std::collections::BTreeSet;
use std::ffi::CString;
use std::path::Path;

struct Handle(*mut CmuxAgentPanePolicy);

impl Drop for Handle {
    fn drop(&mut self) {
        unsafe { cmux_agent_pane_policy_free(self.0) };
    }
}

fn new() -> Handle {
    Handle(cmux_agent_pane_policy_new())
}

fn take(out: CmuxAgentPaneBytes) -> Vec<u8> {
    let bytes = if out.ptr.is_null() {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(out.ptr, out.len) }.to_vec()
    };
    unsafe { cmux_agent_pane_policy_bytes_free(out) };
    bytes
}

fn empty() -> CmuxAgentPaneBytes {
    CmuxAgentPaneBytes { ptr: std::ptr::null_mut(), len: 0 }
}

fn call(pane: *const CmuxAgentPanePolicy, op: &str, request: Value) -> Result<Value, i32> {
    let op = CString::new(op).unwrap();
    let request = serde_json::to_vec(&request).unwrap();
    let mut out = empty();
    let code = unsafe {
        cmux_agent_pane_policy_call(pane, op.as_ptr(), request.as_ptr(), request.len(), &mut out)
    };
    if code != OK {
        assert!(out.ptr.is_null(), "an error writes nothing");
        return Err(code);
    }
    Ok(serde_json::from_slice(&take(out)).unwrap())
}

fn observe(pane: &Handle, frame: &Value, reply_to: Option<&str>) {
    let text = frame.to_string();
    let (ptr, len) = reply_to.map_or((std::ptr::null(), 0), |r| (r.as_ptr(), r.len()));
    let code = unsafe {
        cmux_agent_pane_policy_observe(pane.0, text.as_ptr(), text.len(), ptr, len, false)
    };
    assert_eq!(code, OK);
}

fn check(
    pane: &Handle,
    text: &str,
    first: bool,
    remote: bool,
    token: Option<&str>,
    modes: Option<&Value>,
) -> Value {
    let (token_ptr, token_len) = token.map_or((std::ptr::null(), 0), |t| (t.as_ptr(), t.len()));
    let modes = modes.map(Value::to_string);
    let (modes_ptr, modes_len) =
        modes.as_deref().map_or((std::ptr::null(), 0), |m| (m.as_ptr(), m.len()));
    let mut out = empty();
    let code = unsafe {
        cmux_agent_pane_policy_check(
            pane.0,
            text.as_ptr(),
            text.len(),
            first,
            remote,
            token_ptr,
            token_len,
            modes_ptr,
            modes_len,
            &mut out,
        )
    };
    assert_eq!(code, OK, "check of {text}");
    serde_json::from_slice(&take(out)).unwrap()
}

/// A check of a later frame on this Mac with the gesture number the host
/// names (0 none, 1 key, 2 click): the reply, or the error code.
fn check_gesture(pane: &Handle, text: &str, gesture: u8) -> Result<Value, i32> {
    let mut out = empty();
    let code = unsafe {
        cmux_agent_pane_policy_check_gesture(
            pane.0,
            text.as_ptr(),
            text.len(),
            false,
            false,
            gesture,
            std::ptr::null(),
            0,
            std::ptr::null(),
            0,
            &mut out,
        )
    };
    if code != OK {
        assert!(out.ptr.is_null(), "an error writes nothing");
        return Err(code);
    }
    Ok(serde_json::from_slice(&take(out)).unwrap())
}

/// The pending permission frame a case's `denies` and `questions` stand for
/// (the same frames tests/parity.rs feeds `PermissionOptions` directly).
fn feed_permissions(pane: &Handle, case: &Value) {
    let s = &case["state"];
    let questions: BTreeSet<&str> = s["questions"]
        .as_array()
        .map(|a| a.iter().map(|q| q.as_str().unwrap()).collect())
        .unwrap_or_default();
    let denies = s["denies"].as_array().unwrap();
    for d in denies.iter().filter(|d| !questions.contains(d[0].as_str().unwrap())) {
        observe(
            pane,
            &json!({"jsonrpc": "2.0", "method": "_acpmux/permission_pending", "params": {
            "permissionId": d[0], "request": {"options": [{"optionId": d[1], "kind": "reject_once"}]}}}),
            None,
        );
    }
    for q in &questions {
        let mut listed = vec![json!({"optionId": "allow_once", "kind": "allow_once"})];
        for d in denies.iter().filter(|d| d[0] == *q) {
            listed.push(json!({"optionId": d[1], "kind": "reject_once"}));
        }
        let keys: Vec<String> = case["text"]
            .as_str()
            .and_then(|text| serde_json::from_str::<Value>(text).ok())
            .and_then(|frame| {
                frame["params"]["answers"].as_object().map(|a| a.keys().cloned().collect())
            })
            .unwrap_or_default();
        let items: Vec<Value> = keys.iter().map(|key| json!({"id": key})).collect();
        observe(
            pane,
            &json!({"jsonrpc": "2.0", "method": "_acpmux/permission_pending", "params": {
            "permissionId": q, "request": {"options": listed,
                "toolCall": {"_meta": {"acpmux": {"question": {"items": items}}}}}}}),
            None,
        );
    }
}

#[test]
fn c_abi_runs_the_check_corpus() {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/cases/check.json");
    let cases: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    let cases = cases.as_array().unwrap();
    assert_eq!(cases.len(), 76, "check.json: every case runs here too");
    for case in cases {
        let pane = new();
        let s = &case["state"];
        for session in s["sessions"].as_array().unwrap() {
            call(pane.0, "add", json!({"session": session})).unwrap();
        }
        feed_permissions(&pane, case);
        let modes = s.get("mode_fields").filter(|m| !m.is_null());
        // A case that names the person's gesture (state `gesture`) runs
        // through the check with a gesture; the others through the check
        // without one, as a host that never learned the click rule calls it.
        let got = match s.get("gesture").map(|g| g.as_str().unwrap()) {
            None => check(
                &pane,
                case["text"].as_str().unwrap(),
                s["first"].as_bool().unwrap(),
                s.get("remote_wire").and_then(Value::as_bool).unwrap_or(false),
                s["token"].as_str(),
                modes,
            ),
            Some(name) => {
                let number = match name {
                    "key" => 1,
                    "click" => 2,
                    other => panic!("{}: no gesture {other}", case["name"]),
                };
                assert!(
                    !s["first"].as_bool().unwrap() && modes.is_none() && s["token"].is_null(),
                    "{}: a gesture case is a later frame with no token or mode fields",
                    case["name"]
                );
                check_gesture(&pane, case["text"].as_str().unwrap(), number).unwrap()
            }
        };
        assert_eq!(got, case["expect"], "{}", case["name"]);
    }
}

/// The click rule through the C ABI: the check without a gesture argument
/// (the only check before ABI 3) refuses an answer, so does a key press, and
/// only a click passes it.
#[test]
fn c_abi_a_click_only_answer_passes_on_a_click_only() {
    assert_eq!(cmux_agent_pane_policy_abi_version(), 3);
    let pane = new();
    call(pane.0, "add", json!({"session": "s1"})).unwrap();
    let frames = [
        r#"{"jsonrpc":"2.0","id":5,"method":"_acpmux/presets","params":{"name":"night","approveMode":true,"approveDigest":"sha256:ab","sessionId":"s1"}}"#,
        r#"{"jsonrpc":"2.0","id":5,"method":"_acpmux/plan/build","params":{"sessionId":"s1","permissionId":"p1","target":"compare"}}"#,
        r#"{"jsonrpc":"2.0","id":5,"method":"_acpmux/permission_respond","params":{"sessionId":"s1","permissionId":"p1","optionId":"yes"}}"#,
        r#"{"jsonrpc":"2.0","id":5,"method":"_acpmux/permission_group_respond","params":{"sessionId":"s1","groupId":"g1","revision":1,"decisionKey":"k","decision":"allow_once"}}"#,
    ];
    for frame in frames {
        let old = check(&pane, frame, false, false, None, None);
        assert_eq!(old["refuse"], "transport.gesture_required", "no gesture argument: {frame}");
        assert_eq!(old["id"], "5", "{frame}");
        for gesture in [0, 1] {
            let got = check_gesture(&pane, frame, gesture).unwrap();
            assert_eq!(got["refuse"], "transport.gesture_required", "gesture {gesture}: {frame}");
        }
        let got = check_gesture(&pane, frame, 2).unwrap();
        assert_eq!(got["facts"]["needs_click"], true, "a click: {frame}");
        assert_eq!(got["facts"]["needs_gesture"], true, "a click: {frame}");
        // A number that is no gesture is an error: the host refuses the frame.
        assert_eq!(check_gesture(&pane, frame, 3), Err(ERR_INVALID), "{frame}");
        assert_eq!(check_gesture(&pane, frame, 255), Err(ERR_INVALID), "{frame}");
    }
    // The host reads the list and the window from the same data.
    let p = call(std::ptr::null(), "policy", json!({})).unwrap();
    assert_eq!(
        p["click_only"],
        json!([
            "_acpmux/permission_group_respond",
            "_acpmux/permission_respond",
            "_acpmux/plan/build",
            "_acpmux/presets"
        ])
    );
    assert_eq!(p["click_window_ms"], 1500);
    // The refusal frame for the page takes the new code.
    let refusal = call(
        std::ptr::null(),
        "refusal_frame",
        json!({"id": "5", "code": "transport.gesture_required", "method": "_acpmux/presets"}),
    )
    .unwrap();
    let refusal: Value = serde_json::from_str(refusal["frame"].as_str().unwrap()).unwrap();
    assert_eq!(refusal["error"]["data"]["code"], "transport.gesture_required");
}

#[test]
fn c_abi_a_started_session_joins_the_scope_when_its_reply_comes() {
    let pane = new();
    let p = pane.0;
    assert_eq!(call(p, "is_unstarted", json!({})).unwrap(), json!({"unstarted": true}));
    call(p, "sent", json!({"method": "session/new", "id": "7"})).unwrap();
    assert_eq!(call(p, "is_unstarted", json!({})).unwrap(), json!({"unstarted": false}));
    let prompt = r#"{"jsonrpc":"2.0","id":8,"method":"session/prompt","params":{"sessionId":"s9","prompt":[]}}"#;
    assert_eq!(
        check(&pane, prompt, false, false, None, None)["refuse"],
        "transport.session_not_in_pane"
    );
    observe(
        &pane,
        &json!({"jsonrpc": "2.0", "id": 7, "result": {"sessionId": "s9"}}),
        Some("session/new"),
    );
    assert_eq!(call(p, "contains", json!({"session": "s9"})).unwrap(), json!({"contains": true}));
    assert!(check(&pane, prompt, false, false, None, None).get("frame").is_some());
}

#[test]
fn c_abi_a_remote_wires_watch_reply_brings_the_tab_session_in() {
    let pane = new();
    let reply =
        json!({"jsonrpc": "2.0", "id": 3, "result": {"tabSessionId": "remote-1"}}).to_string();
    let watch = "_acpmux/watch";
    // A local wire learns nothing from it.
    let code = unsafe {
        cmux_agent_pane_policy_observe(
            pane.0,
            reply.as_ptr(),
            reply.len(),
            watch.as_ptr(),
            watch.len(),
            false,
        )
    };
    assert_eq!(code, OK);
    assert_eq!(
        call(pane.0, "contains", json!({"session": "remote-1"})).unwrap()["contains"],
        false
    );
    let code = unsafe {
        cmux_agent_pane_policy_observe(
            pane.0,
            reply.as_ptr(),
            reply.len(),
            watch.as_ptr(),
            watch.len(),
            true,
        )
    };
    assert_eq!(code, OK);
    assert_eq!(call(pane.0, "contains", json!({"session": "remote-1"})).unwrap()["contains"], true);
}

#[test]
fn c_abi_the_permission_ops_read_what_the_daemon_sent() {
    let pane = new();
    observe(
        &pane,
        &json!({"jsonrpc": "2.0", "method": "_acpmux/permission_pending", "params": {
        "permissionId": "p1", "request": {"options": [{"optionId": "no", "kind": "reject_once"}],
            "toolCall": {"_meta": {"acpmux": {"question": {"items": [{"id": "q1", "prompt": "Which?"}]}}}}}}}),
        None,
    );
    let deny = |option: &str| {
        call(pane.0, "is_deny", json!({"permission": "p1", "option": option})).unwrap()
    };
    assert_eq!(deny("no"), json!({"deny": true}));
    assert_eq!(deny("yes"), json!({"deny": false}));
    assert_eq!(
        call(pane.0, "question_keys", json!({"permission": "p1"})).unwrap(),
        json!({"keys": ["Which?", "q1"]})
    );
    assert_eq!(
        call(pane.0, "question_keys", json!({"permission": "p2"})).unwrap(),
        json!({"keys": null})
    );
}

#[test]
fn c_abi_the_ops_without_a_pane() {
    let none = std::ptr::null();
    let p = call(none, "policy", json!({})).unwrap();
    assert_eq!(p["initialize"], "initialize");
    assert_eq!(p["maximum_frame_bytes"], 32 << 20);
    assert_eq!(p["question_answers"]["maximum_items"], 64);
    assert!(p["reply_shape_methods"].as_array().unwrap().contains(&json!("_acpmux/status")));
    assert_eq!(call(none, "raw_id", json!({"value": "a/b"})).unwrap(), json!({"id": r#""a\/b""#}));
    assert_eq!(call(none, "raw_id", json!({"value": true})).unwrap(), json!({"id": null}));
    let frame = call(
        none,
        "refusal_frame",
        json!({"id": "4", "code": "transport.method_refused", "method": "x"}),
    )
    .unwrap();
    let frame: Value = serde_json::from_str(frame["frame"].as_str().unwrap()).unwrap();
    assert_eq!(frame["id"], 4);
    assert_eq!(frame["error"]["data"]["code"], "transport.method_refused");
    // The folder keys the host's disk check walks.
    assert!(p["path_keys"].as_array().unwrap().contains(&json!("cwd")));
    // A prompt's own id: one hand-off turn's label off, an id under two labels as it is.
    let own = |id: &str| call(none, "own_prompt_id", json!({"id": id})).unwrap();
    assert_eq!(own("handoff-3-p1"), json!({"id": "p1"}));
    assert_eq!(own("handoff-1-handoff-2-x"), json!({"id": "handoff-1-handoff-2-x"}));
    assert_eq!(own("p1"), json!({"id": "p1"}));
    // The pane's own ops need a pane.
    assert_eq!(call(none, "add", json!({"session": "s"})), Err(ERR_NULL));
    assert_eq!(
        call(none, "is_known_allow", json!({"permission": "p", "option": "o"})),
        Err(ERR_NULL)
    );
}

/// The pick a gesture ticket is bound to, asked without a frame check (the
/// host redeems a ticket for a page op such as `cloud.startChat`, and holds a
/// click's intent by the same values): every case of tests/cases/picks.json
/// through the `pick` op, and each digest in them through `canonical_digest`.
#[test]
fn c_abi_runs_the_pick_corpus() {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/cases/picks.json");
    let cases: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    let cases = cases.as_array().unwrap();
    assert!(!cases.is_empty(), "picks.json holds no cases");
    let none = std::ptr::null();
    let mut digests = 0;
    for case in cases {
        let name = &case["name"];
        let request = json!({"method": case["method"], "params": case["params"]});
        let got = call(none, "pick", request).unwrap();
        assert_eq!(got["pick"]["method"], case["pick"]["method"], "{name} method");
        assert_eq!(got["pick"]["params"], case["pick"]["params"], "{name} params");
        // A click's intent holds a question's answers and annotations by this digest.
        for key in ["answers", "annotations"] {
            let value = &case["params"][key];
            let want = &case["pick"]["params"][key];
            if value.is_object() && want.is_string() {
                let got = call(none, "canonical_digest", json!({"value": value})).unwrap();
                assert_eq!(got, json!({"digest": want}), "{name} {key}");
                digests += 1;
            }
        }
    }
    assert!(digests > 0, "picks.json holds no digest");
    // A value with no canonical form has no digest.
    assert_eq!(
        call(none, "canonical_digest", json!({"value": {"q": 1.5}})).unwrap(),
        json!({"digest": null})
    );
    assert_eq!(call(none, "canonical_digest", json!({})), Err(ERR_INVALID));
    assert_eq!(call(none, "pick", json!({"method": 1})), Err(ERR_INVALID));
    assert_eq!(call(none, "pick", json!({"method": "m", "params": []})), Err(ERR_INVALID));
}

/// The host reserves a permission answer's ticket only for an option the
/// daemon offered as an allow (Swift `AcpmuxPermissionOptions.isKnownAllow`).
#[test]
fn c_abi_a_known_allow_is_an_option_the_daemon_offered_as_one() {
    let pane = new();
    let pending = |options: Value| {
        json!({"jsonrpc": "2.0", "method": "_acpmux/permission_pending", "params": {
        "permissionId": "p1", "request": {"options": options}}})
    };
    observe(
        &pane,
        &pending(json!([
            {"optionId": "yes", "kind": "allow_once"},
            {"optionId": "no", "kind": "reject_once"},
        ])),
        None,
    );
    let allow = |permission: &str, option: &str| {
        call(pane.0, "is_known_allow", json!({"permission": permission, "option": option})).unwrap()
    };
    assert_eq!(allow("p1", "yes"), json!({"allow": true}));
    assert_eq!(allow("p1", "no"), json!({"allow": false}));
    // An option the pane never saw is no known allow, and no known deny.
    assert_eq!(allow("p1", "other"), json!({"allow": false}));
    assert_eq!(allow("p2", "yes"), json!({"allow": false}));
    assert_eq!(
        call(pane.0, "is_deny", json!({"permission": "p1", "option": "other"})).unwrap(),
        json!({"deny": false})
    );
    // An option seen with two kinds counts as allow.
    observe(&pane, &pending(json!([{"optionId": "no", "kind": "allow_always"}])), None);
    assert_eq!(allow("p1", "no"), json!({"allow": true}));
    assert_eq!(call(pane.0, "is_known_allow", json!({"permission": "p1"})), Err(ERR_INVALID));
}

/// A refusal the host words itself (a refused Enable harness): acpmux's own
/// reason as `detail`, cut to 1000 characters, and why as the `reason` code.
#[test]
fn c_abi_a_refusal_carries_the_hosts_detail_and_reason() {
    let none = std::ptr::null();
    let data = |extra: Value| {
        let mut request = json!({"id": "4", "code": "transport.harness_not_confirmed",
            "method": "_acpmux/harness_enable"});
        request.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
        let reply = call(none, "refusal_frame", request).unwrap();
        let frame: Value = serde_json::from_str(reply["frame"].as_str().unwrap()).unwrap();
        frame["error"]["data"].clone()
    };
    let plain = json!({"code": "transport.harness_not_confirmed", "origin": "native",
        "method": "_acpmux/harness_enable"});
    assert_eq!(data(json!({})), plain);
    assert_eq!(
        data(json!({"detail": "no such harness", "reason": "harness_gone"})),
        json!({"code": "transport.harness_not_confirmed", "origin": "native",
            "method": "_acpmux/harness_enable", "detail": "no such harness",
            "reason": "harness_gone"})
    );
    // An empty detail is no detail.
    assert_eq!(data(json!({"detail": ""})), plain);
    assert_eq!(data(json!({"detail": "é".repeat(1200)}))["detail"], json!("é".repeat(1000)));
}

#[test]
fn c_abi_bad_input_is_an_error_and_writes_nothing() {
    let pane = new();
    assert_eq!(call(pane.0, "no_such_op", json!({})), Err(ERR_UNKNOWN_OP));
    assert_eq!(call(pane.0, "add", json!({})), Err(ERR_INVALID));
    assert_eq!(
        call(pane.0, "refusal_frame", json!({"id": "1", "code": "not.a.code"})),
        Err(ERR_INVALID)
    );
    // Text that is not UTF-8, and mode fields that are not a list of strings.
    let bad = [0xffu8, 0xfe];
    let modes = br#"{"mode":1}"#;
    let text = br#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#;
    let mut out = empty();
    let code = unsafe {
        cmux_agent_pane_policy_check(
            pane.0,
            bad.as_ptr(),
            bad.len(),
            true,
            false,
            std::ptr::null(),
            0,
            std::ptr::null(),
            0,
            &mut out,
        )
    };
    assert_eq!(code, ERR_INVALID);
    let code = unsafe {
        cmux_agent_pane_policy_check(
            pane.0,
            text.as_ptr(),
            text.len(),
            true,
            false,
            std::ptr::null(),
            0,
            modes.as_ptr(),
            modes.len(),
            &mut out,
        )
    };
    assert_eq!(code, ERR_INVALID);
    assert!(out.ptr.is_null());
    let code = unsafe {
        cmux_agent_pane_policy_check(
            std::ptr::null(),
            text.as_ptr(),
            text.len(),
            true,
            false,
            std::ptr::null(),
            0,
            std::ptr::null(),
            0,
            &mut out,
        )
    };
    assert_eq!(code, ERR_NULL);
}

#[test]
fn c_abi_a_reply_is_cut_to_its_shape() {
    let mut out = empty();
    let method = "_acpmux/peers";
    let reply = json!({"jsonrpc": "2.0", "id": 90, "result": {"peers": [{"name": "m1", "secret": "x"}], "other": 1}})
        .to_string();
    let page_id = "5";
    let code = unsafe {
        cmux_agent_pane_policy_filter_reply(
            method.as_ptr(),
            method.len(),
            reply.as_ptr(),
            reply.len(),
            page_id.as_ptr(),
            page_id.len(),
            &mut out,
        )
    };
    assert_eq!(code, OK);
    let filtered: Value = serde_json::from_slice(&take(out)).unwrap();
    assert_eq!(filtered["id"], 5);
    assert!(!filtered.to_string().contains("secret"), "{filtered}");
    let none = "session/prompt";
    let mut out = empty();
    let code = unsafe {
        cmux_agent_pane_policy_filter_reply(
            none.as_ptr(),
            none.len(),
            reply.as_ptr(),
            reply.len(),
            page_id.as_ptr(),
            page_id.len(),
            &mut out,
        )
    };
    assert_eq!(code, NO_SHAPE);
    assert!(out.ptr.is_null());
}
