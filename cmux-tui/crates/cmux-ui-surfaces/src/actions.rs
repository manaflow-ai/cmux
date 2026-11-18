//! What a confirmed action sends. Only [`crate::SurfaceStore::confirm`]
//! makes an [`Outbound`]; there is no other constructor outside this crate.

use serde_json::Value;

#[derive(Clone, Debug, PartialEq)]
pub enum Outbound {
    /// The A2UI `action` client message, sent to the agent as a user turn.
    Agent {
        surface_id: String,
        /// `{"version":"1.0","action":{...}}`
        message: Value,
        /// `{"a2uiRendererDataModel": {...}}` when the surface asked for
        /// `sendDataModel` (every path is listed in the summary).
        metadata: Option<Value>,
        /// The host-written summary the person confirmed.
        summary: String,
    },
    /// An MCP `tools/call` the view asked for; `view_request_id` is the
    /// view's JSON-RPC id to answer with the result.
    ToolCall {
        surface_id: String,
        server: Option<String>,
        tool: String,
        arguments: Value,
        view_request_id: Option<Value>,
    },
    OpenLink {
        surface_id: String,
        url: String,
        view_request_id: Option<Value>,
    },
}

impl Outbound {
    pub(crate) fn fingerprint(&self) -> Value {
        // Everything but the timestamp, which confirm stamps.
        match self {
            Self::Agent { message, metadata, .. } => {
                let mut m = message.clone();
                if let Some(a) = m.get_mut("action").and_then(Value::as_object_mut) {
                    a.remove("timestamp");
                }
                serde_json::json!([m, metadata])
            }
            Self::ToolCall { tool, arguments, .. } => serde_json::json!([tool, arguments]),
            Self::OpenLink { url, .. } => serde_json::json!([url]),
        }
    }

    /// The user-turn text for an [`Outbound::Agent`]: the summary, then the
    /// A2UI action (and data model) in fenced JSON blocks.
    pub fn prompt_text(&self) -> Option<String> {
        let Self::Agent { message, metadata, summary, .. } = self else {
            return None;
        };
        let mut out =
            format!("{summary}\n\n```json\n{}\n```", serde_json::to_string_pretty(message).ok()?);
        if let Some(meta) = metadata {
            out.push_str(&format!(
                "\n\n```json\n{}\n```",
                serde_json::to_string_pretty(meta).ok()?
            ));
        }
        Some(out)
    }
}
