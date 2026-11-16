//! `agent.ask`: one question from an extension to the person's own default
//! agent, through the acpmux this daemon already uses. No new keys, no new
//! model client: the binary installs [`AgentAsker`] (`cmux acp exec`,
//! ephemeral, every tool denied), and this module bounds the call.
//!
//! - Needs scope `agent:execute` and a live user gesture (grants.rs
//!   `PERSON_SPEND_OPS`): it spends the person's model quota.
//! - One ask in flight per extension; a second gets `app.busy` (retryable).
//! - The prompt is at most [`MAX_PROMPT_BYTES`]; the reply is cut at
//!   [`MAX_REPLY_BYTES`] on a character boundary.
//! - The agent runs with policy deny-all and denies every permission ask, so
//!   page text an extension puts in the prompt can steer only the reply,
//!   never a tool.

use std::collections::BTreeSet;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

pub const MAX_PROMPT_BYTES: usize = 256 * 1024;
pub const MAX_REPLY_BYTES: usize = 64 * 1024;
pub const TIMEOUT: Duration = Duration::from_secs(120);

/// One ask the binary runs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AskRequest {
    pub prompt: String,
    /// `HARNESS[/MODEL]` (`claude/haiku`); `None` is the person's default.
    pub model: Option<String>,
    pub timeout: Duration,
}

/// Runs one ask and answers the agent's final reply text.
pub type AgentAsker = Arc<dyn Fn(&AskRequest) -> Result<String, String> + Send + Sync>;

static ASKER: OnceLock<AgentAsker> = OnceLock::new();

/// Installs the binary's asker (once per process).
pub fn install(asker: AgentAsker) {
    let _ = ASKER.set(asker);
}

impl super::supervisor::Supervisor {
    /// The installed asker (none in a daemon whose binary set none).
    pub(super) fn asker(&self) -> Option<AgentAsker> {
        ASKER.get().cloned()
    }
}

#[derive(Debug)]
pub struct AskError {
    pub code: &'static str,
    pub message: String,
    pub retryable: bool,
}

impl AskError {
    pub fn body(&self) -> Value {
        json!({ "code": self.code, "message": self.message, "retryable": self.retryable })
    }
}

fn invalid(message: impl Into<String>) -> AskError {
    AskError { code: "validation.invalid", message: message.into(), retryable: false }
}

/// The params an extension sends: `{prompt, model?}`.
pub fn parse(params: &Value) -> Result<AskRequest, AskError> {
    let prompt = params
        .get("prompt")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|p| !p.is_empty())
        .ok_or_else(|| invalid("prompt is required"))?;
    if prompt.len() > MAX_PROMPT_BYTES {
        return Err(invalid(format!("prompt is larger than {} KiB", MAX_PROMPT_BYTES / 1024)));
    }
    let model = match params.get("model") {
        None | Some(Value::Null) => None,
        Some(Value::String(m))
            if !m.is_empty()
                && m.len() <= 128
                && m.chars()
                    .all(|c| c.is_ascii_alphanumeric() || matches!(c, '/' | '-' | '_' | '.')) =>
        {
            Some(m.clone())
        }
        Some(_) => return Err(invalid("model is HARNESS[/MODEL], for example claude/haiku")),
    };
    Ok(AskRequest { prompt: prompt.to_string(), model, timeout: TIMEOUT })
}

/// The extensions with an ask in flight.
#[derive(Default)]
pub struct InFlight(Mutex<BTreeSet<String>>);

struct Slot<'a> {
    set: &'a InFlight,
    app: String,
}

impl Drop for Slot<'_> {
    fn drop(&mut self) {
        self.set.0.lock().unwrap_or_else(|e| e.into_inner()).remove(&self.app);
    }
}

impl InFlight {
    fn take(&self, app: &str) -> Option<Slot<'_>> {
        let mut set = self.0.lock().unwrap_or_else(|e| e.into_inner());
        set.insert(app.to_string()).then(|| Slot { set: self, app: app.to_string() })
    }
}

fn cut(mut text: String) -> String {
    if text.len() > MAX_REPLY_BYTES {
        let mut end = MAX_REPLY_BYTES;
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        text.truncate(end);
    }
    text
}

/// Runs `params` for `app` on the calling (worker) thread.
pub fn ask(
    asker: Option<AgentAsker>,
    in_flight: &InFlight,
    app: &str,
    params: &Value,
) -> Result<Value, AskError> {
    let request = parse(params)?;
    let asker = asker.ok_or_else(|| AskError {
        code: "provider.unavailable",
        message: "this cmux has no agent to ask (acpmux is not set up)".into(),
        retryable: true,
    })?;
    let _slot = in_flight.take(app).ok_or_else(|| AskError {
        code: "app.busy",
        message: "this extension already has a question out to the agent".into(),
        retryable: true,
    })?;
    let started = Instant::now();
    let text = asker(&request).map_err(|message| AskError {
        code: "operation.failed",
        message,
        retryable: true,
    })?;
    Ok(json!({ "text": cut(text), "ms": started.elapsed().as_millis() as u64 }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn params_are_bounded() {
        assert!(parse(&json!({})).is_err());
        assert!(parse(&json!({ "prompt": "  " })).is_err());
        assert!(parse(&json!({ "prompt": "x".repeat(MAX_PROMPT_BYTES + 1) })).is_err());
        assert!(parse(&json!({ "prompt": "hi", "model": "claude; rm -rf" })).is_err());
        let ok = parse(&json!({ "prompt": " hi ", "model": "claude/haiku" })).unwrap();
        assert_eq!((ok.prompt.as_str(), ok.model.as_deref()), ("hi", Some("claude/haiku")));
    }

    #[test]
    fn one_ask_per_app_and_the_reply_is_cut() {
        let in_flight = InFlight::default();
        let held = in_flight.take("local/x").unwrap();
        let asker: AgentAsker = Arc::new(|_| Ok("é".repeat(MAX_REPLY_BYTES)));
        let busy = ask(Some(asker.clone()), &in_flight, "local/x", &json!({ "prompt": "hi" }))
            .unwrap_err();
        assert_eq!(busy.code, "app.busy");
        let other =
            ask(Some(asker.clone()), &in_flight, "local/y", &json!({ "prompt": "hi" })).unwrap();
        assert!(other["text"].as_str().unwrap().len() <= MAX_REPLY_BYTES);
        drop(held);
        assert!(ask(Some(asker), &in_flight, "local/x", &json!({ "prompt": "hi" })).is_ok());
        let none = ask(None, &in_flight, "local/x", &json!({ "prompt": "hi" })).unwrap_err();
        assert_eq!(none.code, "provider.unavailable");
    }
}
