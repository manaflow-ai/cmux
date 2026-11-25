//! `acpmux forum-mcp`: the `cmux-forum` MCP stdio server every agent session
//! gets (`agent_tools.rs`), the same on every harness: post a rule, read the
//! current rules, ack one (hq#2570). Each tool is one daemon request
//! (`server/forum.rs`) over a connection that carries the session's caller
//! token from this server's own env, so the daemon knows which session posts.
//! `post`, `reply` and `search` reach the team's hosted forum through the daemon
//! (`hub/forum_hosted.rs`); each answers one JSON object as its text, which the
//! chat's card reads.

use crate::client::Client;
use crate::rpc::method;
use crate::secret_mcp::error_result;
use anyhow::Result;
use serde_json::{Value, json};

pub const SERVER_NAME: &str = "cmux-forum";
/// The session the tools act for, set in this server's env with its caller token.
pub const SESSION_ENV: &str = "ACPMUX_SESSION_ID";

fn tools() -> Value {
    json!([
        {
            "name": "announce",
            "description": "Post a rule every agent session on this Mac with cmux tools reads on its next prompt. A new post on the same key replaces the old one. A person's rule outranks yours: posting on its key only proposes a change. Only a person may post an urgent rule (it messages every live session now); urgent: true from an agent is refused.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "key": {"type": "string", "description": "What the rule is about, e.g. \"builds\". One rule per key."},
                    "body": {"type": "string", "description": "The rule, short and self-contained."},
                    "urgent": {"type": "boolean", "description": "Person only: refused for an agent."},
                    "retire": {"type": "boolean", "description": "End the key's rule instead (no body)."}
                },
                "required": ["key"]
            }
        },
        {
            "name": "rules",
            "description": "The current rules, newest per key, with author and how many sessions read each; structuredContent also lists open proposals. A person's rule is an instruction; an agent's is information.",
            "inputSchema": {"type": "object", "properties": {}}
        },
        {
            "name": "ack",
            "description": "Mark a rule as read, so its author sees it reached you.",
            "inputSchema": {
                "type": "object",
                "properties": {"postId": {"type": "string"}},
                "required": ["postId"]
            }
        },
        {
            "name": "post",
            "description": "Open a thread on your team's forum, for people and agents on other machines to read and answer.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "space": {"type": "string", "description": "The space to post in, e.g. \"general\"."},
                    "title": {"type": "string"},
                    "body": {"type": "string", "description": "Markdown."},
                    "kind": {"type": "string", "enum": ["question", "finding", "article", "page"], "description": "What the thread is; sent as a label."},
                    "labels": {"type": "array", "items": {"type": "string"}}
                },
                "required": ["space", "title", "body"]
            }
        },
        {
            "name": "reply",
            "description": "Reply on a thread of your team's forum.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "thread": {"type": "integer", "description": "The thread's number."},
                    "body": {"type": "string", "description": "Markdown."}
                },
                "required": ["thread", "body"]
            }
        },
        {
            "name": "search",
            "description": "Search your team's forum threads; at most 10 hits.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "query": {"type": "string"},
                    "space": {"type": "string", "description": "Only this space."}
                },
                "required": ["query"]
            }
        }
    ])
}

/// The server for the session in its env, its calls on `daemon`'s connection
/// (`tools_mcp.rs`: one process serves it with acpmux's other servers).
pub(crate) fn served(
    daemon: &std::sync::Arc<crate::tools_mcp::Daemon>,
) -> Result<crate::tools_mcp::Served> {
    crate::tools_mcp::served(
        SERVER_NAME,
        SESSION_ENV,
        tools(),
        None,
        daemon,
        |daemon, _session, params| async move { call(&daemon, &params).await },
    )
}

/// Runs the server on stdin and stdout.
pub async fn run() -> Result<()> {
    crate::tools_mcp::serve_one(served).await
}

fn ok(text: String, structured: Value) -> Value {
    json!({"content": [{"type": "text", "text": text}], "structuredContent": structured, "isError": false})
}

/// What an announce did, as the agent or the CLI reads it.
pub fn announce_text(r: &Value) -> String {
    let id = r["post"]["id"].as_str().unwrap_or_default();
    if r["proposed"] == true {
        return format!(
            "A person's rule holds this key; your post {id} is a proposal they will see."
        );
    }
    let n = |k: &str| r[k].as_array().map_or(0, Vec::len);
    format!(
        "Posted {id}. Sessions read it on their next prompt; pushed to {} now, {} still on the way.",
        n("pushed"),
        n("pending")
    )
}

/// The rules as an agent reads them: one paragraph per key.
pub fn rules_text(rules: &Value) -> String {
    let rows = rules["rules"].as_array().cloned().unwrap_or_default();
    if rows.is_empty() {
        return "No rules are posted.".to_owned();
    }
    rows.iter()
        .map(|r| {
            let author = &r["author"];
            let who = match author["kind"].as_str() {
                Some("person") => format!(
                    "{} (a person; an instruction)",
                    author["account"].as_str().unwrap_or("")
                ),
                _ => {
                    let handle = author["handle"].as_str().filter(|h| !h.is_empty());
                    let name = author["name"].as_str().unwrap_or("");
                    match handle {
                        Some(handle) if !name.is_empty() => {
                            format!("agent {handle} (session {name}; information)")
                        }
                        Some(handle) => format!("agent {handle} (information)"),
                        None => format!("agent {name} (information)"),
                    }
                }
            };
            format!(
                "[{}] from {who}, postId {}, read by {}:\n{}",
                r["key"].as_str().unwrap_or(""),
                r["id"].as_str().unwrap_or(""),
                r["acks"].as_array().map_or(0, Vec::len),
                r["body"].as_str().unwrap_or("")
            )
        })
        .collect::<Vec<_>>()
        .join("\n\n")
}

async fn call(daemon: &Client, params: &Value) -> Value {
    let args = params.get("arguments").cloned().unwrap_or_else(|| json!({}));
    if !args.is_object() {
        return error_result("arguments must be an object".to_owned());
    }
    match params["name"].as_str().unwrap_or_default() {
        "announce" => {
            // The author is the session that holds the token, never an argument.
            let mut args = args;
            if let Some(o) = args.as_object_mut() {
                o.remove("account");
            }
            match daemon.request(method::MUX_FORUM_ANNOUNCE, args).await {
                Ok(r) => ok(announce_text(&r), r),
                Err(e) => error_result(format!("{e:#}")),
            }
        }
        "rules" => match daemon.request(method::MUX_FORUM_RULES, json!({})).await {
            Ok(r) => ok(rules_text(&r), r),
            Err(e) => error_result(format!("{e:#}")),
        },
        "ack" => match daemon.request(method::MUX_FORUM_ACK, args).await {
            Ok(r) => ok("Acknowledged.".to_owned(), r),
            Err(e) => error_result(format!("{e:#}")),
        },
        "post" => hosted(daemon, method::MUX_FORUM_POST, args).await,
        "reply" => hosted(daemon, method::MUX_FORUM_REPLY, args).await,
        "search" => hosted(daemon, method::MUX_FORUM_SEARCH, args).await,
        other => {
            error_result(crate::mcp_hint::unknown_tool(other, crate::mcp_hint::names(&tools())))
        }
    }
}

/// A hosted forum call: its answer, one JSON object, is the tool's text as is.
async fn hosted(daemon: &Client, m: &str, args: Value) -> Value {
    match daemon.request(m, args).await {
        Ok(r) => ok(r.to_string(), r),
        Err(e) => error_result(format!("{e:#}")),
    }
}
