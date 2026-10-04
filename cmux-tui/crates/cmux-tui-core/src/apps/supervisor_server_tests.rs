//! Supervisor tests of app servers: lifecycle, the op gate, the environment,
//! host frames and open tokens.

use super::*;

/// A v2-only first-party app `cmux/<dir>` whose catalog ops run in its
/// server (`server` is the manifest's `server` block): `<dir>.ping` (read,
/// granted through the requested `<dir>:read`), `<dir>.write` (mutate-own,
/// needs the ungranted `<dir>:write`) and `<dir>.wipe` (destructive,
/// gesture required).
fn write_server_app(root: &Path, dir: &str, server: Value) {
    let app = root.join(dir);
    std::fs::create_dir_all(&app).unwrap();
    let id = format!("cmux/{dir}");
    let op = |verb: &str, class: &str, risk: &str, idempotency: &str| {
        json!({
            "name": format!("{dir}.{verb}"), "owner": format!("app:{id}"), "class": class, "risk": risk,
            "idempotency": idempotency, "input": { "type": "object" }, "docs": "d", "since": format!("{dir}/1")
        })
    };
    let mut wipe = op("wipe", "mutation", "destructive", "forbidden");
    wipe["gesture"] = json!("required");
    let operations = [
        op("ping", "read", "read", "forbidden"),
        op("fail", "read", "read", "forbidden"),
        op("notify", "read", "read", "forbidden"),
        op("write", "mutation", "mutate-own", "forbidden"),
        wipe,
    ];
    let catalog = json!({ "family": dir, "operations": operations });
    std::fs::write(app.join("catalog.json"), catalog.to_string()).unwrap();
    let manifest = json!({
        "manifestVersion": 2, "id": id, "name": "Server", "version": "1.0.0", "description": "d",
        "engines": { "cmux": "^2.0" }, "repository": "https://github.com/manaflow-ai/cmux",
        "catalog": "catalog.json", "server": server, "files": ["catalog.json"],
        "scopes": { format!("{dir}:read"): "Read." },
        "optionalScopes": { format!("{dir}:write"): "Write." }
    });
    std::fs::write(app.join("cmux-app.v2.json"), manifest.to_string()).unwrap();
}

/// A fake server binary: appends `start` and `stop` to the marker file (its
/// first argument), writes its environment to `<marker>.env`, appends every
/// line it receives to `<marker>.lines`, and answers every op line with
/// `{served: true}`, except `*.fail` (an error with details, retryable) and
/// `*.notify` (an event `<op>.changed` first).
fn write_fake_server(dir: &Path) {
    write_script(
        dir,
        "fake-server",
        "#!/bin/sh\nmarker=\"$1\"\necho start >> \"$marker\"\nprintf '%s\\n' \"id=$CMUX_APP_ID\" \"data=$CMUX_APP_DATA_DIR\" \"tmp=$TMPDIR\" \"home=$HOME\" \"cargo=$CARGO_MANIFEST_DIR\" > \"$marker.env\"\nwhile IFS= read -r line; do\n  printf '%s\\n' \"$line\" >> \"$marker.lines\"\n  id=${line#*\\\"id\\\":\\\"}\n  id=${id%%\\\"*}\n  op=${line#*\\\"op\\\":\\\"}\n  op=${op%%\\\"*}\n  case \"$op\" in\n    *.fail)\n      printf '{\"type\":\"result\",\"id\":\"%s\",\"ok\":false,\"error\":{\"code\":\"cmux.cloud.not_found\",\"message\":\"no such machine\",\"retryable\":true,\"details\":{\"status\":404,\"upstream_code\":\"vm_not_found\"}}}\\n' \"$id\" ;;\n    *.notify)\n      printf '{\"type\":\"event\",\"event\":\"%s.changed\",\"data\":{\"n\":1}}\\n' \"$op\"\n      printf '{\"type\":\"result\",\"id\":\"%s\",\"ok\":true,\"result\":{\"served\":true}}\\n' \"$id\" ;;\n    *)\n      printf '{\"type\":\"result\",\"id\":\"%s\",\"ok\":true,\"result\":{\"served\":true}}\\n' \"$id\" ;;\n  esac\ndone\necho stop >> \"$marker\"\n",
    );
}

/// A server that sends one `host.request` for the op in `$2` and appends
/// every line it receives to the file in `$1`.
fn write_host_probe(dir: &Path) {
    write_script(
        dir,
        "host-probe",
        "#!/bin/sh\nprintf '{\"t\":\"host.request\",\"id\":7,\"op\":\"%s\",\"params\":{}}\\n' \"$2\"\nwhile IFS= read -r line; do\n  printf '%s\\n' \"$line\" >> \"$1\"\ndone\n",
    );
}

fn write_script(dir: &Path, name: &str, body: &str) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::create_dir_all(dir).unwrap();
    let path = dir.join(name);
    std::fs::write(&path, body).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

fn native_server(marker: &Path, lifecycle: Value) -> Value {
    json!({
        "kind": "native",
        "binaries": { "darwin-arm64": "fake-server", "darwin-x64": "fake-server", "linux-arm64": "fake-server", "linux-x64": "fake-server" },
        "args": [marker.to_string_lossy()],
        "instances": "machine", "hosts": ["local"], "lifecycle": lifecycle
    })
}

/// Waits until the marker file holds exactly `lines`.
fn wait_marker(marker: &Path, lines: &[&str]) {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let seen = std::fs::read_to_string(marker).unwrap_or_default();
        if seen.lines().collect::<Vec<_>>() == lines {
            return;
        }
        assert!(Instant::now() < deadline, "marker {seen:?}, want {lines:?}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn run_server_op(
    f: &Fixture,
    app: &str,
    op: &str,
) -> Result<Value, super::super::supervisor::ApiError> {
    run_server_op_as(f, app, op, Origin::User)
}

fn run_server_op_as(
    f: &Fixture,
    app: &str,
    op: &str,
    origin: Origin,
) -> Result<Value, super::super::supervisor::ApiError> {
    let (tx, rx) = channel();
    f.supervisor
        .run(run_request(app, op, None, origin, None), Box::new(move |r| tx.send(r).unwrap()));
    rx.recv_timeout(Duration::from_secs(10)).unwrap()
}

#[test]
fn always_servers_start_on_enable_and_stop_on_disable() {
    let root = temp_dir();
    let marker = root.0.join("always.marker");
    write_fake_server(&root.0.join("servers"));
    write_server_app(
        &root.0.join("bundled"),
        "srv",
        native_server(&marker, json!({ "start": "always" })),
    );
    let f = fixture_with(&[], Duration::from_secs(60), root);
    f.install("cmux/srv");
    wait_marker(&marker, &["start"]);
    assert_eq!(
        run_server_op(&f, "cmux/srv", "srv.ping").unwrap(),
        json!({ "value": { "served": true } })
    );
    f.set("off", "cmux/srv", Origin::User, |o| o.enabled = Some(false)).unwrap();
    wait_marker(&marker, &["start", "stop"]);
    assert_eq!(run_server_op(&f, "cmux/srv", "srv.ping").unwrap_err().code, "apps.disabled");
}

#[test]
fn on_demand_servers_start_on_the_first_call_and_stop_when_idle() {
    let root = temp_dir();
    let marker = root.0.join("demand.marker");
    write_fake_server(&root.0.join("servers"));
    write_server_app(
        &root.0.join("bundled"),
        "lazy",
        native_server(&marker, json!({ "start": "onDemand", "idleStopSeconds": 1 })),
    );
    let f = fixture_with(&[], Duration::from_secs(60), root);
    f.install("cmux/lazy");
    std::thread::sleep(Duration::from_millis(300));
    assert!(!marker.exists(), "an on-demand server waits for its first call");
    assert_eq!(
        run_server_op(&f, "cmux/lazy", "lazy.ping").unwrap(),
        json!({ "value": { "served": true } })
    );
    wait_marker(&marker, &["start"]);
    // idleStopSeconds: 1 stops it after the call; the next call starts it again.
    wait_marker(&marker, &["start", "stop"]);
    assert_eq!(
        run_server_op(&f, "cmux/lazy", "lazy.ping").unwrap(),
        json!({ "value": { "served": true } })
    );
    wait_marker(&marker, &["start", "stop", "start"]);
}

#[test]
fn a_missing_server_binary_is_reported_once_and_never_retried() {
    let root = temp_dir();
    let mut server = native_server(&root.0.join("never.marker"), json!({ "start": "always" }));
    server["binaries"] = json!({ "darwin-arm64": "absent", "darwin-x64": "absent", "linux-arm64": "absent", "linux-x64": "absent" });
    write_server_app(&root.0.join("bundled"), "gone", server);
    let f = fixture_with(&[], Duration::from_secs(60), root);
    f.install("cmux/gone");
    std::thread::sleep(Duration::from_millis(300));
    let errors = |f: &Fixture| {
        f.supervisor.logs(CLIENT, "cmux/gone", false)["lines"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|l| l["level"] == "error")
            .count()
    };
    assert_eq!(errors(&f), 1, "{}", f.supervisor.logs(CLIENT, "cmux/gone", false));
    assert_eq!(
        run_server_op(&f, "cmux/gone", "gone.ping").unwrap_err().code,
        "apps.server_missing"
    );
    std::thread::sleep(Duration::from_millis(300));
    assert_eq!(errors(&f), 1, "nothing retries a missing binary");
}

#[test]
fn external_servers_are_refused_for_now() {
    let root = temp_dir();
    write_server_app(
        &root.0.join("bundled"),
        "ext",
        json!({ "kind": "external", "instances": "user", "hosts": ["local"] }),
    );
    let f = fixture_with(&[], Duration::from_secs(60), root);
    f.install("cmux/ext");
    assert_eq!(
        run_server_op(&f, "cmux/ext", "ext.ping").unwrap_err().code,
        "apps.server_unsupported"
    );
}

#[test]
fn server_ops_need_their_scope_and_required_gestures_need_the_user() {
    let root = temp_dir();
    write_fake_server(&root.0.join("servers"));
    write_server_app(
        &root.0.join("bundled"),
        "gate",
        native_server(&root.0.join("gate.marker"), json!({})),
    );
    let f = fixture_with(&[], Duration::from_secs(60), root);
    f.install("cmux/gate");
    let served = json!({ "value": { "served": true } });
    // gate:read is granted at install; any origin may read.
    assert_eq!(run_server_op_as(&f, "cmux/gate", "gate.ping", Origin::Cli).unwrap(), served);
    // gate:write is optional and not granted yet, even for the user.
    let missing = run_server_op_as(&f, "cmux/gate", "gate.write", Origin::User).unwrap_err();
    assert_eq!(missing.code, "apps.scope_missing");
    f.set("w", "cmux/gate", Origin::User, |o| o.grant = Some(("gate:write".into(), true))).unwrap();
    assert_eq!(run_server_op_as(&f, "cmux/gate", "gate.write", Origin::Cli).unwrap(), served);
    // gesture: required (and destructive, so no app scope): only the user.
    for origin in [Origin::Cli, Origin::Mcp, Origin::Script] {
        let refused = run_server_op_as(&f, "cmux/gate", "gate.wipe", origin).unwrap_err();
        assert_eq!(refused.code, "apps.gesture_required", "{origin:?}");
    }
    assert_eq!(run_server_op_as(&f, "cmux/gate", "gate.wipe", Origin::User).unwrap(), served);
}

#[test]
fn servers_get_only_the_allowlisted_environment() {
    let root = temp_dir();
    let marker = root.0.join("envy.marker");
    let state = root.0.join("state");
    write_fake_server(&root.0.join("servers"));
    let mut server = native_server(&marker, json!({ "start": "always" }));
    server["data"] = json!([{ "name": "keep", "class": "durable" }, { "name": "scratch", "class": "ephemeral" }]);
    write_server_app(&root.0.join("bundled"), "envy", server);
    let f = fixture_with(&[], Duration::from_secs(60), root);
    f.install("cmux/envy");
    let env_file = marker.with_extension("marker.env");
    let deadline = Instant::now() + Duration::from_secs(10);
    let env = loop {
        let env = std::fs::read_to_string(&env_file).unwrap_or_default();
        if env.contains("cargo=") {
            break env;
        }
        assert!(Instant::now() < deadline, "no environment written");
        std::thread::sleep(Duration::from_millis(20));
    };
    let data = state.join("apps-data/cmux.envy");
    let tmp = state.join("apps-tmp/cmux.envy");
    assert_eq!(
        env.lines().collect::<Vec<_>>(),
        [
            "id=cmux/envy".to_string(),
            format!("data={}", data.display()),
            format!("tmp={}", tmp.display()),
            "home=".to_string(),
            "cargo=".to_string(),
        ]
    );
    assert!(data.join("keep").is_dir() && data.join("scratch").is_dir() && tmp.is_dir());
    f.set("rm", "cmux/envy", Origin::User, |o| o.installed = Some(false)).unwrap();
    wait_marker(&marker, &["start", "stop"]);
    assert!(!data.exists() && !tmp.exists(), "uninstall removes the server's directories");
}

fn probe_server(out: &Path, op: &str, scoped: bool) -> Value {
    let mut server = json!({
        "kind": "native",
        "binaries": { "darwin-arm64": "host-probe", "darwin-x64": "host-probe", "linux-arm64": "host-probe", "linux-x64": "host-probe" },
        "args": [out.to_string_lossy(), op],
        "instances": "machine", "hosts": ["local"], "lifecycle": { "start": "always" }
    });
    if scoped {
        server["scopes"] = json!({ "op:cmux.host.link.get": "Read where the link helper lives." });
    }
    server
}

/// Waits for at least `count` lines in `path` and parses them.
fn frames(path: &Path, count: usize) -> Vec<Value> {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let text = std::fs::read_to_string(path).unwrap_or_default();
        let lines: Vec<Value> = text.lines().map(|l| serde_json::from_str(l).unwrap()).collect();
        if lines.len() >= count {
            return lines;
        }
        assert!(Instant::now() < deadline, "{text:?}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn host_link_get_answers_the_daemon_values_and_needs_its_scope() {
    let root = temp_dir();
    let (linked, unscoped, relay) =
        (root.0.join("linked.out"), root.0.join("unscoped.out"), root.0.join("relay.out"));
    write_host_probe(&root.0.join("servers"));
    let bundled = root.0.join("bundled");
    write_server_app(&bundled, "linked", probe_server(&linked, "cmux.host.link.get", true));
    write_server_app(&bundled, "unscoped", probe_server(&unscoped, "cmux.host.link.get", false));
    write_server_app(&bundled, "relay", probe_server(&relay, "cmux.credential.relay", true));
    let state = root.0.join("state");
    let f = fixture_with(&[], Duration::from_secs(60), root);
    for app in ["cmux/linked", "cmux/unscoped", "cmux/relay"] {
        f.install(app);
    }
    let reply = &frames(&linked, 1)[0];
    assert_eq!((reply["t"].clone(), reply["id"].clone()), (json!("host.result"), json!(7)));
    let value = &reply["value"];
    assert_eq!(value["binary"], json!(std::env::current_exe().unwrap()));
    // The link lane registers the hub socket; until then it is null.
    assert_eq!(value["hub_socket"], Value::Null);
    assert_eq!(value["state_dir"], json!(state.join("apps-data/cmux.linked/link")));
    assert_eq!(value["socket_dir"], json!(state.join("apps-tmp/cmux.linked")));
    assert!(value["device_name"].as_str().is_some_and(|n| !n.is_empty()));
    // A server without the scope gets host.error; the relay is not wired yet.
    let refused = &frames(&unscoped, 1)[0];
    assert_eq!(
        (refused["t"].clone(), refused["id"].clone(), refused["code"].clone()),
        (json!("host.error"), json!(7), json!("apps.scope_missing"))
    );
    let relayed = &frames(&relay, 1)[0];
    assert_eq!(
        (relayed["t"].clone(), relayed["code"].clone(), relayed["retryable"].clone()),
        (json!("host.error"), json!("unavailable"), json!(true))
    );
    // A link change reaches only servers that may read the link.
    f.supervisor.host_link_changed();
    let event = &frames(&linked, 2)[1];
    assert_eq!(
        (event["t"].clone(), event["op"].clone(), event["data"].clone()),
        (json!("host.event"), json!("cmux.host.link.changed"), value.clone())
    );
    std::thread::sleep(Duration::from_millis(200));
    assert_eq!(frames(&unscoped, 1).len(), 1);
}

/// Makes the server app `cmux/<dir>` a terminal connector whose user runs of
/// `open_ops` get an open token.
fn with_open_ops(root: &Path, dir: &str, open_ops: &[&str]) {
    let path = root.join(dir).join("cmux-app.v2.json");
    let mut manifest: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    manifest["implements"] = json!({ "cmux.terminal.connector/1": {
        "server": true, "options": { "kinds": ["vm"], "openOps": open_ops } } });
    std::fs::write(&path, manifest.to_string()).unwrap();
}

/// Every line the fake server with `marker` received, once `count` arrived.
fn op_lines(marker: &Path, count: usize) -> Vec<Value> {
    frames(&marker.with_extension("marker.lines"), count)
}

fn run_with(
    f: &Fixture,
    app: &str,
    op: &str,
    args: Value,
    origin: Origin,
    idempotency_key: Option<&str>,
) -> Result<Value, super::super::supervisor::ApiError> {
    let (tx, rx) = channel();
    let mut request = run_request(app, op, idempotency_key.map(str::to_string), origin, None);
    request.args = args;
    f.supervisor.run(request, Box::new(move |r| tx.send(r).unwrap()));
    rx.recv_timeout(Duration::from_secs(10)).unwrap()
}

#[test]
fn client_open_tokens_never_reach_a_server_and_only_user_runs_get_one() {
    let root = temp_dir();
    let marker = root.0.join("tok.marker");
    write_fake_server(&root.0.join("servers"));
    write_server_app(&root.0.join("bundled"), "tok", native_server(&marker, json!({})));
    with_open_ops(&root.0.join("bundled"), "tok", &["tok.ping"]);
    let f = fixture_with(&[], Duration::from_secs(60), root);
    f.install("cmux/tok");
    let forged = json!({ "open_token": "forged", "x": 1 });
    // Agents reach apps-run only with these origins (the A2 gate refuses
    // their origin user), so none of them ever gets a token.
    for origin in [Origin::Cli, Origin::Mcp, Origin::Script, Origin::Remote] {
        run_with(&f, "cmux/tok", "tok.ping", forged.clone(), origin, None).unwrap();
    }
    run_with(&f, "cmux/tok", "tok.ping", forged, Origin::User, Some("k1")).unwrap();
    let lines = op_lines(&marker, 5);
    for line in &lines {
        assert_eq!(line["args"], json!({ "x": 1 }), "args lose the client token: {line}");
        assert_ne!(line["open_token"], "forged", "{line}");
    }
    for line in &lines[..4] {
        assert!(line.get("open_token").is_none_or(Value::is_null), "no token: {line}");
    }
    let token = lines[4]["open_token"].as_str().expect("a user run gets a token");
    assert!(token.len() >= 32 && token.bytes().all(|b| b.is_ascii_hexdigit()), "{token}");
}

#[test]
fn open_tokens_are_single_use_bound_to_the_app_and_expire() {
    let root = temp_dir();
    let marker = root.0.join("use.marker");
    write_fake_server(&root.0.join("servers"));
    write_server_app(&root.0.join("bundled"), "use", native_server(&marker, json!({})));
    with_open_ops(&root.0.join("bundled"), "use", &["use.ping"]);
    let f = fixture_with(&[], Duration::from_secs(60), root);
    f.install("cmux/use");
    for key in ["k1", "k2", "k3"] {
        run_with(&f, "cmux/use", "use.ping", json!({}), Origin::User, Some(key)).unwrap();
    }
    let lines = op_lines(&marker, 3);
    let token = |i: usize| lines[i]["open_token"].as_str().unwrap().to_string();
    let (first, second, third) = (token(0), token(1), token(2));
    assert!(first != second && second != third, "every run gets a fresh token");
    let now = Instant::now();
    // Once, for the app it was minted for, with its op and key.
    let used = f.supervisor.consume_open_token_at(&first, "cmux/use", now).expect("valid");
    assert_eq!((used.op.as_str(), used.idempotency_key.as_deref()), ("use.ping", Some("k1")));
    assert!(f.supervisor.consume_open_token_at(&first, "cmux/use", now).is_none(), "reuse");
    // Another app's attempt fails and burns the token.
    assert!(f.supervisor.consume_open_token_at(&second, "cmux/other", now).is_none());
    assert!(f.supervisor.consume_open_token_at(&second, "cmux/use", now).is_none());
    // A token older than 60 s is refused.
    let late = now + Duration::from_secs(61);
    assert!(f.supervisor.consume_open_token_at(&third, "cmux/use", late).is_none(), "expired");
    assert!(f.supervisor.consume_open_token("not-a-token", "cmux/use").is_none());
}

#[test]
fn only_user_runs_of_open_ops_get_an_open_token() {
    let root = temp_dir();
    let marker = root.0.join("opn.marker");
    write_fake_server(&root.0.join("servers"));
    write_server_app(&root.0.join("bundled"), "opn", native_server(&marker, json!({})));
    with_open_ops(&root.0.join("bundled"), "opn", &["opn.ping"]);
    let f = fixture_with(&[], Duration::from_secs(60), root);
    f.install("cmux/opn");
    f.set("w", "cmux/opn", Origin::User, |o| o.grant = Some(("opn:write".into(), true))).unwrap();
    // An op listed in openOps, run by the user: a token.
    run_with(&f, "cmux/opn", "opn.ping", json!({}), Origin::User, Some("k1")).unwrap();
    // Another op of the same app, run by the user: none (like machine.list).
    run_with(&f, "cmux/opn", "opn.write", json!({}), Origin::User, Some("k2")).unwrap();
    // The open op from any other origin: none.
    run_with(&f, "cmux/opn", "opn.ping", json!({}), Origin::Cli, Some("k3")).unwrap();
    let lines = op_lines(&marker, 3);
    let token = |i: usize| lines[i].get("open_token").and_then(Value::as_str).map(str::to_string);
    let first = token(0).expect("a user run of an open op gets a token");
    assert_eq!((token(1), token(2)), (None, None), "{lines:?}");
    let used = f.supervisor.consume_open_token(&first, "cmux/opn").expect("valid");
    assert_eq!(used.op, "opn.ping");
}

#[test]
fn full_op_names_resolve_for_first_party_apps_only() {
    let root = temp_dir();
    let marker = root.0.join("alias.marker");
    write_fake_server(&root.0.join("servers"));
    write_server_app(&root.0.join("bundled"), "alias", native_server(&marker, json!({})));
    let f = fixture_with(&[], Duration::from_secs(60), root);
    f.install("cmux/alias");
    let served = json!({ "value": { "served": true } });
    // The full name is canonical; the short name stays accepted.
    assert_eq!(run_server_op(&f, "cmux/alias", "cmux.alias.ping").unwrap(), served);
    assert_eq!(run_server_op(&f, "cmux/alias", "alias.ping").unwrap(), served);
    let lines = op_lines(&marker, 2);
    assert_eq!(
        (lines[0]["op"].clone(), lines[1]["op"].clone()),
        (json!("alias.ping"), json!("alias.ping"))
    );
    // A third-party op is its own namespace: no prefix is stripped.
    f.install("local/spy");
    let refused = run_server_op(&f, "local/spy", "cmux.local.spy.go").unwrap_err();
    assert_eq!(refused.code, "apps.op.unknown");
}

#[test]
fn server_errors_keep_details_and_events_use_full_names() {
    let root = temp_dir();
    write_fake_server(&root.0.join("servers"));
    write_server_app(
        &root.0.join("bundled"),
        "detail",
        native_server(&root.0.join("detail.marker"), json!({})),
    );
    let f = fixture_with(&[], Duration::from_secs(60), root);
    f.install("cmux/detail");
    let error = run_server_op(&f, "cmux/detail", "cmux.detail.fail").unwrap_err();
    assert_eq!(
        (error.code.as_str(), error.message.as_str(), error.details.clone(), error.retryable),
        (
            "cmux.cloud.not_found",
            "no such machine",
            Some(json!({ "status": 404, "upstream_code": "vm_not_found" })),
            true
        )
    );
    run_server_op(&f, "cmux/detail", "detail.notify").unwrap();
    let event = f.wait("server event", |e| e["event"] == "apps-server-event");
    assert_eq!(
        (event["app"].clone(), event["name"].clone(), event["data"].clone()),
        (json!("cmux/detail"), json!("cmux.detail.notify.changed"), json!({ "n": 1 }))
    );
}

/// Terminal interface tests; a child module so they share these fixtures.
#[path = "terminal_ops_tests.rs"]
mod terminal_ops_tests;
