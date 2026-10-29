//! `acpmux offer-mcp`: the agent's `offer_session` tool (cx-807da), an MCP
//! stdio server for one agent session that `agent_tools.rs` registers. A
//! call records the offer (`hub/offers.rs`) and returns at once: the chat
//! shows a chip, and the person starts the parallel chat or dismisses it.
//! Codex gets the same server through its MCP config.
//!
//! `suggest_tasks` (cx-lo9yf) offers 1 to [`MAX_TASKS`] follow-ups at the end
//! of a turn: one `_acpmux/offer_session` per task, all with one fresh
//! `groupId`, which the chat shows as one card.

use crate::client::Client;
use crate::no_panic::JsonExt;
use crate::rpc::method;
use crate::secret_mcp::error_result;
use anyhow::Result;
use serde_json::{Value, json};

pub const SERVER_NAME: &str = "cmux-sessions";
/// The session that offers, set in this server's own env.
pub const SESSION_ENV: &str = "ACPMUX_OFFER_SESSION";
/// Most tasks one `suggest_tasks` call offers.
pub const MAX_TASKS: usize = 5;

fn tools() -> Value {
    json!([{
        "name": "offer_session",
        "description": "Offer the user a new chat, running in parallel, for work you noticed that is outside the task at hand (a bug, a follow-up, a cleanup). cmux shows the offer as a chip in this chat; if the user accepts, a new agent session starts with your prompt (in a new git worktree when worktree is true) while this chat goes on. Returns at once: do not wait for an answer, and do not do that work here. If the user starts it, it becomes your sub-session (get_session and wait_for_sessions read it) and its reply comes back to this chat as a message when its first turn ends. Offer only work the user is likely to want, at most a few per task (a chat holds at most 8 open offers). Use it for one suggestion in the middle of a turn; for follow-ups at the end of a turn, use suggest_tasks.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "title": {"type": "string", "description": "What the chip says: a few words, e.g. \"Fix the flaky upload test\" (at most 80 characters)."},
                "prompt": {"type": "string", "description": "The new chat's first message: the whole task, with the context it needs (files, what you saw). It starts with none of this chat's history."},
                "worktree": {"type": "boolean", "description": "Start it in a new git worktree of this project, so its changes stay apart from this chat's. Default false."},
                "cwd": {"type": "string", "description": "The folder it runs in, as an absolute path. Default: this chat's folder."},
                "harness": {"type": "string", "description": "The agent to run it, e.g. claude or codex. Default: the user's default agent."},
                "model": {"type": "string", "description": "The model to run it on. Default: the agent's default."}
            },
            "required": ["title", "prompt"]
        }
    }, {
        "name": "suggest_tasks",
        "description": "At the end of a turn, suggest up to 5 follow-up tasks (usually 2 or more) the user may want to run next, each in its own new chat in parallel: independent work your turn led to (tests or docs for what you built, a related bug you saw, the next step of a plan). cmux shows them together as one card in this chat; the user starts any or all of them, or has you do one here. Returns at once: do not do these tasks yourself and do not wait for an answer; end your turn with your usual summary. Suggest only tasks that stand alone and that the user is likely to want, not steps of the current task. Each prompt must carry its own context: a new chat starts with none of this chat's history. A started task becomes your sub-session, and when its first turn ends its reply comes back to this chat as a message. For one suggestion in the middle of a turn, use offer_session instead.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "tasks": {
                    "type": "array",
                    "minItems": 1,
                    "maxItems": MAX_TASKS,
                    "description": "The tasks, most useful first.",
                    "items": {
                        "type": "object",
                        "properties": {
                            "title": {"type": "string", "description": "What the card says: a few words, e.g. \"Add tests for the cart total\" (at most 80 characters)."},
                            "prompt": {"type": "string", "description": "The new chat's first message: the whole task, with the context it needs (files, what you saw)."},
                            "worktree": {"type": "boolean", "description": "Start it in a new git worktree of this project, so its changes stay apart from this chat's. Default false."},
                            "harness": {"type": "string", "description": "The agent to run it, e.g. claude or codex. Default: the user's default agent."},
                            "model": {"type": "string", "description": "The model to run it on. Default: the agent's default."}
                        },
                        "required": ["title", "prompt"]
                    }
                }
            },
            "required": ["tasks"]
        }
    }])
}

/// What the server tells the agent once, at `initialize` (MCP `instructions`).
pub const INSTRUCTIONS: &str = "Work the user did not ask for: suggest it with offer_session (one task) \
or suggest_tasks (a few at once) and let the user start it; start a session yourself only when the \
user asked for one.";

/// Runs the server on stdin and stdout.
pub async fn run() -> Result<()> {
    crate::secret_mcp::serve(
        SERVER_NAME,
        SESSION_ENV,
        tools(),
        Some(INSTRUCTIONS.to_owned()),
        |daemon, session, params| async move { call(&daemon, &session, &params).await },
    )
    .await
}

async fn call(daemon: &Client, session: &str, params: &Value) -> Value {
    let mut request = params.get("arguments").cloned().unwrap_or_else(|| json!({}));
    if !request.is_object() {
        return error_result("arguments must be an object".to_owned());
    }
    match params["name"].as_str().unwrap_or_default() {
        "offer_session" => {
            request.set("sessionId", Value::String(session.to_owned()));
            match daemon.request(method::MUX_OFFER_SESSION, request).await {
                Ok(result) => {
                    let text = "Offered. The user sees a chip in this chat and can start it as a new chat; carry on with your task.";
                    json!({"content": [{"type": "text", "text": text}], "structuredContent": result, "isError": false})
                }
                Err(e) => error_result(format!("{e:#}")),
            }
        }
        "suggest_tasks" => suggest_tasks(daemon, session, &request).await,
        other => error_result(format!("unknown tool: {other}")),
    }
}

/// Offers each task of `arguments.tasks` under one fresh group id.
async fn suggest_tasks(daemon: &Client, session: &str, arguments: &Value) -> Value {
    let tasks = match arguments.get("tasks").and_then(Value::as_array) {
        Some(tasks) if (1..=MAX_TASKS).contains(&tasks.len()) => tasks,
        _ => return error_result(format!("tasks must list 1 to {MAX_TASKS} tasks")),
    };
    if !tasks.iter().all(Value::is_object) {
        return error_result("each task must be an object".to_owned());
    }
    let nonce: String = crate::hub::person::new_nonce().chars().take(16).collect();
    let group = format!("g-{nonce}");
    let mut offered = Vec::new();
    for (n, task) in tasks.iter().enumerate() {
        let mut request = json!({"sessionId": session, "groupId": group});
        for key in ["title", "prompt", "worktree", "harness", "model"] {
            if let Some(value) = task.get(key) {
                request.set(key, value.clone());
            }
        }
        match daemon.request(method::MUX_OFFER_SESSION, request).await {
            Ok(result) => offered.push(result),
            Err(e) => {
                let done = if offered.is_empty() {
                    "none was offered".to_owned()
                } else {
                    format!("the first {} were offered", offered.len())
                };
                return error_result(format!("task {} was refused ({done}): {e:#}", n + 1));
            }
        }
    }
    let text = format!(
        "Suggested {} tasks. The user sees them as one card in this chat and can start each as a new chat; finish your turn.",
        offered.len()
    );
    let structured = json!({"groupId": group, "offers": offered});
    json!({"content": [{"type": "text", "text": text}], "structuredContent": structured, "isError": false})
}
