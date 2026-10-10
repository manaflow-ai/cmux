//! Parity with the interim Bun agent (web/tests/vm-image-vm-agent.test.ts):
//! what the Cloud role sends, when, and to where, against a fake server
//! that answers with the cloud-vectors.json shapes.

use std::cell::RefCell;
use std::collections::VecDeque;
use std::rc::Rc;

use cmux_server_core::install_key::{SystemRandom, verify};
use serde_json::{Value, json};

use super::client::{BindResult, Http, MemoryStore, Store, bind_machine, ensure_install_key};
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
