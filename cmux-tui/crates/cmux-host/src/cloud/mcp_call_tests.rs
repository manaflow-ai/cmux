//! `mcp.call` on the agent socket (`mcp_call.rs`): the message check, and the request the agent
//! sends for it (route, bearer, headers), against a fake platform. No reply carries the bearer.

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

use cmux_server_core::install_key::{InstallKey, SystemRandom};
use serde_json::{Value, json};

use super::client::{CloudClient, Http};
use super::github_minter::answer_mcp;
use super::mcp_call::{MAX_BODY, McpCall, check_call};
use super::wire::{Bound, Env};

const DEV: &str = "https://cmux-api-development.debussy.workers.dev";
const INSTALL: &str = "inst_v0000000000000000004";
const T0: u64 = 1_790_000_000_000;

#[derive(Clone, Debug)]
struct Sent {
    method: String,
    url: String,
    bearer: Option<String>,
    headers: Vec<(String, String)>,
    body: Option<Value>,
}

#[derive(Default)]
struct State {
    sent: Vec<Sent>,
    minted: usize,
    answers: VecDeque<(u16, Value)>,
}

#[derive(Clone, Default)]
struct Fake(Arc<Mutex<State>>);

impl Http for Fake {
    fn post(
        &self,
        url: &str,
        _body: &Value,
        _bearer: Option<&str>,
    ) -> Result<(u16, Value), String> {
        let mut st = self.0.lock().unwrap();
        match url.strip_prefix(DEV).unwrap_or("") {
            "/v1/auth/challenge" => Ok((
                200,
                json!({ "install": INSTALL, "nonce": "n-1", "message_prefix": format!("cmux-auth-v1\ndevelopment\n{INSTALL}\n") }),
            )),
            "/v1/auth/token" => {
                st.minted += 1;
                let n = st.minted;
                Ok((
                    200,
                    json!({ "access_token": format!("bearer-{n}"), "token_type": "Bearer", "expires_at": T0 + 600_000, "install": INSTALL, "user": "user_u0000000000000000001", "grant": "grant_v000000000000000004", "team": "team_t0000000000000000001" }),
                ))
            }
            _ => Ok((404, json!({}))),
        }
    }

    fn send(
        &self,
        method: &str,
        url: &str,
        body: Option<&Value>,
        bearer: Option<&str>,
        headers: &[(&str, &str)],
    ) -> Result<(u16, Value), String> {
        let mut st = self.0.lock().unwrap();
        st.sent.push(Sent {
            method: method.to_owned(),
            url: url.to_owned(),
            bearer: bearer.map(str::to_owned),
            headers: headers.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect(),
            body: body.cloned(),
        });
        st.answers.pop_front().ok_or_else(|| "no answer".to_owned())
    }
}

fn client(fake: &Fake) -> CloudClient<Fake> {
    let bound = Bound {
        machine: "vm_m0000000000000000004".to_owned(),
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
    CloudClient::new(fake.clone(), bound, key)
}

fn list() -> Value {
    json!({ "jsonrpc": "2.0", "id": 7, "method": "tools/list", "params": {} })
}

fn listed() -> (u16, Value) {
    (
        200,
        json!({ "jsonrpc": "2.0", "id": 7, "result": { "tools": [{ "name": "linear_search" }] } }),
    )
}

#[test]
fn every_method_the_bridge_sends_is_accepted() {
    for method in ["initialize", "notifications/initialized", "ping", "tools/list", "tools/call"] {
        let body = json!({ "jsonrpc": "2.0", "id": 1, "method": method });
        assert_eq!(check_call(&json!({ "body": body })), Ok(McpCall { body }), "{method}");
    }
}

#[test]
fn other_methods_shapes_and_sizes_are_refused() {
    for body in [
        json!({ "jsonrpc": "2.0", "id": 1, "method": "resources/list" }),
        json!({ "jsonrpc": "2.0", "id": 1, "method": "sampling/createMessage" }),
        json!({ "jsonrpc": "2.0", "id": 1 }),
        json!({ "jsonrpc": "1.0", "id": 1, "method": "tools/list" }),
        json!({ "id": 1, "method": "tools/list" }),
        json!([{ "jsonrpc": "2.0", "id": 1, "method": "tools/list" }]),
        json!("tools/list"),
        Value::Null,
    ] {
        assert!(check_call(&json!({ "body": body })).is_err(), "{body} was accepted");
    }
    assert!(check_call(&json!({})).is_err());
    let big = "x".repeat(MAX_BODY);
    let body = json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": { "q": big } });
    assert!(check_call(&json!({ "body": body })).unwrap_err().contains("60 KiB"));
}

#[test]
fn posts_the_message_to_the_platform_mcp_route_as_the_vm_install() {
    let fake = Fake::default();
    fake.0.lock().unwrap().answers.push_back(listed());
    let mut c = client(&fake);
    let reply = answer_mcp(Some(&mut c), check_call(&json!({ "body": list() })), T0);
    assert_eq!(reply["ok"], true);
    assert_eq!(reply["status"], 200);
    assert_eq!(reply["body"]["result"]["tools"][0]["name"], "linear_search");
    let st = fake.0.lock().unwrap();
    let sent = st.sent.last().unwrap().clone();
    assert_eq!(sent.method, "POST");
    assert_eq!(sent.url, format!("{}/mcp", Env::Dev.platform_origin()));
    assert_eq!(sent.bearer.as_deref(), Some("bearer-1"), "the vm install's bearer, minted here");
    assert_eq!(sent.body, Some(list()));
    let header = |name: &str| sent.headers.iter().find(|(k, _)| k == name).map(|(_, v)| v.clone());
    assert_eq!(header("accept").as_deref(), Some("application/json, text/event-stream"));
    assert_eq!(header("mcp-protocol-version").as_deref(), Some("2025-06-18"));
    assert!(!reply.to_string().contains("bearer-1"), "the reply never holds the bearer");
}

#[test]
fn a_401_mints_a_fresh_bearer_and_retries_once() {
    let fake = Fake::default();
    {
        let mut st = fake.0.lock().unwrap();
        st.answers.push_back((401, json!({ "error": "unauthorized" })));
        st.answers.push_back(listed());
    }
    let mut c = client(&fake);
    let reply = answer_mcp(Some(&mut c), check_call(&json!({ "body": list() })), T0);
    assert_eq!(reply["status"], 200);
    let st = fake.0.lock().unwrap();
    let bearers: Vec<_> = st.sent.iter().map(|s| s.bearer.clone().unwrap_or_default()).collect();
    assert_eq!(bearers, ["bearer-1", "bearer-2"]);
    for bearer in &bearers {
        assert!(!reply.to_string().contains(bearer.as_str()));
    }
}

#[test]
fn a_second_401_is_the_answer_and_a_dead_transport_is_unreachable() {
    let fake = Fake::default();
    {
        let mut st = fake.0.lock().unwrap();
        st.answers.push_back((401, json!({})));
        st.answers.push_back((401, json!({})));
    }
    let mut c = client(&fake);
    let reply = answer_mcp(Some(&mut c), check_call(&json!({ "body": list() })), T0);
    assert_eq!(reply["status"], 401);
    assert_eq!(fake.0.lock().unwrap().sent.len(), 2);
    let reply = answer_mcp(Some(&mut c), check_call(&json!({ "body": list() })), T0);
    assert_eq!(reply["ok"], false);
    assert_eq!(reply["error"]["code"], "integration.unreachable");
}

#[test]
fn a_bad_message_or_an_unbound_machine_is_refused_before_any_request() {
    let fake = Fake::default();
    let mut c = client(&fake);
    let bad = check_call(&json!({ "body": { "jsonrpc": "2.0", "method": "resources/read" } }));
    let reply = answer_mcp(Some(&mut c), bad, T0);
    assert_eq!(reply["error"]["code"], "request.invalid");
    let reply = answer_mcp::<Fake>(None, check_call(&json!({ "body": list() })), T0);
    assert_eq!(reply["error"]["code"], "vm.unbound");
    assert!(fake.0.lock().unwrap().sent.is_empty());
}
