//! Preview in the requesting chat's WebKit frame, without publishing a render.

use std::time::Duration;

use serde_json::{Map, Value, json};

use super::{Backend, envelope, failure_result, tool_error, v2_tools};

pub(super) const NAME: &str = "render_preview";

pub(super) fn descriptor() -> Value {
    json!({
        "name": NAME,
        "title": "Check a chat render",
        "description": "Check HTML before showing it with render. Returns a PNG image plus contentHeight, capturedHeight, width, console warnings/errors, uncaught exceptions, missing images and layout warnings. Uses your own running cmux chat's theme, design kit, sandbox and reply column width. Optional width (320 to 1440 CSS px) checks another viewport, e.g. 390 for a phone. Scripts and fonts settle before capture; 8 second limit. Content taller than 1600 CSS px is cropped, with full contentHeight reported. PNGs are at most 1x and 1568px on the long edge, downscaled to stay below 4 MiB of base64. App bridge actions are refused during preview. Requires your local chat pane and its renderPreview and liveRender labs. A preview is diagnostic evidence, not a guarantee about later asynchronous changes.",
        "inputSchema": {"type":"object", "additionalProperties":false, "required":["html"], "properties": {
            "html":{"type":"string", "minLength":1, "description":"Self-contained HTML, at most 1 MiB of UTF-8. Pass it inline; no file needed unless the user asked for one."},
            "width":{"type":"integer", "minimum":320, "maximum":1440}
        }},
        "annotations":{"readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false}
    })
}

/// The target comes only from the MCP process's session, never model arguments.
pub(super) fn params(
    arguments: &Map<String, Value>,
    session: Option<&str>,
) -> Result<Value, String> {
    let session = session
        .filter(|s| !s.trim().is_empty())
        .ok_or("render_preview requires an agent chat MCP session")?;
    if let Some(key) = arguments.keys().find(|key| !matches!(key.as_str(), "html" | "width")) {
        return Err(format!("render_preview has no argument {key:?}"));
    }
    let html = arguments
        .get("html")
        .and_then(Value::as_str)
        .filter(|s| !s.trim().is_empty())
        .ok_or("render_preview needs non-empty html")?;
    if html.len() > 1 << 20 {
        return Err("render_preview html exceeds 1 MiB".into());
    }
    let mut out = json!({"agent_session":session,"html":html});
    if let Some(width) = arguments.get("width") {
        let width = width
            .as_u64()
            .filter(|w| (320..=1440).contains(w))
            .ok_or("render_preview width must be an integer from 320 to 1440")?;
        out["width"] = json!(width);
    }
    Ok(out)
}

pub(super) fn call(
    backend: &impl Backend,
    arguments: &Map<String, Value>,
    session: Option<&str>,
) -> Value {
    let params = match params(arguments, session) {
        Ok(params) => params,
        Err(message) => return tool_error(envelope(v2_tools::invalid(message), "not_run", None)),
    };
    match backend.app("agent.render_preview", params, Duration::from_secs(15), None, false) {
        Ok(value) => result(value),
        Err(error) => failure_result(error),
    }
}

/// Images are MCP content, so the ordinary text-result truncation must not touch them.
pub(super) fn result(mut report: Value) -> Value {
    let png = report.as_object_mut().and_then(|o| o.remove("png"));
    let Some(png) = png
        .and_then(|v| v.as_str().map(str::to_owned))
        .filter(|s| s.starts_with("iVBORw0KGgo") && s.len() <= 4_194_304)
    else {
        return tool_error(envelope(
            v2_tools::invalid("preview returned no bounded PNG"),
            "not_run",
            None,
        ));
    };
    // Keep the image even if a page floods diagnostics. Only known bounded fields cross MCP.
    let mut bounded = Map::new();
    for key in ["contentHeight", "capturedHeight", "width"] {
        if let Some(value) = report.get(key).filter(|v| v.is_number()) {
            bounded.insert(key.into(), value.clone());
        }
    }
    for (key, count, length) in [("warnings", 20, 200), ("missingImages", 20, 200)] {
        let values = report
            .get(key)
            .and_then(Value::as_array)
            .map(|items| {
                items
                    .iter()
                    .take(count)
                    .filter_map(Value::as_str)
                    .map(|s| Value::String(s.chars().take(length).collect()))
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        bounded.insert(key.into(), Value::Array(values));
    }
    let messages = report.get("consoleMessages").and_then(Value::as_array).map(|items| {
        items.iter().take(50).map(|item| json!({
            "level": item.get("level").and_then(Value::as_str).unwrap_or("").chars().take(20).collect::<String>(),
            "message": item.get("message").and_then(Value::as_str).unwrap_or("").chars().take(300).collect::<String>()
        })).collect::<Vec<_>>()
    }).unwrap_or_default();
    bounded.insert("consoleMessages".into(), Value::Array(messages));
    report = Value::Object(bounded);
    // JSON escaping and multibyte text count toward the transport budget too.
    for key in ["consoleMessages", "warnings", "missingImages"] {
        while serde_json::to_vec(&report).map_or(true, |bytes| bytes.len() > 64 << 10) {
            let removed = report.get_mut(key).and_then(Value::as_array_mut).and_then(Vec::pop);
            if removed.is_none() {
                break;
            }
        }
    }
    json!({"content":[{"type":"image","mimeType":"image/png","data":png},
        {"type":"text","text":serde_json::to_string(&report).unwrap_or_default()}],
        "structuredContent":report,"isError":false})
}
