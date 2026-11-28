//! Claude's todo list (cx-ncc.80): Claude Code's TodoWrite tool call becomes
//! an ACP `plan` update with its entries, which clients draw as a checklist
//! (Codex sends `plan` itself).

use super::*;

#[tokio::test]
async fn a_claude_todo_write_becomes_an_acp_plan() {
    let root = std::env::temp_dir().join(format!("acpmux-todo-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c) = claude_setup(&claude, &[]).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "todo-probe"}]});
    c.request(method::SESSION_PROMPT, prompt).await.unwrap();

    let plans: Vec<Value> = hub
        .events(&id, 0, 10_000)
        .unwrap()
        .iter()
        .filter(|e| e.kind == "plan")
        .map(|e| e.msg.pointer("/params/update/entries").cloned().unwrap_or(Value::Null))
        .collect();
    assert_eq!(
        plans,
        vec![json!([
            {"content": "Add retry", "status": "completed", "priority": "medium"},
            {"content": "Cover it", "status": "in_progress", "priority": "medium"},
            {"content": "Update docs", "status": "pending", "priority": "medium"},
        ])]
    );
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}
