//! The link share bridge against a fake room (cmux-platform's `ChatShareRoom` HTTP API):
//! provisioning, its retry and give-up, a refusal, and revoke's `DELETE`.
use super::super::{digest, hex};
use super::*;
use crate::server::agent_session_attach_tests::{
    Client, FakeAcpmux, SESSION, WAIT, agent_tab, assert_code, mux_with,
};
use std::cell::RefCell;
use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::time::Instant;

const OWNER_TOKEN: &str = "owner-access-token";

/// What the fake room saw, in order.
#[derive(Debug)]
enum Seen {
    Request { method: String, path: String, bearer: String, body: Value },
}

#[derive(Default)]
struct Shared {
    /// Statuses the next `PUT`s answer; then 200 with a new host token.
    puts: Mutex<VecDeque<u16>>,
    host_tokens: AtomicU64,
}

struct FakeRoom {
    url: String,
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
        let (server, base) = (shared, url.clone());
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(stream) = stream else { return };
                let (shared, sender, base) = (server.clone(), sender.clone(), base.clone());
                std::thread::spawn(move || serve(stream, &shared, &sender, &base));
            }
        });
        Self { url, seen, buffer: RefCell::default() }
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

    /// The next `method` request: its path, bearer and body.
    fn request(&self, method: &str) -> (String, String, Value) {
        let wanted = |s: &Seen| matches!(s, Seen::Request { method: m, .. } if m == method);
        match self.take(method, wanted) {
            Seen::Request { path, bearer, body, .. } => (path, bearer, body),
        }
    }
}

fn serve(stream: TcpStream, shared: &Shared, seen: &Sender<Seen>, base: &str) {
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
    let (status, reply) = match method.as_str() {
        "PUT" => match shared.puts.lock().unwrap().pop_front() {
            Some(status) => (status, json!({})),
            None => {
                let n = shared.host_tokens.fetch_add(1, Ordering::SeqCst) + 1;
                let id = path.rsplit('/').next().unwrap_or_default();
                (
                    200,
                    json!({"host_token": format!("host-token-{n}"), "url_base": format!("{base}/g/{id}")}),
                )
            }
        },
        _ => (200, json!({"state": "revoked"})),
    };
    let _ = seen.send(Seen::Request { method, path, bearer, body });
    let reply = reply.to_string();
    let mut stream = stream;
    let _ = write!(
        stream,
        "HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{reply}",
        reply.len()
    );
}

fn fast() -> Timing {
    Timing {
        request: Duration::from_secs(2),
        window: Duration::from_millis(400),
        backoff_min: Duration::from_millis(20),
        backoff_max: Duration::from_millis(100),
    }
}

/// A daemon with one agent chat, bridged to `room`.
fn bridged(label: &str, room: &FakeRoom) -> (FakeAcpmux, Arc<Mux>, u64, Client) {
    let fake = FakeAcpmux::start(label);
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
    room.none("a DELETE", |s| matches!(s, Seen::Request { method, .. } if method == "DELETE"));
}
