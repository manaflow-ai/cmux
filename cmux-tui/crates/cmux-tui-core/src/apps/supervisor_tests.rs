//! Supervisor tests against a scripted app host: the test executable itself,
//! re-run with `--ignored --exact …scripted_app_host`, speaks the fd 3
//! protocol (the real host and its VM are tested in `cmux-app-host`).

use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_app_host::{FromHost, ToHost};
use serde_json::{Value, json};

use super::catalog::Sources;
use super::egress::{EgressError, FetchRequest, FetchResponse, Fetcher};
use super::mirror::{Origin, SetOp};
use super::supervisor::{Config, OpRouter, Supervisor};

// MARK: scripted host

/// Callback ids at and above this belong to a run's own call.
const RUN_CALL: u64 = 1 << 20;

#[test]
#[ignore = "the scripted app host that supervisor tests spawn; does nothing without fd 3"]
fn scripted_app_host() {
    use std::os::fd::FromRawFd;
    use std::os::unix::net::UnixStream;
    // SAFETY: fstat only inspects descriptor 3.
    let mut stat: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe { libc::fstat(3, &mut stat) } != 0 || (stat.st_mode & libc::S_IFMT) != libc::S_IFSOCK
    {
        return;
    }
    // SAFETY: fd 3 is the supervisor's socket, owned by this process.
    let stream = unsafe { UnixStream::from_raw_fd(3) };
    let mut out = stream.try_clone().expect("clone");
    let mut send = |m: FromHost| {
        let mut line = serde_json::to_vec(&m).expect("json");
        line.push(b'\n');
        let _ = out.write_all(&line);
    };
    let mut next_cb = 1;
    let mut cb_mount: Vec<(u64, String)> = Vec::new();
    for line in BufReader::new(stream).lines() {
        let Ok(line) = line else { break };
        match serde_json::from_str::<ToHost>(&line).expect("protocol") {
            ToHost::Init { .. } => send(FromHost::Ready { runtime: "scripted".into() }),
            ToHost::Mount { mount, export, .. } => {
                if export == "renderFail" {
                    send(FromHost::Mounted { mount, error: Some("render failed".into()) });
                    continue;
                }
                if export == "renderLive" {
                    send(FromHost::Subscribe {
                        sub: 1,
                        stream: "workspace.changed".into(),
                        filter: json!({}),
                    });
                }
                send(FromHost::Scene {
                    mount: mount.clone(),
                    ops: json!([{ "op": "create", "id": "n1", "type": "Text", "props": { "text": export } }, { "op": "root", "id": "n1" }]),
                });
                send(FromHost::Mounted { mount, error: None });
            }
            ToHost::Dispatch { mount, payload, .. } => {
                let cb = next_cb;
                next_cb += 1;
                cb_mount.push((cb, mount));
                let mut options = json!({});
                if let Some(g) = payload.get("gesture") {
                    options["gesture"] = g.clone();
                }
                let name: String = payload["op"].as_str().unwrap_or_default().into();
                send(FromHost::Call {
                    cb,
                    name: name.clone(),
                    params: payload["params"].clone(),
                    options: options.clone(),
                });
                // `twice`: present the same token in a second call.
                if payload["twice"] == true {
                    let again = next_cb;
                    next_cb += 1;
                    let mount = cb_mount.last().expect("mount").1.clone();
                    cb_mount.push((again, mount));
                    send(FromHost::Call {
                        cb: again,
                        name,
                        params: payload["params"].clone(),
                        options,
                    });
                }
            }
            ToHost::Resolve { cb, ok, body } if cb >= RUN_CALL => {
                // The answer to a run's own call finishes the run.
                send(FromHost::Done { cb: cb - RUN_CALL, ok, body });
            }
            ToHost::Resolve { cb, ok, body } => {
                let mount = cb_mount
                    .iter()
                    .find(|(c, _)| *c == cb)
                    .map(|(_, m)| m.clone())
                    .unwrap_or_default();
                send(FromHost::Scene {
                    mount,
                    ops: json!([{ "op": "update", "id": "n1", "props": { "result": { "ok": ok, "body": body } } }]),
                });
            }
            ToHost::Run { cb, export, gesture, .. } => {
                if export == "crash" {
                    std::process::exit(70);
                }
                if let Some(gesture) = &gesture {
                    send(FromHost::Log {
                        level: "info".into(),
                        message: format!("gesture {gesture}"),
                    });
                }
                send(FromHost::Log { level: "info".into(), message: format!("run {export}") });
                if export == "focusTab" {
                    // A palette command that focuses a tab with its token.
                    let options = gesture.map_or_else(|| json!({}), |g| json!({ "gesture": g }));
                    send(FromHost::Call {
                        cb: RUN_CALL + cb,
                        name: "tab.focus".into(),
                        params: json!({ "tab": "tab_1" }),
                        options,
                    });
                    continue;
                }
                send(FromHost::Done { cb, ok: true, body: json!({ "value": export }) });
            }
            ToHost::Event { sub, .. } => {
                send(FromHost::Log { level: "info".into(), message: format!("event {sub}") });
            }
            ToHost::Unmount { .. } | ToHost::Settings { .. } => {}
            ToHost::Shutdown => break,
        }
    }
    std::process::exit(0);
}

// MARK: fixtures

fn run_request(
    app: &str,
    op: &str,
    idempotency_key: Option<String>,
    origin: Origin,
    gesture: Option<&str>,
) -> super::runs::RunRequest {
    super::runs::RunRequest {
        app: app.into(),
        op: op.into(),
        args: json!({}),
        idempotency_key,
        origin,
        gesture: gesture.map(str::to_string),
    }
}

/// (app, op, params, idempotency key, origin)
type RoutedCall = (String, String, Value, Option<String>, Origin);
type Publish = Box<dyn Fn(&str) + Send + Sync>;

#[derive(Default)]
struct FakeRouter {
    calls: Mutex<Vec<RoutedCall>>,
    publish: Mutex<Option<Publish>>,
}

impl OpRouter for Arc<FakeRouter> {
    fn route(
        &self,
        app: &str,
        op: &str,
        params: Value,
        key: Option<String>,
        origin: Origin,
    ) -> Result<Value, Value> {
        self.calls.lock().unwrap().push((app.into(), op.into(), params, key, origin));
        Ok(json!({ "value": { "routed": op } }))
    }

    fn start_events(&self, publish: Box<dyn Fn(&str) + Send + Sync>) {
        *self.publish.lock().unwrap() = Some(publish);
    }

    fn owns(&self, op: &str) -> bool {
        !super::provider::FAMILIES.contains(&super::provider::family_of(op))
    }
}

#[derive(Default)]
struct FakeFetcher {
    requests: Mutex<Vec<FetchRequest>>,
}

impl Fetcher for Arc<FakeFetcher> {
    fn fetch(&self, request: FetchRequest) -> Result<FetchResponse, EgressError> {
        self.requests.lock().unwrap().push(request);
        Ok(FetchResponse { status: 200, headers: vec![], body: "hi".into() })
    }
}

fn write_app(root: &Path, dir: &str, id: &str, scopes: Value) {
    let app = root.join(dir);
    std::fs::create_dir_all(app.join("dist")).unwrap();
    std::fs::write(app.join("dist/main.js"), "var __cmuxAppExports = {};").unwrap();
    let op = |name: &str, export: &str| {
        json!({
            "name": name, "owner": format!("app:{id}"), "class": "mutation", "risk": "mutate-own",
            "idempotency": "required", "input": { "type": "object" }, "docs": "d", "since": "demo/1",
            "export": export
        })
    };
    // A third-party catalog family is the app's namespace (local.spy); a
    // bare family such as `demo` is first-party only.
    let family = if id.starts_with("cmux/") {
        "demo".to_string()
    } else {
        cmux_app_manifest::app_namespace(id)
    };
    let name = |verb: &str| format!("{family}.{verb}");
    let mut go = op(&name("go"), "go");
    go["palette"] = json!({ "title": "Go", "when": "paneFocused:editor" });
    let ops = [go, op(&name("crash"), "crash"), op(&name("focus"), "focusTab")];
    let catalog = json!({ "family": family, "operations": ops });
    std::fs::write(app.join("catalog.json"), catalog.to_string()).unwrap();
    let mut manifest = json!({
        "manifestVersion": 2, "id": id, "name": "Demo", "version": "1.0.0", "description": "d",
        "engines": { "cmux": "^2.0" }, "runtime": { "main": "dist/main.js" }, "catalog": "catalog.json",
        "implements": { "cmux.section/1": { "export": "render", "title": "Demo" }, "cmux.status/1": { "export": "renderFail" }, "cmux.palette.scope/1": { "export": "renderLive" } },
        "scopes": scopes, "files": ["dist/", "catalog.json"]
    });
    if !id.starts_with("local/") {
        manifest["repository"] = json!("https://github.com/manaflow-ai/cmux");
    }
    std::fs::write(app.join("cmux-app.json"), manifest.to_string()).unwrap();
}

struct Fixture {
    supervisor: Arc<Supervisor>,
    router: Arc<FakeRouter>,
    fetcher: Arc<FakeFetcher>,
    events: Receiver<Value>,
    state: PathBuf,
    _root: TempDir,
}

struct TempDir(PathBuf);

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn temp_dir() -> TempDir {
    let mut bytes = [0u8; 8];
    getrandom::fill(&mut bytes).unwrap();
    let dir = std::env::temp_dir().join(format!(
        "cmux-apps-test-{}",
        bytes.iter().map(|b| format!("{b:02x}")).collect::<String>()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    TempDir(dir)
}

const CLIENT: u64 = 7;

fn fixture_with(defaults: &[&str], idle: Duration, root: TempDir) -> Fixture {
    let bundled = root.0.join("bundled");
    let state = root.0.join("state");
    std::fs::create_dir_all(state.join("apps/local")).unwrap();
    if !bundled.join("demo").exists() {
        write_app(
            &bundled,
            "demo",
            "cmux/demo",
            json!({ "workspace:read": "r", "workspace:write": "w", "storage:local": "s", "net:api.example.com": "n", "actions:run": "a", "terminal:write": "t", "integration:github:read": "g" }),
        );
        write_app(
            &state.join("apps/local"),
            "spy",
            "local/spy",
            json!({ "workspace:read": "r", "workspace:write": "w", "net:api.example.com": "n" }),
        );
    }
    let router = Arc::new(FakeRouter::default());
    let fetcher = Arc::new(FakeFetcher::default());
    let supervisor = Supervisor::new(
        Config {
            state_dir: Some(state.clone()),
            host_binary: Some(std::env::current_exe().unwrap()),
            host_args: [
                "--ignored",
                "--exact",
                "apps::supervisor_tests::scripted_app_host",
                "--test-threads=1",
                "-q",
            ]
            .map(String::from)
            .to_vec(),
            sources: Sources {
                first_party: None,
                bundled: vec![bundled],
                local: Some(state.join("apps/local")),
                defaults: Some(defaults.iter().map(|s| s.to_string()).collect()),
            },
            idle_stop: idle,
            provider_deadline: Duration::from_millis(400),
            provider_user_deadline: Duration::from_millis(400),
        },
        Box::new(router.clone()),
        Box::new(fetcher.clone()),
    );
    let (tx, rx): (Sender<Value>, Receiver<Value>) = channel();
    let tx = Mutex::new(tx);
    supervisor.register_client(
        CLIENT,
        Arc::new(move |v: &Value| tx.lock().unwrap().send(v.clone()).is_ok()),
    );
    Fixture { supervisor, router, fetcher, events: rx, state, _root: root }
}

fn fixture() -> Fixture {
    fixture_with(&[], Duration::from_secs(60), temp_dir())
}

impl Fixture {
    fn set(
        &self,
        key: &str,
        app: &str,
        origin: Origin,
        f: impl FnOnce(&mut SetOp),
    ) -> Result<Value, super::supervisor::ApiError> {
        let mut op = SetOp { key: key.into(), app: app.into(), origin, ..SetOp::default() };
        f(&mut op);
        self.supervisor.set(CLIENT, op)
    }

    fn install(&self, app: &str) {
        self.set(&format!("install-{app}"), app, Origin::User, |o| o.installed = Some(true))
            .unwrap();
    }

    /// Blocks until an event matches (or fails after 10 s).
    fn wait(&self, what: &str, pred: impl Fn(&Value) -> bool) -> Value {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            match self.events.recv_timeout(left) {
                Ok(event) if pred(&event) => return event,
                Ok(_) => {}
                Err(_) => panic!("timed out waiting for {what}"),
            }
        }
    }

    fn wait_event(&self, name: &str) -> Value {
        self.wait(name, |e| e["event"] == name)
    }

    fn mount(&self, mount_id: &str, app: &str, interface: &str, context: Value) {
        self.supervisor.mount(CLIENT, mount_id, app, interface, context).unwrap();
        let scene =
            self.wait("first scene", |e| e["event"] == "apps-scene" && e["mount_id"] == mount_id);
        assert_eq!(scene["ops"][0]["op"], "create");
    }

    /// Dispatches a scripted call and returns `{ok, body}` from the scene update.
    fn call(&self, mount_id: &str, op: &str, params: Value, user: bool) -> Value {
        self.supervisor
            .dispatch(CLIENT, mount_id, "n1", "tap", json!({ "op": op, "params": params }), user)
            .unwrap();
        let update = self.wait("call result", |e| {
            e["event"] == "apps-scene" && e["mount_id"] == mount_id && e["ops"][0]["op"] == "update"
        });
        update["ops"][0]["props"]["result"].clone()
    }
}

fn app_entry(list: &Value, id: &str) -> Value {
    list["apps"].as_array().unwrap().iter().find(|a| a["id"] == id).cloned().unwrap_or(Value::Null)
}

// MARK: install mirror over the wire shape

#[test]
fn list_shows_available_apps_and_installs_need_a_user() {
    let f = fixture();
    let list = f.supervisor.list();
    let demo = app_entry(&list, "cmux/demo");
    assert_eq!(
        (demo["installed"].clone(), demo["tier"].clone(), demo["source"].clone()),
        (json!(false), json!("first-party"), json!("bundled"))
    );
    assert_eq!(app_entry(&list, "local/spy")["tier"], "unverified");
    let refused = f.set("k1", "cmux/demo", Origin::Mcp, |o| o.installed = Some(true)).unwrap_err();
    assert_eq!(refused.code, "apps.origin");
    let record = f.set("k2", "cmux/demo", Origin::User, |o| o.installed = Some(true)).unwrap();
    assert_eq!(record["installed"], true);
    assert_eq!(record["source"], "user");
    assert_eq!(record["revision"], f.supervisor.list()["revision"]);
    assert!(record["bundle_dir"].as_str().is_some_and(|d| d.ends_with("bundled/demo")));
    let changed = f.wait_event("apps-changed");
    let settled = f.wait_event("request-settled");
    assert_eq!(changed["transaction"], settled["transaction"]);
    // Durable: a new supervisor over the same state dir sees the install.
    let saved: Value =
        serde_json::from_slice(&std::fs::read(f.state.join("apps.json")).unwrap()).unwrap();
    assert_eq!(saved["mirror"]["apps"]["cmux/demo"]["installed"], true);
    // Replaying the same key is a no-op with the same answer.
    assert_eq!(
        f.set("k2", "cmux/demo", Origin::User, |o| o.installed = Some(true)).unwrap(),
        record
    );
}

#[test]
fn unverified_apps_start_sandboxed_with_read_scopes() {
    let f = fixture();
    f.install("local/spy");
    let spy = app_entry(&f.supervisor.list(), "local/spy");
    assert_eq!(spy["sandboxed"], true);
    assert_eq!(spy["grants"], json!(["workspace:read"]));
    assert_eq!(spy["source"], "local");
}

#[test]
fn default_apps_are_installed_with_required_scopes() {
    let f = fixture_with(&["cmux/demo"], Duration::from_secs(60), temp_dir());
    let demo = app_entry(&f.supervisor.list(), "cmux/demo");
    assert_eq!(
        (demo["installed"].clone(), demo["source"].clone()),
        (json!(true), json!("default"))
    );
    assert_eq!(
        demo["grants"],
        json!([
            "actions:run",
            "integration:github:read",
            "net:api.example.com",
            "storage:local",
            "terminal:write",
            "workspace:read",
            "workspace:write"
        ])
    );
}

// MARK: hosts, mounts and calls

#[test]
fn focus_ops_need_the_gesture_the_supervisor_minted() {
    let f = fixture();
    f.install("cmux/demo");
    f.mount("m1", "cmux/demo", "cmux.section/1", json!({}));
    let automated = f.call("m1", "tab.focus", json!({ "tab": "tab_1" }), false);
    assert_eq!(
        (automated["ok"].clone(), automated["body"]["code"].clone()),
        (json!(false), json!("gesture.required"))
    );
    let user = f.call("m1", "tab.focus", json!({ "tab": "tab_1" }), true);
    assert_eq!(user["ok"], true, "{user}");
    let calls = f.router.calls.lock().unwrap().clone();
    assert_eq!(calls.len(), 1);
    let (app, op, _, key, origin) = &calls[0];
    assert_eq!((app.as_str(), op.as_str(), origin), ("cmux/demo", "tab.focus", &Origin::User));
    assert!(
        key.as_deref().is_some_and(|k| k.starts_with("app:cmux/demo:")),
        "mutations get an idempotency key"
    );
}

#[test]
fn unknown_ops_ungranted_ops_storage_and_egress() {
    let f = fixture();
    f.install("cmux/demo");
    f.mount("m1", "cmux/demo", "cmux.section/1", json!({}));
    assert_eq!(f.call("m1", "made.up", json!({}), false)["body"]["code"], "operation.unsupported");
    assert_eq!(f.call("m1", "agent.list", json!({}), false)["body"]["code"], "scope.missing");
    assert_eq!(
        f.call("m1", "app.storage.set", json!({ "key": "k", "value": 5 }), false)["ok"],
        true
    );
    assert_eq!(f.call("m1", "app.storage.get", json!({ "key": "k" }), false)["body"]["value"], 5);
    let fetched = f.call(
        "m1",
        "net.fetch",
        json!({ "url": "https://api.example.com/x", "headers": { "Cookie": "c", "Accept": "a" } }),
        false,
    );
    assert_eq!(fetched["body"]["value"]["body"], "hi");
    assert_eq!(
        f.fetcher.requests.lock().unwrap()[0].headers,
        vec![("Accept".to_string(), "a".to_string())]
    );
    assert_eq!(
        f.call("m1", "net.fetch", json!({ "url": "https://other.example.org/" }), false)["body"]["code"],
        "scope.missing"
    );
}

#[test]
fn sandboxed_apps_get_no_network_and_previews_get_nothing() {
    let f = fixture();
    f.install("local/spy");
    f.mount("m1", "local/spy", "cmux.section/1", json!({}));
    assert_eq!(
        f.call("m1", "net.fetch", json!({ "url": "https://api.example.com/" }), false)["body"]["code"],
        "scope.missing"
    );
    assert_eq!(f.call("m1", "workspace.list", json!({}), false)["ok"], true);
    assert!(f.fetcher.requests.lock().unwrap().is_empty());
    // A preview of an app that is not installed: no grants at all, and the host stops with it.
    f.mount("p1", "cmux/demo", "cmux.section/1", json!({ "preview": true }));
    assert_eq!(f.call("p1", "workspace.list", json!({}), true)["body"]["code"], "scope.missing");
    f.supervisor.unmount(CLIENT, "p1").unwrap();
    f.wait("preview host stopped", |e| {
        e["event"] == "apps-host" && e["app"] == "cmux/demo" && e["state"] == "stopped"
    });
    assert_eq!(app_entry(&f.supervisor.list(), "cmux/demo")["installed"], false);
}

#[test]
fn a_failed_render_reports_mount_failed() {
    let f = fixture();
    f.install("cmux/demo");
    f.supervisor.mount(CLIENT, "s1", "cmux/demo", "cmux.status/1", json!({})).unwrap();
    let failed = f.wait_event("apps-mount-failed");
    assert_eq!(
        (failed["mount_id"].clone(), failed["reason"].clone()),
        (json!("s1"), json!("render failed"))
    );
    let missing =
        f.supervisor.mount(CLIENT, "x", "cmux/demo", "cmux.editor/1", json!({})).unwrap_err();
    assert_eq!(missing.code, "apps.interface");
    let not_installed =
        f.supervisor.mount(CLIENT, "y", "local/spy", "cmux.section/1", json!({})).unwrap_err();
    assert_eq!(not_installed.code, "apps.notInstalled");
}

#[test]
fn uninstall_fails_mounts_stops_the_host_and_clears_storage() {
    let f = fixture();
    f.install("cmux/demo");
    f.mount("m1", "cmux/demo", "cmux.section/1", json!({}));
    f.call("m1", "app.storage.set", json!({ "key": "k", "value": 1 }), false);
    f.set("rm", "cmux/demo", Origin::User, |o| o.installed = Some(false)).unwrap();
    let failed = f.wait_event("apps-mount-failed");
    assert_eq!(failed["mount_id"], "m1");
    f.wait("host stopped", |e| e["event"] == "apps-host" && e["state"] == "stopped");
    let storage = f.supervisor.storage();
    assert_eq!(
        storage
            .as_ref()
            .unwrap()
            .call("cmux/demo", "app.storage.get", &json!({ "key": "k" }))
            .unwrap(),
        Value::Null
    );
}

#[test]
fn runs_answer_through_the_responder_and_a_crash_restarts_with_reset() {
    let f = fixture();
    f.install("cmux/demo");
    let (tx, rx) = channel();
    let tx2 = tx.clone();
    f.supervisor.run(
        run_request("cmux/demo", "demo.go", None, Origin::User, None),
        Box::new(move |r| tx.send(r).unwrap()),
    );
    assert_eq!(
        rx.recv_timeout(Duration::from_secs(10)).unwrap().unwrap(),
        json!({ "value": "go" })
    );
    f.mount("m1", "cmux/demo", "cmux.section/1", json!({}));
    f.supervisor.run(
        run_request("cmux/demo", "demo.crash", None, Origin::User, None),
        Box::new(move |r| tx2.send(r).unwrap()),
    );
    assert_eq!(rx.recv_timeout(Duration::from_secs(10)).unwrap().unwrap_err().code, "apps.host");
    f.wait("crash", |e| e["event"] == "apps-host" && e["state"] == "crashed");
    let rerender = f.wait("re-render", |e| e["event"] == "apps-scene" && e["mount_id"] == "m1");
    assert_eq!(rerender["reset"], true, "the first batch after a restart starts a fresh tree");
    assert_eq!(f.supervisor.list()["apps"].as_array().unwrap().len(), 2);
}

#[test]
fn idle_hosts_stop_after_the_last_mount_and_disconnect_unmounts() {
    let f = fixture_with(&[], Duration::from_millis(50), temp_dir());
    f.install("cmux/demo");
    f.mount("m1", "cmux/demo", "cmux.section/1", json!({}));
    // A second connection observes the stop after the first one goes away.
    let (tx, rx) = channel();
    let tx = Mutex::new(tx);
    f.supervisor
        .register_client(8, Arc::new(move |v: &Value| tx.lock().unwrap().send(v.clone()).is_ok()));
    f.supervisor.disconnect(CLIENT);
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let event =
            rx.recv_timeout(deadline.saturating_duration_since(Instant::now())).expect("idle stop");
        if event["event"] == "apps-host" && event["state"] == "stopped" {
            break;
        }
    }
}

#[test]
fn daemon_events_reach_subscribed_apps() {
    let f = fixture();
    f.install("cmux/demo");
    f.supervisor.mount(CLIENT, "l1", "cmux/demo", "cmux.palette.scope/1", json!({})).unwrap();
    f.wait("scene", |e| e["event"] == "apps-scene" && e["mount_id"] == "l1");
    f.supervisor.logs(CLIENT, "cmux/demo", true);
    // The scripted host subscribes before its first scene, and the reader
    // thread handles lines in order, so the bridge is up by now.
    let publish = f.router.publish.lock().unwrap().take().expect("event bridge started");
    publish("workspace.changed");
    let log = f.wait_event("apps-log");
    assert_eq!(log["message"], "event 1");
    let lines = f.supervisor.logs(CLIENT, "cmux/demo", false);
    assert!(lines["lines"].as_array().unwrap().iter().any(|l| l["message"] == "event 1"));
}

#[test]
fn keyed_runs_run_once_and_hidden_apps_refuse_hidden_surfaces() {
    let f = fixture();
    f.install("cmux/demo");
    let (tx, rx) = channel();
    for _ in 0..2 {
        let tx = tx.clone();
        f.supervisor.run(
            run_request("cmux/demo", "demo.go", Some("k1".into()), Origin::Cli, None),
            Box::new(move |r| tx.send(r).unwrap()),
        );
        assert_eq!(
            rx.recv_timeout(Duration::from_secs(10)).unwrap().unwrap(),
            json!({ "value": "go" })
        );
    }
    let runs = f.supervisor.logs(CLIENT, "cmux/demo", false)["lines"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|l| l["message"] == "run go")
        .count();
    assert_eq!(runs, 1, "the replay answered from the stored result");
    f.set("hide", "cmux/demo", Origin::Mcp, |o| {
        o.hidden = Some(true);
        o.hidden_access =
            Some(super::mirror::HiddenAccess { cli: false, mcp: true, automations: true });
    })
    .unwrap();
    let tx2 = tx.clone();
    f.supervisor.run(
        run_request("cmux/demo", "demo.go", None, Origin::Cli, None),
        Box::new(move |r| tx2.send(r).unwrap()),
    );
    assert_eq!(rx.recv_timeout(Duration::from_secs(10)).unwrap().unwrap_err().code, "apps.hidden");
    f.supervisor.run(
        run_request("cmux/demo", "demo.go", None, Origin::Mcp, None),
        Box::new(move |r| tx.send(r).unwrap()),
    );
    assert!(rx.recv_timeout(Duration::from_secs(10)).unwrap().is_ok());
}

#[test]
fn rejects_and_noops_still_settle() {
    let f = fixture();
    assert!(f.set("r1", "cmux/demo", Origin::Cli, |o| o.installed = Some(true)).is_err());
    f.wait_event("request-settled");
    f.install("cmux/demo");
    f.wait_event("request-settled");
    f.set("noop", "cmux/demo", Origin::User, |o| o.hidden = Some(false)).unwrap();
    f.wait_event("request-settled");
    // The no-op recorded its key: reusing it for another change conflicts.
    let conflict = f.set("noop", "cmux/demo", Origin::User, |o| o.hidden = Some(true)).unwrap_err();
    assert_eq!(conflict.code, "idempotency.conflict");
}

#[test]
fn apps_never_move_focus_through_params_without_a_gesture() {
    let f = fixture();
    f.install("cmux/demo");
    f.mount("m1", "cmux/demo", "cmux.section/1", json!({}));
    assert_eq!(f.call("m1", "pane.create", json!({ "focus": true }), false)["ok"], true);
    assert_eq!(f.call("m1", "pane.create", json!({ "focus": true }), true)["ok"], true);
    let calls = f.router.calls.lock().unwrap().clone();
    assert_eq!(calls[0].2.get("focus"), None, "stripped for an automated call");
    assert_eq!((calls[0].4, calls[1].4), (Origin::Script, Origin::User));
    assert_eq!(calls[1].2["focus"], true, "kept when the user's gesture was spent");
}

#[test]
fn a_disabled_app_cannot_preview_or_mount() {
    let f = fixture();
    f.install("cmux/demo");
    f.set("off", "cmux/demo", Origin::User, |o| o.enabled = Some(false)).unwrap();
    let preview = f
        .supervisor
        .mount(CLIENT, "p", "cmux/demo", "cmux.section/1", json!({ "preview": true }))
        .unwrap_err();
    assert_eq!(preview.code, "apps.disabled");
}

#[test]
fn palette_runs_get_one_supervisor_gesture_per_client_token() {
    let f = fixture();
    f.install("cmux/demo");
    let (tx, rx) = channel();
    for (origin, token) in [
        (Origin::User, "palette-0001"),
        (Origin::User, "palette-0001"),
        (Origin::Cli, "palette-0002"),
        (Origin::User, "x"),
    ] {
        let tx = tx.clone();
        f.supervisor.run(
            run_request("cmux/demo", "demo.go", None, origin, Some(token)),
            Box::new(move |r| tx.send(r).unwrap()),
        );
        rx.recv_timeout(Duration::from_secs(10)).unwrap().unwrap();
    }
    let gestures: Vec<String> = f.supervisor.logs(CLIENT, "cmux/demo", false)["lines"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|l| {
            l["message"].as_str().and_then(|m| m.strip_prefix("gesture ")).map(str::to_string)
        })
        .collect();
    assert_eq!(gestures.len(), 1, "only the first user invocation of a token: {gestures:?}");
    assert!(gestures[0].starts_with("g_"), "the host sees a supervisor token, never the client's");
}

// MARK: host-side ABI enforcement (raw calls; the runtime is not involved)

#[test]
fn view_state_ops_need_a_live_token_for_this_app_spent_once() {
    let f = fixture();
    f.install("cmux/demo");
    f.mount("m1", "cmux/demo", "cmux.section/1", json!({}));
    for op in ["tab.focus", "terminal.viewport.scroll", "workspace.focus", "pane.zoom"] {
        let refused = f.call("m1", op, json!({}), false);
        assert_eq!(refused["body"]["code"], "gesture.required", "{op}: {refused}");
    }
    // One user event: the first view-state call spends its token, the second is refused.
    f.supervisor
        .dispatch(
            CLIENT,
            "m1",
            "n1",
            "tap",
            json!({ "op": "tab.focus", "params": { "tab": "tab_1" }, "twice": true }),
            true,
        )
        .unwrap();
    let mut results = Vec::new();
    while results.len() < 2 {
        let update =
            f.wait("call result", |e| e["event"] == "apps-scene" && e["ops"][0]["op"] == "update");
        results.push(update["ops"][0]["props"]["result"].clone());
    }
    // Answers arrive in any order: a refusal is immediate, an accepted call
    // answers from its worker thread.
    let accepted = results.iter().filter(|r| r["ok"] == true).count();
    let refused = results.iter().filter(|r| r["body"]["code"] == "gesture.required").count();
    assert_eq!((accepted, refused), (1, 1), "a token is spent once: {results:?}");
}

#[test]
fn a_client_cannot_mint_a_token_and_another_apps_token_does_not_count() {
    let f = fixture();
    f.install("cmux/demo");
    f.mount("m1", "cmux/demo", "cmux.section/1", json!({}));
    // A token the client wrote into the payload is stripped (automation event).
    f.supervisor
        .dispatch(
            CLIENT,
            "m1",
            "n1",
            "tap",
            json!({ "op": "tab.focus", "params": {}, "gesture": "g_forged" }),
            false,
        )
        .unwrap();
    let update =
        f.wait("call result", |e| e["event"] == "apps-scene" && e["ops"][0]["op"] == "update");
    assert_eq!(update["ops"][0]["props"]["result"]["body"]["code"], "gesture.required");
}

#[test]
fn action_run_honors_the_action_catalog_and_needs_a_gesture() {
    let f = fixture();
    f.install("cmux/demo");
    f.mount("m1", "cmux/demo", "cmux.section/1", json!({}));
    for (id, reason) in [
        ("palette.auth.signIn", "credentials"),
        ("quit", "endsApp"),
        ("keepMacAwake", "systemChange"),
        ("taskManager.killProcess", "liveInput"),
    ] {
        let refused = f.call("m1", "action.run", json!({ "id": id }), true);
        assert_eq!(
            (refused["body"]["code"].clone(), refused["body"]["details"]["reason"].clone()),
            (json!("scope.missing"), json!(reason)),
            "{id}"
        );
    }
    assert_eq!(
        f.call("m1", "action.run", json!({ "id": "made.up" }), true)["body"]["code"],
        "operation.unsupported"
    );
    assert_eq!(
        f.call("m1", "action.run", json!({ "id": "newWindow" }), false)["body"]["code"],
        "gesture.required"
    );
    // Allowed with a gesture; with no Mac app connected it fails at once (APP-R1).
    let unavailable = f.call("m1", "action.run", json!({ "id": "newWindow" }), true);
    assert_eq!(
        (unavailable["body"]["code"].clone(), unavailable["body"]["retryable"].clone()),
        (json!("provider.unavailable"), json!(true))
    );
    assert_eq!(unavailable["body"]["details"]["family"], "action");
}

#[test]
fn action_run_needs_the_actions_scope() {
    let f = fixture();
    f.install("local/spy");
    f.mount("m1", "local/spy", "cmux.section/1", json!({}));
    assert_eq!(
        f.call("m1", "action.run", json!({ "id": "newWindow" }), true)["body"]["code"],
        "scope.missing"
    );
}

#[test]
fn a_palette_command_runs_its_user_only_op_with_the_palette_gesture() {
    let f = fixture();
    f.install("cmux/demo");
    let (tx, rx) = channel();
    let tx2 = tx.clone();
    f.supervisor.run(
        run_request("cmux/demo", "demo.focus", None, Origin::User, Some("palette-run-1")),
        Box::new(move |r| tx.send(r).unwrap()),
    );
    assert!(
        rx.recv_timeout(Duration::from_secs(10)).unwrap().is_ok(),
        "focus from the palette is accepted"
    );
    let calls = f.router.calls.lock().unwrap().clone();
    assert_eq!((calls[0].1.as_str(), calls[0].4), ("tab.focus", Origin::User));
    // The same command from the CLI carries no gesture and is refused.
    f.supervisor.run(
        run_request("cmux/demo", "demo.focus", None, Origin::Cli, Some("palette-run-2")),
        Box::new(move |r| tx2.send(r).unwrap()),
    );
    assert_eq!(
        rx.recv_timeout(Duration::from_secs(10)).unwrap().unwrap_err().code,
        "gesture.required"
    );
}

// MARK: provider channel (app-op-routing.md, APP-R1)

const PROVIDER: u64 = 9;
const APP: super::provider::ProviderClaim =
    super::provider::ProviderClaim { agent: false, app_kind: true };

/// Registers a provider connection and returns its event stream.
fn provider(f: &Fixture, families: &[&str]) -> Receiver<Value> {
    let (tx, rx) = channel();
    let tx = Mutex::new(tx);
    f.supervisor.register_client(
        PROVIDER,
        Arc::new(move |v: &Value| tx.lock().unwrap().send(v.clone()).is_ok()),
    );
    f.supervisor
        .register_provider(PROVIDER, APP, families.iter().map(|s| s.to_string()).collect())
        .unwrap();
    rx
}

fn next_request(rx: &Receiver<Value>) -> Value {
    loop {
        let event = rx.recv_timeout(Duration::from_secs(10)).expect("provider request");
        if event["event"] == "apps-provider-request" {
            return event;
        }
    }
}

#[test]
fn provider_calls_carry_the_stamped_actor_and_answer_the_app() {
    let f = fixture();
    f.install("cmux/demo");
    f.mount("m1", "cmux/demo", "cmux.section/1", json!({}));
    let rx = provider(&f, &["action"]);
    f.supervisor
        .dispatch(
            CLIENT,
            "m1",
            "n1",
            "tap",
            json!({ "op": "action.run", "params": { "id": "newWindow" } }),
            true,
        )
        .unwrap();
    let request = next_request(&rx);
    assert_eq!(
        (
            request["app"].clone(),
            request["actor"].clone(),
            request["origin"].clone(),
            request["op"].clone()
        ),
        (
            json!("cmux/demo"),
            json!({
                "kind": "app",
                "id": "cmux/demo",
                "host": crate::machine_name::machine_name(),
                "version": "1.0.0",
                "on_behalf_of": { "kind": "user", "id": "user_local" }
            }),
            json!("user"),
            json!("action.run")
        )
    );
    assert!(request["idempotency_key"].as_str().is_some_and(|k| k.starts_with("app:cmux/demo:")));
    let id = request["request_id"].as_u64().unwrap();
    // Only the connection the call went to may answer it.
    assert_eq!(
        f.supervisor.provider_result(CLIENT, id, true, json!({ "value": 1 })).unwrap_err().code,
        "apps.provider.unknown"
    );
    f.supervisor.provider_result(PROVIDER, id, true, json!({ "value": "opened" })).unwrap();
    let update =
        f.wait("call result", |e| e["event"] == "apps-scene" && e["ops"][0]["op"] == "update");
    assert_eq!(
        update["ops"][0]["props"]["result"],
        json!({ "ok": true, "body": { "value": "opened" } })
    );
}

#[test]
fn no_provider_fails_at_once_and_a_provider_leaving_fails_its_pending_calls() {
    let f = fixture();
    f.install("cmux/demo");
    f.mount("m1", "cmux/demo", "cmux.section/1", json!({}));
    let started = Instant::now();
    let missing = f.call("m1", "action.run", json!({ "id": "newWindow" }), true);
    assert_eq!(missing["body"]["code"], "provider.unavailable");
    assert!(
        started.elapsed() < Duration::from_millis(400),
        "no wait for a provider that is not there"
    );
    let rx = provider(&f, &["action"]);
    f.supervisor
        .dispatch(
            CLIENT,
            "m1",
            "n1",
            "tap",
            json!({ "op": "action.run", "params": { "id": "newWindow" } }),
            true,
        )
        .unwrap();
    next_request(&rx);
    f.supervisor.disconnect(PROVIDER);
    let update =
        f.wait("call result", |e| e["event"] == "apps-scene" && e["ops"][0]["op"] == "update");
    let body = update["ops"][0]["props"]["result"]["body"].clone();
    assert_eq!(
        (body["code"].clone(), body["retryable"].clone(), body["details"]["family"].clone()),
        (json!("provider.unavailable"), json!(true), json!("action"))
    );
    // The family went with the connection.
    assert_eq!(
        f.call("m1", "action.run", json!({ "id": "newWindow" }), true)["body"]["code"],
        "provider.unavailable"
    );
}

#[test]
fn a_provider_that_does_not_answer_times_out_and_is_told() {
    let f = fixture();
    f.install("cmux/demo");
    f.mount("m1", "cmux/demo", "cmux.section/1", json!({}));
    let rx = provider(&f, &["action"]);
    f.supervisor
        .dispatch(
            CLIENT,
            "m1",
            "n1",
            "tap",
            json!({ "op": "action.run", "params": { "id": "newWindow" } }),
            true,
        )
        .unwrap();
    let id = next_request(&rx)["request_id"].clone();
    let update = f.wait("timeout", |e| e["event"] == "apps-scene" && e["ops"][0]["op"] == "update");
    assert_eq!(update["ops"][0]["props"]["result"]["body"]["details"]["reason"], "timeout");
    let cancel = rx.recv_timeout(Duration::from_secs(5)).unwrap();
    assert_eq!(
        (cancel["event"].clone(), cancel["request_id"].clone()),
        (json!("apps-provider-cancel"), id)
    );
    assert_eq!(
        f.supervisor.register_provider(PROVIDER, APP, vec!["shell".into()]).unwrap_err().code,
        "bad-request"
    );
}

#[test]
fn a_live_provider_cannot_be_taken_over() {
    let f = fixture();
    let _rx = provider(&f, &["action"]);
    let thief = 10;
    f.supervisor.register_client(thief, Arc::new(|_: &Value| true));
    assert_eq!(
        f.supervisor.register_provider(thief, APP, vec!["action".into()]).unwrap_err().code,
        "apps.provider.taken"
    );
    // The holder may register again; after it leaves the family is free.
    f.supervisor.register_provider(PROVIDER, APP, vec!["action".into(), "fs".into()]).unwrap();
    f.supervisor.disconnect(PROVIDER);
    f.supervisor.register_provider(thief, APP, vec!["action".into()]).unwrap();
}

#[test]
fn routed_params_are_bounded_and_integration_methods_are_explicit() {
    let f = fixture();
    f.install("cmux/demo");
    f.mount("m1", "cmux/demo", "cmux.section/1", json!({}));
    let rx = provider(&f, &["action", "integration"]);
    let big = "x".repeat(70 * 1024);
    let refused =
        f.call("m1", "action.run", json!({ "id": "newWindow", "args": { "blob": big } }), true);
    assert_eq!(refused["body"]["code"], "validation.invalid");
    f.supervisor
        .dispatch(
            CLIENT,
            "m1",
            "n1",
            "tap",
            json!({ "op": "integration.request", "params": { "provider": "github", "path": "/user" } }),
            false,
        )
        .unwrap();
    let request = next_request(&rx);
    assert_eq!(request["params"]["method"], "GET", "the read grant's method reaches the provider");
}

#[test]
fn uninstall_cancels_provider_calls_and_errors_reach_the_app_in_abi_shape() {
    let f = fixture();
    f.install("cmux/demo");
    f.mount("m1", "cmux/demo", "cmux.section/1", json!({}));
    let rx = provider(&f, &["action"]);
    let tap = json!({ "op": "action.run", "params": { "id": "newWindow" } });
    f.supervisor.dispatch(CLIENT, "m1", "n1", "tap", tap.clone(), true).unwrap();
    let id = next_request(&rx)["request_id"].as_u64().unwrap();
    // A malformed provider error still reaches the app as {code, message, retryable}.
    f.supervisor.provider_result(PROVIDER, id, false, json!("nope")).unwrap();
    let update = f.wait("error", |e| e["event"] == "apps-scene" && e["ops"][0]["op"] == "update");
    let body = update["ops"][0]["props"]["result"]["body"].clone();
    assert_eq!(
        (body["code"].clone(), body["retryable"].clone()),
        (json!("operation.failed"), json!(false))
    );
    f.supervisor.dispatch(CLIENT, "m1", "n1", "tap", tap, true).unwrap();
    let id = next_request(&rx)["request_id"].clone();
    f.set("rm", "cmux/demo", Origin::User, |o| o.installed = Some(false)).unwrap();
    let cancel = loop {
        let event = rx.recv_timeout(Duration::from_secs(5)).unwrap();
        if event["event"] == "apps-provider-cancel" {
            break event;
        }
    };
    assert_eq!(
        (cancel["request_id"].clone(), cancel["reason"].clone()),
        (id.clone(), json!("revoked"))
    );
    let late = f.supervisor.provider_result(PROVIDER, id.as_u64().unwrap(), true, json!({}));
    assert_eq!(late.unwrap_err().code, "apps.provider.unknown");
}

#[test]
fn the_idle_stop_waits_for_a_provider_call_in_flight() {
    let f = fixture_with(&[], Duration::from_millis(50), temp_dir());
    f.install("cmux/demo");
    f.mount("m1", "cmux/demo", "cmux.section/1", json!({}));
    let rx = provider(&f, &["action"]);
    let tap = json!({ "op": "action.run", "params": { "id": "newWindow" } });
    f.supervisor.dispatch(CLIENT, "m1", "n1", "tap", tap, true).unwrap();
    let id = next_request(&rx)["request_id"].as_u64().unwrap();
    f.supervisor.unmount(CLIENT, "m1").unwrap();
    let early = Instant::now() + Duration::from_millis(200);
    while let Ok(event) = f.events.recv_timeout(early.saturating_duration_since(Instant::now())) {
        let stopped = event["event"] == "apps-host" && event["state"] == "stopped";
        assert!(!stopped, "stopped with a call in flight");
    }
    f.supervisor.provider_result(PROVIDER, id, true, json!({ "value": null })).unwrap();
    f.wait("idle stop after the answer", |e| e["event"] == "apps-host" && e["state"] == "stopped");
}

#[test]
fn only_the_cmux_app_and_never_an_agent_may_provide() {
    let f = fixture();
    let agent = super::provider::ProviderClaim { agent: true, app_kind: true };
    let undeclared = super::provider::ProviderClaim { agent: false, app_kind: false };
    for claim in [agent, undeclared] {
        let refused =
            f.supervisor.register_provider(PROVIDER, claim, vec!["action".into()]).unwrap_err();
        assert_eq!(refused.code, "apps.provider.forbidden", "{claim:?}");
    }
    // Nothing was registered: calls still find no provider.
    f.install("cmux/demo");
    f.mount("m1", "cmux/demo", "cmux.section/1", json!({}));
    assert_eq!(
        f.call("m1", "action.run", json!({ "id": "newWindow" }), true)["body"]["code"],
        "provider.unavailable"
    );
}

#[test]
fn apps_list_lists_palette_commands_and_apps_run_runs_them() {
    let f = fixture();
    f.install("cmux/demo");
    let demo = app_entry(&f.supervisor.list(), "cmux/demo");
    assert_eq!(
        demo["commands"],
        json!([{ "op": "demo.go", "title": "Go", "when": "paneFocused:editor" }])
    );
    let (tx, rx) = channel();
    f.supervisor.run(
        run_request("cmux/demo", "demo.go", None, Origin::User, None),
        Box::new(move |r| tx.send(r).unwrap()),
    );
    assert_eq!(
        rx.recv_timeout(Duration::from_secs(10)).unwrap().unwrap(),
        json!({ "value": "go" })
    );
}

#[test]
fn the_shipped_first_party_directory_is_the_default_set() {
    let root = temp_dir();
    let first_party = root.0.join("first-party");
    write_app(&first_party, "coderouter", "cmux/coderouter", json!({ "workspace:read": "r" }));
    write_app(&first_party, "impostor", "octo/impostor", json!({}));
    let catalog = super::catalog::load(&Sources {
        first_party: Some(first_party),
        bundled: vec![],
        local: None,
        defaults: None,
    });
    assert_eq!(catalog.defaults, vec!["cmux/coderouter".to_string()]);
    assert_eq!(catalog.packages["cmux/coderouter"].source, super::mirror::Source::Default);
    assert!(
        !catalog.packages.contains_key("octo/impostor"),
        "only first-party apps load from there"
    );
    // CMUX_APPS_DEFAULT replaces the shipped set.
    let overridden = super::catalog::load(&Sources {
        first_party: Some(root.0.join("first-party")),
        bundled: vec![],
        local: None,
        defaults: Some(vec![]),
    });
    assert!(overridden.defaults.is_empty());
    assert_eq!(overridden.packages["cmux/coderouter"].source, super::mirror::Source::Bundled);
}

#[test]
fn a_fresh_daemon_with_the_bundle_path_lists_coderouter_installed_by_default() {
    let root = temp_dir();
    let first_party = root.0.join("first-party");
    write_app(&first_party, "coderouter", "cmux/coderouter", json!({ "workspace:read": "r" }));
    let supervisor = Supervisor::new(
        Config {
            state_dir: Some(root.0.join("state")),
            host_binary: None,
            host_args: Vec::new(),
            sources: Sources {
                first_party: Some(first_party),
                bundled: vec![],
                local: None,
                defaults: None,
            },
            idle_stop: Duration::from_secs(60),
            provider_deadline: Duration::from_secs(30),
            provider_user_deadline: Duration::from_secs(600),
        },
        Box::new(Arc::new(FakeRouter::default())),
        Box::new(Arc::new(FakeFetcher::default())),
    );
    let coderouter = app_entry(&supervisor.list(), "cmux/coderouter");
    assert_eq!(
        (
            coderouter["installed"].clone(),
            coderouter["source"].clone(),
            coderouter["grants"].clone()
        ),
        (json!(true), json!("default"), json!(["workspace:read"]))
    );
    // Removing it leaves a tombstone: a restart does not install it again.
    let mut op = SetOp {
        key: "rm".into(),
        app: "cmux/coderouter".into(),
        origin: Origin::User,
        ..SetOp::default()
    };
    op.installed = Some(false);
    supervisor.set(CLIENT, op).unwrap();
    drop(supervisor);
    let again = Supervisor::new(
        Config {
            state_dir: Some(root.0.join("state")),
            host_binary: None,
            host_args: Vec::new(),
            sources: Sources {
                first_party: Some(root.0.join("first-party")),
                bundled: vec![],
                local: None,
                defaults: None,
            },
            idle_stop: Duration::from_secs(60),
            provider_deadline: Duration::from_secs(30),
            provider_user_deadline: Duration::from_secs(600),
        },
        Box::new(Arc::new(FakeRouter::default())),
        Box::new(Arc::new(FakeFetcher::default())),
    );
    assert_eq!(app_entry(&again.list(), "cmux/coderouter")["installed"], false);
}

/// Gate for the switch to the daemon supervisor: every bundled first-party
/// app (`first-party-apps/<name>/BUNDLED`) loads through the supervisor's
/// loader and the manifest v2 validator, preferring `cmux-app.v2.json`, and
/// is installed by default. No first-party app may vanish at the switch.
#[test]
fn every_bundled_first_party_app_loads_and_is_installed_by_default() {
    let tree = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../first-party-apps");
    let mut bundled: Vec<(String, PathBuf)> = std::fs::read_dir(&tree)
        .expect("first-party-apps")
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|dir| dir.join("BUNDLED").is_file())
        .map(|dir| {
            let file = super::catalog::manifest_file(&dir, true);
            let manifest: Value =
                serde_json::from_str(&std::fs::read_to_string(dir.join(file)).expect("manifest"))
                    .expect("json");
            (manifest["id"].as_str().unwrap_or_default().to_string(), dir)
        })
        .collect();
    bundled.sort();
    assert!(!bundled.is_empty(), "no bundled first-party app found in {}", tree.display());
    let root = temp_dir();
    let supervisor = Supervisor::new(
        Config {
            state_dir: Some(root.0.join("state")),
            host_binary: None,
            host_args: Vec::new(),
            sources: Sources {
                first_party: Some(tree.clone()),
                bundled: vec![],
                local: None,
                defaults: None,
            },
            idle_stop: Duration::from_secs(60),
            provider_deadline: Duration::from_secs(30),
            provider_user_deadline: Duration::from_secs(600),
        },
        Box::new(Arc::new(FakeRouter::default())),
        Box::new(Arc::new(FakeFetcher::default())),
    );
    let catalog = super::catalog::load(&Sources {
        first_party: Some(tree),
        bundled: vec![],
        local: None,
        defaults: None,
    });
    let list = supervisor.list();
    for (id, dir) in bundled {
        let why = catalog.rejected.iter().find(|(d, _)| *d == dir).map(|(_, issue)| issue.clone());
        assert!(
            catalog.packages.contains_key(&id),
            "{id} ({}) does not load: {why:?}",
            dir.display()
        );
        let entry = app_entry(&list, &id);
        assert_eq!(
            (entry["installed"].clone(), entry["source"].clone()),
            (json!(true), json!("default")),
            "{id}"
        );
    }
}
