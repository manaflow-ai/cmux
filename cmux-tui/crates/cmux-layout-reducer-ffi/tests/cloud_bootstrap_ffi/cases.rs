//! `cloud_bootstrap_*`, `cloud_machine_config_*`, `cloud_machine_step_outcome`, `cloud_create_*`
//! and `cloud_power_retries` through the C ABI, in the wire shapes the app decodes
//! (cmux-cloud-start-core holds the rules and their cases).

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

#[test]
fn the_facts_name_the_machines_paths() {
    let (code, facts) = call(c"cloud_bootstrap_facts", &json!({}));
    assert_eq!(code, OK);
    assert_eq!(facts["statusPath"], "/home/cmux/.cmux/bootstrap/status.json");
    assert_eq!(facts["logPath"], "/home/cmux/.cmux/bootstrap/bootstrap.log");
    assert_eq!(facts["configStatusPath"], "/home/cmux/.cmux/machine-config/status.json");
    assert_eq!(facts["configLogPath"], "/home/cmux/.cmux/machine-config/setup.log");
    assert_eq!(facts["maxBytes"], 1 << 20);
    assert_eq!(facts["configMaxBytes"], 64 * 1024);
    assert_eq!(facts["noScript"], "#!/bin/sh\nexit 0\n");
    assert!(facts["waitCommand"].as_str().unwrap().contains("cmux-wait"));
}

#[test]
fn a_start_plan_writes_then_starts() {
    let request = json!({"kind": "lane", "name": "n", "startId": "ab",
        "repo": {"owner": "o", "name": "r"}});
    let (code, plan) = call(c"cloud_bootstrap_start_plan", &request);
    assert_eq!(code, OK);
    let steps = plan["steps"].as_array().unwrap();
    assert_eq!(steps.len(), 7);
    assert_eq!(steps[0]["kind"], "exec");
    assert_eq!(
        steps[1],
        json!({"kind": "write", "path": "/home/cmux/.cmux/bootstrap/in-ab/script", "mode": 0o700, "payload": "script"})
    );
    assert_eq!(steps[6]["said"], json!(["started", "running", "skipped"]));
    assert_eq!(call(c"cloud_bootstrap_start_plan", &json!({})).0, ERR_INVALID);
}

#[test]
fn a_config_plan_carries_the_applier() {
    let (code, plan) = call(
        c"cloud_machine_config_plan",
        &json!({"uploaded": true, "nowMs": 9000, "nonce": "ABCDEF01"}),
    );
    assert_eq!(code, OK);
    let steps = plan["steps"].as_array().unwrap();
    assert_eq!(
        steps[1]["path"],
        "/home/cmux/.cmux/machine-config/requests/0000000009000-abcdef01.apply"
    );
    assert!(steps[1]["text"].as_str().unwrap().starts_with("#!/usr/bin/env python3\n"));
    assert_eq!(steps[2]["payload"], "config");
}

#[test]
fn an_exec_answer_goes_on_or_ends_the_plan() {
    let go_on =
        call(c"cloud_machine_step_outcome", &json!({"answer": {"exitCode": 0}, "said": []}));
    assert_eq!(go_on, (OK, json!({"outcome": null})));
    let started = call(
        c"cloud_machine_step_outcome",
        &json!({"answer": {"exitCode": 0, "stdout": "started\n"}, "said": ["started"]}),
    );
    assert_eq!(started.1, json!({"outcome": {"status": "started"}}));
    let failed = call(
        c"cloud_machine_step_outcome",
        &json!({"answer": {"exitCode": 1, "stderr": "no sudo"}}),
    );
    assert_eq!(failed.1, json!({"outcome": {"status": "failed", "reason": "no sudo"}}));
}

#[test]
fn a_wait_read_ends_or_counts() {
    let done = "cmux-wait free 1000\n{\"state\":\"done\",\"exit_code\":0,\"at\":990}\n";
    let (code, next) = call(
        c"cloud_bootstrap_wait_next",
        &json!({"answer": {"exitCode": 0, "stdout": done}, "failures": 2}),
    );
    assert_eq!(code, OK);
    assert_eq!(next, json!({"ended": {"run": "finished", "repoPath": null}, "failures": 2}));
    let (_, cut) =
        call(c"cloud_bootstrap_wait_next", &json!({"error": "timed out", "failures": 2}));
    assert_eq!(
        cut,
        json!({"failures": 3, "unreachable": {"run": "unreachable", "error": "timed out"}})
    );
}

#[test]
fn the_create_rules_answer() {
    let (_, refusal) =
        call(c"cloud_create_definitive_refusal", &json!({"code": "cmux.cloud.plan_required"}));
    assert_eq!(refusal, json!({"definitive": true}));
    let (_, team) =
        call(c"cloud_create_team", &json!({"current": "b", "wasSent": true, "first": "a"}));
    assert_eq!(team, json!({"team": null}));
    let (_, team) = call(c"cloud_create_team", &json!({"current": "b"}));
    assert_eq!(team, json!({"team": "b"}));
    let (_, retries) = call(
        c"cloud_power_retries",
        &json!({"code": "cmux.cloud.indeterminate", "attempt": 1, "attempts": 3}),
    );
    assert_eq!(retries, json!({"retries": true}));
}

#[test]
fn a_repo_spec_parses_or_says_why() {
    let (code, parsed) =
        call(c"cloud_machine_repo_parse", &json!({"spec": "https://gitlab.com/g/p@v1"}));
    assert_eq!(code, OK);
    assert_eq!(parsed["repo"]["owner"], "g");
    assert_eq!(parsed["repo"]["ref"], "v1");
    assert_eq!(parsed["repo"]["isGitHub"], false);
    assert!(parsed["repo"]["step"].as_str().unwrap().contains("host='gitlab.com'"));
    let (_, refused) =
        call(c"cloud_machine_repo_parse", &json!({"spec": "https://x:y@github.com/o/r"}));
    assert_eq!(refused, json!({"invalid": "credentialsInURL"}));
    let (_, described) = call(c"cloud_machine_repo_describe", &json!({"owner": "o", "name": "r"}));
    assert_eq!(described["spec"], "o/r");
    assert_eq!(described["url"], "https://github.com/o/r.git");
    let (_, is_ref) = call(c"cloud_machine_repo_is_ref", &json!({"ref": "a..b"}));
    assert_eq!(is_ref, json!({"isRef": false}));
}
