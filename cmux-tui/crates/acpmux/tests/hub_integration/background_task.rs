//! Claude's background shells (cx-ncc.84): a Bash call that runs in the
//! background is a `local_bash` task to Claude Code, and its
//! `task_notification` ends it. acpmux sends each end as a
//! `background_task_update` naming the call, its command and how it ended, so
//! clients can note it in the transcript and list the chat's background tasks.

use super::*;

/// Each `background_task_update` the chat recorded.
fn ends(hub: &Arc<Hub>, id: &str) -> Vec<Value> {
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

    let ends: Vec<Value> = hub
        .events(&id, 0, 10_000)
        .unwrap()
        .iter()
        .filter(|e| e.kind == "background_task_update")
        .map(|e| e.msg.pointer("/params/update").cloned().unwrap_or(Value::Null))
        .collect();
    assert_eq!(
        ends,
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
