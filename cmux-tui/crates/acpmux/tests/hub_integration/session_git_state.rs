//! A session records its folder's git branch and HEAD commit as they were
//! when it started (hq#1920), so a later report can join it to the pull
//! request it produced. A fork records its own folder's state at fork time.

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
