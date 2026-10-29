//! The agent's side of a hand-off report against a fake Cloud API: the
//! hand-off it names, the request it sends (route, bearer, body), the reply
//! line it builds, and the minter answering it off the poll loop.

use std::collections::VecDeque;
use std::io::{BufRead, BufReader};
use std::os::unix::net::UnixStream;
use std::sync::{Arc, Mutex};

use cmux_server_core::install_key::{InstallKey, SystemRandom};
use serde_json::{Value, json};

use super::client::{CloudClient, Http};
use super::github_minter::Minter;
use super::handoff::{HandoffReport, handoff_id, note_for, reply_for};
use super::sender::Answer;
use super::wire::{Bound, Env};

const DEV: &str = "https://cmux-api-development.debussy.workers.dev";
const INSTALL: &str = "inst_v0000000000000000004";
const USER: &str = "user_u0000000000000000001";
const T0: u64 = 1_790_000_000_000;

#[derive(Default)]
struct State {
    seen: Vec<(String, Option<String>, Value)>,
    tokens_minted: usize,
    answers: VecDeque<(u16, Value)>,
}

#[derive(Clone, Default)]
struct Fake(Arc<Mutex<State>>);

impl Http for Fake {
    fn post(&self, url: &str, body: &Value, bearer: Option<&str>) -> Result<(u16, Value), String> {
        let mut st = self.0.lock().unwrap();
        st.seen.push((url.to_owned(), bearer.map(str::to_owned), body.clone()));
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
                    json!({ "access_token": format!("bearer-{n}"), "token_type": "Bearer", "expires_at": T0 + 600_000 }),
                ))
            }
            path if path.starts_with("/v1/handoffs/") => {
                Ok(st.answers.pop_front().unwrap_or((500, json!({}))))
            }
            _ => Ok((404, json!({}))),
        }
    }
}

fn client(fake: &Fake) -> CloudClient<Fake> {
    let bound = Bound {
        machine: "vm_m0000000000000000004".to_owned(),
        team: "team_t0000000000000000001".to_owned(),
        host: "host_h0000000000000000004".to_owned(),
        epoch: 1,
        install: INSTALL.to_owned(),
        user: USER.to_owned(),
        grant: "grant_v000000000000000004".to_owned(),
        env: Env::Dev,
        api_origin: DEV.to_owned(),
        keyset: Value::Null,
        bound_at: T0,
    };
    let key = InstallKey::generate(&SystemRandom::new()).unwrap();
    CloudClient::new(fake.clone(), bound, key)
}

fn report(v: Value) -> Result<HandoffReport, String> {
    HandoffReport::from_json(&v)
}

fn handoff(turn: u64, status: &str) -> Value {
    json!({ "id": handoff_id(USER, "acp_s1"), "sessionId": "acp_s1", "machine": "vm_m0000000000000000004",
            "turn": turn, "state": "open", "status": status, "summary": "secret-ish summary", "version": 3,
            "statusAt": "2026-10-28T10:00:00.000Z" })
}

/// The store's own id: `ho_` + sha256(owner NUL session)[:20]
/// (backend/apps/api/src/handoffs/routes.ts `create`).
#[test]
fn names_the_hand_off_as_the_store_does() {
    // sha256("user_u0000000000000000001\0acp_s1"), as the Worker computes it
    let id = handoff_id(USER, "acp_s1");
    assert_eq!(id.len(), 23);
    assert!(id.starts_with("ho_"));
    assert!(id[3..].bytes().all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase()));
    assert_eq!(id, "ho_fd10ff7c749affce641e");
    assert_ne!(handoff_id(USER, "acp_s2"), id);
    assert_ne!(handoff_id("user_other", "acp_s1"), id);
}

#[test]
fn reports_to_the_hand_off_route_as_the_vm_install() {
    let fake = Fake::default();
    fake.0.lock().unwrap().answers.push_back((200, json!({ "handoff": handoff(2, "done") })));
    let mut c = client(&fake);
    let r =
        report(json!({ "session": "acp_s1", "turn": 2, "status": "done", "summary": "Fixed it." }))
            .unwrap();
    let (id, answer) = c.handoff_report(&r, T0);
    let reply = reply_for(&answer);
    assert_eq!(
        reply,
        json!({ "ok": true, "handoff": { "id": id, "turn": 2, "state": "open", "status": "done", "statusAt": "2026-10-28T10:00:00.000Z" } }),
        "the reply carries the turn and state, never the summary"
    );
    let st = fake.0.lock().unwrap();
    let (url, bearer, body) = st.seen.last().unwrap().clone();
    assert_eq!(url, format!("{DEV}/v1/handoffs/{id}/report"));
    assert_eq!(bearer.as_deref(), Some("bearer-1"), "the vm install's bearer, minted by the agent");
    assert_eq!(body, json!({ "turn": 2, "status": "done", "summary": "Fixed it." }));
    assert_eq!(note_for(&id, &r, &reply), format!("handoff {id} turn 2 done: accepted"));
}

#[test]
fn a_refusal_passes_the_code_and_the_current_turn_through() {
    let fake = Fake::default();
    fake.0.lock().unwrap().answers.push_back((
        409,
        json!({ "error": { "code": "handoff.stale", "message": "turn 1 is over; the current turn is 2" }, "handoff": handoff(2, "starting") }),
    ));
    let mut c = client(&fake);
    let r = report(json!({ "session": "acp_s1", "turn": 1, "status": "running" })).unwrap();
    let (id, answer) = c.handoff_report(&r, T0);
    let reply = reply_for(&answer);
    assert_eq!(
        reply,
        json!({ "ok": false, "status": 409,
                "error": { "code": "handoff.stale", "message": "turn 1 is over; the current turn is 2" },
                "handoff": { "id": id, "turn": 2, "state": "open", "status": "starting", "statusAt": "2026-10-28T10:00:00.000Z" } })
    );
    assert_eq!(
        note_for(&id, &r, &reply),
        format!("handoff {id} turn 1 running: refused handoff.stale")
    );
    // A session nobody handed off: 404, no hand-off.
    let missing = reply_for(&Answer::Http {
        status: 404,
        body: json!({ "error": { "code": "handoff.not_found", "message": "hand-off not found" } }),
    });
    assert_eq!(missing["error"]["code"], "handoff.not_found");
    assert!(missing.get("handoff").is_none());
    assert_eq!(reply_for(&Answer::Transport)["error"]["code"], "handoff.unreachable");
    assert_eq!(
        reply_for(&Answer::Http { status: 200, body: json!({}) })["error"]["code"],
        "handoff.bad_answer"
    );
}

/// A 401 drops the bearer and retries once, as for GitHub tokens.
#[test]
fn a_stale_bearer_is_dropped_and_retried_once() {
    let fake = Fake::default();
    fake.0.lock().unwrap().answers.extend([
        (401, json!({ "error": { "code": "auth.unauthenticated" } })),
        (200, json!({ "handoff": handoff(1, "running") })),
    ]);
    let mut c = client(&fake);
    let r = report(json!({ "session": "acp_s1", "turn": 1, "status": "running" })).unwrap();
    assert_eq!(reply_for(&c.handoff_report(&r, T0).1)["ok"], true);
    let st = fake.0.lock().unwrap();
    assert_eq!(st.tokens_minted, 2);
    assert_eq!(st.seen.last().unwrap().1.as_deref(), Some("bearer-2"));
}

#[test]
fn reports_are_checked_before_they_reach_the_api() {
    let ok = json!({ "session": "acp_s1", "turn": 1, "status": "needs-you", "summary": "Allow npm install?" });
    let parsed = report(ok.clone()).unwrap();
    assert_eq!(parsed.summary.as_deref(), Some("Allow npm install?"));
    // The line acpmux sends round-trips.
    let line: Value = serde_json::from_str(&parsed.to_line()).unwrap();
    assert_eq!(line["handoff_report"], ok);
    let bad = [
        json!({ "session": "", "turn": 1, "status": "done" }),
        json!({ "session": "a/b", "turn": 1, "status": "done" }),
        json!({ "session": "x".repeat(129), "turn": 1, "status": "done" }),
        json!({ "session": "acp_s1", "turn": 0, "status": "done" }),
        json!({ "session": "acp_s1", "turn": -1, "status": "done" }),
        json!({ "session": "acp_s1", "turn": "1", "status": "done" }),
        json!({ "session": "acp_s1", "turn": 1, "status": "cancelled" }),
        json!({ "session": "acp_s1", "turn": 1, "status": "starting" }),
        json!({ "session": "acp_s1", "turn": 1, "status": "done", "summary": 3 }),
        json!({ "session": "acp_s1", "turn": 1, "status": "done", "summary": "é".repeat(2_001) }),
    ];
    for v in bad {
        assert!(report(v.clone()).is_err(), "{v}");
    }
    // 2 000 UTF-16 units is the store's limit, so an emoji counts twice.
    assert!(
        report(
            json!({ "session": "s", "turn": 1, "status": "done", "summary": "😀".repeat(1_000) })
        )
        .is_ok()
    );
    assert!(
        report(
            json!({ "session": "s", "turn": 1, "status": "done", "summary": "😀".repeat(1_001) })
        )
        .is_err()
    );
}

fn no_log(_: &str) {}
fn fixed_now() -> u64 {
    T0
}

/// One report through the minter thread: the reply line on `ours`.
fn ask_minter(minter: &Minter<Fake>, r: Result<HandoffReport, String>) -> Value {
    let (ours, theirs) = UnixStream::pair().unwrap();
    ours.set_read_timeout(Some(std::time::Duration::from_secs(10))).unwrap();
    minter.ask(r, theirs);
    let mut line = String::new();
    BufReader::new(ours).read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap()
}

#[test]
fn the_minter_answers_reports_off_the_poll_loop() {
    let fake = Fake::default();
    fake.0.lock().unwrap().answers.push_back((200, json!({ "handoff": handoff(1, "running") })));
    let minter: Minter<Fake> = Minter::spawn(fixed_now, no_log, Arc::default()).unwrap();
    let r = report(json!({ "session": "acp_s1", "turn": 1, "status": "running" })).unwrap();
    assert_eq!(ask_minter(&minter, Ok(r.clone()))["error"]["code"], "vm.unbound");
    assert_eq!(ask_minter(&minter, Err("bad".to_owned()))["error"]["code"], "request.invalid");
    minter.bound(client(&fake));
    let reply = ask_minter(&minter, Ok(r));
    assert_eq!(reply["ok"], true);
    assert_eq!(reply["handoff"]["turn"], 1);
    let reports =
        fake.0.lock().unwrap().seen.iter().filter(|(url, _, _)| url.ends_with("/report")).count();
    assert_eq!(reports, 1);
    drop(minter);
}
