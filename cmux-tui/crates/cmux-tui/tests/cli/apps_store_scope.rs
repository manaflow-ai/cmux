//! Request context reaches the current owner before any idempotency replay.
use super::*;

/// `cmux.host.link.get` answers the hub socket from the link agent's
/// registration (`<daemon state dir>/link.json`) while that link runs.
#[test]
fn host_link_get_answers_from_the_link_registration() {
    // A running link: a live pid (this test) that serves the socket.
    let (reply, hub) = host_link_get("link", |state, hub| {
        cmux_link::registration::write(
            state,
            &cmux_link::registration::Registration::new(hub.to_path_buf(), std::process::id()),
        )
        .unwrap();
    });
    assert_eq!(reply["value"]["hub_socket"], json!(hub), "{reply}");
}

fn write_scope_app(apps: &Apps) {
    write_script(
        &apps.dir.join("servers/scope-probe"),
        r#"#!/usr/bin/python3
import json, sys
sent = 0
cache = {}
for line in sys.stdin:
    request = json.loads(line)
    if request.get("type") == "scope.probe":
        print(json.dumps({"type": "scope.ready", "id": request["id"]}), flush=True)
        continue
    if request.get("type") != "op":
        continue
    with open(sys.argv[1], "a") as calls:
        calls.write(line)
    scope = request.get("expected_scope")
    with open(sys.argv[2]) as current:
        active = current.read()
    if scope is not None and scope != active:
        print(json.dumps({"type": "result", "id": request["id"], "ok": False, "error": {"code": "credential.session_changed", "message": "scope changed"}}), flush=True)
        continue
    key = (scope, request.get("idempotency_key"))
    if scope is not None and key in cache:
        result = cache[key]
    else:
        sent += 1
        result = {"scope": scope, "sent": sent}
        if scope is not None:
            cache[key] = result
    print(json.dumps({"type": "result", "id": request["id"], "ok": True, "result": result, "expected_scope": request.get("expected_scope")}), flush=True)
"#,
    );
    std::fs::write(apps.dir.join("scope-current"), "a".repeat(64)).unwrap();
    let app = apps.dir.join("first-party/scope");
    std::fs::create_dir_all(&app).unwrap();
    let catalog = json!({"family": "scope", "operations": [{
        "name": "scope.write", "owner": "app:cmux/scope", "class": "mutation", "risk": "mutate-own",
        "idempotency": "required", "input": {"type": "object"}, "docs": "d", "since": "scope/1"
    }]});
    std::fs::write(app.join("catalog.json"), catalog.to_string()).unwrap();
    write_app(
        &apps.dir.join("first-party"),
        "cmux",
        "scope",
        json!({
            "catalog": "catalog.json", "files": ["catalog.json"], "scopes": {"scope:write": "Write."},
            "server": {"kind": "native", "binaries": {
                "darwin-arm64": "scope-probe", "darwin-x64": "scope-probe",
                "linux-arm64": "scope-probe", "linux-x64": "scope-probe"
            }, "instances": "machine", "hosts": ["local"], "lifecycle": {"start": "onDemand"},
            "args": [apps.dir.join("scope-ops.jsonl").to_string_lossy(), apps.dir.join("scope-current").to_string_lossy()]}
        }),
    );
}

#[test]
fn cloud_scope_real_daemon_forwards_context_and_separates_replay() {
    let apps = Apps::new("scope");
    write_scope_app(&apps);
    apps.start();
    let mut app = apps.app();
    // This must succeed before the new command: a fixture/setup failure is not regression proof.
    let control = app.rpc(json!({"cmd": "apps-run", "app": "cmux/scope", "op": "scope.write",
        "args": {}, "idempotency_key": "control", "origin": "user"}));
    assert_eq!(ok(&control)["value"]["sent"], 1, "{control}");
    let first = "a".repeat(64);
    let second = "b".repeat(64);
    for (scope, sent) in [(&first, 2), (&second, 3), (&second, 3)] {
        std::fs::write(apps.dir.join("scope-current"), scope).unwrap();
        let reply = app.rpc(json!({"cmd": "apps-run-scoped", "app": "cmux/scope", "op": "scope.write",
            "args": {}, "idempotency_key": "same-intent", "origin": "user", "expected_scope": scope}));
        assert_eq!(ok(&reply)["value"], json!({"scope": scope, "sent": sent}), "{reply}");
    }
    let stale = app.rpc(json!({"cmd": "apps-run-scoped", "app": "cmux/scope", "op": "scope.write",
        "args": {}, "idempotency_key": "same-intent", "origin": "user", "expected_scope": first}));
    assert_eq!(
        error_code(&stale),
        "credential.session_changed",
        "cached results must reach the current owner: {stale}"
    );
    let invalid = app.rpc(json!({"cmd": "apps-run-scoped", "app": "cmux/scope", "op": "scope.write",
        "args": {}, "idempotency_key": "invalid", "origin": "user", "expected_scope": "not-a-scope"}));
    assert_eq!(invalid["ok"], false, "{invalid}");
}

#[test]
fn cloud_scope_credential_servers_always_reach_their_own_session_gate() {
    let apps = Apps::new("credential-scope");
    write_scope_app(&apps);
    let path = apps.dir.join("first-party/scope/cmux-app.v2.json");
    let mut manifest: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    manifest["server"]["scopes"] =
        json!({"op:cmux.credential.relay": "Use the parent's current session."});
    std::fs::write(path, manifest.to_string()).unwrap();
    apps.start();
    let mut app = apps.app();
    for sent in 1..=2 {
        let reply = app.rpc(json!({"cmd": "apps-run", "app": "cmux/scope", "op": "scope.write",
            "args": {}, "idempotency_key": "same-intent", "origin": "user"}));
        assert_eq!(
            ok(&reply)["value"]["sent"],
            sent,
            "the server must recheck its parent before replay: {reply}"
        );
    }
}

#[test]
fn cloud_scope_an_older_server_cannot_return_an_unscoped_cached_success() {
    let apps = Apps::new("old-scope-server");
    write_scope_app(&apps);
    let path = apps.dir.join("servers/scope-probe");
    let source = std::fs::read_to_string(&path).unwrap();
    let probe = "    if request.get(\"type\") == \"scope.probe\":\n        print(json.dumps({\"type\": \"scope.ready\", \"id\": request[\"id\"]}), flush=True)\n        continue\n";
    assert!(source.contains(probe));
    write_script(&path, &source.replace(probe, ""));
    apps.start();
    let mut app = apps.app();
    app.reader.get_mut().set_read_timeout(Some(Duration::from_secs(30))).unwrap();
    let reply = app.rpc(json!({"cmd": "apps-run-scoped", "app": "cmux/scope", "op": "scope.write",
        "args": {}, "idempotency_key": "old-cached", "origin": "user", "expected_scope": "a".repeat(64)}));
    assert_eq!(error_code(&reply), "apps.scope_unsupported", "{reply}");
    assert!(
        !apps.dir.join("scope-ops.jsonl").exists(),
        "an old server must receive no operation before admission"
    );
}
