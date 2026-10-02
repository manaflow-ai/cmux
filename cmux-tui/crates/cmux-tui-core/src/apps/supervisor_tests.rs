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
                send(FromHost::Call {
                    cb,
                    name: payload["op"].as_str().unwrap_or_default().into(),
                    params: payload["params"].clone(),
                    options,
                });
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
            ToHost::Run { cb, export, .. } => {
                if export == "crash" {
                    std::process::exit(70);
                }
                send(FromHost::Done { cb, ok: true, body: json!({ "value": export }) });
            }
            ToHost::Event { sub, .. } => {
                send(FromHost::Log { level: "info".into(), message: format!("event {sub}") })
            }
            ToHost::Unmount { .. } | ToHost::Settings { .. } => {}
            ToHost::Shutdown => break,
        }
    }
    std::process::exit(0);
}

// MARK: fixtures

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
    std::fs::write(app.join("catalog.json"), json!({ "operations": { "demo.go": { "export": "go" }, "demo.crash": { "export": "crash" } } }).to_string()).unwrap();
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
            json!({ "workspace:write": "w", "storage:local": "s", "net:api.example.com": "n" }),
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
                bundled: vec![bundled],
                local: Some(state.join("apps/local")),
                defaults: defaults.iter().map(|s| s.to_string()).collect(),
            },
            idle_stop: idle,
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
    assert_eq!(demo["grants"], json!(["net:api.example.com", "storage:local", "workspace:write"]));
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
        key.as_deref().is_some_and(|k| k.starts_with("app-")),
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
    f.supervisor.run("cmux/demo", "demo.go", json!({}), Box::new(move |r| tx.send(r).unwrap()));
    assert_eq!(
        rx.recv_timeout(Duration::from_secs(10)).unwrap().unwrap(),
        json!({ "value": "go" })
    );
    f.mount("m1", "cmux/demo", "cmux.section/1", json!({}));
    f.supervisor.run("cmux/demo", "demo.crash", json!({}), Box::new(move |r| tx2.send(r).unwrap()));
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
