//! A computer use call recovers from a killed helper and a stale endpoint by
//! itself (`cua_recovery.rs`), against real processes: a helper on a unix
//! socket that checks its agent token, and a proxy that, like `cmux-cua mcp`,
//! reads its socket and token once at start and gives up for good after one
//! failed connection.

use std::io::{BufRead as _, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};

use super::*;

/// The helper: answers `ok` to a connection that sends its token, `denied` otherwise.
const HELPER: &str = r#"
import os, socket, sys
path, token = sys.argv[1], sys.argv[2]
try:
    os.unlink(path)
except FileNotFoundError:
    pass
s = socket.socket(socket.AF_UNIX)
s.bind(path)
s.listen(8)
print("ready", flush=True)
while True:
    c, _ = s.accept()
    got = c.makefile().readline().strip()
    c.sendall(b"ok\n" if got == token else b"denied\n")
    c.close()
"#;

/// The proxy, with the text the real one answered on 2026-11-14.
const PROXY: &str = r#"
import json, os, socket, sys
sock = sys.argv[sys.argv.index("--socket") + 1]
token = os.environ.get("CMUX_CUA_SOCKET_AUTH_TOKEN", "")
gave_up = False
def reach():
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(2)
    s.connect(sock)
    s.sendall((token + "\n").encode())
    ok = s.makefile().readline().strip() == "ok"
    s.close()
    return ok
for line in sys.stdin:
    m = json.loads(line)
    if "id" not in m:
        continue
    method, rid = m["method"], m["id"]
    if method == "initialize":
        result = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
                  "serverInfo": {"name": "fake-cua"}}
    elif method == "tools/list":
        result = {"tools": [{"name": "health_report", "description": "Helper health",
                             "inputSchema": {"type": "object"}}]}
    elif method == "tools/call":
        ok = False
        if not gave_up:
            try:
                ok = reach()
            except OSError:
                ok = False
        if ok:
            result = {"content": [{"type": "text", "text": "healthy"}]}
        else:
            gave_up = True
            text = ("computer-use daemon failed to start: the tag-scoped cmux Computer Use runtime "
                    "is not listening on " + sock + ": cmux-owned Computer Use daemon stayed "
                    "unavailable during initial connection. Do not run `cmux-cua serve`, `call`, "
                    "or `permissions` directly. Open cmux Settings > Computer Use, or toggle "
                    "Computer Use off and on, to recover the branded cmux Computer Use helper.")
            result = {"content": [{"type": "text", "text": text}], "isError": True}
    else:
        print(json.dumps({"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "no"}}), flush=True)
        continue
    print(json.dumps({"jsonrpc": "2.0", "id": rid, "result": result}), flush=True)
"#;

/// A running helper; killed when dropped.
struct Helper(Child);

impl Helper {
    fn start(script: &Path, socket: &Path, token: &str) -> Self {
        let mut child = Command::new("python3")
            .arg(script)
            .arg(socket)
            .arg(token)
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let mut line = String::new();
        BufReader::new(child.stdout.take().unwrap()).read_line(&mut line).unwrap();
        assert_eq!(line.trim(), "ready");
        Self(child)
    }
}

impl Drop for Helper {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

struct Fixture {
    dir: PathBuf,
    helper: PathBuf,
    socket: PathBuf,
    /// What acpmux would give a new session now.
    endpoint: Arc<Mutex<Option<acpmux::cua_socket::Socket>>>,
}

impl Fixture {
    fn new(token: &str) -> Self {
        // Short: a unix socket path is at most 104 bytes on macOS.
        static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let dir = PathBuf::from(format!("/tmp/cmux-cuarec-{}-{n}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("helper.py"), HELPER).unwrap();
        std::fs::write(dir.join("proxy.py"), PROXY).unwrap();
        let socket = dir.join("h.sock");
        let endpoint = Arc::new(Mutex::new(Some(acpmux::cua_socket::Socket {
            path: socket.clone(),
            token: token.to_owned(),
        })));
        Self { helper: dir.join("helper.py"), dir, socket, endpoint }
    }

    fn set_token(&self, token: &str) {
        *self.endpoint.lock().unwrap() =
            Some(acpmux::cua_socket::Socket { path: self.socket.clone(), token: token.into() });
    }

    /// The chat's proxy, spawned with `token` (its chat's spawn env).
    fn server(&self, fake: Fake, token: &str) -> Server<Fake> {
        let endpoint = self.endpoint.clone();
        self.server_reading(fake, token, Arc::new(move || Ok(endpoint.lock().unwrap().clone())))
    }

    /// The chat's proxy, recovered with endpoints from `source`.
    fn server_reading(
        &self,
        fake: Fake,
        token: &str,
        source: cua_recovery::EndpointSource,
    ) -> Server<Fake> {
        let specs = upstream::specs(Some(
            json!([{"name": "cmux-cua", "command": "python3",
                    "args": [self.dir.join("proxy.py"), "--socket", self.socket],
                    "env": {"CMUX_CUA_SOCKET_AUTH_TOKEN": token}}])
            .to_string()
            .into(),
        ));
        let upstream = upstream::Upstream::new(specs.into_iter().next().unwrap())
            .with_listings(None)
            .with_endpoint(source);
        let mut server = Server::new(fake, None);
        server.upstreams = vec![upstream::Proxied::new(upstream)];
        server
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn text(result: &Value) -> String {
    result["content"][0]["text"].as_str().unwrap_or_default().to_owned()
}

/// The helper is killed, the app starts a new one with a new agent token (as
/// after an app relaunch), and the chat's proxy, which still holds the old
/// token, is killed too. The next call comes back by itself and runs, and the
/// one after it runs at once.
#[test]
fn a_killed_helper_comes_back_and_the_next_call_succeeds() {
    let fixture = Fixture::new("launch-1");
    let helper = Helper::start(&fixture.helper, &fixture.socket, "launch-1");
    let mut server = fixture.server(Fake::default(), "launch-1");
    assert_eq!(text(&call(&mut server, "cua_health_report", json!({}))), "healthy");

    drop(helper);
    let proxy = server.upstreams[0].inner.lock().unwrap().pid().expect("the proxy runs");
    assert!(Command::new("kill").arg(proxy.to_string()).status().unwrap().success());
    // The reader sees the proxy's end, as a chat's server does before its next call.
    let deadline = Instant::now() + Duration::from_secs(5);
    while server.upstreams[0].inner.lock().unwrap().alive() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    let back = std::thread::spawn({
        let (script, socket) = (fixture.helper.clone(), fixture.socket.clone());
        move || {
            std::thread::sleep(Duration::from_millis(300));
            Helper::start(&script, &socket, "launch-2")
        }
    });
    fixture.set_token("launch-2");

    let started = Instant::now();
    let result = call(&mut server, "cua_health_report", json!({}));
    assert_eq!(text(&result), "healthy", "{result}");
    assert!(started.elapsed() < Duration::from_secs(8), "{:?}", started.elapsed());
    let _helper = back.join().unwrap();

    let started = Instant::now();
    assert_eq!(text(&call(&mut server, "cua_health_report", json!({}))), "healthy");
    assert!(started.elapsed() < Duration::from_secs(2), "{:?}", started.elapsed());
}

/// A helper that stays down: the call asks the app to restart its helper, then
/// says what it tried. The agent is never told to have the person toggle a setting.
#[test]
fn a_helper_that_stays_down_is_restarted_and_never_asks_for_a_toggle() {
    cua_recovery::reset_restart_throttle();
    let fixture = Fixture::new("launch-1");
    let fake = Fake {
        computer_use: Some(json!({"phase": "ready", "accessibility": true,
        "screen_recording": true, "helper": "cmux Computer Use", "driver": "legacy"})),
        ..Fake::default()
    };
    let calls = fake.app_calls.clone();
    let mut server = fixture.server(fake, "launch-1");
    let result = call(&mut server, "cua_health_report", json!({}));
    assert_eq!(result["isError"], true, "{result}");
    let message = result["structuredContent"]["error"]["message"]
        .as_str()
        .map_or_else(|| text(&result), str::to_owned);
    assert!(message.contains("did not answer"), "{message}");
    assert!(!message.to_ascii_lowercase().contains("toggle"), "{message}");
    assert!(!message.contains("Settings > Computer Use"), "{message}");
    let restarts: Vec<_> = calls
        .lock()
        .unwrap()
        .iter()
        .filter(|c| c["method"] == "action.run")
        .map(|c| c["params"]["action"].clone())
        .collect();
    assert_eq!(restarts, [json!(cua_recovery::RESTART_ACTION_CLI)], "{restarts:?}");
}

/// 2026-11-14: the app relaunched for an update mid-turn and its
/// helper came back with the new launch's token, but every read of the current endpoint from
/// acpmux failed. The proxy kept the old token through all five tries, and the final error
/// said it had used "the current endpoint". It now says the read failed and why.
#[test]
fn an_endpoint_read_that_fails_is_named_when_recovery_gives_up() {
    cua_recovery::reset_restart_throttle();
    let fixture = Fixture::new("launch-1");
    let _helper = Helper::start(&fixture.helper, &fixture.socket, "launch-2");
    let source: cua_recovery::EndpointSource =
        Arc::new(|| Err("acpmux refused: only a proven acpmux session may ask".to_owned()));
    let mut server = fixture.server_reading(Fake::default(), "launch-1", source);
    let result = call(&mut server, "cua_health_report", json!({}));
    assert_eq!(result["isError"], true, "{result}");
    let message = result["structuredContent"]["error"]["message"]
        .as_str()
        .map_or_else(|| text(&result), str::to_owned);
    assert!(!message.contains("with the current endpoint"), "{message}");
    assert!(message.contains("only a proven acpmux session may ask"), "{message}");
}
