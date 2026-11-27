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
#[path = "todo_tools_tests.rs"]
mod tests;
