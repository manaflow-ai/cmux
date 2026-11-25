//! `cloud_handler_*` through the C ABI: the app sends its facts and acts on the
//! answer (cmux-cloud-handlers holds the rules and their cases).

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};
use std::ffi::CStr;

fn call(operation: &CStr, request: &[u8]) -> (i32, Value) {
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
    let (code, body) = call(operation, &serde_json::to_vec(&request).unwrap());
    assert_eq!(code, OK, "{operation:?}");
    body
}

#[test]
fn an_argument_check_answers_its_value_or_its_refusal() {
    assert_eq!(
        ok(c"cloud_handler_arg", json!({"check": "port", "args": {"port": 3000}})),
        json!({"value": 3000})
    );
    assert_eq!(
        ok(
            c"cloud_handler_arg",
            json!({"check": "namedPort", "verb": "port-close", "args": {},
                   "names": {"name": "box", "id": "vm-1"}})
        ),
        json!({"refusal": {"key": "portInvalid", "args": ["box", "vm-1", "port-close"]}})
    );
    assert_eq!(
        ok(
            c"cloud_handler_arg",
            json!({"check": "id", "missing": "publicationRequired", "args": {"path": " r1 "}})
        ),
        json!({"value": "r1"})
    );
    assert_eq!(
        ok(
            c"cloud_handler_arg",
            json!({"check": "idlePause", "choices": [0, 15, 30], "args": {"minutes": "off"}})
        ),
        json!({"value": 0})
    );
    assert_eq!(
        ok(c"cloud_handler_arg", json!({"check": "snapshot", "args": {}})),
        json!({"refusal": {"key": "snapshotRequired"}})
    );
}

#[test]
fn new_machine_options_parse_into_one_request() {
    let body = ok(
        c"cloud_handler_arg",
        json!({"check": "newMachine", "home": "/Users/me",
               "args": {"name": "lane-vm-1", "size": "medium", "bootstrap": "lane", "bootstrapScript": "~/boot.sh"}}),
    );
    assert_eq!(
        body,
        json!({"value": {"name": "lane-vm-1", "size": "medium", "memoryMb": 8192, "persistent": false,
               "bootstrapPath": "/Users/me/boot.sh", "bootstrapKind": "lane", "machineConfigPath": null, "repo": null}})
    );
    let request = body["value"].clone();
    let fields = ok(c"cloud_handler_new_machine_fields", json!({"request": request}));
    assert_eq!(fields["fields"]["cpu"], json!(4));
}

#[test]
fn a_named_machine_that_is_not_there_is_not_found() {
    assert_eq!(
        ok(c"cloud_handler_machine_pick", json!({"named": "vm-9"})),
        json!({"refusal": {"key": "unknownMachine", "args": ["vm-9"], "kind": "not_found"}})
    );
    assert_eq!(
        ok(c"cloud_handler_machine_pick", json!({"byUser": true, "cloudCount": 1})),
        json!({"pick": "only"})
    );
}

#[test]
fn decisions_answer_their_route() {
    assert_eq!(
        ok(c"cloud_handler_new_workspace", json!({"byUser": true, "hasWindow": true})),
        json!({"route": "setup"})
    );
    assert_eq!(
        ok(c"cloud_handler_new_machine_start", json!({"isDefault": false})),
        json!({"start": "requested"})
    );
    assert_eq!(
        ok(c"cloud_handler_setup_readiness", json!({"listed": true})),
        json!({"readiness": "waiting"})
    );
    assert_eq!(
        ok(c"cloud_handler_creation", json!({"listed": true, "failed": true})),
        json!({"state": "failed"})
    );
    assert_eq!(
        ok(
            c"cloud_handler_team",
            json!({"teams": [{"id": "t1", "name": "Mine"}], "active": "t2", "team": "Mine"})
        ),
        json!({"select": "t1"})
    );
}

#[test]
fn a_settled_create_answers_fields_or_a_failure() {
    assert_eq!(
        ok(c"cloud_handler_settled", json!({"state": "failed", "reason": "cap", "plan": "pro"})),
        json!({"failure": {"reason": {"key": "text", "args": ["new Cloud machine: cap (plan: pro)"]},
               "code": "cloud.plan.required", "refusal": false}})
    );
    assert_eq!(
        ok(c"cloud_handler_settled", json!({"creationId": "c-1"})),
        json!({"fields": {"pending": true, "status": "creating", "creation_id": "c-1"}})
    );
}

#[test]
fn answers_and_fields_shape_through_the_abi() {
    let answer =
        ok(c"cloud_handler_answer", json!({"kind": "filesList", "path": "/w", "entries": []}));
    assert_eq!(
        answer,
        json!({"text": "(empty)", "copyable": true, "fields": {"path": "/w", "count": 0}})
    );
    let status = ok(
        c"cloud_handler_status",
        json!({"status": {"machineId": "vm-1", "title": "box", "status": "running", "state": "running"}}),
    );
    assert_eq!(status["text"], json!("box (vm-1)\nstate: running, status: running"));
    assert_eq!(
        ok(c"cloud_handler_machine_fields", json!({"machineId": "vm-1", "extra": {"name": "n"}})),
        json!({"fields": {"name": "n", "machine_id": "vm-1", "target": "machine:vm-1"}})
    );
    assert_eq!(
        ok(c"cloud_handler_template_name", json!({"machineId": "vm-1", "unix": 7})),
        json!({"name": "template-vm-1-7"})
    );
    let names = json!({"name": "box", "id": "vm-1", "port": 3000});
    assert_eq!(
        ok(c"cloud_handler_share_link", json!({"url": "https://[::1", "names": names})),
        json!({"ok": false, "refusal": {"key": "portFailed",
               "args": ["box", "vm-1", "3000", "the platform returned an invalid share URL"]}})
    );
    assert_eq!(
        ok(c"cloud_handler_share_link", json!({"url": "https://s.dev/l"})),
        json!({"ok": true, "refusal": null})
    );
    assert_eq!(
        ok(c"cloud_handler_forward", json!({"record": {"port": 1}, "names": names})),
        json!({"refusal": {"key": "portFailed", "args": ["box", "vm-1", "3000", "no local port"]}})
    );
    let no_link = json!({"refusal": {"key": "portNoLink", "args": ["box", "vm-1", "3000"]}});
    assert_eq!(ok(c"cloud_handler_machine_link_port", json!({"names": names})), no_link);
    assert_eq!(
        ok(c"cloud_handler_machine_link", json!({"names": names, "allowsPorts": true})),
        no_link
    );
    assert_eq!(
        ok(c"cloud_handler_machine_link_port", json!({"names": names, "allowsPorts": true})),
        json!({})
    );
    assert_eq!(
        ok(c"cloud_handler_port_failure", json!({"code": "cmux.cloud.port_limit", "names": names})),
        json!({"refusal": {"key": "portLimit", "args": ["box", "vm-1", "3000"]}})
    );
    assert_eq!(
        ok(c"cloud_handler_github_confirm", json!({"name": "Ada", "app": "notConnected"})),
        json!({"parts": [{"key": "gitHubFallbackNotConnected"},
                         {"key": "gitHubConfirmBody", "args": ["Ada", "—"]}]})
    );
    assert_eq!(
        ok(c"cloud_handler_arg", json!({"check": "resize", "args": {"disk": 8}}))["value"]["diskGib"],
        json!(8)
    );
    let constants = ok(c"cloud_handler_constants", json!({}));
    assert_eq!(constants["createSizes"]["xlarge"], json!({"cpu": 12, "memoryMb": 24576}));
    assert_eq!(constants["resizeSizes"]["xlarge"], json!({"cpu": 16, "memoryMb": 24576}));
}

#[test]
fn unknown_ops_and_bad_json_are_refused() {
    assert_eq!(call(c"cloud_handler_nope", b"{}").0, ERR_INVALID);
    assert_eq!(call(c"cloud_handler_arg", b"not json").0, ERR_INVALID);
    assert_eq!(
        call(c"cloud_handler_arg", br#"{"check":"id","missing":"other","args":{}}"#).0,
        ERR_INVALID
    );
}
