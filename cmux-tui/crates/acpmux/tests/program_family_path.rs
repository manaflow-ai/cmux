//! The family of a bare program is read on the PATH its agent is spawned with: the entry's own
//! PATH, then the login PATH (`login_env::with_agent_path`), as `agent/command.rs` spawns it.
//! Before, only the entry's PATH (or the daemon's own) was read, so a program the agent found
//! on the login PATH had no family, and a narrower policy was refused with "add family"
//! (family-rev N1). The login PATH here is this process's own, as `login_env::agent_path`
//! reads it when no login shell was imported; a launchd or app start has a short one.

#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{ConnAuth, Origin, serve_connection_authed};
use serde_json::{Value, json};
use std::os::unix::fs::PermissionsExt as _;
use std::path::Path;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE_AGENT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

mod program_family_path {
    use super::*;

    /// An entry `{"argv": ["opencode"], "env": {"PATH": <empty folder>}}` whose `opencode` is
    /// only on the login PATH: its agent runs it, and its family is OpenCode's, so a chat under
    /// policy `ask` starts (OpenCode is asked to ask).
    #[tokio::test]
    async fn a_program_found_on_the_login_path_keeps_its_family() {
        let _ = &HERMETIC;
        let d = std::env::temp_dir().join(format!("pfp-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        for sub in ["work", "bin", "empty"] {
            std::fs::create_dir_all(d.join(sub)).unwrap();
        }
        let d = std::fs::canonicalize(&d).unwrap();
        let program = d.join("bin/opencode");
        std::fs::write(&program, format!("#!/bin/sh\nexec python3 {FAKE_AGENT} \"$@\"\n")).unwrap();
        std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o755)).unwrap();
        let login = std::env::var("PATH").unwrap_or_default();
        // SAFETY: the only test in this binary, before anything reads the environment.
        unsafe { std::env::set_var("PATH", format!("{}:{login}", d.join("bin").display())) };
        let mut cfg: Config = serde_json::from_value(json!({
            "harnesses": {"oc": {"argv": ["opencode"],
                                 "env": {"PATH": d.join("empty"), "FAKE_ASK_CLAIM": "0"}}},
            "defaultHarness": "oc",
            "permissionPolicy": "approve-all",
            "defaultPermissionMode": "standard",
        }))
        .unwrap();
        cfg.store.mode = StoreMode::Memory;
        let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
        let hub = Hub::new(cfg, store);
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, mut out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_authed(
            hub.clone(),
            in_rx,
            out_tx,
            Origin::Local,
            ConnAuth::LocalSocket,
        ));
        let meta = json!({"harness": "oc", "policy": "ask"});
        let params = json!({"cwd": d.join("work"), "mcpServers": [], "_meta": {"acpmux": meta}});
        in_tx.send(Message::request(1, "session/new", params).to_line()).await.unwrap();
        let r = loop {
            let line = tokio::time::timeout(Duration::from_secs(30), out_rx.recv())
                .await
                .expect("an answer in time")
                .expect("the connection stays open");
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(1)) {
                break v;
            }
        };
        let id = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned();
        let meta = hub.resolve(&id).unwrap().meta();
        assert_eq!(meta.program_family.as_deref(), Some("opencode"), "{r}");
        hub.shutdown_all().await;
        let _ = std::fs::remove_dir_all(&d);
    }
}
