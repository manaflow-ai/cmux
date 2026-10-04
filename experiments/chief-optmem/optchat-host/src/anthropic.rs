//! The compactor's model over the Anthropic Messages API (`POST /v1/messages`),
//! through the team subrouter by default. Rust has no official Anthropic SDK,
//! so this is raw HTTP with a blocking client.

use serde_json::{json, Value};

use optchat_core::CompactRequest;

use crate::config::Config;
use crate::model::{CompactModel, Followup, ModelError, Reply};

/// The subrouter ignores the key; the header keeps the request well formed.
const API_KEY: &str = "subrouter";
const API_VERSION: &str = "2023-06-01";
/// How much of an error body a failure report keeps.
const ERROR_BODY: usize = 600;

/// The beta that enables server-side `fallbacks: "default"`.
const SERVER_FALLBACK_BETA: &str = "server-side-fallback-2026-07-01";

pub struct AnthropicModel {
    agent: ureq::Agent,
    url: String,
    model: String,
    effort: Option<String>,
    max_tokens: u32,
    server_fallback: bool,
}

impl AnthropicModel {
    /// The compactor's model (`config.model`).
    pub fn new(config: &Config) -> AnthropicModel {
        AnthropicModel::with_model(config, &config.model)
    }

    /// The same client for another model id (the refusal fallback).
    pub fn with_model(config: &Config, model: &str) -> AnthropicModel {
        AnthropicModel {
            agent: ureq::AgentBuilder::new()
                .timeout(config.http_timeout)
                .build(),
            url: format!("{}/v1/messages", config.base_url.trim_end_matches('/')),
            model: model.to_owned(),
            effort: config.effort.clone(),
            max_tokens: config.max_tokens,
            server_fallback: config.server_fallback,
        }
    }

    /// The request body. The context comes first, cut at the view's cache
    /// marks (section 8: the last line end before 50k, 80k and 100k
    /// characters), and each piece carries a breakpoint: consecutive calls
    /// share the `<chat>` prefix up to where the view last changed, and a
    /// read lands only where an earlier request wrote a breakpoint. The last
    /// piece's breakpoint is what size-loop retries reread. At most 4
    /// breakpoints; the step block has none. No tools (section 4.2). No
    /// 1-hour entries: they cost twice the input to write (section 8).
    pub fn body(&self, request: &CompactRequest, followups: &[Followup]) -> Value {
        let mut content: Vec<Value> = optchat_core::cache_pieces(&request.context)
            .into_iter()
            .map(|piece| json!({"type": "text", "text": piece, "cache_control": {"type": "ephemeral"}}))
            .collect();
        content.push(json!({"type": "text", "text": request.step}));
        let mut messages = vec![json!({"role": "user", "content": content})];
        for f in followups {
            let content = match &f.reply.content {
                Value::Null => json!(f.reply.text),
                raw => raw.clone(),
            };
            messages.push(json!({"role": "assistant", "content": content}));
            messages.push(json!({"role": "user", "content": f.retry}));
        }
        let mut body = json!({
            "model": self.model,
            "max_tokens": self.max_tokens,
            "system": request.system,
            "messages": messages,
        });
        if let Some(effort) = &self.effort {
            body["output_config"] = json!({"effort": effort});
        }
        if self.server_fallback {
            body["fallbacks"] = json!("default");
        }
        body
    }
}

fn clip(s: &str) -> &str {
    optchat_core::cut_at_bytes(s, ERROR_BODY)
}

impl CompactModel for AnthropicModel {
    fn call(&self, request: &CompactRequest, followups: &[Followup]) -> Result<Reply, ModelError> {
        let response = self
            .agent
            .post(&self.url)
            .set("x-api-key", API_KEY)
            .set("anthropic-version", API_VERSION);
        let response = if self.server_fallback {
            response.set("anthropic-beta", SERVER_FALLBACK_BETA)
        } else {
            response
        }
        .send_json(self.body(request, followups));
        let value: Value = match response {
            Ok(r) => r
                .into_json()
                .map_err(|e| ModelError::new(format!("bad response body: {e}")))?,
            Err(ureq::Error::Status(code, r)) => {
                let text = r.into_string().unwrap_or_default();
                return Err(ModelError::new(format!("HTTP {code}: {}", clip(&text))));
            }
            Err(e) => return Err(ModelError::new(e.to_string())),
        };
        parse(value)
    }
}

/// The reply's text and its raw content. A refusal or a reply cut by
/// `max_tokens` is a failure: a partial line must never become a node.
fn parse(value: Value) -> Result<Reply, ModelError> {
    match value["stop_reason"].as_str() {
        Some("refusal") => {
            return Err(ModelError::refusal(format!(
                "refused: {}",
                value["stop_details"]
            )));
        }
        Some("max_tokens") => return Err(ModelError::new("reply hit max_tokens")),
        _ => {}
    }
    let content = value
        .get("content")
        .cloned()
        .filter(Value::is_array)
        .ok_or_else(|| {
            ModelError::new(format!(
                "no content in response: {}",
                clip(&value.to_string())
            ))
        })?;
    let text: String = content
        .as_array()
        .into_iter()
        .flatten()
        .filter(|b| b["type"] == "text")
        .filter_map(|b| b["text"].as_str())
        .collect();
    Ok(Reply { text, content })
}

#[cfg(test)]
mod tests {
    use super::*;
    use optchat_core::NodeId;

    fn request() -> CompactRequest {
        CompactRequest {
            node: NodeId::new(0, 3),
            system: "SYS".into(),
            context: "<chat>\n</chat>".into(),
            step: "STEP".into(),
        }
    }

    #[test]
    fn body_puts_cached_context_first_and_replays_the_size_loop() {
        let model = AnthropicModel::new(&Config::default());
        let followups = vec![Followup {
            reply: Reply {
                text: "long".into(),
                content: json!([{"type": "text", "text": "long"}]),
            },
            retry: "That line is 600 bytes".into(),
        }];
        let body = model.body(&request(), &followups);
        assert_eq!(body["system"], "SYS");
        assert_eq!(body["model"], "claude-sonnet-5-5");
        assert_eq!(body["output_config"]["effort"], "medium");
        assert!(body.get("tools").is_none());
        let m = body["messages"].as_array().unwrap();
        assert_eq!(m.len(), 3);
        assert_eq!(m[0]["content"][0]["cache_control"]["type"], "ephemeral");
        assert_eq!(m[0]["content"][1]["text"], "STEP");
        assert_eq!(m[1]["role"], "assistant");
        assert_eq!(m[1]["content"][0]["text"], "long");
        assert_eq!(m[2]["content"], "That line is 600 bytes");
    }

    #[test]
    fn a_long_context_is_cut_at_the_marks_with_a_breakpoint_on_each_piece() {
        // Audit round 1: one context block with one breakpoint at its end, so a
        // call whose context differs only in its last line read nothing.
        let line = format!("{}\n", "x".repeat(99));
        let mut context = String::from("<chat>\n");
        for _ in 0..1_100 {
            context.push_str(&line);
        }
        context.push_str("</chat>");
        let request = CompactRequest {
            context: context.clone(),
            ..request()
        };
        let body = AnthropicModel::new(&Config::default()).body(&request, &[]);
        let blocks = body["messages"][0]["content"].as_array().unwrap().clone();
        // Three marks (50k, 80k, 100k) cut four context pieces; the step is last.
        assert_eq!(blocks.len(), 5);
        let joined: String = blocks[..4]
            .iter()
            .map(|b| b["text"].as_str().unwrap())
            .collect();
        assert_eq!(joined, context);
        for (piece, limit) in blocks[..3].iter().zip(optchat_core::MARKS) {
            let text = piece["text"].as_str().unwrap();
            assert!(text.ends_with('\n'));
            assert!(text.chars().count() <= limit);
        }
        let breakpoints = blocks
            .iter()
            .filter(|b| b.get("cache_control").is_some())
            .count();
        assert_eq!(breakpoints, 4, "at most 4 per request");
        assert!(blocks[4].get("cache_control").is_none());
        assert_eq!(blocks[4]["text"], "STEP");
    }

    #[test]
    fn parse_joins_text_and_rejects_refusals_and_cut_replies() {
        let ok = json!({"stop_reason": "end_turn", "content": [
            {"type": "thinking", "thinking": "", "signature": "s"},
            {"type": "text", "text": "user: hi"}]});
        let reply = parse(ok.clone()).unwrap();
        assert_eq!(reply.text, "user: hi");
        assert_eq!(reply.content, ok["content"]);
        assert!(parse(json!({"stop_reason": "refusal", "content": []})).is_err());
        assert!(parse(json!({"stop_reason": "max_tokens", "content": []})).is_err());
        assert!(parse(json!({"error": "x"})).is_err());
    }
}
