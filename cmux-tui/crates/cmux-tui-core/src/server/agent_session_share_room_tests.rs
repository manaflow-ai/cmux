//! The link share bridge against a fake room that speaks `cmux.share/1` (cmux-platform's
//! `ChatShareRoom`): provisioning, its retry and give-up, the host socket's `hello` → `guests`
//! order, redeem, kicks resent until acknowledged, revoke's `end` and `DELETE`, and reconnects.
use super::super::{MAX_SHARES, ShareTerms, digest, hex};
use super::*;
use crate::server::agent_session_attach_tests::{
    Client, FakeAcpmux, Fixture, SESSION, WAIT, agent_tab, assert_code, mux_with,
};
use std::cell::RefCell;
use std::collections::{HashSet, VecDeque};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::Condvar;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::time::Instant;
use tungstenite::handshake::server::{ErrorResponse, Request, Response};

const OWNER_TOKEN: &str = "owner-access-token";
type DeleteGate = Arc<(Mutex<bool>, Condvar)>;

/// What the fake room saw, in order.
#[derive(Debug)]
enum Seen {
    Request {
        method: String,
        path: String,
        bearer: String,
        body: Value,
    },
    Host {
        conn: u64,
        bearer: String,
    },
    Frame {
        conn: u64,
        frame: Value,
    },
    /// A host socket upgrade the room refused with `status`.
    Refused {
        status: u16,
    },
}

#[derive(Default)]
struct Shared {
    /// Statuses the next `PUT`s answer; then 200 with a new host token.
    puts: Mutex<VecDeque<u16>>,
    /// Statuses the next `DELETE`s answer; then 200.
    deletes: Mutex<VecDeque<u16>>,
    /// Runs once as the next `PUT` is answered.
    on_put: Mutex<Option<Box<dyn FnOnce() + Send>>>,
    /// Overrides the next successful `PUT`'s URL base (used to exercise bad room responses).
    url_base_once: Mutex<Option<String>>,
    /// Holds every `DELETE` response until the test releases it.
    delete_gate: Mutex<Option<DeleteGate>>,
    /// Signals a test watcher as each `DELETE` enters the fake room.
    delete_entered: Mutex<Option<Sender<()>>>,
    delete_active: AtomicU64,
    delete_peak: AtomicU64,
    host_tokens: AtomicU64,
    conns: AtomicU64,
    /// The newest host socket's outbox: a frame, or `None` to close it.
    to_host: Mutex<Option<Sender<Option<Value>>>>,
    /// The status every host socket upgrade answers instead of opening, while set.
    refuse_host: Mutex<Option<u16>>,
    /// A `DELETE` closes the host socket first, as the room does: frames the daemon had not
    /// sent by then are lost.
    delete_closes_host: AtomicBool,
    /// Host sockets neither read nor write while set, as a connection lost without a close.
    silent: AtomicBool,
    /// The guests the next `hello` names as connected.
    hello: Mutex<Vec<Value>>,
}

struct FakeRoom {
    url: String,
    shared: Arc<Shared>,
    seen: Receiver<Seen>,
    buffer: RefCell<VecDeque<Seen>>,
}

impl FakeRoom {
    fn start(puts: &[u16]) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let shared = Arc::new(Shared::default());
        shared.puts.lock().unwrap().extend(puts);
        let (sender, seen) = channel();
        let (server, base) = (shared.clone(), url.clone());
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(stream) = stream else { return };
                let (shared, sender, base) = (server.clone(), sender.clone(), base.clone());
                std::thread::spawn(move || serve(stream, &shared, &sender, &base));
            }
        });
        Self { url, shared, seen, buffer: RefCell::default() }
    }

    /// The next thing seen that `wanted` accepts; others stay buffered in order.
    fn take(&self, what: &str, wanted: impl Fn(&Seen) -> bool) -> Seen {
        let mut buffer = self.buffer.borrow_mut();
        if let Some(index) = buffer.iter().position(&wanted) {
            return buffer.remove(index).unwrap();
        }
        let deadline = Instant::now() + WAIT;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            let seen =
                self.seen.recv_timeout(left).unwrap_or_else(|_| panic!("the room sees {what}"));
            if wanted(&seen) {
                return seen;
            }
            buffer.push_back(seen);
        }
    }

    /// Nothing `wanted` accepts arrives for a moment.
    fn none(&self, what: &str, wanted: impl Fn(&Seen) -> bool) {
        assert!(!self.buffer.borrow().iter().any(&wanted), "the room must not see {what}");
        let deadline = Instant::now() + Duration::from_millis(300);
        while let Ok(seen) =
            self.seen.recv_timeout(deadline.saturating_duration_since(Instant::now()))
        {
            assert!(!wanted(&seen), "the room must not see {what}: {seen:?}");
            self.buffer.borrow_mut().push_back(seen);
        }
    }

    fn host(&self) -> (u64, String) {
        match self.take("a host socket", |s| matches!(s, Seen::Host { .. })) {
            Seen::Host { conn, bearer } => (conn, bearer),
            _ => unreachable!(),
        }
    }

    /// The next frame the daemon sent on host socket `conn`.
    fn frame(&self, conn: u64) -> Value {
        match self.take("a host frame", |s| matches!(s, Seen::Frame { conn: c, .. } if *c == conn))
        {
            Seen::Frame { frame, .. } => frame,
            _ => unreachable!(),
        }
    }

    /// The next `method` request: its path, bearer and body.
    fn request(&self, method: &str) -> (String, String, Value) {
        let wanted = |s: &Seen| matches!(s, Seen::Request { method: m, .. } if m == method);
        match self.take(method, wanted) {
            Seen::Request { path, bearer, body, .. } => (path, bearer, body),
            _ => unreachable!(),
        }
    }

    fn block_deletes(&self) -> DeleteGate {
        let gate = Arc::new((Mutex::new(false), Condvar::new()));
        *self.shared.delete_gate.lock().unwrap() = Some(gate.clone());
        gate
    }

    fn watch_delete(&self) -> Receiver<()> {
        let (sender, receiver) = channel();
        *self.shared.delete_entered.lock().unwrap() = Some(sender);
        receiver
    }

    fn delete_peak(&self) -> u64 {
        self.shared.delete_peak.load(Ordering::SeqCst)
    }

    fn send(&self, frame: Value) {
        self.shared.to_host.lock().unwrap().as_ref().unwrap().send(Some(frame)).unwrap();
    }

    /// Closes the host socket the way a dropped connection does (no close code).
    fn drop_host(&self) {
        self.shared.to_host.lock().unwrap().take().unwrap().send(None).unwrap();
    }
}

fn serve(stream: TcpStream, shared: &Shared, seen: &Sender<Seen>, base: &str) {
    let mut start = [0u8; 3];
    if stream.peek(&mut start).is_ok_and(|n| n == 3) && &start == b"GET" {
        return serve_host(stream, shared, seen);
    }
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    let mut parts = line.split_whitespace();
    let method = parts.next().unwrap_or_default().to_owned();
    let path = parts.next().unwrap_or_default().to_owned();
    let (mut bearer, mut length) = (String::new(), 0usize);
    loop {
        let mut header = String::new();
        if reader.read_line(&mut header).unwrap_or(0) == 0 || header.trim().is_empty() {
            break;
        }
        let (name, value) = header.split_once(':').unwrap_or_default();
        let value = value.trim();
        match name.to_ascii_lowercase().as_str() {
            "authorization" => bearer = value.trim_start_matches("Bearer ").to_owned(),
            "content-length" => length = value.parse().unwrap_or(0),
            _ => {}
        }
    }
    let mut body = vec![0; length];
    reader.read_exact(&mut body).unwrap();
    let body = serde_json::from_slice(&body).unwrap_or(Value::Null);
    let is_delete = method == "DELETE";
    if is_delete
        && shared.delete_closes_host.load(Ordering::SeqCst)
        && let Some(host) = shared.to_host.lock().unwrap().take()
    {
        let _ = host.send(None);
    }
    if is_delete {
        let active = shared.delete_active.fetch_add(1, Ordering::SeqCst) + 1;
        shared.delete_peak.fetch_max(active, Ordering::SeqCst);
        if let Some(sender) = shared.delete_entered.lock().unwrap().take() {
            let _ = sender.send(());
        }
    }
    let (status, reply) = match method.as_str() {
        "PUT" => match shared.puts.lock().unwrap().pop_front() {
            None if shared.on_put.lock().unwrap().is_some() => {
                shared.on_put.lock().unwrap().take().unwrap()();
                let n = shared.host_tokens.fetch_add(1, Ordering::SeqCst) + 1;
                let id = path.rsplit('/').next().unwrap_or_default();
                let url_base = shared
                    .url_base_once
                    .lock()
                    .unwrap()
                    .take()
                    .unwrap_or_else(|| format!("{base}/g/{id}"));
                (200, json!({"host_token": format!("host-token-{n}"), "url_base": url_base}))
            }
            Some(status) => (status, json!({})),
            None => {
                let n = shared.host_tokens.fetch_add(1, Ordering::SeqCst) + 1;
                let id = path.rsplit('/').next().unwrap_or_default();
                let url_base = shared
                    .url_base_once
                    .lock()
                    .unwrap()
                    .take()
                    .unwrap_or_else(|| format!("{base}/g/{id}"));
                (200, json!({"host_token": format!("host-token-{n}"), "url_base": url_base}))
            }
        },
        _ => (shared.deletes.lock().unwrap().pop_front().unwrap_or(200), json!({})),
    };
    let _ = seen.send(Seen::Request { method, path, bearer, body });
    if is_delete {
        if let Some(gate) = shared.delete_gate.lock().unwrap().clone() {
            let (released, wake) = &*gate;
            let mut released = released.lock().unwrap();
            while !*released {
                released = wake.wait(released).unwrap();
            }
        }
        shared.delete_active.fetch_sub(1, Ordering::SeqCst);
    }
    let reply = reply.to_string();
    let mut stream = stream;
    let _ = write!(
        stream,
        "HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{reply}",
        reply.len()
    );
}

// tungstenite's handshake callback type fixes its large error variant.
#[allow(clippy::result_large_err)]
fn serve_host(stream: TcpStream, shared: &Shared, seen: &Sender<Seen>) {
    if let Some(status) = *shared.refuse_host.lock().unwrap() {
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        loop {
            let mut line = String::new();
            if reader.read_line(&mut line).unwrap_or(0) == 0 || line.trim().is_empty() {
                break;
            }
        }
        let mut stream = stream;
        let _ = write!(
            stream,
            "HTTP/1.1 {status} Gone\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        );
        let _ = seen.send(Seen::Refused { status });
        return;
    }
    let mut bearer = String::new();
    let callback = |request: &Request, response: Response| -> Result<Response, ErrorResponse> {
        let header = request.headers().get("authorization").and_then(|v| v.to_str().ok());
        bearer = header.unwrap_or_default().trim_start_matches("Bearer ").to_owned();
        Ok(response)
    };
    let Ok(mut socket) = tungstenite::accept_hdr(stream, callback) else { return };
    let conn = shared.conns.fetch_add(1, Ordering::SeqCst) + 1;
    let (outbox, frames) = channel();
    *shared.to_host.lock().unwrap() = Some(outbox);
    let _ = seen.send(Seen::Host { conn, bearer });
    socket.get_mut().set_read_timeout(Some(Duration::from_millis(10))).unwrap();
    let guests = shared.hello.lock().unwrap().clone();
    let hello = json!({"v": 1, "t": "hello", "guests": guests}).to_string();
    let _ = socket.send(Message::text(hello));
    loop {
        if shared.silent.load(Ordering::SeqCst) {
            std::thread::sleep(Duration::from_millis(10));
            continue;
        }
        while let Ok(next) = frames.try_recv() {
            let Some(frame) = next else {
                // Only the frames that already arrived are read.
                while let Ok(Message::Text(text)) = socket.read() {
                    let frame = serde_json::from_str(text.as_str()).unwrap();
                    let _ = seen.send(Seen::Frame { conn, frame });
                }
                let _ = socket.close(None);
                let _ = socket.flush();
                return;
            };
            // `{"ping": text}` pings, as a room or a load balancer does.
            if let Some(text) = frame["ping"].as_str() {
                let _ = socket.send(Message::Ping(text.as_bytes().to_vec().into()));
                continue;
            }
            // `{"close": code}` closes the socket with that code, as the room does.
            if let Some(code) = frame["close"].as_u64() {
                let code = tungstenite::protocol::frame::coding::CloseCode::from(code as u16);
                let _ = socket
                    .close(Some(tungstenite::protocol::CloseFrame { code, reason: "".into() }));
                let _ = socket.flush();
                continue;
            }
            let _ = socket.send(Message::text(frame.to_string()));
        }
        match socket.read() {
            Ok(Message::Text(text)) => {
                let frame = serde_json::from_str(text.as_str()).unwrap();
                let _ = seen.send(Seen::Frame { conn, frame });
            }
            Ok(Message::Pong(payload)) => {
                let pong = String::from_utf8_lossy(&payload).into_owned();
                let _ = seen.send(Seen::Frame { conn, frame: json!({"pong": pong}) });
            }
            Ok(Message::Close(_)) => return,
            Ok(_) => {}
            Err(tungstenite::Error::Io(error))
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) => {}
            Err(_) => return,
        }
    }
}

fn fast() -> Timing {
    Timing {
        request: Duration::from_secs(2),
        window: Duration::from_millis(400),
        backoff_min: Duration::from_millis(20),
        backoff_max: Duration::from_millis(100),
        heartbeat: Duration::from_millis(200),
    }
}

/// A daemon with one agent chat, bridged to `room`.
fn bridged(label: &str, room: &FakeRoom) -> (FakeAcpmux, Arc<Mux>, u64, Client) {
    bridged_with(label, room, Fixture::default())
}

fn bridged_with(
    label: &str,
    room: &FakeRoom,
    fixture: Fixture,
) -> (FakeAcpmux, Arc<Mux>, u64, Client) {
    let fake = FakeAcpmux::start_with(label, fixture);
    let mux = mux_with(&fake, label);
    assert!(shares(&mux).bridge.configure(Some(&room.url), fast()));
    let surface = agent_tab(&mux, Some(SESSION));
    let owner = Client::connect(&mux, label);
    (fake, mux, surface, owner)
}

fn create(owner: &mut Client, surface: u64) -> Value {
    owner.request(json!({"cmd":"agent-session-share-create", "surface":surface,
        "owner_token":OWNER_TOKEN}))
}

fn state(owner: &mut Client) -> Value {
    let reply = owner.request(json!({"cmd":"agent-session-share-list"}));
    reply["data"]["shares"][0].clone()
}

fn redeem(id: &str, attempt: &str, secret: &Value) -> Value {
    json!({"v": 1, "t": "redeem", "request_id": id, "attempt_id": attempt, "secret": secret,
        "name": "Theo"})
}

#[test]
fn a_provisioned_share_answers_hello_with_its_guests_and_redeems_through_the_daemon() {
    let room = FakeRoom::start(&[]);
    let (_fake, _mux, surface, mut owner) = bridged("room-redeem", &room);
    let reply = create(&mut owner, surface);
    assert_eq!(reply["ok"], true, "{reply}");
    let share = &reply["data"];
    let (id, secret) = (share["share_id"].as_str().unwrap(), share["secret"].as_str().unwrap());
    assert_eq!(share["url"], format!("{}/g/{id}#{secret}", room.url));
    // The host socket: the daemon's first frame after `hello` is its guest list.
    let (conn, bearer) = room.host();
    assert_eq!(bearer, "host-token-1");
    assert_eq!(room.frame(conn), json!({"v": 1, "t": "guests", "active": []}));
    room.send(redeem("r1", "attempt-1", &json!(secret)));
    let redeemed = room.frame(conn);
    assert_eq!(
        (redeemed["t"].clone(), redeemed["request_id"].clone()),
        (json!("redeemed"), json!("r1"))
    );
    let guest = redeemed["guest_id"].clone();
    assert_eq!(guest.as_str().unwrap().len(), 11);
    // A lost reply's retry gets the same guest; another attempt finds the one use spent.
    room.send(redeem("r2", "attempt-1", &json!(secret)));
    assert_eq!(room.frame(conn)["guest_id"], guest);
    room.send(redeem("r3", "attempt-2", &json!(secret)));
    assert_eq!(
        room.frame(conn),
        json!({"v": 1, "t": "redeemed", "request_id": "r3", "error": "share.used"})
    );
    room.send(redeem("r4", "attempt-3", &json!("AAAAAAAAAAAAAAAAAAAAAA")));
    assert_eq!(room.frame(conn)["error"], "share.secret");
    // A dropped socket reconnects, and the fresh `hello` gets the guest list first again.
    room.drop_host();
    let (again, bearer) = room.host();
    assert_eq!(bearer, "host-token-1");
    assert_eq!(room.frame(again), json!({"v": 1, "t": "guests", "active": [guest]}));
}

#[test]
fn a_kick_is_resent_until_the_room_acknowledges_it_and_a_revoke_ends_and_deletes() {
    let room = FakeRoom::start(&[]);
    let (_fake, _mux, surface, mut owner) = bridged("room-kick", &room);
    let share = create(&mut owner, surface)["data"].clone();
    let (conn, _) = room.host();
    assert_eq!(room.frame(conn)["active"], json!([]));
    let guest = owner.request(json!({"cmd":"agent-session-share-redeem",
        "share_id":share["share_id"], "secret":share["secret"], "name":"Theo",
        "attempt_id":"attempt-1"}))["data"]["guest_id"]
        .clone();
    let kick = json!({"cmd":"agent-session-share-kick", "share_id":share["share_id"],
        "guest_id":guest});
    assert_eq!(owner.request(kick)["ok"], true);
    let kicked = json!({"v": 1, "t": "kick", "guest_id": guest});
    assert_eq!(room.frame(conn), json!({"v": 1, "t": "guests", "active": []}));
    assert_eq!(room.frame(conn), kicked);
    // Not acknowledged: the next connect sends it again, after the guest list.
    room.drop_host();
    let (conn, _) = room.host();
    assert_eq!(room.frame(conn)["t"], "guests");
    assert_eq!(room.frame(conn), kicked);
    room.send(json!({"v": 1, "t": "kicked", "guest_id": guest}));
    room.drop_host();
    let (conn, _) = room.host();
    assert_eq!(room.frame(conn)["t"], "guests");
    // Acknowledged: not resent. A revoke sends `end`, closes, and deletes with the host token.
    let revoke = json!({"cmd":"agent-session-share-revoke", "share_id":share["share_id"]});
    assert_eq!(owner.request(revoke)["ok"], true);
    assert_eq!(room.frame(conn), json!({"v": 1, "t": "end", "reason": "revoked"}));
    let (path, bearer, _) = room.request("DELETE");
    let id = share["share_id"].as_str().unwrap();
    assert_eq!((path, bearer), (format!("/v1/chat-shares/{id}"), "host-token-1".to_owned()));
    room.none("another host socket", |s| matches!(s, Seen::Host { .. }));
    assert_eq!(state(&mut owner)["state"], "revoked");
}

/// The room closes the host socket when it deletes a share: `end` goes out before the `DELETE`,
/// so the room still has the reason the share ended.
#[test]
fn a_revoke_sends_end_before_the_delete_that_closes_the_socket() {
    let room = FakeRoom::start(&[]);
    room.shared.delete_closes_host.store(true, Ordering::SeqCst);
    let (_fake, _mux, surface, mut owner) = bridged("room-end-first", &room);
    let share = create(&mut owner, surface)["data"].clone();
    let (conn, _) = room.host();
    assert_eq!(room.frame(conn)["t"], "guests");
    let revoke = json!({"cmd":"agent-session-share-revoke", "share_id":share["share_id"]});
    assert_eq!(owner.request(revoke)["ok"], true);
    room.request("DELETE");
    // Read back from the frames the socket held when the DELETE closed it.
    assert_eq!(room.frame(conn), json!({"v": 1, "t": "end", "reason": "revoked"}));
}

#[test]
fn a_provisioned_share_answers_its_link_and_a_revoke_deletes_it_with_the_host_token() {
    let room = FakeRoom::start(&[]);
    let (_fake, _mux, surface, mut owner) = bridged("room-put", &room);
    let reply = create(&mut owner, surface);
    assert_eq!(reply["ok"], true, "{reply}");
    let share = &reply["data"];
    let (id, secret) = (share["share_id"].as_str().unwrap(), share["secret"].as_str().unwrap());
    assert_eq!(share["url"], format!("{}/g/{id}#{secret}", room.url));
    let (path, bearer, body) = room.request("PUT");
    assert_eq!((path, bearer), (format!("/v1/chat-shares/{id}"), OWNER_TOKEN.to_owned()));
    assert_eq!(body["secret_sha256"], hex(&digest(&[secret])));
    assert_eq!(body["uses"], 1);
    assert_eq!(body["expires_at"], share["expires_at"]);
    assert_eq!(body["provision_key"].as_str().unwrap().len(), 22);
    let listed = state(&mut owner);
    assert_eq!(
        (listed["state"].clone(), listed["room"].clone()),
        (json!("active"), json!(room.url))
    );
    assert!(!listed.to_string().contains("host-token"), "the host token stays in the daemon");
    // A redeem is the daemon's, as before; a revoke deletes the room with the host token.
    let guest = owner.request(json!({"cmd":"agent-session-share-redeem", "share_id":id,
        "secret":secret, "name":"Theo", "attempt_id":"attempt-1"}));
    assert_eq!(guest["ok"], true, "{guest}");
    let revoke = json!({"cmd":"agent-session-share-revoke", "share_id":id});
    assert_eq!(owner.request(revoke)["ok"], true);
    let (path, bearer, _) = room.request("DELETE");
    assert_eq!((path, bearer), (format!("/v1/chat-shares/{id}"), "host-token-1".to_owned()));
    room.none(
        "a second DELETE",
        |s| matches!(s, Seen::Request { method, .. } if method == "DELETE"),
    );
    assert_eq!(state(&mut owner)["state"], "revoked");
}

#[test]
fn an_unreachable_room_is_retried_then_the_share_is_revoked_and_deleted() {
    let room = FakeRoom::start(&[503; 64]);
    let (_fake, _mux, surface, mut owner) = bridged("room-down", &room);
    let reply = create(&mut owner, surface);
    assert_code(&reply, "share.room_unreachable");
    let listed = state(&mut owner);
    assert_eq!(listed["state"], "provisioning");
    let redeem = owner.request(json!({"cmd":"agent-session-share-redeem",
        "share_id":listed["share_id"], "secret":"x", "name":"Theo", "attempt_id":"a"}));
    assert_code(&redeem, "share.secret");
    // Retried with the same provision key, then given up: revoked, and the room told with the
    // owner's token (no host token was ever answered).
    let (_, _, first) = room.request("PUT");
    let (_, _, second) = room.request("PUT");
    assert_eq!(first["provision_key"], second["provision_key"]);
    let (path, bearer, _) = room.request("DELETE");
    assert_eq!(path, format!("/v1/chat-shares/{}", listed["share_id"].as_str().unwrap()));
    assert_eq!(bearer, OWNER_TOKEN);
    assert_eq!(state(&mut owner)["state"], "revoked");
    room.none("a host socket", |s| matches!(s, Seen::Host { .. }));
}

#[test]
fn a_room_that_answers_after_create_failed_is_deleted_with_its_host_token() {
    let room = FakeRoom::start(&[503, 503]);
    let (_fake, _mux, surface, mut owner) = bridged("room-late", &room);
    assert_code(&create(&mut owner, surface), "share.room_unreachable");
    for _ in 0..3 {
        room.request("PUT");
    }
    let (_, bearer, _) = room.request("DELETE");
    assert_eq!(bearer, "host-token-1");
    assert_eq!(state(&mut owner)["state"], "revoked");
    room.none("a host socket", |s| matches!(s, Seen::Host { .. }));
}

#[test]
fn a_create_without_sign_in_or_that_the_room_refuses_opens_nothing() {
    let room = FakeRoom::start(&[409, 401]);
    let (_fake, _mux, surface, mut owner) = bridged("room-refused", &room);
    let unsigned = owner.request(json!({"cmd":"agent-session-share-create", "surface":surface}));
    assert_code(&unsigned, "share.needs_sign_in");
    assert_code(&create(&mut owner, surface), "share.room_refused");
    assert_eq!(state(&mut owner)["state"], "revoked");
    assert_code(&create(&mut owner, surface), "share.needs_sign_in");
    room.request("PUT");
    room.request("PUT");
    room.none("a DELETE or a host socket", |s| {
        matches!(s, Seen::Host { .. })
            || matches!(s, Seen::Request { method, .. } if method == "DELETE")
    });
}

fn shares_of(mux: &Mux) -> &LinkShares {
    &mux.control_clients.agent_sessions.link_shares
}

#[test]
fn a_room_that_answers_after_the_share_expired_never_opens_it() {
    let room = FakeRoom::start(&[503, 503, 503]);
    let (_fake, mux, surface, mut owner) = bridged("room-expired", &room);
    assert_code(&create(&mut owner, surface), "share.room_unreachable");
    // The share's day passes while the PUT is retried; then the room answers.
    shares_of(&mux).advance(Duration::from_secs(2 * 86_400));
    for _ in 0..4 {
        room.request("PUT");
    }
    let (_, bearer, _) = room.request("DELETE");
    assert_eq!(bearer, "host-token-1", "the late room is deleted with its own token");
    let listed = state(&mut owner);
    assert_eq!(listed["state"], "expired", "never active: {listed}");
    room.none(
        "a second DELETE",
        |s| matches!(s, Seen::Request { method, .. } if method == "DELETE"),
    );
}

#[test]
fn a_delete_the_room_refuses_stays_queued_and_is_retried_until_acknowledged() {
    let room = FakeRoom::start(&[]);
    room.shared.deletes.lock().unwrap().extend([403, 401, 503]);
    let (_fake, _mux, surface, mut owner) = bridged("room-delete", &room);
    let share = create(&mut owner, surface)["data"].clone();
    room.request("PUT");
    let revoke = json!({"cmd":"agent-session-share-revoke", "share_id":share["share_id"]});
    assert_eq!(owner.request(revoke)["ok"], true);
    for _ in 0..4 {
        let (_, bearer, _) = room.request("DELETE");
        assert_eq!(bearer, "host-token-1");
    }
    room.none(
        "a DELETE after the room's 200",
        |s| matches!(s, Seen::Request { method, .. } if method == "DELETE"),
    );
}

#[test]
fn a_delete_stops_retrying_after_share_expiry_even_with_its_host_token() {
    let room = FakeRoom::start(&[]);
    room.shared.deletes.lock().unwrap().push_back(503);
    let (_fake, mux, surface, mut owner) = bridged("room-delete-expiry", &room);
    let share = create(&mut owner, surface)["data"].clone();
    room.request("PUT");
    let revoke = json!({"cmd":"agent-session-share-revoke", "share_id":share["share_id"]});
    assert_eq!(owner.request(revoke)["ok"], true);
    let (_, bearer, _) = room.request("DELETE");
    assert_eq!(bearer, "host-token-1");

    // A revoked room operation is bounded by the share's expiry even when its host token is
    // available. The first 503 leaves it queued; once the local clock passes expiry, no retry is
    // sent and the queued operation is settled.
    shares_of(&mux).advance(Duration::from_secs(2 * 86_400));
    room.none(
        "a DELETE after the share expired",
        |s| matches!(s, Seen::Request { method, .. } if method == "DELETE"),
    );
    assert_eq!(state(&mut owner)["state"], "revoked");
}

#[test]
fn expired_cleanup_retries_when_settling_the_pending_delete_cannot_be_saved() {
    let room = FakeRoom::start(&[]);
    let (_fake, mux, surface, mut owner) = bridged("room-expired-unsaved", &room);
    let share = create(&mut owner, surface)["data"].clone();
    room.request("PUT");
    assert_eq!(
        owner.request(json!({"cmd":"agent-session-share-revoke",
        "share_id":share["share_id"]}))["ok"],
        true
    );
    room.request("DELETE");

    let shares = shares_of(&mux);
    shares.advance(Duration::from_secs(2 * 86_400));
    shares.refuse_writes.store(true, Ordering::Relaxed);
    shares.expired(&mux);
    assert!(
        view(&mux, share["share_id"].as_str().unwrap()).unwrap().delete,
        "a failed expiry save keeps the DELETE pending"
    );

    shares.refuse_writes.store(false, Ordering::Relaxed);
    room.none(
        "duplicate DELETE while the one worker retries persistence",
        |s| matches!(s, Seen::Request { method, .. } if method == "DELETE"),
    );
    assert!(
        !view(&mux, share["share_id"].as_str().unwrap()).unwrap().delete,
        "the same worker eventually settles the durable operation"
    );
}

#[test]
fn a_slow_expired_delete_has_one_in_flight_worker() {
    let room = FakeRoom::start(&[]);
    let gate = room.block_deletes();
    let (_fake, mux, surface, mut owner) = bridged("room-delete-slow", &room);
    let share = create(&mut owner, surface)["data"].clone();
    room.request("PUT");
    let first = room.watch_delete();
    let revoke = json!({"cmd":"agent-session-share-revoke", "share_id":share["share_id"]});
    assert_eq!(owner.request(revoke)["ok"], true);
    first.recv_timeout(WAIT).expect("the first DELETE enters the room");

    // The expiry sweep races the slow request. It must not dispatch a second worker for the same
    // queued operation while the first worker is waiting for the room response.
    let duplicate = room.watch_delete();
    shares_of(&mux).advance(Duration::from_secs(2 * 86_400));
    shares_of(&mux).expired(&mux);
    assert!(
        shares_of(&mux).armed.lock().unwrap().is_none(),
        "the dispatched expiry is not rearmed"
    );
    assert!(duplicate.recv_timeout(Duration::from_millis(300)).is_err());

    let (released, wake) = &*gate;
    *released.lock().unwrap() = true;
    wake.notify_all();
    room.request("DELETE");
    assert_eq!(room.delete_peak(), 1, "one DELETE worker remains in flight");
}

#[test]
fn a_failed_expired_delete_has_one_in_flight_worker() {
    let room = FakeRoom::start(&[]);
    room.shared.deletes.lock().unwrap().push_back(503);
    let gate = room.block_deletes();
    let (_fake, mux, surface, mut owner) = bridged("room-delete-failed", &room);
    let share = create(&mut owner, surface)["data"].clone();
    room.request("PUT");
    let first = room.watch_delete();
    let revoke = json!({"cmd":"agent-session-share-revoke", "share_id":share["share_id"]});
    assert_eq!(owner.request(revoke)["ok"], true);
    first.recv_timeout(WAIT).expect("the failed DELETE enters the room");

    // Even a failed response that is still in flight must be owned by one cleanup worker; a
    // repeated expiry sweep cannot fan out duplicate retries.
    let duplicate = room.watch_delete();
    shares_of(&mux).advance(Duration::from_secs(2 * 86_400));
    shares_of(&mux).expired(&mux);
    assert!(
        shares_of(&mux).armed.lock().unwrap().is_none(),
        "the dispatched expiry is not rearmed"
    );
    assert!(duplicate.recv_timeout(Duration::from_millis(300)).is_err());

    let (released, wake) = &*gate;
    *released.lock().unwrap() = true;
    wake.notify_all();
    room.request("DELETE");
    assert_eq!(room.delete_peak(), 1, "one failed DELETE worker remains in flight");
}

#[test]
fn revoking_an_already_expired_share_starts_room_cleanup() {
    let room = FakeRoom::start(&[]);
    let (_fake, mux, surface, mut owner) = bridged("room-revoke-expired", &room);
    let share = create(&mut owner, surface)["data"].clone();
    room.request("PUT");

    // `with` marks an active share expired before the revoke runs. The room DELETE still has to
    // be scheduled even though the normal live-to-ended transition is no longer present.
    shares_of(&mux).advance(Duration::from_secs(2 * 86_400));
    shares_of(&mux).expired(&mux);
    let revoke = json!({"cmd":"agent-session-share-revoke", "share_id":share["share_id"]});
    assert_eq!(owner.request(revoke)["ok"], true);
    let (_, bearer, _) = room.request("DELETE");
    assert_eq!(bearer, "host-token-1");
}

#[test]
fn restart_resumes_roomless_pending_deletes_at_expiry_and_frees_capacity() {
    let room = FakeRoom::start(&[]);
    let root = std::env::temp_dir()
        .join(format!("cmux-room-restart-{}", crate::workspace_registry::new_uuid_v4()));
    let options = crate::SurfaceOptions::default();
    let mux = Mux::open_persistent("room-restart", options.clone(), &root).unwrap();
    let shares = shares_of(&mux);
    let directory = mux.session_state_directory().unwrap();
    let expires_at = shares.now().saturating_add(60_000);
    shares
        .with(Some(&directory), |all, _| {
            all.extend((0..MAX_SHARES).map(|index| LinkShare {
                share_id: format!("pending-{index}"),
                session: SESSION.into(),
                surface: 1,
                created_at: expires_at.saturating_sub(60_000),
                expires_at,
                uses_left: 0,
                state: ShareState::Revoked,
                secret_sha256: String::new(),
                provision_key: None,
                create_id: None,
                room: None,
                pending_room_ops: vec![json!({"op": "delete"})],
                guests: Vec::new(),
            }));
            Ok(((), true))
        })
        .unwrap();
    let initial_pending = shares
        .with(Some(&directory), |all, _| {
            Ok((all.iter().filter(|share| !share.pending_room_ops.is_empty()).count(), false))
        })
        .unwrap();
    assert_eq!(initial_pending, MAX_SHARES);

    mux.shutdown();
    drop(mux);
    let mux = Mux::open_persistent("room-restart", options, &root).unwrap();
    let shares = shares_of(&mux);

    // A restart has no owner credential or host token for these failed provisions. It must still
    // resume the records and wake a credentialless cleanup at their expiry.
    start_link_share_bridge(&mux, Some(&room.url));
    shares.advance(Duration::from_secs(2 * 86_400));
    shares.expired(&mux);
    // Each settles on the bridge's own worker (`delete`), not inside `expired`.
    let pending = || {
        shares
            .with(Some(&directory), |all, _| {
                Ok((all.iter().filter(|share| !share.pending_room_ops.is_empty()).count(), false))
            })
            .unwrap()
    };
    let deadline = Instant::now() + WAIT;
    while pending() > 0 && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(pending(), 0, "credentialless pending room deletes settle at expiry");
    assert!(
        shares
            .insert(
                Some(&directory),
                SESSION.into(),
                1,
                ShareTerms { ttl_secs: 3600, uses: 1, create_id: None },
                false
            )
            .is_ok()
    );
    drop(mux);
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn a_room_rejects_a_cross_origin_guest_url() {
    let room = FakeRoom::start(&[]);
    *room.shared.url_base_once.lock().unwrap() = Some("https://evil.example/g/not-the-room".into());
    let (_fake, _mux, surface, mut owner) = bridged("room-bad-url", &room);
    let reply = create(&mut owner, surface);
    assert_code(&reply, "share.room_unreachable");
    let (_, _, _) = room.request("PUT");
    // The invalid first answer is rejected; the retry's valid answer is cleaned up because the
    // create call already returned a failure and never handed its link to a guest.
    room.request("PUT");
    room.request("DELETE");
}

#[test]
fn a_room_whose_answer_could_not_be_written_is_still_deleted_with_its_host_token() {
    let room = FakeRoom::start(&[]);
    room.shared.deletes.lock().unwrap().push_back(503);
    let (_fake, mux, surface, mut owner) = bridged("room-unsaved", &room);
    // The room answers the PUT, and the write of its answer fails.
    let refusing = mux.clone();
    *room.shared.on_put.lock().unwrap() = Some(Box::new(move || {
        shares_of(&refusing).refuse_writes.store(true, Ordering::Relaxed);
    }));
    assert_code(&create(&mut owner, surface), "share.unsaved");
    room.request("PUT");
    let (_, bearer, _) = room.request("DELETE");
    assert_eq!(bearer, "host-token-1", "the host token the write lost is held");
    assert_eq!(state(&mut owner)["state"], "provisioning", "the record never opened");
    // Once a write succeeds the room and its DELETE are the record's.
    shares_of(&mux).refuse_writes.store(false, Ordering::Relaxed);
    let (_, bearer, _) = room.request("DELETE");
    assert_eq!(bearer, "host-token-1");
    let listed = state(&mut owner);
    assert_eq!(
        (listed["state"].clone(), listed["room"].clone()),
        (json!("revoked"), json!(room.url))
    );
}

#[test]
fn invalid_configured_rooms_refuse_creation_but_unset_keeps_local_shares() {
    let fake = FakeAcpmux::start("room-invalid-config");
    let mux = mux_with(&fake, "room-invalid-config");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut owner = Client::connect(&mux, "room-invalid-owner");
    for url in ["http://example.com", "not a url", "", "   "] {
        start_link_share_bridge(&mux, Some(url));
        assert_code(&create(&mut owner, surface), "share.room_unreachable");
        let listed = owner.request(json!({"cmd":"agent-session-share-list"}));
        assert_eq!(listed["data"]["shares"], json!([]));
    }
    start_link_share_bridge(&mux, None);
    let created = create(&mut owner, surface);
    assert_eq!(created["ok"], true);
    assert!(created["data"]["url"].is_null());
    assert_eq!(state(&mut owner)["state"], "active");
}

#[test]
fn retry_exhaustion_keeps_owner_cleanup_when_revocation_cannot_be_written() {
    let room = FakeRoom::start(&[]);
    room.shared.deletes.lock().unwrap().push_back(503);
    let (_fake, mux, surface, _owner) = bridged("room-owner-unsaved", &room);
    let shares = shares_of(&mux);
    let created = shares
        .insert(
            None,
            SESSION.into(),
            surface,
            ShareTerms { ttl_secs: 60, uses: 1, create_id: None },
            true,
        )
        .unwrap();
    let id = created["share_id"].as_str().unwrap().to_owned();
    shares.refuse_writes.store(true, Ordering::Relaxed);
    let mut configured = shares.bridge.room().unwrap();
    configured.timing.window = Duration::ZERO;
    // Drive the retry-window exhaustion itself: its attempt to persist the revoke fails.
    shares.bridge.runtime().unwrap().block_on(retry(
        Arc::downgrade(&mux),
        id.clone(),
        configured,
        Zeroizing::new(OWNER_TOKEN.to_owned()),
        json!({}),
    ));
    let (_, bearer, _) = room.request("DELETE");
    assert_eq!(bearer, OWNER_TOKEN, "failed persistence must not discard the owner token");
    assert!(!view(&mux, &id).unwrap().delete, "the failed write left no durable operation");
    shares.refuse_writes.store(false, Ordering::Relaxed);
    let (_, bearer, _) = room.request("DELETE");
    assert_eq!(bearer, OWNER_TOKEN, "the retained credential retries cleanup");
    let stored = shares.with(None, |all, _| Ok((all[0].state, false))).unwrap();
    assert_eq!(stored, ShareState::Revoked);
}

#[test]
fn revoking_before_the_put_answer_persists_cleanup_across_restart() {
    let room = FakeRoom::start(&[]);
    let root = std::env::temp_dir()
        .join(format!("cmux-room-revoke-restart-{}", crate::workspace_registry::new_uuid_v4()));
    let mux =
        Mux::open_persistent("revoke-restart", crate::SurfaceOptions::default(), &root).unwrap();
    let directory = mux.session_state_directory().unwrap();
    let shares = shares_of(&mux);
    shares.serve(&mux);
    let created = shares
        .insert(
            Some(&directory),
            SESSION.into(),
            1,
            ShareTerms { ttl_secs: 60, uses: 1, create_id: None },
            true,
        )
        .unwrap();
    let id = created["share_id"].as_str().unwrap().to_owned();
    shares
        .end(Some(&directory), &super::super::Named { share_id: id.clone(), guest_id: None })
        .unwrap();
    assert!(view(&mux, &id).unwrap().delete, "revoke persists intent before a PUT answers");
    mux.shutdown();
    drop(mux);

    let mux =
        Mux::open_persistent("revoke-restart", crate::SurfaceOptions::default(), &root).unwrap();
    start_link_share_bridge(&mux, Some(&room.url));
    assert!(view(&mux, &id).unwrap().delete, "restart keeps the revoked provision's cleanup");
    // A late provision response can now attach its host token to the durable intent.
    assert!(retire(&mux, &id, &room.url, "late-host-token"));
    shares_of(&mux).advance(Duration::from_secs(61));
    shares_of(&mux).expired(&mux);
    let (_, bearer, _) = room.request("DELETE");
    assert_eq!(bearer, "late-host-token");
    mux.shutdown();
    drop(mux);
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn a_revoked_inflight_provision_is_not_evicted_before_its_late_host_token() {
    let room = FakeRoom::start(&[]);
    let (_fake, mux, surface, _owner) = bridged("room-late-capacity", &room);
    let shares = shares_of(&mux);
    let created = shares
        .insert(
            None,
            SESSION.into(),
            surface,
            ShareTerms { ttl_secs: 60, uses: 1, create_id: None },
            true,
        )
        .unwrap();
    let id = created["share_id"].as_str().unwrap().to_owned();
    shares.end(None, &super::super::Named { share_id: id.clone(), guest_id: None }).unwrap();
    for _ in 1..MAX_SHARES {
        shares
            .insert(
                None,
                SESSION.into(),
                surface,
                ShareTerms { ttl_secs: 60, uses: 1, create_id: None },
                false,
            )
            .unwrap();
    }
    assert_eq!(
        shares.insert(
            None,
            SESSION.into(),
            surface,
            ShareTerms { ttl_secs: 60, uses: 1, create_id: None },
            false
        ),
        Err("share.limit")
    );
    delete(&mux, &id, Some(Held::Host(room.url.clone(), Zeroizing::new("late-host".into()))));
    let (path, bearer, _) = room.request("DELETE");
    assert_eq!(path, format!("/v1/chat-shares/{id}"));
    assert_eq!(bearer, "late-host");
}

#[test]
fn a_late_host_token_for_an_inflight_tokenless_delete_still_reaches_the_room() {
    let room = FakeRoom::start(&[]);
    let (_fake, mux, surface, _owner) = bridged("room-late-token-race", &room);
    let shares = shares_of(&mux);
    let created = shares
        .insert(
            None,
            SESSION.into(),
            surface,
            ShareTerms { ttl_secs: 60, uses: 1, create_id: None },
            true,
        )
        .unwrap();
    let id = created["share_id"].as_str().unwrap().to_owned();
    shares.end(None, &super::super::Named { share_id: id.clone(), guest_id: None }).unwrap();
    assert!(view(&mux, &id).unwrap().delete, "the revoke queues the room's DELETE");
    // A cleanup worker is in flight for the share and has read it with no credential (the
    // revoke's own worker, if it ran, has ended: it had no credential either).
    let deadline = Instant::now() + WAIT;
    while !shares.claim_room_delete(&id) {
        assert!(Instant::now() < deadline, "the revoke's worker ends");
        std::thread::sleep(Duration::from_millis(10));
    }
    // The late PUT answers: the worker holds the claim, so the token goes to the record.
    delete(&mux, &id, Some(Held::Host(room.url.clone(), Zeroizing::new("late-host".into()))));
    room.none(
        "a DELETE while the worker holds the claim",
        |s| matches!(s, Seen::Request { method, .. } if method == "DELETE"),
    );
    assert_eq!(view(&mux, &id).unwrap().host_token.as_deref(), Some("late-host"));
    // The worker ends for want of the credential it read before the write.
    drop(DeleteGuard { mux: Arc::downgrade(&mux), share_id: id.clone(), tokenless: true });
    let (path, bearer, _) = room.request("DELETE");
    assert_eq!(path, format!("/v1/chat-shares/{id}"));
    assert_eq!(bearer, "late-host", "the room is deleted now, not at the share's expiry");
}

#[test]
fn room_responses_are_bounded_with_or_without_content_length() {
    // The response is small control-plane JSON, never an attachment or transcript.
    let oversized = format!("{{\"padding\":\"{}\"}}", "x".repeat(64 * 1024));
    for chunked in [false, true] {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let body = oversized.clone();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            loop {
                let mut line = String::new();
                if reader.read_line(&mut line).unwrap() == 0 || line.trim().is_empty() {
                    break;
                }
            }
            if chunked {
                let _ = write!(
                    stream,
                    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
                );
                for chunk in body.as_bytes().chunks(4096) {
                    if write!(stream, "{:x}\r\n", chunk.len()).is_err()
                        || stream.write_all(chunk).is_err()
                        || stream.write_all(b"\r\n").is_err()
                    {
                        return;
                    }
                }
                let _ = stream.write_all(b"0\r\n\r\n");
            } else {
                let _ = write!(
                    stream,
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
            }
        });
        let bridge = Bridge::default();
        let response = bridge.runtime().unwrap().block_on(call(
            reqwest::Method::DELETE,
            &url,
            "host-token",
            None,
            Duration::from_secs(2),
        ));
        server.join().unwrap();
        assert!(response.is_none(), "oversized response accepted (chunked={chunked})");
    }
}

#[test]
fn closing_the_chat_closes_its_share_its_guests_and_its_room() {
    let room = FakeRoom::start(&[]);
    let (_fake, mux, surface, mut owner) = bridged("room-closed", &room);
    let share = create(&mut owner, surface)["data"].clone();
    let (conn, _) = room.host();
    assert_eq!(room.frame(conn)["t"], "guests");
    let guest = owner.request(json!({"cmd":"agent-session-share-redeem",
        "share_id":share["share_id"], "secret":share["secret"], "name":"Theo",
        "attempt_id":"attempt-1"}));
    let mut link = Client::connect(&mux, "room-closed-guest");
    let bound = link.request(json!({"cmd":"agent-session-proxy-bind", "link_guest":
        {"share_id": share["share_id"], "guest_id": guest["data"]["guest_id"]}}));
    assert_eq!(bound["ok"], true, "{bound}");
    // acpmux says the chat was closed.
    crate::server::close_chat_shares(&mux, SESSION);
    assert_eq!(room.frame(conn), json!({"v": 1, "t": "end", "reason": "closed"}));
    let (_, bearer, _) = room.request("DELETE");
    assert_eq!(bearer, "host-token-1");
    let deadline = Instant::now() + WAIT;
    while !mux.control_clients.agent_sessions.proxy_authors.lock().unwrap().is_empty() {
        assert!(Instant::now() < deadline, "the guest's connection is closed");
        std::thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(state(&mut owner)["state"], "closed");
    room.none("another host socket", |s| matches!(s, Seen::Host { .. }));
}

#[test]
fn a_restart_reopens_the_host_socket_of_an_active_bridged_share() {
    let room = FakeRoom::start(&[]);
    let root = std::env::temp_dir()
        .join(format!("cmux-room-host-restart-{}", crate::workspace_registry::new_uuid_v4()));
    let options = crate::SurfaceOptions::default();
    let mux = Mux::open_persistent("host-restart", options.clone(), &root).unwrap();
    let shares = shares_of(&mux);
    let directory = mux.session_state_directory().unwrap();
    let now = shares.now();
    shares
        .with(Some(&directory), |all, _| {
            all.push(LinkShare {
                share_id: "active-1".into(),
                session: SESSION.into(),
                surface: 1,
                created_at: now,
                expires_at: now.saturating_add(3_600_000),
                uses_left: 1,
                state: ShareState::Active,
                secret_sha256: String::new(),
                provision_key: None,
                create_id: None,
                room: Some(json!({"url": room.url, "host_token": "kept-host-token"})),
                pending_room_ops: Vec::new(),
                guests: Vec::new(),
            });
            Ok(((), true))
        })
        .unwrap();
    mux.shutdown();
    drop(mux);

    let mux = Mux::open_persistent("host-restart", options, &root).unwrap();
    start_link_share_bridge(&mux, Some(&room.url));
    let (_, bearer) = room.host();
    assert_eq!(bearer, "kept-host-token");
    mux.shutdown();
    drop(mux);
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn a_kick_of_an_ended_share_holds_no_capacity_and_goes_with_its_delete() {
    let room = FakeRoom::start(&[]);
    let (_fake, mux, surface, _owner) = bridged("room-moot-kicks", &room);
    let shares = shares_of(&mux);
    let now = shares.now();
    shares
        .with(None, |all, _| {
            all.extend((0..MAX_SHARES).map(|index| LinkShare {
                share_id: format!("ended-{index}"),
                session: SESSION.into(),
                surface,
                created_at: now,
                expires_at: now.saturating_add(60_000),
                uses_left: 0,
                state: ShareState::Revoked,
                secret_sha256: String::new(),
                provision_key: None,
                create_id: None,
                room: Some(json!({"url": room.url, "host_token": "t"})),
                pending_room_ops: vec![json!({"op": "kick", "guest_id": "g"})],
                guests: Vec::new(),
            }));
            Ok(((), false))
        })
        .unwrap();
    assert!(
        shares
            .insert(
                None,
                SESSION.into(),
                surface,
                ShareTerms { ttl_secs: 60, uses: 1, create_id: None },
                false
            )
            .is_ok()
    );
    shares
        .with(None, |all, _| {
            all[0].pending_room_ops.push(json!({"op": "delete"}));
            Ok(((), false))
        })
        .unwrap();
    let id = shares.with(None, |all, _| Ok((all[0].share_id.clone(), false))).unwrap();
    assert!(done(&mux, &id, &json!({"op": "delete"})));
    let left = shares.with(None, |all, _| Ok((all[0].pending_room_ops.clone(), false))).unwrap();
    assert!(left.is_empty(), "the DELETE's answer also drops the moot kick: {left:?}");
}

#[test]
fn closing_the_chat_stands_when_its_write_fails() {
    let room = FakeRoom::start(&[]);
    let (_fake, mux, surface, mut owner) = bridged("room-close-unsaved", &room);
    let share = create(&mut owner, surface)["data"].clone();
    let (conn, _) = room.host();
    assert_eq!(room.frame(conn)["t"], "guests");
    let shares = shares_of(&mux);
    shares.refuse_writes.store(true, Ordering::Relaxed);
    crate::server::close_chat_shares(&mux, SESSION);
    assert_eq!(room.frame(conn), json!({"v": 1, "t": "end", "reason": "closed"}));
    room.request("DELETE");
    let redeem = owner.request(json!({"cmd":"agent-session-share-redeem",
        "share_id":share["share_id"], "secret":share["secret"], "name":"Late",
        "attempt_id":"attempt-late"}));
    assert_code(&redeem, "share.closed");
    shares.refuse_writes.store(false, Ordering::Relaxed);
    assert_eq!(state(&mut owner)["state"], "closed");
}

#[test]
fn a_share_the_room_ended_ends_here_and_is_not_reconnected() {
    let room = FakeRoom::start(&[]);
    let (_fake, _mux, surface, mut owner) = bridged("room-ended-there", &room);
    create(&mut owner, surface);
    let (conn, _) = room.host();
    assert_eq!(room.frame(conn)["t"], "guests");
    room.send(json!({"close": 4001}));
    let deadline = Instant::now() + WAIT;
    while state(&mut owner)["state"] != "revoked" {
        assert!(Instant::now() < deadline, "the share ends when its room ended it");
        std::thread::sleep(Duration::from_millis(5));
    }
    room.none("another host socket", |s| matches!(s, Seen::Host { .. }));
    room.none(
        "a DELETE of a room already gone",
        |s| matches!(s, Seen::Request { method, .. } if method == "DELETE"),
    );
}

/// The room's expiry alarm may end a share before the daemon's own timer: the room's `end`
/// reason keeps it expired here, not revoked.
#[test]
fn a_share_the_room_expired_is_expired_here() {
    let room = FakeRoom::start(&[]);
    let (_fake, _mux, surface, mut owner) = bridged("room-expired-there", &room);
    create(&mut owner, surface);
    let (conn, _) = room.host();
    assert_eq!(room.frame(conn)["t"], "guests");
    room.send(json!({"v": 1, "t": "end", "reason": "expired"}));
    room.send(json!({"close": 4001}));
    let deadline = Instant::now() + WAIT;
    while state(&mut owner)["state"] != "expired" {
        assert!(Instant::now() < deadline, "the share the room expired is expired here");
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[test]
fn only_guest_facing_redeem_refusals_reach_the_room() {
    assert!(GUEST_REFUSALS.contains(&"share.used"));
    for internal in ["share.unsaved", "share.unknown", "share.provisioning", "share.bad_request"] {
        assert!(!GUEST_REFUSALS.contains(&internal), "{internal} stays in the daemon");
    }
}

#[test]
fn a_whole_chat_list_closes_the_shares_of_chats_it_left_out() {
    let room = FakeRoom::start(&[]);
    let (_fake, mux, surface, mut owner) = bridged("room-unlisted", &room);
    create(&mut owner, surface);
    let (conn, _) = room.host();
    assert_eq!(room.frame(conn)["t"], "guests");
    let listed = std::iter::once(SESSION.to_owned()).collect();
    let before = crate::server::open_chat_shares(&mux);
    assert_eq!(before.len(), 1);
    crate::server::close_unlisted_chat_shares(&mux, &listed, &before);
    assert_eq!(state(&mut owner)["state"], "active", "a listed chat keeps its share");
    // A share created after the list was asked for may be of a chat the list is too old to name.
    crate::server::close_unlisted_chat_shares(&mux, &HashSet::new(), &HashSet::new());
    assert_eq!(state(&mut owner)["state"], "active", "a share newer than the list stays");
    // A closed page closes only shares older than the list.
    crate::server::close_listed_chat_shares(&mux, SESSION, &HashSet::new());
    assert_eq!(state(&mut owner)["state"], "active", "a share newer than a closed page stays");
    crate::server::close_unlisted_chat_shares(&mux, &HashSet::new(), &before);
    assert_eq!(room.frame(conn), json!({"v": 1, "t": "end", "reason": "closed"}));
    room.request("DELETE");
    assert_eq!(state(&mut owner)["state"], "closed");
}

/// A host socket that goes quiet without a close (its connection lost, a NAT mapping gone) is
/// pinged, dropped when nothing answers, and opened again.
#[test]
fn a_host_socket_lost_without_a_close_is_opened_again() {
    let room = FakeRoom::start(&[]);
    let (_fake, _mux, surface, mut owner) = bridged("room-silent", &room);
    create(&mut owner, surface);
    let (conn, _) = room.host();
    assert_eq!(room.frame(conn)["t"], "guests");
    room.shared.silent.store(true, Ordering::SeqCst);
    let (again, _) = room.host();
    room.shared.silent.store(false, Ordering::SeqCst);
    assert!(again > conn, "a fresh socket");
    assert_eq!(room.frame(again)["t"], "guests");
}

/// A kick that races the share's end sends nothing after it: an ended share's socket sends only
/// `end`.
#[test]
fn an_ended_share_reconciles_nothing() {
    let room = FakeRoom::start(&[]);
    let (_fake, mux, surface, mut owner) = bridged("room-ended-kick", &room);
    let share = create(&mut owner, surface)["data"].clone();
    let id = share["share_id"].as_str().unwrap().to_owned();
    let (conn, _) = room.host();
    assert_eq!(room.frame(conn)["t"], "guests");
    let guest = owner.request(json!({"cmd":"agent-session-share-redeem",
        "share_id":id, "secret":share["secret"], "name":"Theo",
        "attempt_id":"attempt-1"}))["data"]["guest_id"]
        .clone();
    let kick = json!({"cmd":"agent-session-share-kick", "share_id":id, "guest_id":guest});
    assert_eq!(owner.request(kick)["ok"], true);
    assert!(!reconcile(&mux, &id).is_empty(), "an active share sends its kicks");
    let revoke = json!({"cmd":"agent-session-share-revoke", "share_id":id});
    assert_eq!(owner.request(revoke)["ok"], true);
    assert_eq!(reconcile(&mux, &id), Vec::<Value>::new(), "an ended share sends no kick");
}

/// A room that refuses the host for good (401/403 at the upgrade, or close code 4003) leaves no
/// share that looks usable: it is revoked here and its room `DELETE` runs.
#[test]
fn a_host_the_room_refuses_for_good_revokes_the_share() {
    for refusal in ["403", "4003"] {
        let room = FakeRoom::start(&[]);
        let (_fake, _mux, surface, mut owner) = bridged(&format!("room-refused-{refusal}"), &room);
        create(&mut owner, surface);
        let (conn, _) = room.host();
        assert_eq!(room.frame(conn)["t"], "guests");
        if refusal == "403" {
            *room.shared.refuse_host.lock().unwrap() = Some(403);
            room.drop_host();
            room.take("the refused upgrade", |s| matches!(s, Seen::Refused { status: 403 }));
        } else {
            room.send(json!({"close": 4003}));
        }
        let deadline = Instant::now() + WAIT;
        while state(&mut owner)["state"] != "revoked" {
            assert!(
                Instant::now() < deadline,
                "{refusal}: the share ends when its host is refused"
            );
            std::thread::sleep(Duration::from_millis(5));
        }
        room.request("DELETE");
    }
}

#[test]
fn the_host_socket_answers_a_ping() {
    let room = FakeRoom::start(&[]);
    let (_fake, _mux, surface, mut owner) = bridged("room-ping", &room);
    create(&mut owner, surface);
    let (conn, _) = room.host();
    assert_eq!(room.frame(conn)["t"], "guests");
    room.send(json!({"ping": "keepalive"}));
    assert_eq!(room.frame(conn), json!({"pong": "keepalive"}));
}

#[test]
fn a_share_the_room_no_longer_has_ends_here() {
    let room = FakeRoom::start(&[]);
    let (_fake, _mux, surface, mut owner) = bridged("room-gone", &room);
    create(&mut owner, surface);
    let (conn, _) = room.host();
    assert_eq!(room.frame(conn)["t"], "guests");
    *room.shared.refuse_host.lock().unwrap() = Some(404);
    room.drop_host();
    room.take("a refused upgrade", |s| matches!(s, Seen::Refused { status: 404 }));
    let deadline = Instant::now() + WAIT;
    while state(&mut owner)["state"] != "revoked" {
        assert!(Instant::now() < deadline, "a share its room no longer has ends here");
        std::thread::sleep(Duration::from_millis(5));
    }
    room.none(
        "a DELETE of a room already gone",
        |s| matches!(s, Seen::Request { method, .. } if method == "DELETE"),
    );
}

#[test]
fn a_room_end_stands_when_its_write_fails() {
    let room = FakeRoom::start(&[]);
    let (_fake, mux, surface, mut owner) = bridged("room-ended-unsaved", &room);
    let share = create(&mut owner, surface)["data"].clone();
    let (conn, _) = room.host();
    assert_eq!(room.frame(conn)["t"], "guests");
    shares_of(&mux).refuse_writes.store(true, Ordering::Relaxed);
    room.send(json!({"close": 4001}));
    let deadline = Instant::now() + WAIT;
    loop {
        let redeem = owner.request(json!({"cmd":"agent-session-share-redeem",
            "share_id":share["share_id"], "secret":share["secret"], "name":"Late",
            "attempt_id":"attempt-late"}));
        if redeem["error_code"] == "share.revoked" {
            break;
        }
        assert!(Instant::now() < deadline, "the room's end stands unwritten: {redeem}");
        std::thread::sleep(Duration::from_millis(5));
    }
    shares_of(&mux).refuse_writes.store(false, Ordering::Relaxed);
}

// MARK: The guest relay

impl FakeRoom {
    /// The next frame of type `t` the daemon sent on host socket `conn`.
    fn next(&self, conn: u64, t: &str) -> Value {
        let wanted =
            |s: &Seen| matches!(s, Seen::Frame { conn: c, frame } if *c == conn && frame["t"] == t);
        match self.take(t, wanted) {
            Seen::Frame { frame, .. } => frame,
            _ => unreachable!(),
        }
    }
}

/// A transcript record of `bytes` bytes of text.
fn sized(seq: u64, bytes: usize) -> Value {
    json!({"sessionId": SESSION, "seq": seq, "dir": "in", "kind": "agent_message",
        "msg": {"text": "x".repeat(bytes)}})
}

/// A share with two redeemed guests and its host socket past `guests`: (share, [guest ids], conn).
fn two_guests(room: &FakeRoom, owner: &mut Client, surface: u64) -> (Value, [String; 2], u64) {
    let reply = owner.request(json!({"cmd":"agent-session-share-create", "surface":surface,
        "owner_token":OWNER_TOKEN, "uses":2}));
    let share = reply["data"].clone();
    let (conn, _) = room.host();
    assert_eq!(room.next(conn, "guests")["active"], json!([]));
    let mut guests = [String::new(), String::new()];
    for (index, name) in ["Ann", "Bob"].into_iter().enumerate() {
        let reply = owner.request(json!({"cmd":"agent-session-share-redeem",
            "share_id":share["share_id"], "secret":share["secret"], "name":name,
            "attempt_id":format!("attempt-{index}")}));
        guests[index] = reply["data"]["guest_id"].as_str().unwrap().to_owned();
    }
    (share, guests, conn)
}

#[test]
fn a_guest_gets_a_bounded_snapshot_its_own_records_and_its_prompts_states() {
    let room = FakeRoom::start(&[]);
    // 200 KiB, 200 KiB, a 300 KiB record (sent cut) and 200 KiB: the newest that fit in 512 KiB.
    let page = vec![
        sized(10, 200 << 10),
        sized(11, 200 << 10),
        sized(12, 300 << 10),
        sized(13, 200 << 10),
    ];
    let history = vec![sized(3, 10), sized(4, 10)];
    let fixture = Fixture { page, history, ..Fixture::default() };
    let (mut fake, _mux, surface, mut owner) = bridged_with("relay-snap", &room, fixture);
    let (_, [ann, bob], conn) = two_guests(&room, &mut owner, surface);
    room.send(json!({"v": 1, "t": "guest_joined", "guest_id": ann}));
    let snapshot = room.next(conn, "snapshot");
    assert!(snapshot.to_string().len() <= 512 << 10, "the whole frame fits");
    assert_eq!((snapshot["to"].clone(), snapshot["has_more"].clone()), (json!(ann), json!(true)));
    let seqs: Vec<u64> = snapshot["records"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["seq"].as_u64().unwrap())
        .collect();
    assert_eq!(seqs, vec![11, 12, 13], "the newest records, oldest first");
    let cut = &snapshot["records"][1];
    assert_eq!(
        (cut["truncated"].clone(), cut["kind"].clone()),
        (json!(true), json!("agent_message"))
    );
    assert!(cut["full_bytes"].as_u64().unwrap() > 300 << 10 && cut.get("msg").is_none());
    assert_eq!(
        (snapshot["watermark"].clone(), snapshot["chat"]["status"].clone()),
        (json!(13), json!("running"))
    );
    // The record acpmux sent while the attach was answered follows the snapshot, to Ann only.
    let early = room.next(conn, "records");
    assert_eq!((early["to"].clone(), early["records"][0]["seq"].clone()), (json!([ann]), json!(2)));
    while fake.next_frame(Duration::from_millis(300)).is_some() {}
    // Ann's prompt reaches acpmux as hers and held; its states follow acpmux's records.
    room.send(json!({"v": 1, "t": "guest_prompt", "guest_id": ann, "client_id": "c1",
        "text": "hello"}));
    let sent = fake.frame();
    assert_eq!(sent["method"], "session/prompt");
    let prompt = sent["params"]["_meta"]["acpmux"]["promptId"].as_str().unwrap().to_owned();
    assert_eq!(sent["params"]["_meta"]["acpmux"]["author"]["approval"], "owner");
    let state = |state: &str| {
        json!({"v": 1, "t": "prompt_state", "guest_id": ann,
        "client_id": "c1", "prompt_id": prompt, "state": state})
    };
    assert_eq!(room.next(conn, "prompt_state"), state("held"));
    for (seq, kind, extra) in [
        (20, "queued", json!({"awaitingOwner": true, "revision": 0})),
        (21, "queue_approved", json!({"revision": 0})),
    ] {
        let mut msg = json!({"promptId": prompt});
        msg.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
        fake.notify(
            "_acpmux/event",
            json!({"sessionId": SESSION, "seq": seq, "dir": "mux",
            "kind": kind, "msg": msg}),
        );
        let records = room.next(conn, "records");
        assert_eq!(
            (records["to"].clone(), records["records"][0]["seq"].clone()),
            (json!([ann]), json!(seq))
        );
    }
    assert_eq!(room.next(conn, "prompt_state"), state("approved"), "held was already said");
    room.send(json!({"v": 1, "t": "prompt_status", "guest_id": ann, "client_ids": ["c1", "c9"]}));
    assert_eq!(room.next(conn, "prompt_state"), state("approved"));
    room.send(json!({"v": 1, "t": "older", "guest_id": ann, "before_seq": 11}));
    let page = room.next(conn, "page");
    assert_eq!((page["to"].clone(), page["has_more"].clone()), (json!(ann), json!(false)));
    assert_eq!(page["records"].as_array().unwrap().len(), 2);
    // Nothing went to Bob, whose browser never joined, nor about a prompt it never sent.
    room.none("a frame for Bob", |s| {
        matches!(s, Seen::Frame { frame, .. }
        if frame.to_string().contains(&bob))
    });
    room.none("a second state", |s| {
        matches!(s, Seen::Frame { frame, .. }
        if frame["t"] == "prompt_state")
    });
}

#[test]
fn reconnects_get_fresh_snapshots_and_a_kick_ends_the_guests_relay() {
    let room = FakeRoom::start(&[]);
    let (fake, _mux, surface, mut owner) = bridged("relay-again", &room);
    let (share, [ann, bob], conn) = two_guests(&room, &mut owner, surface);
    room.send(json!({"v": 1, "t": "guest_joined", "guest_id": ann}));
    assert_eq!(room.next(conn, "snapshot")["to"], json!(ann));
    // A guest reconnect: a fresh snapshot.
    room.send(json!({"v": 1, "t": "guest_joined", "guest_id": ann}));
    assert_eq!(room.next(conn, "snapshot")["to"], json!(ann));
    // A host reconnect: `guests` first, then a snapshot for each guest still connected.
    room.shared
        .hello
        .lock()
        .unwrap()
        .extend([json!({"guest_id": ann, "name": "Ann"}), json!({"guest_id": bob, "name": "Bob"})]);
    room.drop_host();
    let (conn, _) = room.host();
    assert_eq!(room.frame(conn), json!({"v": 1, "t": "guests", "active": [ann, bob]}));
    let mut to: Vec<Value> = (0..2).map(|_| room.next(conn, "snapshot")["to"].clone()).collect();
    to.sort_by_key(Value::to_string);
    let mut both = vec![json!(ann), json!(bob)];
    both.sort_by_key(Value::to_string);
    assert_eq!(to, both);
    while fake.next_frame(Duration::from_millis(300)).is_some() {}
    // A kick ends Ann's relay at the daemon: her prompts reach nothing.
    let kick = json!({"cmd":"agent-session-share-kick", "share_id":share["share_id"],
        "guest_id":ann});
    assert_eq!(owner.request(kick)["ok"], true);
    assert_eq!(room.next(conn, "kick")["guest_id"], json!(ann));
    room.send(json!({"v": 1, "t": "guest_prompt", "guest_id": ann, "client_id": "c1",
        "text": "hello"}));
    fake.no_frame();
    // Bob's still does.
    room.send(json!({"v": 1, "t": "guest_prompt", "guest_id": bob, "client_id": "c1",
        "text": "hello"}));
    assert_eq!(fake.frame()["method"], "session/prompt");
    assert_eq!(room.next(conn, "prompt_state")["guest_id"], json!(bob));
}

/// A prompt the room sends right after `guest_joined` (before the relay's attachment answers)
/// still reaches the daemon; after a host reconnect, the relay counts the guest's sockets from
/// `hello`, so one of two leaving keeps it.
#[test]
fn an_early_prompt_waits_for_the_attachment_and_a_hello_guest_outlives_one_left_socket() {
    let room = FakeRoom::start(&[]);
    let (fake, _mux, surface, mut owner) = bridged("relay-early", &room);
    let (_share, [ann, _bob], conn) = two_guests(&room, &mut owner, surface);
    room.send(json!({"v": 1, "t": "guest_joined", "guest_id": ann}));
    room.send(json!({"v": 1, "t": "guest_prompt", "guest_id": ann, "client_id": "early",
        "text": "hello"}));
    assert_eq!(room.next(conn, "snapshot")["to"], json!(ann));
    let deadline = Instant::now() + WAIT;
    loop {
        let frame = fake.next_frame(deadline.saturating_duration_since(Instant::now()));
        let frame = frame.expect("the early prompt reaches the daemon");
        if frame["method"] == "session/prompt" {
            break;
        }
    }
    assert_eq!(room.next(conn, "prompt_state")["client_id"], "early");
    // A host reconnect names Ann with her two open sockets: one leaving keeps her relay.
    room.shared.hello.lock().unwrap().push(json!({"guest_id": ann, "name": "Ann", "sockets": 2}));
    room.drop_host();
    let (conn, _) = room.host();
    assert_eq!(room.next(conn, "guests")["t"], "guests");
    assert_eq!(room.next(conn, "snapshot")["to"], json!(ann));
    while fake.next_frame(Duration::from_millis(300)).is_some() {}
    room.send(json!({"v": 1, "t": "guest_left", "guest_id": ann}));
    room.send(json!({"v": 1, "t": "guest_prompt", "guest_id": ann, "client_id": "after",
        "text": "still here"}));
    assert_eq!(fake.frame()["method"], "session/prompt");
}

/// A guest frame of another protocol version (or none) starts no relay and sends no prompt.
#[test]
fn a_guest_frame_of_another_version_is_ignored() {
    let room = FakeRoom::start(&[]);
    let (fake, _mux, surface, mut owner) = bridged("relay-version", &room);
    let (_share, [ann, _bob], conn) = two_guests(&room, &mut owner, surface);
    room.send(json!({"v": 2, "t": "guest_joined", "guest_id": ann}));
    room.send(json!({"t": "guest_joined", "guest_id": ann}));
    room.none(
        "a snapshot for a guest_joined that is not v1",
        |s| matches!(s, Seen::Frame { frame, .. } if frame["t"] == "snapshot"),
    );
    room.send(json!({"v": 1, "t": "guest_joined", "guest_id": ann}));
    assert_eq!(room.next(conn, "snapshot")["to"], json!(ann));
    while fake.next_frame(Duration::from_millis(300)).is_some() {}
    room.send(json!({"v": 2, "t": "guest_prompt", "guest_id": ann, "client_id": "v2",
        "text": "hello"}));
    assert!(
        fake.next_frame(Duration::from_millis(500)).is_none_or(|f| f["method"] != "session/prompt"),
        "a v2 prompt never reaches the daemon"
    );
}

/// A guest relay's connection takes one of the daemon's connection permits like any client's:
/// with none free no relay starts, and the guest's next join gets one once a permit is back.
#[test]
fn a_guest_relay_takes_a_connection_permit() {
    let room = FakeRoom::start(&[]);
    let (_fake, mux, surface, mut owner) = bridged("relay-permit", &room);
    let (_share, [ann, _bob], conn) = two_guests(&room, &mut owner, surface);
    let mut held = Vec::new();
    while let Some(permit) = crate::server::claim_connection(mux.connection_stats()) {
        held.push(permit);
    }
    room.send(json!({"v": 1, "t": "guest_joined", "guest_id": ann}));
    room.none(
        "a snapshot without a free connection permit",
        |s| matches!(s, Seen::Frame { frame, .. } if frame["t"] == "snapshot"),
    );
    // With a permit back, the waiting guest's relay starts on its own (no new join).
    drop(held);
    assert_eq!(room.next(conn, "snapshot")["to"], json!(ann));
}

/// A burst of prompts cannot pass the 16-held cap before their replies come: prompts sent and
/// not answered count too, and the 17th is refused.
#[test]
fn a_burst_of_prompts_stops_at_the_held_cap() {
    let room = FakeRoom::start(&[]);
    let (fake, _mux, surface, mut owner) = bridged("relay-burst", &room);
    let (_share, [ann, _bob], conn) = two_guests(&room, &mut owner, surface);
    room.send(json!({"v": 1, "t": "guest_joined", "guest_id": ann}));
    assert_eq!(room.next(conn, "snapshot")["to"], json!(ann));
    while fake.next_frame(Duration::from_millis(300)).is_some() {}
    for n in 0..16 {
        room.send(json!({"v": 1, "t": "guest_prompt", "guest_id": ann,
            "client_id": format!("c{n}"), "text": "hello"}));
    }
    // Client ids a page names in `prompt_status` do not push the held prompts out of the count.
    let fakes: Vec<String> = (0..80).map(|n| format!("fake{n}")).collect();
    room.send(json!({"v": 1, "t": "prompt_status", "guest_id": ann, "client_ids": fakes}));
    room.send(json!({"v": 1, "t": "guest_prompt", "guest_id": ann, "client_id": "c16",
        "text": "hello"}));
    let deadline = Instant::now() + WAIT;
    let refused = loop {
        let state = room.next(conn, "prompt_state");
        if state["state"] == "refused" {
            break state;
        }
        assert!(Instant::now() < deadline, "the 17th prompt is refused");
    };
    assert_eq!(
        (refused["client_id"].clone(), refused["reason"].clone()),
        (json!("c16"), json!("share.too_many_held"))
    );
}

/// A room whose `hello` gives no socket count: the guest's first `guest_left` ends its relay, so
/// no relay holds a daemon connection past its guest's sockets.
#[test]
fn a_hello_guest_without_a_count_ends_with_its_first_left_socket() {
    let room = FakeRoom::start(&[]);
    let (fake, _mux, surface, mut owner) = bridged("relay-uncounted", &room);
    let (_share, [ann, _bob], _conn) = two_guests(&room, &mut owner, surface);
    room.shared.hello.lock().unwrap().push(json!({"guest_id": ann, "name": "Ann"}));
    room.drop_host();
    let (conn, _) = room.host();
    assert_eq!(room.next(conn, "guests")["t"], "guests");
    assert_eq!(room.next(conn, "snapshot")["to"], json!(ann));
    while fake.next_frame(Duration::from_millis(300)).is_some() {}
    room.send(json!({"v": 1, "t": "guest_left", "guest_id": ann}));
    room.send(json!({"v": 1, "t": "guest_prompt", "guest_id": ann, "client_id": "gone",
        "text": "nobody relays this"}));
    fake.no_frame();
}

/// Ann's prompts `c{from}..c{to}`, each sent and said held: their acpmux prompt ids.
fn held_prompts(
    room: &FakeRoom,
    fake: &FakeAcpmux,
    conn: u64,
    ann: &str,
    n: std::ops::Range<u32>,
) -> Vec<String> {
    let mut prompts = Vec::new();
    for n in n {
        let client_id = format!("c{n}");
        room.send(json!({"v": 1, "t": "guest_prompt", "guest_id": ann, "client_id": client_id,
            "text": "hello"}));
        let sent = loop {
            let frame = fake.frame();
            if frame["method"] == "session/prompt" {
                break frame;
            }
        };
        prompts.push(sent["params"]["_meta"]["acpmux"]["promptId"].as_str().unwrap().to_owned());
        let state = room.next(conn, "prompt_state");
        let said = (state["client_id"].clone(), state["state"].clone());
        assert_eq!(said, (json!(client_id), json!("held")));
    }
    prompts
}

/// The state the room is next told of Ann's prompt `client_id` (states of others skipped).
fn state_of(room: &FakeRoom, conn: u64, client_id: &str) -> Value {
    let deadline = Instant::now() + WAIT;
    loop {
        let state = room.next(conn, "prompt_state");
        if state["client_id"] == client_id {
            return state;
        }
        assert!(Instant::now() < deadline, "a state of {client_id}");
    }
}

/// acpmux's record that the owner approved `prompt`.
fn approved(seq: u64, prompt: &str) -> Value {
    json!({"sessionId": SESSION, "seq": seq, "dir": "mux", "kind": "queue_approved",
        "msg": {"promptId": prompt, "revision": 0}})
}

/// A host reconnect keeps the count of the guest's held prompts: 16 held before it, the 17th
/// after it is refused.
#[test]
fn a_host_reconnect_keeps_the_held_cap() {
    let room = FakeRoom::start(&[]);
    let (fake, _mux, surface, mut owner) = bridged("relay-cap-host", &room);
    let (_share, [ann, _bob], conn) = two_guests(&room, &mut owner, surface);
    room.send(json!({"v": 1, "t": "guest_joined", "guest_id": ann}));
    assert_eq!(room.next(conn, "snapshot")["to"], json!(ann));
    while fake.next_frame(Duration::from_millis(300)).is_some() {}
    held_prompts(&room, &fake, conn, &ann, 0..16);
    room.shared.hello.lock().unwrap().push(json!({"guest_id": ann, "name": "Ann", "sockets": 1}));
    room.drop_host();
    let (conn, _) = room.host();
    assert_eq!(room.next(conn, "guests")["t"], "guests");
    assert_eq!(room.next(conn, "snapshot")["to"], json!(ann));
    room.send(json!({"v": 1, "t": "guest_prompt", "guest_id": ann, "client_id": "c16",
        "text": "hello"}));
    let state = state_of(&room, conn, "c16");
    assert_eq!(
        (state["state"].clone(), state["reason"].clone()),
        (json!("refused"), json!("share.too_many_held"))
    );
}

/// A retried prompt the owner already decided is not counted again: 16 decided and retried
/// leave room for a new one.
#[test]
fn retrying_decided_prompts_takes_no_held_slot() {
    let room = FakeRoom::start(&[]);
    let (mut fake, _mux, surface, mut owner) = bridged("relay-cap-retry", &room);
    let (_share, [ann, _bob], conn) = two_guests(&room, &mut owner, surface);
    room.send(json!({"v": 1, "t": "guest_joined", "guest_id": ann}));
    assert_eq!(room.next(conn, "snapshot")["to"], json!(ann));
    while fake.next_frame(Duration::from_millis(300)).is_some() {}
    let prompts = held_prompts(&room, &fake, conn, &ann, 0..16);
    for (n, prompt) in prompts.iter().enumerate() {
        fake.notify("_acpmux/event", approved(40 + n as u64, prompt));
        assert_eq!(state_of(&room, conn, &format!("c{n}"))["state"], "approved");
    }
    // Each retried (its page lost the reply): acpmux's ledger runs none of them again. One at a
    // time: the attachment takes 8 calls at once (`agent_session.limit`).
    for n in 0..16 {
        room.send(json!({"v": 1, "t": "guest_prompt", "guest_id": ann,
            "client_id": format!("c{n}"), "text": "hello"}));
        while fake.frame()["method"] != "session/prompt" {}
    }
    // A new prompt sent while a retry's answer is still out may be refused for that too, never
    // for the held cap.
    let deadline = Instant::now() + WAIT;
    let state = loop {
        room.send(json!({"v": 1, "t": "guest_prompt", "guest_id": ann, "client_id": "c16",
            "text": "hello"}));
        let state = state_of(&room, conn, "c16");
        if state["reason"] != "agent_session.limit" || Instant::now() > deadline {
            break state;
        }
        std::thread::sleep(Duration::from_millis(50));
    };
    assert_eq!(state["state"], "held", "{state}");
}

/// Decisions a history page names release the held slots of prompts decided while the guest was
/// away (their records older than its reconnect's snapshot), and the guest is told of them.
#[test]
fn a_history_page_applies_the_decisions_it_names() {
    let room = FakeRoom::start(&[]);
    let fixture = Fixture::default();
    let later = fixture.history_later.clone();
    let (fake, _mux, surface, mut owner) = bridged_with("relay-cap-page", &room, fixture);
    let (_share, [ann, _bob], conn) = two_guests(&room, &mut owner, surface);
    room.send(json!({"v": 1, "t": "guest_joined", "guest_id": ann}));
    assert_eq!(room.next(conn, "snapshot")["to"], json!(ann));
    while fake.next_frame(Duration::from_millis(300)).is_some() {}
    let prompts = held_prompts(&room, &fake, conn, &ann, 0..16);
    // Ann leaves; the owner decides all 16; Ann comes back to a snapshot that names none of it.
    room.send(json!({"v": 1, "t": "guest_left", "guest_id": ann}));
    let decided = prompts.iter().enumerate().map(|(n, p)| approved(40 + n as u64, p));
    later.lock().unwrap().extend(decided);
    room.send(json!({"v": 1, "t": "guest_joined", "guest_id": ann}));
    assert_eq!(room.next(conn, "snapshot")["to"], json!(ann));
    room.send(json!({"v": 1, "t": "older", "guest_id": ann, "before_seq": 3}));
    assert_eq!(room.next(conn, "page")["to"], json!(ann));
    assert_eq!(state_of(&room, conn, "c0")["state"], "approved");
    room.send(json!({"v": 1, "t": "guest_prompt", "guest_id": ann, "client_id": "c16",
        "text": "hello"}));
    assert_eq!(state_of(&room, conn, "c16")["state"], "held");
}

/// A retry the daemon takes after an earlier send of the prompt was refused is said held.
#[test]
fn a_retry_taken_after_a_refusal_is_held() {
    let room = FakeRoom::start(&[]);
    let (mut fake, _mux, surface, mut owner) = bridged("relay-retry-held", &room);
    let (_share, [ann, _bob], conn) = two_guests(&room, &mut owner, surface);
    room.send(json!({"v": 1, "t": "guest_joined", "guest_id": ann}));
    assert_eq!(room.next(conn, "snapshot")["to"], json!(ann));
    while fake.next_frame(Duration::from_millis(300)).is_some() {}
    let prompts = held_prompts(&room, &fake, conn, &ann, 0..16);
    room.send(json!({"v": 1, "t": "guest_prompt", "guest_id": ann, "client_id": "c16",
        "text": "hello"}));
    assert_eq!(state_of(&room, conn, "c16")["reason"], "share.too_many_held");
    fake.notify("_acpmux/event", approved(40, &prompts[0]));
    assert_eq!(state_of(&room, conn, "c0")["state"], "approved");
    room.send(json!({"v": 1, "t": "guest_prompt", "guest_id": ann, "client_id": "c16",
        "text": "hello"}));
    let state = state_of(&room, conn, "c16");
    assert_eq!(state["state"], "held", "{state}");
}

/// A retry of a decided prompt that the daemon refuses (another send of it still in flight)
/// leaves the owner's decision standing.
#[test]
fn a_refused_retry_never_undoes_a_decision() {
    let room = FakeRoom::start(&[]);
    let (gate, gated) = channel();
    let fixture = Fixture { prompt_gate: Some(Arc::new(Mutex::new(gated))), ..Fixture::default() };
    let (mut fake, _mux, surface, mut owner) = bridged_with("relay-retry-final", &room, fixture);
    let (_share, [ann, _bob], conn) = two_guests(&room, &mut owner, surface);
    room.send(json!({"v": 1, "t": "guest_joined", "guest_id": ann}));
    assert_eq!(room.next(conn, "snapshot")["to"], json!(ann));
    while fake.next_frame(Duration::from_millis(300)).is_some() {}
    gate.send(()).unwrap();
    let prompts = held_prompts(&room, &fake, conn, &ann, 0..1);
    fake.notify("_acpmux/event", approved(40, &prompts[0]));
    assert_eq!(state_of(&room, conn, "c0")["state"], "approved");
    // The first retry waits at acpmux; the second is refused while it is out.
    for _ in 0..2 {
        room.send(json!({"v": 1, "t": "guest_prompt", "guest_id": ann, "client_id": "c0",
            "text": "hello"}));
    }
    std::thread::sleep(Duration::from_millis(500));
    drop(gate);
    room.send(json!({"v": 1, "t": "prompt_status", "guest_id": ann, "client_ids": ["c0"]}));
    let state = state_of(&room, conn, "c0");
    assert_eq!(state["state"], "approved", "{state}");
}

/// A guest's reconnect while its relay's attachment is still answering keeps the prompts that
/// relay held: the new relay sends them.
#[test]
fn a_guest_reconnect_keeps_the_prompts_its_old_relay_held() {
    let room = FakeRoom::start(&[]);
    let (gate, gated) = channel();
    let fixture = Fixture { attach_gate: Some(Arc::new(Mutex::new(gated))), ..Fixture::default() };
    let (fake, _mux, surface, mut owner) = bridged_with("relay-rejoin", &room, fixture);
    let (_share, [ann, _bob], conn) = two_guests(&room, &mut owner, surface);
    room.send(json!({"v": 1, "t": "guest_joined", "guest_id": ann}));
    room.send(json!({"v": 1, "t": "guest_prompt", "guest_id": ann, "client_id": "early",
        "text": "hello"}));
    std::thread::sleep(Duration::from_millis(300));
    room.send(json!({"v": 1, "t": "guest_joined", "guest_id": ann}));
    std::thread::sleep(Duration::from_millis(300));
    gate.send(()).unwrap();
    gate.send(()).unwrap();
    let deadline = Instant::now() + WAIT;
    loop {
        let frame = fake.next_frame(deadline.saturating_duration_since(Instant::now()));
        let frame = frame.expect("the early prompt reaches acpmux");
        if frame["method"] == "session/prompt" {
            break;
        }
    }
    let state = state_of(&room, conn, "early");
    assert_eq!(state["state"], "held", "{state}");
}

/// A host reconnect's snapshot names the guest's prompts from before it, though the new attach
/// page has none of their records.
#[test]
fn a_host_reconnect_snapshot_names_the_guests_prompts() {
    let room = FakeRoom::start(&[]);
    let (fake, _mux, surface, mut owner) = bridged("relay-host-states", &room);
    let (_share, [ann, _bob], conn) = two_guests(&room, &mut owner, surface);
    room.send(json!({"v": 1, "t": "guest_joined", "guest_id": ann}));
    assert_eq!(room.next(conn, "snapshot")["to"], json!(ann));
    while fake.next_frame(Duration::from_millis(300)).is_some() {}
    let prompts = held_prompts(&room, &fake, conn, &ann, 0..1);
    room.shared.hello.lock().unwrap().push(json!({"guest_id": ann, "name": "Ann", "sockets": 1}));
    room.drop_host();
    let (conn, _) = room.host();
    assert_eq!(room.next(conn, "guests")["t"], "guests");
    let snapshot = room.next(conn, "snapshot");
    assert_eq!(
        snapshot["prompts"],
        json!([{"client_id": "c0", "prompt_id": prompts[0], "state": "held"}]),
        "{snapshot}"
    );
}

/// History asks past what the relay keeps in flight, while acpmux is slow to answer, are each
/// answered at once with an empty page that has more.
#[test]
fn history_asks_past_the_in_flight_cap_get_a_busy_page() {
    let room = FakeRoom::start(&[]);
    let (gate, gated) = channel::<()>();
    let fixture = Fixture { events_gate: Some(Arc::new(Mutex::new(gated))), ..Fixture::default() };
    let (fake, _mux, surface, mut owner) = bridged_with("relay-older-flood", &room, fixture);
    let (_share, [ann, _bob], conn) = two_guests(&room, &mut owner, surface);
    room.send(json!({"v": 1, "t": "guest_joined", "guest_id": ann}));
    assert_eq!(room.next(conn, "snapshot")["to"], json!(ann));
    while fake.next_frame(Duration::from_millis(300)).is_some() {}
    for _ in 0..20 {
        room.send(json!({"v": 1, "t": "older", "guest_id": ann, "before_seq": 3}));
    }
    let started = Instant::now();
    for _ in 0..16 {
        let page = room.next(conn, "page");
        assert_eq!((page["records"].clone(), page["has_more"].clone()), (json!([]), json!(true)));
    }
    assert!(started.elapsed() < Duration::from_secs(4), "answered without waiting on acpmux");
    drop(gate);
}

/// A prompt the daemon has not answered when the host socket drops is sent again by the guest's
/// relay on the new host socket, and its state reaches the guest there.
#[test]
fn a_prompt_in_flight_across_a_host_reconnect_is_sent_again() {
    let room = FakeRoom::start(&[]);
    let (gate, gated) = channel();
    let fixture = Fixture { prompt_gate: Some(Arc::new(Mutex::new(gated))), ..Fixture::default() };
    let (fake, _mux, surface, mut owner) = bridged_with("relay-host-inflight", &room, fixture);
    let (_share, [ann, _bob], conn) = two_guests(&room, &mut owner, surface);
    room.send(json!({"v": 1, "t": "guest_joined", "guest_id": ann}));
    assert_eq!(room.next(conn, "snapshot")["to"], json!(ann));
    while fake.next_frame(Duration::from_millis(300)).is_some() {}
    room.send(json!({"v": 1, "t": "guest_prompt", "guest_id": ann, "client_id": "c0",
        "text": "hello"}));
    while fake.frame()["method"] != "session/prompt" {}
    // acpmux has not accepted it when the host socket drops.
    room.shared.hello.lock().unwrap().push(json!({"guest_id": ann, "name": "Ann", "sockets": 1}));
    room.drop_host();
    let (conn, _) = room.host();
    assert_eq!(room.next(conn, "guests")["t"], "guests");
    assert_eq!(room.next(conn, "snapshot")["to"], json!(ann));
    // The first send's acceptance goes to the gone relay; the second is the new relay's.
    gate.send(()).unwrap();
    while fake.frame()["method"] != "session/prompt" {}
    gate.send(()).unwrap();
    let state = state_of(&room, conn, "c0");
    assert_eq!(state["state"], "held", "{state}");
}
