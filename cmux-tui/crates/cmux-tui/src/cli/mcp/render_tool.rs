//! `render`: a page the cmux NEXT chat draws live in the transcript.
//!
//! The tool reaches no owner. The chat reads the call's own input (`html`,
//! `title`) and draws it as a render card above the turn's answer, in a
//! sandboxed frame of its own origin that allows no connection
//! (webviews/src/agent-session/acpmux/conversation/renderCall.ts). The
//! result is the receipt, so the agent needs no screenshot to know what the
//! chat shows. A client other than the cmux chat shows a plain tool call.

use serde_json::{Map, Value, json};

pub(super) const NAME: &str = "render";
/// The largest page the tool takes, in UTF-8 bytes.
const MAX_HTML_BYTES: usize = 1 << 20;
/// The longest card heading, in characters.
const MAX_TITLE_CHARS: usize = 200;

pub(super) fn descriptor() -> Value {
    json!({
        "name": NAME,
        "title": "Show a page in the chat",
        "description": "Show an HTML page live in the cmux chat, above your answer: a chart, a diagram, a three.js scene or a small interactive tool. Pass one complete, self-contained page in html, with a <title>. Scripts and styles go inline or load from cdn.jsdelivr.net, unpkg.com or cdnjs.cloudflare.com; the page cannot fetch, open frames or submit forms. A page with no CSS already matches the chat: cmux adds a base stylesheet in the chat's light or dark theme, and your own styles override it. Theme variables: colors --cmux-text, --cmux-muted, --cmux-bg, --cmux-card, --cmux-border, --cmux-accent, --cmux-control, --cmux-control-hover; fonts --cmux-font, --cmux-mono; sizes --cmux-size-caption, --cmux-size-detail, --cmux-size-body, --cmux-size-title, --cmux-size-heading; --cmux-radius; spacing --cmux-space-1, --cmux-space-2, --cmux-space-3, --cmux-space-4 (4, 8, 12, 16px). Rely on these instead of hardcoding colors, fonts or sizes. The card takes the page's height, and the user presses Run to start it.",
        "inputSchema": {
            "type": "object",
            "additionalProperties": false,
            "required": ["html"],
            "properties": {
                "html": {"type": "string", "minLength": 1, "description": "At most 1 MiB of UTF-8."},
                "title": {"type": "string", "maxLength": MAX_TITLE_CHARS}
            }
        },
        "annotations": {"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false},
    })
}

/// The receipt for a page the chat can show, or why it cannot.
pub(super) fn receipt(arguments: &Map<String, Value>) -> Result<Value, String> {
    if let Some(name) = arguments.keys().find(|name| !matches!(name.as_str(), "html" | "title")) {
        return Err(format!("render has no argument {name:?}"));
    }
    let html = arguments
        .get("html")
        .and_then(Value::as_str)
        .filter(|html| !html.trim().is_empty())
        .ok_or("render needs html: a non-empty HTML page")?;
    if html.len() > MAX_HTML_BYTES {
        return Err(format!("render html is larger than {} KiB", MAX_HTML_BYTES >> 10));
    }
    let title = match arguments.get("title") {
        None | Some(Value::Null) => None,
        Some(Value::String(title)) if title.chars().count() > MAX_TITLE_CHARS => {
            return Err(format!("render title is longer than {MAX_TITLE_CHARS} characters"));
        }
        Some(Value::String(title)) => Some(title.trim()).filter(|title| !title.is_empty()),
        Some(_) => return Err("render title must be a string".into()),
    };
    Ok(json!({
        "rendered": true,
        "bytes": html.len(),
        "title": title,
        "message": "The cmux chat shows this page as a card above your answer; the user presses Run to start it.",
    }))
}
