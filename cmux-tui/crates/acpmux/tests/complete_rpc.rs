//! `_acpmux/complete` (hq#1957) over the request path, with shell scripts
//! standing in for Claude Code: the unix socket only (LocalApp, Web and peer
//! are refused before anything runs), the prompt on stdin in a fresh folder
//! that is removed afterwards, and the typed errors for an unknown harness,
//! an unsupported one, a signed-out one and a timeout.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (shell scripts standing in for Claude Code).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, HarnessKind, HarnessProfile, ProfileSources, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

fn scratch() -> PathBuf {
    let root = std::env::temp_dir().join(format!("acpmux-complete-rpc-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(root.join("home")).unwrap();
    std::fs::create_dir_all(root.join("config").join("harnesses")).unwrap();
    std::fs::canonicalize(&root).unwrap()
}

async fn call(hub: &Arc<Hub>, origin: Origin, params: Value) -> Result<Value, Value> {
    let (tx, in_rx) = mpsc::channel(8);
    let (out_tx, mut rx) = mpsc::channel(64);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
    tx.send(Message::request(1, "_acpmux/complete", params).to_line()).await.unwrap();
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

fn reason(reply: &Result<Value, Value>) -> &str {
    reply.as_ref().err().and_then(|e| e["data"]["reason"].as_str()).unwrap_or("(none)")
}

/// A Claude Code profile whose program is an executable shell script in
/// `dir` named `name`: the recipe's own flags land in `$1`, ... and are ignored.
fn fake_claude(dir: &Path, name: &str, script: &str) -> HarnessProfile {
    let path = dir.join(name);
    std::fs::write(&path, format!("#!/bin/sh\n{script}\n")).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    HarnessProfile {
        kind: HarnessKind::ClaudeStdio,
        argv: vec![path.to_string_lossy().into_owned()],
        env: BTreeMap::new(),
        description: None,
        fallback: None,
        family: None,
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn complete_is_unix_socket_only_and_runs_headless() {
    let root = scratch();
    // SAFETY: the only test in this binary; nothing else reads the env now.
    unsafe { std::env::set_var("ACPMUX_HOME", root.join("acpmux-home")) };
    let sources = ProfileSources {
        managed: vec![],
        user_dir: Some(root.join("config").join("harnesses")),
        cmux_json: None,
    };
    std::fs::write(root.join("home").join("config.json"), "{}").unwrap();
    let mut cfg = Config::load_from_with(&root.join("home").join("config.json"), &sources).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let ran = root.join("ran");
    let cwd_file = root.join("cwd");
    let answers = format!(
        "touch '{}'; pwd > '{}'; tr a-z A-Z; printf '\\n'",
        ran.display(),
        cwd_file.display()
    );
    cfg.harnesses.insert("fake".into(), fake_claude(&root, "fake", &answers));
    cfg.harnesses.insert(
        "signedout".into(),
        fake_claude(
            &root,
            "signedout",
            "cat >/dev/null; echo 'Not logged in · Please run /login' >&2; exit 1",
        ),
    );
    cfg.harnesses.insert("slow".into(), fake_claude(&root, "slow", "exec sleep 30"));
    cfg.harnesses.insert(
        "gemini".into(),
        HarnessProfile {
            kind: HarnessKind::Acp,
            argv: vec!["/bin/gemini".into(), "--experimental-acp".into()],
            ..fake_claude(&root, "unused", "")
        },
    );
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);

    // Every WebSocket origin is refused before the harness runs.
    for origin in [Origin::LocalApp, Origin::Web, Origin::Peer] {
        let reply = call(&hub, origin, json!({"prompt": "fix login bug", "harness": "fake"})).await;
        assert_eq!(reason(&reply), "complete.local_only", "{origin:?}: {reply:?}");
    }
    assert!(!ran.exists(), "a refused completion ran the harness");

    // The unix socket runs it: the prompt on stdin, in a fresh folder.
    let reply = call(&hub, Origin::Local, json!({"prompt": "fix login bug", "harness": "fake"}))
        .await
        .expect("a local completion");
    assert_eq!(reply["text"], "FIX LOGIN BUG");
    assert_eq!(reply["harness"], "fake");
    assert!(reply["model"].as_str().is_some_and(|m| !m.is_empty()), "{reply}");
    // One fixed empty cwd for every run, under the acpmux home; the run's
    // own folder (prompt and output files) is gone.
    let cwd = std::fs::read_to_string(&cwd_file).unwrap();
    let complete = root.join("acpmux-home").join("complete");
    assert_eq!(
        std::fs::canonicalize(cwd.trim()).unwrap(),
        std::fs::canonicalize(complete.join("cwd")).unwrap(),
        "ran in {cwd:?}"
    );
    assert_eq!(std::fs::read_dir(complete.join("cwd")).unwrap().count(), 0, "the cwd was written");
    assert_eq!(std::fs::read_dir(complete.join("runs")).unwrap().count(), 0, "a run folder stayed");

    let errors = [
        (json!({"prompt": "x", "harness": "nope"}), "complete.unknown_harness"),
        (json!({"prompt": "x", "harness": "gemini"}), "complete.unsupported_harness"),
        (json!({"prompt": "x", "harness": "signedout"}), "complete.signed_out"),
        (json!({"prompt": "x", "harness": "slow", "timeoutMs": 500}), "complete.timeout"),
        (json!({"prompt": "x".repeat(4097), "harness": "fake"}), "complete.prompt_too_large"),
    ];
    for (params, want) in errors {
        let started = std::time::Instant::now();
        let reply = call(&hub, Origin::Local, params.clone()).await;
        assert_eq!(reason(&reply), want, "{params}: {reply:?}");
        assert!(started.elapsed() < Duration::from_secs(10), "{params} took too long");
    }
}
