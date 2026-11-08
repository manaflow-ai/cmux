//! The plan approval card's builds (`hub/plan_build.rs`, `server/plan_build.rs`): a plan built
//! here answers its approval's allow; one built on two agents starts two sub-sessions in two new
//! worktrees with the plan as their first prompt, stops the plan's own chat with the reject, reads
//! each build's change, and keeps one while the other's chat is archived and its worktree stays.
//!
//! Stand-in agent (fake_agent.py): `plan-ask: <plan>` asks a plan approval as Claude Code's
//! ExitPlanMode does and says which option it got. One test function: it sets HOME.

#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const PERSON_KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake",
        "permissionPolicy": "ask",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let _ = hub.person.install_spawn_key(PERSON_KEY);
    hub
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    /// The app's connection: `initialize`, then the person's proof (`hub/person.rs`).
    async fn person(hub: &Arc<Hub>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        let mut c = Client(in_tx, out_rx, 0);
        let init = c.call("initialize", json!({"protocolVersion": 1})).await;
        let challenge = &init["result"]["_meta"]["acpmux"]["personChallenge"];
        let proof = acpmux::hub::person::person_proof(
            PERSON_KEY,
            acpmux::hub::person::TRANSPORT_UNIX,
            challenge["nonce"].as_str().unwrap(),
            challenge["connection"].as_str().unwrap(),
        )
        .unwrap();
        let r = c.call("_acpmux/person_prove", json!({"proof": proof})).await;
        assert_eq!(r["result"]["person"], json!(true), "{r}");
        c
    }

    async fn send(&mut self, m: &str, params: Value) -> i64 {
        self.2 += 1;
        self.0.send(Message::request(self.2, m, params).to_line()).await.unwrap();
        self.2
    }

    async fn next(&mut self) -> Value {
        let line =
            tokio::time::timeout(Duration::from_secs(30), self.1.recv()).await.unwrap().unwrap();
        serde_json::from_str(&line).unwrap()
    }

    /// The reply to request `id`; other lines are dropped.
    async fn reply(&mut self, id: i64) -> Value {
        loop {
            let v = self.next().await;
            if v.get("id") == Some(&json!(id)) && v.get("method").is_none() {
                return v;
            }
        }
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        let id = self.send(m, params).await;
        self.reply(id).await
    }

    async fn ok(&mut self, m: &str, params: Value) -> Value {
        let r = self.call(m, params).await;
        assert!(r.get("error").is_none(), "{m}: {r}");
        r["result"].clone()
    }

    /// Sends a prompt and answers the id of the plan approval it asks.
    async fn ask_plan(&mut self, session: &str, text: &str) -> (i64, String) {
        let rid = self
            .send(
                "session/prompt",
                json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]}),
            )
            .await;
        loop {
            let v = self.next().await;
            if v.get("method") == Some(&json!("_acpmux/permission_pending")) {
                return (rid, v["params"]["permissionId"].as_str().unwrap().to_owned());
            }
            // A notice that carries the pending ask in a session update.
            if let Some(pid) = v.pointer("/params/permissionId").and_then(Value::as_str)
                && v.get("method").and_then(Value::as_str).is_some_and(|m| m.contains("permission"))
            {
                return (rid, pid.to_owned());
            }
        }
    }

    /// The text the turn `rid` streamed, once it ended.
    async fn said(&mut self, rid: i64) -> String {
        let mut text = String::new();
        loop {
            let v = self.next().await;
            if let Some(t) = v.pointer("/params/update/content/text").and_then(Value::as_str) {
                text.push_str(t);
            }
            if v.get("id") == Some(&json!(rid)) && v.get("method").is_none() {
                return text;
            }
        }
    }
}

fn git(dir: &Path, args: &[&str]) {
    let out = std::process::Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "init.defaultBranch=main"])
        .args(["-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"])
        .args(args)
        .output()
        .unwrap();
    assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
}

fn reason(v: &Value) -> &str {
    v.pointer("/error/data/reason").and_then(Value::as_str).unwrap_or_default()
}

#[tokio::test]
async fn a_plan_builds_here_or_on_two_agents_and_one_is_kept() {
    let root = std::env::temp_dir().join(format!("acpmux-planbuild-{}", uuid::Uuid::now_v7()));
    let home = root.join("home");
    std::fs::create_dir_all(&home).unwrap();
    // SAFETY: the only test in this binary; set before any session starts.
    unsafe {
        std::env::set_var("HOME", &home);
        std::env::set_var("ACPMUX_HOME", root.join("acpmux"));
        std::env::set_var("CMUX_NEXT_CONFIG_FILE", root.join("cmux-next.json"));
        std::env::remove_var("FLEET_REGISTRY");
    }
    let repo = root.join("shop");
    std::fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "-q"]);
    std::fs::write(repo.join("README.md"), "shop\n").unwrap();
    // The chat runs in a subfolder: a build's change is still read from its worktree's root.
    std::fs::create_dir_all(repo.join("web")).unwrap();
    std::fs::write(repo.join("web/app.js"), "app\n").unwrap();
    git(&repo, &["add", "."]);
    git(&repo, &["commit", "-q", "-m", "first"]);

    let hub = hub();
    let mut app = Client::person(&hub).await;
    let new = json!({"cwd": repo.join("web"), "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}});
    let chat = app.ok("session/new", new).await["sessionId"].as_str().unwrap().to_owned();

    // An ask that is no plan approval builds nothing.
    let (rid, pid) = app.ask_plan(&chat, "ask: rm -rf build").await;
    let r = app
        .call(
            "_acpmux/plan/build",
            json!({"sessionId": chat, "permissionId": pid, "target": "worktree"}),
        )
        .await;
    assert_eq!(reason(&r), "plan_build.not_plan", "{r}");
    app.ok(
        "_acpmux/permission_respond",
        json!({"sessionId": chat, "permissionId": pid, "optionId": "no"}),
    )
    .await;
    app.said(rid).await;

    // Build here: the approval's allow, as Approve plan.
    let (rid, pid) = app.ask_plan(&chat, "plan-ask: Add a changelog").await;
    let here = app
        .ok("_acpmux/plan/build", json!({"sessionId": chat, "permissionId": pid, "target": "here"}))
        .await;
    assert_eq!(here["builds"], json!([]), "{here}");
    assert!(app.said(rid).await.contains("chose yes"));

    // Build on two agents: two chats in two new worktrees, the plan's own chat stopped.
    let (rid, pid) = app.ask_plan(&chat, "plan-ask: Add a license file").await;
    let built = app
        .ok(
            "_acpmux/plan/build",
            json!({"sessionId": chat, "permissionId": pid, "target": "compare", "harnesses": ["fake", "fake"]}),
        )
        .await;
    assert!(app.said(rid).await.contains("chose no"), "the plan's chat stops: {built}");
    let builds = built["builds"].as_array().unwrap();
    assert_eq!(builds.len(), 2, "{built}");
    let build_id = built["buildId"].as_str().unwrap().to_owned();
    let worktrees = home.join(".cmux/worktrees");
    let roots: Vec<String> =
        builds.iter().map(|b| b["worktree"]["root"].as_str().unwrap().to_owned()).collect();
    assert_ne!(roots[0], roots[1], "{built}");
    for b in builds {
        assert!(
            b["branch"].as_str().is_some_and(|s| !s.is_empty()),
            "the record names the branch: {b}"
        );
    }
    for r in &roots {
        assert!(r.starts_with(&*worktrees.to_string_lossy()), "{built}");
        assert!(Path::new(r).join("README.md").is_file(), "{built}");
    }
    // The same plan answered twice builds nothing more: the ask is gone.
    let again = app
        .call(
            "_acpmux/plan/build",
            json!({"sessionId": chat, "permissionId": pid, "target": "worktree"}),
        )
        .await;
    assert_eq!(reason(&again), "plan_build.not_pending", "{again}");

    // The first build adds a file and edits one; the second commits a change.
    std::fs::write(Path::new(&roots[0]).join("LICENSE"), "MIT\nfree\n").unwrap();
    std::fs::write(Path::new(&roots[0]).join("README.md"), "shop\nmore\n").unwrap();
    std::fs::write(Path::new(&roots[1]).join("LICENSE"), "MIT\n").unwrap();
    git(Path::new(&roots[1]), &["add", "."]);
    git(Path::new(&roots[1]), &["commit", "-q", "-m", "license"]);

    // What an agent can write: a filter in the worktree's attributes, and its command in the
    // repository's config. Reading a build's change runs neither.
    let marker = root.join("filter-ran");
    std::fs::write(Path::new(&roots[0]).join(".gitattributes"), "* filter=pwn\n").unwrap();
    let clean = format!("touch {} && cat", marker.display());
    git(&repo, &["config", "filter.pwn.clean", &clean]);
    git(&repo, &["config", "diff.pwn.textconv", &clean]);

    let first = builds[0]["sessionId"].as_str().unwrap().to_owned();
    let second = builds[1]["sessionId"].as_str().unwrap().to_owned();
    // What a build's agent can set on chats: tags. They move nothing: the plan's own record names
    // its builds, roots and bases, so git never runs in a folder a tag names.
    let elsewhere = home.join("elsewhere");
    std::fs::create_dir_all(&elsewhere).unwrap();
    app.ok(
        "_acpmux/tag",
        json!({"sessionId": first, "set": {"planBuild": "other", "planBuildRoot": elsewhere, "planBuildBase": "HEAD~1"}}),
    )
    .await;
    app.ok("_acpmux/tag", json!({"sessionId": chat, "set": {"planBuild": build_id}})).await;
    let compared =
        app.ok("_acpmux/plan/compare", json!({"sessionId": chat, "buildId": build_id})).await;
    let row = |id: &str| {
        compared["builds"]
            .as_array()
            .unwrap()
            .iter()
            .find(|b| b["sessionId"] == id)
            .cloned()
            .unwrap()
    };
    let (a, b) = (row(&first), row(&second));
    assert_eq!(compared["builds"].as_array().unwrap().len(), 2, "{compared}");
    assert_eq!(a["root"], json!(roots[0]), "the recorded root, not the tag: {compared}");
    assert!(!marker.exists(), "comparing ran the repository's filter");
    // LICENSE (2), README.md (+1) and .gitattributes (1).
    assert_eq!((a["added"].as_u64(), a["removed"].as_u64()), (Some(4), Some(0)), "{compared}");
    assert_eq!(b["added"].as_u64(), Some(1), "a committed change counts: {compared}");
    let paths: Vec<&str> =
        a["files"].as_array().unwrap().iter().filter_map(|f| f["path"].as_str()).collect();
    assert!(paths.contains(&"LICENSE") && paths.contains(&"README.md"), "{compared}");
    assert_eq!(compared["keptSessionId"], Value::Null);

    // Keep the second: the first chat is archived, its worktree and work stay.
    let kept = app
        .ok("_acpmux/plan/keep", json!({"sessionId": chat, "buildId": build_id, "keep": second}))
        .await;
    assert_eq!(kept["keptSessionId"], json!(second), "{kept}");
    let row = |id: &str| {
        kept["builds"].as_array().unwrap().iter().find(|b| b["sessionId"] == id).cloned().unwrap()
    };
    assert_eq!(row(&first)["archived"], json!(true), "{kept}");
    assert_eq!(row(&second)["archived"], json!(false), "{kept}");
    assert!(Path::new(&roots[0]).join("LICENSE").is_file(), "the archived build's work stays");
    let r = app
        .call("_acpmux/plan/keep", json!({"sessionId": chat, "buildId": build_id, "keep": chat}))
        .await;
    assert!(r.get("error").is_some(), "only a build is kept: {r}");

    let _ = std::fs::remove_dir_all(&root);
}
