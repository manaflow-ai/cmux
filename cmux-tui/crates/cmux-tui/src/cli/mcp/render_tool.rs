//! `render`: show the user a live HTML page in the cmux thread. The one tool
//! that comes from no owner's catalog: it owns no state and calls nothing.
//! The agent pane draws the call itself from its input, as a render card
//! above the reply (webviews/src/agent-session/acpmux/conversation/RenderCard.tsx),
//! in a sandboxed frame with no network. The call only checks the input and
//! says the page is shown. Because it can do nothing else, `serve
//! --render-only` offers it without `mcp.enabled`, and acpmux gives that
//! server to every agent session it starts (plans/cmux-next/mcp.md).

use serde_json::{Map, Value, json};

use super::{envelope, success, tool_error, v2_tools};

pub(super) const NAME: &str = "render";
/// The largest page, in bytes of UTF-8.
pub(super) const MAX_HTML_BYTES: usize = 512_000;
const MAX_TITLE_CHARS: usize = 120;

const DESCRIPTION: &str = "Show the user a live HTML page in the cmux thread: a UI mock, a chart, a \
    diagram or a table. The page draws above your reply in a sandboxed frame at its content \
    height. Inline <script> and <style> run, and scripts and styles may load from \
    cdn.jsdelivr.net, unpkg.com or cdnjs.cloudflare.com. Nothing else on the network is \
    reachable: no fetch, no remote images, no forms. Match the thread with the CSS variables \
    --cmux-text, --cmux-muted, --cmux-bg, --cmux-border, --cmux-font and --cmux-mono. Send one \
    self-contained page per call. To offer options, render each as its own call in the same \
    turn (they show side by side) and set recommended on the one you suggest.";

pub(super) fn descriptor_json() -> Value {
    json!({
        "name": NAME,
        "description": DESCRIPTION,
        "inputSchema": {
            "type": "object",
            "properties": {
                "html": {
                    "type": "string",
                    "description": "The page: a full document or a fragment, at most 512000 bytes.",
                },
                "title": {
                    "type": "string",
                    "description": "A short heading for the page, shown over it.",
                },
                "recommended": {
                    "type": "boolean",
                    "description": "Marks the option you suggest among several renders in one turn.",
                },
            },
            "required": ["html"],
            "additionalProperties": false,
        },
        "annotations": {
            "readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false,
        },
    })
}

/// Checks the page and reports it shown; the pane draws it from the call.
pub(super) fn call(arguments: &Map<String, Value>) -> Value {
    match check(arguments) {
        Ok(bytes) => success(json!({ "shown": true, "bytes": bytes }), false),
        Err(message) => tool_error(envelope(v2_tools::invalid(message), "not_run", None)),
    }
}

fn check(arguments: &Map<String, Value>) -> Result<usize, String> {
    if let Some(name) =
        arguments.keys().find(|name| !matches!(name.as_str(), "html" | "title" | "recommended"))
    {
        return Err(format!("render has no argument {name:?}"));
    }
    let html = match arguments.get("html") {
        Some(Value::String(html)) if !html.trim().is_empty() => html,
        Some(Value::String(_)) => return Err("html is empty".into()),
        _ => return Err("render needs html, a string".into()),
    };
    if html.len() > MAX_HTML_BYTES {
        return Err(format!("html is {} bytes; the most is {MAX_HTML_BYTES}", html.len()));
    }
    match arguments.get("title") {
        None => {}
        Some(Value::String(title)) if title.chars().count() <= MAX_TITLE_CHARS => {}
        Some(Value::String(_)) => {
            return Err(format!("title is longer than {MAX_TITLE_CHARS} characters"));
        }
        Some(_) => return Err("title must be a string".into()),
    }
    if arguments.get("recommended").is_some_and(|value| !value.is_boolean()) {
        return Err("recommended must be true or false".into());
    }
    Ok(html.len())
}
