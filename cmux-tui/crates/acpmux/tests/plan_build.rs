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

    /// A chat's own agent's connection (its caller token), as `start_session` uses.
    async fn agent(hub: &Arc<Hub>, session: &str) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        let mut c = Client(in_tx, out_rx, 0);
        let token = acpmux::hub::person::caller_token(session);
        c.ok(
            "initialize",
            json!({"protocolVersion": 1,
                   "_meta": {"acpmux": {"callerSession": {"sessionId": session, "token": token}}}}),
        )
        .await;
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
    // Every start's model is one id, whoever asks: the daemon refuses it, not only the pane
    // (`chat.fix_from_link` and a sub-session start through here without the pane's rule).
    for model in ["m$(touch /tmp/pwn)", "m`id`", "m;id", "claude opus", "--yolo"] {
        let bad = json!({"cwd": repo, "mcpServers": [], "_meta": {"acpmux": {"harness": "fake", "model": model}}});
        let r = app.call("session/new", bad).await;
        assert!(r.get("error").is_some(), "{model} starts no chat: {r}");
    }
    let r = app
        .call("session/new", json!({"cwd": repo, "mcpServers": [], "_meta": {"acpmux": {"harness": "fake", "effort": "$(id)"}}}))
        .await;
    assert!(r.get("error").is_some(), "an effort is one id too: {r}");
    // An empty model is none, as on every start: the chat starts on its harness's own.
    let none = json!({"cwd": repo, "mcpServers": [], "_meta": {"acpmux": {"harness": "fake", "model": ""}}});
    let r = app.ok("session/new", none).await;
    assert_ne!(r["_meta"]["acpmux"]["model"], json!(""), "{r}");

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
    assert!(!marker.exists(), "comparing ran the repository's filter");
    // LICENSE (2), README.md (+1) and .gitattributes (1).
    assert_eq!((a["added"].as_u64(), a["removed"].as_u64()), (Some(4), Some(0)), "{compared}");
    assert_eq!(b["added"].as_u64(), Some(1), "a committed change counts: {compared}");
    let paths: Vec<&str> =
        a["files"].as_array().unwrap().iter().filter_map(|f| f["path"].as_str()).collect();
    assert!(paths.contains(&"LICENSE") && paths.contains(&"README.md"), "{compared}");
    assert_eq!(compared["keptSessionId"], Value::Null);

    // Keep the second: the first chat is archived, its worktree and work stay, even when the
    // caller asks for the composer runs' cleanup: a plan approval's build is no composer run.
    let keep =
        json!({"sessionId": chat, "buildId": build_id, "keep": second, "removeOthers": true});
    let kept = app.ok("_acpmux/plan/keep", keep).await;
    assert_eq!(kept["keptSessionId"], json!(second), "{kept}");
    assert_eq!(kept["removed"], json!([]), "a plan build's Keep removes nothing: {kept}");
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

    // The composer's Run on N agents: one typed prompt on three agents, three worktrees.
    let few = app
        .call(
            "_acpmux/plan/fanout",
            json!({"sessionId": chat, "prompt": "Add a NOTICE", "variants": [{"harness": "fake"}]}),
        )
        .await;
    assert!(few.get("error").is_some(), "one variant is no fan-out: {few}");
    let five: Vec<Value> = (0..5).map(|_| json!({"harness": "fake"})).collect();
    let many = app
        .call(
            "_acpmux/plan/fanout",
            json!({"sessionId": chat, "prompt": "Add a NOTICE", "variants": five}),
        )
        .await;
    assert!(many.get("error").is_some(), "at most four: {many}");
    // A run's harness, model and effort are spawn parameters (`${model}` in a harness's argv):
    // one id each, refused before any run starts, as `session/new` refuses them.
    let chats = app.ok("_acpmux/sessions", json!({})).await["sessions"].as_array().unwrap().len();
    for bad in [
        json!({"harness": "fake", "model": "m$(touch /tmp/pwn)"}),
        json!({"harness": "fake", "model": "m`id`"}),
        json!({"harness": "fake", "model": "m;id"}),
        json!({"harness": "fake", "model": "claude opus"}),
        json!({"harness": "fake", "model": "m\nid"}),
        json!({"harness": "fake", "model": "--dangerously-skip-permissions"}),
        json!({"harness": "fake", "effort": "$(id)"}),
        json!({"harness": "fake;id"}),
        json!({"harness": "fake", "model": 1}),
    ] {
        // The bad run is the last, so a check made run by run would start the first.
        let variants = json!([{"harness": "fake"}, bad]);
        let r = app
            .call(
                "_acpmux/plan/fanout",
                json!({"sessionId": chat, "prompt": "Add a NOTICE", "variants": variants}),
            )
            .await;
        assert!(r.get("error").is_some(), "{bad} is refused: {r}");
    }
    let after = app.ok("_acpmux/sessions", json!({})).await["sessions"].as_array().unwrap().len();
    assert_eq!(after, chats, "a refused fan-out starts no chat");
    let four: Vec<Value> = (0..4).map(|_| json!({"harness": "fake"})).collect();
    let ran = app
        .ok(
            "_acpmux/plan/fanout",
            json!({"sessionId": chat, "prompt": "Add a NOTICE", "variants": four}),
        )
        .await;
    assert_eq!(ran["target"], json!("prompt"), "{ran}");
    let runs = ran["builds"].as_array().unwrap();
    assert_eq!(runs.len(), 4, "{ran}");
    let run_id = ran["buildId"].as_str().unwrap().to_owned();
    let run_roots: Vec<String> =
        runs.iter().map(|b| b["worktree"]["root"].as_str().unwrap().to_owned()).collect();
    for (i, r) in run_roots.iter().enumerate() {
        assert!(Path::new(r).join("README.md").is_file(), "{ran}");
        std::fs::write(Path::new(r).join("NOTICE"), format!("run {i}\n")).unwrap();
    }
    // What the repository's own `info/exclude` leaves out is no change: a run's ignored cache
    // never counts as added.
    let exclude = repo.join(".git/info/exclude");
    std::fs::create_dir_all(exclude.parent().unwrap()).unwrap();
    std::fs::write(&exclude, "cache/\n").unwrap();
    std::fs::create_dir_all(Path::new(&run_roots[0]).join("cache")).unwrap();
    std::fs::write(Path::new(&run_roots[0]).join("cache/blob"), "ignored\n").unwrap();
    let compared =
        app.ok("_acpmux/plan/compare", json!({"sessionId": chat, "buildId": run_id})).await;
    assert!(
        compared["builds"].as_array().unwrap().iter().all(|b| b["added"].as_u64() == Some(1)),
        "{compared}"
    );
    // A run's change is read against the commit it was made from, not its branch's name: one
    // run commits its work, and the branch the runs left is renamed; every run still shows it.
    git(Path::new(&run_roots[1]), &["add", "NOTICE"]);
    git(Path::new(&run_roots[1]), &["commit", "-q", "-m", "notice"]);
    git(&repo, &["branch", "-m", "main", "moved"]);
    let renamed =
        app.ok("_acpmux/plan/compare", json!({"sessionId": chat, "buildId": run_id})).await;
    git(&repo, &["branch", "-m", "moved", "main"]);
    assert!(
        renamed["builds"].as_array().unwrap().iter().all(|b| b["added"].as_u64() == Some(1)),
        "a committed change still counts after its branch is renamed: {renamed}"
    );
    // Tags are no proof (`_acpmux/tag` writes them for anyone): one run's root tag points at
    // the earlier build's worktree, and that earlier build is tagged as one of these runs.
    let forged_root = json!({"planBuildRoot": roots[0]});
    let run2 = runs[2]["sessionId"].clone();
    app.ok("_acpmux/tag", json!({"sessionId": run2, "set": forged_root})).await;
    let earlier = builds[0]["sessionId"].clone();
    app.ok("_acpmux/tag", json!({"sessionId": earlier, "set": {"planBuild": run_id}})).await;
    // Nor do the base and root tags steer a comparison: a run's change is read from the worktree
    // and commit its lineage recorded, whatever the tags say.
    let run0 = runs[0]["sessionId"].clone();
    let forged =
        json!({"planBuildBase": "0000000000000000000000000000000000000000", "planBuildRoot": repo});
    app.ok("_acpmux/tag", json!({"sessionId": run0, "set": forged})).await;
    let again = app.ok("_acpmux/plan/compare", json!({"sessionId": chat, "buildId": run_id})).await;
    let row0 = again["builds"].as_array().unwrap().iter().find(|b| b["sessionId"] == run0).unwrap();
    assert_eq!(row0["added"].as_u64(), Some(1), "{again}");
    assert_eq!(row0["root"], json!(run_roots[0]), "{again}");
    assert!(row0.get("error").is_none_or(Value::is_null), "{again}");
    // And the chat's agent starts an ordinary sub-session in a worktree, tagged into the runs.
    let mut agent = Client::agent(&hub, &chat).await;
    let plain = agent
        .ok("_acpmux/subsession/start", json!({"prompt": "look around", "worktree": true}))
        .await;
    let plain_id = plain["sessionId"].clone();
    let plain_root = plain["worktree"]["root"].as_str().unwrap().to_owned();
    agent.ok("_acpmux/tag", json!({"sessionId": plain_id, "set": {"planBuild": run_id}})).await;
    // The fourth run's worktree went, and git made another worktree at its path, on that branch
    // again: a folder with someone's work, not the worktree that run was made in, so it stays.
    let branch3 = runs[3]["worktree"]["branch"].as_str().unwrap().to_owned();
    git(&repo, &["worktree", "remove", "--force", &run_roots[3]]);
    git(&repo, &["worktree", "add", "-q", &run_roots[3], &branch3]);
    std::fs::write(Path::new(&run_roots[3]).join("MINE"), "someone else's\n").unwrap();
    // Compare reads no change from it either: the folder there is not the run's worktree now.
    let swapped =
        app.ok("_acpmux/plan/compare", json!({"sessionId": chat, "buildId": run_id})).await;
    let rows = swapped["builds"].as_array().unwrap();
    let row3 = rows.iter().find(|b| b["sessionId"] == runs[3]["sessionId"]).unwrap();
    assert!(
        row3["error"].as_str().is_some_and(|e| e.contains("not this run's worktree")),
        "{swapped}"
    );
    assert!(
        rows.iter()
            .filter(|b| b["sessionId"] != runs[3]["sessionId"])
            .all(|b| b.get("error").is_none()),
        "{swapped}"
    );
    // Keep the second and drop the rest: their chats close and their worktrees go, archived. A
    // Keep that recorded the winner and stopped (here, one that removed nothing) is finished by
    // the next: its retry removes what the first left.
    let keep = runs[1]["sessionId"].as_str().unwrap().to_owned();
    let first = app
        .ok("_acpmux/plan/keep", json!({"sessionId": chat, "buildId": run_id, "keep": keep}))
        .await;
    assert_eq!(first["keptSessionId"], json!(keep), "{first}");
    assert!(Path::new(&run_roots[0]).is_dir(), "a Keep without removeOthers removes nothing");
    let kept = app
        .ok(
            "_acpmux/plan/keep",
            json!({"sessionId": chat, "buildId": run_id, "keep": keep, "removeOthers": true}),
        )
        .await;
    assert_eq!(kept["keptSessionId"], json!(keep), "{kept}");
    // Neither chat tagged in is one of these runs: the daemon never started either as one. Both
    // stay open, unarchived, with their worktrees.
    assert!(kept["builds"].as_array().unwrap().iter().all(|b| b["sessionId"] != earlier), "{kept}");
    let removed = kept["removed"].as_array().unwrap();
    assert!(
        removed.iter().all(|r| r["sessionId"] != earlier && r["sessionId"] != plain_id),
        "{kept}"
    );
    assert!(
        kept["builds"].as_array().unwrap().iter().all(|b| b["sessionId"] != plain_id),
        "{kept}"
    );
    assert!(Path::new(&plain_root).is_dir(), "the ordinary sub-session's worktree stays: {kept}");
    let plain_session = hub.resolve(plain_id.as_str().unwrap()).unwrap();
    let status = plain_session.meta().status;
    assert_ne!(status, acpmux::store::SessionStatus::Closed, "the ordinary sub-session stays open");
    assert!(!plain_session.meta().tags.contains_key("archived"), "and unarchived");
    assert_eq!(removed.len(), 3, "{kept}");
    let (gone, stayed): (Vec<&Value>, Vec<&Value>) =
        removed.iter().partition(|r| r["sessionId"] != runs[3]["sessionId"]);
    assert!(gone.iter().all(|r| r["removed"] == json!(true)), "{kept}");
    // Each went through worktree care's archive first; its branch stays to restore it from.
    assert!(gone.iter().all(|r| r["archive"].as_str().is_some_and(|a| !a.is_empty())), "{kept}");
    assert_eq!(stayed.len(), 1, "{kept}");
    assert_eq!(stayed[0]["removed"], json!(false), "{kept}");
    assert!(
        Path::new(&run_roots[3]).join("MINE").is_file(),
        "the folder at its path stays: {kept}"
    );
    for (i, b) in runs.iter().enumerate().filter(|(i, _)| *i != 1) {
        let branch = b["worktree"]["branch"].as_str().unwrap();
        let out = std::process::Command::new("git")
            .arg("-C")
            .arg(&repo)
            .args(["rev-parse", "--verify", "--quiet", &format!("refs/heads/{branch}")])
            .output()
            .unwrap();
        assert!(out.status.success(), "run {i}'s branch {branch} stays");
    }
    assert!(!Path::new(&run_roots[0]).exists() && !Path::new(&run_roots[2]).exists(), "{kept}");
    assert!(Path::new(&run_roots[1]).join("NOTICE").is_file(), "the kept run stays");
    // Keeping it again changes nothing; keeping another run (a second pane's stale choice) is
    // refused, so it never discards the kept one.
    let again = app
        .ok(
            "_acpmux/plan/keep",
            json!({"sessionId": chat, "buildId": run_id, "keep": keep, "removeOthers": true}),
        )
        .await;
    assert_eq!(again["keptSessionId"], json!(keep), "{again}");
    assert!(
        again["removed"].as_array().unwrap().iter().all(|r| r["removed"] == json!(false)),
        "a retry removes nothing more: {again}"
    );
    assert!(Path::new(&run_roots[3]).join("MINE").is_file(), "{again}");
    let other = runs[0]["sessionId"].as_str().unwrap();
    let stale = app
        .call(
            "_acpmux/plan/keep",
            json!({"sessionId": chat, "buildId": run_id, "keep": other, "removeOthers": true}),
        )
        .await;
    assert_eq!(reason(&stale), "plan_build.already_kept", "{stale}");
    assert!(Path::new(&run_roots[1]).join("NOTICE").is_file(), "the kept run still stays");
    // The plan builds' Keep above, without removeOthers, left its other worktree, and neither
    // forged tag reached it.
    assert!(Path::new(&roots[0]).join("LICENSE").is_file(), "{kept}");

    let _ = std::fs::remove_dir_all(&root);
}
