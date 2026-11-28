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
async fn a_cloud_key_is_checked_before_the_broker_relies_on_the_guest_to_accept_it() {
    let home = tempfile::tempdir().unwrap();
    let path = home.path().join("google-key");
    let invalid = "fixture!key";
    std::fs::write(&path, invalid).unwrap();
    crate::private_file::owner_only(&path);
    let mut config = Config::default();
    config.path = Some(home.path().join("config.json"));
    config.profile_sources = crate::config::ProfileSources::none();
    config.profile_sources.cmux_json = Some(home.path().join("cmux.json"));
    let (routes, _) = crate::routes::places(&config);
    let (id, _) = super::connections::add_key(
        routes.as_deref(),
        home.path(),
        "google",
        &format!("file:{}", path.display()),
        None,
        &config.profile_sources,
        Some(true),
    )
    .unwrap();
    let hub = hub_with_config(config);
    let mut rpc = Rpc::connect(&hub, &Who::Person).await;
    let read = rpc.call(method::MUX_CONNECTIONS_CREDENTIAL, json!({"id": id})).await;
    assert_eq!(read["error"]["data"]["reason"], "credentials.invalid");
    assert!(!read.to_string().contains(invalid));
}

#[tokio::test]
async fn new_keys_wait_for_cloud_opt_in_and_openrouter_never_delivers() {
    let home = tempfile::tempdir().unwrap();
    let path = home.path().join("model-key");
    let fixture = "fixture-api-key";
    std::fs::write(&path, fixture).unwrap();
    crate::private_file::owner_only(&path);
    let reference = format!("file:{}", path.display());
    let mut config = Config::default();
    config.path = Some(home.path().join("config.json"));
    config.profile_sources = crate::config::ProfileSources::none();
    config.profile_sources.cmux_json = Some(home.path().join("cmux.json"));
    let hub = hub_with_config(config);
    let mut rpc = Rpc::connect(&hub, &Who::Person).await;

    for (provider, cloud) in [("google", None), ("openrouter", Some(true))] {
        let id = format!("{provider}-key");
        let mut params = json!({"provider": provider, "secret": reference});
        if let Some(cloud) = cloud {
            params["servesCloud"] = json!(cloud);
        }
        let added = rpc.call(method::MUX_CONNECTIONS_KEY_ADD, params).await;
        let row = added["result"]["connections"]
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row["id"] == id)
            .unwrap();
        assert_eq!(row["serves_cloud"], false);
        let model = if provider == "openrouter" { "openrouter/default" } else { "default" };
        let request = json!({"id": id, "model": model});
        let refused = rpc.call(method::MUX_CONNECTIONS_CREDENTIAL, request.clone()).await;
        assert_eq!(refused["error"]["data"]["reason"], "connections.not_cloud");
        assert!(!refused.to_string().contains(fixture));
        if provider == "google" {
            let enabled = rpc
                .call(
                    method::MUX_ACCOUNT_SET,
                    json!({"id": id, "instance": row["credential_instance"], "cloudUse": true,
                           "keyRevision": row["key_revision"]}),
                )
                .await;
            assert!(enabled.get("error").is_none(), "{enabled}");
            let credential = rpc.call(method::MUX_CONNECTIONS_CREDENTIAL, request).await;
            assert_eq!(credential["result"]["env"], json!({"GEMINI_API_KEY": fixture}));
        }
    }
}

#[tokio::test]
async fn a_cloud_toggle_cannot_authorize_a_new_key_at_the_same_route_id() {
    let home = tempfile::tempdir().unwrap();
    let mut config = Config::default();
    config.path = Some(home.path().join("config.json"));
    config.profile_sources = crate::config::ProfileSources::none();
    config.profile_sources.cmux_json = Some(home.path().join("cmux.json"));
    let hub = hub_with_config(config);
    let mut rpc = Rpc::connect(&hub, &Who::Person).await;
    let id = "google-key";
    let identity = |reply: &Value| {
        let row = reply["result"]["connections"]
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row["id"] == id)
            .unwrap();
        let instance = row["credential_instance"].as_str().unwrap().to_owned();
        let revision = row["key_revision"].as_str().unwrap().to_owned();
        (instance, revision)
    };
    let original = rpc
        .call(
            method::MUX_CONNECTIONS_KEY_ADD,
            json!({"provider": "google", "secret": "env:ORIGINAL"}),
        )
        .await;
    let (instance, revision) = identity(&original);
    let removed =
        rpc.call(method::MUX_CONNECTIONS_REMOVE, json!({"id": id, "instance": instance})).await;
    assert!(removed.get("error").is_none(), "{removed}");
    let replacement = rpc
        .call(
            method::MUX_CONNECTIONS_KEY_ADD,
            json!({"provider": "google", "secret": "env:REPLACEMENT"}),
        )
        .await;
    let (new_instance, new_revision) = identity(&replacement);
    assert_ne!(instance, new_instance);

    for change in [
        json!({"id": id, "cloudUse": true, "keyRevision": new_revision}),
        json!({"id": id, "instance": instance, "cloudUse": true, "keyRevision": new_revision}),
        json!({"id": id, "instance": new_instance, "cloudUse": true}),
        json!({"id": id, "instance": new_instance, "servesCloud": true}),
    ] {
        let refused = rpc.call(method::MUX_ACCOUNT_SET, change).await;
        assert!(refused.get("error").is_some(), "{refused}");
    }
    assert_ne!(revision, new_revision);
    let read = rpc.call(method::MUX_CONNECTIONS_CREDENTIAL, json!({"id": id})).await;
    assert_eq!(read["error"]["data"]["reason"], "connections.not_cloud");
    let enabled = rpc
        .call(
            method::MUX_ACCOUNT_SET,
            json!({"id": id, "instance": new_instance, "cloudUse": true, "keyRevision": new_revision}),
        )
        .await;
    assert!(enabled.get("error").is_none(), "{enabled}");
}

#[tokio::test]
async fn a_cloud_toggle_cannot_authorize_a_key_replaced_in_place() {
    let home = tempfile::tempdir().unwrap();
    let mut config = Config::default();
    config.path = Some(home.path().join("config.json"));
    config.profile_sources = crate::config::ProfileSources::none();
    config.profile_sources.cmux_json = Some(home.path().join("cmux.json"));
    let hub = hub_with_config(config);
    let mut rpc = Rpc::connect(&hub, &Who::Person).await;
    let id = "google-key";
    let row = |reply: &Value| {
        reply["result"]["connections"]
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row["id"] == id)
            .unwrap()
            .clone()
    };

    let original = rpc
        .call(
            method::MUX_CONNECTIONS_KEY_ADD,
            json!({"provider": "google", "secret": "env:ORIGINAL", "servesCloud": true}),
        )
        .await;
    let original = row(&original);
    assert_eq!(original["serves_cloud"], true);
    let replacement = rpc
        .call(
            method::MUX_CONNECTIONS_KEY_ADD,
            json!({"provider": "google", "secret": "env:REPLACEMENT", "replace": id,
                   "replaceInstance": original["credential_instance"]}),
        )
        .await;
    let replaced_state = replacement["result"].clone();
    let replacement = row(&replacement);
    assert_eq!(replacement["serves_cloud"], false);
    assert_ne!(replacement["credential_instance"], original["credential_instance"]);
    assert_ne!(replacement["key_revision"], original["key_revision"]);
    assert_eq!(
        replaced_state["disconnected_credentials"][id],
        json!([original["credential_instance"]])
    );

    for instance in [&original["credential_instance"], &replacement["credential_instance"]] {
        let refused = rpc
            .call(
                method::MUX_ACCOUNT_SET,
                json!({"id": id, "instance": instance, "cloudUse": true,
                       "keyRevision": original["key_revision"]}),
            )
            .await;
        assert!(refused.get("error").is_some(), "{refused}");
    }
    let read = rpc.call(method::MUX_CONNECTIONS_CREDENTIAL, json!({"id": id})).await;
    assert_eq!(read["error"]["data"]["reason"], "connections.not_cloud");
    let enabled = rpc
        .call(
            method::MUX_ACCOUNT_SET,
            json!({"id": id, "instance": replacement["credential_instance"], "cloudUse": true,
                   "keyRevision": replacement["key_revision"]}),
        )
        .await;
    assert!(enabled.get("error").is_none(), "{enabled}");
}

#[tokio::test]
async fn an_in_flight_cloud_start_cannot_use_a_replaced_key_after_new_consent() {
    let home = tempfile::tempdir().unwrap();
    let mut config = Config::default();
    config.path = Some(home.path().join("config.json"));
    config.profile_sources = crate::config::ProfileSources::none();
    config.profile_sources.cmux_json = Some(home.path().join("cmux.json"));
    let hub = hub_with_config(config);
    let mut rpc = Rpc::connect(&hub, &Who::Person).await;
    let reference = |name: &str| {
        let path = home.path().join(name);
        std::fs::write(&path, name).unwrap();
        crate::private_file::owner_only(&path);
        format!("file:{}", path.display())
    };
    for (provider, variable) in [("google", "GEMINI_API_KEY"), ("xai", "XAI_API_KEY")] {
        let id = format!("{provider}-key");
        let row = |reply: &Value| {
            reply["result"]["connections"]
                .as_array()
                .unwrap()
                .iter()
                .find(|row| row["id"] == id)
                .unwrap()
                .clone()
        };
        let original = rpc
            .call(
                method::MUX_CONNECTIONS_KEY_ADD,
                json!({"provider": provider, "secret": reference("original-fixture"), "servesCloud": true}),
            )
            .await;
        let picked = row(&original);
        assert_eq!(picked["serves_cloud"], true);
        let replacement = rpc
            .call(
                method::MUX_CONNECTIONS_KEY_ADD,
                json!({"provider": provider, "secret": reference("replacement-fixture"), "replace": id,
                       "replaceInstance": picked["credential_instance"]}),
            )
            .await;
        let replacement = row(&replacement);
        let enabled = rpc
            .call(
                method::MUX_ACCOUNT_SET,
                json!({"id": id, "instance": replacement["credential_instance"], "cloudUse": true,
                       "keyRevision": replacement["key_revision"]}),
            )
            .await;
        assert!(enabled.get("error").is_none());
        let credential = rpc.call(method::MUX_CONNECTIONS_CREDENTIAL, json!({"id": id})).await;
        let delivered = &credential["result"];
        assert_eq!(delivered["env"][variable], "replacement-fixture");
        // The app uses these same instances to validate the choice it captured before copying.
        assert!(delivered["credential_instance"].is_string());
        assert_eq!(delivered["credential_instance"], replacement["credential_instance"]);
        assert_ne!(delivered["credential_instance"], picked["credential_instance"]);
    }
}

#[tokio::test]
async fn the_daemon_schema_supplies_every_field_needed_to_disconnect() {
    let dir = tempfile::tempdir().unwrap();
    let mut config = Config::default();
    config.path = Some(dir.path().join("config.json"));
    config.profile_sources = crate::config::ProfileSources::none();
    config.profile_sources.cmux_json = Some(dir.path().join("cmux.json"));
    let hub = hub_with_config(config);
    let mut person = Rpc::connect(&hub, &Who::Person).await;
    let added = person
        .call(
            method::MUX_CONNECTIONS_KEY_ADD,
            json!({"provider": "google", "secret": "env:FIXTURE_KEY"}),
        )
        .await;
    assert!(added.get("error").is_none(), "{added}");
    let listed = person.call(method::MUX_CONNECTIONS, json!({})).await;
    let row = listed["result"]["connections"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["id"] == "google-key")
        .unwrap();
    let schema = person.call(method::MUX_SCHEMA, json!({})).await;
    let documented =
        schema["result"]["methods"][method::MUX_CONNECTIONS_REMOVE]["params"].as_object().unwrap();
    let fields = json!({"id": row["id"], "instance": row["credential_instance"].as_str().unwrap()});
    let params = documented.keys().map(|field| (field.clone(), fields[field].clone())).collect();
    let removed = person.call(method::MUX_CONNECTIONS_REMOVE, Value::Object(params)).await;
    assert!(removed.get("error").is_none(), "{removed}");
    assert!(
        !removed["result"]["connections"]
            .as_array()
            .unwrap()
            .iter()
            .any(|row| row["id"] == "google-key")
    );
}

#[tokio::test]
async fn claude_token_add_registers_a_reference_whose_value_only_the_person_reads() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("setup-token");
    let token = "sk-ant-oat01-fixture";
    std::fs::write(&path, token).unwrap();
    crate::private_file::owner_only(&path);
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
    let receipt = &added["result"]["added_connection"];
    assert_eq!(receipt["id"], row["id"]);
    assert!(receipt["credential_instance"].as_str().is_some());
    assert_eq!(receipt["credential_instance"], row["credential_instance"]);
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
