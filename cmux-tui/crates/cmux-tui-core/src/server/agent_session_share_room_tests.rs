//! The link share bridge against a fake room (cmux-platform's `ChatShareRoom` HTTP API):
//! provisioning, its retry and give-up, a refusal, and revoke's `DELETE`.
use super::super::{digest, hex, MAX_SHARES};
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
use std::sync::Condvar;
use std::time::Instant;

const OWNER_TOKEN: &str = "owner-access-token";
type DeleteGate = Arc<(Mutex<bool>, Condvar)>;

/// What the fake room saw, in order.
#[derive(Debug)]
enum Seen {
    Request { method: String, path: String, bearer: String, body: Value },
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

    /// The next `method` request: its path, bearer and body.
    fn request(&self, method: &str) -> (String, String, Value) {
        let wanted = |s: &Seen| matches!(s, Seen::Request { method: m, .. } if m == method);
        match self.take(method, wanted) {
            Seen::Request { path, bearer, body, .. } => (path, bearer, body),
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
    let is_delete = method == "DELETE";
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
                (
                    200,
                    json!({"host_token": format!("host-token-{n}"), "url_base": url_base}),
                )
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
                (
                    200,
                    json!({"host_token": format!("host-token-{n}"), "url_base": url_base}),
                )
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
    assert_eq!(owner.request(json!({"cmd":"agent-session-share-revoke",
        "share_id":share["share_id"]}))[
        "ok"], true);
    room.request("DELETE");

    let shares = shares_of(&mux);
    shares.advance(Duration::from_secs(2 * 86_400));
    shares.refuse_writes.store(true, Ordering::Relaxed);
    shares.expired(&mux);
    assert!(view(&mux, share["share_id"].as_str().unwrap()).unwrap().delete,
        "a failed expiry save keeps the DELETE pending");

    shares.refuse_writes.store(false, Ordering::Relaxed);
    room.none("duplicate DELETE while the one worker retries persistence",
        |s| matches!(s, Seen::Request { method, .. } if method == "DELETE"));
    assert!(!view(&mux, share["share_id"].as_str().unwrap()).unwrap().delete,
        "the same worker eventually settles the durable operation");
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
                room: None,
                pending_room_ops: vec![json!({"op": "delete"})],
                guests: Vec::new(),
            }));
            Ok(((), true))
        })
        .unwrap();
    let initial_pending = shares
        .with(Some(&directory), |all, _| {
            Ok((
                all.iter()
                    .filter(|share| !share.pending_room_ops.is_empty())
                    .count(),
                false,
            ))
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
    let pending = shares
        .with(Some(&directory), |all, _| {
            Ok((
                all.iter()
                    .filter(|share| !share.pending_room_ops.is_empty())
                    .count(),
                false,
            ))
        })
        .unwrap();
    assert_eq!(pending, 0, "credentialless pending room deletes settle at expiry");
    assert!(shares.insert(Some(&directory), SESSION.into(), 1, 3600, 1, false).is_ok());
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
    let created = shares.insert(None, SESSION.into(), surface, 60, 1, true).unwrap();
    let id = created["share_id"].as_str().unwrap().to_owned();
    shares.refuse_writes.store(true, Ordering::Relaxed);
    let mut configured = shares.bridge.room().unwrap();
    configured.timing.window = Duration::ZERO;
    // Drive the retry-window exhaustion itself: its attempt to persist the revoke fails.
    shares.bridge.runtime().unwrap().block_on(retry(
        Arc::downgrade(&mux), id.clone(), configured,
        Zeroizing::new(OWNER_TOKEN.to_owned()), json!({}),
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
    let mux = Mux::open_persistent("revoke-restart", crate::SurfaceOptions::default(), &root)
        .unwrap();
    let directory = mux.session_state_directory().unwrap();
    let shares = shares_of(&mux);
    shares.serve(&mux);
    let created = shares.insert(Some(&directory), SESSION.into(), 1, 60, 1, true).unwrap();
    let id = created["share_id"].as_str().unwrap().to_owned();
    shares.end(Some(&directory), &super::super::Named {
        share_id: id.clone(), guest_id: None,
    }).unwrap();
    assert!(view(&mux, &id).unwrap().delete, "revoke persists intent before a PUT answers");
    mux.shutdown();
    drop(mux);

    let mux = Mux::open_persistent("revoke-restart", crate::SurfaceOptions::default(), &root)
        .unwrap();
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
fn startup_resumes_pending_deletes_when_revoking_provisioning_shares_cannot_be_saved() {
    let room = FakeRoom::start(&[]);
    let root = std::env::temp_dir()
        .join(format!("cmux-room-start-unsaved-{}", crate::workspace_registry::new_uuid_v4()));
    let options = crate::SurfaceOptions::default();
    let mux = Mux::open_persistent("start-unsaved", options.clone(), &root).unwrap();
    let directory = mux.session_state_directory().unwrap();
    let shares = shares_of(&mux);
    let expires_at = shares.now().saturating_add(3_600_000);
    let record = |id: &str, state, token: &str, ops: Vec<Value>| LinkShare {
        share_id: id.into(),
        session: SESSION.into(),
        surface: 1,
        created_at: expires_at.saturating_sub(3_600_000),
        expires_at,
        uses_left: 1,
        state,
        secret_sha256: String::new(),
        provision_key: None,
        room: Some(json!({"url": room.url, "host_token": token})),
        pending_room_ops: ops,
        guests: Vec::new(),
    };
    shares
        .with(Some(&directory), |all, _| {
            all.push(record("pending", ShareState::Revoked, "pending-host", vec![
                json!({"op": "delete"}),
            ]));
            all.push(record("provisioning", ShareState::Provisioning, "provisioning-host", vec![]));
            Ok(((), true))
        })
        .unwrap();
    mux.shutdown();
    drop(mux);

    let mux = Mux::open_persistent("start-unsaved", options, &root).unwrap();
    let shares = shares_of(&mux);
    // The startup write that revokes the provisioning share fails; the share already queued for
    // deletion still has its durable host token and must be cleaned up.
    shares.refuse_writes.store(true, Ordering::Relaxed);
    start_link_share_bridge(&mux, Some(&room.url));
    let mut bearers = vec![room.request("DELETE").1, room.request("DELETE").1];
    bearers.sort();
    assert_eq!(bearers, ["pending-host", "provisioning-host"]);
    shares.refuse_writes.store(false, Ordering::Relaxed);
    mux.shutdown();
    drop(mux);
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn a_late_host_token_reaches_the_delete_worker_already_in_flight() {
    let room = FakeRoom::start(&[]);
    room.shared.deletes.lock().unwrap().push_back(503);
    let gate = room.block_deletes();
    let (_fake, mux, surface, _owner) = bridged("room-late-handoff", &room);
    let shares = shares_of(&mux);
    let created = shares.insert(None, SESSION.into(), surface, 60, 1, true).unwrap();
    let id = created["share_id"].as_str().unwrap().to_owned();
    shares.end(None, &super::super::Named { share_id: id.clone(), guest_id: None }).unwrap();
    // A worker with only the owner's token is waiting on the room.
    let entered = room.watch_delete();
    delete(&mux, &id, Some(Held::Owner(Zeroizing::new(OWNER_TOKEN.to_owned()))));
    entered.recv_timeout(WAIT).expect("the owner's DELETE enters the room");
    // The in-flight PUT answers while writes fail: its host token cannot reach the record.
    shares.refuse_writes.store(true, Ordering::Relaxed);
    delete(&mux, &id, Some(Held::Host(room.url.clone(), Zeroizing::new("late-host".into()))));
    let (released, wake) = &*gate;
    *released.lock().unwrap() = true;
    wake.notify_all();
    let (_, first, _) = room.request("DELETE");
    assert_eq!(first, OWNER_TOKEN);
    let (_, second, _) = room.request("DELETE");
    assert_eq!(second, "late-host", "the owning worker retries with the handed host token");
    shares.refuse_writes.store(false, Ordering::Relaxed);
}

#[test]
fn a_revoked_inflight_provision_is_not_evicted_before_its_late_host_token() {
    let room = FakeRoom::start(&[]);
    let (_fake, mux, surface, _owner) = bridged("room-late-capacity", &room);
    let shares = shares_of(&mux);
    let created = shares.insert(None, SESSION.into(), surface, 60, 1, true).unwrap();
    let id = created["share_id"].as_str().unwrap().to_owned();
    shares.end(None, &super::super::Named { share_id: id.clone(), guest_id: None }).unwrap();
    for _ in 1..MAX_SHARES {
        shares.insert(None, SESSION.into(), surface, 60, 1, false).unwrap();
    }
    assert_eq!(shares.insert(None, SESSION.into(), surface, 60, 1, false), Err("share.limit"));
    delete(&mux, &id, Some(Held::Host(room.url.clone(), Zeroizing::new("late-host".into()))));
    let (path, bearer, _) = room.request("DELETE");
    assert_eq!(path, format!("/v1/chat-shares/{id}"));
    assert_eq!(bearer, "late-host");
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
                let _ = write!(stream,
                    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n");
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
                let _ = write!(stream,
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(), body);
            }
        });
        let bridge = Bridge::default();
        let response = bridge.runtime().unwrap().block_on(call(
            reqwest::Method::DELETE, &url, "host-token", None, Duration::from_secs(2),
        ));
        server.join().unwrap();
        assert!(response.is_none(), "oversized response accepted (chunked={chunked})");
    }
}
