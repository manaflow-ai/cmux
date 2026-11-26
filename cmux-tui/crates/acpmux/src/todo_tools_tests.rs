use super::*;
use serde_json::json;

#[test]
fn a_plan_is_dropped() {
    let plan = json!({"sessionUpdate": "plan", "entries": [{"content": "x", "status": "pending"}]});
    assert!(drops("plan-chat", &plan));
}

#[test]
fn a_todo_call_and_its_updates_are_dropped_until_the_turn_ends() {
    let s = "todo-chat";
    let call = json!({"sessionUpdate": "tool_call", "toolCallId": "c1", "title": "todo_write",
                      "status": "in_progress"});
    let done =
        json!({"sessionUpdate": "tool_call_update", "toolCallId": "c1", "status": "completed"});
    assert!(drops(s, &call));
    assert!(drops(s, &call), "asked twice: the tap, then the hub");
    assert!(drops(s, &done));
    assert!(drops(s, &done));
    let other =
        json!({"sessionUpdate": "tool_call_update", "toolCallId": "c2", "status": "completed"});
    assert!(!drops(s, &other));
    forget(s);
    assert!(!drops(s, &done), "a late result after the turn passes");
}

#[test]
fn todo_tools_are_known_by_any_spelling_or_by_their_input() {
    let s = "spelling-chat";
    for (id, title) in
        [("a", "TodoWrite"), ("b", "write_todos"), ("c", "todowrite"), ("d", "update_plan")]
    {
        let call = json!({"sessionUpdate": "tool_call", "toolCallId": id, "title": title});
        assert!(drops(s, &call), "{title}");
    }
    let by_input = json!({"sessionUpdate": "tool_call", "toolCallId": "e", "title": "Update todos",
                          "rawInput": {"todos": [{"content": "x", "status": "pending"}]}});
    assert!(drops(s, &by_input));
    let other_tool = json!({"sessionUpdate": "tool_call", "toolCallId": "s", "title": "sync_issues",
                            "rawInput": {"todos": [{"content": "x", "status": "open"}]}});
    assert!(!drops(s, &other_tool), "a tool named for something else keeps its todos input");
    let plan_ask = json!({"sessionUpdate": "tool_call", "toolCallId": "p", "title": "Ready to code?",
                          "kind": "switch_mode", "rawInput": {"plan": "1. x",
                          "todos": [{"content": "x", "status": "pending"}]}});
    assert!(!drops(s, &plan_ask), "plan mode's approval stays");
    let script = json!({"sessionUpdate": "tool_call", "toolCallId": "x", "title": "todo-read",
                        "kind": "execute", "rawInput": {"command": "todo-read"}});
    assert!(!drops(s, &script), "a shell command named like a to-do tool runs as a command");
    for (id, title) in [("f", "Bash"), ("g", "Task"), ("h", "Read todo.md")] {
        let call = json!({"sessionUpdate": "tool_call", "toolCallId": id, "title": title});
        assert!(!drops(s, &call), "{title}");
    }
    forget(s);
}

#[test]
fn claudes_task_todo_tools_are_dropped_but_its_subagent_and_background_tools_stay() {
    let s = "claude-task-chat";
    for (id, tool) in
        [("a", "TaskCreate"), ("b", "TaskUpdate"), ("c", "TaskList"), ("d", "TaskGet")]
    {
        let call = json!({"sessionUpdate": "tool_call", "toolCallId": id, "title": tool,
                          "_meta": {"claude": {"tool": tool}}});
        assert!(drops(s, &call), "{tool}");
    }
    for (id, tool) in [("e", "Task"), ("f", "TaskOutput"), ("g", "TaskStop"), ("h", "Agent")] {
        let call = json!({"sessionUpdate": "tool_call", "toolCallId": id, "title": tool,
                          "_meta": {"claude": {"tool": tool}}});
        assert!(!drops(s, &call), "{tool}");
    }
    // Only Claude's own name counts: another agent's tool titled TaskCreate is its own.
    let other = json!({"sessionUpdate": "tool_call", "toolCallId": "i", "title": "TaskCreate"});
    assert!(!drops(s, &other));
    forget(s);
}

#[test]
fn held_ids_and_chats_are_bounded_and_the_oldest_chat_goes() {
    let mut held = Held::default();
    hold(&mut held, "in-flight", "c");
    for chat in 0..MAX_CHATS + 10 {
        hold(&mut held, &format!("chat-{chat}"), "c");
        if chat % 10 == 0 {
            hold(&mut held, "in-flight", "c");
        }
    }
    assert_eq!(held.chats.len(), MAX_CHATS);
    assert!(held.chats.contains_key("in-flight"), "a chat that keeps holding ids stays");
    assert!(!held.chats.contains_key("chat-0"), "the chat that held one longest ago goes");
    for id in 0..MAX_HELD + 5 {
        hold(&mut held, "busy", &id.to_string());
    }
    assert_eq!(held.chats["busy"].1.len(), MAX_HELD);
    assert_eq!(held.chats.len(), MAX_CHATS);
}

#[test]
fn a_new_call_under_a_held_id_is_not_dropped() {
    let s = "reuse-chat";
    assert!(drops(
        s,
        &json!({"sessionUpdate": "tool_call", "toolCallId": "c1", "title": "todo_write"})
    ));
    let bash = json!({"sessionUpdate": "tool_call", "toolCallId": "c1", "title": "Bash"});
    assert!(!drops(s, &bash));
    assert!(!drops(s, &json!({"sessionUpdate": "tool_call_update", "toolCallId": "c1"})));
    forget(s);
}
