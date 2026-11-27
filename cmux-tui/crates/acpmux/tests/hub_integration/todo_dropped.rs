//! cmux shows no agent to-do list: Claude Code's TodoWrite call never reaches the log or a client,
//! and Claude Code starts without its to-do tools (TaskCreate, TaskUpdate), so neither makes a
//! `plan` (acpmux `todo_tools.rs`).

use super::*;

/// The kinds and tool names a chat's log holds.
fn logged(hub: &Hub, id: &str) -> (Vec<String>, Vec<String>) {
    let events = hub.events(id, 0, 10_000).unwrap();
    let kinds = events.iter().map(|e| e.kind.clone()).collect();
    let tools = events
        .iter()
        .filter(|e| e.kind == "tool_call")
        .filter_map(|e| {
            let update = e.msg.pointer("/params/update")?;
            update
                .pointer("/_meta/claude/tool")
                .or_else(|| update.get("title"))
                .and_then(Value::as_str)
                .map(str::to_owned)
        })
        .collect();
    (kinds, tools)
}

#[tokio::test]
async fn a_claude_todo_write_is_never_logged() {
    let root = std::env::temp_dir().join(format!("acpmux-todo-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c) = claude_setup(&claude, &[]).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "todo-probe"}]});
    c.request(method::SESSION_PROMPT, prompt).await.unwrap();

    let (kinds, tools) = logged(&hub, &id);
    assert!(!kinds.iter().any(|k| k == "plan"), "{kinds:?}");
    assert!(!tools.iter().any(|t| t == "TodoWrite"), "{tools:?}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn claude_starts_without_its_todo_tools() {
    let root = std::env::temp_dir().join(format!("acpmux-tasks-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    // Not even a profile that asks for them gets them.
    let (hub, mut c) = claude_setup(&claude, &[("CLAUDE_CODE_ENABLE_TODO_TOOLS", "1")]).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    // The fake calls its task tools only when acpmux launched it with them on.
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "task-probe"}]});
    c.request(method::SESSION_PROMPT, prompt).await.unwrap();

    let (kinds, tools) = logged(&hub, &id);
    assert!(!kinds.iter().any(|k| k == "plan"), "{kinds:?}");
    assert!(!tools.iter().any(|t| t.starts_with("Task")), "{tools:?}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}
