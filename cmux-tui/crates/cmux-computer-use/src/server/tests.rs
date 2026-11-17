//! The agent socket over a real Unix socket, with the fake desktop.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use serde_json::{Value, json};

use super::*;
use crate::desktop::fake::{Event, FakeDesktop};
use crate::engine::{EngineParts, PersonActivity};

const SECRET: [u8; 32] = [7; 32];

/// Holds acting calls (pause-on-takeover's wait) until opened.
#[derive(Default)]
struct Gate {
    open: Mutex<bool>,
    waiting: Mutex<u32>,
    changed: Condvar,
    arrived: Condvar,
}

impl Gate {
    fn release(&self) {
        *self.open.lock().unwrap() = true;
        self.changed.notify_all();
    }
    fn wait_for_waiters(&self, n: u32) {
        let guard = self.waiting.lock().unwrap();
        let (guard, timeout) =
            self.arrived.wait_timeout_while(guard, Duration::from_secs(10), |w| *w < n).unwrap();
        assert!(!timeout.timed_out(), "only {} calls reached the gate", *guard);
    }
}

impl PersonActivity for Gate {
    fn wait_idle(&self, _limit: Duration) -> bool {
        *self.waiting.lock().unwrap() += 1;
        self.arrived.notify_all();
        let open = self.open.lock().unwrap();
        let _open = self.changed.wait_while(open, |open| !*open).unwrap();
        true
    }
}

struct Fixture {
    server: Option<Server>,
    path: PathBuf,
    desktop: Arc<FakeDesktop>,
    gate: Arc<Gate>,
    engine: Arc<Engine>,
    _dir: tempdir::Dir,
}

mod tempdir {
    pub struct Dir(pub std::path::PathBuf);
    impl Drop for Dir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    pub fn new(tag: &str) -> Dir {
        use std::sync::atomic::{AtomicU32, Ordering};
        static N: AtomicU32 = AtomicU32::new(0);
        // Short: macOS socket paths are at most 104 bytes.
        let path = std::path::PathBuf::from("/tmp").join(format!(
            "cu{}{}{}",
            tag,
            std::process::id(),
            N.fetch_add(1, Ordering::SeqCst)
        ));
        Dir(path)
    }
}

fn fixture(tag: &str, uid: Option<u32>) -> Fixture {
    let dir = tempdir::new(tag);
    let path = dir.0.join("s").join("cu.sock");
    // The person uses Safari (window 1), so acting on it meets the takeover
    // wait, which the gate holds.
    let mut fake = FakeDesktop::standard();
    fake.windows[1].focused = true;
    let desktop = Arc::new(fake);
    let gate = Arc::new(Gate::default());
    let mut parts = EngineParts::new(desktop.clone());
    parts.takeover = gate.clone();
    parts.sleep = Arc::new(|_| {});
    // Each clock read is a second later: the settle wait ends at once.
    let ticks = Arc::new(std::sync::atomic::AtomicU64::new(0));
    parts.clock = Arc::new(move || Duration::from_secs(ticks.fetch_add(1, Ordering::SeqCst)));
    let engine = Arc::new(Engine::new(parts));
    let mut listener = transport::Listener::bind(path.to_str().unwrap()).unwrap();
    if let Some(uid) = uid {
        listener.uid = uid;
    }
    let server = serve_on(engine.clone(), listener, path.to_str().unwrap(), &SECRET).unwrap();
    Fixture { _dir: dir, path, desktop, gate, engine, server: Some(server) }
}

struct Client {
    writer: UnixStream,
    reader: BufReader<UnixStream>,
}

impl Client {
    fn raw(path: &PathBuf) -> Self {
        let stream = UnixStream::connect(path).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        Self { writer: stream.try_clone().unwrap(), reader: BufReader::new(stream) }
    }
    fn connect(path: &PathBuf) -> Self {
        let mut client = Self::raw(path);
        let hello = client.hello(&wire::hex(&SECRET));
        assert_eq!(hello["ok"], true, "{hello}");
        assert_eq!(hello["capabilities"][0], wire::CAPABILITY);
        client
    }
    fn hello(&mut self, secret: &str) -> Value {
        self.send(&json!({"secret": secret}));
        self.recv()
    }
    fn send(&mut self, v: &Value) {
        writeln!(self.writer, "{v}").unwrap();
    }
    fn recv(&mut self) -> Value {
        let mut line = String::new();
        self.reader.read_line(&mut line).unwrap();
        serde_json::from_str(&line).unwrap_or(Value::Null)
    }
    fn call(&mut self, id: u64, session: &str, name: &str, args: Value, call_id: Option<&str>) {
        self.send(&json!({
            "id": id, "method": "tools/call", "name": name, "arguments": args,
            "session": session, "label": "Claude", "call_id": call_id,
        }));
    }
}

#[test]
fn socket_and_directory_are_private() {
    let f = fixture("perm", None);
    let mode = |p: &std::path::Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode(&f.path), 0o600);
    assert_eq!(mode(f.path.parent().unwrap()), 0o700);
}

#[test]
fn a_wrong_secret_is_refused_and_closed() {
    let f = fixture("sec", None);
    let mut client = Client::raw(&f.path);
    let answer = client.hello(&"00".repeat(32));
    assert_eq!(answer, json!({"ok": false, "error": "refused", "reason": "bad secret"}));
    let mut rest = String::new();
    assert_eq!(client.reader.read_line(&mut rest).unwrap(), 0);
    // Not hex, and missing, are refused the same way.
    assert_eq!(Client::raw(&f.path).hello("zz")["reason"], "bad secret");
    let mut client = Client::raw(&f.path);
    client.send(&json!({"hello": 1}));
    assert_eq!(client.recv()["reason"], "bad secret");
}

#[test]
fn another_user_is_refused_before_the_secret() {
    // SAFETY: plain call.
    let other = unsafe { libc::geteuid() }.wrapping_add(1);
    let f = fixture("uid", Some(other));
    let mut client = Client::raw(&f.path);
    // The refusal comes first, unasked; the secret is never read.
    let answer = client.recv();
    assert_eq!(answer, json!({"ok": false, "error": "refused", "reason": "another user"}));
}

#[test]
fn status_and_tools_list_answer() {
    let f = fixture("st", None);
    let mut client = Client::connect(&f.path);
    client.send(&json!({"id": 1, "method": "status"}));
    let status = client.recv();
    assert_eq!(status["id"], 1);
    assert_eq!(status["result"]["body"]["mode"], "fullAccess", "{status}");
    client.send(&json!({"id": 2, "method": "tools/list"}));
    assert!(client.recv()["result"]["tools"].as_array().is_some_and(|t| !t.is_empty()));
    client.send(&json!({"id": 3, "method": "nope"}));
    assert_eq!(client.recv()["error"], "unknown_method");
}

#[test]
fn one_sessions_calls_stay_ordered_and_others_go_on() {
    let f = fixture("ord", None);
    let mut client = Client::connect(&f.path);
    let click = json!({"window_id": "1", "element_id": "e1"});
    // A1 acts and waits at the gate; A2 (discover) must wait behind it.
    client.call(1, "a", "click", click, Some("a1"));
    f.gate.wait_for_waiters(1);
    client.call(2, "a", "list_apps", json!({}), None);
    // Session b is not held up by a.
    client.call(3, "b", "list_windows", json!({}), None);
    let first = client.recv();
    assert_eq!(first["id"], 3, "{first}");
    f.gate.release();
    let second = client.recv();
    let third = client.recv();
    assert_eq!((second["id"].clone(), third["id"].clone()), (json!(1), json!(2)));
    assert_eq!(second["result"]["is_error"], false, "{second}");
}

#[test]
fn a_retry_on_a_new_connection_returns_the_first_result_and_clicks_once() {
    let f = fixture("rt", None);
    let click = json!({"window_id": "1", "element_id": "e1"});
    let mut first = Client::connect(&f.path);
    first.call(1, "s", "click", click.clone(), Some("call-1"));
    f.gate.wait_for_waiters(1);
    // The bridge loses the connection mid-call and retries on a new one.
    drop(first);
    let mut second = Client::connect(&f.path);
    second.call(9, "s", "click", click.clone(), Some("call-1"));
    f.gate.release();
    let answer = second.recv();
    assert_eq!(answer["id"], 9);
    assert_eq!(answer["result"]["is_error"], false, "{answer}");
    // And once more after it finished.
    second.call(10, "s", "click", click, Some("call-1"));
    assert_eq!(second.recv()["result"], answer["result"]);
    let clicks = f.desktop.events().iter().filter(|e| matches!(e, Event::Click { .. })).count();
    assert_eq!(clicks, 1);
}

#[test]
fn session_end_and_stop_close_connections_and_remove_the_socket() {
    let mut f = fixture("stop", None);
    let mut client = Client::connect(&f.path);
    client.send(&json!({"id": 1, "method": "session/end", "session": "s"}));
    assert_eq!(client.recv(), json!({"id": 1, "ok": true, "result": {}}));
    f.server.take().unwrap().stop();
    let mut rest = String::new();
    assert_eq!(client.reader.read_line(&mut rest).unwrap_or(0), 0);
    assert!(!f.path.exists());
    assert!(UnixStream::connect(&f.path).is_err());
}

#[test]
fn a_stale_socket_is_replaced_but_a_regular_file_is_not() {
    let mut f = fixture("stale", None);
    let path = f.path.clone();
    f.server.take().unwrap().stop();
    // A crashed worker leaves its socket file behind: the next one binds over it.
    drop(std::os::unix::net::UnixListener::bind(&path).unwrap());
    assert!(path.exists());
    let mut parts = EngineParts::new(Arc::new(FakeDesktop::standard()));
    parts.sleep = Arc::new(|_| {});
    // Each clock read is a second later: the settle wait ends at once.
    let ticks = Arc::new(std::sync::atomic::AtomicU64::new(0));
    parts.clock = Arc::new(move || Duration::from_secs(ticks.fetch_add(1, Ordering::SeqCst)));
    let engine = Arc::new(Engine::new(parts));
    serve(engine.clone(), path.to_str().unwrap(), &SECRET).unwrap().stop();
    std::fs::write(&path, b"not a socket").unwrap();
    assert!(serve(engine, path.to_str().unwrap(), &SECRET).is_err());
}

/// Polls `cond` for up to 10 s (the connection's end reaches the server on
/// its own thread).
fn eventually(cond: impl Fn() -> bool) -> bool {
    for _ in 0..1000 {
        if cond() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    false
}

fn look(client: &mut Client, id: u64, session: &str) {
    client.call(id, session, "get_ui_tree", json!({"window_id": "1"}), None);
    let answer = client.recv();
    assert_eq!(answer["result"]["is_error"], false, "{answer}");
}

#[test]
fn an_agent_process_that_exits_without_session_end_ends_its_session() {
    let f = fixture("att", None);
    let mut presence = Client::connect(&f.path);
    presence.send(&json!({"id": 1, "method": "session/attach", "session": "s"}));
    assert_eq!(presence.recv()["ok"], true);
    let mut calls = Client::connect(&f.path);
    look(&mut calls, 2, "s");
    assert_eq!(f.engine.active_sessions(), vec!["s".to_string()]);
    // The cursor stays while the agent thinks: nothing ends it but its end.
    std::thread::sleep(Duration::from_millis(200));
    assert_eq!(f.engine.active_sessions(), vec!["s".to_string()]);
    // The agent crashed: its bridge's connections close, no session/end.
    drop(calls);
    drop(presence);
    assert!(eventually(|| f.engine.active_sessions().is_empty()));
}

#[test]
fn a_turn_end_idles_the_sessions_of_its_terminal_only() {
    let f = fixture("idle", None);
    let mut client = Client::connect(&f.path);
    look(&mut client, 1, "terminal:T1:100");
    look(&mut client, 2, "terminal:T2:200");
    look(&mut client, 3, "chat-1");
    client.send(&json!({"id": 4, "method": "session/idle", "session": "terminal:T1:", "prefix": true}));
    let answer = client.recv();
    assert_eq!(answer["result"]["ended"], json!(["terminal:T1:100"]), "{answer}");
    client.send(&json!({"id": 5, "method": "session/idle", "session": "chat-1"}));
    assert_eq!(client.recv()["result"]["ended"], json!(["chat-1"]));
    assert_eq!(f.engine.active_sessions(), vec!["terminal:T2:200".to_string()]);
}

#[test]
fn a_preview_watch_gets_the_card_of_an_active_session() {
    let f = fixture("pw", None);
    let mut watch = Client::connect(&f.path);
    watch.send(&json!({"id": 1, "method": "preview/watch"}));
    assert_eq!(watch.recv()["ok"], true);
    let mut client = Client::connect(&f.path);
    look(&mut client, 2, "s");
    assert!(eventually(|| f.engine.preview().streaming() == vec!["1".to_string()]));
    f.engine.preview().frame("1", b"jpeg");
    let line = watch.recv();
    assert_eq!(line["event"], "preview", "{line}");
    assert_eq!(line["card"]["session"], "s");
    assert_eq!(line["card"]["app"], "Safari");
    client.send(&json!({"id": 3, "method": "session/idle", "session": "s"}));
    client.recv();
    let done = watch.recv();
    assert_eq!(done["card"]["done"], true, "{done}");
    // A remote origin never watches this machine's windows.
    let mut remote = Client::connect(&f.path);
    remote.send(&json!({"id": 1, "method": "preview/watch",
        "origin": {"kind": "remote", "machine": "m", "same_account": true}}));
    assert_eq!(remote.recv()["ok"], false);
}
