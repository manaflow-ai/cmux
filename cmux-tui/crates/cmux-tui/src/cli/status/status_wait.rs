//! `cmux status wait KEY [--target <ws>] [--until settled|cleared|state=<s>]
//! [--timeout D]` (cx-6so.14, plans/cmux-next/status-indicators.md section
//! 5): blocks until the workspace status entry `KEY` holds the condition,
//! then prints it as `{workspace_id, key, cleared, entry}`.
//!
//! - `settled` (the default): the spec's `0 success/cleared, 1 error`. The
//!   entry is gone (cleared, its owner ended or its TTL passed: exit 0),
//!   shows `success` (exit 0) or shows `error` (exit 1). A key with no entry
//!   is settled at once.
//! - `cleared`: the entry is gone.
//! - `state=<s>`: the entry shows state `s` (an entry without one is `info`).
//!
//! Nothing polls: every status write, clear and daemon auto-clear commits a
//! `workspace_status` change to the session journal, so the wait holds the
//! session's `session.events` stream on a second connection, opened before
//! the first read, and reads the workspace's status again after each event.
//! A passed `--timeout` exits 124 with `wait.timeout`; without one the wait
//! lasts until the condition holds or Ctrl-C.

use std::io::BufReader;
use std::time::{Duration, Instant};

use cmux_tui_core::platform::transport;
use cmux_tui_core::resource::ResourceOperation;
use serde_json::{Map, Value, json};

use super::super::command::CommandPlan;
use super::super::resolve::{self, Failure, SocketRoute};
use super::super::{GlobalArgs, Surface, UsageError, wire};
use super::terminal_wait::{ANSWER_TIMEOUT, TIMEOUT_EXIT, answer_wait, duration, past};

/// The states `status set --state` takes.
const STATES: &[&str] = &["busy", "waiting", "success", "error", "info"];

#[derive(Clone, Debug, PartialEq, Eq)]
enum Until {
    Settled,
    Cleared,
    State(String),
}

impl Until {
    fn label(&self) -> String {
        match self {
            Self::Settled => "settled".to_owned(),
            Self::Cleared => "cleared".to_owned(),
            Self::State(state) => format!("state={state}"),
        }
    }

    /// `Some(exit code)` once `entry` (`None`: no entry) holds the condition.
    fn exit_code(&self, entry: Option<&Value>) -> Option<i32> {
        let state = entry.map(|entry| entry["state"].as_str().unwrap_or("info"));
        match (self, state) {
            (Self::Settled | Self::Cleared, None) => Some(0),
            (Self::Settled, Some("success")) => Some(0),
            (Self::Settled, Some("error")) => Some(1),
            (Self::State(wanted), Some(state)) if wanted == state => Some(0),
            _ => None,
        }
    }
}

struct WaitPlan {
    key: String,
    target: Option<String>,
    until: Until,
    timeout: Option<Duration>,
}

/// `status wait …`, given the words after `wait`.
pub(super) fn run(global: &GlobalArgs, words: &[String]) -> i32 {
    match parse(words) {
        Ok(plan) => wait(global, &plan),
        Err(error) => {
            super::super::app::failure("usage.invalid", &format!("cmux: {error}"), global.output, 2)
        }
    }
}

fn parse(words: &[String]) -> Result<WaitPlan, UsageError> {
    let mut key = None;
    let mut target = None;
    let mut until = Until::Settled;
    let mut timeout = None;
    let mut words = words.iter();
    while let Some(word) = words.next() {
        if !word.starts_with("--") {
            if key.replace(word.clone()).is_some() {
                return Err(UsageError::new(format!(
                    "status wait takes one KEY, not {word:?} too"
                )));
            }
            continue;
        }
        let (name, given) = match word.split_once('=') {
            Some((name, value)) => (name, Some(value.to_owned())),
            None => (word.as_str(), words.next().cloned()),
        };
        let value = given
            .filter(|value| !value.starts_with("--"))
            .ok_or_else(|| UsageError::new(format!("{name} needs a value")))?;
        match name {
            "--target" => target = Some(value),
            "--until" => until = parse_until(&value)?,
            "--timeout" => timeout = Some(duration(&value)?),
            "--timeout-ms" => {
                let millis = value.parse::<u64>().map_err(|_| {
                    UsageError::new("--timeout-ms takes a whole number of milliseconds")
                })?;
                timeout = Some(Duration::from_millis(millis));
            }
            other => {
                return Err(UsageError::new(format!(
                    "status wait takes KEY, --target, --until and --timeout, not {other}"
                )));
            }
        }
    }
    let key = key.ok_or_else(|| UsageError::new("status wait needs a KEY"))?;
    Ok(WaitPlan { key, target, until, timeout })
}

fn parse_until(value: &str) -> Result<Until, UsageError> {
    match value {
        "settled" => Ok(Until::Settled),
        "cleared" => Ok(Until::Cleared),
        _ => match value.strip_prefix("state=") {
            Some(state) if STATES.contains(&state) => Ok(Until::State(state.to_owned())),
            _ => Err(UsageError::new(format!(
                "--until takes settled, cleared or state=busy|waiting|success|error|info, not \
                 {value:?}"
            ))),
        },
    }
}

fn wait(global: &GlobalArgs, wait: &WaitPlan) -> i32 {
    let mut words = vec!["workspace".to_owned()];
    words.extend(wait.target.clone());
    words.extend(["status".to_owned(), "list".to_owned()]);
    let mut plan = match super::super::command::parse(&words, Surface::current()) {
        Ok(CommandPlan::Protocol(plan)) => *plan,
        Ok(_) => {
            return super::super::app::failure(
                "usage.invalid",
                "cmux: status wait is a daemon request",
                global.output,
                2,
            );
        }
        Err(error) => {
            return super::super::app::failure(
                "usage.invalid",
                &format!("cmux: {error}"),
                global.output,
                2,
            );
        }
    };
    if let Err(error) = resolve::apply_global_route(global, &mut plan) {
        eprintln!("cmux: {error}");
        return 2;
    }
    let (socket, derived) = match wire::resolve_socket_or_report(global) {
        Ok(resolved) => resolved,
        Err(code) => return code,
    };
    let deadline = wait.timeout.and_then(|timeout| Instant::now().checked_add(timeout));
    // The caller's terminal names the workspace only on its own session.
    let caller_route = global.socket.is_none() && global.session.is_none();
    let held = cmux_tui_core::server::connect_session_socket(&socket, derived)
        .map_err(|error| Failure::Local {
            error: json!({
                "code": "socket.unreachable",
                "message": wire::connect_failure(&socket, &error),
                "details": {"socket": socket.display().to_string()},
                "retryable": false,
            }),
            exit: 3,
        })
        .and_then(|stream| {
            let _ = stream.set_read_timeout(Some(ANSWER_TIMEOUT));
            let mut reader = BufReader::new(stream);
            let route = SocketRoute::new(&socket, derived, global);
            if !plan.resolve.is_empty() {
                resolve::apply(&mut reader, &mut plan, caller_route, &route)?;
            }
            let params = plan.params.as_object().cloned().ok_or_else(|| {
                Failure::Transport("cmux: request params are not an object".into())
            })?;
            hold(&mut reader, &route, params, wait, deadline)
        });
    match held {
        Ok((shown, code)) => match wire::print_success(&shown, global.output) {
            0 => code,
            failed => failed,
        },
        Err(failure) => failure.report(global.output),
    }
}

/// Reads the workspace's status until `wait.until` holds, waking on each
/// session event. Returns what to print and the exit code.
fn hold(
    reader: &mut BufReader<Box<dyn transport::Stream>>,
    socket: &SocketRoute<'_>,
    mut params: Map<String, Value>,
    wait: &WaitPlan,
    deadline: Option<Instant>,
) -> Result<(Value, i32), Failure> {
    // Subscribe before the first read: a change between that read and the
    // subscription still wakes the wait (the stream starts with a snapshot).
    let opened = Instant::now() + answer_wait(deadline);
    let mut events =
        resolve::session_events(socket, &resolve::route(&params), opened).ok_or_else(|| {
            if past(deadline) {
                timed_out(wait)
            } else {
                Failure::Transport("cmux: the session's event stream did not open".into())
            }
        })?;
    // Ctrl-C shuts the stream down, which ends a wait without a timeout.
    wire::arm_signal_interrupt(events.get_ref().as_ref());
    loop {
        // `--timeout` bounds every daemon answer too, not only the event wait.
        let _ = reader.get_mut().set_read_timeout(Some(answer_wait(deadline)));
        let listed = resolve::read(reader, ResourceOperation::WorkspaceStatusList, params.clone())
            .map_err(|failure| if past(deadline) { timed_out(wait) } else { failure })?;
        let snapshot = listed.as_array().and_then(|snapshots| snapshots.first());
        let workspace = snapshot
            .and_then(|snapshot| snapshot["workspace_id"].as_str())
            .map(str::to_owned)
            .or_else(|| params.get("workspace").and_then(Value::as_str).map(str::to_owned));
        // Later reads stay on this workspace even when `current` moves.
        if let Some(workspace) = &workspace {
            params.insert("workspace".into(), Value::String(workspace.clone()));
        }
        let entry = snapshot
            .and_then(|snapshot| snapshot["entries"].as_array())
            .and_then(|entries| entries.iter().find(|entry| entry["key"] == wait.key.as_str()));
        if let Some(code) = wait.until.exit_code(entry) {
            let shown = json!({
                "workspace_id": workspace,
                "key": wait.key,
                "cleared": entry.is_none(),
                "entry": entry,
            });
            return Ok((shown, code));
        }
        let remaining = match deadline {
            None => None,
            Some(deadline) => match deadline.checked_duration_since(Instant::now()) {
                Some(remaining) if !remaining.is_zero() => Some(remaining),
                _ => return Err(timed_out(wait)),
            },
        };
        if events.get_mut().set_read_timeout(remaining).is_err() {
            return Err(Failure::Transport("cmux: cannot wait on the event stream".into()));
        }
        match wire::read_envelope(&mut events, false) {
            Ok(Some(_)) => {}
            _ if crate::shutdown_requested() => {
                return Err(Failure::Local {
                    error: json!({
                        "code": "wait.interrupted",
                        "message": "cmux: the wait was interrupted",
                        "details": {"key": wait.key, "until": wait.until.label()},
                        "retryable": true,
                    }),
                    exit: 130,
                });
            }
            // The read timed out at the deadline: read the status once more
            // (a change may have landed just before it), then time out.
            Err(_) if past(deadline) => {}
            Ok(None) => {
                return Err(Failure::Transport("cmux: the session's event stream ended".into()));
            }
            Err(error) => return Err(Failure::Transport(error)),
        }
    }
}

fn timed_out(wait: &WaitPlan) -> Failure {
    let millis = wait.timeout.map_or(0, |timeout| timeout.as_millis());
    let until = wait.until.label();
    Failure::Local {
        error: json!({
            "code": "wait.timeout",
            "message": format!("the status entry {:?} was not {until} within {millis} ms", wait.key),
            "details": {"key": wait.key, "until": until, "timeout_ms": millis.to_string()},
            "retryable": true,
        }),
        exit: TIMEOUT_EXIT,
    }
}
