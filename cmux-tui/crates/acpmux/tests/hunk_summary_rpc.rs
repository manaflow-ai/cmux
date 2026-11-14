//! `_acpmux/hunk_summary` over the request path, with shell scripts standing in for Claude Code:
//! the unix socket only, one run per new hunk (a kept sentence runs nothing, a changed hunk runs
//! only itself), the chat's own harness first, and `check` running nothing.

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

const PATCH: &str = "@@ -10,3 +10,6 @@\n-    send(file)?;\n+    for _ in 0..3 {\n+        if send(file).is_ok() { return Ok(()); }\n+    }\n";

fn scratch() -> PathBuf {
    let root = std::env::temp_dir().join(format!("acpmux-hunk-summary-rpc-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(root.join("home")).unwrap();
    std::fs::create_dir_all(root.join("config").join("harnesses")).unwrap();
    std::fs::canonicalize(&root).unwrap()
}

async fn call(hub: &Arc<Hub>, origin: Origin, params: Value) -> Result<Value, Value> {
    let (tx, in_rx) = mpsc::channel(8);
    let (out_tx, mut rx) = mpsc::channel(64);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
    tx.send(Message::request(1, "_acpmux/hunk_summary", params).to_line()).await.unwrap();
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

/// A Claude Code profile whose program is the shell script `script`, in `dir` as `name`.
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

fn runs(log: &Path) -> usize {
    std::fs::read_to_string(log).map(|s| s.lines().count()).unwrap_or(0)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_hunk_is_summarized_once_and_kept_by_its_content() {
    let root = scratch();
    let home = root.join("acpmux-home");
    // SAFETY: the only test in this binary; nothing else reads the env now.
    unsafe { std::env::set_var("ACPMUX_HOME", &home) };
    let sources = ProfileSources {
        managed: vec![],
        user_dir: Some(root.join("config").join("harnesses")),
        cmux_json: None,
    };
    std::fs::write(root.join("home").join("config.json"), "{}").unwrap();
    let mut cfg = Config::load_from_with(&root.join("home").join("config.json"), &sources).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let log = root.join("runs.log");
    // Each run logs its harness and whether the prompt held the hunk, then answers a sentence.
    let answer = |who: &str| {
        format!(
            "if grep -q 'for _ in 0..3' ; then echo '{who} hunk' >> '{}'; else echo '{who} other' >> '{}'; fi; \
             printf '\"retries the upload three times\"\\n'",
            log.display(),
            log.display()
        )
    };
    cfg.harnesses.insert("fake".into(), fake_claude(&root, "fake", &answer("fake")));
    cfg.harnesses.insert("mine".into(), fake_claude(&root, "mine", &answer("mine")));
    cfg.default_harness = Some("fake".into());
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let params = json!({"path": "src/upload.rs", "patch": PATCH});

    // Every WebSocket origin is refused before anything runs.
    for origin in [Origin::LocalApp, Origin::Web, Origin::Peer] {
        let reply = call(&hub, origin, params.clone()).await;
        assert_eq!(reason(&reply), "complete.local_only", "{origin:?}: {reply:?}");
        let check = call(&hub, origin, json!({"check": true})).await;
        assert_eq!(reason(&check), "complete.local_only", "{origin:?}: {check:?}");
    }
    assert_eq!(runs(&log), 0, "a refused summary ran the harness");

    // `check` names the harness that would answer and runs nothing.
    let check = call(&hub, Origin::Local, json!({"check": true})).await.expect("check");
    assert_eq!(check, json!({"ready": true, "harness": "fake"}));
    let check = call(&hub, Origin::Local, json!({"check": true, "harness": "nope"})).await;
    assert_eq!(reason(&check), "complete.unknown_harness", "{check:?}");
    assert_eq!(runs(&log), 0, "check ran the harness");

    // The first ask runs the harness once and cleans its answer into one sentence.
    let first = call(&hub, Origin::Local, params.clone()).await.expect("a summary");
    assert_eq!(first["text"], "Retries the upload three times.");
    assert_eq!(first["cached"], false);
    assert_eq!(first["harness"], "fake");
    let key = first["key"].as_str().unwrap().to_owned();
    assert_eq!(key.len(), 64);
    assert_eq!(runs(&log), 1);
    assert!(home.join("hunk-summaries").join(&key).exists(), "the sentence was not kept");

    // Asking again (a reopened diff) reads the kept sentence and runs nothing.
    let again = call(&hub, Origin::Local, params.clone()).await.expect("a kept summary");
    assert_eq!(again["text"], "Retries the upload three times.");
    assert_eq!(again["cached"], true);
    assert_eq!(again["key"], key.as_str());
    assert_eq!(runs(&log), 1, "a kept summary ran the harness");

    // A changed hunk is a new key: it alone runs, and the first one stays kept.
    let changed = json!({"path": "src/upload.rs", "patch": PATCH.replace("0..3", "0..5")});
    let reply = call(&hub, Origin::Local, changed).await.expect("a changed hunk's summary");
    assert_eq!(reply["cached"], false);
    assert_ne!(reply["key"], key.as_str());
    assert_eq!(runs(&log), 2);
    let kept = call(&hub, Origin::Local, params.clone()).await.unwrap();
    assert_eq!(kept["cached"], true);
    assert_eq!(runs(&log), 2);

    // A named harness answers in place of the default.
    let other = json!({"path": "src/b.rs", "patch": PATCH, "harness": "mine"});
    let reply = call(&hub, Origin::Local, other).await.expect("mine");
    assert_eq!(reply["harness"], "mine");
    assert_eq!(std::fs::read_to_string(&log).unwrap().lines().last(), Some("mine hunk"));

    // A chat that is gone is no chat: the default answers.
    let gone = json!({"path": "src/c.rs", "patch": PATCH, "sessionId": "no-such-chat"});
    let reply = call(&hub, Origin::Local, gone).await.expect("the default");
    assert_eq!(reply["harness"], "fake");

    // Bad params run nothing.
    let before = runs(&log);
    for bad in [json!({"path": "a"}), json!({"path": "a", "patch": "  "}), json!({"patch": PATCH})]
    {
        let reply = call(&hub, Origin::Local, bad.clone()).await;
        assert_eq!(reason(&reply), "complete.invalid_params", "{bad}: {reply:?}");
    }
    assert_eq!(runs(&log), before);
}
