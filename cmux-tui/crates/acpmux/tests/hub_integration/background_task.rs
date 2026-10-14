//! Claude's background shells (cx-ncc.84): a Bash call that runs in the
//! background is a `local_bash` task to Claude Code, and its
//! `task_notification` ends it. acpmux sends each end as a
//! `background_task_update` naming the call, its command and how it ended, so
//! clients can note it in the transcript and list the chat's background tasks.

use super::*;

/// Each `background_task_update` the chat recorded that says how a shell
/// ended (a `running` one says it went to the background).
fn ends(hub: &Arc<Hub>, id: &str) -> Vec<Value> {
    updates(hub, id).into_iter().filter(|u| u["state"] != "running").collect()
}

/// Every `background_task_update` the chat recorded.
fn updates(hub: &Arc<Hub>, id: &str) -> Vec<Value> {
    hub.events(id, 0, 10_000)
        .unwrap()
        .iter()
        .filter(|e| e.kind == "background_task_update")
        .map(|e| e.msg.pointer("/params/update").cloned().unwrap_or(Value::Null))
        .collect()
}

#[tokio::test]
async fn a_claude_background_shell_reports_how_it_ended() {
    let root = std::env::temp_dir().join(format!("acpmux-bg-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c) = claude_setup(&claude, &[]).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "bg-probe"}]});
    c.request(method::SESSION_PROMPT, prompt).await.unwrap();

    assert_eq!(
        ends(&hub, &id),
        vec![
            json!({"sessionUpdate": "background_task_update", "taskId": "b1", "toolCallId": "toolu_bg1",
                   "command": "npm run dev", "state": "stopped", "reason": "Stopped by the agent"}),
            json!({"sessionUpdate": "background_task_update", "taskId": "b2", "toolCallId": "toolu_bg2",
                   "command": "cargo test", "state": "completed", "summary": "Tests passed"}),
        ]
    );
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn a_foreground_shell_or_an_unseen_call_reports_nothing() {
    let root = std::env::temp_dir().join(format!("acpmux-bg-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c) = claude_setup(&claude, &[]).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "fg-probe"}]});
    c.request(method::SESSION_PROMPT, prompt).await.unwrap();
    assert_eq!(ends(&hub, &id), Vec::<Value>::new());
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// Claude's background shells end with its process: one still running when
/// Claude exits is reported stopped, so no client shows it running forever.
#[tokio::test]
async fn a_background_shell_left_when_claude_exits_is_reported_stopped() {
    let root = std::env::temp_dir().join(format!("acpmux-bg-{}", uuid::Uuid::now_v7()));
    let (claude, die) = (root.join("claude"), root.join("die"));
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c) =
        claude_setup(&claude, &[("FAKE_CLAUDE_DIE_IF", &die.to_string_lossy())]).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let prompt = |text: &str| json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]});
    c.request(method::SESSION_PROMPT, prompt("bg-left")).await.unwrap();
    assert_eq!(ends(&hub, &id), Vec::<Value>::new());
    std::fs::write(&die, "").unwrap();
    let _ = c.request(method::SESSION_PROMPT, prompt("lost")).await;
    let want = vec![json!({"sessionUpdate": "background_task_update", "taskId": "",
                           "toolCallId": "toolu_left", "command": "npm run dev", "state": "stopped"})];
    for _ in 0..50 {
        if ends(&hub, &id) == want {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
    assert_eq!(ends(&hub, &id), want);
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// A foreground shell moved to the background while it ran reports its end
/// like one launched there, under its own command.
#[tokio::test]
async fn a_shell_moved_to_the_background_reports_how_it_ended() {
    let root = std::env::temp_dir().join(format!("acpmux-bg-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c) = claude_setup(&claude, &[]).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "bg-moved"}]});
    c.request(method::SESSION_PROMPT, prompt).await.unwrap();
    let want = vec![json!({"sessionUpdate": "background_task_update", "taskId": "m1",
                           "toolCallId": "toolu_mv", "command": "npm run build",
                           "state": "completed", "summary": "Build finished"})];
    assert_eq!(ends(&hub, &id), want);
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// A chat whose shell still runs in the background (a dev server) keeps its
/// harness when nobody uses it: the idle reaper would end the shell with it.
/// A chat without one is still reaped.
#[tokio::test]
async fn the_idle_reaper_never_ends_a_chat_with_a_running_background_shell() {
    let root = std::env::temp_dir().join(format!("acpmux-bg-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c) = claude_setup(&claude, &[]).await;
    let clock = acpmux::clock::ManualClock::new();
    hub.set_clock(clock.clone());
    hub.set_idle_child(Some(Duration::from_secs(300)));
    let mut ids = Vec::new();
    let chats =
        [("bg-alive", "bg-running"), ("bg-none", "hi"), ("agent-bg-alive", "agent-bg-running")];
    for (name, said) in chats {
        let s = c
            .request(
                method::SESSION_NEW,
                json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": name}}}),
            )
            .await
            .unwrap();
        let id = s["sessionId"].as_str().unwrap().to_owned();
        let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": said}]});
        c.request(method::SESSION_PROMPT, prompt).await.unwrap();
        // A later turn does not forget the shell.
        let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "hi"}]});
        c.request(method::SESSION_PROMPT, prompt).await.unwrap();
        c.request(method::MUX_DETACH, json!({"sessionId": id})).await.unwrap();
        ids.push(id);
    }
    assert_eq!(updates(&hub, &ids[0]).last().map(|u| u["state"].clone()), Some(json!("running")));
    let status = |id: &str| hub.session_summary(&hub.resolve(id).unwrap())["status"].clone();
    clock.advance(Duration::from_secs(301));
    let deadline = std::time::Instant::now() + Duration::from_secs(20);
    while status(&ids[1]) != "idle" {
        assert!(std::time::Instant::now() < deadline, "the chat without a shell was never reaped");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    clock.advance(Duration::from_secs(3600));
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(status(&ids[0]), "ready", "the harness running a background shell was reaped");
    assert_eq!(
        status(&ids[2]),
        "ready",
        "the harness whose subagent runs a background shell was reaped"
    );
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// Claude Code starts with its subagent and background limits lifted (Leo
/// 2026-10-14, no caps on subagents), and a value the profile sets wins.
#[tokio::test]
async fn a_chat_starts_claude_with_its_limits_lifted_unless_the_profile_sets_one() {
    let root = std::env::temp_dir().join(format!("acpmux-limits-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c) =
        claude_setup(&claude, &[("CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH", "5")]).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "limits-probe"}]});
    c.request(method::SESSION_PROMPT, prompt).await.unwrap();
    let said: String = hub
        .events(&id, 0, 10_000)
        .unwrap()
        .iter()
        .filter(|e| e.kind == "agent_message_chunk")
        .filter_map(|e| e.msg.pointer("/params/update/content/text").and_then(Value::as_str))
        .collect();
    let knobs: Value = serde_json::from_str(&said).unwrap_or_else(|e| panic!("{e}: {said}"));
    assert_eq!(
        knobs,
        json!({
            "CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS": "1000",
            "CLAUDE_CODE_MAX_SUBAGENTS_PER_SESSION": "100000",
            "CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH": "5",
            "CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY": "64",
            "BASH_MAX_TIMEOUT_MS": "2147483647",
            // The foreground default stays Claude Code's own.
            "BASH_DEFAULT_TIMEOUT_MS": null,
        })
    );
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}
