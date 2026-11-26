//! The routed `forum` namespace over the connection message handler, against a scripted hosted
//! forum: the snapshot in the page's shape, a thread with its comments, a post and a reply, the
//! not-set-up gate, refusals, and who may call.

use std::collections::VecDeque;
use std::sync::Mutex;
use std::time::Instant;

use serde_json::{Value, json};

use super::{AnyTransport, ForumOwner};
use crate::server::origin_gate::{
    set_peer_key_for_test, set_role_for_test, set_verified_app_for_test,
};
use crate::server::*;
use cmux_forum_hosted::{Method, Request, Response, Transport, TransportError};

#[derive(Clone, Default)]
struct Fake {
    replies: Arc<Mutex<VecDeque<(String, Response)>>>,
    sent: Arc<Mutex<Vec<Request>>>,
}

impl Fake {
    /// Answers the next request whose path starts with `prefix` with `body`.
    fn on(&self, prefix: &str, status: u16, body: Value) {
        let response = Response {
            status,
            headers: vec![("content-type".into(), "application/json".into())],
            body: serde_json::to_vec(&body).unwrap(),
        };
        self.replies.lock().unwrap().push_back((prefix.to_owned(), response));
    }

    fn sent(&self) -> Vec<Request> {
        self.sent.lock().unwrap().clone()
    }
}

impl Transport for Fake {
    async fn send(&self, request: Request) -> Result<Response, TransportError> {
        self.sent.lock().unwrap().push(request.clone());
        let mut replies = self.replies.lock().unwrap();
        let at = replies.iter().position(|(prefix, _)| request.path_and_query.starts_with(prefix));
        match at.and_then(|at| replies.remove(at)) {
            Some((_, response)) => Ok(response),
            None => Err(TransportError::new(format!("unscripted {}", request.path_and_query))),
        }
    }
}

struct Conn {
    client: u64,
    writer: MessageWriter,
    outbound: Arc<BoundedOutbound>,
    scheduler: Arc<ConnectionSurfaceScheduler>,
}

fn connect(mux: &Arc<Mux>, role: &str, verified: bool) -> Conn {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    set_role_for_test(mux, client, role);
    set_peer_key_for_test(mux, client, "token:30.1");
    set_verified_app_for_test(mux, client, verified);
    Conn { client, writer, outbound, scheduler }
}

/// Sends one routed request and waits for its reply (a forum op answers from its own thread).
fn send(mux: &Arc<Mux>, conn: &Conn, operation: &str, params: Value, key: Option<&str>) -> Value {
    let mut request = json!({
        "protocol": "cmux.protocol/2", "type": "request", "id": "r1",
        "operation": operation, "params": params,
    });
    if let Some(key) = key {
        request["idempotency_key"] = json!(key);
    }
    assert!(handle_connection_message(
        mux,
        conn.client,
        &request.to_string(),
        &conn.writer,
        &conn.scheduler
    ));
    let deadline = Instant::now() + std::time::Duration::from_secs(10);
    loop {
        if let Some(reply) = conn.outbound.try_pop() {
            return serde_json::from_str(&reply).unwrap();
        }
        assert!(Instant::now() < deadline, "no reply to {operation}");
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
}

fn ok(reply: Value) -> Value {
    assert_eq!(reply["ok"], true, "{reply}");
    reply["result"].clone()
}

const KEY: &str = "cfk_test_secret_value";

fn app(fake: Option<&Fake>) -> (Arc<Mux>, Conn) {
    let mux = Mux::new_for_test("forum-routed", crate::SurfaceOptions::default());
    let owner = match fake {
        Some(fake) => ForumOwner::new(AnyTransport::new(fake.clone()), "team-a", KEY),
        None => ForumOwner::not_set_up(),
    };
    assert!(mux.install_forum_owner(owner));
    let conn = connect(&mux, "main", true);
    (mux, conn)
}

/// The agent key's exchange, the first request of every fresh client.
fn token(fake: &Fake) {
    fake.on("/v1/forum/token", 200, json!({"token": "bearer-1", "expires_in": 3600}));
}

fn hosted_thread(number: u64, labels: &[&str], state: &str) -> Value {
    json!({
        "number": number, "title": format!("Thread {number}"), "body": "Body",
        "state": state, "labels": labels.iter().map(|l| json!({"name": l})).collect::<Vec<_>>(),
        "author": {"kind": "agent", "id": "ag_1", "name": "builder", "on_behalf_of": "Ada",
                   "session": "s-1", "host": "mac-1"},
        "space": "fleet", "comments": 2,
        "created_at": "2026-11-22T09:00:00Z", "updated_at": "2026-11-22T09:30:00.500Z",
        "html_url": format!("https://forum.example/t/{number}"),
    })
}

#[test]
fn snapshot_reads_spaces_and_threads_in_the_page_shape() {
    let fake = Fake::default();
    token(&fake);
    fake.on(
        "/v1/forum/spaces",
        200,
        json!([{"name": "fleet", "visibility": "private", "threads": 2},
               {"name": "open", "visibility": "public", "threads": 0}]),
    );
    fake.on(
        "/v1/forum/threads",
        200,
        json!([hosted_thread(41, &["finding", "build"], "open"), hosted_thread(40, &[], "closed")]),
    );
    let (mux, conn) = app(Some(&fake));
    let snapshot = ok(send(&mux, &conn, "forum.snapshot", json!({"space": "fleet"}), None));
    assert_eq!(snapshot["status"], "ready");
    assert_eq!(snapshot["team"], "team-a");
    assert_eq!(
        snapshot["spaces"][1],
        json!({"name": "open", "visibility": "public", "threads": 0})
    );
    let first = &snapshot["threads"][0];
    assert_eq!(first["kind"], "finding");
    assert_eq!(first["labels"], json!(["build"]));
    assert_eq!(first["state"], "open");
    assert_eq!(first["created_at"], 1_795_338_000_000i64);
    assert_eq!(first["updated_at"], 1_795_339_800_500i64);
    assert_eq!(first["author"]["kind"], "agent");
    assert_eq!(first["author"]["on_behalf_of"], "Ada");
    assert_eq!(snapshot["threads"][1]["kind"], "question");
    assert_eq!(snapshot["threads"][1]["state"], "closed");
    let list = fake.sent().into_iter().find(|r| r.path_and_query.starts_with("/v1/forum/threads"));
    let list = list.expect("a thread list request").path_and_query;
    assert!(list.contains("space=fleet") && list.contains("state=all"), "{list}");
    assert!(!snapshot.to_string().contains(KEY));
}

#[test]
fn thread_get_reads_the_thread_and_its_comments() {
    let fake = Fake::default();
    token(&fake);
    fake.on("/v1/forum/threads/41/comments", 200, json!([
        {"id": 7, "body": "Seen it too", "author": {"kind": "person", "id": "u_ada", "name": "Ada"},
         "thread": 41, "created_at": "2026-11-22T09:10:00Z"}
    ]));
    fake.on("/v1/forum/threads/41", 200, hosted_thread(41, &["question"], "open"));
    let (mux, conn) = app(Some(&fake));
    let read = ok(send(&mux, &conn, "forum.thread.get", json!({"number": 41}), None));
    assert_eq!(read["thread"]["number"], 41);
    assert_eq!(read["comments"][0]["id"], 7);
    assert_eq!(read["comments"][0]["author"]["name"], "Ada");
    assert_eq!(read["comments"][0]["thread"], 41);
}

#[test]
fn post_and_reply_go_to_the_hosted_forum() {
    let fake = Fake::default();
    token(&fake);
    fake.on("/v1/forum/threads/41/comments", 201, json!({"id": 9, "body": "Fixed", "thread": 41}));
    fake.on("/v1/forum/threads/41", 200, hosted_thread(41, &[], "open"));
    fake.on("/v1/forum/threads", 201, hosted_thread(42, &["finding"], "open"));
    let (mux, conn) = app(Some(&fake));
    // The verified app connection acts with origin user; a mutation needs its idempotency key.
    let posted = ok(send(
        &mux,
        &conn,
        "forum.thread.post",
        json!({"space": "fleet", "title": "T", "body": "B", "kind": "finding"}),
        Some("k1"),
    ));
    assert_eq!(posted["thread"]["number"], 42);
    let replied = ok(send(
        &mux,
        &conn,
        "forum.thread.reply",
        json!({"number": 41, "body": "Fixed"}),
        Some("k2"),
    ));
    assert_eq!(replied["comment"]["id"], 9);
    assert_eq!(replied["thread"]["number"], 41);
    let post = fake
        .sent()
        .into_iter()
        .find(|r| r.method == Method::Post && r.path_and_query == "/v1/forum/threads")
        .expect("a post");
    let body: Value = serde_json::from_slice(post.body.as_deref().unwrap()).unwrap();
    assert_eq!(body, json!({"space": "fleet", "title": "T", "body": "B", "labels": ["finding"]}));
}

#[test]
fn a_mutation_without_its_key_or_with_bad_params_is_refused_before_the_network() {
    let fake = Fake::default();
    let (mux, conn) = app(Some(&fake));
    let reply = send(&mux, &conn, "forum.thread.reply", json!({"number": 41, "body": "x"}), None);
    assert_eq!(reply["ok"], false, "{reply}");
    let reply =
        send(&mux, &conn, "forum.thread.reply", json!({"number": 0, "body": "x"}), Some("k"));
    assert_eq!(reply["ok"], false, "{reply}");
    let reply = send(
        &mux,
        &conn,
        "forum.thread.post",
        json!({"space": "fleet", "title": "T", "body": "B", "kind": "rant"}),
        Some("k"),
    );
    assert_eq!(reply["ok"], false, "{reply}");
    assert!(fake.sent().is_empty());
}

#[test]
fn without_a_forum_the_snapshot_is_signed_out_and_writes_say_so() {
    let (mux, conn) = app(None);
    let snapshot = ok(send(&mux, &conn, "forum.snapshot", json!({}), None));
    assert_eq!(snapshot["status"], "signed-out");
    let reply =
        send(&mux, &conn, "forum.thread.reply", json!({"number": 4, "body": "x"}), Some("k"));
    assert_eq!(reply["ok"], false, "{reply}");
    assert!(reply.to_string().contains("forum.not_set_up"), "{reply}");
}

#[test]
fn a_refusal_carries_its_code_and_never_the_key() {
    let fake = Fake::default();
    fake.on(
        "/v1/forum/token",
        401,
        json!({"code": "auth.invalid", "message": format!("bad {KEY}")}),
    );
    let (mux, conn) = app(Some(&fake));
    let reply = send(&mux, &conn, "forum.snapshot", json!({}), None);
    assert_eq!(reply["ok"], false, "{reply}");
    assert!(reply.to_string().contains("forum.unauthorized"), "{reply}");
    assert!(!reply.to_string().contains(KEY), "{reply}");
}

#[test]
fn only_the_app_process_reads_the_forum() {
    let fake = Fake::default();
    let (mux, _) = app(Some(&fake));
    let script = connect(&mux, "main", false);
    let reply = send(&mux, &script, "forum.snapshot", json!({}), None);
    assert_eq!(reply["ok"], false, "{reply}");
    assert!(fake.sent().is_empty());
}

/// Seeded secrets on the wire (cmux_egress::capture): the agent key rides only in the token
/// exchange's `Authorization`, the team only in `x-cmux-team`. tests/egress_seeded.json names this
/// test for `cmux_tui_core::server::forum_routed`.
#[test]
fn seeded_secrets_ride_only_where_the_forum_needs_them() {
    cmux_egress::capture::install().unwrap();
    let key = "cfk_SEEDforumRoutedKey-7d20";
    let team = "SEEDroutedTeam-35fe";
    let owner = ForumOwner::at(cmux_forum_hosted::DEVELOPMENT_BASE_URL.to_owned(), team, key);
    // The capture server answers `200 {}`: the exchange decodes no token and the call ends.
    let _ = super::run(&owner, "forum.snapshot", super::ForumRequest::Snapshot { space: None });
    let sent = cmux_egress::capture::requests_to("cmux-platform-development.debussy.workers.dev");
    assert!(!sent.is_empty(), "the exchange reached the capture server");
    let places = cmux_egress::capture::leaks(key);
    assert!(!places.is_empty(), "{sent:?}");
    assert!(
        places.iter().all(|p| p.ends_with(" /v1/forum/token: header authorization")),
        "{places:?}"
    );
    let places = cmux_egress::capture::leaks(team);
    assert!(places.iter().all(|p| p.ends_with(": header x-cmux-team")), "{places:?}");
}
