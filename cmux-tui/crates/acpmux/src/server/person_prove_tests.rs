//! `_acpmux/person_prove` at any point of a challenged connection's life, and held while the
//! daemon has no key yet (`hub/person.rs`): after an update the app's pane may connect to the
//! restarted daemon before the app's `_acpmux/person_enroll` reaches it, and it must become the
//! person once the key lands, on the same connection, with no reconnect.

use super::*;
use crate::config::{Config, StoreMode};
use crate::hub::person::{PROOF_REFUSED, PROVES_PER_CONNECTION, REPROVE_FIELD, TRANSPORT_UNIX};
use std::time::Duration;

const KEY: &str = "5e1f0c2a9b8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f";
const OTHER: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

fn hub() -> Arc<Hub> {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(config, store)
}

struct Rpc {
    input: mpsc::Sender<String>,
    output: mpsc::Receiver<String>,
    next: i64,
    nonce: String,
    connection: String,
    reprove: bool,
}

impl Rpc {
    async fn connect(hub: &Arc<Hub>) -> Self {
        let (input, incoming) = mpsc::channel(64);
        let (output, outgoing) = mpsc::channel(64);
        tokio::spawn(serve_connection_with(hub.clone(), incoming, output, Origin::Local));
        let mut rpc = Self {
            input,
            output: outgoing,
            next: 0,
            nonce: String::new(),
            connection: String::new(),
            reprove: false,
        };
        let id = rpc
            .send(method::INITIALIZE, json!({"protocolVersion": 1, "clientCapabilities": {}}))
            .await;
        let reply = rpc.reply(id).await;
        let challenge = &reply["result"]["_meta"]["acpmux"]["personChallenge"];
        rpc.nonce = challenge["nonce"].as_str().unwrap().to_owned();
        rpc.connection = challenge["connection"].as_str().unwrap().to_owned();
        rpc.reprove = challenge[REPROVE_FIELD] == json!(true);
        rpc
    }

    fn proof(&self, key: &str) -> String {
        crate::hub::person::person_proof(key, TRANSPORT_UNIX, &self.nonce, &self.connection)
            .unwrap()
    }

    async fn send(&mut self, m: &str, params: Value) -> i64 {
        self.next += 1;
        self.input.send(Message::request(self.next, m, params).to_line()).await.unwrap();
        self.next
    }

    async fn reply(&mut self, id: i64) -> Value {
        // timeout: test-only bound; a lost reply fails the test instead of hanging it.
        tokio::time::timeout(Duration::from_secs(30), async {
            loop {
                let reply: Value =
                    serde_json::from_str(&self.output.recv().await.unwrap()).unwrap();
                if reply["id"] == id {
                    return reply;
                }
            }
        })
        .await
        .expect("RPC answered")
    }

    async fn prove(&mut self, proof: String) -> Value {
        let id = self.send(method::MUX_PERSON_PROVE, json!({"proof": proof})).await;
        self.reply(id).await
    }

    /// Whether the person gate lets this connection read a connection token (person only).
    async fn passes_person_gate(&mut self) -> bool {
        let id = self.send(method::MUX_CONNECTIONS_CREDENTIAL, json!({})).await;
        self.reply(id).await["error"]["data"]["reason"] != crate::hub::person::REASON
    }
}

fn proven(reply: &Value) -> bool {
    reply["result"]["person"] == json!(true)
}

#[tokio::test]
async fn the_challenge_says_a_proof_may_come_again() {
    let hub = hub();
    let rpc = Rpc::connect(&hub).await;
    assert!(rpc.reprove);
}

/// The update race: the pane's connection proves before the app's enroll reached the restarted
/// daemon. The prove waits for the key and then proves; nothing reconnects.
#[tokio::test]
async fn a_proof_before_the_enroll_proves_once_the_key_lands() {
    let hub = hub();
    let mut rpc = Rpc::connect(&hub).await;
    let id = rpc.send(method::MUX_PERSON_PROVE, json!({"proof": rpc.proof(KEY)})).await;
    // The prove is held: let it reach its wait, then the app's enroll lands.
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert!(!hub.person.has_key());
    hub.person.enroll(KEY, true).unwrap();
    let reply = rpc.reply(id).await;
    assert!(proven(&reply), "{reply}");
    assert!(rpc.passes_person_gate().await);
}

/// The key landed before the prove was read: the in-order check proves at once.
#[tokio::test]
async fn a_proof_after_the_enroll_proves_at_once() {
    let hub = hub();
    hub.person.enroll(KEY, true).unwrap();
    let mut rpc = Rpc::connect(&hub).await;
    let started = std::time::Instant::now();
    assert!(proven(&rpc.prove(rpc.proof(KEY)).await));
    assert!(started.elapsed() < Duration::from_secs(2));
}

/// A connection that proved nothing (the daemon held an earlier launch's key) proves on the same
/// connection after the new key's enroll, later in its life: no reconnect.
#[tokio::test]
async fn a_later_proof_on_the_same_connection_proves() {
    let hub = hub();
    hub.person.enroll(OTHER, true).unwrap();
    let mut rpc = Rpc::connect(&hub).await;
    let started = std::time::Instant::now();
    let refused = rpc.prove(rpc.proof(KEY)).await;
    assert_eq!(refused["error"]["data"]["reason"], PROOF_REFUSED, "{refused}");
    // A daemon with a key refuses a wrong proof at once: no hold.
    assert!(started.elapsed() < Duration::from_secs(2));
    assert!(!rpc.passes_person_gate().await);
    hub.person.enroll(KEY, true).unwrap();
    let reply = rpc.prove(rpc.proof(KEY)).await;
    assert!(proven(&reply), "{reply}");
    assert!(rpc.passes_person_gate().await);
}

/// The hold never weakens the binding: another connection's proof, or one under another key,
/// proves nothing once the key lands.
#[tokio::test]
async fn a_held_proof_still_binds_its_connection_and_key() {
    let hub = hub();
    let mut rpc = Rpc::connect(&hub).await;
    let other = Rpc::connect(&hub).await;
    let wrong_connection =
        rpc.send(method::MUX_PERSON_PROVE, json!({"proof": other.proof(KEY)})).await;
    let wrong_key = rpc.send(method::MUX_PERSON_PROVE, json!({"proof": rpc.proof(OTHER)})).await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    hub.person.enroll(KEY, true).unwrap();
    for id in [wrong_connection, wrong_key] {
        let reply = rpc.reply(id).await;
        assert_eq!(reply["error"]["data"]["reason"], PROOF_REFUSED, "{reply}");
    }
    assert!(!rpc.passes_person_gate().await);
}

/// No app ever keys the daemon: the held prove ends at its bound and proves nothing.
#[tokio::test(start_paused = true)]
async fn a_held_proof_ends_at_its_bound() {
    let hub = hub();
    let mut rpc = Rpc::connect(&hub).await;
    let reply = rpc.prove(rpc.proof(KEY)).await;
    assert_eq!(reply["error"]["data"]["reason"], PROOF_REFUSED, "{reply}");
    assert!(!rpc.passes_person_gate().await);
}

/// A connection gets a bounded number of tries: past them even the right proof proves nothing.
#[tokio::test]
async fn proofs_per_connection_are_bounded() {
    let hub = hub();
    hub.person.enroll(KEY, true).unwrap();
    let mut rpc = Rpc::connect(&hub).await;
    for _ in 0..PROVES_PER_CONNECTION {
        let reply = rpc.prove(rpc.proof(OTHER)).await;
        assert_eq!(reply["error"]["data"]["reason"], PROOF_REFUSED, "{reply}");
    }
    let reply = rpc.prove(rpc.proof(KEY)).await;
    assert_eq!(reply["error"]["data"]["reason"], PROOF_REFUSED, "{reply}");
    assert!(!rpc.passes_person_gate().await);
}

/// The first request is never a proof: a connection must take its challenge first.
#[tokio::test]
async fn a_proof_without_a_challenge_proves_nothing() {
    let hub = hub();
    hub.person.enroll(KEY, true).unwrap();
    let (input, incoming) = mpsc::channel(64);
    let (output, outgoing) = mpsc::channel(64);
    tokio::spawn(serve_connection_with(hub.clone(), incoming, output, Origin::Local));
    let mut rpc = Rpc {
        input,
        output: outgoing,
        next: 0,
        nonce: String::new(),
        connection: String::new(),
        reprove: false,
    };
    let reply = rpc.prove("00".repeat(32)).await;
    assert_eq!(reply["error"]["data"]["reason"], PROOF_REFUSED, "{reply}");
}
