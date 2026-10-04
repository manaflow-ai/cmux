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

pub struct AnthropicModel {
    agent: ureq::Agent,
    url: String,
    model: String,
    effort: Option<String>,
    max_tokens: u32,
}

impl AnthropicModel {
    pub fn new(config: &Config) -> AnthropicModel {
        AnthropicModel {
            agent: ureq::AgentBuilder::new()
                .timeout(config.http_timeout)
                .build(),
            url: format!("{}/v1/messages", config.base_url.trim_end_matches('/')),
            model: config.model.clone(),
            effort: config.effort.clone(),
            max_tokens: config.max_tokens,
        }
    }

    /// The request body. The context block comes first and carries the cache
    /// breakpoint: every compactor call shares the `<chat>` prefix (section 8),
    /// and size-loop retries reread it. No tools (section 4.2). No 1-hour
    /// entries: they cost twice the input to write (section 8).
    pub fn body(&self, request: &CompactRequest, followups: &[Followup]) -> Value {
        let mut messages = vec![json!({
            "role": "user",
            "content": [
                {"type": "text", "text": request.context, "cache_control": {"type": "ephemeral"}},
                {"type": "text", "text": request.step},
            ],
        })];
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
            .set("anthropic-version", API_VERSION)
            .send_json(self.body(request, followups));
        let value: Value = match response {
            Ok(r) => r
                .into_json()
                .map_err(|e| ModelError(format!("bad response body: {e}")))?,
            Err(ureq::Error::Status(code, r)) => {
                let text = r.into_string().unwrap_or_default();
                return Err(ModelError(format!("HTTP {code}: {}", clip(&text))));
            }
            Err(e) => return Err(ModelError(e.to_string())),
        };
        parse(value)
    }
}

/// The reply's text and its raw content. A refusal or a reply cut by
/// `max_tokens` is a failure: a partial line must never become a node.
fn parse(value: Value) -> Result<Reply, ModelError> {
    match value["stop_reason"].as_str() {
        Some("refusal") => {
            return Err(ModelError(format!("refused: {}", value["stop_details"])));
        }
        Some("max_tokens") => return Err(ModelError("reply hit max_tokens".into())),
        _ => {}
    }
    let content = value
        .get("content")
        .cloned()
        .filter(Value::is_array)
        .ok_or_else(|| {
            ModelError(format!(
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
