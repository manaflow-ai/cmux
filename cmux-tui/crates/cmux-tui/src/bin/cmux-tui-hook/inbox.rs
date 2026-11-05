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
/// The second argument that runs [`wake`] (`cmux-tui-hook claude inbox-wait`).
pub(super) const WAKE_MODE: &str = "inbox-wait";

/// Whether this hook runs for the Claude process `agent` itself.
#[cfg(unix)]
fn runs_under(agent: u32) -> bool {
    // SAFETY: getppid has no preconditions and cannot fail.
    let Ok(parent) = u32::try_from(unsafe { libc::getppid() }) else { return false };
    run_by(agent, parent, &ancestor_route::parent_and_arguments)
}

/// Whether a hook whose parent process is `hook_parent` was started by Claude
/// process `agent`. Claude Code starts a hook command in a shell of its own
/// (`sh -c <command>`), and the shell either runs the helper as its child or
/// becomes it (`exec`). So the helper's parent is `agent`, or a shell whose
/// command is a cmux hook command (it carries [`HOOK_COMMAND_MARKER`]) and
/// whose parent is `agent`. Nothing else is: a Claude started inside `agent`
/// (from a tool call, through any number of shells) inherits `agent`'s
/// variables, but its hooks' shells are its children, and it is no hook
/// shell, so its hooks are never taken for `agent`'s. A process that cannot
/// be read is not `agent`'s.
#[cfg_attr(not(unix), allow(dead_code))]
fn run_by(
    agent: u32,
    hook_parent: u32,
    process: &dyn Fn(u32) -> Option<(u32, Vec<Vec<u8>>)>,
) -> bool {
    if agent <= 1 {
        return false;
    }
    if hook_parent == agent {
        return true;
    }
    let Some((grandparent, arguments)) = process(hook_parent) else { return false };
    let marker = HOOK_COMMAND_MARKER.as_bytes();
    let hook_shell = arguments
        .iter()
        .any(|argument| argument.windows(marker.len()).any(|window| window == marker));
    hook_shell && grandparent == agent
}

/// The comment every cmux hook command ends with (cmux-tui-hooks).
#[cfg_attr(not(unix), allow(dead_code))]
const HOOK_COMMAND_MARKER: &str = cmux_tui_hooks::COMMAND_MARKER;

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
        Ok(Ok(answer)) => {
            Claim::Claimed(answer["messages"].as_array().cloned().unwrap_or_default())
        }
        Ok(Err(error)) if unknown_operation(&error) => Claim::Unsupported,
        _ => Claim::Failed,
    }
}

/// A daemon older than an operation refuses the whole request envelope
/// (`resource_router::malformed_resource_response`): `validation.invalid`,
/// "invalid request envelope". A request this helper builds is otherwise
/// well formed, so that answer means the operation is unknown there.
fn unknown_operation(error: &Value) -> bool {
    error["code"] == "validation.invalid" && error["message"] == "invalid request envelope"
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
    let session = payload["session_id"].as_str().filter(|id| !id.is_empty() && id.len() <= 256);
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
                match answer["status"].as_str() {
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
    let messages = answer["messages"].as_array().cloned().unwrap_or_default();
    let ids: Vec<&str> = messages.iter().filter_map(|message| message["id"].as_str()).collect();
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

    fn env(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<OsString> + use<> {
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

    /// A process table: pid -> (parent, arguments).
    fn table(rows: &[(u32, u32, &[&str])]) -> impl Fn(u32) -> Option<(u32, Vec<Vec<u8>>)> + use<> {
        let rows: Vec<(u32, u32, Vec<Vec<u8>>)> = rows
            .iter()
            .map(|(pid, parent, argv)| {
                (*pid, *parent, argv.iter().map(|arg| arg.as_bytes().to_vec()).collect())
            })
            .collect();
        move |pid| {
            rows.iter().find(|row| row.0 == pid).map(|(_, parent, argv)| (*parent, argv.clone()))
        }
    }

    /// Review P2 (nested launch): only `agent`'s own hooks run for it. Its
    /// hook shell (marked) or the helper exec'd in its place has it as parent;
    /// a Claude started inside it inherits its pid but is no hook shell, and
    /// that Claude's hook shells are its own children.
    #[test]
    fn only_the_named_claudes_own_hooks_run_for_it() {
        const OUTER: u32 = 100;
        const NESTED: u32 = 200;
        let hook = "h=x;\"$h\" claude UserPromptSubmit||echo {};#cmux-tui-journal-hook";
        let processes = table(&[
            (OUTER, 50, &["claude"]),
            (150, OUTER, &["/bin/sh", "-c", hook]),
            (160, OUTER, &["/bin/zsh", "-c", "claude"]),
            (NESTED, OUTER, &["claude", "--resume"]),
            (210, NESTED, &["/bin/sh", "-c", hook]),
            (220, 160, &["/bin/sh", "-c", hook]),
            (230, OUTER, &["/bin/sh", "-c", "my-hook"]),
        ]);
        // The outer Claude's own hook, through its shell or exec'd in its place.
        assert!(run_by(OUTER, 150, &processes));
        assert!(run_by(OUTER, OUTER, &processes));
        // outer -> nested -> hook shell -> hook: the nested session's hook.
        assert!(!run_by(OUTER, 210, &processes));
        assert!(run_by(NESTED, 210, &processes), "the nested Claude's own hook is its own");
        // outer -> nested -> hook (the shell exec'd it): its parent is no hook shell.
        assert!(!run_by(OUTER, NESTED, &processes));
        // A Claude under a tool shell of the outer one: its hook shell's parent is not outer.
        assert!(!run_by(OUTER, 220, &processes));
        // An unmarked shell (another program's hook) and unreadable processes.
        assert!(!run_by(OUTER, 230, &processes));
        assert!(!run_by(OUTER, 999, &processes));
        assert!(!run_by(0, 0, &processes));
        assert!(!run_by(1, 1, &processes));
    }

    /// The same, on real processes: this test is the outer Claude; a child
    /// shell plays a Claude started inside it, and that shell's child (whose
    /// command carries the hook marker) plays the nested Claude's hook shell.
    #[cfg(unix)]
    #[test]
    fn a_real_nested_process_tree_does_not_run_for_the_outer_claude() {
        use std::io::BufRead as _;
        // Both shells wait on a builtin read of the piped stdin, so they keep
        // their argv and end when the test closes it: no process outlives it.
        let inner = format!("echo $$; read line; : #{HOOK_COMMAND_MARKER}");
        let mut nested = std::process::Command::new("/bin/sh")
            .args(["-c", "/bin/sh -c \"$INNER\"; :"])
            .env("INNER", &inner)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        let nested_pid = nested.id();
        let mut line = String::new();
        std::io::BufReader::new(nested.stdout.take().unwrap()).read_line(&mut line).unwrap();
        let hook_shell: u32 = line.trim().parse().unwrap();
        let read = ancestor_route::parent_and_arguments;
        let outer = std::process::id();
        let owned_outer = run_by(outer, hook_shell, &read);
        let owned_nested = run_by(nested_pid, hook_shell, &read);
        let nested_as_shell = run_by(outer, nested_pid, &read);
        drop(nested.stdin.take());
        let _ = nested.wait();
        assert!(!owned_outer, "the nested hook shell ran for the outer Claude");
        assert!(owned_nested, "the nested Claude's hook shell is its own");
        assert!(!nested_as_shell, "a nested Claude is no hook shell of the outer one");
    }

    const TERMINAL: &str = "term_0123456789abcdef0123456789abcdef";

    /// A daemon on a Unix socket that logs each request and answers it with
    /// `answer` (`None`: close without answering).
    #[cfg(unix)]
    struct FakeDaemon {
        _dir: tempfile::TempDir,
        socket: PathBuf,
        log: std::sync::Arc<std::sync::Mutex<Vec<Value>>>,
    }

    #[cfg(unix)]
    impl FakeDaemon {
        fn start(answer: impl Fn(&Value) -> Option<Value> + Send + 'static) -> Self {
            let dir = tempfile::tempdir().unwrap();
            let socket = dir.path().join("daemon.sock");
            let listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
            let log = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
            let seen = log.clone();
            std::thread::spawn(move || {
                for stream in listener.incoming() {
                    let Ok(mut stream) = stream else { return };
                    let mut line = String::new();
                    if BufReader::new(&stream).read_line(&mut line).is_err() {
                        continue;
                    }
                    let Ok(request) = serde_json::from_str::<Value>(&line) else { continue };
                    seen.lock().unwrap().push(request.clone());
                    if let Some(mut reply) = answer(&request) {
                        reply["id"] = request["id"].clone();
                        let _ = writeln!(stream, "{reply}");
                    }
                }
            });
            Self { _dir: dir, socket, log }
        }

        fn operations(&self) -> Vec<String> {
            let log = self.log.lock().unwrap();
            log.iter().map(|request| request["operation"].as_str().unwrap().to_owned()).collect()
        }

        fn requests(&self) -> Vec<Value> {
            self.log.lock().unwrap().clone()
        }
    }

    fn ok(result: Value) -> Option<Value> {
        Some(
            json!({"protocol": "cmux.protocol/2", "type": "response", "ok": true, "result": result}),
        )
    }

    fn refused(code: &str, message: &str) -> Option<Value> {
        Some(json!({
            "protocol": "cmux.protocol/2", "type": "response", "ok": false,
            "error": {"code": code, "message": message, "details": {}, "retryable": false},
        }))
    }

    fn queued_message() -> Value {
        json!({"id": "msg_1", "thread_id": "msg_1", "sender": "cli", "body": "rebase when free"})
    }

    /// Review P2: only a daemon that does not know the claim lets Claude's
    /// prompt hook list the queue; a refusal, a busy daemon or a dropped
    /// connection takes nothing, so a message a wake hook leased is not
    /// handed over beside it.
    #[cfg(unix)]
    #[test]
    fn the_prompt_hook_lists_the_queue_only_when_the_daemon_does_not_know_the_claim() {
        let old = FakeDaemon::start(|request| match request["operation"].as_str() {
            Some("agent.message.wait") => refused("validation.invalid", "invalid request envelope"),
            Some("agent.message.list") => ok(json!([queued_message()])),
            _ => ok(json!({"value": []})),
        });
        let claude = Delivery::for_event("claude", "UserPromptSubmit").unwrap();
        let mut out = Vec::new();
        deliver_to(&mut out, claude, &old.socket, Some(TERMINAL), true);
        assert_eq!(
            old.operations(),
            ["agent.message.wait", "agent.message.list", "agent.message.mark"]
        );
        assert!(String::from_utf8(out).unwrap().contains("rebase when free"));

        for failure in [
            refused("operation.failed", "agent message wait capacity exceeded"),
            refused("validation.invalid", "agent.message.wait claims for a terminal agent"),
            None,
        ] {
            let daemon = FakeDaemon::start(move |request| match request["operation"].as_str() {
                Some("agent.message.wait") => failure.clone(),
                _ => ok(json!([queued_message()])),
            });
            let mut out = Vec::new();
            deliver_to(&mut out, claude, &daemon.socket, Some(TERMINAL), true);
            assert_eq!(daemon.operations(), ["agent.message.wait"], "listed beside a lease");
            assert_eq!(String::from_utf8(out).unwrap().trim(), "{}");
        }
    }

    struct FailingWriter;

    impl Write for FailingWriter {
        fn write(&mut self, _: &[u8]) -> io::Result<usize> {
            Err(io::Error::new(io::ErrorKind::BrokenPipe, "the agent closed its end"))
        }

        fn flush(&mut self) -> io::Result<()> {
            Err(io::Error::new(io::ErrorKind::BrokenPipe, "the agent closed its end"))
        }
    }

    /// Review P2: a hook output the agent cannot have read (stdout write or
    /// flush failed) marks nothing delivered; the messages stay queued.
    #[cfg(unix)]
    #[test]
    fn a_prompt_hook_whose_output_failed_marks_nothing_delivered() {
        let daemon = FakeDaemon::start(|request| match request["operation"].as_str() {
            Some("agent.message.wait") => ok(
                json!({"status": "claimed", "lease_id": "lease_0", "messages": [queued_message()]}),
            ),
            Some("agent.message.list") => ok(json!([queued_message()])),
            _ => ok(json!({"value": []})),
        });
        for event in ["UserPromptSubmit", "Stop"] {
            let source = if event == "Stop" { "codex" } else { "claude" };
            let delivery = Delivery::for_event(source, event).unwrap();
            deliver_to(&mut FailingWriter, delivery, &daemon.socket, Some(TERMINAL), true);
        }
        let marks: Vec<Value> = daemon
            .requests()
            .into_iter()
            .filter(|request| request["operation"] == "agent.message.mark")
            .filter(|request| request["params"]["state"] == "delivered")
            .collect();
        assert!(marks.is_empty(), "{marks:?}");
    }

    /// Review P2 (interleaving): a wake hook that starts at a Stop while an
    /// earlier wake may still be handing messages over acknowledges nothing.
    /// It claims, writes the messages, marks them delivered via claude.wake
    /// and exits 2; no request ever marks a delivery acknowledged.
    #[cfg(unix)]
    #[test]
    fn a_wake_hook_started_at_stop_acknowledges_nothing() {
        let daemon = FakeDaemon::start(|request| match request["operation"].as_str() {
            Some("agent.message.wait") => ok(
                json!({"status": "claimed", "lease_id": "lease_0", "messages": [queued_message()]}),
            ),
            Some("agent.message.list") => ok(json!([queued_message()])),
            _ => ok(json!({"value": []})),
        });
        let parent = std::os::unix::process::parent_id().to_string();
        let socket = daemon.socket.to_str().unwrap().to_owned();
        let getenv = env(&[
            ("CMUX_TUI_SOCKET", socket.as_str()),
            ("CMUX_TUI_TERMINAL_ID", TERMINAL),
            (CLAUDE_PID_ENV, parent.as_str()),
        ]);
        let payload = json!({"hook_event_name": "Stop", "session_id": "s1"});
        let mut err = Vec::new();
        assert_eq!(wake_with(&getenv, &payload, &mut err), 2);
        assert!(String::from_utf8(err).unwrap().contains("rebase when free"));
        let requests = daemon.requests();
        assert_eq!(daemon.operations(), ["agent.message.wait", "agent.message.mark"]);
        assert_eq!(requests[0]["params"]["agent_session_id"], "s1");
        assert_eq!(requests[1]["params"]["state"], "delivered");
        assert_eq!(requests[1]["params"]["via"], "claude.wake");
        assert!(requests.iter().all(|request| request["params"]["state"] != "acknowledged"));
    }

    /// A wake hook whose stderr is gone (Claude exited) marks nothing and
    /// exits 0; its claim lapses and the messages are offered again.
    #[cfg(unix)]
    #[test]
    fn a_wake_hook_that_cannot_write_marks_nothing() {
        let daemon = FakeDaemon::start(|request| match request["operation"].as_str() {
            Some("agent.message.wait") => ok(
                json!({"status": "claimed", "lease_id": "lease_0", "messages": [queued_message()]}),
            ),
            _ => ok(json!({"value": []})),
        });
        let parent = std::os::unix::process::parent_id().to_string();
        let socket = daemon.socket.to_str().unwrap().to_owned();
        let getenv = env(&[
            ("CMUX_TUI_SOCKET", socket.as_str()),
            ("CMUX_TUI_TERMINAL_ID", TERMINAL),
            (CLAUDE_PID_ENV, parent.as_str()),
        ]);
        let payload = json!({"hook_event_name": "SessionStart", "session_id": "s1"});
        assert_eq!(wake_with(&getenv, &payload, &mut FailingWriter), 0);
        assert_eq!(daemon.operations(), ["agent.message.wait"]);
    }

    /// A daemon that answers `disabled` (Settings > Agents > Agent Messages
    /// is off, managed layers included) ends the wake hook: it hands nothing
    /// over and asks for nothing more.
    #[cfg(unix)]
    #[test]
    fn a_disabled_answer_ends_the_wake_hook() {
        let daemon =
            FakeDaemon::start(|_| ok(json!({"status": "disabled", "reason": "setting_off"})));
        let parent = std::os::unix::process::parent_id().to_string();
        let socket = daemon.socket.to_str().unwrap().to_owned();
        let getenv = env(&[
            ("CMUX_TUI_SOCKET", socket.as_str()),
            ("CMUX_TUI_TERMINAL_ID", TERMINAL),
            (CLAUDE_PID_ENV, parent.as_str()),
        ]);
        let payload = json!({"hook_event_name": "Stop", "session_id": "s1"});
        let mut err = Vec::new();
        assert_eq!(wake_with(&getenv, &payload, &mut err), 0);
        assert!(err.is_empty());
        assert_eq!(daemon.operations(), ["agent.message.wait"]);
    }
}
