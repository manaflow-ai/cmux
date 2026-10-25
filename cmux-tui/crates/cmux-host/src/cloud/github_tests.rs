//! The agent's side of a GitHub token ask against a fake Cloud API: the
//! request it sends (route, bearer, body), the reply line it builds, and
//! that neither the journal note nor a refusal carries a token.

use std::collections::VecDeque;
use std::io::{BufRead, BufReader};
use std::os::unix::net::UnixStream;
use std::sync::{Arc, Mutex};

use cmux_server_core::install_key::{InstallKey, SystemRandom};
use serde_json::{Value, json};

use super::client::{CloudClient, Http};
use super::github::{TOKEN_PATH, TokenAsk, note_for, reply_for};
use super::github_minter::{Minter, answer};
use super::sender::Answer;
use super::wire::{Bound, Env};

const DEV: &str = "https://cmux-api-development.debussy.workers.dev";
const TEAM: &str = "team_t0000000000000000001";
const INSTALL: &str = "inst_v0000000000000000004";
const T0: u64 = 1_790_000_000_000;
const SECRET: &str = "ghs_fake_installation_token_0000000000";

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
            TOKEN_PATH => Ok(st.answers.pop_front().unwrap_or((500, json!({})))),
            _ => Ok((404, json!({}))),
        }
    }
}

fn client(fake: &Fake) -> CloudClient<Fake> {
    let bound = Bound {
        machine: "vm_m0000000000000000004".to_owned(),
        team: TEAM.to_owned(),
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
    CloudClient::new(fake.clone(), bound, key)
}

fn ask(perms: Value) -> TokenAsk {
    TokenAsk::from_json(
        &json!({ "repo": "manaflow-ai/cmux", "permissions": perms, "label": "git-credential" }),
    )
    .unwrap()
}

fn minted() -> (u16, Value) {
    (
        200,
        json!({ "token": SECRET, "expires_at": "2026-10-25T02:00:00Z", "repo": "manaflow-ai/cmux",
                "permissions": { "contents": "write" }, "token_id": "0123456789abcdef" }),
    )
}

#[test]
fn asks_the_token_route_as_the_vm_install_for_its_team() {
    let fake = Fake::default();
    fake.0.lock().unwrap().answers.push_back(minted());
    let mut c = client(&fake);
    let a = ask(json!({ "contents": "write" }));
    let answer = c.github_token(&a, T0);
    let reply = reply_for(&a, &answer);
    assert_eq!(reply["ok"], true);
    assert_eq!(reply["token"], SECRET);
    assert_eq!(reply["expires_at"], "2026-10-25T02:00:00Z");
    let st = fake.0.lock().unwrap();
    let (url, bearer, body) = st.seen.last().unwrap().clone();
    assert_eq!(url, format!("{DEV}{TOKEN_PATH}"));
    assert_eq!(bearer.as_deref(), Some("bearer-1"), "the vm install's bearer, minted by the agent");
    assert_eq!(
        body,
        json!({ "team": TEAM, "repo": "manaflow-ai/cmux", "permissions": { "contents": "write" }, "label": "git-credential" })
    );
    let note = note_for(&a, &reply);
    assert_eq!(note, "github token manaflow-ai/cmux contents:write: minted");
    assert!(!note.contains(SECRET));
}

#[test]
fn a_policy_refusal_is_passed_through_without_a_bearer_retry() {
    let fake = Fake::default();
    fake.0.lock().unwrap().answers.push_back((
        403,
        json!({ "error": { "code": "policy.denied", "message": "contents:write is over the grant" } }),
    ));
    let mut c = client(&fake);
    let a = ask(json!({ "contents": "write" }));
    let reply = reply_for(&a, &c.github_token(&a, T0));
    assert_eq!(
        reply,
        json!({ "ok": false, "status": 403, "error": { "code": "policy.denied", "message": "contents:write is over the grant" } })
    );
    let st = fake.0.lock().unwrap();
    assert_eq!(st.tokens_minted, 1);
    assert_eq!(st.seen.iter().filter(|s| s.0.ends_with(TOKEN_PATH)).count(), 1);
}

#[test]
fn a_stale_bearer_is_dropped_and_retried_once() {
    let fake = Fake::default();
    {
        let mut st = fake.0.lock().unwrap();
        st.answers.push_back((401, json!({ "error": { "code": "auth.required", "message": "" } })));
        st.answers.push_back(minted());
    }
    let mut c = client(&fake);
    let a = ask(json!({ "contents": "read" }));
    let reply = reply_for(&a, &c.github_token(&a, T0));
    assert_eq!(reply["ok"], true);
    let st = fake.0.lock().unwrap();
    assert_eq!(st.tokens_minted, 2);
    assert_eq!(st.seen.last().unwrap().1.as_deref(), Some("bearer-2"));
}

#[test]
fn rate_limits_and_transport_errors_become_refusals() {
    let limited = Answer::Http {
        status: 429,
        body: json!({ "error": { "code": "rate_limited", "message": "slow down" }, "retry_after": 30 }),
    };
    let a = ask(json!({ "contents": "read" }));
    let reply = reply_for(&a, &limited);
    assert_eq!(reply["error"]["code"], "rate_limited");
    assert_eq!(reply["retry_after"], 30);
    assert_eq!(reply_for(&a, &Answer::Transport)["error"]["code"], "integration.unreachable");
    // A 200 without a token is not a success.
    let empty = Answer::Http { status: 200, body: json!({ "expires_at": "x" }) };
    assert_eq!(reply_for(&a, &empty)["ok"], false);
    let unknown = Answer::Http { status: 502, body: json!({}) };
    assert_eq!(reply_for(&a, &unknown)["error"]["code"], "http.502");
}

#[test]
fn asks_are_checked_before_they_reach_the_api() {
    let bad = |v: Value| TokenAsk::from_json(&v).is_err();
    assert!(bad(json!({ "repo": "manaflow-ai", "permissions": { "contents": "read" } })));
    assert!(bad(json!({ "repo": "a/b/c", "permissions": { "contents": "read" } })));
    assert!(bad(json!({ "repo": "a/..", "permissions": { "contents": "read" } })));
    assert!(bad(json!({ "repo": "a/b", "permissions": {} })));
    assert!(bad(json!({ "repo": "a/b", "permissions": { "administration": "write" } })));
    assert!(bad(json!({ "repo": "a/b", "permissions": { "contents": "admin" } })));
    assert!(bad(
        json!({ "repo": "a/b", "permissions": { "contents": "read" }, "label": "has space" })
    ));
    let ok =
        TokenAsk::from_json(&json!({ "repo": "a-b/c.d_e", "permissions": { "metadata": "read" } }))
            .unwrap();
    assert_eq!(ok.label, None);
    // The line round-trips.
    let line: Value = serde_json::from_str(&ask(json!({ "contents": "write" })).to_line()).unwrap();
    assert_eq!(
        TokenAsk::from_json(&line["github_token"]).unwrap(),
        ask(json!({ "contents": "write" }))
    );
}

#[test]
fn an_auth_403_retries_with_a_fresh_bearer_once() {
    let fake = Fake::default();
    {
        let mut st = fake.0.lock().unwrap();
        st.answers
            .push_back((403, json!({ "error": { "code": "auth.forbidden", "message": "" } })));
        st.answers
            .push_back((403, json!({ "error": { "code": "auth.forbidden", "message": "" } })));
    }
    let mut c = client(&fake);
    let a = ask(json!({ "contents": "read" }));
    let reply = reply_for(&a, &c.github_token(&a, T0));
    assert_eq!(reply["error"]["code"], "auth.forbidden");
    let st = fake.0.lock().unwrap();
    assert_eq!(st.tokens_minted, 2, "one fresh bearer, then the answer stands");
    assert_eq!(st.seen.iter().filter(|s| s.0.ends_with(TOKEN_PATH)).count(), 2);
}

#[test]
fn a_200_must_carry_every_field_for_the_asked_repo() {
    let a = ask(json!({ "contents": "write" }));
    let full = || {
        json!({ "token": SECRET, "expires_at": "2026-10-25T02:00:00Z", "repo": "manaflow-ai/cmux",
                "permissions": { "contents": "write", "metadata": "read" } })
    };
    let reply = |body: Value| reply_for(&a, &Answer::Http { status: 200, body });
    assert_eq!(reply(full())["ok"], true);
    assert_eq!(reply(full())["permissions"]["metadata"], "read", "as granted");
    for key in ["token", "expires_at", "repo", "permissions"] {
        let mut body = full();
        body.as_object_mut().unwrap().remove(key);
        let out = reply(body);
        assert_eq!(out["error"]["code"], "integration.bad_answer", "{key}");
        assert!(!out.to_string().contains(SECRET));
    }
    let mut other = full();
    other["repo"] = json!("manaflow-ai/other");
    assert_eq!(reply(other)["ok"], false);
}

fn no_log(_: &str) {}
fn fixed_now() -> u64 {
    T0
}

/// One ask through the minter thread: the reply line on `ours`.
fn ask_minter(minter: &Minter<Fake>, a: Result<TokenAsk, String>) -> Value {
    let (ours, theirs) = UnixStream::pair().unwrap();
    ours.set_read_timeout(Some(std::time::Duration::from_secs(10))).unwrap();
    minter.ask(a, theirs);
    let mut line = String::new();
    BufReader::new(ours).read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap()
}

#[test]
fn the_minter_answers_each_connection_off_the_poll_loop() {
    let fake = Fake::default();
    fake.0.lock().unwrap().answers.extend([minted(), minted()]);
    let minter: Minter<Fake> = Minter::spawn(fixed_now, no_log).unwrap();
    let a = ask(json!({ "contents": "write" }));
    assert_eq!(ask_minter(&minter, Ok(a.clone()))["error"]["code"], "vm.unbound");
    assert_eq!(ask_minter(&minter, Err("bad".to_owned()))["error"]["code"], "request.invalid");
    minter.bound(client(&fake));
    // A client gone before its reply does not stop the minter.
    let (gone, theirs) = UnixStream::pair().unwrap();
    drop(gone);
    minter.ask(Ok(a.clone()), theirs);
    let reply = ask_minter(&minter, Ok(a));
    assert_eq!(reply["ok"], true);
    assert_eq!(reply["token"], SECRET);
}

#[test]
fn answer_logs_the_outcome_without_the_token() {
    use std::sync::atomic::{AtomicBool, Ordering};
    static LEAKED: AtomicBool = AtomicBool::new(false);
    fn check(line: &str) {
        if line.contains(SECRET) {
            LEAKED.store(true, Ordering::SeqCst);
        }
    }
    let fake = Fake::default();
    fake.0.lock().unwrap().answers.push_back(minted());
    let mut c = client(&fake);
    let reply = answer(Some(&mut c), Ok(ask(json!({ "contents": "write" }))), T0, check);
    assert_eq!(reply["token"], SECRET);
    assert!(!LEAKED.load(Ordering::SeqCst));
}
