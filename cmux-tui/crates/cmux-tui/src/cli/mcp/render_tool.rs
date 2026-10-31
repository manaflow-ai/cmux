//! `render`: a page the cmux NEXT chat draws live in the transcript.
//!
//! The tool reaches no owner. The chat reads the call's own input (`html`,
//! `title`) and draws it as a render card above the turn's answer, in a
//! sandboxed frame of its own origin that allows no connection
//! (webviews/src/agent-session/acpmux/conversation/renderCall.ts). The
//! result is the receipt, so the agent needs no screenshot to know what the
//! chat shows. A client other than the cmux chat shows a plain tool call.
//!
//! The receipt names the page by an id the chat derives from the call's own
//! input as well (`renderId` in renderCall.ts): FNV-1a over the page's UTF-8
//! bytes and its length. A later render that passes that `id` updates the
//! same card in place (cx-ncc.94); this process refuses an id it did not
//! return, so a resumed agent whose server restarted draws a new card.

use std::collections::HashSet;

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
        "description": "Show an HTML page live in the cmux chat, above your answer: a chart, a diagram, a three.js scene or a small interactive tool. Pass one complete, self-contained page in html, with a <title>. Scripts and styles go inline or load from cdn.jsdelivr.net, unpkg.com or cdnjs.cloudflare.com; the page cannot fetch, open frames or submit forms. A page with no CSS already matches the chat: cmux adds a base stylesheet in the chat's light or dark theme, and your own styles override it. Theme variables: colors --cmux-text, --cmux-muted, --cmux-bg, --cmux-card, --cmux-border, --cmux-accent, --cmux-control, --cmux-control-hover; fonts --cmux-font, --cmux-mono; sizes --cmux-size-caption, --cmux-size-detail, --cmux-size-body, --cmux-size-title, --cmux-size-heading; --cmux-radius; spacing --cmux-space-1, --cmux-space-2, --cmux-space-3, --cmux-space-4 (4, 8, 12, 16px). Rely on these instead of hardcoding colors, fonts or sizes. The card takes the page's height, and the user presses Run to start it. The result's id names the page: pass it as id to show a new page in that same card, with the earlier page kept as a previous version.",
        "inputSchema": {
            "type": "object",
            "additionalProperties": false,
            "required": ["html"],
            "properties": {
                "html": {"type": "string", "minLength": 1, "description": "At most 1 MiB of UTF-8."},
                "title": {"type": "string", "maxLength": MAX_TITLE_CHARS},
                "id": {"type": "string", "description": "The id an earlier render in this session returned: its card shows this page in place. After the cmux server restarts (a resumed chat) an earlier id is refused; leave id out then."}
            }
        },
        "annotations": {"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false},
    })
}

/// The receipt for a page the chat can show, or why it cannot.
/// `renders` holds the ids this server returned; the page's own id joins it.
pub(super) fn receipt(
    arguments: &Map<String, Value>,
    renders: &mut HashSet<String>,
) -> Result<Value, String> {
    if let Some(name) =
        arguments.keys().find(|name| !matches!(name.as_str(), "html" | "title" | "id"))
    {
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
    let updated = match arguments.get("id") {
        None | Some(Value::Null) => None,
        Some(Value::String(id)) if renders.contains(id) => Some(id.clone()),
        Some(Value::String(id)) => {
            return Err(format!(
                "render has no page {id:?}: pass an id a render returned in this session, or leave id out to draw a new card"
            ));
        }
        Some(_) => return Err("render id must be a string".into()),
    };
    // An update keeps its card's id: the chat keys the card by it, not by the new page.
    let id = updated.clone().unwrap_or_else(|| {
        let own = render_id(html);
        renders.insert(own.clone());
        own
    });
    let message = if updated.is_some() {
        "The cmux chat shows this page in place in the card with this id; the earlier page stays a previous version in the side panel, and the user presses Run to start it."
    } else {
        "The cmux chat shows this page as a card above your answer; the user presses Run to start it. Pass this id to render to update the card in place."
    };
    Ok(json!({
        "rendered": true,
        "id": id,
        "updated": updated.is_some(),
        "bytes": html.len(),
        "title": title,
        "message": message,
    }))
}

/// A page's id: `r`, FNV-1a 32 of its UTF-8 bytes (8 hex digits), then its byte length in hex.
/// The chat computes the same id from the call's input (renderCall.ts `renderId`).
fn render_id(html: &str) -> String {
    let hash = html
        .bytes()
        .fold(0x811c_9dc5_u32, |hash, byte| (hash ^ u32::from(byte)).wrapping_mul(0x0100_0193));
    format!("r{hash:08x}{:x}", html.len())
}
