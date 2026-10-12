//! Claude's background shells (cx-ncc.84): a Bash call that runs in the
//! background is a `local_bash` task to Claude Code, and its
//! `task_notification` ends it. acpmux sends each end as a
//! `background_task_update` naming the call, its command and how it ended, so
//! clients can note it in the transcript and list the chat's background tasks.

use super::*;

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
