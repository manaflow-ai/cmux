//! `cmux terminal <t> wait --until idle|prompt|ready [--timeout D]` (cx-6so.14,
//! plans/cmux-next/status-indicators.md section 5): blocks until the
//! terminal's shell facts (`terminal-activity-v1`) hold, then prints one
//! shape for every condition (W6-C): `{terminal_id, until, state,
//! waited_ms}`, with the terminal's record as `terminal` for idle and
//! prompt. An idle wait whose agent waits on a dialog answers `blocked`
//! with `dialog` and `reason` and exits 4, as `--until ready` does.
//!
//! - `prompt`: the shell sits at its prompt (`extra.prompt`: OSC 133 A, until
//!   the next command starts). A shell without shell integration never shows
//!   one; an exited terminal fails the wait.
//! - `idle`: nothing in the terminal works: no plain shell command runs
//!   (`extra.activity` `running`), no program reports `working` (OSC 7501)
//!   and no OSC 9;4 progress is under way. An interactive command
//!   (`in_use`: vim, a REPL, an agent's own screen) is idle unless it
//!   reports work itself.
//!   Idle right after input is not yet an answer (W5-R, bench round 4 item
//!   10): when a client wrote input less than `INPUT_GRACE_MS` ago
//!   (`extra.last_input`), the wait holds until the terminal answers it (a
//!   work state seen during the wait and ended, or a command finished or a
//!   prompt drawn after the input), or until the grace passes with nothing
//!   started. An agent's turn starts within a second of Enter under load.
//!
//! - `ready`: the terminal's agent can take a message: no startup dialog,
//!   and its hooks say idle or its input box shows. A dialog (Claude's
//!   folder-trust question, a login) ends the wait as `blocked` (exit 4).
//!   It looks four times a second, like `agent start` (agent_start.rs).
//!
//! Nothing else polls: the wait holds the session's `session.events` stream on a
//! second connection, opened before the first read, and reads the record
//! again after each event. A passed `--timeout` exits 124 with
//! `wait.timeout`; without one the wait lasts until the condition holds or
//! Ctrl-C.

use std::io::BufReader;
use std::time::{Duration, Instant};

use cmux_json::JsonSet as _;
use cmux_tui_core::platform::transport;
use cmux_tui_core::resource::ResourceOperation;
use serde_json::{Map, Value, json};

use super::super::agent_start::{BLOCKED_EXIT, dialog_options};
use super::super::command::CommandPlan;
use super::super::resolve::{self, Failure, SocketRoute};
use super::super::{GlobalArgs, OutputMode, Surface, UsageError, wire};

/// The exit code of a wait whose timeout passed, as timeout(1) has it.
pub(super) const TIMEOUT_EXIT: i32 = 124;
/// How long the daemon may take to open the event stream or answer a read.
pub(super) const ANSWER_TIMEOUT: Duration = Duration::from_secs(10);
/// A read timeout may wake this much before the deadline it was set for.
const DEADLINE_SLACK: Duration = Duration::from_millis(50);
/// How long after input an idle terminal may take to show that the input
/// started work. Measured: Claude Code's first `working` report came
/// 116-897 ms after Enter at load average ~150 (owners/W5-R.md).
const INPUT_GRACE_MS: u64 = 3_000;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Until {
    Idle,
    Prompt,
    /// The terminal's agent can take a message (agent_start/readiness.rs).
    Ready,
}

impl Until {
    fn as_str(self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::Prompt => "prompt",
            Self::Ready => "ready",
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
        Ok((Until::Ready, timeout)) => {
            super::super::agent_start::wait_ready_command(global, selector, timeout)
        }
        Ok((until, timeout)) => wait(global, selector, until, timeout),
        Err(error) => {
            super::super::app::failure("usage.invalid", &format!("cmux: {error}"), global.output, 2)
        }
    })
}

pub(super) fn parse(words: &[String]) -> Result<(Until, Option<Duration>), UsageError> {
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
                    "ready" => Until::Ready,
                    other => {
                        return Err(UsageError::new(format!(
                            "--until takes idle, prompt or ready, not {other:?}"
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
                    "terminal wait takes --until idle|prompt|ready and --timeout, not {other}"
                )));
            }
        }
    }
    let until = until.ok_or_else(|| {
        UsageError::new(
            "terminal wait needs --until idle|prompt|ready (screen wait and process wait wait \
             for output and exit)",
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
    let started = Instant::now();
    let deadline = timeout.and_then(|timeout| started.checked_add(timeout));
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
            let caller_route = wire::routes_to_caller_session(global);
            resolve::apply(&mut reader, &mut plan, caller_route, &route)?;
            let params = plan.params.as_object().cloned().ok_or_else(|| {
                Failure::Transport("cmux: request params are not an object".into())
            })?;
            let record = hold(&mut reader, &route, &params, until, deadline, timeout)?;
            Ok(answer(&mut reader, &params, until, record, started))
        });
    match held {
        Ok((answer, exit)) => print_answer(global, &answer, exit),
        Err(failure) => failure.report(global.output),
    }
}

/// The one shape every `terminal wait` answers (W6-C, bench round 5
/// orchestration row 4), as `--until ready` does: `{terminal_id, until,
/// state, waited_ms, terminal}` with the terminal's record, and the exit
/// code. An idle wait whose agent waits on a dialog is `blocked` (exit 4)
/// with `dialog` (agent_start/dialog_options.rs `blocked_dialog`) and a
/// localized `reason`; the screen is read only then.
fn answer(
    reader: &mut BufReader<Box<dyn transport::Stream>>,
    params: &Map<String, Value>,
    until: Until,
    record: Value,
    started: Instant,
) -> (Value, i32) {
    let id = record.get("id").and_then(Value::as_str).unwrap_or_default().to_owned();
    let mut answer = json!({
        "terminal_id": id,
        "until": until.as_str(),
        "state": until.as_str(),
        "waited_ms": started.elapsed().as_millis().to_string(),
    });
    let dialog = (until == Until::Idle).then(|| blocked(reader, params, &id, &record)).flatten();
    let exit = match dialog {
        Some(dialog) => {
            let messages = &crate::localization::catalog().pane_cli;
            let reason = dialog_options::dialog_reason(messages, &id, &dialog);
            answer.set("state", json!("blocked"));
            answer.set("dialog", dialog);
            answer.set("reason", json!(reason));
            BLOCKED_EXIT
        }
        None => 0,
    };
    answer.set("terminal", record);
    (answer, exit)
}

/// The dialog the terminal's agent waits on, from its agent records and
/// (only when those or its program status say blocked) its screen; `None`
/// when nothing says blocked or the agent records cannot be read.
fn blocked(
    reader: &mut BufReader<Box<dyn transport::Stream>>,
    params: &Map<String, Value>,
    id: &str,
    record: &Value,
) -> Option<Value> {
    let mut agent_params = resolve::route(params);
    agent_params.insert("terminal_id".into(), json!(id));
    let agents = resolve::read(reader, ResourceOperation::AgentList, agent_params)
        .ok()
        .and_then(|agents| agents.as_array().cloned())
        .unwrap_or_default();
    dialog_options::blocked_dialog(record, &agents, "")?;
    let mut screen_params = resolve::route(params);
    screen_params.insert("terminal".into(), json!(id));
    let screen = resolve::read(reader, ResourceOperation::TerminalScreenRead, screen_params)
        .ok()
        .and_then(|screen| screen.get("text").and_then(Value::as_str).map(str::to_owned))
        .unwrap_or_default();
    dialog_options::blocked_dialog(record, &agents, &screen)
}

/// Prints a wait's answer: JSON as it is, or for a person one line (`term_…
/// idle`, `term_… blocked (permission)`) and the reason below it.
fn print_answer(global: &GlobalArgs, answer: &Value, exit: i32) -> i32 {
    if global.output != OutputMode::Human {
        let code = wire::print_local_success(answer, global.output);
        return if code == 0 { exit } else { code };
    }
    let field = |key: &str| answer[key].as_str().unwrap_or("-").to_owned();
    match answer.pointer("/dialog/kind").and_then(Value::as_str) {
        Some(kind) => println!("{} {} ({kind})", field("terminal_id"), field("state")),
        None => println!("{} {}", field("terminal_id"), field("state")),
    }
    if let Some(reason) = answer["reason"].as_str() {
        println!("  {reason}");
    }
    exit
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
    // A work state seen during this wait: its end answers the input.
    let mut seen_work = false;
    loop {
        // `--timeout` bounds every daemon answer too, not only the event wait.
        let _ = reader.get_mut().set_read_timeout(Some(answer_wait(deadline)));
        let record = resolve::read(reader, ResourceOperation::TerminalGet, params.clone())
            .map_err(|failure| if past(deadline) { timed_out(until, timeout) } else { failure })?;
        let held = holds(&record, until)?;
        if until == Until::Idle && !held {
            seen_work = true;
        }
        let grace = if held && until == Until::Idle {
            unanswered_input_grace(&record, seen_work, now_epoch_ms())
        } else {
            None
        };
        if held && grace.is_none() {
            return Ok(record);
        }
        let grace_end = grace.map(|left| Instant::now() + left);
        let remaining = match deadline {
            None => None,
            Some(deadline) => match deadline.checked_duration_since(Instant::now()) {
                Some(remaining) if !remaining.is_zero() => Some(remaining),
                // Idle, only waiting out the input's grace: the old answer.
                _ if held => return Ok(record),
                _ => return Err(timed_out(until, timeout)),
            },
        };
        let remaining = match (remaining, grace) {
            (Some(remaining), Some(grace)) => Some(remaining.min(grace)),
            (remaining, grace) => remaining.or(grace),
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
            // The input's grace passed: read the record once more.
            Err(_) if past(grace_end) => {}
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
        Until::Prompt | Until::Ready => Ok(false),
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

/// For an idle record: how much longer to wait for the terminal to answer
/// input written less than `INPUT_GRACE_MS` ago (`extra.last_input`), or
/// none when the input is answered or old. Answered: a work state seen
/// during the wait (`seen_work`), or a command finished or a prompt drawn
/// at or after the input. A `last_input` further ahead of this clock than
/// the grace (another machine's clock) is ignored.
fn unanswered_input_grace(record: &Value, seen_work: bool, now_ms: u64) -> Option<Duration> {
    let ms = |pointer: &str| {
        record.pointer(pointer).and_then(Value::as_str).and_then(|text| text.parse::<u64>().ok())
    };
    let input = ms("/extra/last_input/at_ms")?;
    let answered = seen_work
        || [ms("/extra/last_command/finished_at_ms"), ms("/extra/prompt/since_ms")]
            .into_iter()
            .flatten()
            .any(|at| at >= input);
    let left = input.saturating_add(INPUT_GRACE_MS).checked_sub(now_ms)?;
    (!answered && left > 0 && left <= INPUT_GRACE_MS).then_some(Duration::from_millis(left))
}

fn now_epoch_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX))
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
        Until::Ready => "ready for a message",
    };
    Failure::Local {
        error: json!({
            "code": "wait.timeout",
            "message": format!("the terminal was not {condition} within {millis} ms"),
            "details": {
                "until": until.as_str(),
                "timeout_ms": millis.to_string(),
                "timed_out": true,
                "waited_ms": millis.to_string(),
            },
            "retryable": true,
        }),
        exit: TIMEOUT_EXIT,
    }
}
