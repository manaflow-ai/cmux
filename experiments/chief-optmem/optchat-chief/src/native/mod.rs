//! The native engine: the Chief's turn loop on the Messages API, in the
//! host (section 9 allows "your own agent loop"). It is the engine that
//! keeps sections 7 and 8 whole, which a turn through acpmux and Claude Code
//! cannot:
//!
//! - Request layout and breakpoints (section 8): constant tools, then the
//!   constant system prompt, then the view cut at its marks with a
//!   breakpoint on each of the first three pieces, then the new messages;
//!   the top-level automatic `cache_control` is the fourth breakpoint, at the
//!   end of each request, so every step reads what the previous one wrote.
//! - A human message sent while the turn works interrupts it at once
//!   (decision 2026-10-04): a streaming step (thinking or text) is dropped
//!   at the next streamed event and the model is called again with the
//!   message; a running tool call finishes first and its result goes with
//!   the message. Delivered messages are logged as `user` (section 7).
//!   Children's reports are delivered between tool calls without one.
//! - Model outputs go back verbatim (thinking blocks and signatures).
//! - Every tool result is capped at CAP before it is logged and before it is
//!   sent back (section 7).
//!
//! Tools: Anthropic's `bash` and text editor (client-executed, approve-all
//! like the acpmux engine's policy), plus `zoom` and `date` answered from
//! the live memory. Subagents run through `chief agents` from bash.

mod api;
mod editor;
mod shell;
mod sse;

pub use api::{CallError, ChatModel, HttpModel};
pub use shell::Shell;
pub use sse::Assembler;
pub use sse::read_until;

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

use optchat_core::Kind;
use optchat_host::{OptChat, cap_tool_result};
use serde_json::{Value, json};

use crate::fold::{Usage, stop_error};
use crate::prompt::{DATE_DESCRIPTION, ZOOM_DESCRIPTION};
use crate::tools::Call;
use crate::turn::{TurnOutcome, TurnStart, usage_line};

/// Breakpoints in the view; the request's own automatic one is the fourth
/// (Anthropic allows four per request).
const VIEW_BREAKPOINTS: usize = 3;
/// Tries per model call; transient failures wait `Native::retry` between
/// tries (fixed, not exponential: the user waits on the turn).
const TRIES: u32 = 6;

/// How the native engine runs.
#[derive(Clone, Debug)]
pub struct NativeConfig {
    /// Model id (default `claude-opus-5-5`).
    pub model: String,
    /// `output_config.effort`.
    pub effort: Option<String>,
    pub max_tokens: u32,
    /// Send `fallbacks: "default"` (the beta header goes with it in `HttpModel`).
    pub server_fallback: bool,
    /// The system prompt (`prompt::claude_md`), constant for the host's life.
    pub system: String,
    /// Where the bash tool starts each turn.
    pub cwd: PathBuf,
    /// Env over the host's for the bash tool (MUX_HOME, PATH with `chief`, ...).
    pub env: BTreeMap<String, String>,
    /// Longest one bash command may run.
    pub bash_timeout: Duration,
    /// Where the bash tool records each command's final directory.
    pub pwd_file: PathBuf,
}

pub struct Native {
    config: NativeConfig,
    model: Arc<dyn ChatModel>,
    retry: Duration,
}

impl Native {
    pub fn new(config: NativeConfig, model: Arc<dyn ChatModel>, retry: Duration) -> Native {
        Native {
            config,
            model,
            retry,
        }
    }

    /// The tool list: constant, the head of every cached prefix (section 7.2).
    pub fn tools() -> Value {
        let integer = json!({"type": "integer", "minimum": 0});
        json!([
            {"type": "bash_20250124", "name": "bash"},
            {"type": "text_editor_20250728", "name": "str_replace_based_edit_tool"},
            {
                "name": "zoom",
                "description": ZOOM_DESCRIPTION,
                "input_schema": {
                    "type": "object",
                    "properties": {"id": integer, "n": integer},
                    "required": ["id", "n"],
                    "additionalProperties": false
                }
            },
            {
                "name": "date",
                "description": DATE_DESCRIPTION,
                "input_schema": {
                    "type": "object",
                    "properties": {"id": integer},
                    "required": ["id"],
                    "additionalProperties": false
                }
            }
        ])
    }

    /// The turn's first user message: the view pieces (a breakpoint on each
    /// of the first three) and the new messages, as `turn_blocks` cut them.
    pub fn first_message(blocks: &[Value]) -> Value {
        let views = blocks.len().saturating_sub(1);
        let content: Vec<Value> = blocks
            .iter()
            .enumerate()
            .map(|(i, block)| {
                let mut block = block.clone();
                if i < views && i < VIEW_BREAKPOINTS {
                    block["cache_control"] = json!({"type": "ephemeral"});
                }
                block
            })
            .collect();
        json!({"role": "user", "content": content})
    }

    /// One step's request body.
    pub fn body(&self, messages: &[Value]) -> Value {
        let mut body = json!({
            "model": self.config.model,
            "max_tokens": self.config.max_tokens,
            "stream": true,
            "system": self.config.system,
            "tools": Native::tools(),
            "messages": messages,
            // The end of each request: the next step reads it (section 8).
            "cache_control": {"type": "ephemeral"},
        });
        if let Some(effort) = &self.config.effort {
            body["output_config"] = json!({"effort": effort});
        }
        if self.config.server_fallback {
            body["fallbacks"] = json!("default");
        }
        body
    }

    fn call(
        &self,
        body: &Value,
        key: &str,
        log: &dyn Fn(&str),
        stop: &dyn Fn() -> bool,
    ) -> Result<Value, CallError> {
        let mut tries = 0;
        loop {
            tries += 1;
            match self.model.send(body, stop) {
                Ok(message) => return Ok(message),
                Err(e) if e.retry && tries < TRIES && !stop() => {
                    log(&format!(
                        "turn {key}: model call failed ({}); retrying in {} s",
                        e.message,
                        self.retry.as_secs()
                    ));
                    std::thread::sleep(self.retry);
                }
                Err(e) if e.retry && stop() => return Err(CallError::interrupted()),
                Err(e) => return Err(e),
            }
        }
    }

    /// Runs one turn to its end. `mailbox` is called between tool calls and
    /// after an interrupt, and returns the messages the brain logged for
    /// delivery; `interrupted` says a human message waits (checked after
    /// every streamed event).
    pub fn run(
        &self,
        chat: &OptChat,
        start: &TurnStart,
        log: &dyn Fn(&str),
        mailbox: &dyn Fn() -> Vec<String>,
        interrupted: &dyn Fn() -> bool,
    ) -> TurnOutcome {
        let deadline = start.limit.map(|limit| Instant::now() + limit);
        let shell = Shell::new(
            &self.config.cwd,
            self.config.env.clone(),
            self.config.pwd_file.clone(),
        );
        let append = |kind: Kind, text: &str| {
            if let Err(e) = chat.append(kind, text) {
                log(&format!("logging a {} entry failed: {e}", kind.as_str()));
            }
        };
        let mut messages = vec![Native::first_message(&start.blocks)];
        let mut reply: Option<String> = None;
        let mut first_usage = None;
        let mut totals = Usage::default();
        let error = loop {
            if deadline.is_some_and(|d| Instant::now() >= d) {
                break Some(limit_text(start.limit));
            }
            // A message that arrived since the last call goes with this one.
            if interrupted() {
                deliver(&mut messages, mailbox());
            }
            let message = match self.call(&self.body(&messages), &start.key, log, interrupted) {
                Ok(m) => m,
                Err(e) if e.interrupted => {
                    // The step is dropped whole: its thinking is never
                    // logged, and its unfinished text is not a reply.
                    log(&format!(
                        "turn {}: a new message arrived; the model was interrupted",
                        start.key
                    ));
                    deliver(&mut messages, mailbox());
                    continue;
                }
                Err(e) => break Some(e.message),
            };
            if let Some(usage) = message.get("usage").and_then(Usage::parse) {
                first_usage.get_or_insert(usage);
                totals.input += usage.input;
                totals.cache_read += usage.cache_read;
                totals.cache_write += usage.cache_write;
                totals.output += usage.output;
            }
            let content = message.get("content").cloned().unwrap_or(json!([]));
            let blocks = content.as_array().cloned().unwrap_or_default();
            // Section 7: each reply is `talk`, each call `tool`; thoughts never.
            for block in &blocks {
                match block.get("type").and_then(Value::as_str) {
                    Some("text") => {
                        let text = block
                            .get("text")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .trim();
                        if !text.is_empty() {
                            append(Kind::Talk, text);
                            reply = Some(text.to_owned());
                        }
                    }
                    Some("tool_use") => {
                        let name = block.get("name").and_then(Value::as_str).unwrap_or("tool");
                        let input = block.get("input").cloned().unwrap_or(json!({}));
                        append(Kind::Tool, &format!("{name} {input}"));
                    }
                    _ => {}
                }
            }
            messages.push(json!({"role": "assistant", "content": content}));
            let stop = message
                .get("stop_reason")
                .and_then(Value::as_str)
                .unwrap_or("");
            match stop {
                "tool_use" => {
                    let mut results = Vec::new();
                    for block in blocks.iter().filter(|b| b["type"] == "tool_use") {
                        let (text, is_error) = self.run_tool(block, chat, &shell, deadline);
                        let text = cap_tool_result(&text).into_owned();
                        append(
                            Kind::Echo,
                            &if is_error {
                                format!("error: {text}")
                            } else {
                                text.clone()
                            },
                        );
                        let mut result = json!({"type": "tool_result", "tool_use_id": block["id"], "content": text});
                        if is_error {
                            result["is_error"] = json!(true);
                        }
                        results.push(result);
                    }
                    messages.push(json!({"role": "user", "content": results}));
                    // Messages sent meanwhile, already logged as `user` by the brain.
                    deliver(&mut messages, mailbox());
                }
                // A paused server turn: send it back as it is to continue.
                "pause_turn" => {}
                "end_turn" | "stop_sequence" => break None,
                other => {
                    break stop_error(other)
                        .or_else(|| Some("the response had no stop reason".into()));
                }
            }
        };
        log(&usage_line(&start.key, first_usage, Some((totals, "turn total"))));
        TurnOutcome {
            reply,
            error,
            orphan: None,
            cancelled: false,
        }
    }

    /// One tool call: (result text, is_error).
    fn run_tool(
        &self,
        block: &Value,
        chat: &OptChat,
        shell: &Shell,
        deadline: Option<Instant>,
    ) -> (String, bool) {
        let name = block.get("name").and_then(Value::as_str).unwrap_or("");
        let input = block.get("input").cloned().unwrap_or(json!({}));
        let result = match name {
            "bash" => {
                if input.get("restart").and_then(Value::as_bool) == Some(true) {
                    shell.restart();
                    Ok("The shell was restarted.".to_owned())
                } else {
                    match input.get("command").and_then(Value::as_str) {
                        Some(command) => {
                            let left = deadline
                                .map(|d| d.saturating_duration_since(Instant::now()))
                                .unwrap_or(self.config.bash_timeout);
                            shell.run(command, left.min(self.config.bash_timeout))
                        }
                        None => Err("missing `command`".to_owned()),
                    }
                }
            }
            "str_replace_based_edit_tool" => editor::run(&input, &shell.cwd()),
            "zoom" | "date" => Call::parse(name, &input).map(|call| call.answer(chat)),
            other => Err(format!("unknown tool {other}")),
        };
        match result {
            Ok(text) => (text, false),
            Err(text) => (text, true),
        }
    }
}

/// Adds delivered messages (already logged as `user` by the brain) to the
/// request: at the end of the last user message, else as a new one.
fn deliver(messages: &mut Vec<Value>, delivered: Vec<String>) {
    if delivered.is_empty() {
        return;
    }
    let block = json!({"type": "text", "text": delivered.join("\n\n")});
    if let Some(last) = messages.last_mut()
        && last["role"] == "user"
        && let Some(content) = last["content"].as_array_mut()
    {
        content.push(block);
        return;
    }
    messages.push(json!({"role": "user", "content": [block]}));
}

fn limit_text(limit: Option<Duration>) -> String {
    format!(
        "the turn ran past its limit of {} minutes and was stopped",
        limit.unwrap_or_default().as_secs() / 60
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn at_most_three_view_breakpoints_plus_the_request_end() {
        // A view past 100k characters: three marks cut four pieces.
        let line = format!("{}\n", "x".repeat(99));
        let mut view = String::from("<chat>\n");
        for _ in 0..1_100 {
            view.push_str(&line);
        }
        view.push_str("</chat>");
        let blocks = crate::prompt::turn_blocks(&view, &["new".into()]);
        assert_eq!(blocks.len(), 5);
        let message = Native::first_message(&blocks);
        let marked: Vec<bool> = message["content"]
            .as_array()
            .unwrap()
            .iter()
            .map(|b| b.get("cache_control").is_some())
            .collect();
        assert_eq!(marked, vec![true, true, true, false, false]);
    }
}
