//! A connection's token (`_acpmux/connections/credential`, `_acpmux/connections/chatgpt.token`)
//! is read only on a connection that proved the person, through the actual daemon dispatcher: an
//! agent's connection with a proven caller session, one whose token proves nothing, and a bare
//! unix client are all refused; the person's line gets past the gate.

use super::*;
use crate::config::{Config, StoreMode};
use std::time::Duration;

const KEY: &str = "5e1f0c2a9b8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f";
const SESSION: &str = "token-reader";

fn hub() -> Arc<Hub> {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let meta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": SESSION, "name": SESSION,
        "harness": "fake", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1
    }))
    .unwrap();
    store.save(&meta).unwrap();
    let hub = Hub::new(config, store);
    hub.person.install_spawn_key(KEY).unwrap();
    hub
}

enum Who {
    ProvenCaller,
    UnprovenCaller,
    Bare,
    Person,
}

struct Rpc(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Rpc {
    async fn connect(hub: &Arc<Hub>, who: &Who) -> Self {
        let (input, incoming) = mpsc::channel(64);
        let (output, outgoing) = mpsc::channel(64);
        tokio::spawn(serve_connection_with(hub.clone(), incoming, output, Origin::Local));
        let mut client = Self(input, outgoing, 0);
        let mut hello = json!({"protocolVersion": 1, "clientCapabilities": {}});
        let token = match who {
            Who::ProvenCaller => Some(crate::hub::person::caller_token(SESSION)),
            Who::UnprovenCaller => Some("not-this-sessions-token".to_owned()),
            Who::Bare | Who::Person => None,
        };
        if let Some(token) = token {
            hello["_meta"] =
                json!({"acpmux": {"callerSession": {"sessionId": SESSION, "token": token}}});
        }
        let reply = client.call(method::INITIALIZE, hello).await;
        assert!(reply.get("error").is_none(), "{reply}");
        let proven = matches!(who, Who::ProvenCaller).then_some(SESSION);
        assert_eq!(reply["result"]["_meta"]["acpmux"]["callerSessionId"].as_str(), proven);
        if matches!(who, Who::Person) {
            let challenge = &reply["result"]["_meta"]["acpmux"]["personChallenge"];
            let proof = crate::hub::person::person_proof(
                KEY,
                crate::hub::person::TRANSPORT_UNIX,
                challenge["nonce"].as_str().unwrap(),
                challenge["connection"].as_str().unwrap(),
            )
            .unwrap();
            let proved = client.call(method::MUX_PERSON_PROVE, json!({"proof": proof})).await;
            assert!(proved.get("error").is_none(), "{proved}");
        }
        client
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        // timeout: test-only bound; a lost reply fails the test instead of hanging it.
        tokio::time::timeout(Duration::from_secs(10), async {
            loop {
                let reply: Value = serde_json::from_str(&self.1.recv().await.unwrap()).unwrap();
                if reply["id"] == id {
                    return reply;
                }
            }
        })
        .await
        .expect("RPC answered")
    }
}

#[tokio::test]
async fn only_the_person_reads_a_connection_token() {
    let hub = hub();
    for m in [method::MUX_CONNECTIONS_CREDENTIAL, method::MUX_CONNECTIONS_CHATGPT_TOKEN] {
        for who in [Who::ProvenCaller, Who::UnprovenCaller, Who::Bare] {
            let mut rpc = Rpc::connect(&hub, &who).await;
            let reply = rpc.call(m, json!({})).await;
            assert_eq!(
                reply["error"]["data"]["reason"],
                crate::hub::person::REASON,
                "{m}: {reply}"
            );
        }
        // The person passes the gate: the handler itself answers (no id given, so it reads
        // nothing).
        let mut rpc = Rpc::connect(&hub, &Who::Person).await;
        let reply = rpc.call(m, json!({})).await;
        assert_ne!(reply["error"]["data"]["reason"], crate::hub::person::REASON, "{m}: {reply}");
        assert!(
            reply["error"]["message"].as_str().is_some_and(|e| e.contains("id is required")),
            "{m}: {reply}"
        );
    }
}
