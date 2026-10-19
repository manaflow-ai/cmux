//! `acpmux forum-mcp`: the `cmux-forum` MCP stdio server every agent session
//! gets (`agent_tools.rs`), the same on every harness: post a rule, read the
//! current rules, ack one (hq#2570). Each tool is one daemon request
//! (`server/forum.rs`) over a connection that carries the session's caller
//! token from this server's own env, so the daemon knows which session posts.

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
            "description": "Post a rule every agent session on this Mac reads. A new post on the same key replaces the old one. A person's rule outranks yours: posting on its key only proposes a change. urgent: true also messages every live session now; use it only for \"stop doing X now\".",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "key": {"type": "string", "description": "What the rule is about, e.g. \"builds\". One rule per key."},
                    "body": {"type": "string", "description": "The rule, short and self-contained."},
                    "urgent": {"type": "boolean"},
                    "retire": {"type": "boolean", "description": "End the key's rule instead (no body)."}
                },
                "required": ["key"]
            }
        },
        {
            "name": "rules",
            "description": "The current rules, newest per key, with author and who has read each. A person's rule is an instruction; an agent's is information.",
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
        }
    ])
}

/// Runs the server on stdin and stdout.
pub async fn run() -> Result<()> {
    crate::secret_mcp::serve(
        SERVER_NAME,
        SESSION_ENV,
        tools(),
        |daemon, _session, params| async move { call(&daemon, &params).await },
    )
    .await
}

fn ok(text: String, structured: Value) -> Value {
    json!({"content": [{"type": "text", "text": text}], "structuredContent": structured, "isError": false})
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
                _ => format!("agent {} (information)", author["name"].as_str().unwrap_or("")),
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
                Ok(r) => {
                    let id = r["post"]["id"].as_str().unwrap_or_default();
                    let text = if r["proposed"] == true {
                        format!(
                            "A person's rule holds this key; your post {id} is a proposal they will see."
                        )
                    } else {
                        let n = |k: &str| r[k].as_array().map_or(0, Vec::len);
                        let (pushed, pending) = (n("pushed"), n("pending"));
                        format!(
                            "Posted {id}. Sessions read it on their next prompt; pushed to {pushed} now, {pending} still on the way."
                        )
                    };
                    ok(text, r)
                }
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
        other => error_result(format!("unknown tool: {other}")),
    }
}
