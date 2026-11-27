//! `cloud_machine_*` and `cloud_model_*` through the C ABI: the app sends a server's answer or
//! its records and acts on the answer (cmux-cloud-machine holds the rules and their cases).

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

fn machine(record: Value) -> Value {
    let (code, body) = call(c"cloud_model_read", &json!({"kind": "machine_next", "value": record}));
    assert_eq!(code, OK);
    body["value"].clone()
}

#[test]
fn a_next_record_reads_into_the_apps_json_and_its_facts() {
    let record = machine(
        json!({"id": "vm_aaaaaaaaaaaaaaaaaaaa", "status": "running", "name": "fs-lane", "desktop": true, "creator": "u1"}),
    );
    assert_eq!(record["provider"], "cmux-next");
    assert_eq!(record["displayName"], "fs-lane");
    assert_eq!(record["servesDesktop"], true);
    let (code, facts) = call(c"cloud_machine_facts", &json!({"machine": record, "user": "u1"}));
    assert_eq!(code, OK);
    assert_eq!(facts["agentInfrastructure"], true);
    assert_eq!(facts["desktopViewer"], "rd");
    assert_eq!(facts["humanName"], "fs-lane");
    assert_eq!(facts["capabilities"]["desktop"], true);
    assert_eq!(facts["allowed"].as_array().unwrap().len(), 10);
}

#[test]
fn a_classic_record_that_is_malformed_answers_why() {
    let (code, body) =
        call(c"cloud_model_read", &json!({"kind": "machine_classic", "value": {"id": 42}}));
    assert_eq!(code, OK);
    assert!(body["error"].is_string());
    assert!(body.get("value").is_none());
}

#[test]
fn the_status_table_names_live_and_changing() {
    let (code, body) = call(c"cloud_machine_statuses", &json!({}));
    assert_eq!(code, OK);
    assert_eq!(body["live"], json!(["provisioning", "running", "starting"]));
    assert_eq!(body["changing"], json!(["pausing", "starting", "deleting"]));
    assert_eq!(body["operations"][9], "persistentHome");
}

#[test]
fn the_overlay_round_trips_its_state() {
    let baseline = machine(json!({"id": "vm_a", "status": "running"}));
    let (_, begun) = call(
        c"cloud_machine_changes_begin",
        &json!({"machine": "vm_a", "change": "pausing", "id": "M1", "baseline": baseline}),
    );
    assert_eq!(begun["shown"], json!({"pendingChange": "pausing", "pendingMutationID": "M1"}));
    let (_, returned) = call(
        c"cloud_machine_changes_returned",
        &json!({"state": begun["state"], "machine": "vm_a", "id": "M1"}),
    );
    let (_, stale) = call(
        c"cloud_machine_changes_apply",
        &json!({"state": returned["state"], "record": baseline}),
    );
    assert_eq!(stale["record"]["pendingChange"], "pausing");
    let paused = machine(json!({"id": "vm_a", "status": "paused"}));
    let (_, settled) = call(
        c"cloud_machine_changes_apply",
        &json!({"state": stale["state"], "record": paused, "read": 3}),
    );
    assert_eq!(settled["record"]["pendingChange"], Value::Null);
    assert_eq!(settled["state"]["latestIssuedRead"], 3);
    let (_, unsettled) = call(
        c"cloud_machine_changes_unsettled",
        &json!({"state": settled["state"], "list": [paused]}),
    );
    assert_eq!(unsettled["machines"], json!([]));
}

#[test]
fn the_read_order_round_trips_its_state() {
    let (code, list) = call(c"cloud_machine_reads_begin", &json!({}));
    assert_eq!(code, OK);
    assert_eq!(list["read"], 1);
    let (_, status) =
        call(c"cloud_machine_reads_begin", &json!({"state": list["state"], "machine": "vm_a"}));
    assert_eq!(status["read"], 2);
    let (_, omitted) = call(
        c"cloud_machine_reads_listed",
        &json!({"state": status["state"], "machines": ["vm_c"], "held": ["vm_a"], "read": 1}),
    );
    assert_eq!(omitted["add"], json!(["vm_c"]));
    assert_eq!(omitted["removals"], json!([]), "a newer read of vm_a holds the removal");
    assert_eq!(omitted["state"]["deferred"], json!({"vm_a": 1}));
    let (_, stale) = call(
        c"cloud_machine_reads_admit",
        &json!({"state": omitted["state"], "machine": "vm_b", "read": 1}),
    );
    assert_eq!(stale["admitted"], true);
    let (_, finished) =
        call(c"cloud_machine_reads_finish", &json!({"state": stale["state"], "read": 2}));
    assert_eq!(finished["removals"], json!(["vm_a"]), "the failed read released it");
    assert_eq!(finished["idle"], true);
    let (_, again) = call(
        c"cloud_machine_reads_admit",
        &json!({"state": finished["state"], "machine": "vm_a", "read": 1}),
    );
    assert_eq!(again["admitted"], false, "the omission's list is vm_a's read now");
    let (_, removed) =
        call(c"cloud_machine_reads_removed", &json!({"state": again["state"], "machine": "vm_a"}));
    assert_eq!(removed["state"]["deferred"], json!({}));
}

#[test]
fn a_push_frame_says_what_to_show() {
    let id = "vm_aaaaaaaaaaaaaaaaaaaa";
    let text = json!({"t": "state", "machine": id, "state": {"record": {"id": id, "status": "paused", "revision": "4"}}}).to_string();
    let (code, body) = call(c"cloud_machine_push_frame", &json!({"machine": id, "text": text}));
    assert_eq!(code, OK);
    assert_eq!(body["action"], "state");
    assert_eq!(body["record"]["status"], "paused");
    assert_eq!(body["forward"]["t"], "state");
    let (_, url) =
        call(c"cloud_machine_push_url", &json!({"base": "https://p.invalid", "machine": id}));
    assert_eq!(url["url"], format!("wss://p.invalid/v1/cloud/machines/{id}/state"));
}

#[test]
fn an_api_error_reads_and_words_itself() {
    let body = json!({"error": "vm_busy", "message": "Busy.", "traceId": "t1"}).to_string();
    let (code, error) = call(c"cloud_model_api_error", &json!({"status": 409, "body": body}));
    assert_eq!(code, OK);
    assert_eq!(error["error"]["http"]["code"], "vm_busy");
    let (_, text) = call(
        c"cloud_model_api_error_text",
        &json!({"error": error["error"], "traceFormat": "(trace %@)"}),
    );
    assert_eq!(text, json!({"text": "Busy. (trace t1)", "code": "vm_busy"}));
}

#[test]
fn a_malformed_request_is_refused() {
    assert_eq!(call(c"cloud_machine_facts", &json!({})).0, ERR_INVALID);
    assert_eq!(call(c"cloud_machine_nope", &json!({})).0, ERR_INVALID);
}

#[test]
fn a_classic_record_reads_with_the_swift_keys() {
    let (code, body) = call(
        c"cloud_model_read",
        &json!({"kind": "machine_classic", "value": {"id": "vm-1", "status": "running", "capabilities": {"exec": true}, "error": {"code": "x", "message": "y"}}}),
    );
    assert_eq!(code, OK);
    assert_eq!(body["value"]["capabilities"]["exec"], true);
    assert_eq!(body["value"]["error"]["code"], "x");
}

#[test]
fn an_unsafe_scp_route_answers_why_and_no_route() {
    let route = json!({"host": "h", "port": 2222, "username": "cmux", "hostPublicKey": "ssh-ed25519 A", "expiresAtUnix": 4_000_000_000_i64});
    let (code, body) = call(c"cloud_model_read", &json!({"kind": "scp_endpoint", "value": route}));
    assert_eq!(code, OK);
    assert!(body["error"].is_string());
    assert!(body.get("value").is_none());
}

#[test]
fn the_server_shaped_models_read_over_the_channel() {
    for (kind, value) in [
        ("machine_stats", json!({"state": "paused"})),
        (
            "machine_previews",
            json!({"machine": "vm_1", "previews": [], "listening": [], "unavailable": []}),
        ),
        ("preview_share_link_revocation", json!({"revoked": false})),
    ] {
        let (code, body) = call(c"cloud_model_read", &json!({"kind": kind, "value": value}));
        assert_eq!(code, OK);
        assert!(body.get("value").is_some(), "{kind}: {body}");
    }
}

#[test]
fn a_preview_url_with_no_path_opens_the_root() {
    let url = "https://p.invalid";
    let (code, bare) = call(c"cloud_model_preview_url", &json!({"url": url}));
    assert_eq!(code, OK);
    let (code, root) = call(c"cloud_model_preview_url", &json!({"url": url, "path": "/"}));
    assert_eq!(code, OK);
    assert_eq!(bare, root);
    assert_eq!(bare["url"], url);
    let (code, deep) = call(c"cloud_model_preview_url", &json!({"url": url, "path": "/x"}));
    assert_eq!(code, OK);
    assert_eq!(deep["url"], "https://p.invalid?return_to=/x");
}

#[test]
fn github_setup_checks_the_identity_builds_the_script_and_reads_the_answer() {
    let (code, body) =
        call(c"cloud_model_github_setup_validate", &json!({"name": "Ann Lee\n", "email": "\n"}));
    assert_eq!(code, OK);
    assert_eq!(body, json!({"identity": {"name": "Ann Lee"}}));
    let (_, body) = call(c"cloud_model_github_setup_validate", &json!({"name": "Ann\u{1B}[31m"}));
    assert_eq!(body, json!({"refused": "unsafe"}));
    let (_, body) = call(c"cloud_model_github_setup_validate", &json!({}));
    assert_eq!(body, json!({"identity": {}}));

    let (code, body) = call(
        c"cloud_model_github_setup_command",
        &json!({"identity": {"name": "O'Brien"}, "app": true}),
    );
    assert_eq!(code, OK);
    assert_eq!(body["timeoutMs"], 25_000);
    let command = body["command"].as_str().unwrap();
    assert!(command.contains(r"git config --global user.name 'O'\''Brien'"));
    assert!(command.contains("cmux github setup"));
    let (_, plain) = call(c"cloud_model_github_setup_command", &json!({}));
    assert!(!plain["command"].as_str().unwrap().contains("cmux github setup"));
    assert!(plain["command"].as_str().unwrap().contains("echo 'cmux-git: skipped'"));

    let (code, body) = call(
        c"cloud_model_github_setup_read",
        &json!({"exitCode": 0, "stdout": "cmux-git: set\ncmux-app: unavailable\ncmux-gh: pending AB12-CD34\n",
                "app": "ready", "identity": {"name": "Ann"}}),
    );
    assert_eq!(code, OK);
    assert_eq!(
        body,
        json!({
            "outcome": {"identity": "set", "gitHub": "pending", "deviceCode": "AB12-CD34", "appNotOnMachine": true},
            "ok": true,
            "fallback": "not_on_machine",
            "fields": {"ok": true, "method": "device", "gh_status": "pending", "fallback_reason": "not_on_machine",
                       "user_name": "Ann", "device_code": "AB12-CD34",
                       "verification_uri": "https://github.com/login/device"},
        })
    );
    let (_, body) = call(
        c"cloud_model_github_setup_read",
        &json!({"exitCode": 0, "stdout": "cmux-git: skipped\ncmux-gh: app\n", "app": "ready"}),
    );
    assert_eq!(body["fallback"], Value::Null);
    assert_eq!(body["fields"], json!({"ok": true, "method": "app", "gh_status": "app"}));
    let (_, body) =
        call(c"cloud_model_github_setup_read", &json!({"exitCode": 124, "app": "needs_reauth"}));
    assert_eq!(
        body["outcome"],
        json!({"identity": "failed", "gitHub": "failed", "appNotOnMachine": false})
    );
    assert_eq!(body["fallback"], "not_connected");
    assert_eq!(
        call(c"cloud_model_github_setup_read", &json!({"exitCode": 0, "app": "bogus"})).0,
        ERR_INVALID
    );
}
