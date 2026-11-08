//! Real daemon RPC, isolated git worktrees and fixture ACP processes. The same barrier
//! harness measures sequential children (before) and racing children (after).
#![cfg(unix)]
#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in().tools(&["git"]);

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::{path::Path, sync::Arc, time::Duration};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::mpsc;

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);
impl Client {
    fn new(hub: &Arc<Hub>) -> Self {
        let (tx, rx) = mpsc::channel(64);
        let (out, input) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), rx, out, Origin::Local));
        Self(tx, input, 0)
    }
    async fn caller(hub: &Arc<Hub>, parent: &str) -> Self {
        let mut client = Self::new(hub);
        client
            .ok(
                "initialize",
                json!({"protocolVersion": 1, "_meta": {"acpmux": {
            "callerSession": {"sessionId": parent,
                "token": acpmux::hub::person::caller_token(parent)}}}}),
            )
            .await;
        client
    }
    async fn call(&mut self, method: &str, params: Value) -> Value {
        self.2 += 1;
        self.0.send(Message::request(self.2, method, params).to_line()).await.unwrap();
        tokio::time::timeout(Duration::from_secs(30), async {
            loop {
                let line = self.1.recv().await.unwrap();
                let reply: Value = serde_json::from_str(&line).unwrap();
                if reply.get("id") == Some(&json!(self.2)) {
                    return reply;
                }
            }
        })
        .await
        .expect("RPC deadline")
    }
    async fn ok(&mut self, method: &str, params: Value) -> Value {
        let reply = self.call(method, params).await;
        assert!(reply.get("error").is_none(), "{method}: {reply}");
        reply["result"].clone()
    }
}

fn git(dir: &Path, args: &[&str]) {
    let result = std::process::Command::new("git")
        .arg("-C")
        .arg(dir)
        .args([
            "-c",
            "user.name=Fixture",
            "-c",
            "user.email=fixture@example.test",
            "-c",
            "commit.gpgsign=false",
            "-c",
            "core.hooksPath=/dev/null",
        ])
        .args(args)
        .output()
        .unwrap();
    assert!(result.status.success(), "{}", String::from_utf8_lossy(&result.stderr));
}

async fn race_until(
    hub: &Arc<Hub>,
    parent: &str,
    id: &str,
    predicate: impl Fn(&Value) -> bool,
) -> Value {
    let mut events = hub.subscribe();
    let session = hub.resolve(parent).unwrap();
    tokio::time::timeout(Duration::from_secs(40), async {
        loop {
            let race = json!(hub.race_get(&session, id).unwrap());
            if predicate(&race) {
                return race;
            }
            events.recv().await.expect("hub event");
        }
    })
    .await
    .expect("race outcome deadline")
}

async fn terminal(hub: &Arc<Hub>, parent: &str, id: &str) -> Value {
    race_until(hub, parent, id, |r| {
        matches!(r["state"].as_str(), Some("completed" | "failed" | "cancelled"))
    })
    .await
}

async fn release(listener: &tokio::net::UnixListener, count: usize) -> usize {
    tokio::time::timeout(Duration::from_secs(25), async {
        let mut waiting = Vec::new();
        for _ in 0..count {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut model = [0; 1];
            stream.read_exact(&mut model).await.unwrap();
            waiting.push(stream);
        }
        let overlap = waiting.len();
        for mut stream in waiting {
            stream.write_all(b"!").await.unwrap();
        }
        overlap
    })
    .await
    .expect("both candidates must enter their prompts without waiting for the other to finish")
}

fn start(prompt: &str, reviewer: &str) -> Value {
    json!({"prompt": prompt, "candidates": [{"harness":"fake","model":"a"},
        {"harness":"fake","model":"b"}], "reviewer":{"harness":"fake","model":reviewer}})
}

#[tokio::test]
async fn races_overlap_review_and_cancel_without_touching_other_sessions() {
    let scratch = tempfile::tempdir().unwrap();
    let root = scratch.path();
    let home = root.join("home");
    let repo = root.join("repo");
    std::fs::create_dir_all(&home).unwrap();
    std::fs::create_dir_all(&repo).unwrap();
    // SAFETY: this binary has one test, and sets the environment before any task starts.
    unsafe {
        std::env::set_var("HOME", &home);
        std::env::set_var("ACPMUX_HOME", root.join("acpmux"));
        std::env::set_var("CMUX_NEXT_CONFIG_FILE", root.join("settings.json"));
        std::env::set_var("FLEET_REGISTRY", root.join("fleet.json"));
    }
    std::fs::write(root.join("settings.json"), "{}").unwrap();
    std::fs::write(root.join("fleet.json"), "{\"machines\":{}}").unwrap();
    git(&repo, &["init", "-q"]);
    git(&repo, &["commit", "--allow-empty", "-qm", "fixture"]);
    acpmux::trust::set(
        &acpmux::trust::Paths::current().unwrap(),
        &root.to_string_lossy(),
        "trusted",
    )
    .unwrap();
    let mut config: Config = serde_json::from_value(json!({"harnesses":{"fake":{"argv":[
        "python3", concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_race_agent.py")]}},
        "defaultHarness":"fake", "permissionPolicy":"approve-all"}))
    .unwrap();
    config.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&config.store, root).unwrap();
    let hub = Hub::new(config, store);
    let mut app = Client::new(&hub);
    let parent = app
        .ok(
            "session/new",
            json!({"cwd":repo,"mcpServers":[],
        "_meta":{"acpmux":{"harness":"fake"}}}),
        )
        .await["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let mut client = Client::caller(&hub, &parent).await;
    // Naming a parent does not prove a caller.
    let mut unauthorized = start("task", "review");
    unauthorized["parent"] = json!(parent);
    assert!(app.call("_acpmux/race/start", unauthorized).await.get("error").is_some());
    assert_eq!(client.ok("_acpmux/race/stats", json!({})).await["models"], json!([]));

    let barrier = root.join("gate.sock");
    let listener = tokio::net::UnixListener::bind(&barrier).unwrap();
    let task = format!("barrier:{}", barrier.display());
    // Same fixture, sequential execution as the old compare command: peak concurrency 1.
    let mut before = 0;
    for model in ["a", "b"] {
        let child = client
            .ok(
                "_acpmux/subsession/start",
                json!({"prompt":task,
            "harness":"fake","model":model,"worktree":true}),
            )
            .await;
        before = before.max(release(&listener, 1).await);
        client
            .ok(
                "_acpmux/wait",
                json!({"sessions":[child["sessionId"]],
            "until":["ready"],"timeoutMs":20000}),
            )
            .await;
        client
            .ok("_acpmux/subsession/stop", json!({"sessionId":child["sessionId"],"close":true}))
            .await;
    }
    let started = client.ok("_acpmux/race/start", start(&task, "review")).await;
    let id = started["id"].as_str().unwrap();
    let after = release(&listener, 2).await;
    let done = terminal(&hub, &parent, id).await;
    assert_eq!(done["state"], "completed", "{done}");
    assert_eq!(done["winnerId"], "c1", "{done}");
    let candidates = done["candidates"].as_array().unwrap();
    assert_ne!(candidates[0]["cwd"], candidates[1]["cwd"]);
    assert_eq!(candidates[0]["base"].as_str().unwrap().len(), 40);
    assert_eq!(candidates[0]["base"], candidates[1]["base"]);
    assert!(!repo.join("implementation.txt").exists());
    for (i, expected) in ["a", "b"].iter().enumerate() {
        assert_eq!(
            std::fs::read_to_string(
                Path::new(candidates[i]["cwd"].as_str().unwrap()).join("implementation.txt")
            )
            .unwrap(),
            *expected
        );
        let info = app.ok("_acpmux/info", json!({"sessionId":candidates[i]["sessionId"]})).await;
        assert_eq!(info["status"] == "closed", i == 1, "{info}");
    }
    let stats = client.ok("_acpmux/race/stats", json!({})).await;
    assert_eq!(stats["models"][0]["wins"], 1);
    assert_eq!(stats["models"][0]["winRate"], 1.0);
    assert_eq!(stats["models"][1]["wins"], 0);
    assert_eq!(stats["models"][1]["winRate"], 0.0);
    println!(
        "RACE_METRIC {}",
        json!({"harness":"fake_race_agent.py barrier", "peakActivePrompts":
        {"before":before,"after":after},"fixtureWinRates":stats["models"]})
    );

    let bad = client.ok("_acpmux/race/start", start("task", "invalid")).await;
    let failed = terminal(&hub, &parent, bad["id"].as_str().unwrap()).await;
    assert_eq!(failed["state"], "failed", "{failed}");
    for candidate in failed["candidates"].as_array().unwrap() {
        assert_eq!(candidate["state"], "completed", "{failed}");
        assert!(Path::new(candidate["cwd"].as_str().unwrap()).exists());
    }
    let stopped_failed = client.ok("_acpmux/race/cancel", json!({"raceId":bad["id"]})).await;
    assert_eq!(stopped_failed["state"], "cancelled");
    for candidate in failed["candidates"].as_array().unwrap() {
        let info = app.ok("_acpmux/info", json!({"sessionId":candidate["sessionId"]})).await;
        assert_eq!(info["status"], "closed", "{info}");
    }
    let held = client.ok("_acpmux/race/start", start("hold", "review")).await;
    let held_id = held["id"].as_str().unwrap();
    race_until(&hub, &parent, held_id, |r| {
        r["candidates"].as_array().unwrap().iter().all(|c| c["sessionId"].is_string())
    })
    .await;
    let cancelled = client.ok("_acpmux/race/cancel", json!({"raceId":held_id})).await;
    assert_eq!(cancelled["state"], "cancelled");
    assert_eq!(client.ok("_acpmux/race/stats", json!({})).await, stats);
    let parent_info = app.ok("_acpmux/info", json!({"sessionId":parent})).await;
    assert_ne!(parent_info["status"], "closed");
    let winner_info = app.ok("_acpmux/info", json!({"sessionId":candidates[0]["sessionId"]})).await;
    assert_ne!(winner_info["status"], "closed");
    hub.shutdown_all().await;
}
