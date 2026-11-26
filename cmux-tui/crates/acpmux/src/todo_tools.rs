//! cmux shows no agent to-do list. Claude Code runs without its to-do tools (`agent/command.rs`
//! removes `CLAUDE_CODE_ENABLE_TODO_TOOLS`) and Codex without `update_plan`
//! (`harness_limits.rs`). Other harnesses have no switch for theirs (DeepSeek Harness's
//! `todo_write`, Muse's and Gemini's `write_todos`, OpenCode's `todowrite`), so their lists are
//! dropped here, before they are logged or reach any client: every ACP `plan` update, and each
//! to-do tool call with all of its updates.
//!
//! A to-do call is known by its tool name ([`TODO_TOOLS`], in any case and spelling), or by a
//! name that says "todo" with an input of a `todos` list of steps that each have a status: a tool
//! named for something else (an issue sync with its own `todos`) is never one. Its later updates name only its id, so
//! a chat's to-do call ids are held until its turn ends ([`forget`]), at most [`MAX_HELD`].

use serde_json::Value;
use std::collections::HashMap;
use std::sync::{LazyLock, Mutex};

/// To-do tool names, lowercased with every character other than a letter or digit left out.
const TODO_TOOLS: [&str; 6] =
    ["todowrite", "todoread", "writetodos", "readtodos", "updatetodos", "updateplan"];

/// Claude Code's own to-do tools (TaskCreate and its kin, 2.1), known only by the name Claude gives
/// the call: a profile or Claude's own settings can still turn them on. Its `Task` (a subagent),
/// `TaskOutput` and `TaskStop` (background work) are not to-do tools and are never dropped.
const CLAUDE_TODO_TOOLS: [&str; 4] = ["TaskCreate", "TaskUpdate", "TaskList", "TaskGet"];

/// The most to-do call ids one chat holds; past it the oldest go.
const MAX_HELD: usize = 64;
/// The most chats that hold to-do call ids at once; past it one goes. A chat replayed by
/// `session/load`, or closed mid-turn, may never reach the turn end that lets its ids go.
const MAX_CHATS: usize = 256;

/// A tool name as [`TODO_TOOLS`] spells it.
fn plain(name: &str) -> String {
    name.chars().filter(char::is_ascii_alphanumeric).map(|c| c.to_ascii_lowercase()).collect()
}

/// Whether a `tool_call` update starts a to-do call.
fn is_todo_call(update: &Value) -> bool {
    // A shell call's title is its command (`todo-read` is a script), never a tool's name.
    let shell = update.get("kind").and_then(Value::as_str) == Some("execute");
    let names = |keys: &'static [&'static str]| {
        keys.iter()
            .filter(move |key| !(shell && **key == "title"))
            .filter_map(move |key| update.get(*key).and_then(Value::as_str))
    };
    let named = names(&["title", "name"])
        .chain(
            ["/_meta/claude/tool", "/_meta/claudeCode/toolName"]
                .iter()
                .filter_map(|at| update.pointer(at).and_then(Value::as_str)),
        )
        .any(|name| TODO_TOOLS.contains(&plain(name).as_str()));
    let claude_todo = ["/_meta/claude/tool", "/_meta/claudeCode/toolName"]
        .iter()
        .filter_map(|at| update.pointer(at).and_then(Value::as_str))
        .any(|name| CLAUDE_TODO_TOOLS.contains(&name));
    // Not a plan to approve (plan mode's `rawInput.plan`, which Cursor sends with its todos).
    let plan_ask = update.get("kind").and_then(Value::as_str) == Some("switch_mode")
        || update.pointer("/rawInput/plan").is_some();
    let todos = update.pointer("/rawInput/todos").and_then(Value::as_array).is_some_and(|todos| {
        !todos.is_empty()
            && todos.iter().all(|todo| todo.get("status").is_some_and(Value::is_string))
    });
    // The input alone names no tool: only a call whose own name says "todo" counts by it.
    let says_todo = names(&["title", "name"]).any(|name| plain(name).contains("todo"));
    named || claude_todo || (todos && says_todo && !plan_ask)
}

/// The chats' held to-do call ids, each with when it last held one: past [`MAX_CHATS`] the chat that
/// held one longest ago goes, never one with a to-do call in flight now.
#[derive(Default)]
struct Held {
    tick: u64,
    chats: HashMap<String, (u64, Vec<String>)>,
}

/// Holds to-do call `id` for chat `session`: at most [`MAX_HELD`] ids a chat, [`MAX_CHATS`] chats.
fn hold(held: &mut Held, session: &str, id: &str) {
    held.tick += 1;
    if !held.chats.contains_key(session)
        && held.chats.len() >= MAX_CHATS
        && let Some(gone) =
            held.chats.iter().min_by_key(|(_, (at, _))| *at).map(|(chat, _)| chat.clone())
    {
        held.chats.remove(&gone);
    }
    let (at, ids) = held.chats.entry(session.to_owned()).or_default();
    *at = held.tick;
    if !ids.iter().any(|held| held == id) {
        if ids.len() >= MAX_HELD {
            ids.remove(0);
        }
        ids.push(id.to_owned());
    }
}

static HELD: LazyLock<Mutex<Held>> = LazyLock::new(Default::default);

/// Whether chat `session`'s `update` (a `session/update`'s `update`) is part of an agent to-do
/// list, which is never logged, shown or applied: a `plan`, a to-do tool call, or an update of
/// one. Safe to ask twice about one update (the tap, then the hub's own handling).
pub fn drops(session: &str, update: &Value) -> bool {
    let kind = update.get("sessionUpdate").and_then(Value::as_str);
    match kind {
        Some("plan") => true,
        Some("tool_call" | "tool_call_update") => {
            let Some(id) = update.get("toolCallId").and_then(Value::as_str) else {
                return false;
            };
            let mut held = HELD.lock().unwrap_or_else(|e| e.into_inner());
            if kind == Some("tool_call") && is_todo_call(update) {
                hold(&mut held, session, id);
                return true;
            }
            let Some((_, ids)) = held.chats.get_mut(session) else { return false };
            let at = ids.iter().position(|held| held == id);
            match (kind, at) {
                // A new call under a held id is another tool's: an adapter may number calls per run.
                (Some("tool_call"), Some(at)) => {
                    ids.remove(at);
                    if ids.is_empty() {
                        held.chats.remove(session);
                    }
                    false
                }
                (_, at) => at.is_some(),
            }
        }
        _ => false,
    }
}

/// Lets go of chat `session`'s to-do call ids when its turn ends, however it ends (`hub/turns.rs`).
pub fn forget(session: &str) {
    HELD.lock().unwrap_or_else(|e| e.into_inner()).chats.remove(session);
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn a_plan_is_dropped() {
        let plan =
            json!({"sessionUpdate": "plan", "entries": [{"content": "x", "status": "pending"}]});
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
}
