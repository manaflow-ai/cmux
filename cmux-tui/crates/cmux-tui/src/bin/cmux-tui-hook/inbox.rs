//! Agent messages (`cmux agent message`) for the agent in this terminal,
//! handed over as the hook's output: extra context for a submitted prompt,
//! or, for codex, a reason to keep going instead of stopping. Delivery is at
//! least once: the output is written before the messages are marked
//! delivered, so a lost mark means the agent may see a message twice, never
//! that it misses one.
//!
//! The installed command for these events prints `{}` only when this helper
//! fails, so on success the helper prints exactly one JSON object itself.
//!
//! Claude also wakes for a message while it is idle (issue 36496): the wrapper's
//! `SessionStart`, `Stop` and `StopFailure` hooks run [`wake`] in the
//! background (`asyncRewake`). It blocks in the daemon's `agent.message.wait`
//! until messages are queued for this terminal and the agent is not waiting
//! on the person, writes them to stderr and exits 2: Claude Code shows that
//! text to the model as a system reminder and starts a turn if it was idle.
//! The prompt box, and any draft in it, is never touched, and nothing is
//! typed into the terminal. Claude's prompt hook claims through the same
//! daemon lease, so a prompt the person submits while a wake is out never
//! carries the same message.

use super::*;
use cmux_json::JsonSet as _;

/// Queued messages one hook asks the daemon for, oldest first.
const PAGE: u64 = 50;
const DEADLINE: Duration = Duration::from_millis(1500);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Delivery {
    /// `UserPromptSubmit`: `hookSpecificOutput.additionalContext`.
    PromptContext { via: &'static str },
    /// codex `Stop`: `{"decision":"block","reason":…}` continues the turn.
    /// Messages delivered earlier count as read once a turn ends.
    ContinueTurn,
    /// claude `SessionStart`: cmux's line under Claude Code's startup banner
    /// (`session_banner`), as `systemMessage`, which the person sees and the
    /// model does not. It carries no agent messages.
    SessionBanner,
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
            ("claude", "SessionStart") => Some(Self::SessionBanner),
            _ => None,
        }
    }

    fn via(self) -> &'static str {
        match self {
            Self::PromptContext { via } => via,
            Self::ContinueTurn => "codex.stop",
            Self::SessionBanner => "claude.session-start",
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
            (Self::SessionBanner, Some(text)) => json!({"systemMessage": text}),
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
    let _ = write_output(&mut io::stdout().lock(), value);
}

fn write_nothing(out: &mut dyn Write, delivery: Delivery) {
    let _ = write_output(out, &delivery.output(None));
}

/// One JSON line, flushed: whether the agent can have read it.
fn write_output(out: &mut dyn Write, value: &Value) -> io::Result<()> {
    writeln!(out, "{value}")?;
    out.flush()
}

pub(super) fn deliver(delivery: Delivery, socket: &Path, terminal: Option<&str>) {
    let claude = delivery == Delivery::PromptContext { via: "claude.prompt-submit" };
    let owns = !claude || claude_owns_terminal(|name| env::var_os(name));
    deliver_to(&mut io::stdout().lock(), delivery, socket, terminal, owns);
}

/// [`deliver`], writing the hook's output to `out`. `owns` is false for a
/// Claude hook that must take nothing (headless or nested).
fn deliver_to(
    out: &mut dyn Write,
    delivery: Delivery,
    socket: &Path,
    terminal: Option<&str>,
    owns: bool,
) {
    let Some(terminal) = terminal.filter(|terminal| terminal.starts_with("term_")) else {
        return write_nothing(out, delivery);
    };
    if !owns {
        return write_nothing(out, delivery);
    }
    let claude = delivery == Delivery::PromptContext { via: "claude.prompt-submit" };
    let deadline = Instant::now() + DEADLINE;
    if delivery == Delivery::ContinueTurn {
        let _ = acknowledge_delivered(socket, terminal, "codex.stop", deadline);
    }
    // Claude's prompt hook claims under the daemon's lease, as its wake hook
    // does. Only a daemon that does not know the claim (an older one) lets it
    // list the queue instead; any other failure takes nothing, so a message a
    // wake hook holds is never handed over twice. It stays queued.
    let listed = if claude {
        match claim_once(socket, terminal, deadline) {
            Claim::Claimed(messages) => Ok(messages),
            Claim::Unsupported => queued(socket, terminal, deadline),
            Claim::Failed => return write_nothing(out, delivery),
        }
    } else {
        queued(socket, terminal, deadline)
    };
    let Ok(messages) = listed else { return write_nothing(out, delivery) };
    let batch = cmux_tui_core::agent_message_prompt::batch(messages);
    if batch.is_empty() {
        return write_nothing(out, delivery);
    }
    let text = cmux_tui_core::agent_message_prompt::render(&batch);
    // Marked only once the agent can have read it; an output that failed
    // leaves the messages queued (a claim's lease lapses and offers them again).
    if write_output(out, &delivery.output(Some(&text))).is_err() {
        return;
    }
    let ids: Vec<&str> = batch.iter().filter_map(|message| message["id"].as_str()).collect();
    let _ = request(
        socket,
        "agent.message.mark",
        json!({"ids": ids, "recipient": terminal, "state": "delivered", "via": delivery.via()}),
        true,
        deadline,
    );
}

/// claude `SessionStart` in a cmux terminal: the startup line for how this
/// session compacts (`session_banner`), or the empty object.
pub(super) fn session_banner(terminal: Option<&str>, source: &str) {
    let line = terminal
        .filter(|terminal| terminal.starts_with("term_"))
        .and_then(|_| session_banner::message(session_banner::from_environment(), source));
    print_output(&Delivery::SessionBanner.output(line));
}

/// Whether a Claude hook runs for the interactive Claude the wrapper started
/// in this terminal. Its `claude -p` runs (headless) share the terminal and
/// must not take its messages, and neither may a Claude started inside it (a
/// tool call, a second install, a nested wrapper): it inherits the terminal's
/// variables and `CMUX_TUI_CLAUDE_PID`, but only the hooks of the wrapper's
/// own launch settings name that launch (`CMUX_TUI_HOOK_LAUNCH`,
/// cmux-tui-hooks message_hooks.rs `add_claude_launch_hooks`). A hook that
/// names no launch, or another one, takes nothing: its messages stay queued.
fn claude_owns_terminal(getenv: impl Fn(&str) -> Option<std::ffi::OsString>) -> bool {
    let is_one = |name: &str| getenv(name).is_some_and(|value| value == "1");
    if is_one(CLAUDE_HEADLESS_ENV) {
        return false;
    }
    // Claude without the wrapper (an installed hook only) names no launch:
    // nothing can tell a nested run apart, so it keeps the old behavior.
    let Some(launch) = getenv(CLAUDE_PID_ENV) else { return true };
    getenv(LAUNCH_ENV).is_some_and(|named| named == launch)
}

/// The wrapper's environment for the Claude it starts: its process id (the
/// wrapper execs Claude, so they share it) and whether it runs headless.
pub(super) const CLAUDE_PID_ENV: &str = "CMUX_TUI_CLAUDE_PID";
pub(super) const CLAUDE_HEADLESS_ENV: &str = "CMUX_TUI_CLAUDE_HEADLESS";
/// The launch a hook command names (cmux-tui-hooks message_hooks.rs).
const LAUNCH_ENV: &str = cmux_tui_hooks::message_hooks::LAUNCH_ENV;
/// The second argument that runs [`wake`] (`cmux-tui-hook claude inbox-wait`).
pub(super) const WAKE_MODE: &str = "inbox-wait";
/// The second argument that runs [`drain`] (`cmux-tui-hook claude inbox-drain`).
pub(super) const DRAIN_MODE: &str = "inbox-drain";

/// Claude's prompt hook of the wrapper's launch: the queued messages as the
/// submitted prompt's context, or the empty object. It reports nothing to
/// the journal (the shared prompt hook does) and never exits 2, which would
/// erase the person's prompt.
pub(super) fn drain() {
    let getenv = |name: &str| env::var_os(name).filter(|value| !value.is_empty());
    let owns = claude_owns_terminal(getenv);
    let terminal = getenv("CMUX_TUI_TERMINAL_ID").and_then(|value| value.into_string().ok());
    let delivery = Delivery::PromptContext { via: "claude.prompt-submit" };
    let mut out = io::stdout().lock();
    match getenv("CMUX_TUI_SOCKET").map(PathBuf::from) {
        Some(socket) => deliver_to(&mut out, delivery, &socket, terminal.as_deref(), owns),
        None => write_nothing(&mut out, delivery),
    }
}

#[cfg(unix)]
fn alive(pid: u32) -> bool {
    let Ok(pid) = libc::pid_t::try_from(pid) else { return false };
    // SAFETY: signal 0 only checks that the process exists.
    pid > 1
        && (unsafe { libc::kill(pid, 0) } == 0
            || io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH))
}

#[cfg(not(unix))]
fn alive(_pid: u32) -> bool {
    false
}

/// What a one-shot claim got.
#[derive(Debug, PartialEq)]
enum Claim {
    Claimed(Vec<Value>),
    /// The daemon does not know `agent.message.wait` (an older daemon).
    Unsupported,
    /// No answer, a refusal or a busy daemon: nothing is known to be free.
    Failed,
}

/// One claim that does not wait (`timeout_ms` 0) and ignores the person
/// hold: the person just submitted a prompt.
fn claim_once(socket: &Path, terminal: &str, deadline: Instant) -> Claim {
    let params = json!({"recipient": terminal, "respect_hold": false});
    match exchange(socket, "agent.message.wait", params, false, deadline) {
        Ok(Ok(answer)) => match answer.get("status").and_then(Value::as_str) {
            // A claim must carry its messages; one that does not holds a
            // lease on nothing it named, so nothing is taken and they stay queued.
            Some("claimed") => match claimed_messages(&answer) {
                Some(messages) => Claim::Claimed(messages),
                None => Claim::Failed,
            },
            // Nothing to hand over now (`timeout`, `stale`, ...).
            Some(_) => Claim::Claimed(Vec::new()),
            // No status: a malformed answer, not an empty queue.
            None => Claim::Failed,
        },
        Ok(Err(error)) if unknown_operation(&error) => Claim::Unsupported,
        _ => Claim::Failed,
    }
}

/// A `claimed` answer's messages; `None` when the answer does not carry them.
fn claimed_messages(answer: &Value) -> Option<Vec<Value>> {
    answer.get("messages").and_then(Value::as_array).cloned()
}

/// A daemon older than an operation refuses the whole request envelope
/// (`resource_router::malformed_resource_response`): `validation.invalid`,
/// "invalid request envelope". A request this helper builds is otherwise
/// well formed, so that answer means the operation is unknown there.
fn unknown_operation(error: &Value) -> bool {
    let field = |name: &str| error.get(name).and_then(Value::as_str);
    field("code") == Some("validation.invalid")
        && field("message") == Some("invalid request envelope")
}

/// How long one daemon wait blocks before the hook asks again (below the
/// daemon's 15-minute bound).
const WAIT: Duration = Duration::from_secs(10 * 60);
/// A wake hook ends after this long; the agent's next stop starts another.
const WAKE_LIFETIME: Duration = Duration::from_secs(24 * 60 * 60);
/// How long the hook keeps trying while the daemon does not answer (it may
/// be restarting).
const UNREACHABLE_BUDGET: Duration = Duration::from_secs(10 * 60);
const BACKOFF_FIRST: Duration = Duration::from_secs(1);
const BACKOFF_MAX: Duration = Duration::from_secs(30);

/// Claude's `asyncRewake` hook. Exits 2 after it wrote claimed messages to
/// stderr, which wakes Claude with them; 0 when there is nothing to do (no
/// wrapper identity, a headless or nested run, wake turned off, the agent
/// gone, superseded by a newer wake hook, or the daemon unreachable for
/// [`UNREACHABLE_BUDGET`]).
pub(super) fn wake(payload: &Value) -> ExitCode {
    let getenv = |name: &str| env::var_os(name);
    ExitCode::from(wake_with(&getenv, payload, &mut io::stderr()))
}

/// [`wake`] with its environment and its stderr given; the exit status.
fn wake_with(
    getenv: &dyn Fn(&str) -> Option<std::ffi::OsString>,
    payload: &Value,
    err: &mut dyn Write,
) -> u8 {
    const NOTHING: u8 = 0;
    let getenv = |name: &str| getenv(name).filter(|value| !value.is_empty());
    let text = |name: &str| getenv(name).and_then(|value| value.into_string().ok());
    // Settings > Agents > Agent Messages is the daemon's to apply (its
    // effective value, managed layers included): a wait answers `disabled`.
    if getenv(CLAUDE_PID_ENV).is_none() || !claude_owns_terminal(getenv) {
        return NOTHING;
    }
    let (Some(socket), Some(terminal), Some(pid)) = (
        text("CMUX_TUI_SOCKET").map(PathBuf::from),
        text("CMUX_TUI_TERMINAL_ID").filter(|terminal| terminal.starts_with("term_")),
        text(CLAUDE_PID_ENV).and_then(|pid| pid.parse::<u32>().ok()),
    ) else {
        return NOTHING;
    };
    let Ok((poller, _)) = random_identifiers() else { return NOTHING };
    let session = payload
        .get("session_id")
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty() && id.len() <= 256);
    // No acknowledgement at Stop: an earlier wake hook may still hand a
    // message over after this Stop and before any listing of delivered
    // messages, and nothing tells which turn saw it. A wake's messages stay
    // `delivered` (handed to Claude's process), never claimed as read.
    let started = Instant::now();
    let mut register = true;
    let mut unreachable_since: Option<Instant> = None;
    let mut backoff = BACKOFF_FIRST;
    while alive(pid) && started.elapsed() < WAKE_LIFETIME {
        let mut params = json!({
            "recipient": terminal,
            "poller": poller,
            "register": register,
            "agent_pid": pid,
            "timeout_ms": WAIT.as_millis().to_string(),
        });
        if let Some(session) = session {
            params.set("agent_session_id", json!(session));
        }
        let deadline = Instant::now() + WAIT + Duration::from_secs(30);
        match exchange(&socket, "agent.message.wait", params, false, deadline) {
            // The daemon refused the wait (an older daemon has none).
            Ok(Err(_)) => return NOTHING,
            Ok(Ok(answer)) => {
                register = false;
                match answer.get("status").and_then(Value::as_str) {
                    Some("claimed") => return hand_over(&socket, &terminal, &answer, err),
                    Some("timeout") => {
                        unreachable_since = None;
                        backoff = BACKOFF_FIRST;
                        continue;
                    }
                    // The terminal is not there (yet): a restarted daemon
                    // brings it back; a closed one ends Claude too.
                    Some("gone") => {}
                    // Superseded, stale, disabled (the setting is off) or
                    // unknown: another hook or nobody. A wake that ended
                    // re-arms at Claude's next start or stop.
                    _ => return NOTHING,
                }
            }
            Err(_) => {}
        }
        let since = *unreachable_since.get_or_insert_with(Instant::now);
        if since.elapsed() >= UNREACHABLE_BUDGET {
            break;
        }
        // Only while the daemon does not answer; an answered wait blocks.
        std::thread::sleep(backoff);
        backoff = (backoff * 2).min(BACKOFF_MAX);
    }
    NOTHING
}

/// Writes a claim's messages to stderr, then marks them delivered. A write
/// that fails (Claude is gone) marks nothing: the claim lapses and the
/// messages are offered again. A lost mark leaves them queued, so they may
/// be shown twice; `delivered` says the hook handed them to Claude's
/// process, not that the model read them.
fn hand_over(socket: &Path, terminal: &str, answer: &Value, err: &mut dyn Write) -> u8 {
    let messages = claimed_messages(answer).unwrap_or_default();
    let ids: Vec<&str> =
        messages.iter().filter_map(|message| message.get("id").and_then(Value::as_str)).collect();
    if ids.is_empty() {
        return 0;
    }
    let text = cmux_tui_core::agent_message_prompt::render(&messages);
    if writeln!(err, "{text}").and_then(|()| err.flush()).is_err() {
        return 0;
    }
    let _ = request(
        socket,
        "agent.message.mark",
        json!({"ids": ids, "recipient": terminal, "state": "delivered", "via": "claude.wake"}),
        true,
        Instant::now() + DEADLINE,
    );
    2
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

/// Marks the terminal's delivered messages acknowledged: the turn they were
/// handed over in has ended. It does not prove the model acted on them.
fn acknowledge_delivered(
    socket: &Path,
    terminal: &str,
    via: &str,
    deadline: Instant,
) -> anyhow::Result<()> {
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
            json!({"ids": ids, "recipient": terminal, "state": "acknowledged", "via": via}),
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
    params: Value,
    mutation: bool,
    deadline: Instant,
) -> anyhow::Result<Value> {
    exchange(socket, operation, params, mutation, deadline)?.map_err(|error| {
        let message = error.get("message").and_then(Value::as_str).unwrap_or("no message");
        anyhow!("{operation} failed: {message}")
    })
}

/// [`request`], with the daemon's refusal (its `error` object) apart from a
/// transport failure.
fn exchange(
    socket: &Path,
    operation: &str,
    mut params: Value,
    mutation: bool,
    deadline: Instant,
) -> anyhow::Result<Result<Value, Value>> {
    let (request_id, idempotency_key) = random_identifiers()?;
    params.set("machine", json!("current"));
    params.set("session", json!("current"));
    let mut request = json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "id": request_id,
        "operation": operation,
        "params": params,
    });
    if mutation {
        request.set("idempotency_key", Value::String(idempotency_key));
    }
    let mut encoded = serde_json::to_vec(&request)?;
    encoded.push(b'\n');
    let attempt = || -> Result<Vec<u8>, AppendAttemptError> {
        let mut stream = connect_before(socket, deadline)?;
        // Bound the read before writing: read_before
        // only shrinks this bound, since macOS refuses the option once the
        // daemon has answered and closed.
        stream
            .set_read_timeout(Some(remaining_before(deadline)?))
            .map_err(|error| AppendAttemptError::Retryable(error.into()))?;
        write_before(&mut *stream, &encoded, deadline)?;
        read_before(stream, deadline)
    };
    let response = attempt().map_err(|error| match error {
        AppendAttemptError::Retryable(error) | AppendAttemptError::Fatal(error) => error,
    })?;
    let response: Value = serde_json::from_slice(&response)?;
    if let Some(busy) = journal_append::busy_line(&response) {
        bail!("{operation} was refused: {busy}");
    }
    if response.get("id").and_then(Value::as_str) != Some(request_id.as_str()) {
        bail!("{operation} returned a mismatched request id");
    }
    // A malformed response is a failure of the exchange, never a refusal or
    // a result: a caller must not read a missing field as an empty answer.
    match response.get("ok").and_then(Value::as_bool) {
        Some(true) => {}
        Some(false) => {
            let error = response.get("error").filter(|error| error.is_object()).cloned();
            return match error {
                Some(error) => Ok(Err(error)),
                None => bail!("{operation} was refused without an error object"),
            };
        }
        None => bail!("{operation} answered without a boolean ok"),
    }
    let Some(result) = response.get("result") else {
        bail!("{operation} answered ok without a result");
    };
    if !mutation {
        return Ok(Ok(result.clone()));
    }
    match result.get("value") {
        Some(value) => Ok(Ok(value.clone())),
        None => bail!("{operation} answered a mutation without its value"),
    }
}

#[cfg(test)]
#[path = "inbox_tests.rs"]
mod tests;
