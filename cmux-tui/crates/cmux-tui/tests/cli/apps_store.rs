//! The app supervisor through a real daemon socket (bead cx-9ce.2.28): App
//! Store ops (`apps-store`, `cmux.apps.*`) change apps only for the user,
//! first-party apps are hidden and never removed, `cmux.host.link.get`
//! answers from the link registration, and an app never reaches a
//! person-only or money op.
#![cfg(unix)]

use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_tui_core::server::frontend_proof::{NONCE_LEN, hello_proof, unhex};
use serde_json::{Value, json};

const KEY_HEX: &str = "8f0e1d2c3b4a59687766554433221100ffeeddccbbaa99887766554433221100";
const INSTALL_ID: &str = "inst_apps_store";

/// One daemon with its own state, app directories and scripted app host.
struct Apps {
    dir: PathBuf,
    socket: PathBuf,
    session: String,
}

impl Apps {
    fn new(name: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir =
            PathBuf::from("/tmp").join(format!("cmux-as-{name}-{}-{stamp}", std::process::id()));
        for sub in ["state", "first-party", "bundled", "servers"] {
            std::fs::create_dir_all(dir.join(sub)).unwrap();
        }
        // The app host: a script that answers init, makes the call named in
        // `<dir>/call.json` on mount, and records every resolve.
        let host = format!(
            "#!/bin/sh\nwhile IFS= read -r line <&3; do\n  case \"$line\" in\n    *'\"t\":\"init\"'*) printf '{{\"t\":\"ready\",\"runtime\":\"probe\"}}\\n' >&3 ;;\n    *'\"t\":\"mount\"'*) while IFS= read -r call; do printf '%s\\n' \"$call\" >&3; done < '{call}' ;;\n    *'\"t\":\"resolve\"'*) printf '%s\\n' \"$line\" >> '{out}' ;;\n  esac\ndone\n",
            call = dir.join("call.json").display(),
            out = dir.join("resolved.jsonl").display(),
        );
        write_script(&dir.join("app-host"), &host);
        Self { socket: dir.join("mux.sock"), session: format!("as-{name}"), dir }
    }

    fn command(&self, action: &str) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command
            .args(["server", action, "--json", "--session", &self.session, "--socket"])
            .arg(&self.socket)
            .env("CMUX_TUI_STATE_DIR", self.dir.join("state"))
            .env("CMUX_TUI_CONFIG", self.dir.join("config.json"))
            .env("CMUX_APP_HOST_BIN", self.dir.join("app-host"))
            .env("CMUX_APP_SERVER_DIR", self.dir.join("servers"))
            .env("CMUX_APPS_FIRST_PARTY_DIR", self.dir.join("first-party"))
            .env("CMUX_APPS_DIRS", self.dir.join("bundled"));
        command
    }

    /// Starts the daemon with the app's install key, so a connection can
    /// prove itself the verified cmux app.
    fn start(&self) {
        let mut child = self
            .command("ensure")
            .arg("--install-key-stdin")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let key = format!("cmuxik1 {INSTALL_ID} {KEY_HEX}\n");
        child.stdin.take().unwrap().write_all(key.as_bytes()).unwrap();
        let output: Output = child.wait_with_output().unwrap();
        assert!(
            output.status.success(),
            "ensure failed: {:?}\nstdout: {}\nstderr: {}",
            output.status,
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
    }

    /// A connection with no hello: the daemon derives origin agent.
    fn agent(&self) -> Client {
        let stream = UnixStream::connect(&self.socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(12))).unwrap();
        Client { reader: BufReader::new(stream), next: 100 }
    }

    /// The verified cmux app connection (install-key hello).
    fn app(&self) -> Client {
        let mut client = self.agent();
        let challenge =
            client.rpc(json!({ "cmd": "client-hello", "role": "main", "install_id": INSTALL_ID }));
        let nonce = unhex::<NONCE_LEN>(challenge["data"]["nonce"].as_str().unwrap()).unwrap();
        let proof = hello_proof(&unhex::<32>(KEY_HEX).unwrap(), INSTALL_ID, &nonce);
        let proved =
            client.rpc(json!({ "cmd": "client-hello", "install_id": INSTALL_ID, "proof": proof }));
        assert_eq!(proved["data"]["verified"], true, "{proved}");
        client
    }

    /// Waits for at least `count` lines in `<dir>/<file>` and parses them.
    fn lines(&self, file: &str, count: usize) -> Vec<Value> {
        let path = self.dir.join(file);
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            let text = std::fs::read_to_string(&path).unwrap_or_default();
            let lines: Vec<Value> =
                text.lines().filter_map(|l| serde_json::from_str(l).ok()).collect();
            if lines.len() >= count {
                return lines;
            }
            assert!(Instant::now() < deadline, "{} holds {text:?}", path.display());
            std::thread::sleep(Duration::from_millis(25));
        }
    }
}

impl Drop for Apps {
    fn drop(&mut self) {
        let _ = self.command("stop").arg("--end-terminals").output();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

struct Client {
    reader: BufReader<UnixStream>,
    next: u64,
}

impl Client {
    /// Sends `request` with a fresh id and returns the reply with that id
    /// (apps events may arrive in between).
    fn rpc(&mut self, mut request: Value) -> Value {
        self.next += 1;
        request["id"] = json!(self.next);
        writeln!(self.reader.get_mut(), "{request}").unwrap();
        loop {
            let mut line = String::new();
            assert_ne!(self.reader.read_line(&mut line).unwrap(), 0, "the daemon closed");
            let reply: Value = serde_json::from_str(&line).unwrap();
            if reply["id"] == json!(self.next) {
                return reply;
            }
        }
    }

    /// An App Store op; `origin` is the claimed origin.
    fn store(&mut self, op: &str, args: Value, origin: &str) -> Value {
        self.rpc(json!({ "cmd": "apps-store", "op": op, "args": args, "origin": origin }))
    }
}

fn error_code(reply: &Value) -> &str {
    reply["error_code"].as_str().unwrap_or_else(|| panic!("expected a refusal: {reply}"))
}

fn ok(reply: &Value) -> &Value {
    assert_eq!(reply["ok"], true, "{reply}");
    &reply["data"]
}

fn write_script(path: &Path, body: &str) {
    std::fs::write(path, body).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

/// Writes app `<publisher>/<dir>` into `root` with `extra` merged into its
/// manifest v2.
fn write_app(root: &Path, publisher: &str, dir: &str, extra: Value) {
    let app = root.join(dir);
    std::fs::create_dir_all(&app).unwrap();
    // A store app's repository owner is its publisher; cmux's is manaflow-ai.
    let owner = if publisher == "cmux" { "manaflow-ai" } else { publisher };
    let mut manifest = json!({
        "manifestVersion": 2, "id": format!("{publisher}/{dir}"), "name": dir, "version": "1.0.0",
        "description": "d", "engines": { "cmux": "^2.0" },
        "repository": format!("https://github.com/{owner}/{dir}"),
    });
    for (key, value) in extra.as_object().unwrap() {
        manifest[key] = value.clone();
    }
    std::fs::write(app.join("cmux-app.v2.json"), manifest.to_string()).unwrap();
}

fn listing<'a>(catalog: &'a Value, app: &str) -> &'a Value {
    catalog["listings"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["app"] == app)
        .unwrap_or_else(|| panic!("{app} not listed: {catalog}"))
}

/// An agent never changes an app; the verified app changes one only with
/// origin user, for every field; a first-party app is hidden, never
/// removed; a third-party app installs and uninstalls for the user.
#[test]
fn app_store_changes_need_the_user_and_first_party_apps_are_hide_only() {
    let apps = Apps::new("store");
    write_app(&apps.dir.join("first-party"), "cmux", "fp", json!({}));
    write_app(
        &apps.dir.join("first-party"),
        "cmux",
        "quiet",
        json!({ "presentation": { "hiddenByDefault": true } }),
    );
    write_app(&apps.dir.join("bundled"), "acme", "tool", json!({}));
    apps.start();

    // Reads need no user; first-party apps are default, hide-only, and a
    // hiddenByDefault app starts installed but hidden.
    let mut agent = apps.agent();
    let reply = agent.store("cmux.apps.catalog.list", json!({}), "cli");
    let catalog = ok(&reply);
    let fp = listing(catalog, "cmux/fp");
    assert_eq!(
        (fp["hide_only"].clone(), fp["install"]["installed"].clone()),
        (json!(true), json!(true)),
        "{fp}"
    );
    let quiet = listing(catalog, "cmux/quiet");
    assert_eq!(
        (quiet["install"]["installed"].clone(), quiet["install"]["hidden"].clone()),
        (json!(true), json!(true)),
        "{quiet}"
    );
    let tool = listing(catalog, "acme/tool");
    assert_eq!(
        (tool["hide_only"].clone(), tool["install"].clone()),
        (json!(false), Value::Null),
        "{tool}"
    );

    // An agent connection changes nothing, whatever origin it claims.
    for (key, field) in [("a1", "enabled"), ("a2", "hidden")] {
        let args = json!({ "app": "cmux/fp", field: field == "hidden", "idempotency_key": key });
        let refused = agent.store("cmux.apps.set", args.clone(), "cli");
        assert_eq!(error_code(&refused), "origin.forbidden", "{refused}");
        let refused = agent.store("cmux.apps.set", args, "user");
        assert_eq!(error_code(&refused), "origin.forbidden", "{refused}");
    }
    let refused = agent.rpc(
        json!({ "cmd": "apps-set", "idempotency_key": "a3", "app": "cmux/fp", "enabled": false }),
    );
    assert_eq!(error_code(&refused), "origin.forbidden", "{refused}");

    // On the verified app connection, an agent-like origin changes no field.
    let mut app = apps.app();
    for (key, field, value) in
        [("s1", "enabled", false), ("s2", "hidden", true), ("s3", "sandboxed", true)]
    {
        let args = json!({ "app": "cmux/fp", field: value, "idempotency_key": key });
        let refused = app.store("cmux.apps.set", args, "script");
        assert_eq!(error_code(&refused), "apps.origin", "{field}: {refused}");
    }
    let refused = app.rpc(json!({ "cmd": "apps-set", "origin": "mcp", "idempotency_key": "s4", "app": "cmux/fp", "hidden": true }));
    assert_eq!(error_code(&refused), "apps.origin", "{refused}");

    // Origin user works, for enable and hide alike.
    let reply = app.store(
        "cmux.apps.set",
        json!({ "app": "cmux/fp", "enabled": false, "idempotency_key": "u1" }),
        "user",
    );
    assert_eq!(ok(&reply)["app"]["state"]["enabled"], false, "{reply}");
    let reply = app.store(
        "apps.set",
        json!({ "app": "cmux/fp", "hidden": true, "idempotency_key": "u2" }),
        "user",
    );
    assert_eq!(ok(&reply)["app"]["state"]["hidden"], true, "{reply}");

    // A first-party app is never removed, through either door.
    let refused = app.store(
        "cmux.apps.uninstall",
        json!({ "app": "cmux/fp", "idempotency_key": "u3" }),
        "user",
    );
    assert_eq!(error_code(&refused), "apps.first_party_hide_only", "{refused}");
    let refused = app.rpc(json!({ "cmd": "apps-set", "origin": "user", "idempotency_key": "u4", "app": "cmux/quiet", "installed": false }));
    assert_eq!(error_code(&refused), "apps.first_party_hide_only", "{refused}");
    let reply = app.store("cmux.apps.installed.list", json!({}), "cli");
    let installed: Vec<&str> =
        ok(&reply)["apps"].as_array().unwrap().iter().filter_map(|a| a["app"].as_str()).collect();
    assert!(installed.contains(&"cmux/fp") && installed.contains(&"cmux/quiet"), "{reply}");

    // A third-party app installs and uninstalls for the user only.
    let refused = app.store(
        "cmux.apps.install",
        json!({ "app": "acme/tool", "idempotency_key": "t0" }),
        "script",
    );
    assert_eq!(error_code(&refused), "apps.origin", "{refused}");
    let reply = app.store(
        "cmux.apps.install",
        json!({ "app": "acme/tool", "idempotency_key": "t1" }),
        "user",
    );
    assert_eq!(ok(&reply)["app"]["state"]["installed"], true, "{reply}");
    let reply = app.store(
        "cmux.apps.uninstall",
        json!({ "app": "acme/tool", "idempotency_key": "t2" }),
        "user",
    );
    assert_eq!(ok(&reply)["app"]["state"]["installed"], false, "{reply}");
}

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

/// A registration that names a live process which does not serve the
/// socket is not a link: the daemon answers no hub socket, so a process
/// cannot point first-party apps at a socket it serves by naming another
/// process.
#[test]
fn host_link_get_refuses_a_socket_served_by_another_process() {
    let mut bystander = Command::new("sleep").arg("60").spawn().unwrap();
    let bystander_pid = bystander.id();
    let (reply, _hub) = host_link_get("linkpid", |state, hub| {
        cmux_link::registration::write(
            state,
            &cmux_link::registration::Registration::new(hub.to_path_buf(), bystander_pid),
        )
        .unwrap();
    });
    let _ = bystander.kill();
    let _ = bystander.wait();
    assert_eq!(reply["value"]["hub_socket"], Value::Null, "{reply}");
}

/// A registration file that another user could have written (mode 0666)
/// is not trusted, even when its pid serves the socket.
#[test]
fn host_link_get_refuses_a_world_writable_registration() {
    let (reply, _hub) = host_link_get("linkmode", |state, hub| {
        cmux_link::registration::write(
            state,
            &cmux_link::registration::Registration::new(hub.to_path_buf(), std::process::id()),
        )
        .unwrap();
        let file = cmux_link::registration::path(state);
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o666)).unwrap();
    });
    assert_eq!(reply["value"]["hub_socket"], Value::Null, "{reply}");
}

/// Start a daemon whose state dir holds the link registration `register`
/// writes (given the state dir and a socket this test serves), with a
/// first-party app whose always-on server asks `cmux.host.link.get` at
/// start. The app's recorded `host.result` and the served socket.
fn host_link_get(name: &str, register: impl FnOnce(&Path, &Path)) -> (Value, PathBuf) {
    let apps = Apps::new(name);
    let hub = apps.dir.join("hub.sock");
    let _listener = UnixListener::bind(&hub).unwrap();
    register(&apps.dir.join("state"), &hub);
    // A first-party app whose always-on server asks for the link at start
    // and records the answer.
    write_script(
        &apps.dir.join("servers").join("host-probe"),
        "#!/bin/sh\nprintf '{\"t\":\"host.request\",\"id\":7,\"op\":\"cmux.host.link.get\",\"params\":{}}\\n'\nwhile IFS= read -r line; do\n  printf '%s\\n' \"$line\" >> \"$1\"\ndone\n",
    );
    let app = apps.dir.join("first-party").join("linked");
    std::fs::create_dir_all(&app).unwrap();
    let catalog = json!({ "family": "linked", "operations": [{
        "name": "linked.ping", "owner": "app:cmux/linked", "class": "read", "risk": "read",
        "idempotency": "forbidden", "input": { "type": "object" }, "docs": "d", "since": "linked/1"
    }] });
    std::fs::write(app.join("catalog.json"), catalog.to_string()).unwrap();
    let out = apps.dir.join("link.jsonl");
    write_app(
        &apps.dir.join("first-party"),
        "cmux",
        "linked",
        json!({
            "catalog": "catalog.json", "files": ["catalog.json"],
            "scopes": { "linked:read": "Read." },
            "server": {
                "kind": "native",
                "binaries": { "darwin-arm64": "host-probe", "darwin-x64": "host-probe", "linux-arm64": "host-probe", "linux-x64": "host-probe" },
                "args": [out.to_string_lossy()],
                "instances": "machine", "hosts": ["local"], "lifecycle": { "start": "always" },
                "scopes": { "op:cmux.host.link.get": "Read where the link helper lives." }
            }
        }),
    );
    apps.start();
    ok(&apps.agent().rpc(json!({ "cmd": "apps-list" })));

    let reply = apps.lines("link.jsonl", 1).swap_remove(0);
    assert_eq!(
        (reply["t"].clone(), reply["id"].clone()),
        (json!("host.result"), json!(7)),
        "{reply}"
    );
    (reply, hub)
}

/// An app holding the family scope still never reaches an op only a
/// signed-in person may call (no install principal) or one that moves
/// money: the supervisor refuses the call before routing it.
#[test]
fn person_only_and_money_ops_never_reach_an_app() {
    let apps = Apps::new("never");
    let calls = [
        json!({ "t": "call", "cb": 1, "name": "integration.connect", "params": { "provider": "github" }, "options": {} }),
        json!({ "t": "call", "cb": 2, "name": "usage.cap.set", "params": {}, "options": {} }),
        json!({ "t": "call", "cb": 3, "name": "cloud.machine.link_token", "params": {}, "options": {} }),
    ];
    let lines: Vec<String> = calls.iter().map(Value::to_string).collect();
    std::fs::write(apps.dir.join("call.json"), lines.join("\n") + "\n").unwrap();
    let app = apps.dir.join("first-party").join("probe");
    std::fs::create_dir_all(app.join("dist")).unwrap();
    std::fs::write(app.join("dist").join("main.js"), "function render() {}\n").unwrap();
    write_app(
        &apps.dir.join("first-party"),
        "cmux",
        "probe",
        json!({
            "runtime": { "main": "dist/main.js" }, "files": ["dist/"],
            "implements": { "cmux.status/1": { "export": "render", "title": "Probe", "symbol": "circle", "options": { "placement": "titlebar" } } },
            "scopes": { "integration:write": "Connect.", "usage:write": "Cap.", "cloud:execute": "Dial." }
        }),
    );
    apps.start();
    let mut agent = apps.agent();
    ok(&agent.rpc(json!({ "cmd": "apps-mount", "app": "cmux/probe", "interface": "cmux.status/1", "mount_id": "m1", "context": {} })));

    let resolved = apps.lines("resolved.jsonl", calls.len());
    for call in &calls {
        let reply = resolved
            .iter()
            .find(|reply| reply["cb"] == call["cb"])
            .unwrap_or_else(|| panic!("no resolve for {call}: {resolved:?}"));
        assert_eq!(
            (
                reply["cb"].clone(),
                reply["ok"].clone(),
                reply["body"]["code"].clone(),
                reply["body"]["message"].clone()
            ),
            (
                call["cb"].clone(),
                json!(false),
                json!("scope.missing"),
                json!("this op is not available to apps")
            ),
            "{} -> {reply}",
            call["name"],
        );
    }
}
