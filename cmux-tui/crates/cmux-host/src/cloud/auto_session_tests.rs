//! The agent's side of an Auto mode call against a fake Cloud API: the line
//! each call is, the request it becomes (route, bearer, body, headers), the
//! reply line it gets, and that a chat's content is in no journal line.

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use cmux_server::cloud_http::{Payload, RawRequest, Response};
use cmux_server_core::install_key::{InstallKey, SystemRandom};
use serde_json::{Value, json};

use super::auto_session::{Call, Kind, REQUEST_KEY, note_for, valid_session, valid_sha256};
use super::auto_session_server::answer_call;
use super::client::{CloudClient, Http};
use super::wire::{Bound, Env};

pub(super) const DEV: &str = "https://cmux-api-development.debussy.workers.dev";
const INSTALL: &str = "inst_v0000000000000000004";
pub(super) const MACHINE: &str = "vm_m0000000000000000004";
pub(super) const T0: u64 = 1_790_000_000_000;
const SHA: &str = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08";

/// One raw request as the fake saw it.
#[derive(Clone, Debug, PartialEq)]
pub(super) struct Seen {
    pub method: String,
    pub url: String,
    pub bearer: Option<String>,
    pub headers: Vec<(String, String)>,
    pub json: Option<Value>,
    pub bytes: Option<Vec<u8>>,
    pub within_ms: u128,
    pub limit: usize,
}

#[derive(Default)]
pub(super) struct State {
    pub seen: Vec<Seen>,
    pub tokens_minted: usize,
    /// The answers to raw requests, in order; `None` is no answer.
    pub answers: VecDeque<Option<(u16, Vec<u8>)>>,
}

#[derive(Clone, Default)]
pub(super) struct Fake(pub Arc<Mutex<State>>);

impl Fake {
    pub(super) fn answers(&self, status: u16, body: &Value) {
        self.0.lock().unwrap().answers.push_back(Some((status, body.to_string().into_bytes())));
    }

    pub(super) fn last(&self) -> Seen {
        self.0.lock().unwrap().seen.last().unwrap().clone()
    }
}

/// The auth routes every fake here answers the same way.
pub(super) fn auth(st: &mut State, url: &str) -> Result<(u16, Value), String> {
    match url.strip_prefix(DEV).unwrap_or("") {
        "/v1/auth/challenge" => Ok((
            200,
            json!({ "install": INSTALL, "nonce": "n-1", "message_prefix": format!("cmux-auth-v1\ndevelopment\n{INSTALL}\n") }),
        )),
        "/v1/auth/token" => {
            st.tokens_minted += 1;
            let n = st.tokens_minted;
            Ok((
                200,
                json!({ "access_token": format!("bearer-{n}"), "token_type": "Bearer", "expires_at": T0 + 600_000, "install": INSTALL, "user": "user_u0000000000000000001", "grant": "grant_v000000000000000004", "team": "team_t0000000000000000001" }),
            ))
        }
        _ => Ok((404, json!({}))),
    }
}

pub(super) fn seen_of(request: &RawRequest<'_>) -> Seen {
    let (json, bytes) = match request.payload {
        Some(Payload::Json(body)) => (Some(body.clone()), None),
        Some(Payload::Bytes(bytes)) => (None, Some(bytes.to_vec())),
        None => (None, None),
    };
    Seen {
        method: request.method.to_owned(),
        url: request.url.to_owned(),
        bearer: request.bearer.map(str::to_owned),
        headers: request.headers.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect(),
        json,
        bytes,
        within_ms: request.within.as_millis(),
        limit: request.limit,
    }
}

impl Http for Fake {
    fn post(
        &self,
        url: &str,
        _body: &Value,
        _bearer: Option<&str>,
    ) -> Result<(u16, Value), String> {
        auth(&mut self.0.lock().unwrap(), url)
    }

    fn raw(&self, request: &RawRequest<'_>) -> Result<Response, String> {
        let mut st = self.0.lock().unwrap();
        st.seen.push(seen_of(request));
        match st.answers.pop_front().flatten() {
            Some((status, bytes)) => Ok(Response { status, retry_after: None, bytes }),
            None => Err("Cloud request failed".to_owned()),
        }
    }
}

pub(super) fn client<H: Http>(http: H) -> CloudClient<H> {
    let bound = Bound {
        machine: MACHINE.to_owned(),
        team: "team_t0000000000000000001".to_owned(),
        host: "host_h0000000000000000004".to_owned(),
        epoch: 1,
        install: INSTALL.to_owned(),
        user: "user_u0000000000000000001".to_owned(),
        grant: "grant_v000000000000000004".to_owned(),
        env: Env::Dev,
        api_origin: DEV.to_owned(),
        keyset: Value::Null,
        bound_at: T0,
    };
    let key = InstallKey::generate(&SystemRandom::new()).unwrap();
    CloudClient::new(http, bound, key)
}

fn holder() -> String {
    format!("vm:{MACHINE}")
}

fn fence() -> Value {
    json!({ "holder": holder(), "epoch": 4 })
}

fn session_view() -> Value {
    json!({ "id": "as_1", "auto": true, "holder": holder(), "epoch": 4, "state": "cloud", "version": 9 })
}

/// Every call, with the method and path it becomes.
fn calls() -> Vec<(Call, &'static str, String)> {
    let at = |tail: &str| format!("/v1/auto-sessions/as_1{tail}");
    let lease = json!({ "holder": holder(), "epoch": 4, "needsRun": true });
    let events = json!({ "holder": holder(), "epoch": 4, "events": [{ "seq": 1, "record": { "kind": "prompt", "text": "private words" } }] });
    let snapshot = json!({ "holder": holder(), "epoch": 4, "manifest": { "v": 1, "lastSeq": 1 } });
    let ack = json!({ "holder": holder(), "epoch": 4, "through": 2 });
    vec![
        (
            Call::assignments(25_000),
            "GET",
            "/v1/auto-sessions/assignments?timeoutMs=25000".to_owned(),
        ),
        (Call::read(Kind::Get, "as_1"), "GET", at("")),
        (Call::write(Kind::Lease, "as_1", lease), "POST", at("/lease")),
        (Call::write(Kind::Release, "as_1", fence()), "POST", at("/release")),
        (Call::write(Kind::Give, "as_1", fence()), "POST", at("/give")),
        (Call::write(Kind::EventsAppend, "as_1", events), "POST", at("/events")),
        (Call::page(Kind::Events, "as_1", 7, Some(100)), "GET", at("/events?after=7&limit=100")),
        (Call::page(Kind::Events, "as_1", 0, None), "GET", at("/events?after=0")),
        (
            Call::chunk_put("as_1", SHA, &holder(), 4, b"\x00\x01chunk"),
            "PUT",
            at(&format!("/chunks/{SHA}")),
        ),
        (Call::chunk("as_1", SHA), "GET", at(&format!("/chunks/{SHA}"))),
        (Call::write(Kind::SnapshotPost, "as_1", snapshot), "POST", at("/snapshot")),
        (Call::read(Kind::Snapshot, "as_1"), "GET", at("/snapshot")),
        (Call::page(Kind::Inbox, "as_1", 3, None), "GET", at("/inbox?after=3")),
        (Call::write(Kind::InboxAck, "as_1", ack), "POST", at("/inbox/ack")),
        (Call::write(Kind::AssignmentAck, "as_1", fence()), "POST", at("/assignment/ack")),
        (Call::write(Kind::Move, "as_1", json!({ "to": "local" })), "POST", at("/move")),
        (Call::write(Kind::Keep, "as_1", json!({ "keepInCloud": false })), "POST", at("/keep")),
    ]
}

fn parsed(line: &str) -> Result<Call, String> {
    let value: Value = serde_json::from_str(line).unwrap();
    Call::from_json(&value[REQUEST_KEY])
}

#[test]
fn every_route_a_machine_may_call_has_a_line_that_round_trips() {
    let calls = calls();
    // Every kind but `machine` (no request) is a route, and all of them are here.
    for kind in Kind::ALL {
        let covered = calls.iter().any(|(call, _, _)| call.kind == kind);
        assert_eq!(covered, kind != Kind::Machine, "{}", kind.name());
    }
    for (call, method, path) in calls {
        let line = call.to_line();
        assert!(!line.contains('\n'), "one line: {}", call.kind.name());
        assert_eq!(parsed(&line).as_ref(), Ok(&call), "{line}");
        assert_eq!(call.method(), Some(method), "{}", call.kind.name());
        assert_eq!(call.path(), path, "{}", call.kind.name());
    }
    let machine = Call::machine();
    assert_eq!(parsed(&machine.to_line()), Ok(machine.clone()));
    assert_eq!(machine.method(), None);
}

#[test]
fn a_call_goes_out_as_the_vm_install_and_its_answer_comes_back() {
    for (call, method, path) in calls() {
        let fake = Fake::default();
        let answer = json!({ "session": session_view(), "role": "holder", "leaseMs": 45_000 });
        fake.answers(200, &answer);
        let mut c = client(fake.clone());
        let reply = answer_call(Some(&mut c), Ok(call.clone()), T0);
        let seen = fake.last();
        assert_eq!(seen.method, method);
        assert_eq!(seen.url, format!("{DEV}{path}"));
        assert_eq!(seen.bearer.as_deref(), Some("bearer-1"), "the vm install's bearer");
        match call.kind {
            Kind::ChunkPut => {
                assert_eq!(seen.bytes.as_deref(), Some(&b"\x00\x01chunk"[..]));
                assert_eq!(
                    seen.headers,
                    [
                        ("x-cmux-auto-holder".to_owned(), holder()),
                        ("x-cmux-auto-epoch".to_owned(), "4".to_owned())
                    ]
                );
                assert_eq!(reply, json!({ "ok": true, "status": 200 }));
            }
            Kind::Chunk => {
                assert_eq!((seen.json, seen.bytes), (None, None));
                let bytes = BASE64.encode(answer.to_string());
                assert_eq!(reply, json!({ "ok": true, "status": 200, "bytes": bytes }));
            }
            _ => {
                assert_eq!(seen.json, call.body, "the body goes out as the daemon wrote it");
                assert!(seen.headers.is_empty());
                assert_eq!(reply, json!({ "ok": true, "status": 200, "body": answer }));
            }
        }
        assert_eq!(note_for(&call, &reply), None, "a call that went through leaves no line");
    }
}

#[test]
fn a_held_wait_gets_the_stores_hold_and_ten_seconds() {
    let fake = Fake::default();
    fake.answers(
        200,
        &json!({ "assignments": [{ "kind": "takeover", "session": session_view() }] }),
    );
    let mut c = client(fake.clone());
    let reply = answer_call(Some(&mut c), parsed(r#"{"auto_session":{"call":"assignments"}}"#), T0);
    assert_eq!(reply["body"]["assignments"][0]["kind"], "takeover");
    let seen = fake.last();
    assert_eq!(seen.url, format!("{DEV}/v1/auto-sessions/assignments?timeoutMs=25000"));
    assert_eq!(seen.within_ms, 35_000);
    // A longer ask is cut to what the store holds; a shorter one is kept.
    assert_eq!(Call::assignments(90_000).timeout_ms, 25_000);
    let short = parsed(r#"{"auto_session":{"call":"assignments","timeoutMs":0}}"#).unwrap();
    assert_eq!(short.path(), "/v1/auto-sessions/assignments?timeoutMs=0");
    assert_eq!(short.within().as_millis(), 10_000);
    // A renewal keeps the agent's usual bound.
    assert_eq!(Call::write(Kind::Lease, "as_1", fence()).within().as_millis(), 20_000);
}

#[test]
fn a_chunk_crosses_as_its_bytes_and_a_204_is_an_answer() {
    let chunk: Vec<u8> = (0..=255u8).cycle().take(1024 * 1024).collect();
    let fake = Fake::default();
    fake.0.lock().unwrap().answers.push_back(Some((204, Vec::new())));
    fake.0.lock().unwrap().answers.push_back(Some((200, chunk.clone())));
    let mut c = client(fake.clone());
    let put = Call::chunk_put("as_1", SHA, &holder(), 4, &chunk);
    assert_eq!(
        answer_call(Some(&mut c), parsed(&put.to_line()), T0),
        json!({ "ok": true, "status": 204 })
    );
    assert!(fake.last().bytes.as_deref() == Some(chunk.as_slice()), "the chunk arrives as sent");
    let got = answer_call(Some(&mut c), Ok(Call::chunk("as_1", SHA)), T0);
    assert_eq!(got["ok"], true);
    assert!(BASE64.decode(got["bytes"].as_str().unwrap()).unwrap() == chunk);
    assert_eq!(fake.last().limit, 1024 * 1024, "a chunk answer is at most a chunk");
}

#[test]
fn a_refusal_passes_the_stores_body_through_and_the_journal_names_only_its_code() {
    let fake = Fake::default();
    let refusal = json!({ "error": { "code": "auto.seq_gap", "message": "events must go on from 8" }, "session": session_view(), "lastSeq": 7 });
    fake.answers(409, &refusal);
    let mut c = client(fake.clone());
    let events = json!({ "holder": holder(), "epoch": 4, "events": [{ "seq": 9, "record": { "text": "private words" } }] });
    let call = Call::write(Kind::EventsAppend, "as_1", events);
    let reply = answer_call(Some(&mut c), Ok(call.clone()), T0);
    assert_eq!(reply, json!({ "ok": false, "status": 409, "body": refusal }));
    let note = note_for(&call, &reply).unwrap();
    assert_eq!(note, "auto-session events_append as_1: refused 409 auto.seq_gap");
    assert!(!note.contains("private"));
    // An answer that is no envelope keeps its status; no answer is the agent's own refusal.
    fake.0.lock().unwrap().answers.push_back(Some((502, b"<html>bad gateway</html>".to_vec())));
    let reply = answer_call(Some(&mut c), Ok(call.clone()), T0);
    assert_eq!(reply, json!({ "ok": false, "status": 502, "body": null }));
    assert_eq!(note_for(&call, &reply).unwrap(), "auto-session events_append as_1: refused 502 ?");
    fake.0.lock().unwrap().answers.push_back(None);
    let reply = answer_call(Some(&mut c), Ok(call.clone()), T0);
    assert_eq!(reply["error"]["code"], "auto.unreachable");
    assert!(reply.get("status").is_none());
    assert_eq!(
        note_for(&call, &reply).unwrap(),
        "auto-session events_append as_1: refused auto.unreachable"
    );
    // A 200 that is not JSON, for a route that answers JSON.
    fake.0.lock().unwrap().answers.push_back(Some((200, b"not json".to_vec())));
    assert_eq!(answer_call(Some(&mut c), Ok(call), T0)["error"]["code"], "auto.bad_answer");
}

/// A 401 drops the bearer and retries once, as for hand-off reports; an `auth.*` 403 too. A
/// store refusal is the answer, not a stale bearer.
#[test]
fn a_stale_bearer_is_dropped_and_retried_once() {
    let fake = Fake::default();
    fake.answers(401, &json!({ "error": { "code": "auth.unauthenticated" } }));
    fake.answers(200, &json!({ "session": session_view() }));
    fake.answers(403, &json!({ "error": { "code": "auth.forbidden" } }));
    fake.answers(200, &json!({ "session": session_view() }));
    fake.answers(409, &json!({ "error": { "code": "auto.stale_epoch", "message": "x" } }));
    let mut c = client(fake.clone());
    let get = Call::read(Kind::Get, "as_1");
    assert_eq!(answer_call(Some(&mut c), Ok(get.clone()), T0)["ok"], true);
    assert_eq!(fake.last().bearer.as_deref(), Some("bearer-2"));
    assert_eq!(answer_call(Some(&mut c), Ok(get.clone()), T0)["ok"], true);
    assert_eq!(fake.last().bearer.as_deref(), Some("bearer-3"));
    let refused = answer_call(Some(&mut c), Ok(get), T0);
    assert_eq!(refused["body"]["error"]["code"], "auto.stale_epoch");
    let st = fake.0.lock().unwrap();
    assert_eq!(st.tokens_minted, 3);
    assert_eq!(st.seen.len(), 5);
}

#[test]
fn the_machine_names_itself_without_a_request() {
    let fake = Fake::default();
    let mut c = client(fake.clone());
    let reply = answer_call(Some(&mut c), Ok(Call::machine()), T0);
    assert_eq!(reply, json!({ "ok": true, "machine": MACHINE }));
    assert!(fake.0.lock().unwrap().seen.is_empty());
    let unbound = answer_call(None::<&mut CloudClient<Fake>>, Ok(Call::machine()), T0);
    assert_eq!(unbound["error"]["code"], "vm.unbound");
    let invalid = answer_call(Some(&mut c), Err("bad".to_owned()), T0);
    assert_eq!(invalid["error"]["code"], "request.invalid");
}

#[test]
fn calls_are_checked_before_they_reach_the_api() {
    let ok = json!({ "holder": holder(), "epoch": 4 });
    let chunk = BASE64.encode(b"abc");
    let bad = [
        json!({}),
        json!({ "call": "put" }),
        json!({ "call": "wait", "session": "as_1" }),
        json!({ "call": "inbox_post", "session": "as_1", "body": ok }),
        json!({ "call": "get" }),
        json!({ "call": "get", "session": "" }),
        json!({ "call": "get", "session": "a/b" }),
        json!({ "call": "get", "session": "../machine" }),
        json!({ "call": "get", "session": "machine" }),
        json!({ "call": "get", "session": "assignments" }),
        json!({ "call": "get", "session": "x".repeat(129) }),
        json!({ "call": "lease", "session": "as_1" }),
        json!({ "call": "lease", "session": "as_1", "body": "text" }),
        json!({ "call": "lease", "session": "as_1", "body": { "epoch": 4 } }),
        json!({ "call": "lease", "session": "as_1", "body": { "holder": holder() } }),
        json!({ "call": "lease", "session": "as_1", "body": { "holder": "vm:a b", "epoch": 4 } }),
        json!({ "call": "lease", "session": "as_1", "body": { "holder": holder(), "epoch": -1 } }),
        json!({ "call": "lease", "session": "as_1", "body": { "holder": holder(), "epoch": "4" } }),
        json!({ "call": "move", "session": "as_1" }),
        json!({ "call": "move", "session": "as_1", "body": { "to": "mars" } }),
        json!({ "call": "move", "session": "as_1", "body": { "to": "local", "device": "vm:a" } }),
        json!({ "call": "keep", "session": "as_1", "body": { "keepInCloud": "yes" } }),
        json!({ "call": "events", "session": "as_1", "after": -1 }),
        json!({ "call": "events", "session": "as_1", "after": 1, "limit": 0 }),
        json!({ "call": "inbox", "session": "as_1", "after": "1" }),
        json!({ "call": "assignments", "timeoutMs": "long" }),
        json!({ "call": "chunk", "session": "as_1", "sha256": "abc" }),
        json!({ "call": "chunk", "session": "as_1", "sha256": SHA.to_uppercase() }),
        json!({ "call": "chunk", "session": "as_1", "sha256": format!("{}/..", &SHA[..60]) }),
        json!({ "call": "chunk_put", "session": "as_1", "sha256": SHA, "holder": holder(), "epoch": 4 }),
        json!({ "call": "chunk_put", "session": "as_1", "sha256": SHA, "holder": holder(), "epoch": 4, "bytes": "not base64!" }),
        json!({ "call": "chunk_put", "session": "as_1", "sha256": SHA, "epoch": 4, "bytes": chunk }),
        json!({ "call": "chunk_put", "session": "as_1", "sha256": SHA, "holder": holder(), "bytes": chunk }),
        json!({ "call": "chunk_put", "session": "as_1", "sha256": SHA, "holder": holder(), "epoch": 4,
                "bytes": BASE64.encode(vec![0u8; 1024 * 1024 + 1]) }),
    ];
    for v in bad {
        assert!(
            Call::from_json(&v).is_err(),
            "{}",
            v.to_string().chars().take(200).collect::<String>()
        );
    }
    assert!(valid_session("as_0123456789abcdef0123") && valid_session("acp:s.1-x"));
    assert!(valid_sha256(SHA) && !valid_sha256(&SHA[1..]));
    // A chunk of exactly 1 MiB is one.
    let full = json!({ "call": "chunk_put", "session": "as_1", "sha256": SHA, "holder": holder(), "epoch": 4,
                       "bytes": BASE64.encode(vec![7u8; 1024 * 1024]) });
    assert_eq!(Call::from_json(&full).unwrap().bytes.len(), 1024 * 1024);
}
