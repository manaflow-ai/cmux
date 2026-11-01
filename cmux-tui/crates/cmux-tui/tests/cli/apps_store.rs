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
    /// The daemon's `XDG_RUNTIME_DIR`; `None` runs it with none.
    runtime: Option<PathBuf>,
    /// The daemon's customization folder (`CMUX_CUSTOMIZE_DIR`).
    customize: PathBuf,
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
        Self {
            socket: dir.join("mux.sock"),
            session: format!("as-{name}"),
            customize: dir.join("customize"),
            dir,
            runtime: None,
        }
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
            .env("CMUX_APPS_DIRS", self.dir.join("bundled"))
            .env("CMUX_CUSTOMIZE_DIR", &self.customize);
        // Fake remote tools (`ssh`, `docker`, ...) a test puts in `<dir>/bin` come first.
        if self.dir.join("bin").is_dir() {
            let path = std::env::var_os("PATH").unwrap_or_default();
            let mut dirs = vec![self.dir.join("bin")];
            dirs.extend(std::env::split_paths(&path));
            command.env("PATH", std::env::join_paths(dirs).unwrap());
        }
        // By default a daemon with no login session (cx-9mmyz: rbx, containers,
        // cron) has no runtime dir, and its `<state>/apps-tmp/<ns>` is too long
        // for a socket path: app servers must still get a socket folder.
        match &self.runtime {
            Some(runtime) => command.env("XDG_RUNTIME_DIR", runtime),
            None => command.env_remove("XDG_RUNTIME_DIR"),
        };
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

    /// The next event line named `name` (other events and replies are
    /// skipped; the read timeout bounds the wait).
    fn event(&mut self, name: &str) -> Value {
        loop {
            let mut line = String::new();
            assert_ne!(self.reader.read_line(&mut line).unwrap(), 0, "the daemon closed");
            let value: Value = serde_json::from_str(&line).unwrap();
            if value["event"] == name {
                return value;
            }
        }
    }

    /// An App Store op; `origin` is the claimed origin.
    fn store(&mut self, op: &str, args: Value, origin: &str) -> Value {
        self.rpc(json!({ "cmd": "apps-store", "op": op, "args": args, "origin": origin }))
    }

    /// A `cmux.protocol/2` request as a page host sends it (selectors
    /// current, a string id); `extra` adds envelope members.
    fn v2(&mut self, operation: &str, params: Value, extra: Value) -> Value {
        self.next += 1;
        let id = format!("v2-{}", self.next);
        let mut params = params;
        params["machine"] = json!("current");
        params["session"] = json!("current");
        let mut request = json!({
            "protocol": "cmux.protocol/2", "type": "request", "id": id,
            "operation": operation, "params": params,
        });
        for (key, value) in extra.as_object().unwrap() {
            request[key] = value.clone();
        }
        writeln!(self.reader.get_mut(), "{request}").unwrap();
        loop {
            let mut line = String::new();
            assert_ne!(self.reader.read_line(&mut line).unwrap(), 0, "the daemon closed");
            let reply: Value = serde_json::from_str(&line).unwrap();
            if reply["id"] == json!(id) {
                return reply;
            }
        }
    }
}

fn v2_ok(reply: &Value) -> &Value {
    assert_eq!(reply["ok"], true, "{reply}");
    &reply["result"]
}

fn v2_reason(reply: &Value) -> &str {
    assert_eq!(reply["ok"], false, "{reply}");
    assert_eq!(reply["error"]["code"], "origin.forbidden", "{reply}");
    reply["error"]["details"]["reason"].as_str().unwrap_or_default()
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

/// With a runtime dir (a login session), a state path too long for a socket
/// puts the app's socket folder under `$XDG_RUNTIME_DIR/cmux-apps`, a 0700
/// folder; without one it goes under `/tmp/cmux-apps-<uid>` (cx-9mmyz).
#[cfg(target_os = "linux")]
#[test]
fn app_socket_folder_uses_the_runtime_dir_else_a_per_user_tmp_folder() {
    let mut apps = Apps::new("rundir");
    let runtime = apps.dir.join("run");
    std::fs::create_dir(&runtime).unwrap();
    std::fs::set_permissions(&runtime, std::fs::Permissions::from_mode(0o700)).unwrap();
    apps.runtime = Some(runtime.clone());
    write_probe_app(&apps);
    apps.start();
    ok(&apps.agent().rpc(json!({ "cmd": "apps-list" })));
    let reply = apps.lines("link.jsonl", 1).swap_remove(0);
    assert_eq!(reply["t"], json!("host.result"), "{reply}");
    let socket_dir = PathBuf::from(reply["value"]["socket_dir"].as_str().unwrap());
    assert_eq!(socket_dir.parent(), Some(runtime.join("cmux-apps").as_path()), "{reply}");
    let meta = std::fs::symlink_metadata(&socket_dir).unwrap();
    assert_eq!(meta.permissions().mode() & 0o777, 0o700, "{}", socket_dir.display());

    let apps = Apps::new("notmp");
    write_probe_app(&apps);
    apps.start();
    ok(&apps.agent().rpc(json!({ "cmd": "apps-list" })));
    let reply = apps.lines("link.jsonl", 1).swap_remove(0);
    assert_eq!(reply["t"], json!("host.result"), "{reply}");
    let socket_dir = PathBuf::from(reply["value"]["socket_dir"].as_str().unwrap());
    // SAFETY: geteuid has no preconditions.
    let uid = unsafe { libc::geteuid() };
    let parent = PathBuf::from(format!("/tmp/cmux-apps-{uid}"));
    assert_eq!(socket_dir.parent(), Some(parent.as_path()), "{reply}");
    let meta = std::fs::symlink_metadata(&parent).unwrap();
    assert_eq!(meta.permissions().mode() & 0o777, 0o700, "{}", parent.display());
}

/// A registration that names a live process which does not serve the
/// socket is not a link: the daemon answers no hub socket, so a process
/// cannot point first-party apps at a socket it serves by naming another
/// process. Only where the system names the peer pid (Linux, macOS); the
/// other BSDs check the uid only.
#[cfg(any(target_os = "linux", target_os = "android", target_vendor = "apple"))]
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
    write_probe_app(&apps);
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

/// A first-party app whose always-on server asks `cmux.host.link.get` at
/// start and records every line it gets in `<dir>/link.jsonl`.
fn write_probe_app(apps: &Apps) {
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
}

/// cx-rtipa review P2-1: a link whose probe does not finish is unknown, not
/// "no link": `link.get` answers `apps.link_probe_timeout` (retryable), and
/// `apps-link-changed` sends that server nothing. The link here is a socket
/// of this test with a full accept queue (listen backlog 0, filled), so the
/// daemon's probe connect blocks. Linux only: there a connect to a full
/// queue waits; macOS refuses it at once.
#[cfg(target_os = "linux")]
#[test]
fn a_link_probe_that_times_out_is_unknown_not_no_link() {
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    let apps = Apps::new("probetime");
    let hub = apps.dir.join("hub.sock");
    let address = |path: &Path| {
        // SAFETY: sockaddr_un is plain data; all-zero is a valid value.
        let mut addr: libc::sockaddr_un = unsafe { std::mem::zeroed() };
        addr.sun_family = libc::AF_UNIX as libc::sa_family_t;
        for (slot, byte) in addr.sun_path.iter_mut().zip(path.as_os_str().as_encoded_bytes()) {
            *slot = *byte as libc::c_char;
        }
        addr
    };
    let len = size_of::<libc::sockaddr_un>() as libc::socklen_t;
    let socket = |flags: libc::c_int| {
        // SAFETY: a new socket descriptor this test owns.
        let fd = unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_STREAM | flags, 0) };
        assert!(fd >= 0);
        // SAFETY: as above.
        unsafe { OwnedFd::from_raw_fd(fd) }
    };
    let listener = socket(0);
    let addr = address(&hub);
    // SAFETY: bind and listen on the test's own socket.
    unsafe {
        assert_eq!(libc::bind(listener.as_raw_fd(), (&raw const addr).cast(), len), 0);
        assert_eq!(libc::listen(listener.as_raw_fd(), 0), 0);
    }
    // Fill the accept queue with non-blocking connects until it refuses.
    let mut queued = Vec::new();
    loop {
        let client = socket(libc::SOCK_NONBLOCK);
        // SAFETY: connect of the test's own socket.
        let rc = unsafe { libc::connect(client.as_raw_fd(), (&raw const addr).cast(), len) };
        if rc != 0 {
            let error = std::io::Error::last_os_error();
            assert_eq!(error.raw_os_error(), Some(libc::EAGAIN), "fill the accept queue: {error}");
            break;
        }
        queued.push(client);
        assert!(queued.len() < 64, "the accept queue never filled");
    }
    cmux_link::registration::write(
        &apps.dir.join("state"),
        &cmux_link::registration::Registration::new(hub, std::process::id()),
    )
    .unwrap();
    write_probe_app(&apps);
    apps.start();
    ok(&apps.agent().rpc(json!({ "cmd": "apps-list" })));
    let reply = apps.lines("link.jsonl", 1).swap_remove(0);
    assert_eq!(
        (reply["t"].clone(), reply["code"].clone(), reply["retryable"].clone()),
        (json!("host.error"), json!("apps.link_probe_timeout"), json!(true)),
        "a probe timeout was reported as: {reply}"
    );
    let told = apps.app().rpc(json!({ "cmd": "apps-link-changed" }));
    assert_eq!(ok(&told)["servers"], 0, "{told}");
    let lines = std::fs::read_to_string(apps.dir.join("link.jsonl")).unwrap();
    assert_eq!(
        lines.lines().count(),
        1,
        "link.changed sent an event while the link was unknown: {lines}"
    );
    drop(queued);
}

/// cx-rtipa S2: a link that `cmux link ensure` starts after an app server
/// read "no link" reaches that server at once: the app sends
/// `apps-link-changed`, and the server gets `cmux.host.link.changed` with the
/// new link's socket. `cmux link stop` and another `apps-link-changed` take
/// it away again. A connection that is not the verified app is refused.
#[test]
fn apps_link_changed_tells_servers_the_link_that_ensure_started() {
    let apps = Apps::new("ensured");
    let out = apps.dir.join("link.jsonl");
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
    let first = apps.lines("link.jsonl", 1).swap_remove(0);
    assert_eq!(first["value"]["hub_socket"], Value::Null, "no link runs yet: {first}");

    let state = apps.dir.join("state");
    let link = |args: &[&str]| -> Value {
        let output = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .arg("link")
            .args(args)
            .arg("--state-dir")
            .arg(state.join("link"))
            .env("CMUX_TUI_STATE_DIR", &state)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "link {args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        let text = String::from_utf8_lossy(&output.stdout).into_owned();
        serde_json::from_str(text.lines().last().unwrap_or_default()).unwrap()
    };
    let started = link(&["ensure", "--install", "inst_apps_store_link", "--port", "0"]);
    assert_eq!(started["status"], "started", "{started}");
    // Only the verified cmux app reports a link change: an agent
    // connection is refused and tells no server.
    let refused = apps.agent().rpc(json!({ "cmd": "apps-link-changed" }));
    assert_eq!(error_code(&refused), "origin.forbidden", "{refused}");
    let told = apps.app().rpc(json!({ "cmd": "apps-link-changed" }));
    assert_eq!(ok(&told)["servers"], 1, "{told}");
    let changed = apps.lines("link.jsonl", 2).swap_remove(1);
    assert_eq!(
        (changed["t"].clone(), changed["op"].clone(), changed["data"]["hub_socket"].clone()),
        (json!("host.event"), json!("cmux.host.link.changed"), started["socket"].clone()),
        "{changed}"
    );

    assert_eq!(link(&["stop"])["stopped"], true);
    ok(&apps.app().rpc(json!({ "cmd": "apps-link-changed" })));
    let gone = apps.lines("link.jsonl", 3).swap_remove(2);
    assert_eq!(gone["data"]["hub_socket"], Value::Null, "the stopped link is gone: {gone}");
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

/// A first-party app whose always-on server asks `cmux.host.link.get` at
/// start and again once `<dir>/again` exists, recording each answer in
/// `<dir>/link.jsonl` (cx-wmd8x).
fn write_linked_app(apps: &Apps) {
    write_script(
        &apps.dir.join("servers").join("host-probe"),
        "#!/bin/sh\nprintf '{\"t\":\"host.request\",\"id\":7,\"op\":\"cmux.host.link.get\",\"params\":{}}\\n'\n(while [ ! -e \"$2\" ]; do sleep 0.05; done; printf '{\"t\":\"host.request\",\"id\":8,\"op\":\"cmux.host.link.get\",\"params\":{}}\\n') &\nwaiter=$!\nwhile IFS= read -r line; do\n  printf '%s\\n' \"$line\" >> \"$1\"\ndone\nkill $waiter 2>/dev/null\n",
    );
    let app = apps.dir.join("first-party").join("linked");
    std::fs::create_dir_all(&app).unwrap();
    let catalog = json!({ "family": "linked", "operations": [{
        "name": "linked.ping", "owner": "app:cmux/linked", "class": "read", "risk": "read",
        "idempotency": "forbidden", "input": { "type": "object" }, "docs": "d", "since": "linked/1"
    }] });
    std::fs::write(app.join("catalog.json"), catalog.to_string()).unwrap();
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
                "args": [apps.dir.join("link.jsonl").to_string_lossy(), apps.dir.join("again").to_string_lossy()],
                "instances": "machine", "hosts": ["local"], "lifecycle": { "start": "always" },
                "scopes": { "op:cmux.host.link.get": "Read where the link helper lives." }
            }
        }),
    );
}

/// Stops the daemon and waits until its socket refuses connections, so the
/// next `ensure` of the same session never meets an owner that is still ending.
fn stop_daemon(apps: &Apps) {
    let output = apps.command("stop").output().unwrap();
    assert!(output.status.success(), "stop failed: {}", String::from_utf8_lossy(&output.stderr));
    let deadline = Instant::now() + Duration::from_secs(20);
    while UnixStream::connect(&apps.socket).is_ok() {
        assert!(Instant::now() < deadline, "the daemon did not stop");
        std::thread::sleep(Duration::from_millis(25));
    }
}

/// The `apps-logs` lines of `app` once one holds `needle` (or every line after 20 s).
fn log_with(apps: &Apps, app: &str, needle: &str) -> Vec<String> {
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let reply = apps.agent().rpc(json!({ "cmd": "apps-logs", "app": app }));
        let lines: Vec<String> = ok(&reply)["lines"]
            .as_array()
            .unwrap()
            .iter()
            .map(|l| l["message"].as_str().unwrap_or_default().to_string())
            .collect();
        if lines.iter().any(|l| l.contains(needle)) || Instant::now() > deadline {
            return lines;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// cx-wmd8x: the app server's temporary folder is also its socket folder
/// (`socket_dir` of `cmux.host.link.get`), a trust boundary. Through the
/// daemon: a folder that is a symlink, or that other users may open, is never
/// emptied or used; the server does not start and nothing it would have
/// answered is sent. A clean start answers a 0700 folder short enough for the
/// link socket; once that folder opens to other users, the next link answer
/// refuses.
#[test]
fn app_socket_folder_refuses_a_symlink_or_an_open_folder() {
    for case in ["symlink", "open"] {
        let apps = Apps::new(&format!("sd{case}{}", std::process::id()));
        write_linked_app(&apps);
        // A first start names the folder this daemon's app uses.
        apps.start();
        ok(&apps.agent().rpc(json!({ "cmd": "apps-list" })));
        let first = apps.lines("link.jsonl", 1).swap_remove(0);
        let leaf = PathBuf::from(first["value"]["socket_dir"].as_str().unwrap());
        // The person turns the app off: its server stops and its folder goes with it.
        let mut app = apps.app();
        let set = |app: &mut Client, enabled: bool, key: &str| {
            let args = json!({ "app": "cmux/linked", "enabled": enabled, "idempotency_key": key });
            ok(&app.store("cmux.apps.set", args, "user")).clone()
        };
        set(&mut app, false, &format!("{case}-off"));
        let deadline = Instant::now() + Duration::from_secs(20);
        while std::fs::symlink_metadata(&leaf).is_ok() {
            assert!(Instant::now() < deadline, "{case}: the stopped server's folder stays");
            std::thread::sleep(Duration::from_millis(25));
        }
        std::fs::remove_file(apps.dir.join("link.jsonl")).unwrap();
        // Then another process of the user puts a folder of its own there.
        let elsewhere = apps.dir.join("elsewhere");
        std::fs::create_dir_all(&elsewhere).unwrap();
        std::fs::write(elsewhere.join("keep"), "x").unwrap();
        if case == "symlink" {
            std::os::unix::fs::symlink(&elsewhere, &leaf).unwrap();
        } else {
            std::fs::create_dir(&leaf).unwrap();
            std::fs::set_permissions(&leaf, std::fs::Permissions::from_mode(0o755)).unwrap();
            std::fs::write(leaf.join("keep"), "x").unwrap();
        }
        // Turned on again, the server's start refuses that folder.
        set(&mut app, true, &format!("{case}-on"));
        let lines = log_with(&apps, "cmux/linked", "app socket folder");
        assert!(
            lines.iter().any(|l| l.contains("app socket folder")),
            "{case}: the server start must refuse the folder: {lines:?}"
        );
        assert!(!apps.dir.join("link.jsonl").exists(), "{case}: a refused server answered nothing");
        let kept = if case == "symlink" { elsewhere.join("keep") } else { leaf.join("keep") };
        assert!(kept.exists(), "{case}: a refused folder is never emptied");
        // The planted folder may be outside the test dir (macOS: the per-user temp dir).
        if case == "symlink" {
            std::fs::remove_file(&leaf).unwrap();
        } else {
            std::fs::remove_dir_all(&leaf).unwrap();
        }
    }

    let apps = Apps::new(&format!("sdclean{}", std::process::id()));
    write_linked_app(&apps);
    apps.start();
    ok(&apps.agent().rpc(json!({ "cmd": "apps-list" })));
    let first = apps.lines("link.jsonl", 1).swap_remove(0);
    assert_eq!(
        (first["t"].clone(), first["id"].clone()),
        (json!("host.result"), json!(7)),
        "{first}"
    );
    let socket_dir = PathBuf::from(first["value"]["socket_dir"].as_str().unwrap());
    assert!(socket_dir.as_os_str().len() <= 104 - 1 - 27, "{}", socket_dir.display());
    let meta = std::fs::symlink_metadata(&socket_dir).unwrap();
    assert!(meta.is_dir() && !meta.file_type().is_symlink());
    assert_eq!(meta.permissions().mode() & 0o777, 0o700, "{}", socket_dir.display());
    std::fs::set_permissions(&socket_dir, std::fs::Permissions::from_mode(0o755)).unwrap();
    std::fs::write(apps.dir.join("again"), "").unwrap();
    let second = apps.lines("link.jsonl", 2).swap_remove(1);
    assert_eq!(
        (second["t"].clone(), second["id"].clone(), second["code"].clone()),
        (json!("host.error"), json!(8), json!("apps.socket_dir_unsafe")),
        "{second}"
    );
    // And the server stops: it never keeps binding in a folder that failed its check.
    let lines =
        log_with(&apps, "cmux/linked", "server stopping: its socket folder failed its check");
    assert!(
        lines.iter().any(|l| l.contains("server stopping: its socket folder failed its check")),
        "{lines:?}"
    );
    stop_daemon(&apps);
    let _ = std::fs::remove_dir_all(&socket_dir);
}

/// The App Store answers v2 `apps.*` requests (page-router-v1 routed
/// namespace) on every page host: a plain connection, the app's page relay
/// for page `apps`; another page's relay is refused, and an install from the
/// Apps page needs the person's confirmation (a token the verified app
/// minted for exactly that request).
#[test]
fn the_app_store_answers_v2_namespace_requests_for_the_apps_page() {
    use sha2::Digest;
    let apps = Apps::new("v2");
    write_app(&apps.dir.join("first-party"), "cmux", "fp", json!({}));
    write_app(&apps.dir.join("bundled"), "acme", "tool", json!({}));
    apps.start();

    // A plain connection reads the catalog through the v2 name.
    let mut agent = apps.agent();
    let reply = agent.v2("apps.catalog.list", json!({}), json!({}));
    let catalog = v2_ok(&reply);
    assert_eq!(listing(catalog, "acme/tool")["install"], Value::Null, "{reply}");
    let detail = agent.v2("apps.catalog.get", json!({"app": "cmux/fp"}), json!({}));
    assert_eq!(v2_ok(&detail)["app"], "cmux/fp", "{detail}");
    // An agent installs nothing (Gate A2).
    let refused =
        agent.v2("apps.install", json!({"app": "acme/tool"}), json!({"idempotency_key": "g0"}));
    assert_eq!(refused["error"]["details"]["required"], "user", "{refused}");

    // The Apps page's relay reads the catalog; another page's relay may not.
    let mut relay = apps.agent();
    let hello = relay.rpc(json!({"cmd": "client-hello", "role": "page_relay", "page": "apps"}));
    let relay_id = ok(&hello)["connection_id"].as_str().unwrap().to_owned();
    let page = json!({"origin": {"claim": "page"}});
    let reply = relay.v2("apps.catalog.list", json!({}), page.clone());
    assert!(v2_ok(&reply)["listings"].as_array().is_some_and(|l| !l.is_empty()), "{reply}");
    let mut history = apps.agent();
    history.rpc(json!({"cmd": "client-hello", "role": "page_relay", "page": "history"}));
    let refused = history.v2("apps.catalog.list", json!({}), page);
    assert_eq!(v2_reason(&refused), "page_not_allowed");

    // An install from the Apps page needs the person's confirmation.
    let install = json!({"app": "acme/tool"});
    let refused = relay.v2("apps.install", install.clone(), json!({"idempotency_key": "g1"}));
    assert_eq!(v2_reason(&refused), "confirmation_required");
    let digest =
        sha2::Sha256::digest(br#"{"app":"acme/tool","machine":"current","session":"current"}"#);
    let digest: String = digest.iter().map(|byte| format!("{byte:02x}")).collect();
    let mut app = apps.app();
    let issued = app.v2(
        "origin.confirmation.issue",
        json!({"operation": "apps.install", "params_sha256": digest, "relay_connection_id": relay_id}),
        json!({}),
    );
    let token = v2_ok(&issued)["token"].as_str().unwrap().to_owned();
    let confirmed =
        json!({"idempotency_key": "g2", "origin": {"claim": "user", "confirmation": token}});
    let reply = relay.v2("apps.install", install, confirmed);
    assert_eq!(v2_ok(&reply)["app"]["state"]["installed"], true, "{reply}");
}

/// The token the verified app mints for one relay request: `operation` with
/// exactly `params` (plus the host's `current` selectors) on `relay_id`.
fn confirmation(app: &mut Client, relay_id: &str, operation: &str, params: &Value) -> String {
    use sha2::Digest;
    // Canonical params: sorted keys, as the relay hashes them.
    let mut sorted: std::collections::BTreeMap<String, Value> =
        params.as_object().unwrap().iter().map(|(k, v)| (k.clone(), v.clone())).collect();
    sorted.insert("machine".into(), json!("current"));
    sorted.insert("session".into(), json!("current"));
    let digest = sha2::Sha256::digest(serde_json::to_string(&sorted).unwrap().as_bytes());
    let digest: String = digest.iter().map(|byte| format!("{byte:02x}")).collect();
    let issued = app.v2(
        "origin.confirmation.issue",
        json!({"operation": operation, "params_sha256": digest, "relay_connection_id": relay_id}),
        json!({}),
    );
    v2_ok(&issued)["token"].as_str().unwrap().to_owned()
}

/// The Apps page gets the installed-app panels from the daemon (cx-hnmbt.13):
/// grants, logs and the icon are reads; Hide/Show and revoking a scope need
/// the person's gesture; allowing a scope needs the native sheet's
/// confirmation; an agent changes none of them.
#[test]
fn the_apps_page_reads_panels_and_changes_apps_only_for_the_person() {
    let apps = Apps::new("panels");
    let tool = apps.dir.join("bundled");
    write_app(
        &tool,
        "acme",
        "tool",
        json!({
            "icon": "icon.png",
            "scopes": { "workspace:read": "Show workspaces." },
            "optionalScopes": { "storage:local": "Keep notes." },
        }),
    );
    let png = b"\x89PNG\r\n\x1a\nhq6d";
    std::fs::write(tool.join("tool").join("icon.png"), png).unwrap();
    std::fs::write(tool.join("tool").join("notes.txt"), "text").unwrap();
    apps.start();
    let mut app = apps.app();
    let reply = app.store(
        "cmux.apps.install",
        json!({ "app": "acme/tool", "idempotency_key": "p0" }),
        "user",
    );
    assert_eq!(ok(&reply)["app"]["state"]["installed"], true, "{reply}");

    let mut relay = apps.agent();
    let hello = relay.rpc(json!({"cmd": "client-hello", "role": "page_relay", "page": "apps"}));
    let relay_id = ok(&hello)["connection_id"].as_str().unwrap().to_owned();
    let gesture = &ok(&hello)["page_operations"]["gesture"];
    let hides = gesture.as_array().is_some_and(|ops| ops.contains(&json!("apps.hidden.set")));
    assert!(hides, "{hello}");
    let page = json!({"origin": {"claim": "page"}});

    // Reads: grants with their state, the icon as a data URL, the log ring.
    let reply = relay.v2("apps.grants.get", json!({"app": "acme/tool"}), page.clone());
    let grants = v2_ok(&reply);
    let granted = |grants: &Value, scope: &str| {
        grants["scopes"].as_array().unwrap().iter().find(|row| row["scope"] == scope).unwrap()
            ["granted"]
            .clone()
    };
    assert_eq!(
        (granted(grants, "workspace:read"), granted(grants, "storage:local")),
        (json!(true), json!(false)),
        "{reply}"
    );
    let reply =
        relay.v2("apps.asset.get", json!({"app": "acme/tool", "path": "icon.png"}), page.clone());
    let url = v2_ok(&reply)["data_url"].as_str().unwrap_or_default().to_owned();
    assert!(url.starts_with("data:image/png;base64,"), "{reply}");
    for path in ["notes.txt", "../tool/notes.png"] {
        let refused =
            relay.v2("apps.asset.get", json!({"app": "acme/tool", "path": path}), page.clone());
        assert_eq!(refused["ok"], false, "{path}: {refused}");
    }
    let reply = relay.v2("apps.logs", json!({"app": "acme/tool"}), page.clone());
    assert!(v2_ok(&reply)["lines"].is_array(), "{reply}");

    // Hide needs the person's gesture (a token the app mints for it).
    let hide = json!({"app": "acme/tool", "hidden": true});
    let refused = relay.v2("apps.hidden.set", hide.clone(), json!({"idempotency_key": "h1"}));
    assert_eq!(v2_reason(&refused), "gesture_required");
    let token = confirmation(&mut app, &relay_id, "apps.hidden.set", &hide);
    let user = |key: &str, token: String| json!({"idempotency_key": key, "origin": {"claim": "user", "confirmation": token}});
    let reply = relay.v2("apps.hidden.set", hide, user("h2", token));
    assert_eq!(v2_ok(&reply)["app"]["state"]["hidden"], true, "{reply}");

    // Allowing a scope needs the sheet's confirmation; revoking a gesture.
    let allow = json!({"app": "acme/tool", "scope": "storage:local", "granted": true});
    let refused = relay.v2("apps.grant.set", allow.clone(), json!({"idempotency_key": "g1"}));
    assert_eq!(v2_reason(&refused), "confirmation_required");
    let token = confirmation(&mut app, &relay_id, "apps.grant.set", &allow);
    v2_ok(&relay.v2("apps.grant.set", allow, user("g2", token)));
    let reply = relay.v2("apps.grants.get", json!({"app": "acme/tool"}), page.clone());
    assert_eq!(granted(v2_ok(&reply), "storage:local"), json!(true), "{reply}");
    let revoke = json!({"app": "acme/tool", "scope": "storage:local"});
    let refused = relay.v2("apps.grant.revoke", revoke.clone(), json!({"idempotency_key": "r1"}));
    assert_eq!(v2_reason(&refused), "gesture_required");
    let token = confirmation(&mut app, &relay_id, "apps.grant.revoke", &revoke);
    v2_ok(&relay.v2("apps.grant.revoke", revoke, user("r2", token)));
    let reply = relay.v2("apps.grants.get", json!({"app": "acme/tool"}), page);
    assert_eq!(granted(v2_ok(&reply), "storage:local"), json!(false), "{reply}");

    // An agent connection changes nothing, through either door.
    let mut agent = apps.agent();
    let refused = agent.v2(
        "apps.hidden.set",
        json!({"app": "acme/tool", "hidden": false}),
        json!({"idempotency_key": "a1"}),
    );
    assert_eq!(refused["error"]["details"]["required"], "user", "{refused}");
    let refused = agent.store(
        "cmux.apps.grant.revoke",
        json!({"app": "acme/tool", "scope": "workspace:read", "idempotency_key": "a2"}),
        "user",
    );
    assert_eq!(error_code(&refused), "origin.forbidden", "{refused}");
}

/// Writes the customization app at `version` into the folder `dir`.
fn write_customize(dir: &Path, version: &str) {
    let (Some(root), Some(name)) = (dir.parent(), dir.file_name()) else {
        panic!("{} has no parent", dir.display())
    };
    write_app(
        root,
        "local",
        &name.to_string_lossy(),
        json!({
            "id": "local/customize",
            "version": version,
            "runtime": { "main": "main.js" },
            "implements": { "cmux.hovercard/1": { "export": "renderCard" } },
            "scopes": { "agent:read": "Shows what the hovered row's agent does." },
        }),
    );
    std::fs::write(
        dir.join("main.js"),
        "globalThis.__cmuxAppExports = { renderCard: () => Text('hi') }\n",
    )
    .unwrap();
}

/// Waits (at most 20 s) until `local/customize` is listed at `version`;
/// returns its entry.
fn customize_listed(client: &mut Client, version: &str) -> Value {
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let list = client.rpc(json!({ "cmd": "apps-list" }));
        let found = list["data"]["apps"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|app| app["id"] == "local/customize" && app["version"] == version)
            .cloned();
        if let Some(found) = found {
            return found;
        }
        assert!(Instant::now() < deadline, "local/customize {version} never listed: {list}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// The user's customization folder (cx-swovq.1): its `local/customize` app
/// installs itself with its required scopes, and a changed file reloads it
/// with no restart and no command.
#[test]
fn the_customize_folder_installs_itself_and_reloads_when_it_changes() {
    let apps = Apps::new("customize");
    let customize = apps.dir.join("customize");
    write_customize(&customize, "1.0.0");
    apps.start();
    let mut client = apps.agent();
    let first = customize_listed(&mut client, "1.0.0");
    assert_eq!(first["installed"], true, "{first}");
    assert_eq!(first["enabled"], true, "{first}");
    assert!(
        first["grants"].as_array().is_some_and(|g| g.iter().any(|s| s == "agent:read")),
        "its read scope is granted: {first}"
    );
    assert_eq!(first["sandboxed"], true, "it runs sandboxed as any unverified app: {first}");
    write_customize(&customize, "1.0.1");
    let reloaded = customize_listed(&mut client, "1.0.1");
    assert_eq!(reloaded["installed"], true, "still installed after the reload: {reloaded}");
}

/// A customization folder deleted and made again (a `git checkout`, an
/// editor that saves a folder by replacing it, `rm -rf` then a copy) is
/// watched again: a later save in the new folder reloads with no restart.
/// On Linux the inotify watch went away with the old folder, and nothing
/// watched the new one until the daemon restarted.
#[test]
fn the_customize_folder_reloads_after_it_is_deleted_and_made_again() {
    let apps = Apps::new("customize-remade");
    let customize = apps.dir.join("customize");
    write_customize(&customize, "1.0.0");
    apps.start();
    let mut client = apps.agent();
    customize_listed(&mut client, "1.0.0");
    // Deleted, then made again in one step: a full copy renamed into place.
    std::fs::remove_dir_all(&customize).unwrap();
    let staged = apps.dir.join("customize.new");
    write_customize(&staged, "1.0.1");
    std::fs::rename(&staged, &customize).unwrap();
    customize_listed(&mut client, "1.0.1");
    // A save in the new folder.
    write_customize(&customize, "1.0.2");
    let saved = customize_listed(&mut client, "1.0.2");
    assert_eq!(saved["installed"], true, "{saved}");
}

/// A customization folder whose parent is missing too when the daemon
/// starts (no `~/.config/cmux` yet) is picked up once the user makes it,
/// and a later save in it reloads. The watch went no higher than the
/// folder's parent, so nothing watched for it until the daemon restarted.
#[test]
fn the_customize_folder_installs_when_its_missing_parent_is_made_later() {
    let mut apps = Apps::new("customize-parent");
    apps.customize = apps.dir.join("config/cmux/customize");
    apps.start();
    let mut client = apps.agent();
    write_customize(&apps.customize, "1.0.0");
    let first = customize_listed(&mut client, "1.0.0");
    assert_eq!(first["installed"], true, "{first}");
    write_customize(&apps.customize, "1.0.1");
    customize_listed(&mut client, "1.0.1");
}

/// The documented template (docs/cmux-next/sidebar-customization) is a valid
/// customize folder: copied as is, it installs, sandboxed, with its read scope.
#[test]
fn the_documented_customize_template_installs_as_is() {
    let apps = Apps::new("customize-template");
    let template =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../docs/cmux-next/sidebar-customization");
    let target = apps.dir.join("customize");
    std::fs::create_dir_all(&target).unwrap();
    for name in ["cmux-app.json", "main.js"] {
        std::fs::copy(template.join(name), target.join(name)).unwrap();
    }
    apps.start();
    let mut client = apps.agent();
    let deadline = Instant::now() + Duration::from_secs(20);
    let entry = loop {
        let list = client.rpc(json!({ "cmd": "apps-list" }));
        if let Some(found) = list["data"]["apps"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|app| app["id"] == "local/customize")
        {
            break found.clone();
        }
        let logs = client.rpc(json!({ "cmd": "apps-logs", "app": "cmux/supervisor" }));
        assert!(
            Instant::now() < deadline,
            "the template never listed: {list}\nsupervisor logs: {logs}"
        );
        std::thread::sleep(Duration::from_millis(50));
    };
    assert_eq!(entry["installed"], true, "{entry}");
    assert_eq!(entry["enabled"], true, "{entry}");
    assert_eq!(entry["sandboxed"], true, "{entry}");
    assert!(
        entry["grants"].as_array().is_some_and(|g| g.iter().any(|s| s == "workspace:read")),
        "{entry}"
    );
}

/// Copies the App Store examples shipped with cmux (`samples/apps/<name>`
/// with a `STORE` marker, the folder the Mac app hands its daemon as
/// `CMUX_APPS_DIRS`) into `root`; returns their app ids.
fn copy_store_examples(root: &Path) -> Vec<String> {
    let samples = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../samples/apps");
    let mut ids = Vec::new();
    for entry in std::fs::read_dir(&samples).unwrap() {
        let dir = entry.unwrap().path();
        if !dir.join("STORE").is_file() {
            continue;
        }
        let manifest: Value =
            serde_json::from_str(&std::fs::read_to_string(dir.join("cmux-app.v2.json")).unwrap())
                .unwrap();
        ids.push(manifest["id"].as_str().unwrap().to_string());
        let status = Command::new("cp")
            .arg("-R")
            .arg(&dir)
            .arg(root.join(dir.file_name().unwrap()))
            .status()
            .unwrap();
        assert!(status.success());
    }
    ids.sort();
    ids
}

/// The examples the App Store ships (a command-only app, a web app and a
/// scene app) pass the supervisor's validator, list as installable
/// third-party apps, and install and uninstall for the user only.
#[test]
fn the_store_examples_list_and_install_for_the_user() {
    let apps = Apps::new("examples");
    let ids = copy_store_examples(&apps.dir.join("bundled"));
    assert_eq!(
        ids,
        [
            "manaflow-ai/cmux-docs",
            "manaflow-ai/hello-deploy",
            "manaflow-ai/quick-links",
            "manaflow-ai/standup"
        ],
        "the shipped examples"
    );
    apps.start();

    let mut agent = apps.agent();
    let reply = agent.rpc(json!({ "cmd": "apps-logs", "app": "cmux/supervisor" }));
    let rejected = ok(&reply)["lines"].as_array().cloned().unwrap_or_default();
    assert!(rejected.is_empty(), "no example is rejected: {rejected:?}");
    let reply = agent.store("cmux.apps.catalog.list", json!({}), "cli");
    let catalog = ok(&reply).clone();
    for id in &ids {
        let row = listing(&catalog, id);
        assert_eq!(
            (row["hide_only"].clone(), row["tier"].clone(), row["install"].clone()),
            (json!(false), json!("unverified"), Value::Null),
            "{row}"
        );
    }

    // An agent cannot install an example; the person can, and can remove it.
    let args =
        json!({ "app": "manaflow-ai/standup", "grant_optional": false, "idempotency_key": "e1" });
    let refused = agent.store("cmux.apps.install", args.clone(), "user");
    assert_eq!(error_code(&refused), "origin.forbidden", "{refused}");
    let mut app = apps.app();
    let installed = app.store("cmux.apps.install", args, "user");
    assert_eq!(ok(&installed)["app"]["state"]["installed"], true, "{installed}");
    let listed = app.store("cmux.apps.installed.list", json!({}), "user");
    assert!(
        ok(&listed)["apps"].as_array().unwrap().iter().any(|a| a["app"] == "manaflow-ai/standup"),
        "{listed}"
    );
    let removed = app.store(
        "cmux.apps.uninstall",
        json!({ "app": "manaflow-ai/standup", "idempotency_key": "e2" }),
        "user",
    );
    assert_eq!(ok(&removed)["app"]["state"]["installed"], false, "{removed}");
}

/// `cmux apps list` and `cmux apps info` read the store from the CLI with
/// no Mac app (a self-hosted Linux host included): the examples with their
/// tier and install state, `--installed` for the installed apps only, and a
/// listing's scopes with their risk class.
#[test]
fn apps_list_and_info_read_the_store_from_the_cli() {
    let apps = Apps::new("cli-list");
    copy_store_examples(&apps.dir.join("bundled"));
    apps.start();
    let cli = |args: &[&str]| -> Output {
        Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .arg("--socket")
            .arg(&apps.socket)
            .args(args)
            .env("CMUX_TUI_STATE_DIR", apps.dir.join("state"))
            .env("CMUX_TUI_CONFIG", apps.dir.join("config.json"))
            .output()
            .unwrap()
    };

    let parsed = |out: &Output| -> Value {
        serde_json::from_slice(&out.stdout).unwrap_or_else(|error| {
            panic!(
                "{error}: status {:?}, stdout {:?}, stderr {:?}",
                out.status,
                String::from_utf8_lossy(&out.stdout),
                String::from_utf8_lossy(&out.stderr)
            )
        })
    };
    let out = cli(&["apps", "list", "--json"]);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let listed = parsed(&out);
    let standup = listed["apps"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["app"] == "manaflow-ai/standup")
        .unwrap_or_else(|| panic!("standup listed: {listed}"));
    assert_eq!(
        (standup["tier"].clone(), standup["installed"].clone()),
        (json!("unverified"), json!(false)),
        "{standup}"
    );

    let out = cli(&["apps", "list"]);
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(out.status.success() && text.contains("manaflow-ai/standup"), "{text}");
    assert!(text.contains("Standup"), "the name shows: {text}");

    let out = cli(&["apps", "list", "--installed", "--json"]);
    let installed = parsed(&out);
    assert!(
        installed["apps"].as_array().unwrap().iter().all(|row| row["installed"] == true),
        "{installed}"
    );

    let out = cli(&["apps", "info", "manaflow-ai/standup", "--json"]);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let info = parsed(&out);
    assert_eq!(info["scopes"][0]["scope"], "storage:local", "{info}");

    let out = cli(&["apps", "info", "acme/nothing"]);
    assert_eq!(out.status.code(), Some(1), "an unknown app fails");
    assert!(String::from_utf8_lossy(&out.stderr).contains("apps.unknown"));
}

/// Fake remote tools for the deploy tests in `<dir>/bin`: `ssh` logs its
/// destination and runs the script it gets on stdin here; `docker` logs each
/// call and answers `port` with 49153; `curl` passes the health check unless
/// `<dir>/health-fail` exists; `tailscale ip -4` answers 100.64.0.9.
fn fake_remote_tools(dir: &Path) {
    let bin = dir.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    let log = |name: &str| dir.join(name).display().to_string();
    write_script(
        &bin.join("ssh"),
        &format!(
            "#!/bin/sh\nfor a in \"$@\"; do last=\"$a\"; done\nprintf '%s\\n' \"$*\" >> '{ssh}'\n# the destination is the word after --\nexec sh -s\n",
            ssh = log("ssh.log")
        ),
    );
    write_script(
        &bin.join("docker"),
        &format!(
            "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{docker}'\ncase \"$1\" in\n  port) echo '100.64.0.9:49153' ;;\n  logs) echo 'fake container log' ;;\nesac\nexit 0\n",
            docker = log("docker.log")
        ),
    );
    write_script(
        &bin.join("curl"),
        &format!("#!/bin/sh\n[ -e '{fail}' ] && exit 22\nexit 0\n", fail = log("health-fail")),
    );
    write_script(&bin.join("wget"), "#!/bin/sh\nexit 1\n");
    write_script(&bin.join("tailscale"), "#!/bin/sh\necho 100.64.0.9\n");
    // A short health wait so the failure case ends quickly.
    write_script(&bin.join("sleep"), "#!/bin/sh\nexit 0\n");
}

/// The installed row of `app` once `done` accepts its instance, within 20 s.
fn wait_instance(app_client: &mut Client, app: &str, done: impl Fn(&Value) -> bool) -> Value {
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let reply = app_client.store("cmux.apps.installed.list", json!({}), "user");
        let row = ok(&reply)["apps"]
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row["app"] == app)
            .cloned()
            .unwrap_or(Value::Null);
        if done(&row) {
            return row;
        }
        assert!(Instant::now() < deadline, "{app}: {row}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// Install = deploy + pin on a self-hosted machine (docs/app-store-platonic-ideal.md
/// 8a, 15): the person's install with `deploy: {target: "self-hosted:<host>"}`
/// runs the app's container on that host over SSH, waits for its health check
/// and records a running instance with its URL, with no cmux Cloud call;
/// removing the app removes the container; a failed health check rolls the
/// install back; an agent cannot deploy.
#[test]
fn self_hosted_deploy_runs_the_container_and_rolls_back_on_failure() {
    let apps = Apps::new("deploy");
    copy_store_examples(&apps.dir.join("bundled"));
    fake_remote_tools(&apps.dir);
    apps.start();
    let target = json!({ "target": "self-hosted:ops@build-01.corp" });
    let install = |key: &str| json!({ "app": "manaflow-ai/hello-deploy", "grant_optional": false, "idempotency_key": key, "deploy": target });

    let mut agent = apps.agent();
    let refused = agent.store("cmux.apps.install", install("d0"), "user");
    assert_eq!(error_code(&refused), "origin.forbidden", "{refused}");

    let mut app = apps.app();
    let reply = app.store("cmux.apps.install", install("d1"), "user");
    let data = ok(&reply);
    assert_eq!(data["app"]["state"]["installed"], true, "{reply}");
    assert_eq!(data["instance"]["target"], "self-hosted:ops@build-01.corp", "{reply}");
    let row = wait_instance(&mut app, "manaflow-ai/hello-deploy", |row| {
        row["instance"]["state"] == "running"
    });
    assert_eq!(row["instance"]["url"], "http://100.64.0.9:49153/", "{row}");
    let ssh = std::fs::read_to_string(apps.dir.join("ssh.log")).unwrap();
    assert!(ssh.contains("ops@build-01.corp"), "deployed over SSH to the host: {ssh}");
    let docker = std::fs::read_to_string(apps.dir.join("docker.log")).unwrap();
    assert!(
        docker.contains("run -d") && docker.contains("docker.io/traefik/whoami:v1.10"),
        "{docker}"
    );
    assert!(docker.contains("cmux-app-manaflow_ai.hello_deploy"), "{docker}");

    // `cmux apps list` shows the instance too.
    let listed = app.rpc(json!({ "cmd": "apps-list" }));
    let entry = ok(&listed)["apps"]
        .as_array()
        .unwrap()
        .iter()
        .find(|e| e["id"] == "manaflow-ai/hello-deploy")
        .cloned()
        .unwrap();
    assert_eq!(entry["instance"]["state"], "running", "{entry}");

    // Remove stops the container and drops the instance.
    let removed = app.store(
        "cmux.apps.uninstall",
        json!({ "app": "manaflow-ai/hello-deploy", "idempotency_key": "d2" }),
        "user",
    );
    assert_eq!(ok(&removed)["app"]["state"]["installed"], false, "{removed}");
    let deadline = Instant::now() + Duration::from_secs(20);
    while !std::fs::read_to_string(apps.dir.join("docker.log"))
        .unwrap()
        .contains("rm -f cmux-app-manaflow_ai.hello_deploy\n")
        || std::fs::read_to_string(apps.dir.join("docker.log")).unwrap().matches("rm -f").count()
            < 2
    {
        assert!(Instant::now() < deadline, "the container is removed");
        std::thread::sleep(Duration::from_millis(50));
    }

    // A failed health check rolls the install back.
    std::fs::write(apps.dir.join("health-fail"), "").unwrap();
    let reply = app.store("cmux.apps.install", install("d3"), "user");
    assert_eq!(ok(&reply)["app"]["state"]["installed"], true, "{reply}");
    let row = wait_instance(&mut app, "manaflow-ai/hello-deploy", |row| row.is_null());
    assert!(row.is_null(), "rolled back: no longer installed");
    let logs = app.rpc(json!({ "cmd": "apps-logs", "app": "manaflow-ai/hello-deploy" }));
    let text = ok(&logs).to_string();
    assert!(text.contains("health check failed"), "{text}");

    // A target the manifest does not allow is refused before anything installs.
    let refused = app.store(
        "cmux.apps.install",
        json!({ "app": "manaflow-ai/hello-deploy", "idempotency_key": "d4", "deploy": { "target": "team-vm:t1" } }),
        "user",
    );
    assert_eq!(error_code(&refused), "deploy.target_not_allowed", "{refused}");
}

/// An open App Store page shows an app installed from somewhere else (the
/// CLI's `cmux apps install`, another window, an agent's request the person
/// approved) without a reload: its relay hears `apps-changed` and re-reads
/// `installed.list`. Before, the page's entry named no event and the relay
/// was never an apps event sink, so the Installed tab stayed empty while
/// `cmux apps list --installed` showed the app.
#[test]
fn the_apps_page_relay_hears_an_install_made_elsewhere() {
    let apps = Apps::new("page-events");
    copy_store_examples(&apps.dir.join("bundled"));
    apps.start();

    let mut relay = apps.agent();
    let hello = relay.rpc(json!({"cmd": "client-hello", "role": "page_relay", "page": "apps"}));
    assert_eq!(ok(&hello)["page_events"], json!(["apps-changed"]), "{hello}");
    let page = json!({"origin": {"claim": "page"}});
    let reply = relay.v2("apps.installed.list", json!({}), page.clone());
    let before = v2_ok(&reply)["apps"].as_array().cloned().unwrap_or_default();
    assert!(before.iter().all(|row| row["app"] != "manaflow-ai/standup"), "{reply}");
    let subscribed = relay.rpc(json!({"cmd": "subscribe"}));
    assert_eq!(subscribed["ok"], true, "{subscribed}");

    // The person installs from the CLI: the cmux app's own connection.
    let mut app = apps.app();
    let installed = app.store(
        "cmux.apps.install",
        json!({ "app": "manaflow-ai/standup", "grant_optional": false, "idempotency_key": "pe1" }),
        "user",
    );
    assert_eq!(ok(&installed)["app"]["state"]["installed"], true, "{installed}");

    let changed = relay.event("apps-changed");
    assert_eq!(changed["app"], "manaflow-ai/standup", "{changed}");
    let reply = relay.v2("apps.installed.list", json!({}), page);
    let after = v2_ok(&reply)["apps"].as_array().cloned().unwrap_or_default();
    assert!(after.iter().any(|row| row["app"] == "manaflow-ai/standup"), "{reply}");
}

/// A listing with a `deploy` block says where it runs: `catalog.get` sends
/// the manifest's targets (the App Store page's "Runs on" section) and
/// `cmux apps info` prints them; an app with no deploy block sends none.
#[test]
fn a_deployed_apps_listing_names_its_deploy_targets() {
    let apps = Apps::new("deploy-targets");
    copy_store_examples(&apps.dir.join("bundled"));
    apps.start();
    let mut agent = apps.agent();
    let reply =
        agent.store("cmux.apps.catalog.get", json!({"app": "manaflow-ai/hello-deploy"}), "cli");
    let detail = ok(&reply);
    assert_eq!(detail["deploy"]["targets"], json!(["self-hosted", "cloud-vm"]), "{reply}");
    assert_eq!(detail["deploy"]["tenancy"], json!(["user"]), "{reply}");
    let reply = agent.store("cmux.apps.catalog.get", json!({"app": "manaflow-ai/standup"}), "cli");
    assert!(ok(&reply).get("deploy").is_none_or(Value::is_null), "{reply}");

    let out = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .arg("--socket")
        .arg(&apps.socket)
        .args(["apps", "info", "manaflow-ai/hello-deploy"])
        .env("CMUX_TUI_STATE_DIR", apps.dir.join("state"))
        .env("CMUX_TUI_CONFIG", apps.dir.join("config.json"))
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    assert!(text.contains("runs on: self-hosted, cloud-vm"), "{text}");
}
