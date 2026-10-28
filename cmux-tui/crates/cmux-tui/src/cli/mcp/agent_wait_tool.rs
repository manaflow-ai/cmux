//! `agents_wait`: `cmux agents wait` as a tool. A call builds the words the
//! CLI takes and runs the CLI's parser and `agents::execute`, so both wait
//! the same way (`cli/agents/wait.rs`) and answer the same receipt. A client
//! that sends a `progressToken` gets `notifications/progress` while it waits.

use std::sync::mpsc::{self, RecvTimeoutError};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use serde_json::{Map, Value, json};

use super::super::GlobalArgs;
use super::super::agents::{self, AgentCommand, AgentFailure};
use super::{Backend, agent_tools, envelope, failure_result, success, tool_error, v2_tools, watch};

pub(super) const NAME: &str = "agents_wait";

#[cfg(not(test))]
const PROGRESS_EVERY: Duration = Duration::from_secs(5);
#[cfg(test)]
const PROGRESS_EVERY: Duration = Duration::from_millis(250);

const DESCRIPTION: &str = "Wait for other agents in cmux instead of polling agents_snapshot \
    (`cmux agents wait`). until idle: the agent of target (a term_, tab_ or agent_ id, or an \
    agent chat's session, as agents_snapshot shows them) stops working: idle, done or blocked \
    on a dialog, and match.state says which. until dialog: a permission or question dialog is \
    pending, target's when given (agents_dialog_list shows them). until text: text appears on \
    the screen of target (a terminal or terminal tab); regex true reads text as a regular \
    expression. It answers at once when the condition already holds, and answers {until, \
    matched, waited_seconds, match, state} with a fresh agents_snapshot-shaped state; a timeout \
    is matched false, not an error. timeout_seconds defaults to 30 and is at most 120. It reads \
    other agents' state and dialogs, as agents_snapshot and agents_dialog_list do, and a \
    terminal's screen, as terminal_wait does. Changes nothing. With a progressToken it reports \
    progress every 5 s.";

pub(super) fn descriptor() -> Value {
    json!({
        "name": NAME,
        "title": "Wait for agents",
        "description": DESCRIPTION,
        "inputSchema": input_schema(),
        "annotations": {
            "readOnlyHint": true,
            "destructiveHint": false,
            "idempotentHint": true,
            "openWorldHint": false,
        },
    })
}

fn input_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "until": {"type": "string", "enum": ["idle", "dialog", "text"]},
            "target": {
                "type": "string",
                "minLength": 1,
                "pattern": "^[^-]",
                "description": "A term_, tab_ or agent_ id or an agent chat's session \
                    (<session>:<id> routes to that session).",
            },
            "text": {"type": "string", "minLength": 1, "description": "For until text."},
            "regex": {"type": "boolean", "description": "Read text as a regular expression."},
            "timeout_seconds": {
                "type": "number",
                "minimum": 0,
                "maximum": agents::MAX_WAIT_SECONDS,
                "default": agents::DEFAULT_WAIT_SECONDS,
            },
            "session": {
                "type": "string",
                "minLength": 1,
                "description": "The named cmux session to use, as `cmux --session`.",
            },
        },
        "required": ["until"],
        "additionalProperties": false,
    })
}

/// Where and under which token a call reports progress.
pub(super) struct Progress {
    output: watch::Output,
    token: Value,
}

impl Progress {
    /// The call's `_meta.progressToken`, when it sent one and the server
    /// can write notifications.
    pub(super) fn requested(params: &Value, output: Option<&watch::Output>) -> Option<Self> {
        let token = params.get("_meta")?.get("progressToken")?;
        if !(token.is_string() || token.is_i64() || token.is_u64()) {
            return None;
        }
        Some(Self { output: output?.clone(), token: token.clone() })
    }
}

pub(super) fn call<B: Backend>(
    backend: &B,
    arguments: &Map<String, Value>,
    progress: Option<Progress>,
) -> Value {
    let not_run =
        |message: String| tool_error(envelope(v2_tools::invalid(message), "not_run", None));
    let (command, session) = match command(arguments) {
        Ok(call) => call,
        Err(message) => return not_run(message),
    };
    let ticker = match &command {
        AgentCommand::Wait(request) => Ticker::start(progress, request.timeout),
        _ => Ticker::start(None, Duration::ZERO),
    };
    let outcome = agents::execute(backend, session.as_deref(), &command, None, "mcp");
    drop(ticker);
    match outcome {
        Ok(receipt) => success(agent_tools::fit_receipt(receipt), false),
        Err(AgentFailure::Usage(message)) => not_run(message),
        Err(AgentFailure::Owner(failure)) => failure_result(failure),
    }
}

/// The `cmux agents wait` command these arguments name, and its session.
fn command(arguments: &Map<String, Value>) -> Result<(AgentCommand, Option<String>), String> {
    let schema = input_schema();
    if let Some(name) = arguments.keys().find(|name| schema["properties"].get(*name).is_none()) {
        return Err(format!("{NAME} has no argument {name:?}"));
    }
    let text = |name: &str| match arguments.get(name) {
        None => Ok(None),
        Some(Value::String(value)) if !value.is_empty() => Ok(Some(value.clone())),
        Some(_) => Err(format!("{NAME}: {name} must be a nonempty string")),
    };
    let until = text("until")?.ok_or_else(|| format!("{NAME}: until is required"))?;
    let mut words = vec!["wait".to_owned(), format!("--until={until}")];
    if let Some(target) = text("target")? {
        if target.starts_with('-') {
            return Err(format!("{NAME}: target must not start with '-'"));
        }
        words.extend(["--target".to_owned(), target]);
    }
    if let Some(value) = text("text")? {
        // Inline, so text that starts with `-` stays a value.
        words.push(format!("--text={value}"));
    }
    match arguments.get("regex") {
        None | Some(Value::Bool(false)) => {}
        Some(Value::Bool(true)) => words.push("--regex".to_owned()),
        Some(_) => return Err(format!("{NAME}: regex must be true or false")),
    }
    match arguments.get("timeout_seconds") {
        None => {}
        Some(Value::Number(seconds)) => {
            let seconds = seconds.as_f64().unwrap_or(f64::NAN);
            words.push(format!("--timeout={seconds}"));
        }
        Some(_) => return Err(format!("{NAME}: timeout_seconds must be a number")),
    }
    let mut global = GlobalArgs { session: text("session")?, ..GlobalArgs::default() };
    agents::normalize_qualified_targets(&mut global, &mut words).map_err(|error| error.0)?;
    let command = agents::command(&words).map_err(|error| error.0)?;
    Ok((command, global.session))
}

/// Sends `notifications/progress` every [`PROGRESS_EVERY`] until dropped:
/// `progress` is the seconds waited, `total` the timeout.
pub(super) struct Ticker {
    stop: Option<mpsc::Sender<()>>,
    thread: Option<JoinHandle<()>>,
}

impl Ticker {
    pub(super) fn start(progress: Option<Progress>, total: Duration) -> Self {
        let Some(progress) = progress else { return Self { stop: None, thread: None } };
        let (stop, stopped) = mpsc::channel::<()>();
        let started = Instant::now();
        let spawned =
            std::thread::Builder::new().name("cmux-mcp-wait-progress".into()).spawn(move || {
                loop {
                    match crate::blocking::sync::recv_timeout(&stopped, PROGRESS_EVERY) {
                        Err(RecvTimeoutError::Timeout) => {}
                        Ok(()) | Err(RecvTimeoutError::Disconnected) => return,
                    }
                    let elapsed = started.elapsed();
                    if elapsed >= total {
                        return;
                    }
                    let note = json!({
                        "jsonrpc": "2.0",
                        "method": "notifications/progress",
                        "params": {
                            "progressToken": progress.token.clone(),
                            "progress": (elapsed.as_millis() / 100) as f64 / 10.0,
                            "total": total.as_secs_f64(),
                        },
                    });
                    if progress.output.send(&note).is_err() {
                        return;
                    }
                }
            });
        // No thread, no notes: the wait itself still runs.
        Self { stop: Some(stop), thread: spawned.ok() }
    }
}

impl Drop for Ticker {
    fn drop(&mut self) {
        drop(self.stop.take());
        if let Some(thread) = self.thread.take() {
            let _ = crate::blocking::thread::join(thread);
        }
    }
}
