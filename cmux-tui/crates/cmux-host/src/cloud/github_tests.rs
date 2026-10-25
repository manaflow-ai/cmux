//! The agent's side of a GitHub token ask against a fake Cloud API: the
//! request it sends (route, bearer, body), the reply line it builds, and
//! that neither the journal note nor a refusal carries a token.

use std::cell::RefCell;
use std::collections::VecDeque;
use std::rc::Rc;

use cmux_server_core::install_key::{InstallKey, SystemRandom};
use serde_json::{Value, json};

use super::client::{CloudClient, Http};
use super::github::{TOKEN_PATH, TokenAsk, note_for, reply_for};
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
struct Fake(Rc<RefCell<State>>);

impl Http for Fake {
    fn post(&self, url: &str, body: &Value, bearer: Option<&str>) -> Result<(u16, Value), String> {
        let mut st = self.0.borrow_mut();
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
    fake.0.borrow_mut().answers.push_back(minted());
    let mut c = client(&fake);
    let a = ask(json!({ "contents": "write" }));
    let answer = c.github_token(&a, T0);
    let reply = reply_for(&answer);
    assert_eq!(reply["ok"], true);
    assert_eq!(reply["token"], SECRET);
    assert_eq!(reply["expires_at"], "2026-10-25T02:00:00Z");
    let st = fake.0.borrow();
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
    fake.0.borrow_mut().answers.push_back((
        403,
        json!({ "error": { "code": "policy.denied", "message": "contents:write is over the grant" } }),
    ));
    let mut c = client(&fake);
    let reply = reply_for(&c.github_token(&ask(json!({ "contents": "write" })), T0));
    assert_eq!(
        reply,
        json!({ "ok": false, "status": 403, "error": { "code": "policy.denied", "message": "contents:write is over the grant" } })
    );
    let st = fake.0.borrow();
    assert_eq!(st.tokens_minted, 1);
    assert_eq!(st.seen.iter().filter(|s| s.0.ends_with(TOKEN_PATH)).count(), 1);
}

#[test]
fn a_stale_bearer_is_dropped_and_retried_once() {
    let fake = Fake::default();
    {
        let mut st = fake.0.borrow_mut();
        st.answers.push_back((401, json!({ "error": { "code": "auth.required", "message": "" } })));
        st.answers.push_back(minted());
    }
    let mut c = client(&fake);
    let reply = reply_for(&c.github_token(&ask(json!({ "contents": "read" })), T0));
    assert_eq!(reply["ok"], true);
    let st = fake.0.borrow();
    assert_eq!(st.tokens_minted, 2);
    assert_eq!(st.seen.last().unwrap().1.as_deref(), Some("bearer-2"));
}

#[test]
fn rate_limits_and_transport_errors_become_refusals() {
    let limited = Answer::Http {
        status: 429,
        body: json!({ "error": { "code": "rate_limited", "message": "slow down" }, "retry_after": 30 }),
    };
    let reply = reply_for(&limited);
    assert_eq!(reply["error"]["code"], "rate_limited");
    assert_eq!(reply["retry_after"], 30);
    assert_eq!(reply_for(&Answer::Transport)["error"]["code"], "integration.unreachable");
    // A 200 without a token is not a success.
    let empty = Answer::Http { status: 200, body: json!({ "expires_at": "x" }) };
    assert_eq!(reply_for(&empty)["ok"], false);
    let unknown = Answer::Http { status: 502, body: json!({}) };
    assert_eq!(reply_for(&unknown)["error"]["code"], "http.502");
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
