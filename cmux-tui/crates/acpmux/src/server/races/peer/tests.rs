use super::*;
use crate::config::{Config, StoreMode};
use crate::rpc::Message;
use crate::server::{WsAuth, peer_auth, serve_connection_authed};
use std::time::Duration;
use tokio::sync::mpsc;

const KEY: &str = "5e1f0c2a9b8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f";
const PARENT: &str = "parent-id";

fn race() -> Value {
    json!({"id":"race-1", "parent":PARENT, "prompt":"task", "state":"completed",
        "candidates":[{"id":"c1", "target":{"harness":"fake"}, "state":"completed",
            "sessionId":"winner-id"}], "reviewer":{"harness":"fake"},
        "reviewerSessionId":"reviewer-id", "winnerId":"c1", "reason":"best result",
        "createdAt":1, "updatedAt":2, "local":true})
}

fn hub() -> Arc<Hub> {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    for id in [PARENT, "other-id"] {
        let meta = serde_json::from_value(json!({
            "schema":crate::store::META_SCHEMA, "id":id, "name":format!("named-{id}"),
            "harness":"fake", "cwd":"/tmp", "status":"idle", "createdAt":1,"updatedAt":1,
            "races":if id == PARENT { vec![race()] } else { vec![] }
        }))
        .unwrap();
        store.save(&meta).unwrap();
    }
    let hub = Hub::new(config, store);
    hub.person.install_spawn_key(KEY).unwrap();
    hub
}

struct Rpc {
    input: mpsc::Sender<String>,
    output: mpsc::Receiver<String>,
    id: i64,
    task: tokio::task::JoinHandle<()>,
}

impl Drop for Rpc {
    fn drop(&mut self) {
        self.task.abort();
    }
}

impl Rpc {
    async fn connect(hub: &Arc<Hub>, origin: Origin, auth: ConnAuth, person: bool) -> Self {
        let (input, incoming) = mpsc::channel(64);
        let (outgoing, output) = mpsc::channel(64);
        let task =
            tokio::spawn(serve_connection_authed(hub.clone(), incoming, outgoing, origin, auth));
        let mut rpc = Self { input, output, id: 0, task };
        let mut init = json!({"protocolVersion":1});
        if origin == Origin::Local && !person {
            init["_meta"] = json!({"acpmux":{"callerSession":{
                "sessionId":PARENT, "token":"unproven-caller"
            }}});
        }
        let hello = rpc.call(method::INITIALIZE, init).await;
        assert!(hello.get("error").is_none(), "{hello}");
        if person {
            let challenge = &hello["result"]["_meta"]["acpmux"]["personChallenge"];
            let proof = crate::hub::person::person_proof(
                KEY,
                if origin == Origin::LocalApp { "app" } else { "unix" },
                challenge["nonce"].as_str().unwrap(),
                challenge["connection"].as_str().unwrap(),
            )
            .unwrap();
            let result = rpc.call(method::MUX_PERSON_PROVE, json!({"proof":proof})).await;
            assert!(result.get("error").is_none(), "{result}");
        }
        rpc
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.id += 1;
        self.input.send(Message::request(self.id, m, params).to_line()).await.unwrap();
        tokio::time::timeout(Duration::from_secs(10), async {
            loop {
                let value: Value =
                    serde_json::from_str(&self.output.recv().await.unwrap()).unwrap();
                if value["id"] == self.id {
                    return value;
                }
            }
        })
        .await
        .expect("RPC answered")
    }
}

#[test]
fn race_owner_assertion_is_bound_to_method_parent_and_peer_owner() {
    let p = forwarded(&json!({}), PARENT, method::MUX_RACE_LIST);
    assert!(asserted(Origin::Peer, ConnAuth::PeerToken, method::MUX_RACE_LIST, &p));
    for origin in [Origin::Local, Origin::LocalApp, Origin::Web] {
        assert!(!asserted(origin, ConnAuth::PeerToken, method::MUX_RACE_LIST, &p));
    }
    for auth in [
        ConnAuth::None,
        ConnAuth::LocalSocket,
        ConnAuth::LocalApp,
        ConnAuth::ListenerToken,
        ConnAuth::Device,
        ConnAuth::ReadOnlyDevice,
    ] {
        assert!(!asserted(Origin::Peer, auth, method::MUX_RACE_LIST, &p));
    }
    for via in ["web", "device", "cloud-mobile"] {
        let mut p = p.clone();
        p["_meta"]["acpmux"]["via"] = json!(via);
        assert!(!asserted(Origin::Peer, ConnAuth::PeerToken, method::MUX_RACE_LIST, &p));
    }
    let mut wrong_parent = p.clone();
    wrong_parent["parent"] = json!("other-id");
    assert!(!asserted(Origin::Peer, ConnAuth::PeerToken, method::MUX_RACE_LIST, &wrong_parent));
    assert!(!asserted(Origin::Peer, ConnAuth::PeerToken, method::MUX_RACE_START, &p));
    let mut missing = p.clone();
    missing["_meta"]["acpmux"][FIELD] = Value::Null;
    assert!(!asserted(Origin::Peer, ConnAuth::PeerToken, method::MUX_RACE_LIST, &missing));
    let forged = json!({"parent":"wrong", "sessionId":"other-id", "cwd":"/", "prompt":"task",
        "_meta":{"acpmux":{"via":"web", FIELD:{"parent":"other-id"}, "personKey":"fake"}}});
    let clean = forwarded(&forged, PARENT, method::MUX_RACE_LIST);
    assert_eq!(clean, forwarded(&json!({"prompt":"task"}), PARENT, method::MUX_RACE_LIST));
}

#[tokio::test]
async fn race_owner_dispatch_accepts_only_the_exact_asserted_parent() {
    let hub = hub();
    let mut peer = Rpc::connect(&hub, Origin::Peer, ConnAuth::PeerToken, false).await;
    let bare = peer.call(method::MUX_RACE_LIST, json!({"parent":PARENT})).await;
    assert!(bare.get("error").is_some(), "peer token alone is not a race authorization: {bare}");
    let result = peer
        .call(method::MUX_RACE_LIST, forwarded(&json!({}), PARENT, method::MUX_RACE_LIST))
        .await;
    assert_eq!(result["result"]["races"][0]["id"], "race-1", "{result}");
    let other = peer
        .call(
            method::MUX_RACE_GET,
            forwarded(&json!({"raceId":"race-1"}), "other-id", method::MUX_RACE_GET),
        )
        .await;
    assert!(other["error"]["message"].as_str().unwrap().contains("not found under this parent"));
    for parent in ["parent", "named-parent-id"] {
        let result = peer
            .call(method::MUX_RACE_LIST, forwarded(&json!({}), parent, method::MUX_RACE_LIST))
            .await;
        assert!(result.get("error").is_some(), "mutable parent accepted: {result}");
    }
    for (origin, auth) in [
        (Origin::Local, ConnAuth::LocalSocket),
        (Origin::LocalApp, ConnAuth::LocalApp),
        (Origin::Web, ConnAuth::ListenerToken),
        (Origin::Peer, ConnAuth::Device),
        (Origin::Web, ConnAuth::ReadOnlyDevice),
    ] {
        let mut client = Rpc::connect(&hub, origin, auth, false).await;
        let result = client
            .call(method::MUX_RACE_LIST, forwarded(&json!({}), PARENT, method::MUX_RACE_LIST))
            .await;
        assert!(result.get("error").is_some(), "{origin:?}/{auth:?}: {result}");
        let remote = client
            .call(
                method::MUX_RACE_LIST,
                forwarded(&json!({}), "box/parent-id", method::MUX_RACE_LIST),
            )
            .await;
        assert!(remote.get("error").is_some(), "remote spoof accepted: {remote}");
    }
    for via in ["web", "device", "cloud-mobile"] {
        let mut params = forwarded(&json!({}), PARENT, method::MUX_RACE_LIST);
        params["_meta"]["acpmux"]["via"] = json!(via);
        let result = peer.call(method::MUX_RACE_LIST, params).await;
        assert!(result.get("error").is_some(), "{via}: {result}");
    }
}

#[test]
fn race_replies_and_events_qualify_only_session_routes() {
    let mut one = race();
    qualify_reply("box", &mut one);
    assert_eq!(one["parent"], "box/parent-id");
    assert_eq!(one["candidates"][0]["sessionId"], "box/winner-id");
    assert_eq!(one["reviewerSessionId"], "box/reviewer-id");
    assert_eq!(one["winnerId"], "c1");
    assert_eq!(one["id"], "race-1");
    let mut list = json!({"races":[race()]});
    qualify_reply("box", &mut list);
    assert_eq!(list["races"][0], one);
    let mut event = json!({"sessionId":PARENT, "kind":"race", "msg":race()});
    qualify_event("box", &mut event);
    assert_eq!(event["msg"], one);
    assert_eq!(event["sessionId"], PARENT); // The ordinary event envelope keeps its peer field.
    let mut unrelated = json!({"kind":"prompt", "msg":race()});
    let before = unrelated.clone();
    qualify_event("box", &mut unrelated);
    assert_eq!(unrelated, before);
}

#[tokio::test]
async fn person_race_reads_cross_a_real_peer_link_with_qualified_winner_and_events() {
    let remote = hub();
    let local = hub(); // Same raw ids on both machines must not select the local race.
    let home = std::env::temp_dir().join(format!("acpmux-race-peer-{}", uuid::Uuid::now_v7()));
    let auth = Arc::new(peer_auth::PeerAuth::create(&home).unwrap());
    let peer_token = std::fs::read_to_string(auth.path()).unwrap();
    let listener = crate::server::bind_ws("127.0.0.1:0").await.unwrap();
    let url = format!("ws://{}", listener.local_addr().unwrap());
    let served = tokio::spawn(crate::server::serve_ws_with(
        remote.clone(),
        listener,
        "race-test-token".into(),
        WsAuth { local_app: None, peer: Some(auth) },
    ));
    let connected = local
        .add_peer("box", &url, Some("race-test-token".into()), Some(peer_token.trim().into()), true)
        .await
        .unwrap();
    assert!(local.resolve_remote("box/parent-id").is_some(), "{connected}");
    let mut person = Rpc::connect(&local, Origin::LocalApp, ConnAuth::LocalApp, true).await;
    let result = person.call(method::MUX_RACE_LIST, json!({"parent":"box/parent-id"})).await;
    assert_eq!(result["result"]["races"][0]["parent"], "box/parent-id", "{result}");
    assert_eq!(result["result"]["races"][0]["candidates"][0]["sessionId"], "box/winner-id");
    let parent = remote.resolve(PARENT).unwrap();
    remote.append(&parent, "mux", "race", race());
    let event = tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            let v: Value = serde_json::from_str(&person.output.recv().await.unwrap()).unwrap();
            if v["method"] == method::MUX_EVENT && v["params"]["kind"] == "race" {
                return v;
            }
        }
    })
    .await
    .expect("race event crossed the subscribed peer link");
    assert_eq!(event["params"]["peer"], "box");
    assert_eq!(event["params"]["msg"]["parent"], "box/parent-id");
    assert_eq!(event["params"]["msg"]["candidates"][0]["sessionId"], "box/winner-id");
    local.peer_by_name("box").unwrap().stop();
    served.abort();
    let _ = served.await;
    let _ = std::fs::remove_dir_all(home);
}
