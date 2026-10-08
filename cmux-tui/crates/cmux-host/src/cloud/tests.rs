//! Parity with the interim Bun agent (web/tests/vm-image-vm-agent.test.ts):
//! what the Cloud role sends, when, and to where, against a fake server
//! that answers with the cloud-vectors.json shapes.

use std::cell::RefCell;
use std::collections::VecDeque;
use std::rc::Rc;

use cmux_server_core::install_key::{SystemRandom, verify};
use serde_json::{Value, json};

use super::client::{
    BindResult, CloudClient, Http, MemoryStore, Store, bind_machine, ensure_install_key,
};
use super::sender::{Answer, OpRequest};
use super::session::Session;
use super::wire::*;

const DEV: &str = "https://cmux-api-development.debussy.workers.dev";
const TEAM: &str = "team_t0000000000000000001";
const MACHINE: &str = "vm_m0000000000000000004";
const INSTALL: &str = "inst_v0000000000000000004";
const USER: &str = "user_u0000000000000000001";
const T0: u64 = 1_790_000_000_000;

fn bind_text() -> String {
    json!({
        "team": TEAM,
        "machine": MACHINE,
        "bind_token": "bt_vector_one_time_token_000000000000000000",
        "api_origin": DEV,
        "env": "dev",
    })
    .to_string()
}

#[derive(Clone, Debug)]
struct Seen {
    url: String,
    bearer: Option<String>,
    body: Value,
}

#[derive(Default)]
struct FakeState {
    seen: Vec<Seen>,
    bind_calls: usize,
    registered: Option<Value>,
    prefix_env: String,
    ops: VecDeque<(u16, Value)>,
}

#[derive(Clone, Default)]
struct Fake(Rc<RefCell<FakeState>>);

impl Fake {
    fn new() -> Fake {
        let fake = Fake::default();
        fake.0.borrow_mut().prefix_env = "development".to_owned();
        fake
    }
    fn ops(&self) -> Vec<Seen> {
        self.0.borrow().seen.iter().filter(|s| s.url.ends_with("/v1/ops")).cloned().collect()
    }
    fn clear(&self) {
        self.0.borrow_mut().seen.clear();
    }
    fn script(&self, answers: Vec<(u16, Value)>) {
        self.0.borrow_mut().ops = answers.into();
    }
}

fn applied() -> Value {
    json!({ "ok": true, "op": "cloud.vm.status.report", "value": { "applied": true } })
}

impl Http for Fake {
    fn post(&self, url: &str, body: &Value, bearer: Option<&str>) -> Result<(u16, Value), String> {
        let mut st = self.0.borrow_mut();
        st.seen.push(Seen {
            url: url.to_owned(),
            bearer: bearer.map(str::to_owned),
            body: body.clone(),
        });
        let path = url.strip_prefix(DEV).ok_or_else(|| format!("unexpected origin in {url}"))?;
        match path {
            "/v1/cloud/bind" => {
                st.bind_calls += 1;
                if st.bind_calls == 1 {
                    st.registered = Some(body["install_public_jwk"].clone());
                    Ok((
                        200,
                        json!({ "ok": true, "value": {
                            "machine": MACHINE, "host": "host_h0000000000000000004", "epoch": 1,
                            "keyset": { "version": "0123456789abcdef", "keys": {} },
                            "install": { "id": INSTALL, "user": USER, "grant": "grant_v000000000000000004" },
                        }}),
                    ))
                } else {
                    Ok((
                        403,
                        json!({ "ok": false, "error": { "code": "auth.forbidden", "message": "bind refused" } }),
                    ))
                }
            }
            "/v1/auth/challenge" => Ok((
                200,
                json!({
                    "install": body["install"], "nonce": "nonce-1", "expires_at": T0 + 60_000,
                    "message_prefix": format!("cmux-auth-v1\n{}\n{}\n", st.prefix_env, body["install"].as_str().unwrap_or("")),
                }),
            )),
            "/v1/auth/token" => {
                let message = format!("cmux-auth-v1\ndevelopment\n{INSTALL}\nnonce-1");
                let jwk = st.registered.clone().unwrap_or(Value::Null);
                if !verify(&jwk, message.as_bytes(), body["signature"].as_str().unwrap_or("")) {
                    return Ok((403, json!({ "code": "auth.forbidden" })));
                }
                Ok((
                    200,
                    json!({ "access_token": "tok-1", "token_type": "Bearer", "expires_at": T0 + 3_600_000 }),
                ))
            }
            "/v1/ops" => Ok(st.ops.pop_front().unwrap_or((200, applied()))),
            _ => Ok((404, json!({}))),
        }
    }
}

fn daemon() -> DaemonInfo {
    DaemonInfo {
        version: "0.40.0".to_owned(),
        capabilities: vec!["terminal".to_owned(), "files".to_owned()],
    }
}

/// A bound client against the fake (bind done with the vector's answer).
fn bound_client(fake: &Fake) -> CloudClient<Fake> {
    let rng = SystemRandom::new();
    let mut store = MemoryStore::default();
    store.write(BIND_FILE, &bind_text(), 0o600).unwrap();
    let key = ensure_install_key(&mut store, "i-aaa", &rng).unwrap().key;
    let BindResult::Bound(bound) = bind_machine(&mut store, fake, &key, "AAAA=", &daemon(), T0)
    else {
        panic!("bind failed")
    };
    CloudClient::new(fake.clone(), *bound, key)
}

/// What the role's worker does: send each request, feed the answer back.
fn drive(
    client: &mut CloudClient<Fake>,
    session: &mut Session,
    mut queue: Vec<OpRequest>,
    now: u64,
) -> Vec<String> {
    let mut reasons = Vec::new();
    while let Some(req) = queue.pop() {
        let answer = client.op(&req, T0 + now);
        reasons.push(req.reason.clone());
        queue.extend(session.answered(&req, &answer, now, 0.5).0);
    }
    reasons
}

#[test]
fn bind_file_allows_only_the_environment_origin() {
    assert_eq!(parse_bind_file(&bind_text()).unwrap().env, Env::Dev);
    let other = bind_text().replace(DEV, "https://cloud-api.cmux.dev");
    assert!(parse_bind_file(&other).unwrap_err().contains("api_origin"));
    assert!(parse_bind_file(&bind_text().replace("\"dev\"", "\"qa\"")).is_err());
    assert!(parse_bind_file(&bind_text().replace(TEAM, "team_short")).is_err());
}

#[test]
fn install_key_is_kept_per_instance_and_replaced_on_a_new_instance_id() {
    let rng = SystemRandom::new();
    let mut store = MemoryStore::default();
    let a = ensure_install_key(&mut store, "i-aaa", &rng).unwrap();
    assert!(a.rotated);
    assert_eq!(store.mode_of(INSTALL_KEY_FILE), Some(0o600));
    let again = ensure_install_key(&mut store, "i-aaa", &rng).unwrap();
    assert!(!again.rotated);
    assert_eq!(again.key.public_jwk(), a.key.public_jwk());
    let clone = ensure_install_key(&mut store, "i-bbb", &rng).unwrap();
    assert!(clone.rotated);
    assert_ne!(clone.key.public_jwk(), a.key.public_jwk());
}

#[test]
fn bind_posts_the_vector_fields_writes_bound_then_removes_bind() {
    let fake = Fake::new();
    let rng = SystemRandom::new();
    let mut store = MemoryStore::default();
    store.write(BIND_FILE, &bind_text(), 0o600).unwrap();
    let key = ensure_install_key(&mut store, "i-aaa", &rng).unwrap().key;
    let result = bind_machine(&mut store, &fake, &key, "AAAA=", &daemon(), T0);
    assert!(matches!(result, BindResult::Bound(_)), "{result:?}");
    let seen = fake.0.borrow().seen[0].clone();
    assert_eq!(seen.url, format!("{DEV}/v1/cloud/bind"));
    assert_eq!(seen.bearer, None, "the one-time token is the credential");
    let mut keys: Vec<&String> = seen.body.as_object().unwrap().keys().collect();
    keys.sort();
    assert_eq!(
        keys,
        ["bind_token", "daemon", "install_public_jwk", "machine", "team", "wg_public_key"]
    );
    assert_eq!(seen.body["install_public_jwk"], key.public_jwk());
    let bound: Value = serde_json::from_str(&store.read(BOUND_FILE).unwrap()).unwrap();
    assert_eq!(bound["machine"], MACHINE);
    assert_eq!(bound["install"], INSTALL);
    assert_eq!(bound["user"], USER);
    assert_eq!(bound["env"], "dev");
    assert_eq!(store.read(BIND_FILE), None);
    assert_eq!(store.mode_of(BOUND_FILE), Some(0o600));
}

#[test]
fn a_spent_token_is_refused_and_never_overwrites_bound() {
    let fake = Fake::new();
    let _ = bound_client(&fake);
    let rng = SystemRandom::new();
    let mut store = MemoryStore::default();
    store.write(BOUND_FILE, "{\"before\":1}", 0o600).unwrap();
    store.write(BIND_FILE, &bind_text(), 0o600).unwrap();
    let key = ensure_install_key(&mut store, "i-aaa", &rng).unwrap().key;
    let result = bind_machine(&mut store, &fake, &key, "AAAA=", &daemon(), T0);
    assert_eq!(result, BindResult::Refused("auth.forbidden".to_owned()));
    assert_eq!(store.read(BOUND_FILE).as_deref(), Some("{\"before\":1}"));
    assert_eq!(store.read(BIND_FILE), None);
}

#[test]
fn token_signs_prefix_and_nonce_and_refuses_another_environment() {
    let fake = Fake::new();
    let mut client = bound_client(&fake);
    fake.0.borrow_mut().prefix_env = "production".to_owned();
    assert!(client.token(T0).unwrap_err().contains("prefix"));
    fake.0.borrow_mut().prefix_env = "development".to_owned();
    assert_eq!(client.token(T0).unwrap(), "tok-1");
    let seen = fake.0.borrow().seen.clone();
    let token_req = seen.iter().rfind(|s| s.url.ends_with("/v1/auth/token")).unwrap();
    assert_eq!(token_req.body["user"], USER);
    assert_eq!(token_req.body["install"], INSTALL);
    assert_eq!(token_req.body["nonce"], "nonce-1");
}

#[test]
fn first_report_goes_to_ops_after_start_with_zero_sessions() {
    let fake = Fake::new();
    let mut client = bound_client(&fake);
    fake.clear();
    let mut session = Session::new(MACHINE, daemon(), 60_000);
    let reqs = session.start(0);
    assert_eq!(drive(&mut client, &mut session, reqs, 0), ["start"]);
    let ops = fake.ops();
    assert_eq!(ops.len(), 1);
    assert_eq!(ops[0].url, format!("{DEV}/v1/ops"), "where: the bound environment's /v1/ops");
    assert_eq!(ops[0].bearer.as_deref(), Some("tok-1"));
    assert_eq!(
        ops[0].body,
        json!({ "op": "cloud.vm.status.report", "params": {
            "machine": MACHINE, "state": "running", "daemon": daemon().to_json(),
            "activity": { "active_sessions": 0 },
        }})
    );
}

#[test]
fn changes_coalesce_to_one_report_per_10s_latest_wins() {
    let fake = Fake::new();
    let mut client = bound_client(&fake);
    let mut session = Session::new(MACHINE, daemon(), 60_000);
    let reqs = session.start(0);
    drive(&mut client, &mut session, reqs, 0);
    fake.clear();
    let line = |n: u64, key: &str, at: u64| {
        json!({ "activity": { "active_sessions": n, key: at } }).to_string()
    };
    let (reqs, _) = session.line(&line(1, "last_user_input_at", T0), 1);
    assert!(reqs.is_empty(), "inside the 10 s window");
    let (reqs, _) = session.line(&line(2, "last_agent_action_at", T0 + 1), 2);
    assert!(reqs.is_empty());
    assert_eq!(session.next_deadline(), Some(10_000), "one window deadline");
    let reqs = session.fire(10_000);
    assert_eq!(drive(&mut client, &mut session, reqs, 10_000), ["change"]);
    let ops = fake.ops();
    assert_eq!(ops.len(), 1);
    assert_eq!(
        ops[0].body["params"]["activity"],
        json!({ "active_sessions": 2, "last_user_input_at": T0, "last_agent_action_at": T0 + 1 })
    );
}

#[test]
fn heartbeat_is_one_deadline_rearmed_after_each_accepted_report() {
    let fake = Fake::new();
    let mut client = bound_client(&fake);
    let mut session = Session::new(MACHINE, daemon(), 60_000);
    let reqs = session.start(0);
    drive(&mut client, &mut session, reqs, 0);
    fake.clear();
    assert_eq!(session.reporter.deadlines(), [60_000]);
    assert!(session.fire(59_999).is_empty());
    let reqs = session.fire(60_000);
    assert_eq!(drive(&mut client, &mut session, reqs, 60_000), ["heartbeat"]);
    assert_eq!(fake.ops().len(), 1);
    assert_eq!(session.reporter.deadlines(), [120_000]);
}

#[test]
fn failed_reports_back_off_honor_retry_after_and_cap_at_10_min() {
    let fake = Fake::new();
    let mut client = bound_client(&fake);
    let mut session = Session::new(MACHINE, daemon(), 60_000);
    let reqs = session.start(0);
    drive(&mut client, &mut session, reqs, 0);
    fake.clear();
    let mut script = vec![(
        200,
        json!({ "ok": false, "error": { "code": "cloud.rate_limited", "details": { "retry_after_ms": 4_000 } } }),
    )];
    script.extend((0..12).map(|_| (503, json!({ "code": "owner.unreachable" }))));
    fake.script(script);
    let reqs = session.line(&json!({ "activity": { "active_sessions": 0 } }).to_string(), 5_000).0;
    assert!(reqs.is_empty());
    let mut now = 10_000;
    let reqs = session.fire(now);
    drive(&mut client, &mut session, reqs, now);
    let mut delays = Vec::new();
    for _ in 0..13 {
        let deadlines = session.reporter.deadlines();
        assert_eq!(deadlines.len(), 1, "while failing, the retry is the only timer: {deadlines:?}");
        delays.push(deadlines[0] - now);
        now = deadlines[0];
        let reqs = session.fire(now);
        drive(&mut client, &mut session, reqs, now);
    }
    assert!(delays[0] >= 4_000, "{delays:?}");
    assert!(delays.windows(2).all(|w| w[1] >= w[0]), "{delays:?}");
    assert_eq!(*delays.last().unwrap(), 600_000);
    assert_eq!(fake.ops().len(), 14);
    assert_eq!(session.reporter.deadlines(), [now + 60_000], "heartbeat re-armed after success");
}

#[test]
fn resume_sends_one_report_named_resume() {
    let fake = Fake::new();
    let mut client = bound_client(&fake);
    let mut session = Session::new(MACHINE, daemon(), 60_000);
    let reqs = session.start(0);
    drive(&mut client, &mut session, reqs, 0);
    fake.clear();
    // The supervisor's Resumed event (outside the 10 s window).
    let reqs = session.resume(30_000);
    assert_eq!(drive(&mut client, &mut session, reqs, 30_000), ["resume"]);
    assert_eq!(fake.ops().len(), 1);
    // The interim agent's socket line still works.
    let reqs = session.line("{\"resume\": true}", 45_000).0;
    assert_eq!(drive(&mut client, &mut session, reqs, 45_000), ["resume"]);
}

#[test]
fn change_and_resume_before_one_send_are_both_named() {
    let fake = Fake::new();
    let mut client = bound_client(&fake);
    let mut session = Session::new(MACHINE, daemon(), 60_000);
    let reqs = session.start(0);
    drive(&mut client, &mut session, reqs, 0);
    assert!(
        session.line(&json!({ "activity": { "active_sessions": 1 } }).to_string(), 1).0.is_empty()
    );
    assert!(session.resume(2).is_empty());
    let reqs = session.fire(10_000);
    assert_eq!(drive(&mut client, &mut session, reqs, 10_000), ["change+resume"]);
}

#[test]
fn daemon_activity_maps_to_sessions_and_real_times() {
    let change = activity_from_daemon(&json!({
        "attached_clients": 2, "live_agents": 1, "last_user_input_at_ms": 5, "last_agent_action_at_ms": null,
    }));
    assert_eq!(
        change,
        ActivityChange {
            active_sessions: Some(3),
            last_user_input_at: Some(5),
            last_agent_action_at: None
        }
    );
    assert_eq!(activity_from_daemon(&json!({})).active_sessions, Some(0));
}

#[test]
fn activity_capability_is_advertised_only_while_the_stream_is_live() {
    let fake = Fake::new();
    let mut client = bound_client(&fake);
    let mut session = Session::new(MACHINE, daemon(), 60_000);
    let reqs = session.start(0);
    drive(&mut client, &mut session, reqs, 0);
    fake.clear();
    assert!(session.activity_stream(true, 1).is_empty(), "held for the window");
    let reqs = session.daemon_activity(&json!({ "attached_clients": 1, "live_agents": 0 }), 2);
    assert!(reqs.is_empty());
    let reqs = session.fire(10_000);
    assert_eq!(drive(&mut client, &mut session, reqs, 10_000), ["daemon+change"]);
    let ops = fake.ops();
    assert_eq!(
        ops[0].body["params"]["daemon"]["capabilities"],
        json!(["terminal", "files", "activity"])
    );
    assert_eq!(ops[0].body["params"]["activity"]["active_sessions"], 1);
    let reqs = session.activity_stream(false, 20_000);
    assert_eq!(drive(&mut client, &mut session, reqs, 20_000), ["daemon"]);
    assert_eq!(
        fake.ops()[1].body["params"]["daemon"]["capabilities"],
        json!(["terminal", "files"])
    );
}

#[test]
fn events_v1_kinds_only_in_order_rate_limit_honored() {
    let fake = Fake::new();
    let mut client = bound_client(&fake);
    let mut session = Session::new(MACHINE, daemon(), 60_000);
    fake.script(vec![
        (200, json!({ "ok": false, "error": { "code": "cloud.rate_limited", "details": { "retry_after_ms": 100 } } })),
        (200, json!({ "ok": true, "value": { "delivered": true } })),
    ]);
    let (reqs, note) = session.line(
        &json!({ "event": { "kind": "agent.exploded", "at": T0, "data": {} } }).to_string(),
        0,
    );
    assert!(reqs.is_empty() && note.unwrap().contains("kind"));
    let line = json!({ "event": { "kind": "agent.finished", "at": T0, "data": { "title": "Done", "outcome": "success" } } });
    let reqs = session.line(&line.to_string(), 0).0;
    assert_eq!(drive(&mut client, &mut session, reqs, 0), ["agent.finished"]);
    assert_eq!(session.next_deadline(), Some(100));
    let reqs = session.fire(100);
    drive(&mut client, &mut session, reqs, 100);
    let ops = fake.ops();
    assert_eq!(ops.len(), 2);
    assert_eq!(
        ops[1].body,
        json!({ "op": "cloud.vm.event.emit", "params": { "machine": MACHINE, "kind": "agent.finished", "at": T0, "data": { "title": "Done", "outcome": "success" } } })
    );
    assert!(session.events.is_empty());
}

#[test]
fn heartbeat_override_only_in_dev() {
    assert_eq!(heartbeat_ms_for(Env::Dev, Some("15000")), 15_000);
    assert_eq!(heartbeat_ms_for(Env::Dev, Some("999")), DEFAULT_HEARTBEAT_MS);
    assert_eq!(heartbeat_ms_for(Env::Dev, Some("x")), DEFAULT_HEARTBEAT_MS);
    assert_eq!(heartbeat_ms_for(Env::Stg, Some("15000")), DEFAULT_HEARTBEAT_MS);
    assert_eq!(heartbeat_ms_for(Env::Prod, Some("15000")), DEFAULT_HEARTBEAT_MS);
}

#[test]
fn daemon_block_from_identify_is_gated_and_versioned() {
    let identify = json!({
        "version": "0.40.0", "build_commit": "abcdef0123456789",
        "capabilities": ["terminal", "loopback-forward-v1", "fs-v1", "vm-activity-v1"],
    });
    let info = daemon_info_from_identify(&identify, false);
    assert_eq!(info.version, "0.40.0+abcdef012345");
    assert_eq!(info.capabilities, ["fs-v1", "loopback-forward-v1", "vm-agent-v1"]);
    assert_eq!(
        daemon_info_from_identify(&json!({}), true).capabilities,
        ["vm-agent-v1", "activity"]
    );
}

#[test]
fn transport_failure_keeps_the_report_for_the_retry() {
    let mut session = Session::new(MACHINE, daemon(), 60_000);
    let req = session.start(0).pop().unwrap();
    let (next, note) = session.answered(&req, &Answer::Transport, 0, 0.5);
    assert!(next.is_empty());
    assert_eq!(note.as_deref(), Some("report start failed"));
    assert_eq!(session.reporter.deadlines(), [5_000]);
    let retry = session.fire(5_000);
    assert_eq!(retry[0].reason, "start");
}

/// The server applies one report per 10 s measured from when it RECEIVED the
/// last applied one (cloud-vm.ts VmStatusQueue); dev-e2e on 2026-10-08 saw
/// change, heartbeat and resume reports `held` because the agent measured its
/// window from its own SEND time, one latency earlier. The window starts when
/// the answer arrives, which is after the server's receive time.
#[test]
fn the_10s_window_counts_from_the_answer_not_the_send() {
    let fake = Fake::new();
    let mut client = bound_client(&fake);
    let mut session = Session::new(MACHINE, daemon(), 60_000);
    let mut reqs = session.start(0);
    let req = reqs.pop().expect("first report");
    let answer = client.op(&req, T0);
    // The answer arrives 300 ms after the send.
    let (next, _) = session.answered(&req, &answer, 300, 0.5);
    assert!(next.is_empty());
    let line = json!({ "activity": { "active_sessions": 1 } }).to_string();
    let (reqs, _) = session.line(&line, 1_000);
    assert!(reqs.is_empty(), "inside the window");
    assert_eq!(session.next_deadline(), Some(10_300), "10 s after the answer arrived");
    assert!(session.fire(10_000).is_empty(), "10 s after the send is still inside the server's window");
}
