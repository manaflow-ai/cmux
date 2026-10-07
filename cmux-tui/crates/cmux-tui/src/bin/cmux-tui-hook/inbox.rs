//! Agent messages (`cmux agent message`) for the agent in this terminal,
//! handed over as the hook's output: extra context for a submitted prompt,
//! or, for codex, a reason to keep going instead of stopping. Delivery is at
//! least once: the output is written before the messages are marked
//! delivered, so a lost mark means the agent may see a message twice, never
//! that it misses one.
//!
//! The installed command for these events prints `{}` only when this helper
//! fails, so on success the helper prints exactly one JSON object itself.

use super::*;

/// Queued messages one hook asks the daemon for, oldest first.
const PAGE: u64 = 50;
/// Rendered text one hook hands over; later messages wait for the next
/// hook. Codex keeps 2,500 tokens of hook output by default.
const MAX_TEXT_BYTES: usize = 8 * 1024;
const DEADLINE: Duration = Duration::from_millis(1500);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Delivery {
    /// `UserPromptSubmit`: `hookSpecificOutput.additionalContext`.
    PromptContext { via: &'static str },
    /// codex `Stop`: `{"decision":"block","reason":…}` continues the turn.
    /// Messages delivered earlier count as read once a turn ends.
    ContinueTurn,
}

impl Delivery {
    pub(super) fn for_event(source: &str, native_event: &str) -> Option<Self> {
        match (source, native_event) {
            ("claude", "UserPromptSubmit") => {
                Some(Self::PromptContext { via: "claude.prompt-submit" })
            }
            ("codex", "UserPromptSubmit") => {
                Some(Self::PromptContext { via: "codex.prompt-submit" })
            }
            ("codex", "Stop") => Some(Self::ContinueTurn),
            _ => None,
        }
    }

    fn via(self) -> &'static str {
        match self {
            Self::PromptContext { via } => via,
            Self::ContinueTurn => "codex.stop",
        }
    }

    pub(super) fn output(self, text: Option<&str>) -> Value {
        match (self, text) {
            (_, None) => json!({}),
            (Self::PromptContext { .. }, Some(text)) => json!({
                "hookSpecificOutput": {
                    "hookEventName": "UserPromptSubmit",
                    "additionalContext": text,
                }
            }),
            (Self::ContinueTurn, Some(text)) => json!({"decision": "block", "reason": text}),
        }
    }
}

/// The empty object for an event that delivers messages, when there are
/// none to hand over.
pub(super) fn print_nothing(delivery: Option<Delivery>) {
    if let Some(delivery) = delivery {
        print_output(&delivery.output(None));
    }
}

fn print_output(value: &Value) {
    let mut stdout = io::stdout().lock();
    let _ = writeln!(stdout, "{value}");
    let _ = stdout.flush();
}

pub(super) fn deliver(delivery: Delivery, socket: &Path, terminal: Option<&str>) {
    let Some(terminal) = terminal.filter(|terminal| terminal.starts_with("term_")) else {
        print_nothing(Some(delivery));
        return;
    };
    let deadline = Instant::now() + DEADLINE;
    if delivery == Delivery::ContinueTurn {
        let _ = acknowledge_delivered(socket, terminal, deadline);
    }
    let messages = match queued(socket, terminal, deadline) {
        Ok(messages) => messages,
        Err(_) => {
            print_nothing(Some(delivery));
            return;
        }
    };
    let batch = batch(messages);
    if batch.is_empty() {
        print_nothing(Some(delivery));
        return;
    }
    let text = cmux_tui_core::agent_message_prompt::render(&batch);
    print_output(&delivery.output(Some(&text)));
    let ids: Vec<&str> = batch.iter().filter_map(|message| message["id"].as_str()).collect();
    let _ = request(
        socket,
        "agent.message.mark",
        json!({"ids": ids, "recipient": terminal, "state": "delivered", "via": delivery.via()}),
        true,
        deadline,
    );
}

/// The oldest queued messages that fit in one hook's output; always at
/// least one.
pub(super) fn batch(oldest_first: Vec<Value>) -> Vec<Value> {
    let mut batch = Vec::new();
    let mut bytes = 0;
    for message in oldest_first {
        let size = message["body"].as_str().map_or(0, str::len) + 512;
        if !batch.is_empty() && bytes + size > MAX_TEXT_BYTES {
            break;
        }
        bytes += size;
        batch.push(message);
    }
    batch
}

fn queued(socket: &Path, terminal: &str, deadline: Instant) -> anyhow::Result<Vec<Value>> {
    let listed = request(
        socket,
        "agent.message.list",
        json!({"recipient": terminal, "state": "queued", "oldest_first": true, "limit": PAGE}),
        false,
        deadline,
    )?;
    Ok(listed.as_array().cloned().unwrap_or_default())
}

fn acknowledge_delivered(socket: &Path, terminal: &str, deadline: Instant) -> anyhow::Result<()> {
    let listed = request(
        socket,
        "agent.message.list",
        json!({"recipient": terminal, "state": "delivered", "limit": 1000}),
        false,
        deadline,
    )?;
    let ids: Vec<&str> = listed
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|message| message["id"].as_str())
        .collect();
    if !ids.is_empty() {
        request(
            socket,
            "agent.message.mark",
            json!({"ids": ids, "recipient": terminal, "state": "acknowledged", "via": "codex.stop"}),
            true,
            deadline,
        )?;
    }
    Ok(())
}

/// One `cmux.protocol/2` request on its own connection.
fn request(
    socket: &Path,
    operation: &str,
    mut params: Value,
    mutation: bool,
    deadline: Instant,
) -> anyhow::Result<Value> {
    let (request_id, idempotency_key) = random_identifiers()?;
    params["machine"] = json!("current");
    params["session"] = json!("current");
    let mut request = json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "id": request_id,
        "operation": operation,
        "params": params,
    });
    if mutation {
        request["idempotency_key"] = Value::String(idempotency_key);
    }
    let mut encoded = serde_json::to_vec(&request)?;
    encoded.push(b'\n');
    let attempt = || -> Result<Vec<u8>, AppendAttemptError> {
        let mut stream = connect_before(socket, deadline)?;
        write_before(&mut *stream, &encoded, deadline)?;
        read_before(stream, deadline)
    };
    let response = attempt().map_err(|error| match error {
        AppendAttemptError::Retryable(error) | AppendAttemptError::Fatal(error) => error,
    })?;
    let response: Value = serde_json::from_slice(&response)?;
    if response["id"].as_str() != Some(request_id.as_str()) {
        bail!("{operation} returned a mismatched request id");
    }
    if response["ok"] != true {
        bail!("{operation} failed: {}", response["error"]["message"]);
    }
    let result = response["result"].clone();
    Ok(if mutation { result["value"].clone() } else { result })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn message_events_map_to_their_provider_output() {
        assert_eq!(Delivery::for_event("claude", "Stop"), None);
        assert_eq!(Delivery::for_event("gemini", "UserPromptSubmit"), None);
        let prompt = Delivery::for_event("codex", "UserPromptSubmit").unwrap();
        assert_eq!(prompt.output(None), json!({}));
        assert_eq!(
            prompt.output(Some("hi")),
            json!({"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": "hi"}})
        );
        let stop = Delivery::for_event("codex", "Stop").unwrap();
        assert_eq!(stop.output(Some("hi")), json!({"decision": "block", "reason": "hi"}));
        assert!(Delivery::for_event("claude", "UserPromptSubmit").is_some());
    }

    #[test]
    fn a_hook_hands_over_the_oldest_messages_that_fit() {
        let message = |id: &str, bytes: usize| json!({"id": id, "body": "x".repeat(bytes)});
        // The daemon lists oldest first (oldest_first).
        let ids = |batch: Vec<Value>| -> Vec<String> {
            batch.iter().map(|message| message["id"].as_str().unwrap().to_owned()).collect()
        };
        assert_eq!(
            ids(batch(vec![message("m1", 10), message("m2", 10), message("m3", 10)])),
            ["m1", "m2", "m3"]
        );
        assert_eq!(ids(batch(vec![message("m1", 6000), message("m2", 6000)])), ["m1"]);
        // One message always goes, however long.
        assert_eq!(ids(batch(vec![message("m1", 30_000)])), ["m1"]);
    }
}
