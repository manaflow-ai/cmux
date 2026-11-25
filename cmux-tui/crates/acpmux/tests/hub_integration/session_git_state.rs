//! A session records its folder's git branch and HEAD commit as they were
//! when it started (hq#1920), so a later report can join it to the pull
//! request it produced. A fork records its own folder's state at fork time.
//! Each turn's `turn_result` records the folder's state when that turn ended,
//! so a session whose agent switches branch follows it there.

use super::*;
use std::path::{Path, PathBuf};
use std::process::Command;

/// A fresh folder for one test, canonical (macOS's temp dir is a symlink).
fn scratch(name: &str) -> PathBuf {
    let dir =
        std::env::temp_dir().join(format!("acpmux-session-git-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::canonicalize(dir).unwrap()
}

/// Runs git in `dir` and returns its trimmed output.
fn git(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=acpmux", "-c", "user.email=acpmux@example.com"])
        .args(["-c", "commit.gpgsign=false"])
        .args(args)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_COMMON_DIR")
        .env_remove("GIT_INDEX_FILE")
        .output()
        .unwrap();
    assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8_lossy(&out.stdout).trim().to_owned()
}

/// A repository at `dir` on `branch` with one commit; returns that commit.
fn repo(dir: &Path, branch: &str) -> String {
    git(dir, &["init", "-q"]);
    git(dir, &["checkout", "-q", "-b", branch]);
    git(dir, &["commit", "-q", "--allow-empty", "-m", "init"]);
    git(dir, &["rev-parse", "HEAD"])
}

async fn new_session(c: &mut TestClient, cwd: &Path) -> String {
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd, "mcpServers": []})).await.unwrap();
    s["sessionId"].as_str().unwrap().to_owned()
}

/// The session's saved meta as session.json holds it.
fn saved(hub: &Hub, id: &str) -> Value {
    serde_json::to_value(hub.resolve(id).unwrap().meta()).unwrap()
}

/// The session's `turn_result` records, oldest first.
fn turn_results(hub: &Hub, id: &str) -> Vec<Value> {
    hub.events(id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.dir == "mux" && e.kind == "turn_result")
        .map(|e| e.msg)
        .collect()
}

async fn say(c: &mut TestClient, id: &str) {
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "hi"}]});
    c.request(method::SESSION_PROMPT, prompt).await.unwrap();
}

#[tokio::test]
async fn git_state_records_the_branch_and_head_at_session_new() {
    let dir = scratch("branch");
    let head = repo(&dir, "feature/git-state");
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, &dir).await;

    let meta = saved(&hub, &id);
    assert_eq!(meta["gitBranch"], "feature/git-state", "{meta}");
    assert_eq!(meta["gitHead"], head.as_str(), "{meta}");
    let info = c.request(method::MUX_INFO, json!({"sessionId": id})).await.unwrap();
    assert_eq!(info["gitBranch"], "feature/git-state", "{info}");
    assert_eq!(info["gitHead"], head.as_str(), "{info}");

    // Started-at state: a later commit or checkout does not rewrite it.
    git(&dir, &["checkout", "-q", "-b", "later"]);
    git(&dir, &["commit", "-q", "--allow-empty", "-m", "later"]);
    let meta = saved(&hub, &id);
    assert_eq!(meta["gitBranch"], "feature/git-state", "{meta}");
    assert_eq!(meta["gitHead"], head.as_str(), "{meta}");
}

#[tokio::test]
async fn git_state_on_a_detached_head_records_only_the_head() {
    let dir = scratch("detached");
    let head = repo(&dir, "main");
    git(&dir, &["checkout", "-q", "--detach"]);
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, &dir).await;

    let meta = saved(&hub, &id);
    assert!(meta.get("gitBranch").is_none(), "{meta}");
    assert_eq!(meta["gitHead"], head.as_str(), "{meta}");
}

#[tokio::test]
async fn git_state_outside_a_repository_records_nothing() {
    let dir = scratch("plain");
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, &dir).await;

    let meta = saved(&hub, &id);
    assert!(meta.get("gitBranch").is_none(), "{meta}");
    assert!(meta.get("gitHead").is_none(), "{meta}");
    let info = c.request(method::MUX_INFO, json!({"sessionId": id})).await.unwrap();
    assert!(info["gitBranch"].is_null() && info["gitHead"].is_null(), "{info}");
    say(&mut c, &id).await;
    let turn = &turn_results(&hub, &id)[0];
    assert!(turn.get("gitBranch").is_none() && turn.get("gitHead").is_none(), "{turn}");
}

#[tokio::test]
async fn git_state_records_the_branch_each_turn_ended_on() {
    let dir = scratch("turns");
    let first = repo(&dir, "first");
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, &dir).await;
    say(&mut c, &id).await;

    // The agent switched branch between turns: the next turn records where it ended.
    git(&dir, &["checkout", "-q", "-b", "second"]);
    git(&dir, &["commit", "-q", "--allow-empty", "-m", "second"]);
    let second = git(&dir, &["rev-parse", "HEAD"]);
    say(&mut c, &id).await;

    let turns = turn_results(&hub, &id);
    assert_eq!(turns.len(), 2, "{turns:?}");
    assert_eq!((&turns[0]["gitBranch"], &turns[0]["gitHead"]), (&json!("first"), &json!(first)));
    assert_eq!((&turns[1]["gitBranch"], &turns[1]["gitHead"]), (&json!("second"), &json!(second)));
    // The session's own branch stays the one it started on.
    assert_eq!(saved(&hub, &id)["gitBranch"], "first");
}

#[tokio::test]
async fn git_state_of_a_fork_is_its_folder_at_fork_time() {
    let dir = scratch("fork");
    let first = repo(&dir, "first");
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, &dir).await;
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "hi"}]}),
    )
    .await
    .unwrap();

    git(&dir, &["checkout", "-q", "-b", "second"]);
    git(&dir, &["commit", "-q", "--allow-empty", "-m", "second"]);
    let second = git(&dir, &["rev-parse", "HEAD"]);
    let f = c.request(method::SESSION_FORK, json!({"sessionId": id, "cwd": dir})).await.unwrap();
    let fid = f["sessionId"].as_str().unwrap().to_owned();

    let fork = saved(&hub, &fid);
    assert_eq!(fork["gitBranch"], "second", "{fork}");
    assert_eq!(fork["gitHead"], second.as_str(), "{fork}");
    let parent = saved(&hub, &id);
    assert_eq!(parent["gitBranch"], "first", "{parent}");
    assert_eq!(parent["gitHead"], first.as_str(), "{parent}");
}

#[test]
fn git_state_absent_from_an_old_session_json_still_loads() {
    let old: acpmux::store::SessionMeta = serde_json::from_value(json!({
        "schema": "acpmux.session.v1",
        "id": "old",
        "name": "old",
        "harness": "fake",
        "cwd": "/tmp",
        "status": "idle",
        "createdAt": 1,
        "updatedAt": 1,
    }))
    .unwrap();
    let back = serde_json::to_value(&old).unwrap();
    assert!(back.get("gitBranch").is_none() && back.get("gitHead").is_none(), "{back}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn git_state_of_a_held_chat_follows_a_checkout_mid_session() {
    let dir = scratch("live");
    repo(&dir, "first");
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    hub.start_harness_watch();
    let id = new_session(&mut c, &dir).await;
    let attach = json!({"sessionId": id, "limit": 0});
    let attached = c.request(method::MUX_ATTACH, attach).await.unwrap();
    assert_eq!(attached["session"]["gitBranch"], "first", "{attached}");
    c.request(method::MUX_WATCH, json!({})).await.unwrap();
    let git_changed = |p: &Value| p["kind"] == "git" && p["sessionId"] == id.as_str();

    // The agent, or the person in a terminal, switches branch mid-session:
    // a client holding the chat hears it without a turn ending.
    let switched = std::time::Instant::now();
    git(&dir, &["checkout", "-q", "-b", "second"]);
    let changed = c.wait_for(method::MUX_SESSION_CHANGED, git_changed).await;
    assert_eq!(changed["session"]["gitBranch"], "second", "{changed}");
    // About a second is the goal; the bound leaves a loaded runner room.
    let took = switched.elapsed();
    assert!(took < Duration::from_secs(3), "the checkout took {took:?} to reach the watcher");
    let info = c.request(method::MUX_INFO, json!({"sessionId": id})).await.unwrap();
    assert_eq!(info["gitBranch"], "second", "{info}");
    // The branch it started on stays, for the stats and its pull request.
    assert_eq!(saved(&hub, &id)["gitBranch"], "first");

    // A detached HEAD has no branch.
    git(&dir, &["checkout", "-q", "--detach"]);
    let changed = c.wait_for(method::MUX_SESSION_CHANGED, git_changed).await;
    assert!(changed["session"]["gitBranch"].is_null(), "{changed}");
}

/// A daemon whose store is on disk, so a second hub over `dir` is a restart.
fn disk_config() -> Config {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let profile = HarnessProfile {
        kind: Default::default(),
        argv: vec!["python3".into(), fake.into()],
        env: BTreeMap::new(),
        description: None,
        fallback: None,
        family: None,
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    };
    let harnesses = BTreeMap::from([("fake".to_owned(), profile)]);
    let mut cfg = Config { harnesses, default_harness: Some("fake".into()), ..Default::default() };
    cfg.store.mode = StoreMode::Local;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    cfg
}

/// `c` holds the chat and watches every session.
async fn hold(c: &mut TestClient, id: &str) {
    c.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 0})).await.unwrap();
    c.request(method::MUX_WATCH, json!({})).await.unwrap();
}

/// Waits for the `git` change of `id` and returns the branch it names.
async fn git_changed(c: &mut TestClient, id: &str) -> Value {
    let changed = c
        .wait_for(method::MUX_SESSION_CHANGED, |p| p["kind"] == "git" && p["sessionId"] == id)
        .await;
    changed["session"]["gitBranch"].clone()
}

/// The branches the session's `git` records told, oldest first.
fn told(hub: &Hub, id: &str) -> Vec<Value> {
    let events = hub.events(id, 0, 10_000).unwrap();
    events
        .into_iter()
        .filter(|e| e.dir == "mux" && e.kind == "git")
        .map(|e| e.msg["gitBranch"].clone())
        .collect()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn git_state_a_restart_tells_no_branch_the_log_already_told() {
    let dir = scratch("restart");
    repo(&dir, "first");
    let store = scratch("restart-store");
    let cfg = disk_config();
    let hub = Hub::new(cfg.clone(), acpmux::store::open(&cfg.store, &store).unwrap());
    hub.start_harness_watch();
    let mut c = connect(&hub).await;
    let id = new_session(&mut c, &dir).await;
    hold(&mut c, &id).await;
    git(&dir, &["checkout", "-q", "-b", "second"]);
    assert_eq!(git_changed(&mut c, &id).await, "second");
    hub.shutdown_all().await;
    drop(c);
    drop(hub);

    // The next daemon reads the folder on the first attach: still `second`,
    // which the log already told, so no record; a checkout after it is one.
    let hub = Hub::new(cfg.clone(), acpmux::store::open(&cfg.store, &store).unwrap());
    hub.start_harness_watch();
    let mut c = connect(&hub).await;
    hold(&mut c, &id).await;
    git(&dir, &["checkout", "-q", "-b", "third"]);
    assert_eq!(git_changed(&mut c, &id).await, "third");
    assert_eq!(told(&hub, &id), [json!("second"), json!("third")]);
}

/// Both a recorded branch and the absence of any `git` record are restored before
/// attach. A first attach must not start a second scan over a long chat's history.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn git_state_restores_the_no_git_record_baseline_before_attach() {
    let dir = scratch("unreported");
    repo(&dir, "first");
    let store = scratch("unreported-store");
    let cfg = disk_config();
    let hub = Hub::new(cfg.clone(), acpmux::store::open(&cfg.store, &store).unwrap());
    let mut c = connect(&hub).await;
    let id = new_session(&mut c, &dir).await;
    hub.shutdown_all().await;
    drop(c);
    drop(hub);

    let hub = Hub::new(cfg.clone(), acpmux::store::open(&cfg.store, &store).unwrap());
    assert!(hub.git_branch_tracked(&id), "startup left the Git baseline for attach to scan");
    hub.start_harness_watch();
    let mut c = connect(&hub).await;
    hold(&mut c, &id).await;
    git(&dir, &["checkout", "-q", "-b", "second"]);
    assert_eq!(git_changed(&mut c, &id).await, "second");
    assert_eq!(told(&hub, &id), [json!("second")]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn git_state_of_a_purged_chat_is_forgotten() {
    let dir = scratch("purge");
    repo(&dir, "first");
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    hub.start_harness_watch();
    let id = new_session(&mut c, &dir).await;
    hold(&mut c, &id).await;
    git(&dir, &["checkout", "-q", "-b", "second"]);
    assert_eq!(git_changed(&mut c, &id).await, "second");
    assert!(hub.git_branch_tracked(&id));

    c.request("_acpmux/kill", json!({"sessionId": id, "purge": true})).await.unwrap();
    assert!(!hub.git_branch_tracked(&id), "the purged chat's branch is still kept");
}

#[test]
fn git_state_the_schema_documents_the_live_branch_and_its_record() {
    let schema: Value = serde_json::from_str(acpmux::schema::SCHEMA).unwrap();
    let types = &schema["types"];
    assert!(types["SessionSummary"]["gitBranch"].is_string(), "SessionSummary has no gitBranch");
    let kinds = types["muxEventKinds"].as_array().unwrap();
    assert!(kinds.contains(&json!("git")), "muxEventKinds has no git");
    assert!(types["git"]["gitBranch"].is_string(), "no git record");
    let changed = &schema["notifications"]["_acpmux/session_changed"]["params"]["kind"];
    assert!(changed.as_str().unwrap().contains("git"), "session_changed kind names no git");
}
