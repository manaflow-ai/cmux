//! The state sockets against a local server that speaks `cmux.machine-state/1`: what the upgrade
//! carries, what a frame does, a reconnect with a fresh bearer, a stop, a redirect, a 401 and the
//! keepalive.
use super::*;
use std::collections::VecDeque;
use std::net::TcpListener;
use std::sync::atomic::AtomicBool;
use std::sync::mpsc::{Receiver, Sender, channel};
use tungstenite::handshake::server::{ErrorResponse, Request, Response};

const A: &str = "vm_aaaaaaaaaaaaaaaaaaaa";
const B: &str = "vm_bbbbbbbbbbbbbbbbbbbb";
const CLIENT: u64 = 7;
const WAIT: Duration = Duration::from_secs(10);
const QUIET: Duration = Duration::from_millis(400);

/// How the server answers its next connection.
enum Conn {
    /// Sends `frames`, then reads until the client closes.
    Hold(Vec<String>),
    /// Sends `frames`, then closes.
    Close(Vec<String>),
    /// Refuses the upgrade with `status` (and a `Location`).
    Refuse(u16, Option<String>),
}

#[derive(Debug)]
enum Seen {
    Open { conn: u64, path: String, auth: Option<String>, team: Option<String> },
    Refused { status: u16 },
    Text { conn: u64, text: String },
    Closed { conn: u64 },
}

struct Server {
    url: String,
    seen: Receiver<Seen>,
    script: Arc<Mutex<VecDeque<Conn>>>,
}

impl Server {
    fn start() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let (tx, seen) = channel();
        let script: Arc<Mutex<VecDeque<Conn>>> = Arc::default();
        let queue = script.clone();
        std::thread::spawn(move || {
            for (conn, stream) in (1_u64..).zip(listener.incoming()) {
                let Ok(stream) = stream else { return };
                let plan = queue.lock().unwrap().pop_front().unwrap_or(Conn::Hold(Vec::new()));
                let tx = tx.clone();
                std::thread::spawn(move || serve(conn, stream, plan, &tx));
            }
        });
        Self { url, seen, script }
    }

    fn plan(&self, conn: Conn) {
        self.script.lock().unwrap().push_back(conn);
    }

    fn next(&self) -> Seen {
        self.seen.recv_timeout(WAIT).expect("the server saw nothing")
    }

    /// The next `Open` (anything between is skipped).
    fn open(&self) -> (u64, String, Option<String>, Option<String>) {
        loop {
            if let Seen::Open { conn, path, auth, team } = self.next() {
                return (conn, path, auth, team);
            }
        }
    }
}

fn serve(conn: u64, stream: std::net::TcpStream, plan: Conn, tx: &Sender<Seen>) {
    let refuse = match &plan {
        Conn::Refuse(status, location) => Some((*status, location.clone())),
        _ => None,
    };
    let mut opened = None;
    let callback = |request: &Request, response: Response| -> Result<Response, ErrorResponse> {
        if let Some((status, location)) = refuse {
            let mut reply = tungstenite::http::Response::builder().status(status);
            if let Some(location) = location {
                reply = reply.header("location", location);
            }
            return Err(reply.body(None).unwrap());
        }
        let header = |name: &str| {
            request.headers().get(name).and_then(|v| v.to_str().ok()).map(str::to_owned)
        };
        opened = Some(Seen::Open {
            conn,
            path: request.uri().path().to_owned(),
            auth: header("authorization"),
            team: header("x-cmux-team"),
        });
        Ok(response)
    };
    let Ok(mut socket) = tungstenite::accept_hdr(stream, callback) else {
        if let Conn::Refuse(status, _) = plan {
            let _ = tx.send(Seen::Refused { status });
        }
        return;
    };
    let _ = tx.send(opened.unwrap());
    let (frames, close) = match plan {
        Conn::Hold(frames) => (frames, false),
        Conn::Close(frames) => (frames, true),
        Conn::Refuse(..) => return,
    };
    for frame in frames {
        if socket.send(tungstenite::Message::text(frame)).is_err() {
            break;
        }
    }
    if close {
        let _ = socket.close(None);
    }
    while let Ok(message) = socket.read() {
        if let tungstenite::Message::Text(text) = message {
            let _ = tx.send(Seen::Text { conn, text: text.as_str().to_owned() });
        }
    }
    let _ = tx.send(Seen::Closed { conn });
}

#[derive(Default)]
struct FakeHost {
    bearers: AtomicU64,
    forwarded: Mutex<Vec<Value>>,
    unauthenticated: Mutex<Vec<u64>>,
    /// No Cloud app server takes a frame.
    nobody: AtomicBool,
    /// The next bearer's lease is replaced as soon as it is handed out (an account switch).
    switch_once: AtomicBool,
    /// Leases up to this generation are no longer the daemon's.
    replaced: AtomicU64,
}

impl Host for FakeHost {
    fn bearer(&self) -> Result<(Zeroizing<String>, u64), ()> {
        let n = self.bearers.fetch_add(1, Ordering::SeqCst) + 1;
        if self.switch_once.swap(false, Ordering::SeqCst) {
            self.replaced.store(n, Ordering::SeqCst);
        }
        Ok((Zeroizing::new(format!("token-{n}")), n))
    }

    fn unauthenticated(&self, generation: u64) {
        self.unauthenticated.lock().unwrap().push(generation);
    }

    fn forward(&self, data: &Value) -> bool {
        self.forwarded.lock().unwrap().push(data.clone());
        !self.nobody.load(Ordering::SeqCst)
    }

    fn current(&self, generation: u64) -> bool {
        generation > self.replaced.load(Ordering::SeqCst)
    }
}

struct Fixture {
    push: MachineStatePush,
    host: Arc<FakeHost>,
    events: Receiver<Value>,
    sink: Sink,
    server: Server,
}

impl Fixture {
    fn new(keepalive: Duration) -> Self {
        let (tx, events) = channel();
        let tx = Mutex::new(tx);
        let sink: Sink =
            Arc::new(move |event: &Value| tx.lock().unwrap().send(event.clone()).is_ok());
        let timing = Timing { keepalive, handshake: Duration::from_secs(5), speedup: 100 };
        Self {
            push: MachineStatePush::with_timing(timing),
            host: Arc::default(),
            events,
            sink,
            server: Server::start(),
        }
    }

    fn watch(&self, ids: &[&str]) {
        let machines = ids.iter().map(|id| Machine::new(*id, Status::Running)).collect();
        let request =
            Watch { machines, platform: self.server.url.clone(), team: Some("team-a".into()) };
        self.push.watch(CLIENT, self.sink.clone(), self.host.clone(), request).unwrap();
    }

    fn event(&self) -> Value {
        self.events.recv_timeout(WAIT).expect("the app heard nothing")
    }

    fn kinds(&self, count: usize) -> Vec<String> {
        (0..count).map(|_| self.event()["kind"].as_str().unwrap().to_owned()).collect()
    }

    fn quiet(&self) {
        assert!(self.events.recv_timeout(QUIET).is_err(), "the app heard an event it should not");
    }
}

use cmux_cloud_machine::record::Status;

fn state(machine: &str, status: &str, revision: &str) -> String {
    json!({"v": 1, "t": "state", "machine": machine, "revision": 1,
        "state": {"record": {"id": machine, "status": status, "revision": revision}}})
    .to_string()
}

fn removed(machine: &str) -> String {
    json!({"v": 1, "t": "removed", "machine": machine, "revision": 2}).to_string()
}

#[test]
fn a_frame_goes_to_the_app_server_then_shows_and_goes_live() {
    let f = Fixture::new(Duration::from_secs(30));
    f.server.plan(Conn::Hold(vec![state(A, "paused", "5")]));
    f.watch(&[A]);
    let (_, path, auth, team) = f.server.open();
    assert_eq!(path, format!("/v1/cloud/machines/{A}/state"));
    assert_eq!(auth.as_deref(), Some("Bearer token-1"));
    assert_eq!(team.as_deref(), Some("team-a"));
    let record = f.event();
    assert_eq!((record["event"].as_str(), record["kind"].as_str()), (Some(EVENT), Some("record")));
    assert_eq!(record["machine"], A);
    assert_eq!(record["record"]["status"], "paused");
    assert_eq!(f.event()["kind"], "live");
    let forwarded = f.host.forwarded.lock().unwrap().clone();
    assert_eq!(forwarded.len(), 1);
    assert_eq!(forwarded[0]["t"], "state");
}

#[test]
fn a_frame_nobody_took_shows_but_stays_on_reads() {
    let f = Fixture::new(Duration::from_secs(30));
    f.host.nobody.store(true, Ordering::SeqCst);
    f.server.plan(Conn::Hold(vec![state(A, "paused", "5")]));
    f.watch(&[A]);
    assert_eq!(f.event()["kind"], "record");
    f.quiet();
}

#[test]
fn a_frame_of_another_machine_or_garbage_is_ignored() {
    let f = Fixture::new(Duration::from_secs(30));
    f.server.plan(Conn::Hold(vec!["not json".into(), state(B, "paused", "5")]));
    f.watch(&[A]);
    f.server.open();
    f.quiet();
    assert!(f.host.forwarded.lock().unwrap().is_empty());
}

#[test]
fn a_removal_is_forwarded_ends_the_watch_and_shows_the_machine_destroyed() {
    let f = Fixture::new(Duration::from_secs(30));
    f.server.plan(Conn::Hold(vec![removed(A)]));
    f.watch(&[A]);
    let gone = f.event();
    assert_eq!(gone["kind"], "record");
    assert_eq!(gone["record"]["status"], "destroyed");
    assert_eq!(f.host.forwarded.lock().unwrap()[0]["t"], "removed");
    let (conn, ..) = f.server.open();
    loop {
        if matches!(f.server.next(), Seen::Closed { conn: closed } if closed == conn) {
            break;
        }
    }
    assert_eq!(f.push.watching(CLIENT), 0);
}

#[test]
fn a_closed_socket_tells_lost_and_reconnects_with_a_fresh_bearer() {
    let f = Fixture::new(Duration::from_secs(30));
    f.server.plan(Conn::Close(vec![state(A, "running", "5")]));
    f.server.plan(Conn::Hold(vec![state(A, "paused", "6")]));
    f.watch(&[A]);
    assert_eq!(f.kinds(3), ["record", "live", "lost"]);
    let (first, _, auth, _) = f.server.open();
    assert_eq!(auth.as_deref(), Some("Bearer token-1"));
    let (second, _, auth, _) = f.server.open();
    assert_ne!(first, second);
    assert_eq!(auth.as_deref(), Some("Bearer token-2"));
    assert_eq!(f.kinds(2), ["record", "live"]);
}

#[test]
fn a_frame_after_the_lease_changed_is_dropped_and_the_socket_reopens_on_the_new_one() {
    let f = Fixture::new(Duration::from_secs(30));
    f.host.switch_once.store(true, Ordering::SeqCst);
    f.server.plan(Conn::Hold(vec![state(A, "paused", "5")]));
    f.server.plan(Conn::Hold(vec![state(A, "running", "6")]));
    f.watch(&[A]);
    let (first, _, auth, _) = f.server.open();
    assert_eq!(auth.as_deref(), Some("Bearer token-1"));
    loop {
        if matches!(f.server.next(), Seen::Closed { conn } if conn == first) {
            break;
        }
    }
    let (_, _, auth, _) = f.server.open();
    assert_eq!(auth.as_deref(), Some("Bearer token-2"));
    // Only the new lease's frame reached the app server and the app.
    let record = f.event();
    assert_eq!(record["kind"], "record");
    assert_eq!(record["record"]["status"], "running");
    assert_eq!(f.event()["kind"], "live");
    let forwarded = f.host.forwarded.lock().unwrap().clone();
    assert_eq!(forwarded.len(), 1);
}

#[test]
fn stop_closes_the_socket_and_nothing_is_delivered_after() {
    let f = Fixture::new(Duration::from_secs(30));
    f.server.plan(Conn::Hold(vec![state(A, "running", "5")]));
    f.watch(&[A]);
    assert_eq!(f.kinds(2), ["record", "live"]);
    let (conn, ..) = f.server.open();
    f.push.stop(CLIENT);
    assert_eq!(f.push.watching(CLIENT), 0);
    loop {
        if matches!(f.server.next(), Seen::Closed { conn: closed } if closed == conn) {
            break;
        }
    }
    // No reconnect, no `lost`.
    assert!(f.server.seen.recv_timeout(QUIET).is_err());
    f.quiet();
}

#[test]
fn a_new_list_closes_the_unlisted_and_keeps_the_listed() {
    let f = Fixture::new(Duration::from_secs(30));
    f.watch(&[A, B]);
    let mut opened = [f.server.open().0, f.server.open().0];
    opened.sort_unstable();
    f.watch(&[B]);
    assert_eq!(f.push.watching(CLIENT), 1);
    // One of the two closed; B's stays open (no third connection).
    loop {
        if matches!(f.server.next(), Seen::Closed { .. }) {
            break;
        }
    }
    assert!(f.server.seen.recv_timeout(QUIET).is_err());
    f.watch(&[]);
    assert_eq!(f.push.watching(CLIENT), 0);
}

#[test]
fn a_redirect_is_refused_not_followed() {
    let f = Fixture::new(Duration::from_secs(30));
    let elsewhere = TcpListener::bind("127.0.0.1:0").unwrap();
    elsewhere.set_nonblocking(true).unwrap();
    let target = format!("http://{}/v1/cloud/machines/{A}/state", elsewhere.local_addr().unwrap());
    f.server.plan(Conn::Refuse(302, Some(target)));
    f.watch(&[A]);
    assert!(matches!(f.server.next(), Seen::Refused { status: 302 }));
    // The next attempt is the backoff's, to the same server.
    let (_, _, auth, _) = f.server.open();
    assert_eq!(auth.as_deref(), Some("Bearer token-2"));
    assert!(elsewhere.accept().is_err(), "the redirect was followed");
}

#[test]
fn a_401_asks_the_app_for_a_new_session_and_tries_again() {
    let f = Fixture::new(Duration::from_secs(30));
    f.server.plan(Conn::Refuse(401, None));
    f.watch(&[A]);
    assert!(matches!(f.server.next(), Seen::Refused { status: 401 }));
    let (_, _, auth, _) = f.server.open();
    assert_eq!(auth.as_deref(), Some("Bearer token-2"));
    assert_eq!(*f.host.unauthenticated.lock().unwrap(), [1]);
}

#[test]
fn an_open_socket_sends_the_protocol_ping() {
    let f = Fixture::new(Duration::from_millis(60));
    f.watch(&[A]);
    f.server.open();
    for _ in 0..2 {
        loop {
            if let Seen::Text { text, .. } = f.server.next() {
                assert_eq!(text, push::PING);
                break;
            }
        }
    }
}

#[test]
fn only_https_or_loopback_platforms_get_a_bearer() {
    assert_eq!(
        platform_origin("https://platform.invalid/").as_deref(),
        Some("https://platform.invalid")
    );
    assert_eq!(platform_origin("http://127.0.0.1:8787").as_deref(), Some("http://127.0.0.1:8787"));
    assert_eq!(platform_origin("http://localhost:1").as_deref(), Some("http://localhost:1"));
    for bad in [
        "http://platform.invalid",
        "https://user:pw@platform.invalid",
        "https://platform.invalid/x",
        "https://platform.invalid/?a=1",
        "ftp://platform.invalid",
        "platform.invalid",
        "",
    ] {
        assert!(platform_origin(bad).is_none(), "{bad}");
    }
}

#[test]
fn a_watch_with_a_plain_http_platform_is_refused() {
    let f = Fixture::new(Duration::from_secs(30));
    let request = Watch {
        machines: vec![Machine::new(A, Status::Running)],
        platform: "http://platform.invalid".into(),
        team: None,
    };
    assert!(f.push.watch(CLIENT, f.sink.clone(), f.host.clone(), request).is_err());
    assert_eq!(f.push.watching(CLIENT), 0);
}
