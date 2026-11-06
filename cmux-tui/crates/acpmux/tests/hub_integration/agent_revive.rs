use super::super::*;
use std::path::Path;
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
    let resumed = &records(&hub, &id, "user_message")[1];
    let text = resumed["text"].as_str().unwrap();
    assert!(text.contains("agent process exit"), "{text}");
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
    assert_eq!(prompt_ids(&hub, &id).len(), 1);
    assert_eq!(status(&hub, &id), "disconnected");
}

#[tokio::test]
async fn a_limit_is_resumed_even_when_the_agent_dies_of_it() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![20]);
    let id = new_session(&mut c, "limit").await;
    let _ = c.request(method::SESSION_PROMPT, prompt(&id, "limit: x", None)).await;
    let died = new_session(&mut c, "limit-died").await;
    let r = c
        .request(
            method::SESSION_PROMPT,
            // Keep this integration test fast; the real Claude clock hint is covered by
            // reset_hint unit tests, while this exercises the same usage-limit recovery path.
            prompt(&died, "die: You've hit your limit · retry after 20ms", None),
        )
        .await;
    assert!(r.unwrap_err().contains("hit your limit"));
    until("the limit continuation completes", || records(&hub, &died, "turn_result").len() >= 2)
        .await;
    assert!(kinds(&hub, &died).iter().any(|k| k == "auto_resume_scheduled"));
    assert!(prompt_ids(&hub, &died).len() >= 2);
    let summary = hub.session_summary(&hub.resolve(&died).unwrap());
    assert_eq!(summary["status"], "ready", "{summary}");
    assert_eq!(summary["lastTurn"]["status"], "completed", "{summary}");
}

fn git(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args([
            "-c",
            "user.name=acpmux",
            "-c",
            "user.email=acpmux@example.com",
            "-c",
            "commit.gpgsign=false",
        ])
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

#[tokio::test]
async fn deleted_worktrees_return_without_running_repository_filters() {
    for source in ["branch", "origin", "last commit", "detached"] {
        let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
        let dir = std::env::temp_dir().join(format!("acpmux-revive-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        let dir = std::fs::canonicalize(dir).unwrap();
        let (repo, wt, marker) = (dir.join("repo"), dir.join("lane"), dir.join("smudged"));
        std::fs::create_dir_all(&repo).unwrap();
        git(&repo, &["init", "-q", "-b", "main"]);
        std::fs::write(repo.join(".gitattributes"), "*.txt filter=mark\n").unwrap();
        std::fs::write(repo.join("a.txt"), "words\n").unwrap();
        git(&repo, &["add", "."]);
        git(&repo, &["commit", "-qm", "init"]);
        let head = git(&repo, &["rev-parse", "HEAD"]);
        let mode = if source == "detached" { "--detach" } else { "-b" };
        let mut args = vec!["worktree", "add", "-q", mode];
        if source != "detached" {
            args.push("lane");
        }
        args.extend([wt.to_str().unwrap(), &head]);
        git(&repo, &args);
        git(
            &repo,
            &["config", "filter.mark.smudge", &format!("touch '{}'; cat", marker.display())],
        );
        git(&repo, &["config", "filter.mark.required", "true"]);
        let s = c.request(method::SESSION_NEW, json!({"cwd": wt, "mcpServers": []})).await.unwrap();
        let id = s["sessionId"].as_str().unwrap();
        c.request(method::SESSION_PROMPT, prompt(id, "hello", None)).await.unwrap();
        let session = hub.resolve(id).unwrap();
        assert!(session.meta().worktree.is_some());
        hub.detach_child(&session).await;
        std::fs::remove_dir_all(&wt).unwrap();
        git(&repo, &["worktree", "prune"]);
        if source == "origin" {
            git(&repo, &["update-ref", "refs/remotes/origin/lane", &head]);
        }
        if matches!(source, "origin" | "last commit") {
            git(&repo, &["branch", "-D", "lane"]);
        }
        c.request(method::SESSION_PROMPT, prompt(id, "back", None)).await.unwrap();
        assert_eq!(git(&wt, &["rev-parse", "HEAD"]), head);
        let branch = git(&wt, &["rev-parse", "--abbrev-ref", "HEAD"]);
        assert_eq!(branch, if matches!(source, "branch" | "origin") { "lane" } else { "HEAD" });
        assert_eq!(std::fs::read_to_string(wt.join("a.txt")).unwrap(), "words\n");
        assert!(!marker.exists(), "repository smudge filter ran");
        assert_eq!(records(&hub, id, "worktree_recreated").len(), 1);
        hub.detach_child(&session).await;
        std::fs::remove_dir_all(&wt).unwrap();
        std::fs::remove_dir_all(&repo).unwrap();
        let error =
            c.request(method::SESSION_PROMPT, prompt(id, "missing", None)).await.unwrap_err();
        assert!(error.contains("session.folder_missing"), "{error}");
        assert_eq!(session.meta().cwd, wt);
        let _ = std::fs::remove_dir_all(dir);
    }
}
