//! `acpmux offer-mcp`: the agent's `offer_session` tool (cx-807da), an MCP
//! stdio server for one agent session that `agent_tools.rs` registers. A
//! call records the offer (`hub/offers.rs`) and returns at once: the chat
//! shows a chip, and the person starts the parallel chat or dismisses it.
//! Codex gets the same server through its MCP config.

use crate::client::Client;
use crate::rpc::method;
use crate::secret_mcp::error_result;
use anyhow::Result;
use serde_json::{Value, json};

pub const SERVER_NAME: &str = "cmux-sessions";
/// The session that offers, set in this server's own env.
pub const SESSION_ENV: &str = "ACPMUX_OFFER_SESSION";

fn tools() -> Value {
    json!([{
        "name": "offer_session",
        "description": "Offer the user a new chat, running in parallel, for work you noticed that is outside the task at hand (a bug, a follow-up, a cleanup). cmux shows the offer as a chip in this chat; if the user accepts, a new agent session starts with your prompt (in a new git worktree when worktree is true) while this chat goes on. Returns at once: do not wait for an answer, and do not do that work here. Offer only work the user is likely to want, at most a few per task.",
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
    }])
}

/// Runs the server on stdin and stdout.
pub async fn run() -> Result<()> {
    crate::secret_mcp::serve(
        SERVER_NAME,
        SESSION_ENV,
        tools(),
        |daemon, session, params| async move { call(&daemon, &session, &params).await },
    )
    .await
}

async fn call(daemon: &Client, session: &str, params: &Value) -> Value {
    if params["name"] != "offer_session" {
        return error_result(format!(
            "unknown tool: {}",
            params["name"].as_str().unwrap_or_default()
        ));
    }
    let mut request = params.get("arguments").cloned().unwrap_or_else(|| json!({}));
    if !request.is_object() {
        return error_result("arguments must be an object".to_owned());
    }
    request["sessionId"] = Value::String(session.to_owned());
    match daemon.request(method::MUX_OFFER_SESSION, request).await {
        Ok(result) => {
            let text = "Offered. The user sees a chip in this chat and can start it as a new chat; carry on with your task.";
            json!({"content": [{"type": "text", "text": text}], "structuredContent": result, "isError": false})
        }
        Err(e) => error_result(format!("{e:#}")),
    }
}
