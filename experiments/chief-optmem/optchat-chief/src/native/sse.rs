//! Assembles a streamed Messages API response (server-sent events) into the
//! message a non-streaming call returns. The turn streams so that a long
//! reply never meets a total timeout; an idle read timeout catches a stalled
//! connection instead. Blocks are kept verbatim (thinking text and
//! signatures included): section 8 resends every model output as it came.

use serde_json::{Map, Value};

#[derive(Debug, Default)]
pub struct Assembler {
    message: Map<String, Value>,
    blocks: Vec<Value>,
    /// Streamed JSON input of each tool-use block, joined at its stop.
    partial: Vec<String>,
    done: bool,
    error: Option<String>,
}

impl Assembler {
    /// Feeds one SSE `data:` payload.
    pub fn feed(&mut self, data: &Value) {
        match data.get("type").and_then(Value::as_str).unwrap_or("") {
            "message_start" => {
                if let Some(Value::Object(message)) = data.get("message") {
                    self.message = message.clone();
                }
            }
            "content_block_start" => {
                let i = index(data);
                while self.blocks.len() <= i {
                    self.blocks.push(Value::Null);
                    self.partial.push(String::new());
                }
                self.blocks[i] = data.get("content_block").cloned().unwrap_or(Value::Null);
            }
            "content_block_delta" => {
                let i = index(data);
                let (Some(block), Some(delta)) = (self.blocks.get_mut(i), data.get("delta")) else {
                    return;
                };
                let text = |k: &str| delta.get(k).and_then(Value::as_str).unwrap_or("");
                match delta.get("type").and_then(Value::as_str).unwrap_or("") {
                    "text_delta" => append(block, "text", text("text")),
                    "thinking_delta" => append(block, "thinking", text("thinking")),
                    "signature_delta" => {
                        block["signature"] = Value::String(text("signature").into())
                    }
                    "input_json_delta" => self.partial[i].push_str(text("partial_json")),
                    "citations_delta" => {
                        if let Some(citation) = delta.get("citation") {
                            match block.get_mut("citations") {
                                Some(Value::Array(list)) => list.push(citation.clone()),
                                _ => block["citations"] = Value::Array(vec![citation.clone()]),
                            }
                        }
                    }
                    _ => {}
                }
            }
            "content_block_stop" => {
                let i = index(data);
                if let (Some(block), Some(json)) = (self.blocks.get_mut(i), self.partial.get(i))
                    && !json.is_empty()
                {
                    match serde_json::from_str::<Value>(json) {
                        Ok(input) => block["input"] = input,
                        Err(e) => {
                            self.error = Some(format!("a tool call's input is not JSON: {e}"))
                        }
                    }
                }
            }
            "message_delta" => {
                if let Some(Value::Object(delta)) = data.get("delta") {
                    for (k, v) in delta {
                        self.message.insert(k.clone(), v.clone());
                    }
                }
                if let Some(Value::Object(usage)) = data.get("usage") {
                    let entry = self
                        .message
                        .entry("usage")
                        .or_insert_with(|| Value::Object(Map::new()));
                    if let Value::Object(total) = entry {
                        for (k, v) in usage {
                            if !v.is_null() {
                                total.insert(k.clone(), v.clone());
                            }
                        }
                    }
                }
            }
            "message_stop" => self.done = true,
            "error" => {
                let error = data.get("error").unwrap_or(data);
                self.error = Some(
                    error
                        .get("message")
                        .and_then(Value::as_str)
                        .map_or_else(|| error.to_string(), str::to_owned),
                );
            }
            _ => {}
        }
    }

    /// The whole message, or why the stream failed.
    pub fn finish(mut self) -> Result<Value, String> {
        if let Some(e) = self.error {
            return Err(e);
        }
        if !self.done {
            return Err("the response stream ended before message_stop".into());
        }
        self.message
            .insert("content".into(), Value::Array(self.blocks));
        Ok(Value::Object(self.message))
    }
}

fn index(data: &Value) -> usize {
    data.get("index").and_then(Value::as_u64).unwrap_or(0) as usize
}

fn append(block: &mut Value, key: &str, text: &str) {
    let mut joined = block
        .get(key)
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned();
    joined.push_str(text);
    block[key] = Value::String(joined);
}

/// Reads an SSE body line by line into an assembler.
#[cfg(test)]
pub fn read(body: impl std::io::BufRead) -> Result<Value, String> {
    read_until(body, &|| false).map(|m| m.expect("never stopped"))
}

/// `read`, checking `stop` after every event: Ok(None) when it said so (the
/// partial message is dropped; nothing of it is logged or resent).
pub fn read_until(
    body: impl std::io::BufRead,
    stop: &dyn Fn() -> bool,
) -> Result<Option<Value>, String> {
    let mut assembler = Assembler::default();
    for line in body.lines() {
        let line = line.map_err(|e| format!("reading the response stream: {e}"))?;
        if let Some(data) = line.strip_prefix("data:") {
            let data: Value = serde_json::from_str(data.trim())
                .map_err(|e| format!("a response event is not JSON: {e}"))?;
            assembler.feed(&data);
            if stop() {
                return Ok(None);
            }
        }
    }
    assembler.finish().map(Some)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn a_stream_assembles_into_the_message_with_blocks_verbatim() {
        let body = [
            json!({"type": "message_start", "message": {"id": "m", "role": "assistant", "content": [], "usage": {"input_tokens": 5, "cache_read_input_tokens": 100, "output_tokens": 1}}}),
            json!({"type": "content_block_start", "index": 0, "content_block": {"type": "thinking", "thinking": "", "signature": ""}}),
            json!({"type": "content_block_delta", "index": 0, "delta": {"type": "signature_delta", "signature": "sig"}}),
            json!({"type": "content_block_stop", "index": 0}),
            json!({"type": "content_block_start", "index": 1, "content_block": {"type": "text", "text": ""}}),
            json!({"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": "Let me "}}),
            json!({"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": "look."}}),
            json!({"type": "content_block_stop", "index": 1}),
            json!({"type": "content_block_start", "index": 2, "content_block": {"type": "tool_use", "id": "t1", "name": "bash", "input": {}}}),
            json!({"type": "content_block_delta", "index": 2, "delta": {"type": "input_json_delta", "partial_json": "{\"comm"}}),
            json!({"type": "content_block_delta", "index": 2, "delta": {"type": "input_json_delta", "partial_json": "and\": \"ls\"}"}}),
            json!({"type": "content_block_stop", "index": 2}),
            json!({"type": "message_delta", "delta": {"stop_reason": "tool_use", "stop_sequence": null}, "usage": {"output_tokens": 42}}),
            json!({"type": "message_stop"}),
        ]
        .iter()
        .map(|d| format!("event: x\ndata: {d}\n\n"))
        .collect::<String>();
        let message = read(body.as_bytes()).unwrap();
        assert_eq!(message["stop_reason"], "tool_use");
        assert_eq!(message["usage"]["output_tokens"], 42);
        assert_eq!(message["usage"]["cache_read_input_tokens"], 100);
        assert_eq!(
            message["content"],
            json!([
                {"type": "thinking", "thinking": "", "signature": "sig"},
                {"type": "text", "text": "Let me look."},
                {"type": "tool_use", "id": "t1", "name": "bash", "input": {"command": "ls"}},
            ])
        );
    }

    #[test]
    fn a_stop_drops_the_stream_at_the_next_event() {
        let body = (0..10)
            .map(|i| {
                format!(
                    "data: {}\n\n",
                    json!({"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": format!("{i}")}})
                )
            })
            .collect::<String>();
        let seen = std::cell::Cell::new(0);
        let stop = || {
            seen.set(seen.get() + 1);
            seen.get() >= 3
        };
        assert_eq!(read_until(body.as_bytes(), &stop), Ok(None));
        assert_eq!(seen.get(), 3, "checked after every event, stopped at once");
    }

    #[test]
    fn an_error_event_or_a_cut_stream_fails() {
        let error = format!(
            "data: {}\n\n",
            json!({"type": "error", "error": {"type": "overloaded_error", "message": "Overloaded"}})
        );
        assert_eq!(read(error.as_bytes()), Err("Overloaded".into()));
        let cut = format!(
            "data: {}\n\n",
            json!({"type": "message_start", "message": {"content": []}})
        );
        assert!(read(cut.as_bytes()).is_err());
    }
}
