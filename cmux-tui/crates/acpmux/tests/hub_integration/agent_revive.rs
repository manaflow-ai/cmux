//! A chat whose agent process died comes back by itself (`hub/auto_resume/revive.rs`,
//! `hub/worktree_care/revive.rs`): on 2026-10-20 lane `chief-fix` sat `disconnected` for hours after
//! its agent closed mid-turn, two coordinator messages held behind it, and a reclaim job had
//! deleted the worktrees of three such lanes.
use super::super::*;
use std::path::{Path, PathBuf};
use std::process::Command;

fn records(hub: &Hub, id: &str, kind: &str) -> Vec<Value> {
    hub.events(id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == kind)
        .map(|e| e.msg)
        .collect()
}

fn kinds(hub: &Hub, id: &str) -> Vec<String> {
    hub.events(id, 0, 10_000).unwrap().into_iter().map(|e| e.kind).collect()
}

fn prompt_ids(hub: &Hub, id: &str) -> Vec<Value> {
    records(hub, id, "user_message").into_iter().map(|m| m["promptId"].clone()).collect()
}

fn agent_sid(hub: &Hub, id: &str) -> Option<String> {
    hub.resolve(id).unwrap().meta().agent_session_id
}

/// Waits (up to 20 s) until `pred` holds for the hub.
async fn until(what: &str, pred: impl Fn() -> bool) {
    for _ in 0..400 {
        if pred() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("never happened: {what}");
}

fn status(hub: &Hub, id: &str) -> Value {
    hub.session_summary(&hub.resolve(id).unwrap())["status"].clone()
}

#[tokio::test]
async fn an_agent_that_dies_mid_turn_is_restarted_on_its_conversation_and_its_queue_runs() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![50]);
    let id = new_session(&mut c, "died").await;
    let sid = agent_sid(&hub, &id);
    assert!(sid.is_some());
    c.send(method::SESSION_PROMPT, prompt(&id, "die-later: segfault in the agent", Some("p-die")))
        .await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "dying ").await;
    c.send(method::SESSION_PROMPT, prompt(&id, "then test it", Some("p-q1"))).await;
    c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-q1" && p["queued"] == true)
        .await;

    until("the held prompt ran", || prompt_ids(&hub, &id).contains(&json!("p-q1"))).await;
    assert_eq!(
        prompt_ids(&hub, &id),
        [json!("p-die"), json!("p-die~resume-1"), json!("p-q1")],
        "{:?}",
        kinds(&hub, &id)
    );
    let scheduled = records(&hub, &id, "auto_resume_scheduled");
    assert_eq!(scheduled[0]["cause"], "agent_exited", "{scheduled:?}");
    let resumed = &records(&hub, &id, "user_message")[1];
    let text = resumed["text"].as_str().unwrap();
    assert!(text.contains("agent process stopped"), "{text}");
    assert!(text.contains("segfault in the agent"), "{text}");
    assert_eq!(resumed["_meta"]["provenance"]["kind"], "auto_resume");
    // The same conversation, loaded into a new agent process in the same folder.
    assert!(kinds(&hub, &id).iter().any(|k| k == "resumed"), "{:?}", kinds(&hub, &id));
    assert_eq!(agent_sid(&hub, &id), sid);
    until("three turns ended", || records(&hub, &id, "turn_result").len() == 3).await;
    let summary = hub.session_summary(&hub.resolve(&id).unwrap());
    assert_eq!(summary["lastTurn"]["status"], "completed", "{summary}");
    assert_eq!(summary["status"], "ready", "{summary}");
}

#[tokio::test]
async fn an_agent_that_exits_between_turns_leaves_the_chat_idle_and_the_next_prompt_loads_it() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![20]);
    let id = new_session(&mut c, "between").await;
    let sid = agent_sid(&hub, &id);
    c.request(method::SESSION_PROMPT, prompt(&id, "answer-then-exit", None)).await.unwrap();
    until("the chat is idle", || status(&hub, &id) == "idle").await;
    let exited = records(&hub, &id, "agent_exited");
    assert_eq!(exited.len(), 1, "{:?}", kinds(&hub, &id));
    assert_eq!(exited[0]["betweenTurns"], true);
    assert!(!kinds(&hub, &id).iter().any(|k| k.starts_with("auto_resume")));

    c.request(method::SESSION_PROMPT, prompt(&id, "hello", None)).await.unwrap();
    assert!(kinds(&hub, &id).iter().any(|k| k == "resumed"), "{:?}", kinds(&hub, &id));
    assert_eq!(agent_sid(&hub, &id), sid);
    assert_eq!(status(&hub, &id), "ready");
}

#[tokio::test]
async fn a_prompt_during_the_backoff_fires_the_continuation_now_and_runs_after_it() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    // A wait no test outlasts: only the prompt below can end it.
    hub.config.write().await.auto_resume_delays_ms = Some(vec![600_000]);
    let id = new_session(&mut c, "hurry").await;
    let r = c.request(method::SESSION_PROMPT, prompt(&id, "die: boom", Some("p-die"))).await;
    assert!(r.unwrap_err().contains("agent process closed"));
    until("the continuation waits", || !records(&hub, &id, "auto_resume_scheduled").is_empty())
        .await;
    assert_eq!(status(&hub, &id), "disconnected");

    let next = c.request(method::SESSION_PROMPT, prompt(&id, "the next message", Some("p-next")));
    let next = tokio::time::timeout(Duration::from_secs(15), next).await.expect("never ran");
    next.unwrap();
    assert_eq!(
        prompt_ids(&hub, &id),
        [json!("p-die"), json!("p-die~resume-1"), json!("p-next")],
        "{:?}",
        kinds(&hub, &id)
    );
    assert_eq!(records(&hub, &id, "auto_resume_hurried").len(), 1);
    until("both turns ended", || records(&hub, &id, "turn_result").len() == 3).await;
    let results = records(&hub, &id, "turn_result");
    assert_eq!(results[1]["status"], "completed", "{results:?}");
    assert_eq!(results[2]["status"], "completed", "{results:?}");
}

#[tokio::test]
async fn stop_during_the_wait_keeps_a_dead_agent_from_resuming() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![400]);
    let id = new_session(&mut c, "stopped").await;
    let _ = c.request(method::SESSION_PROMPT, prompt(&id, "die: boom", None)).await;
    c.request(method::SESSION_CANCEL, json!({"sessionId": id})).await.unwrap();
    until("the continuation is skipped", || !records(&hub, &id, "auto_resume_skipped").is_empty())
        .await;
    let skipped = records(&hub, &id, "auto_resume_skipped");
    assert_eq!(skipped[0]["skipped"], "stopped");
    assert_eq!(skipped[0]["cause"], "agent_exited");
    assert_eq!(prompt_ids(&hub, &id).len(), 1);
    assert_eq!(status(&hub, &id), "disconnected");
}

/// A limit is moved to another account or host (the fallback profile, or the reconciler that
/// reads `lastTurn` and `status`), never continued here.
#[tokio::test]
async fn a_limit_is_never_resumed_even_when_the_agent_dies_of_it() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![20]);
    let id = new_session(&mut c, "limit").await;
    let _ = c.request(method::SESSION_PROMPT, prompt(&id, "limit: x", None)).await;
    let died = new_session(&mut c, "limit-died").await;
    let r = c
        .request(
            method::SESSION_PROMPT,
            prompt(&died, "die: You've hit your limit · resets 3pm", None),
        )
        .await;
    assert!(r.unwrap_err().contains("hit your limit"));
    tokio::time::sleep(Duration::from_millis(400)).await;
    for id in [&id, &died] {
        assert!(
            !kinds(&hub, id).iter().any(|k| k.starts_with("auto_resume")),
            "{:?}",
            kinds(&hub, id)
        );
        assert_eq!(prompt_ids(&hub, id).len(), 1);
    }
    let summary = hub.session_summary(&hub.resolve(&died).unwrap());
    assert_eq!(summary["status"], "disconnected", "{summary}");
    assert_eq!(summary["lastTurn"]["status"], "failed", "{summary}");
    assert!(summary["lastTurn"]["errorText"].as_str().unwrap().contains("hit your limit"));
}

/// A fresh folder for one test, canonical (macOS's temp dir is a symlink).
fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("acpmux-revive-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::canonicalize(dir).unwrap()
}

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

/// Ends the session's agent and deletes its worktree folder, as a reclaim job does.
async fn reclaim(hub: &Arc<Hub>, id: &str, wt: &Path) {
    hub.detach_child(&hub.resolve(id).unwrap()).await;
    std::fs::remove_dir_all(wt).unwrap();
}

/// What the agent replied in the session's last turn.
fn reply(hub: &Hub, id: &str) -> String {
    hub.resolve(id).unwrap().meta().preview.unwrap_or_default()
}

#[tokio::test]
async fn a_deleted_worktree_is_added_back_before_the_agent_starts_and_the_agent_is_told() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let dir = scratch("worktree");
    let (repo, lanes) = (dir.join("repo"), dir.join("lanes"));
    let wt = lanes.join("lane");
    std::fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "-q", "-b", "main"]);
    std::fs::write(repo.join("README"), "hello\n").unwrap();
    git(&repo, &["add", "README"]);
    git(&repo, &["commit", "-q", "-m", "init"]);
    git(&repo, &["worktree", "add", "-q", "-b", "lane", wt.to_str().unwrap()]);
    let head = git(&wt, &["rev-parse", "HEAD"]);
    let s = c.request(method::SESSION_NEW, json!({"cwd": wt, "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.request(method::SESSION_PROMPT, prompt(&id, "hello", None)).await.unwrap();
    assert!(!reply(&hub, &id).contains("[acpmux]"), "{}", reply(&hub, &id));
    let saved = hub.resolve(&id).unwrap().meta().worktree.expect("the worktree is recorded");
    assert_eq!((saved.branch.as_deref(), &saved.root), (Some("lane"), &wt));
    let shown = wt.display().to_string();

    // The local branch is there: the worktree comes back on it.
    reclaim(&hub, &id, &wt).await;
    c.request(method::SESSION_PROMPT, prompt(&id, "hello again", None)).await.unwrap();
    let made = records(&hub, &id, "worktree_recreated");
    assert_eq!(made.len(), 1, "{:?}", kinds(&hub, &id));
    assert_eq!((&made[0]["branch"], &made[0]["from"]), (&json!("lane"), &json!("branch")));
    assert_eq!(git(&wt, &["rev-parse", "--abbrev-ref", "HEAD"]), "lane");
    assert_eq!(std::fs::read_to_string(wt.join("README")).unwrap(), "hello\n");
    let told = format!("[acpmux] your cwd {shown} was missing; recreated it from branch lane.");
    assert!(reply(&hub, &id).contains(&told), "{}", reply(&hub, &id));

    // A live agent whose folder went: the turn brings it back before the prompt, and the agent
    // starts again in it (the one that ran is still in the deleted folder).
    std::fs::remove_dir_all(&wt).unwrap();
    git(&repo, &["worktree", "prune"]);
    git(&repo, &["remote", "add", "origin", repo.to_str().unwrap()]);
    git(&repo, &["update-ref", "refs/remotes/origin/lane", "lane"]);
    git(&repo, &["branch", "-q", "-D", "lane"]);
    c.request(method::SESSION_PROMPT, prompt(&id, "cwd-probe", None)).await.unwrap();
    let made = records(&hub, &id, "worktree_recreated");
    assert_eq!(made.len(), 2, "{:?}", kinds(&hub, &id));
    assert_eq!(made[1]["from"], "origin");
    assert_eq!(git(&wt, &["rev-parse", "--abbrev-ref", "HEAD"]), "lane");
    assert_eq!(git(&wt, &["rev-parse", "--abbrev-ref", "lane@{upstream}"]), "origin/lane");
    let said = reply(&hub, &id);
    assert!(said.starts_with(&format!("echo: cwd: {shown} |")), "{said}");
    assert!(said.contains("recreated it from origin/lane as branch lane."), "{said}");
    assert_eq!(git(&wt, &["status", "--porcelain"]), "");

    // The branch is gone everywhere (merged and deleted): back at its last commit, detached.
    reclaim(&hub, &id, &wt).await;
    git(&repo, &["worktree", "prune"]);
    git(&repo, &["update-ref", "-d", "refs/remotes/origin/lane"]);
    git(&repo, &["branch", "-q", "-D", "lane"]);
    c.request(method::SESSION_PROMPT, prompt(&id, "once more", None)).await.unwrap();
    let made = records(&hub, &id, "worktree_recreated");
    assert_eq!(made.len(), 3, "{:?}", kinds(&hub, &id));
    assert_eq!(made[2]["from"], "its last commit");
    assert_eq!(git(&wt, &["rev-parse", "HEAD"]), head);
    assert_eq!(git(&wt, &["rev-parse", "--abbrev-ref", "HEAD"]), "HEAD");
    assert!(reply(&hub, &id).contains("branch lane is gone, so recreated it at its last commit"));

    // It cannot be added back (its repository is gone too). With no agent running, the prompt
    // is refused, retryably, naming the folder (a send keeps it queued), and nothing moves.
    reclaim(&hub, &id, &wt).await;
    std::fs::remove_dir_all(&repo).unwrap();
    let refused = c.request(method::SESSION_PROMPT, prompt(&id, "cwd-probe", None)).await;
    assert!(refused.unwrap_err().contains("session.folder_missing"));
    assert_eq!(records(&hub, &id, "worktree_recreate_failed").len(), 1, "{:?}", kinds(&hub, &id));
    assert_eq!(hub.resolve(&id).unwrap().meta().cwd, wt);
    // Made again by hand as a plain folder, it is no longer a worktree (its record goes). With
    // its agent running, the turn moves the session to the folder above, and the agent is told.
    std::fs::create_dir_all(&wt).unwrap();
    c.request(method::SESSION_PROMPT, prompt(&id, "hello", None)).await.unwrap();
    std::fs::remove_dir_all(&wt).unwrap();
    c.request(method::SESSION_PROMPT, prompt(&id, "cwd-probe", None)).await.unwrap();
    let moved = records(&hub, &id, "cwd_fallback");
    assert_eq!(moved.len(), 1, "{:?}", kinds(&hub, &id));
    assert_eq!(moved[0]["to"], json!(lanes));
    assert_eq!(hub.resolve(&id).unwrap().meta().cwd, lanes);
    let said = reply(&hub, &id);
    assert!(said.starts_with(&format!("echo: cwd: {} |", lanes.display())), "{said}");
    assert!(
        said.contains(&format!(
            "[acpmux] your cwd {shown} was missing; it was not a git worktree acpmux knew"
        )),
        "{said}"
    );
    assert!(said.contains(&format!("running in {} instead.", lanes.display())), "{said}");
    assert!(!wt.exists());
    let _ = std::fs::remove_dir_all(&dir);
}

/// A detached worktree is recorded too, and comes back at its commit, detached.
#[tokio::test]
async fn a_deleted_detached_worktree_comes_back_at_its_commit() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let dir = scratch("detached");
    let (repo, wt) = (dir.join("repo"), dir.join("lanes").join("lane"));
    std::fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "-q", "-b", "main"]);
    std::fs::write(repo.join("README"), "hello\n").unwrap();
    git(&repo, &["add", "README"]);
    git(&repo, &["commit", "-q", "-m", "init"]);
    let head = git(&repo, &["rev-parse", "HEAD"]);
    git(&repo, &["worktree", "add", "-q", "--detach", wt.to_str().unwrap(), &head]);
    let s = c.request(method::SESSION_NEW, json!({"cwd": wt, "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.request(method::SESSION_PROMPT, prompt(&id, "hello", None)).await.unwrap();
    let saved = hub.resolve(&id).unwrap().meta().worktree.expect("the worktree is recorded");
    assert_eq!((saved.branch, saved.head.as_deref()), (None, Some(head.as_str())));

    reclaim(&hub, &id, &wt).await;
    c.request(method::SESSION_PROMPT, prompt(&id, "hello again", None)).await.unwrap();
    let made = records(&hub, &id, "worktree_recreated");
    assert_eq!(made.len(), 1, "{:?}", kinds(&hub, &id));
    assert_eq!(made[0]["from"], "its last commit");
    assert_eq!(git(&wt, &["rev-parse", "HEAD"]), head);
    assert_eq!(git(&wt, &["rev-parse", "--abbrev-ref", "HEAD"]), "HEAD");
    let said = reply(&hub, &id);
    assert!(said.contains("recreated it at its last commit"), "{said}");
    assert!(!said.contains("branch  is gone"), "{said}");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A folder that stops being a linked worktree (its path reused for a plain folder) loses its
/// record: deleted later, it is not made into the old worktree again.
#[tokio::test]
async fn a_folder_that_stops_being_a_worktree_is_never_made_into_it_again() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let dir = scratch("reused");
    let (repo, lanes) = (dir.join("repo"), dir.join("lanes"));
    let wt = lanes.join("lane");
    std::fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "-q", "-b", "main"]);
    std::fs::write(repo.join("README"), "hello\n").unwrap();
    git(&repo, &["add", "README"]);
    git(&repo, &["commit", "-q", "-m", "init"]);
    git(&repo, &["worktree", "add", "-q", "-b", "lane", wt.to_str().unwrap()]);
    let s = c.request(method::SESSION_NEW, json!({"cwd": wt, "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.request(method::SESSION_PROMPT, prompt(&id, "hello", None)).await.unwrap();
    assert!(hub.resolve(&id).unwrap().meta().worktree.is_some());

    // The path is reused for a plain folder; the agent starts again there.
    reclaim(&hub, &id, &wt).await;
    git(&repo, &["worktree", "prune"]);
    std::fs::create_dir_all(&wt).unwrap();
    c.request(method::SESSION_PROMPT, prompt(&id, "hello", None)).await.unwrap();
    assert!(hub.resolve(&id).unwrap().meta().worktree.is_none(), "the old record stayed");

    reclaim(&hub, &id, &wt).await;
    let refused = c.request(method::SESSION_PROMPT, prompt(&id, "cwd-probe", None)).await;
    assert!(refused.unwrap_err().contains("session.folder_missing"));
    assert!(records(&hub, &id, "worktree_recreated").is_empty(), "{:?}", kinds(&hub, &id));
    assert!(!wt.exists());
    let _ = std::fs::remove_dir_all(&dir);
}

/// A missing folder that was never a linked worktree is not made (acpmux makes no folder git
/// did not): the session moves to the folder above it, and the agent is told.
#[tokio::test]
async fn a_missing_plain_folder_moves_the_session_to_its_parent_and_the_agent_is_told() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let dir = scratch("plain");
    let folder = dir.join("plain").join("deeper");
    std::fs::create_dir_all(&folder).unwrap();
    let s = c.request(method::SESSION_NEW, json!({"cwd": folder, "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let sid = agent_sid(&hub, &id);
    c.request(method::SESSION_PROMPT, prompt(&id, "hello", None)).await.unwrap();
    assert!(hub.resolve(&id).unwrap().meta().worktree.is_none());
    // Its agent runs: the turn moves the session (with none running, the prompt is refused,
    // naming the folder, and kept by a send until the folder is back: `worktree_care.rs`).
    std::fs::remove_dir_all(dir.join("plain")).unwrap();
    c.request(method::SESSION_PROMPT, prompt(&id, "cwd-probe", None)).await.unwrap();
    assert!(!folder.exists() && !dir.join("plain").exists());
    assert!(records(&hub, &id, "worktree_recreated").is_empty());
    let moved = records(&hub, &id, "cwd_fallback");
    assert_eq!(moved.len(), 1, "{:?}", kinds(&hub, &id));
    assert_eq!(moved[0]["to"], json!(dir));
    let said = reply(&hub, &id);
    assert!(said.starts_with(&format!("echo: cwd: {} |", dir.display())), "{said}");
    let told = format!(
        "[acpmux] your cwd {} was missing; it was not a git worktree acpmux knew; running in {} instead.",
        folder.display(),
        dir.display()
    );
    assert!(said.contains(&told), "{said}");
    // Told once: the next turn's prompt is the person's own.
    c.request(method::SESSION_PROMPT, prompt(&id, "hello", None)).await.unwrap();
    assert!(!reply(&hub, &id).contains("[acpmux]"), "{}", reply(&hub, &id));
    assert_eq!(agent_sid(&hub, &id), sid);
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn a_prompt_sent_while_a_turn_moves_from_a_missing_folder_queues_behind_it() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let dir = scratch("behind");
    let folder = dir.join("gone");
    std::fs::create_dir_all(&folder).unwrap();
    let s = c.request(method::SESSION_NEW, json!({"cwd": folder, "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let sid = agent_sid(&hub, &id);
    c.request(method::SESSION_PROMPT, prompt(&id, "hello", None)).await.unwrap();
    // The agent is live when its folder goes: the next turn restarts it in the folder above.
    std::fs::remove_dir_all(&folder).unwrap();
    // Back to back: the second arrives while the first brings its folder back or holds its turn.
    let first = c.send(method::SESSION_PROMPT, prompt(&id, "[hold]", Some("p-first"))).await;
    let second = c.send(method::SESSION_PROMPT, prompt(&id, "hello", Some("p-second"))).await;
    let acc = c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-second").await;
    assert_eq!(acc["queued"], true, "{:?}", kinds(&hub, &id));
    let (first, second) = (c.response(first).await.0, c.response(second).await.0);
    assert!(first.is_ok() && second.is_ok(), "{first:?} {second:?}");
    let queued = records(&hub, &id, "queued");
    assert!(queued.iter().any(|q| q["promptId"] == "p-second"), "{queued:?}");
    assert_eq!(prompt_ids(&hub, &id)[1..], [json!("p-first"), json!("p-second")]);
    let moved = records(&hub, &id, "cwd_fallback");
    assert_eq!(moved.len(), 1, "{:?}", kinds(&hub, &id));
    assert_eq!(moved[0]["to"], json!(dir));
    // The agent it stopped was no death: nothing resumed, and the same conversation loaded.
    assert!(records(&hub, &id, "auto_resume_scheduled").is_empty(), "{:?}", kinds(&hub, &id));
    assert_eq!(hub.resolve(&id).unwrap().meta().cwd, dir);
    assert_eq!(agent_sid(&hub, &id), sid);
    let _ = std::fs::remove_dir_all(&dir);
}

/// A worktree comes back with none of its repository's config: a smudge filter the repository
/// names does not run in the daemon (one that hangs would hold the turn for good).
#[tokio::test]
async fn a_worktree_comes_back_without_running_the_repositorys_filters() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let dir = scratch("filter");
    let (repo, wt, marker) = (dir.join("repo"), dir.join("lane"), dir.join("smudged"));
    std::fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "-q", "-b", "main"]);
    std::fs::write(repo.join(".gitattributes"), "*.txt filter=mark\n").unwrap();
    std::fs::write(repo.join("a.txt"), "words\n").unwrap();
    git(&repo, &["add", "."]);
    git(&repo, &["commit", "-q", "-m", "init"]);
    git(&repo, &["worktree", "add", "-q", "-b", "lane", wt.to_str().unwrap()]);
    git(&repo, &["config", "filter.mark.smudge", &format!("touch '{}'; cat", marker.display())]);
    git(&repo, &["config", "filter.mark.required", "true"]);
    let s = c.request(method::SESSION_NEW, json!({"cwd": wt, "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.request(method::SESSION_PROMPT, prompt(&id, "hello", None)).await.unwrap();
    assert!(hub.resolve(&id).unwrap().meta().worktree.is_some());
    reclaim(&hub, &id, &wt).await;
    c.request(method::SESSION_PROMPT, prompt(&id, "cwd-probe", None)).await.unwrap();
    assert_eq!(records(&hub, &id, "worktree_recreated").len(), 1, "{:?}", kinds(&hub, &id));
    assert!(!marker.exists(), "the repository's smudge filter ran in the daemon");
    assert_eq!(std::fs::read_to_string(wt.join("a.txt")).unwrap(), "words\n");
    assert_eq!(git(&wt, &["rev-parse", "--abbrev-ref", "HEAD"]), "lane");
    let said = reply(&hub, &id);
    assert!(said.starts_with(&format!("echo: cwd: {} |", wt.display())), "{said}");
    let _ = std::fs::remove_dir_all(&dir);
}
