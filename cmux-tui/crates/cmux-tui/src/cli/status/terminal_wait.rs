//! `cmux terminal <t> wait --until idle|prompt [--timeout D]` (cx-6so.14,
//! plans/cmux-next/status-indicators.md section 5): blocks until the
//! terminal's shell facts (`terminal-activity-v1`) hold, then prints its
//! record as `terminal <t> show` does.
//!
//! - `prompt`: the shell sits at its prompt (`extra.prompt`: OSC 133 A, until
//!   the next command starts). A shell without shell integration never shows
//!   one; an exited terminal fails the wait.
//! - `idle`: nothing in the terminal works: no plain shell command runs
//!   (`extra.activity` `running`), no program reports `working` (OSC 7501)
//!   and no OSC 9;4 progress is under way. An interactive command
//!   (`in_use`: vim, a REPL, an agent's own screen) is idle unless it
//!   reports work itself.
//!
//! Nothing polls: the wait holds the session's `session.events` stream on a
//! second connection, opened before the first read, and reads the record
//! again after each event. A passed `--timeout` exits 124 with
//! `wait.timeout`; without one the wait lasts until the condition holds or
//! Ctrl-C.

use std::io::BufReader;
use std::time::{Duration, Instant};

use cmux_tui_core::platform::transport;
use cmux_tui_core::resource::ResourceOperation;
use serde_json::{Map, Value, json};

use super::super::command::CommandPlan;
use super::super::resolve::{self, Failure, SocketRoute};
use super::super::{GlobalArgs, Surface, UsageError, wire};

/// The exit code of a wait whose timeout passed, as timeout(1) has it.
pub(super) const TIMEOUT_EXIT: i32 = 124;
/// How long the daemon may take to open the event stream or answer a read.
pub(super) const ANSWER_TIMEOUT: Duration = Duration::from_secs(10);
/// A read timeout may wake this much before the deadline it was set for.
const DEADLINE_SLACK: Duration = Duration::from_millis(50);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Until {
    Idle,
    Prompt,
}

impl Until {
    fn as_str(self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::Prompt => "prompt",
        }
    }
}

/// `Some(exit code)` for `terminal <t> wait …`; `None` for any other
/// terminal command.
pub(super) fn run(global: &GlobalArgs, words: &[String]) -> Option<i32> {
    let [selector, verb, flags @ ..] = words else { return None };
    if verb != "wait" {
        return None;
    }
    Some(match parse(flags) {
        Ok((until, timeout)) => wait(global, selector, until, timeout),
        Err(error) => {
            super::super::app::failure("usage.invalid", &format!("cmux: {error}"), global.output, 2)
        }
    })
}

fn parse(words: &[String]) -> Result<(Until, Option<Duration>), UsageError> {
    let mut until = None;
    let mut timeout = None;
    let mut words = words.iter();
    while let Some(word) = words.next() {
        let (name, inline) = match word.split_once('=') {
            Some((name, value)) => (name, Some(value.to_owned())),
            None => (word.as_str(), None),
        };
        let given = match inline {
            Some(value) => Some(value),
            None if name.starts_with("--") => words.next().cloned(),
            None => None,
        };
        let value = || {
            given
                .clone()
                .filter(|value| !value.starts_with("--"))
                .ok_or_else(|| UsageError::new(format!("{name} needs a value")))
        };
        match name {
            "--until" => {
                until = Some(match value()?.as_str() {
                    "idle" => Until::Idle,
                    "prompt" => Until::Prompt,
                    other => {
                        return Err(UsageError::new(format!(
                            "--until takes idle or prompt, not {other:?}"
                        )));
                    }
                });
            }
            "--timeout" => timeout = Some(duration(&value()?)?),
            "--timeout-ms" => {
                let millis = value()?.parse::<u64>().map_err(|_| {
                    UsageError::new("--timeout-ms takes a whole number of milliseconds")
                })?;
                timeout = Some(Duration::from_millis(millis));
            }
            other => {
                return Err(UsageError::new(format!(
                    "terminal wait takes --until idle|prompt and --timeout, not {other}"
                )));
            }
        }
    }
    let until = until.ok_or_else(|| {
        UsageError::new(
            "terminal wait needs --until idle|prompt (screen wait and process wait wait for \
             output and exit)",
        )
    })?;
    Ok((until, timeout))
}

/// `500ms`, `30s` (or `30`), `5m`, `1h`.
pub(in crate::cli) fn duration(text: &str) -> Result<Duration, UsageError> {
    let invalid = || {
        UsageError::new(format!(
            "--timeout takes a duration such as 500ms, 30s, 5m or 1h, not {text:?}"
        ))
    };
    let digits = text.find(|character: char| !character.is_ascii_digit()).unwrap_or(text.len());
    let (number, unit) = text.split_at(digits);
    let number = number.parse::<u64>().map_err(|_| invalid())?;
    let millis = match unit {
        "ms" => Some(number),
        "" | "s" => number.checked_mul(1_000),
        "m" => number.checked_mul(60_000),
        "h" => number.checked_mul(3_600_000),
        _ => None,
    };
    millis.map(Duration::from_millis).ok_or_else(invalid)
}

fn wait(global: &GlobalArgs, selector: &str, until: Until, timeout: Option<Duration>) -> i32 {
    let words = ["terminal".to_owned(), selector.to_owned(), "show".to_owned()];
    let mut plan = match super::super::command::parse(&words, Surface::current()) {
        Ok(CommandPlan::Protocol(plan)) => *plan,
        Ok(_) => {
            return super::super::app::failure(
                "usage.invalid",
                "cmux: terminal wait is a daemon request",
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
    let deadline = timeout.and_then(|timeout| Instant::now().checked_add(timeout));
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
            // `terminal current wait` waits on the caller's own terminal.
            let caller_route = global.socket.is_none() && global.session.is_none();
            resolve::apply(&mut reader, &mut plan, caller_route, &route)?;
            let params = plan.params.as_object().cloned().ok_or_else(|| {
                Failure::Transport("cmux: request params are not an object".into())
            })?;
            hold(&mut reader, &route, &params, until, deadline, timeout)
        });
    match held {
        Ok(record) => wire::print_result(global, &plan, record),
        Err(failure) => failure.report(global.output),
    }
}

/// Reads the terminal until `until` holds, waking on each session event.
fn hold(
    reader: &mut BufReader<Box<dyn transport::Stream>>,
    socket: &SocketRoute<'_>,
    params: &Map<String, Value>,
    until: Until,
    deadline: Option<Instant>,
    timeout: Option<Duration>,
) -> Result<Value, Failure> {
    // Subscribe before the first read: a change between that read and the
    // subscription still wakes the wait (the stream starts with a snapshot).
    let opened = Instant::now() + answer_wait(deadline);
    let mut events =
        resolve::session_events(socket, &resolve::route(params), opened).ok_or_else(|| {
            if past(deadline) {
                timed_out(until, timeout)
            } else {
                Failure::Transport("cmux: the session's event stream did not open".into())
            }
        })?;
    // Ctrl-C shuts the stream down, which ends a wait without a timeout.
    wire::arm_signal_interrupt(events.get_ref().as_ref());
    loop {
        // `--timeout` bounds every daemon answer too, not only the event wait.
        let _ = reader.get_mut().set_read_timeout(Some(answer_wait(deadline)));
        let record = resolve::read(reader, ResourceOperation::TerminalGet, params.clone())
            .map_err(|failure| if past(deadline) { timed_out(until, timeout) } else { failure })?;
        if holds(&record, until)? {
            return Ok(record);
        }
        let remaining = match deadline {
            None => None,
            Some(deadline) => match deadline.checked_duration_since(Instant::now()) {
                Some(remaining) if !remaining.is_zero() => Some(remaining),
                _ => return Err(timed_out(until, timeout)),
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
                        "details": {"until": until.as_str()},
                        "retryable": true,
                    }),
                    exit: 130,
                });
            }
            // The read timed out at the deadline: read the record once more
            // (a change may have landed just before it), then time out.
            Err(_) if past(deadline) => {}
            Ok(None) => {
                return Err(Failure::Transport("cmux: the session's event stream ended".into()));
            }
            Err(error) => return Err(Failure::Transport(error)),
        }
    }
}

/// Whether the record shows `until`. An exited terminal is idle, and can
/// never show a prompt again.
fn holds(record: &Value, until: Until) -> Result<bool, Failure> {
    let extra = &record["extra"];
    match until {
        Until::Prompt if extra["prompt"].is_object() => Ok(true),
        Until::Prompt if record["lifecycle"] == "exited" => Err(Failure::Local {
            error: json!({
                "code": "terminal.exited",
                "message": "the terminal exited before it showed a prompt",
                "details": {"terminal": record["id"], "until": "prompt"},
                "retryable": false,
            }),
            exit: 1,
        }),
        Until::Prompt => Ok(false),
        Until::Idle => {
            let command = extra["activity"]["state"] == "running";
            let progress =
                matches!(extra["progress"]["state"].as_str(), Some("normal" | "indeterminate"));
            let working = extra["program_status"]
                .as_array()
                .is_some_and(|records| records.iter().any(|record| record["state"] == "working"));
            Ok(!(command || progress || working))
        }
    }
}

/// How long to wait for one daemon answer: its usual bound, cut to what is
/// left of the deadline (at least 1 ms: a zero socket timeout is refused).
pub(super) fn answer_wait(deadline: Option<Instant>) -> Duration {
    deadline.map_or(ANSWER_TIMEOUT, |deadline| {
        deadline
            .saturating_duration_since(Instant::now())
            .clamp(Duration::from_millis(1), ANSWER_TIMEOUT)
    })
}

/// Whether the deadline has (all but) passed.
pub(super) fn past(deadline: Option<Instant>) -> bool {
    deadline.is_some_and(|deadline| Instant::now() + DEADLINE_SLACK >= deadline)
}

fn timed_out(until: Until, timeout: Option<Duration>) -> Failure {
    let millis = timeout.map_or(0, |timeout| timeout.as_millis());
    let condition = match until {
        Until::Idle => "idle",
        Until::Prompt => "at its prompt",
    };
    Failure::Local {
        error: json!({
            "code": "wait.timeout",
            "message": format!("the terminal was not {condition} within {millis} ms"),
            "details": {"until": until.as_str(), "timeout_ms": millis.to_string()},
            "retryable": true,
        }),
        exit: TIMEOUT_EXIT,
    }
}
