//! `render`: a page the cmux NEXT chat draws live in the transcript.
//!
//! The tool reaches no owner. The chat reads the call's own input (`html`,
//! `title`) and draws it as a render card above the turn's answer, in a
//! sandboxed frame of its own origin that allows no connection
//! (webviews/src/agent-session/acpmux/conversation/renderCall.ts). The
//! result is a receipt. Use render_preview first to inspect a screenshot and
//! diagnostics from the same frame runtime. A client other than the cmux chat shows a plain tool call.

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
        "description": "Show self-contained HTML live inline in the cmux chat. It runs automatically and streams as it arrives; scripts run when the page closes. Check it with render_preview, then show it with render. Fenced cmux-render HTML (or cmux-react with function App(), React 18 global) is the fast streaming reply path. Use fluid width and content height, never 100vh. No outer card, banner or background. Built-in native defaults and classes: .stack, .row, .grid, .panel, .stat (strong + small), .badge, .muted, .segmented. Tokens use --cmux-: text, muted, bg, card, border, accent, control, control-hover, success, warning, danger, chart-1 through chart-6, radius, font, font-mono, space-1 through space-4. cmux.chart(element,{type:'line'|'area'|'bar'|'donut'|'pie',height:220,labels:[],series:[{name,values:[]}]}) or data-cmux-chart='JSON'. Buttons with data-cmux-prompt or data-cmux-prefill request confirmed chat follow-ups. window.cmux also provides prefill, sendPrompt, copy, openLink, theme, onTheme and per-render state.get/set. Catch rejected actions. Scripts/styles may load from cdn.jsdelivr.net, unpkg.com, cdnjs.cloudflare.com; Google Fonts supported. No fetch, remote images, frames or forms. At most 1 MiB of HTML; never include secrets.",
        "inputSchema": {
            "type": "object",
            "additionalProperties": false,
            "required": ["html"],
            "properties": {
                "html": {"type": "string", "minLength": 1, "description": "At most 1 MiB of UTF-8. Pass it inline; never write it to a file first."},
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
        "message": "The cmux chat draws this page inline automatically while liveRender is enabled. Scripts run when the page closes.",
    }))
}
