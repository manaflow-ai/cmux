//! The cmux sign-in the app lends for GitHub App tokens (`src/github_app_token.rs`): only the
//! app's own unix-socket connection, which proved the person, lends it or takes it back, and no
//! answer holds it.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process starts no agent.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

/// By name, so the same test runs, and fails, on a build from before the lease.
const APP_LEASE: &str = "_acpmux/github_app_lease";
const PERSON_KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const BEARER: &str = "cmux-install-token";

fn hub() -> Arc<Hub> {
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

/// A unix-socket client of `hub` (the app's own call), or one from `origin`.
struct C(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl C {
    async fn new(hub: &Arc<Hub>, origin: Origin) -> Self {
        Self::open(hub, origin).await.0
    }

    /// A connection that has sent nothing yet.
    fn raw(hub: &Arc<Hub>, origin: Origin) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
        C(in_tx, out_rx, 0)
    }

    async fn open(hub: &Arc<Hub>, origin: Origin) -> (Self, Value) {
        let mut c = Self::raw(hub, origin);
        let init = c
            .call(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "t"}}))
            .await
            .unwrap();
        (c, init)
    }

    /// The app's own unix-socket connection, which proved the person (`hub/person.rs`).
    async fn app(hub: &Arc<Hub>) -> Self {
        let _ = hub.person.install_spawn_key(PERSON_KEY);
        let (mut c, init) = Self::open(hub, Origin::Local).await;
        let challenge = &init["_meta"]["acpmux"]["personChallenge"];
        let proof = acpmux::hub::person::person_proof(
            PERSON_KEY,
            acpmux::hub::person::TRANSPORT_UNIX,
            challenge["nonce"].as_str().unwrap(),
            challenge["connection"].as_str().unwrap(),
        )
        .unwrap();
        c.call("_acpmux/person_prove", json!({"proof": proof})).await.unwrap();
        c
    }

    async fn call(&mut self, m: &str, params: Value) -> Result<Value, Value> {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .expect("timeout")
                .expect("closed");
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return match v.get("error") {
                    Some(e) => Err(e.clone()),
                    None => Ok(v["result"].clone()),
                };
            }
        }
    }
}

#[tokio::test]
async fn only_the_apps_own_connection_lends_its_sign_in_and_no_answer_holds_it() {
    let a = hub();
    let mut app = C::app(&a).await;
    let lend = |seq: u64| {
        json!({"seq": seq, "origin": "https://cloud-api.cmux.dev", "bearer": BEARER,
            "team": "team_0123456789abcdef0123", "expiresAtMs": acpmux::store::now_ms() + 600_000})
    };
    assert_eq!(app.call(APP_LEASE, lend(5)).await.unwrap(), json!({"lent": true}));

    // Not another process on the socket that did not prove the person, nor the app's pane, a
    // page or a peer over the WebSocket: none of them lends a sign-in or takes it back.
    let mut other = C::new(&a, Origin::Local).await;
    let e = other.call(APP_LEASE, lend(6)).await.unwrap_err();
    assert!(e["message"].as_str().unwrap_or("").contains("only from the cmux app"), "{e}");
    let clear = json!({"seq": 6, "clear": true});
    assert!(other.call(APP_LEASE, clear.clone()).await.is_err());
    for origin in [Origin::LocalApp, Origin::Web, Origin::Peer] {
        let mut c = C::raw(&a, origin);
        let e = c.call(APP_LEASE, lend(6)).await.unwrap_err();
        assert!(
            e["message"].as_str().unwrap_or("").contains("only over the local unix socket"),
            "{e}"
        );
        assert!(c.call(APP_LEASE, clear.clone()).await.is_err(), "{origin:?}");
    }

    // The app's own lend still holds, and an older call changes nothing.
    let stale = app.call(APP_LEASE, lend(4)).await.unwrap();
    assert_eq!(stale, json!({"lent": true, "stale": true, "seq": 5}));
    assert!(!stale.to_string().contains(BEARER));
    assert_eq!(app.call(APP_LEASE, clear).await.unwrap(), json!({"lent": false}));
    assert_eq!(app.call(APP_LEASE, lend(5)).await.unwrap()["stale"], true, "a late lend");
}
