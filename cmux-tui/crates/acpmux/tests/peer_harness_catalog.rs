//! Chief placement reads the selected machine's catalog and cached sign-in
//! status without forwarding controls or exposing a second hop through a peer.

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use acpmux::config::{Config, StoreMode};
use acpmux::harness_health::Settings;
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::peer_auth::{PeerAuth, token_path};
use acpmux::server::{Origin, WsAuth, bind_ws, serve_connection_with, serve_ws_with};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

fn hub(id: &str, auth: &str) -> Arc<Hub> {
    let mut profiles = serde_json::Map::new();
    profiles.insert(id.into(), json!({"argv": ["missing-placement-test-harness"]}));
    let mut config: Config =
        serde_json::from_value(json!({"harnesses": profiles, "defaultHarness": id})).unwrap();
    config.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(config, store);
    hub.health.attach(Settings {
        fixture: Some(
            serde_json::from_value(json!([{
                "id": id, "program": "private-program", "path": "/private/diagnostic",
                "channel": "standalone", "version": "1.2.3", "outdated": false,
                "auth": auth, "authDetail": "private-sign-in-detail", "checkedAt": 123,
            }]))
            .unwrap(),
        ),
        ..Settings::default()
    });
    hub
}

async fn call(hub: &Arc<Hub>, origin: Origin, method: &str, params: Value) -> Result<Value, Value> {
    let (tx, inbound) = mpsc::channel(8);
    let (outbound, mut rx) = mpsc::channel(64);
    let server = tokio::spawn(serve_connection_with(hub.clone(), inbound, outbound, origin));
    tx.send(Message::request(1, method, params).to_line()).await.unwrap();
    let result = tokio::time::timeout(Duration::from_secs(10), async {
        while let Some(line) = rx.recv().await {
            let value: Value = serde_json::from_str(&line).unwrap();
            if value.get("id") == Some(&json!(1)) {
                return match value.get("error") {
                    Some(error) => Err(error.clone()),
                    None => Ok(value["result"].clone()),
                };
            }
        }
        panic!("connection ended before {method} replied");
    })
    .await
    .expect("bounded harness read");
    drop(tx);
    server.abort();
    result
}

#[tokio::test]
async fn peer_harness_catalog_and_auth_are_selected_without_forwarding_controls() {
    let root = tempfile::tempdir().unwrap();
    let local = hub("local", "signedOut");
    let remote = hub("codex", "signedIn");
    let peer_auth = PeerAuth::create(root.path()).unwrap();
    let peer_token = std::fs::read_to_string(token_path(root.path())).unwrap();
    let listener = bind_ws("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = tokio::spawn(serve_ws_with(
        remote.clone(),
        listener,
        "placement-test-token".into(),
        WsAuth { local_app: None, peer: Some(Arc::new(peer_auth)) },
    ));
    let added = local
        .add_peer(
            "mini",
            &format!("ws://127.0.0.1:{port}"),
            Some("placement-test-token".into()),
            Some(peer_token),
            true,
        )
        .await
        .unwrap();
    assert_eq!(added["peer"]["connected"], true, "{added}");

    for origin in [Origin::Local, Origin::LocalApp] {
        // Invalid local cwd and health controls must never travel to the peer.
        let params = json!({"cwd": "invalid-relative-folder", "refresh": true,
            "rescan": true, "checkLatest": true,
            "autoUpdate": {"id": "codex", "on": true},
            "_meta": {"acpmux": {"peer": "mini"}}});
        let catalog = call(&local, origin, method::MUX_HARNESSES, params.clone()).await.unwrap();
        assert_eq!(catalog["peer"], "mini");
        assert!(catalog["harnesses"].get("codex").is_some(), "{catalog}");
        assert!(catalog["harnesses"].get("local").is_none(), "{catalog}");
        let auth = call(&local, origin, method::MUX_HARNESS_HEALTH, params).await.unwrap();
        assert_eq!(
            auth,
            json!({"peer": "mini", "harnesses": [{"id": "codex", "auth": "signedIn"}]})
        );
        assert!(!remote.health.rows()[0].auto_update);
    }

    // No machine selected: preserve the local catalog and full health reply.
    let catalog = call(&local, Origin::Local, method::MUX_HARNESSES, json!({})).await.unwrap();
    assert!(catalog["harnesses"].get("local").is_some(), "{catalog}");
    let health = call(&local, Origin::Local, method::MUX_HARNESS_HEALTH, json!({})).await.unwrap();
    assert_eq!(health["harnesses"][0]["id"], "local");
    assert_eq!(health["harnesses"][0]["auth"], "signedOut");
    assert_eq!(health["harnesses"][0]["version"], "1.2.3");

    for origin in [Origin::Peer, Origin::Web] {
        for method in [method::MUX_HARNESSES, method::MUX_HARNESS_HEALTH] {
            let error =
                call(&local, origin, method, json!({"_meta": {"acpmux": {"peer": "mini"}}}))
                    .await
                    .expect_err("remote caller selected this host's peer");
            assert!(error["message"].as_str().unwrap().contains("only the local app"), "{error}");
        }
    }
    for params in [
        json!({"refresh": true}),
        json!({"rescan": true}),
        json!({"checkLatest": true}),
        json!({"autoUpdate": {"id": "codex", "on": true}}),
    ] {
        call(&remote, Origin::Peer, method::MUX_HARNESS_HEALTH, params)
            .await
            .expect_err("peer ran a health control");
    }
    for method in [method::MUX_HARNESSES, method::MUX_HARNESS_HEALTH] {
        call(&local, Origin::Local, method, json!({"_meta": {"acpmux": {"peer": "unknown"}}}))
            .await
            .expect_err("unknown peer fell back to the local machine");
    }
    let unserved = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let offline_port = unserved.local_addr().unwrap().port();
    drop(unserved);
    local
        .add_peer("offline", &format!("ws://127.0.0.1:{offline_port}"), None, None, false)
        .await
        .unwrap();
    for method in [method::MUX_HARNESSES, method::MUX_HARNESS_HEALTH] {
        call(&local, Origin::Local, method, json!({"_meta": {"acpmux": {"peer": "offline"}}}))
            .await
            .expect_err("disconnected peer fell back to the local machine");
    }
    local.remove_peer("offline").await.unwrap();
    local.remove_peer("mini").await.unwrap();
    server.abort();
}
