//! `cloud_move_*` through the C ABI: the shapes the app's Swift decodes (cmux-cloud-start-core
//! `moves` holds the rules and their cases).

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
    let (code, body) = call(operation, &request);
    assert_eq!(code, OK, "{operation:?}");
    body
}

#[test]
fn a_cli_answer_reads_with_the_apps_field_names() {
    let body = ok(
        c"cloud_move_cli_read",
        json!({"reading": "plain", "stdout": "{\"ok\":true,\"session_id\":\"s\",\"not_older\":true}\n", "stderr": "", "status": 0}),
    );
    assert_eq!(body["answer"]["ok"], true);
    assert_eq!(body["answer"]["sessionID"], "s");
    assert_eq!(body["answer"]["notOlder"], true);
    assert_eq!(body["answer"]["conflicts"], json!([]));
    let plan = ok(
        c"cloud_move_cli_read",
        json!({"reading": "start-chat-plan", "stdout": "{\"ok\":true,\"create_key\":\"c\",\"tab_key\":\"t\"}", "stderr": "", "status": 0}),
    );
    assert_eq!(plan["plan"]["createKey"], "c");
    assert_eq!(plan["plan"]["createSent"], false);
    let copy = ok(
        c"cloud_move_cli_read",
        json!({"reading": "start-chat-copy", "stdout": "", "stderr": "boom", "status": 1}),
    );
    assert_eq!(copy["answer"]["errorCode"], "bad_answer");
    assert_eq!(copy["copy"]["sourceTrusted"], false);
    let restarted = ok(
        c"cloud_move_restarted_daemon",
        json!({"ok": false, "errorCode": "machine_update_busy"}),
    );
    assert_eq!(restarted["restarted"], false);
}

#[test]
fn a_call_names_its_arguments() {
    let body = ok(
        c"cloud_move_cli_invocation",
        json!({"verb": "start-chat-create-sent", "key": "k", "account": "a", "team": "t", "createKey": "c"}),
    );
    assert_eq!(
        body["args"],
        json!([
            "link",
            "start-chat",
            "create-sent",
            "--key",
            "k",
            "--account",
            "a",
            "--team",
            "t",
            "--create-key",
            "c"
        ])
    );
    assert_eq!(body["timeoutSeconds"], Value::Null);
    assert_eq!(call(c"cloud_move_cli_invocation", &json!({"verb": "rm"})).0, ERR_INVALID);
}

#[test]
fn a_folder_is_read_from_this_disk() {
    let base = std::env::temp_dir().join(format!("cloud-move-ffi-{}", std::process::id()));
    std::fs::create_dir_all(base.join("app/.git")).unwrap();
    std::fs::create_dir_all(base.join("app/src/ui")).unwrap();
    let chat = base.join("app/src/ui");
    let body = ok(c"cloud_move_folder", json!({"chat": chat.to_str().unwrap()}));
    assert_eq!(body["folder"]["root"], base.join("app").to_str().unwrap());
    assert_eq!(body["folder"]["subpath"], "src/ui");
    assert_eq!(body["folder"]["git"], true);
    assert_eq!(ok(c"cloud_move_folder", json!({"chat": "relative"}))["folder"], Value::Null);
    std::fs::remove_dir_all(&base).unwrap();
}

#[test]
fn the_ledgers_round_trip_through_the_defaults_text() {
    let set = ok(
        c"cloud_move_retries",
        json!({"tab": "t1", "set": true, "retry": {"show": {"_0": {"session": "s", "machineID": "m", "folder": "/f", "key": "k"}}}}),
    );
    assert_eq!(set["changed"], true);
    let stored = set["stored"].as_str().unwrap().to_owned();
    let read = ok(c"cloud_move_retries", json!({"stored": stored}));
    assert_eq!(read["retries"]["t1"]["show"]["_0"]["machineID"], "m");
    let cleared = ok(c"cloud_move_retries", json!({"stored": stored, "tab": "t1", "set": true}));
    assert_eq!(cleared, json!({"changed": true, "stored": null}));

    let entry = json!({"machineID": "m", "host": "h", "session": "", "localRoot": "/l", "localChat": "/l", "remoteFolder": "/r", "remoteChat": "/r"});
    let copied = ok(c"cloud_move_moved_chats", json!({"action": "copied", "entry": entry}));
    let starting = copied["write"]["starting"]["value"].as_str().unwrap().to_owned();
    let started = ok(
        c"cloud_move_moved_chats",
        json!({"action": "started", "starting": starting, "host": "h", "session": "s", "remoteChat": "/r"}),
    );
    assert_eq!(started["started"], true);
    assert_eq!(started["write"]["starting"], json!({"value": null}));
    let moved = started["write"]["moved"]["value"].as_str().unwrap().to_owned();
    assert_eq!(
        ok(
            c"cloud_move_moved_chats",
            json!({"action": "entry", "moved": moved, "host": "h", "session": "s"})
        )["entry"]["session"],
        "s"
    );

    let scope =
        json!({"userID": "u", "teamID": "t", "cloudOrigin": "https://cmux.com", "folder": "/w"});
    let mut remember = scope.clone();
    remember["action"] = json!("remember");
    remember["always"] = json!(true);
    let stored = ok(c"cloud_move_grants", remember)["stored"].as_str().unwrap().to_owned();
    let mut contains = scope;
    contains["action"] = json!("contains");
    contains["stored"] = json!(stored);
    assert_eq!(ok(c"cloud_move_grants", contains)["granted"], true);
    assert_eq!(
        ok(c"cloud_move_grants", json!({"action": "scope", "userID": "u", "cloudOrigin": "o"}))["valid"],
        false
    );
}

#[test]
fn the_rest_answer_in_the_shapes_the_app_reads() {
    let seed = ok(
        c"cloud_move_seed_read",
        json!({"reader": {}, "line": "{\"progress\":{\"phase\":\"clone\",\"objects\":1}}", "nowMs": 5.0}),
    );
    assert_eq!(seed["progress"]["phase"], "clone");
    assert_eq!(seed["reader"]["phase"], "clone");
    let pick = ok(
        c"cloud_move_work_pick",
        json!({"folder": "/p", "names": ["package.json"], "text": "run tests"}),
    );
    assert_eq!(pick["taskKind"], "test");
    assert_eq!(pick["rootFiles"], json!(["package.json"]));
    assert_eq!(pick["repo"], Value::Null, "no remote names no repo");
    let github = ok(
        c"cloud_move_work_pick",
        json!({"folder": "/p", "top": "/p", "remote": "git@github.com:octo/paint.git",
               "upstream": "refs/heads/it's\u{0}\u{0}origin"}),
    );
    assert_eq!(github["repo"]["owner"], "octo");
    assert_eq!(github["repo"]["ref"], Value::Null, "an unquotable branch clones the default");
    assert_eq!(github["cloneRef"], Value::Null);
    assert_eq!(
        ok(c"cloud_move_autosize_body", json!({"taskKind": "build"}))["body"],
        json!({"taskKind": "build"})
    );
    assert_eq!(ok(c"cloud_move_deadlines", json!({}))["startRedialInitialMs"], 1000);
    assert_eq!(
        ok(c"cloud_move_start_redial", json!({"ended": true, "running": true, "redials": 0})),
        json!({"redial": "connect"})
    );
    assert_eq!(
        ok(c"cloud_move_start_redial", json!({"paused": true, "resumed": false})),
        json!({"redial": "resume"})
    );
    assert_eq!(ok(c"cloud_move_start_redial", json!({})), json!({"redial": "nothing"}));
    assert_eq!(
        ok(c"cloud_move_new_workspace_route", json!({"signedIn": false, "hasWindow": true})),
        json!({"route": "thisMac", "refusal": {"kind": "signedOut"}})
    );
    assert_eq!(
        ok(c"cloud_move_new_workspace_machine", json!({"named": "vm-1", "byPerson": false})),
        json!({"kind": "named", "id": "vm-1"})
    );
    assert_eq!(
        ok(c"cloud_move_new_workspace_machine", json!({"byPerson": false})),
        json!({"kind": "new"})
    );
    assert_eq!(
        ok(
            c"cloud_move_copy_step",
            json!({"ok": false, "errorCode": "machine_outdated", "last": true})
        ),
        json!({"step": "outdated"})
    );
    assert_eq!(ok(c"cloud_move_shell_quoted", json!({"text": "a b"}))["word"], "'a b'");
    let pin = ok(
        c"cloud_move_pin",
        json!({"answer": format!("{{\"ok\":true,\"commit\":\"{}\",\"sha256\":\"{}\",\"target\":\"x86_64-unknown-linux-musl\"}}", "e".repeat(40), "f".repeat(64))}),
    );
    assert_eq!(pin["bundled"], false);
    assert_eq!(pin["pin"]["commit"], "e".repeat(40));
    let legacy = ok(
        c"cloud_move_legacy_update",
        json!({"exitCode": 0, "stdout": "started\n", "stderr": "", "commit": "c"}),
    );
    assert_eq!(legacy["lastLine"], "started");
    assert_eq!(legacy["answer"]["errorCode"], "machine_update_failed");
}
