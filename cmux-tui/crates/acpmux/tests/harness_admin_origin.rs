//! Who may change and check harness profiles (coordinator decision
//! 2026-10-08): `_acpmux/harness/add` writes a profile that runs a program
//! and `_acpmux/harness/doctor` starts a harness, so only the unix socket may
//! call them; LocalApp, Web and peer connections are refused (remote_guard:
//! LocalApp never makes this machine spawn a process). LocalApp may call
//! `remove`, `restore` and `registry` (recoverable or read only); Web and
//! peer may call none of them.

use acpmux::config::{Config, ProfileSources, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

fn scratch() -> PathBuf {
    let root = std::env::temp_dir().join(format!("acpmux-admin-origin-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(root.join("home")).unwrap();
    std::fs::create_dir_all(root.join("config").join("harnesses")).unwrap();
    std::fs::canonicalize(&root).unwrap()
}

async fn call(hub: &Arc<Hub>, origin: Origin, m: &str, params: Value) -> Result<Value, Value> {
    let (tx, in_rx) = mpsc::channel(8);
    let (out_tx, mut rx) = mpsc::channel(64);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
    tx.send(Message::request(1, m, params).to_line()).await.unwrap();
    loop {
        let line = tokio::time::timeout(Duration::from_secs(60), rx.recv())
            .await
            .expect("no reply")
            .unwrap();
        let v: Value = serde_json::from_str(&line).unwrap();
        if v.get("id") == Some(&json!(1)) {
            return match v.get("error") {
                Some(e) => Err(e.clone()),
                None => Ok(v["result"].clone()),
            };
        }
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn add_and_doctor_are_unix_socket_only() {
    let root = scratch();
    let acpmux_home = root.join("acpmux-home");
    // SAFETY: the only test in this binary; nothing else reads the env now.
    unsafe { std::env::set_var("ACPMUX_HOME", &acpmux_home) };
    acpmux::registry::save(&acpmux_home, include_bytes!("fixtures/acp-registry.json")).unwrap();
    let user = root.join("config").join("harnesses");
    let sources = ProfileSources { managed: vec![], user_dir: Some(user.clone()), cmux_json: None };
    std::fs::write(root.join("home").join("config.json"), "{}").unwrap();
    let mut cfg = Config::load_from_with(&root.join("home").join("config.json"), &sources).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);

    let add = |id: &str| json!({"id": id, "command": "/bin/echo"});
    for origin in [Origin::LocalApp, Origin::Web, Origin::Peer] {
        let refused = call(&hub, origin, "_acpmux/harness/add", add("fromremote")).await;
        assert!(refused.is_err(), "{origin:?} added a harness: {refused:?}");
        let doctor =
            call(&hub, origin, "_acpmux/harness/doctor", json!({"id": "fromremote"})).await;
        assert!(doctor.is_err(), "{origin:?} ran doctor: {doctor:?}");
    }
    assert!(!user.join("fromremote.toml").exists(), "a refused add wrote a file");

    // The unix socket adds; LocalApp removes, restores and reads the registry.
    call(&hub, Origin::Local, "_acpmux/harness/add", add("local")).await.expect("unix socket add");
    let removed = call(&hub, Origin::LocalApp, "_acpmux/harness/remove", json!({"id": "local"}))
        .await
        .expect("local app remove");
    call(&hub, Origin::LocalApp, "_acpmux/harness/restore", json!({"backup": removed["backup"]}))
        .await
        .expect("local app restore");
    assert!(user.join("local.toml").exists());
    let reg = call(&hub, Origin::LocalApp, "_acpmux/registry", json!({}))
        .await
        .expect("local app registry");
    assert!(reg["agents"].as_array().is_some_and(|a| !a.is_empty()));

    // Web and peer change and read nothing here.
    for origin in [Origin::Web, Origin::Peer] {
        for (m, params) in [
            ("_acpmux/harness/remove", json!({"id": "local"})),
            ("_acpmux/harness/restore", json!({"backup": "local-1.toml"})),
            ("_acpmux/registry", json!({})),
        ] {
            assert!(call(&hub, origin, m, params).await.is_err(), "{origin:?} called {m}");
        }
    }
    assert!(user.join("local.toml").exists());
}
