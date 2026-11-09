//! `cmux terminal wait --any|--all <t1,t2,...> [--until idle,blocked,done]
//! [--timeout D]` (bench round 4: herdr waits on several agents at once):
//! blocks until the first listed agent (`--any`) or every listed agent
//! (`--all`) shows one of the `--until` states, then names the terminal that
//! matched, its state, and every listed agent's state.
//!
//! The states are the shared status `terminal list --agents` shows
//! (terminal_talk/roster.rs, done-until-seen included), read from the session
//! snapshot: nothing here classifies a terminal. `idle` also matches `done`
//! (a finished turn nobody has viewed is at rest too).
//!
//! Nothing polls: as `terminal <t> wait` (terminal_wait.rs), the wait holds the
//! session's `session.events` stream on a second connection, opened before
//! the first read, and reads the snapshot again after each event. A passed
//! `--timeout` exits 124 with `wait.timeout`; Ctrl-C exits 130 with
//! `wait.interrupted`; agents that ended so the wait can never hold exit 1
//! with `wait.agent_ended`.

use std::io::BufReader;
use std::time::{Duration, Instant};

use cmux_tui_core::platform::transport;
use cmux_tui_core::resource::ResourceOperation;
use serde_json::{Map, Value, json};

use super::super::resolve::{self, Failure, SocketRoute};
use super::super::terminal_talk::{roster, roster_names, send};
use super::super::{GlobalArgs, OutputMode, UsageError, wire};
use super::terminal_wait::{
    ANSWER_TIMEOUT, DEADLINE_SLACK, TIMEOUT_EXIT, answer_wait, duration, past,
};

type Reader = BufReader<Box<dyn transport::Stream>>;

/// The most terminals one wait names.
const MAX_TARGETS: usize = 64;

/// Whether the first or every listed agent must match.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Mode {
    Any,
    All,
}

impl Mode {
    fn as_str(self) -> &'static str {
        match self {
            Self::Any => "any",
            Self::All => "all",
        }
    }
}

/// One `--until` state.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Until {
    /// At rest: `idle`, or `done` (a finished turn nobody has viewed).
    Idle,
    Blocked,
    Done,
    Working,
    /// The agent's session or its terminal ended.
    Ended,
}

impl Until {
    pub(super) fn as_str(self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::Blocked => "blocked",
            Self::Done => "done",
            Self::Working => "working",
            Self::Ended => "ended",
        }
    }

    fn parse(word: &str) -> Option<Self> {
        Some(match word {
            "idle" => Self::Idle,
            "blocked" => Self::Blocked,
            "done" => Self::Done,
            "working" => Self::Working,
            "ended" => Self::Ended,
            _ => return None,
        })
    }

    /// Whether an agent whose status word is `status` shows this state.
    fn matches(self, status: &str) -> bool {
        match self {
            Self::Idle => matches!(status, "idle" | "done"),
            Self::Ended => matches!(status, "ended" | "gone"),
            other => status == other.as_str(),
        }
    }
}

/// A parsed `terminal wait --any|--all`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Request {
    pub(super) mode: Mode,
    /// Terminal, tab or agent names, as given.
    pub(super) targets: Vec<String>,
    pub(super) until: Vec<Until>,
    pub(super) timeout: Option<Duration>,
}

/// `Some(exit code)` for `terminal wait --any|--all …` (`words` follow
/// `terminal`); `None` for any other terminal command.
pub(super) fn run(global: &GlobalArgs, words: &[String]) -> Option<i32> {
    let [verb, flags @ ..] = words else { return None };
    let names_mode = |flag: &String| {
        ["--any", "--all"]
            .iter()
            .any(|mode| flag == mode || flag.strip_prefix(mode).is_some_and(|r| r.starts_with('=')))
    };
    if verb != "wait" || !flags.iter().any(names_mode) {
        return None;
    }
    Some(match parse(flags) {
        Ok(request) => wait(global, &request),
        Err(error) => {
            super::super::app::failure("usage.invalid", &format!("cmux: {error}"), global.output, 2)
        }
    })
}

fn list(value: &str) -> impl Iterator<Item = &str> {
    value.split(',').map(str::trim).filter(|item| !item.is_empty())
}

pub(super) fn parse(words: &[String]) -> Result<Request, UsageError> {
    let mut mode = None;
    let mut targets = Vec::new();
    let mut until = Vec::new();
    let mut timeout = None;
    let mut words = words.iter();
    while let Some(word) = words.next() {
        let (name, inline) = match word.split_once('=') {
            Some((name, value)) => (name, Some(value.to_owned())),
            None => (word.as_str(), None),
        };
        let mut value = || {
            inline
                .clone()
                .or_else(|| words.next().cloned())
                .filter(|value| !value.starts_with("--"))
                .ok_or_else(|| UsageError::new(format!("{name} needs a value")))
        };
        match name {
            "--any" | "--all" => {
                let given = if name == "--any" { Mode::Any } else { Mode::All };
                if mode.is_some_and(|mode| mode != given) {
                    return Err(UsageError::new("terminal wait takes --any or --all, not both"));
                }
                mode = Some(given);
                targets.extend(list(&value()?).map(str::to_owned));
            }
            "--until" => {
                for word in list(&value()?) {
                    let state = Until::parse(word).ok_or_else(|| {
                        UsageError::new(format!(
                            "--until takes idle, blocked, done, working or ended, not {word:?}"
                        ))
                    })?;
                    if !until.contains(&state) {
                        until.push(state);
                    }
                }
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
                    "terminal wait --any|--all takes a terminal list, --until and --timeout, \
                     not {other}"
                )));
            }
        }
    }
    let mode = mode.ok_or_else(|| UsageError::new("terminal wait needs --any or --all"))?;
    if targets.is_empty() {
        return Err(UsageError::new(format!(
            "--{} needs one or more terminal, tab or agent names",
            mode.as_str()
        )));
    }
    targets.dedup();
    if targets.len() > MAX_TARGETS {
        return Err(UsageError::new(format!(
            "terminal wait takes at most {MAX_TARGETS} terminals, not {}",
            targets.len()
        )));
    }
    if until.is_empty() {
        until = vec![Until::Idle, Until::Blocked, Until::Done];
    }
    Ok(Request { mode, targets, until, timeout })
}

/// One listed agent as the snapshot shows it.
#[derive(Clone, Debug, PartialEq)]
pub(super) struct Seen {
    pub(super) terminal: String,
    pub(super) name: Option<String>,
    /// The shared status word, `ended` for an ended session, `gone` for a
    /// terminal the session no longer has, `none` while no agent reported.
    pub(super) status: &'static str,
    pub(super) source: Option<String>,
    pub(super) updated_at_ms: Option<u64>,
}

impl Seen {
    fn ended(&self) -> bool {
        matches!(self.status, "ended" | "gone")
    }

    fn to_json(&self) -> Value {
        json!({
            "terminal": self.terminal,
            "name": self.name,
            "status": self.status,
            "source": self.source,
            "updated_at_ms": self.updated_at_ms.map(|ms| ms.to_string()),
        })
    }
}

/// Each terminal of `terminals` (ids) as `snapshot` shows it.
pub(super) fn observe(snapshot: &Value, terminals: &[String]) -> Vec<Seen> {
    let records = snapshot["terminals"].as_array().map(Vec::as_slice).unwrap_or_default();
    let agents = snapshot["agents"].as_array().map(Vec::as_slice).unwrap_or_default();
    let notifications = snapshot["notifications"].as_array().map(Vec::as_slice);
    let unseen = wire::unseen_terminals(notifications.unwrap_or_default());
    let facts = roster_names::facts(snapshot);
    terminals
        .iter()
        .map(|id| {
            let name = facts.get(id).and_then(|facts| facts.name()).map(str::to_owned);
            let record = records.iter().find(|record| record["id"] == id.as_str());
            let row = record.and_then(|record| {
                roster::agent_of_terminal(record, agents, unseen.contains(id.as_str()))
            });
            let status = match (record, &row) {
                (None, _) => "gone",
                (Some(record), _) if record["lifecycle"] == "exited" => "ended",
                (Some(_), Some(row)) => row.status_word(),
                (Some(_), None) => "none",
            };
            Seen {
                terminal: id.clone(),
                name,
                status,
                source: row.as_ref().map(|row| row.source.clone()),
                updated_at_ms: row.and_then(|row| row.updated_at_ms),
            }
        })
        .collect()
}

/// What one look at the listed agents says.
#[derive(Clone, Debug, PartialEq)]
pub(super) enum Outcome {
    /// The wait holds; `terminal` is the index of the agent to name (the
    /// first match for `--any`, the latest change for `--all`).
    Holds { terminal: usize },
    /// Not yet.
    Pending,
    /// Agents ended (indexes) so the wait can never hold.
    Impossible { ended: Vec<usize> },
}

/// Whether `seen` holds `request`.
pub(super) fn evaluate(request: &Request, seen: &[Seen]) -> Outcome {
    let matched = |agent: &Seen| request.until.iter().any(|until| until.matches(agent.status));
    let waits_for_end = request.until.contains(&Until::Ended);
    let ended: Vec<usize> = seen
        .iter()
        .enumerate()
        .filter(|(_, agent)| agent.ended() && !waits_for_end)
        .map(|(index, _)| index)
        .collect();
    match request.mode {
        Mode::Any => {
            if let Some(index) = seen.iter().position(matched) {
                return Outcome::Holds { terminal: index };
            }
            if !seen.is_empty() && ended.len() == seen.len() {
                return Outcome::Impossible { ended };
            }
        }
        Mode::All => {
            if !seen.is_empty() && seen.iter().all(matched) {
                let latest = seen
                    .iter()
                    .enumerate()
                    .max_by_key(|(index, agent)| (agent.updated_at_ms, std::cmp::Reverse(*index)))
                    .map_or(0, |(index, _)| index);
                return Outcome::Holds { terminal: latest };
            }
            if !ended.is_empty() {
                return Outcome::Impossible { ended };
            }
        }
    }
    Outcome::Pending
}

fn until_words(request: &Request) -> Vec<&'static str> {
    request.until.iter().map(|until| until.as_str()).collect()
}

/// The `terminal wait --any|--all` result of a wait that holds.
pub(super) fn result(request: &Request, seen: &[Seen], terminal: usize, waited: Duration) -> Value {
    let named = seen.get(terminal);
    let matched: Vec<&str> = seen
        .iter()
        .filter(|agent| request.until.iter().any(|until| until.matches(agent.status)))
        .map(|agent| agent.terminal.as_str())
        .collect();
    json!({
        "mode": request.mode.as_str(),
        "until": until_words(request),
        "terminal": named.map(|agent| agent.terminal.as_str()),
        "name": named.and_then(|agent| agent.name.as_deref()),
        "status": named.map(|agent| agent.status),
        "matched": matched,
        "agents": seen.iter().map(Seen::to_json).collect::<Vec<_>>(),
        "waited_ms": waited.as_millis().to_string(),
    })
}

fn wait(global: &GlobalArgs, request: &Request) -> i32 {
    let mut plan = super::super::agents::snapshot_plan();
    if let Err(error) = resolve::apply_global_route(global, &mut plan) {
        eprintln!("cmux: {error}");
        return 2;
    }
    let (socket, derived) = match wire::resolve_socket_or_report(global) {
        Ok(resolved) => resolved,
        Err(code) => return code,
    };
    let started = Instant::now();
    let deadline = request.timeout.and_then(|timeout| started.checked_add(timeout));
    let route = SocketRoute::new(&socket, derived, global);
    let params = plan.params.as_object().cloned().unwrap_or_default();
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
            // Tab names (agent names) as `terminal list --agents` sees them.
            super::super::tab_capabilities::negotiate(&mut reader)?;
            hold(&mut reader, &route, &params, request, deadline)
        });
    match held {
        Ok((seen, terminal)) => {
            let value = result(request, &seen, terminal, started.elapsed());
            print(global, &value);
            0
        }
        Err(failure) => failure.report(global.output),
    }
}

fn print(global: &GlobalArgs, value: &Value) {
    match global.output {
        OutputMode::Quiet => {}
        OutputMode::Json | OutputMode::JsonLines => {
            println!("{}", serde_json::to_string(value).unwrap_or_default());
        }
        OutputMode::Human => {
            let terminal = value["terminal"].as_str().unwrap_or_default();
            let label = value["name"].as_str().unwrap_or(terminal);
            println!("{label} {}", value["status"].as_str().unwrap_or_default());
        }
    }
}

/// Opens the session's event stream, then reads the snapshot until
/// `request` holds, waking on each session event.
fn hold(
    reader: &mut Reader,
    socket: &SocketRoute<'_>,
    params: &Map<String, Value>,
    request: &Request,
    deadline: Option<Instant>,
) -> Result<(Vec<Seen>, usize), Failure> {
    // Subscribe before the first read: a change between that read and the
    // subscription still wakes the wait.
    let now = Instant::now();
    let opened = now.checked_add(answer_wait(deadline)).unwrap_or(now);
    let events =
        resolve::session_events(socket, &resolve::route(params), opened).ok_or_else(|| {
            if past(deadline) {
                timed_out(request, &[])
            } else {
                Failure::Transport("cmux: the session's event stream did not open".into())
            }
        })?;
    // Ctrl-C shuts the stream down, which ends a wait without a timeout.
    wire::arm_signal_interrupt(events.get_ref().as_ref());
    let mut session = LiveSession { reader, events, params };
    watch(&mut session, request, deadline, &Instant::now)
}

/// What one blocking read of the session's event stream gave.
#[derive(Debug)]
pub(super) enum Wake {
    /// An event came: read the snapshot again.
    Event,
    /// Ctrl-C (or a shutdown signal) ended the read.
    Interrupted,
    /// The stream ended.
    Ended,
    /// The read failed or timed out, with the transport's message.
    ReadFailed(String),
    /// The stream cannot take the read timeout.
    Unwaitable,
}

/// The session a wait reads: its snapshot and its event stream (tests pass
/// a fake one).
pub(super) trait Session {
    /// The session snapshot, answered before `deadline` or failed.
    fn snapshot(&mut self, deadline: Option<Instant>) -> Result<Value, Failure>;
    /// Blocks until the next event, at most `within` (`None`: no bound).
    fn wake(&mut self, within: Option<Duration>) -> Wake;
}

struct LiveSession<'a> {
    reader: &'a mut Reader,
    events: Reader,
    params: &'a Map<String, Value>,
}

impl Session for LiveSession<'_> {
    fn snapshot(&mut self, deadline: Option<Instant>) -> Result<Value, Failure> {
        let _ = self.reader.get_mut().set_read_timeout(Some(answer_wait(deadline)));
        resolve::read(self.reader, ResourceOperation::SessionSnapshot, self.params.clone())
    }

    fn wake(&mut self, within: Option<Duration>) -> Wake {
        if self.events.get_mut().set_read_timeout(within).is_err() {
            return Wake::Unwaitable;
        }
        match wire::read_envelope(&mut self.events, false) {
            Ok(Some(_)) => Wake::Event,
            _ if crate::shutdown_requested() => Wake::Interrupted,
            Ok(None) => Wake::Ended,
            Err(error) => Wake::ReadFailed(error),
        }
    }
}

/// Whether `deadline` passed at `now` (within the slack a read timeout
/// may wake early by).
fn past_at(now: Instant, deadline: Option<Instant>) -> bool {
    deadline.is_some_and(|deadline| {
        now.checked_add(DEADLINE_SLACK).is_none_or(|slack| slack >= deadline)
    })
}

/// Reads `session` until `request` holds, it can never hold, or `deadline`
/// passes. `now` is the clock.
pub(super) fn watch<S, N>(
    session: &mut S,
    request: &Request,
    deadline: Option<Instant>,
    now: &N,
) -> Result<(Vec<Seen>, usize), Failure>
where
    S: Session + ?Sized,
    N: Fn() -> Instant + ?Sized,
{
    let mut terminals: Option<Vec<String>> = None;
    // What the last read showed, so a timeout says where each agent stood.
    let mut last: Vec<Seen> = Vec::new();
    loop {
        let snapshot = session.snapshot(deadline).map_err(|failure| {
            if past_at(now(), deadline) { timed_out(request, &last) } else { failure }
        })?;
        // The names are resolved once, so a renamed tab keeps its place.
        if terminals.is_none() {
            terminals = Some(resolve_targets(&snapshot, &request.targets)?);
        }
        let seen = observe(&snapshot, terminals.as_deref().unwrap_or_default());
        match evaluate(request, &seen) {
            Outcome::Holds { terminal } => return Ok((seen, terminal)),
            Outcome::Impossible { ended } => return Err(agents_ended(request, &seen, &ended)),
            Outcome::Pending => {}
        }
        last = seen;
        let remaining = match deadline {
            None => None,
            Some(deadline) => match deadline.checked_duration_since(now()) {
                Some(remaining) if !remaining.is_zero() => Some(remaining),
                _ => return Err(timed_out(request, &last)),
            },
        };
        match session.wake(remaining) {
            Wake::Event => {}
            Wake::Interrupted => {
                return Err(Failure::Local {
                    error: json!({
                        "code": "wait.interrupted",
                        "message": "cmux: the wait was interrupted",
                        "details": {"mode": request.mode.as_str(), "until": until_words(request)},
                        "retryable": true,
                    }),
                    exit: 130,
                });
            }
            // The read timed out at the deadline: read once more (a change
            // may have landed just before it), then time out.
            Wake::ReadFailed(_) if past_at(now(), deadline) => {}
            Wake::ReadFailed(error) => return Err(Failure::Transport(error)),
            Wake::Ended => {
                return Err(Failure::Transport("cmux: the session's event stream ended".into()));
            }
            Wake::Unwaitable => {
                return Err(Failure::Transport("cmux: cannot wait on the event stream".into()));
            }
        }
    }
}

/// The terminal ids `targets` name, in order, each once.
fn resolve_targets(snapshot: &Value, targets: &[String]) -> Result<Vec<String>, Failure> {
    let mut ids: Vec<String> = Vec::new();
    for target in targets {
        let terminal = send::find_terminal(snapshot, target).map_err(|failure| Failure::Local {
            error: failure.failure.error,
            exit: failure.exit,
        })?;
        let id = terminal["id"].as_str().unwrap_or_default().to_owned();
        if !ids.contains(&id) {
            ids.push(id);
        }
    }
    Ok(ids)
}

fn agents_ended(request: &Request, seen: &[Seen], ended: &[usize]) -> Failure {
    let terminals: Vec<&str> = ended
        .iter()
        .filter_map(|&index| seen.get(index))
        .map(|agent| agent.terminal.as_str())
        .collect();
    Failure::Local {
        error: json!({
            "code": "wait.agent_ended",
            "message": format!(
                "the wait can never hold: {} ended ({})",
                if terminals.len() == 1 { "an agent" } else { "agents" },
                terminals.join(", ")
            ),
            "details": {
                "mode": request.mode.as_str(),
                "until": until_words(request),
                "ended": terminals,
                "agents": seen.iter().map(Seen::to_json).collect::<Vec<_>>(),
            },
            "retryable": false,
        }),
        exit: 1,
    }
}

fn timed_out(request: &Request, seen: &[Seen]) -> Failure {
    let millis = request.timeout.map_or(0, |timeout| timeout.as_millis());
    Failure::Local {
        error: json!({
            "code": "wait.timeout",
            "message": format!(
                "{} of the agents showed {} within {millis} ms",
                if request.mode == Mode::Any { "none" } else { "not all" },
                until_words(request).join(", ")
            ),
            "details": {
                "mode": request.mode.as_str(),
                "until": until_words(request),
                "timeout_ms": millis.to_string(),
                "agents": seen.iter().map(Seen::to_json).collect::<Vec<_>>(),
            },
            "retryable": true,
        }),
        exit: TIMEOUT_EXIT,
    }
}

#[cfg(test)]
#[path = "agents_wait_tests.rs"]
mod tests;
