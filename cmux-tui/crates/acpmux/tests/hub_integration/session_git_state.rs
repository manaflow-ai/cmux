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
