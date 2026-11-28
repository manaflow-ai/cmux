//! The error and fault lines of a device log written by `log stream --style
//! ndjson`, newest last, for the feedback summary (Swift `PhoneLogTail`).
use serde::Serialize;
use serde_json::Value;
use unicode_segmentation::UnicodeSegmentation;

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct LogLine {
    pub level: String,
    pub process: String,
    pub message: String,
}

/// The longest message kept whole, in characters (grapheme clusters, as Swift counts them).
pub const MESSAGE_LIMIT: usize = 240;

/// Keeps the last `limit` error and fault lines; lines that are not JSON (the
/// stream's header) are skipped.
pub fn log_tail(ndjson: &[u8], limit: usize) -> Vec<LogLine> {
    let mut kept: Vec<LogLine> = Vec::new();
    for raw in ndjson.split(|byte| *byte == b'\n').filter(|raw| !raw.is_empty()) {
        let Ok(Value::Object(object)) = serde_json::from_slice::<Value>(raw) else { continue };
        let Some(kind) = object.get("messageType").and_then(Value::as_str) else { continue };
        if kind != "Error" && kind != "Fault" {
            continue;
        }
        let Some(message) = object.get("eventMessage").and_then(Value::as_str) else { continue };
        let path = object.get("processImagePath").and_then(Value::as_str).unwrap_or("");
        let process = path.split('/').rfind(|part| !part.is_empty()).unwrap_or("?").to_owned();
        let message = if message.graphemes(true).count() > MESSAGE_LIMIT {
            message.graphemes(true).take(MESSAGE_LIMIT).collect::<String>() + "…"
        } else {
            message.to_owned()
        };
        kept.push(LogLine { level: kind.to_lowercase(), process, message });
        if kept.len() > limit {
            kept.remove(0);
        }
    }
    kept
}
