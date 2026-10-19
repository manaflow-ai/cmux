//! Request context crosses the actual daemon and partitions outer idempotency replay.
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
for line in sys.stdin:
    request = json.loads(line)
    if request.get("type") != "op":
        continue
    sent += 1
    result = {"scope": request.get("expected_scope"), "sent": sent}
    print(json.dumps({"type": "result", "id": request["id"], "ok": True, "result": result}), flush=True)
"#,
    );
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
            }, "instances": "machine", "hosts": ["local"], "lifecycle": {"start": "on-demand"}}
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
    for (scope, sent) in [(&first, 2), (&second, 3), (&first, 2)] {
        let reply = app.rpc(json!({"cmd": "apps-run-scoped", "app": "cmux/scope", "op": "scope.write",
            "args": {}, "idempotency_key": "same-intent", "origin": "user", "expected_scope": scope}));
        assert_eq!(ok(&reply)["value"], json!({"scope": scope, "sent": sent}), "{reply}");
    }
    let invalid = app.rpc(json!({"cmd": "apps-run-scoped", "app": "cmux/scope", "op": "scope.write",
        "args": {}, "idempotency_key": "invalid", "origin": "user", "expected_scope": "not-a-scope"}));
    assert_eq!(invalid["ok"], false, "{invalid}");
}
