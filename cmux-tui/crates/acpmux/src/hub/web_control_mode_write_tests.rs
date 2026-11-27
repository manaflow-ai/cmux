use super::*;
use crate::config::{Config, StoreMode};
use crate::hub::NewRequest;
use serde_json::json;
use std::path::Path;

fn test_hub() -> Arc<Hub> {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut config: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .expect("config");
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, Path::new("/nonexistent")).expect("store");
    Hub::new(config, store)
}

/// A harness answers `session/new` with `modes` that is not an object (the answer is stored as
/// sent) and later reports its current mode. The write used `modes["currentModeId"] = v`, which
/// panics on an array, string, number or bool, under the session's meta lock: that poisoned it
/// and every later `Session::meta()` panicked with it.
#[test]
fn cloud_mobile_mode_requires_a_phone_asking_mode() {
    let hub = test_hub();
    let meta = |mode: &str| -> crate::store::SessionMeta {
        serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA,
            "id": "cloud-mobile-test",
            "name": "cloud mobile",
            "harness": "claude",
            "family": "claude",
            "cwd": "/tmp",
            "status": "running",
            "createdAt": 1,
            "updatedAt": 2,
            "modes": {"currentModeId": mode},
        }))
        .expect("session metadata")
    };
    for mode in ["default", "plan"] {
        assert!(hub.cloud_mobile_mode_asks(&meta(mode)), "{mode} should ask on phone");
    }
    for mode in ["ask", "agent", "full-access", "bypassPermissions"] {
        assert!(!hub.cloud_mobile_mode_asks(&meta(mode)), "{mode} must be refused on phone");
    }
    let codex = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "codex-test", "name": "codex",
        "harness": "codex", "family": "codex", "cwd": "/tmp", "status": "running",
        "createdAt": 1, "updatedAt": 2, "modes": {"currentModeId": "ask"},
    }))
    .expect("codex metadata");
    assert!(!hub.cloud_mobile_mode_asks(&codex), "codex is not a Claude phone profile");

    let mut bridge_cfg: Config = serde_json::from_value(json!({
        "harnesses": {"codex": {"argv": ["codex", "app-server"]}},
        "defaultHarness": "codex",
    }))
    .expect("bridge config");
    bridge_cfg.store.mode = StoreMode::Memory;
    let bridge_store =
        crate::store::open(&bridge_cfg.store, Path::new("/nonexistent")).expect("bridge store");
    let bridge_hub = Hub::new(bridge_cfg, bridge_store);
    let bridge_meta: crate::store::SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "bridge-test", "name": "codex",
        "harness": "codex", "family": "codex", "harnessArgv": ["codex", "app-server"],
        "cwd": "/tmp", "status": "running", "createdAt": 1, "updatedAt": 2,
        "modes": {"currentModeId": "ask"},
    }))
    .expect("bridge metadata");
    assert!(bridge_hub.cloud_mobile_mode_asks(&bridge_meta));
    let mut agent_meta = bridge_meta.clone();
    agent_meta.modes = Some(json!({"currentModeId": "agent"}));
    assert!(!bridge_hub.cloud_mobile_mode_asks(&agent_meta));
}

#[tokio::test]
async fn a_current_mode_written_over_modes_that_are_not_an_object_does_not_panic() {
    let hub = test_hub();
    let session = hub
        .new_session(NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() })
        .await
        .expect("session");
    for modes in [json!(["plan"]), json!("plan"), json!(7), json!(true)] {
        hub.write_mode_state(&session, [ModeWrite::Modes(modes.clone())]);
        hub.write_mode_state(&session, [ModeWrite::CurrentMode(json!("plan"))]);
        // The modes stay as sent, the mode is kept apart as for a harness with no modes, and
        // the meta lock still opens.
        assert_eq!(session.meta().modes, Some(modes));
        let kept = session.floor.undeclared_mode.lock().unwrap().clone();
        assert_eq!(kept.as_deref(), Some("plan"));
        *session.floor.undeclared_mode.lock().unwrap() = None;
    }
    // Modes that are an object still take the mode in place.
    hub.write_mode_state(&session, [ModeWrite::Modes(json!({"availableModes": []}))]);
    hub.write_mode_state(&session, [ModeWrite::CurrentMode(json!("code"))]);
    assert_eq!(session.meta().modes.unwrap()["currentModeId"], json!("code"));
    assert_eq!(*session.floor.undeclared_mode.lock().unwrap(), None);
}
