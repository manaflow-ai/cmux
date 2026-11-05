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
    let mut stdout = io::stdout().lock();
    let _ = writeln!(stdout, "{value}");
    let _ = stdout.flush();
}

pub(super) fn deliver(delivery: Delivery, socket: &Path, terminal: Option<&str>) {
    let Some(terminal) = terminal.filter(|terminal| terminal.starts_with("term_")) else {
        print_nothing(Some(delivery));
        return;
    };
    let claude = delivery == Delivery::PromptContext { via: "claude.prompt-submit" };
    if claude && !claude_owns_terminal(|name| env::var_os(name)) {
        print_nothing(Some(delivery));
        return;
    }
    let deadline = Instant::now() + DEADLINE;
    if delivery == Delivery::ContinueTurn {
        let _ = acknowledge_delivered(socket, terminal, "codex.stop", deadline);
    }
    // Claude's prompt hook claims under the daemon's lease, as its wake hook
    // does; an older daemon without the claim lists the queue instead.
    let claimed = if claude { claim_once(socket, terminal, deadline) } else { None };
    let messages = match claimed.map_or_else(|| queued(socket, terminal, deadline), Ok) {
        Ok(messages) => messages,
        Err(_) => {
            print_nothing(Some(delivery));
            return;
        }
    };
    let batch = cmux_tui_core::agent_message_prompt::batch(messages);
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
/// must not take its messages, and neither may a Claude started inside it
/// (a nested session inherits the outer one's terminal variables).
fn claude_owns_terminal(getenv: impl Fn(&str) -> Option<std::ffi::OsString>) -> bool {
    let is_one = |name: &str| getenv(name).is_some_and(|value| value == "1");
    if is_one(CLAUDE_HEADLESS_ENV) {
        return false;
    }
    // Claude without the wrapper (an installed hook only) names no process:
    // nothing can tell a nested run apart, so it keeps the old behavior.
    let Some(pid) = getenv(CLAUDE_PID_ENV) else { return true };
    pid.to_str().and_then(|pid| pid.parse::<u32>().ok()).is_some_and(runs_under)
}

/// The wrapper's environment for the Claude it starts: its process id (the
/// wrapper execs Claude, so they share it) and whether it runs headless.
pub(super) const CLAUDE_PID_ENV: &str = "CMUX_TUI_CLAUDE_PID";
pub(super) const CLAUDE_HEADLESS_ENV: &str = "CMUX_TUI_CLAUDE_HEADLESS";
/// `1` turns off the idle wake; prompt hooks still hand messages over.
pub(super) const CLAUDE_WAKE_DISABLED_ENV: &str = "CMUX_TUI_CLAUDE_WAKE_DISABLED";
/// The second argument that runs [`wake`] (`cmux-tui-hook claude inbox-wait`).
pub(super) const WAKE_MODE: &str = "inbox-wait";

/// Parent levels between a hook and its Claude: the shell Claude starts the
/// command in, and one launcher. A Claude started from a tool call of
/// another one is further away and is not taken for it.
const CLAUDE_ANCESTORS: usize = 3;

#[cfg(unix)]
fn runs_under(agent: u32) -> bool {
    // SAFETY: getppid has no preconditions and cannot fail.
    let mut pid = u32::try_from(unsafe { libc::getppid() }).ok();
    for _ in 0..CLAUDE_ANCESTORS {
        match pid {
            Some(current) if current == agent => return true,
            Some(current) if current > 1 => pid = ancestor_route::parent_of(current),
            _ => return false,
        }
    }
    false
}

#[cfg(not(unix))]
fn runs_under(_agent: u32) -> bool {
    false
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

/// One claim that does not wait (`timeout_ms` 0) and ignores the person
/// hold: the person just submitted a prompt. `None` when the daemon has no
/// claim (an older one) or did not answer.
fn claim_once(socket: &Path, terminal: &str, deadline: Instant) -> Option<Vec<Value>> {
    let params = json!({"recipient": terminal, "respect_hold": false});
    let answer = exchange(socket, "agent.message.wait", params, false, deadline).ok()?.ok()?;
    Some(answer["messages"].as_array().cloned().unwrap_or_default())
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
    let getenv = |name: &str| env::var_os(name).filter(|value| !value.is_empty());
    let text = |name: &str| getenv(name).and_then(|value| value.into_string().ok());
    if getenv(CLAUDE_WAKE_DISABLED_ENV).is_some_and(|value| value == "1")
        || getenv(CLAUDE_PID_ENV).is_none()
        || !claude_owns_terminal(getenv)
    {
        return ExitCode::SUCCESS;
    }
    let (Some(socket), Some(terminal), Some(pid)) = (
        text("CMUX_TUI_SOCKET").map(PathBuf::from),
        text("CMUX_TUI_TERMINAL_ID").filter(|terminal| terminal.starts_with("term_")),
        text(CLAUDE_PID_ENV).and_then(|pid| pid.parse::<u32>().ok()),
    ) else {
        return ExitCode::SUCCESS;
    };
    let Ok((poller, _)) = random_identifiers() else { return ExitCode::SUCCESS };
    let session = payload["session_id"].as_str().filter(|id| !id.is_empty() && id.len() <= 256);
    // A turn that ended normally saw what was delivered in it; one that died
    // on an API error (StopFailure) did not, so its messages stay delivered.
    if payload["hook_event_name"] == "Stop" {
        let _ = acknowledge_delivered(&socket, &terminal, "claude.stop", Instant::now() + DEADLINE);
    }
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
            Ok(Err(_)) => return ExitCode::SUCCESS,
            Ok(Ok(answer)) => {
                register = false;
                match answer["status"].as_str() {
                    Some("claimed") => return hand_over(&socket, &terminal, &answer),
                    Some("timeout") => {
                        unreachable_since = None;
                        backoff = BACKOFF_FIRST;
                        continue;
                    }
                    // The terminal is not there (yet): a restarted daemon
                    // brings it back; a closed one ends Claude too.
                    Some("gone") => {}
                    // Superseded, stale or unknown: another hook or nobody.
                    _ => return ExitCode::SUCCESS,
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
    ExitCode::SUCCESS
}

/// Writes a claim's messages to stderr, then marks them delivered. A write
/// that fails (Claude is gone) marks nothing: the claim lapses and the
/// messages are offered again. A lost mark leaves them queued, so they may
/// be shown twice; `delivered` says the hook handed them to Claude's
/// process, not that the model read them.
fn hand_over(socket: &Path, terminal: &str, answer: &Value) -> ExitCode {
    let messages = answer["messages"].as_array().cloned().unwrap_or_default();
    let ids: Vec<&str> = messages.iter().filter_map(|message| message["id"].as_str()).collect();
    if ids.is_empty() {
        return ExitCode::SUCCESS;
    }
    let text = cmux_tui_core::agent_message_prompt::render(&messages);
    let mut stderr = io::stderr().lock();
    if writeln!(stderr, "{text}").and_then(|()| stderr.flush()).is_err() {
        return ExitCode::SUCCESS;
    }
    drop(stderr);
    let _ = request(
        socket,
        "agent.message.mark",
        json!({"ids": ids, "recipient": terminal, "state": "delivered", "via": "claude.wake"}),
        true,
        Instant::now() + DEADLINE,
    );
    ExitCode::from(2)
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
    exchange(socket, operation, params, mutation, deadline)?
        .map_err(|error| anyhow!("{operation} failed: {}", error["message"]))
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
    if response["id"].as_str() != Some(request_id.as_str()) {
        bail!("{operation} returned a mismatched request id");
    }
    if response["ok"] != true {
        return Ok(Err(response["error"].clone()));
    }
    let result = response["result"].clone();
    Ok(Ok(if mutation { result["value"].clone() } else { result }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::OsString;

    fn env(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<OsString> {
        let pairs: Vec<(String, OsString)> =
            pairs.iter().map(|(name, value)| ((*name).to_owned(), OsString::from(value))).collect();
        move |name| pairs.iter().find(|(key, _)| key == name).map(|(_, value)| value.clone())
    }

    /// A `claude -p` run shares the terminal; it never takes the interactive
    /// session's messages.
    #[test]
    fn a_headless_claude_does_not_own_the_terminal() {
        assert!(!claude_owns_terminal(env(&[(CLAUDE_HEADLESS_ENV, "1")])));
    }

    /// A Claude the wrapper did not start keeps the old prompt-hook delivery.
    #[test]
    fn a_claude_without_the_wrappers_identity_keeps_prompt_delivery() {
        assert!(claude_owns_terminal(env(&[])));
    }

    /// A nested Claude inherits the outer one's process id; its hooks do not
    /// run under that process, so they take nothing.
    #[cfg(unix)]
    #[test]
    fn a_claude_whose_hooks_do_not_run_under_the_named_process_does_not_own_it() {
        assert!(!claude_owns_terminal(env(&[(CLAUDE_PID_ENV, "1")])));
        assert!(!claude_owns_terminal(env(&[(CLAUDE_PID_ENV, "not-a-pid")])));
        // This test's own parent is within the hook's reach of it.
        let parent = std::os::unix::process::parent_id().to_string();
        assert!(claude_owns_terminal(env(&[(CLAUDE_PID_ENV, parent.as_str())])));
    }
}
