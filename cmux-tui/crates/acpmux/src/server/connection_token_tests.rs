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
    hub_with_config(Config::default())
}

fn hub_with_config(mut config: Config) -> Arc<Hub> {
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

#[tokio::test]
async fn claude_token_add_registers_a_reference_whose_value_only_the_person_reads() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("setup-token");
    let token = "sk-ant-oat01-fixture";
    std::fs::write(&path, token).unwrap();
    crate::router_socket::owner_only(&path);
    let mut config = Config::default();
    config.path = Some(dir.path().join("config.json"));
    config.profile_sources = crate::config::ProfileSources::none();
    config.profile_sources.cmux_json = Some(dir.path().join("cmux.json"));
    let hub = hub_with_config(config);
    let mut cli = Rpc::connect(&hub, &Who::Bare).await;
    let rejected =
        cli.call(method::MUX_CONNECTIONS_CLAUDE_TOKEN_ADD, json!({"secret": token})).await;
    assert_eq!(rejected["error"]["data"]["reason"], "route.secret_inline");
    let added = cli
        .call(
            method::MUX_CONNECTIONS_CLAUDE_TOKEN_ADD,
            json!({
                "secret": format!("file:{}", path.display()), "label": "Work",
            }),
        )
        .await;
    let row = added["result"]["connections"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["id"] == "claude-token")
        .unwrap();
    assert_eq!(row["label"], "Work");
    assert_eq!(row["serves_cloud"], true);
    assert!(!added.to_string().contains(token));

    let request = json!({"id": "claude-token"});
    let rejected = cli.call(method::MUX_CONNECTIONS_CREDENTIAL, request.clone()).await;
    assert_eq!(rejected["error"]["data"]["reason"], crate::hub::person::REASON);
    let mut person = Rpc::connect(&hub, &Who::Person).await;
    let credential = person.call(method::MUX_CONNECTIONS_CREDENTIAL, request).await;
    assert_eq!(credential["result"]["kind"], "claude-token");
    assert_eq!(credential["result"]["env"], json!({"ANTHROPIC_AUTH_TOKEN": token}));
}

#[tokio::test]
async fn chatgpt_device_rpc_requires_person_proof() {
    let hub = hub();
    for method in [
        method::MUX_CONNECTIONS_CHATGPT_DEVICE_BEGIN,
        method::MUX_CONNECTIONS_CHATGPT_DEVICE_WAIT,
        method::MUX_CONNECTIONS_CHATGPT_DEVICE_CANCEL,
    ] {
        for who in [Who::ProvenCaller, Who::UnprovenCaller, Who::Bare] {
            let mut rpc = Rpc::connect(&hub, &who).await;
            let reply = rpc.call(method, json!({})).await;
            assert_eq!(reply["error"]["data"]["reason"], crate::hub::person::REASON);
        }
    }
    let mut rpc = Rpc::connect(&hub, &Who::Person).await;
    for method in
        [method::MUX_CONNECTIONS_CHATGPT_DEVICE_WAIT, method::MUX_CONNECTIONS_CHATGPT_DEVICE_CANCEL]
    {
        let reply = rpc.call(method, json!({"attempt": "no-such-attempt"})).await;
        assert_eq!(reply["error"]["data"]["reason"], "chatgpt.unknown_attempt");
    }
}

#[tokio::test]
async fn subscription_device_methods_require_person_proof() {
    let hub = hub();
    for method in [
        method::MUX_CONNECTIONS_SUBSCRIPTION_BEGIN,
        method::MUX_CONNECTIONS_SUBSCRIPTION_WAIT,
        method::MUX_CONNECTIONS_SUBSCRIPTION_CANCEL,
    ] {
        for who in [Who::ProvenCaller, Who::UnprovenCaller, Who::Bare] {
            let mut rpc = Rpc::connect(&hub, &who).await;
            let reply = rpc.call(method, json!({})).await;
            assert_eq!(reply["error"]["data"]["reason"], crate::hub::person::REASON);
        }
        let mut rpc = Rpc::connect(&hub, &Who::Person).await;
        let reply = rpc.call(method, json!({})).await;
        assert_ne!(reply["error"]["data"]["reason"], crate::hub::person::REASON);
        assert!(reply["error"].is_object());
    }
}
