//! `cmux terminal <t> send --text <msg> [--wait idle|prompt|none]
//! [--timeout 5m]`: type a message into a terminal (an agent's composer or a
//! shell), press Enter, wait until the terminal settles, and answer what it
//! printed after the message.
//!
//! - Typing: one bracketed paste when the terminal has paste mode on
//!   (reply.rs), then Enter (`\r`) after [`SendRequest::enter_delay`], so the
//!   harness has taken the paste before it submits.
//! - `idle`: no fresh agent record (hooks, plugin) or OSC 7501 status says
//!   `working`, no OSC 9;4 progress runs, no shell command runs, and the
//!   screen has not changed for [`SendRequest::settle`]. Agent TUIs animate
//!   a spinner or a timer while they work, so a still screen is the
//!   harness-independent half of the signal; the records cover an agent
//!   that thinks with a still screen. A record older than the send cannot
//!   hold the wait (a harness killed mid-turn leaves `working` behind).
//!   An agent that stops on a dialog ends the wait as `blocked`.
//! - `prompt`: the shell shows its prompt again (OSC 133) and the screen
//!   is still, or at once when the shell reported the command finished
//!   (OSC 133 `D`) and drew its prompt. The receipt's `exit_status` is that
//!   command's status (`terminal-exit-status-v1`); it is absent when the
//!   shell reported none (no shell integration), never guessed.
//! - `pattern`: the wait also ends as soon as output printed after the
//!   message's echo matches a regex (the echo itself and older output never
//!   match), and when the command finishes without a match.
//! - The output is the screen after the message's echo; without the echo,
//!   the output after what the screen showed before the send (`idle`).
//! - `reply` (W5-Q) is the agent's own last message, whole, when the wait
//!   ended idle and the daemon kept a reply after the send (a Stop hook's
//!   `last_reply_text` on the one-terminal `agent.list`; `reply_source`
//!   `hook`); else the output (`reply_source` `screen`). A wait that ended
//!   `blocked` has no reply (`reply` and `reply_source` null, W6-C): it has
//!   `dialog` (`kind`, `msg`, `options` with their `keys`, `deny_keys`;
//!   agent_start/dialog_options.rs) and a localized `reason`, and the CLI
//!   exits 4, as a blocked `agent start`.
//! - Reads join soft-wrapped rows into the lines the program printed
//!   (`terminal-read-unwrap-v1`) when the daemon can; an older daemon gets
//!   the plain row reads.
//! - A terminal whose agent waits on a dialog is refused without `force`:
//!   the typed text would answer the dialog. The refusal exits 4 and its
//!   details carry the same `dialog`.
//! - `idle` checks that Enter submitted the message (W5-R, bench round 4
//!   A6), and fails with `send.not_submitted` instead of an empty reply:
//!   - `no_agent_report`: the terminal's agent reports through hooks (the
//!     daemon keeps its harness session id on the terminal), and it wrote
//!     no record within [`SendRequest::stall`] after Enter: its prompt
//!     submit hook did not run, so no turn started (herdr's
//!     `agent_prompt_stalled`). A message that starts with `/` is a local
//!     command of the harness, which runs no hook, and is exempt.
//!   - `input_box`: the screen is still, the agent reported nothing since
//!     Enter (a screen-detection record is no report) and its input box
//!     still holds the message.

use std::cell::Cell;
use std::time::{Duration, Instant};

use base64::Engine as _;
use regex::Regex;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::super::Surface;
use super::super::agent_start::dialog_options;
use super::super::agent_start::readiness::AGENT_QUESTION;
use super::super::agent_start::{BLOCKED_EXIT, Clock};
use super::super::command::{self, CommandPlan, RequestPlan};
use super::super::mcp::{Backend, CallFailure, FailureKind};
use super::reply::{self, Reply};
use super::roster::{self, AgentState};
use cmux_json::JsonSet as _;

pub(in crate::cli) const DEFAULT_TIMEOUT: Duration = Duration::from_secs(300);
pub(in crate::cli) const DEFAULT_SETTLE: Duration = Duration::from_secs(3);
const DEFAULT_ENTER_DELAY: Duration = Duration::from_millis(300);
/// How long a hook agent may take to report a submitted prompt. Measured on
/// `sr2 claude` under load 150 (W5-R real build): 116-897 ms from Enter to
/// the `working` hook record. A false stall makes a caller send the prompt
/// twice, so the limit is ten times the slowest seen, not herdr's 5 s.
pub(in crate::cli) const DEFAULT_STALL: Duration = Duration::from_secs(10);
const DEFAULT_POLL: Duration = Duration::from_millis(250);
/// History rows one page reads while the message's echo is not found.
const HISTORY_PAGE_ROWS: u32 = 200;
/// History pages at most read for one reply.
const HISTORY_PAGES: usize = 10;
/// Logical lines the first unwrapped reply read takes; it doubles up to
/// [`REPLY_LINES_MAX`] while the echo is not found.
const REPLY_LINES: u32 = 400;
/// The most logical lines an unwrapped reply reads, as many as the history
/// pages of a row read hold.
const REPLY_LINES_MAX: u32 = 2_000;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::cli) enum Wait {
    Idle,
    Prompt,
    None,
}

impl Wait {
    pub(in crate::cli) fn parse(text: &str) -> Option<Self> {
        Some(match text {
            "idle" => Self::Idle,
            "prompt" => Self::Prompt,
            "none" => Self::None,
            _ => return None,
        })
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::Prompt => "prompt",
            Self::None => "none",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub(in crate::cli) struct SendRequest {
    pub target: String,
    pub text: String,
    pub wait: Wait,
    pub timeout: Duration,
    pub settle: Duration,
    pub force: bool,
    /// Stable identity for retrying the whole paste-and-Enter send.
    pub idempotency_key: Option<String>,
    pub enter_delay: Duration,
    pub poll: Duration,
    /// How long a hook agent may stay silent after Enter ([`DEFAULT_STALL`]).
    pub stall: Duration,
    /// End the wait once output after the message's echo matches this regex.
    pub pattern: Option<String>,
    /// The CLI exits with the command's `exit_status` (`--exit-with-status`,
    /// `terminal <t> run`).
    pub exit_with_status: bool,
}

impl SendRequest {
    pub(in crate::cli) fn new(target: String, text: String) -> Self {
        Self {
            target,
            text,
            wait: Wait::Idle,
            timeout: DEFAULT_TIMEOUT,
            settle: DEFAULT_SETTLE,
            force: false,
            idempotency_key: None,
            enter_delay: DEFAULT_ENTER_DELAY,
            poll: DEFAULT_POLL,
            stall: DEFAULT_STALL,
            pattern: None,
            exit_with_status: false,
        }
    }
}

/// The one daemon call a send makes: a unary resource request. Every MCP
/// [`Backend`] is one; tests fake it.
pub(in crate::cli) trait Daemon {
    fn request(&self, session: Option<&str>, plan: RequestPlan) -> Result<Value, CallFailure>;
}

impl<B: Backend> Daemon for B {
    fn request(&self, session: Option<&str>, plan: RequestPlan) -> Result<Value, CallFailure> {
        self.resource(session, plan, &[])
    }
}

/// A failed send, and the exit code the CLI gives it.
#[derive(Debug)]
pub(in crate::cli) struct SendFailure {
    pub failure: CallFailure,
    pub exit: i32,
}

impl SendFailure {
    fn local(code: &str, message: impl Into<String>, details: Value, exit: i32) -> Self {
        let error = json!({
            "code": code,
            "message": message.into(),
            "details": details,
            "retryable": false,
        });
        Self {
            failure: CallFailure { kind: FailureKind::Rejected, error, idempotency_key: None },
            exit,
        }
    }
}

impl From<CallFailure> for SendFailure {
    fn from(failure: CallFailure) -> Self {
        Self { failure, exit: 1 }
    }
}

/// A daemon request from CLI words with plain ids (no name lookup).
fn plan(words: &[&str]) -> Result<RequestPlan, SendFailure> {
    let words: Vec<String> = words.iter().map(|word| (*word).to_owned()).collect();
    match command::parse(&words, Surface::CmuxTui) {
        Ok(CommandPlan::Protocol(plan)) => Ok(*plan),
        Ok(_) => Err(SendFailure::local("usage.invalid", "not a daemon request", json!({}), 2)),
        Err(error) => Err(SendFailure::local("usage.invalid", error.0, json!({}), 2)),
    }
}

fn mutation(words: &[&str], key: String) -> Result<RequestPlan, SendFailure> {
    let mut plan = plan(words)?;
    plan.idempotency_key = Some(key);
    Ok(plan)
}

/// Both terminal writes derive stable, distinct daemon keys from one caller
/// key and the resolved terminal. A lost reply can then replay the original
/// paste or Enter without repeating that input on the terminal.
fn stage_key(send_id: &str, terminal: &str, stage: &str) -> String {
    let mut hash = Sha256::new();
    for part in ["cmux.terminal.send.v1", send_id, terminal, stage] {
        hash.update(part.as_bytes());
        hash.update([0]);
    }
    format!("terminal-send-{:x}", hash.finalize())
}

/// The daemon's write key is an implementation detail. Return the caller's
/// identity and the uncertain phase, so the *entire send* can be retried.
fn stage_failure(
    mut failure: SendFailure,
    send_id: &str,
    terminal: &str,
    phase: &str,
) -> SendFailure {
    if !failure.failure.error.get("details").is_some_and(Value::is_object) {
        failure.failure.error.set("details", json!({}));
    }
    failure.failure.error.set_path(&["details", "send_id"], json!(send_id));
    failure.failure.error.set_path(&["details", "phase"], json!(phase));
    failure.failure.error.set_path(&["details", "terminal"], json!(terminal));
    if failure.failure.kind == FailureKind::InProgress {
        let original = failure
            .failure
            .error
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("terminal write acknowledgement lost")
            .to_owned();
        failure.failure.error.set(
            "message",
            json!(format!(
                "{original}; {phase} may have applied in {terminal}; retry that exact terminal id with --idempotency-key {send_id}"
            )),
        );
        failure.failure.error.set("retryable", json!(true));
    }
    failure.failure.idempotency_key = Some(send_id.to_owned());
    failure
}

/// The daemon's session snapshot (`session.snapshot`).
pub(in crate::cli) fn snapshot<B: Daemon + ?Sized>(
    backend: &B,
    session: Option<&str>,
) -> Result<Value, CallFailure> {
    backend.request(session, super::super::agents::snapshot_plan())
}

/// The terminal record `target` names: a `term_` id or unique prefix, a
/// `tab_` id it shows in, `current` (the caller's terminal), an exact title,
/// or (when no title matches) an agent name or unique tab name
/// (agent_names.rs).
pub(in crate::cli) fn find_terminal<'a>(
    snapshot: &'a Value,
    target: &str,
) -> Result<&'a Value, SendFailure> {
    let terminals = snapshot["terminals"].as_array().map(Vec::as_slice).unwrap_or_default();
    let caller = std::env::var("CMUX_TUI_TERMINAL_ID").ok();
    let target = match (target, caller.as_deref()) {
        ("current", Some(caller)) => caller,
        _ => target.strip_prefix("name:").unwrap_or(target),
    };
    let exact = terminals.iter().find(|terminal| {
        terminal["id"] == target
            || terminal["tab_id"] == target
            || terminal["tab_ids"].as_array().is_some_and(|tabs| tabs.iter().any(|t| t == target))
    });
    if let Some(found) = exact {
        return Ok(found);
    }
    let matches: Vec<&Value> = if target.starts_with("term_") {
        terminals
            .iter()
            .filter(|terminal| terminal["id"].as_str().is_some_and(|id| id.starts_with(target)))
            .collect()
    } else {
        terminals.iter().filter(|terminal| terminal["title"] == target).collect()
    };
    // An agent name (or a unique tab name) only where no title matches, so a
    // title that selected a terminal before still selects it.
    if matches.is_empty() && !target.starts_with("term_") {
        use super::super::agent_names::{Found, resolve};
        match resolve(snapshot, target) {
            Found::One(place) => {
                if let Some(found) =
                    terminals.iter().find(|terminal| terminal["id"] == place.terminal)
                {
                    return Ok(found);
                }
            }
            Found::Ambiguous(tabs) => {
                return Err(SendFailure::local(
                    "selector.ambiguous",
                    format!("{} tabs are named {target:?}; name one by its id", tabs.len()),
                    json!({"target": target, "candidates": tabs}),
                    1,
                ));
            }
            Found::Missing => {}
        }
    }
    match matches.as_slice() {
        [one] => Ok(one),
        [] => Err(SendFailure::local(
            "selector.not_found",
            format!("no terminal is {target:?}"),
            json!({"target": target}),
            1,
        )),
        many => Err(SendFailure::local(
            "selector.ambiguous",
            format!("{} terminals match {target:?}; name one by its term_ id", many.len()),
            json!({"target": target, "terminals": many.iter().map(|t| &t["id"]).collect::<Vec<_>>()}),
            1,
        )),
    }
}

/// One look at the terminal while the wait runs.
#[derive(Clone, Debug, Default, PartialEq)]
pub(in crate::cli) struct Sample {
    /// The screen's revision, or its text when the revision is absent.
    pub screen: String,
    /// A fresh agent record or a program status says `working`, progress
    /// runs, or a shell command runs.
    pub busy: bool,
    /// A fresh agent record says the agent waits on a dialog.
    pub waiting_for_input: bool,
    /// The shell shows its prompt (OSC 133).
    pub prompt: bool,
    /// The terminal exited.
    pub exited: bool,
    /// The shell finished a command after the send (a new OSC 133 `D`, or a
    /// prompt that ended it).
    pub finished: bool,
    /// The agent itself (hooks, socket) wrote a record after the send.
    pub agent_reported: bool,
}

/// The wait's verdict on the samples so far.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::cli) enum Verdict {
    Pending,
    Done(AgentState),
    Exited,
    /// A hook agent reported nothing within the stall limit after Enter.
    Stalled,
}

/// The wait after Enter: [`Settle::observe`] each sample with its time.
#[derive(Debug)]
pub(in crate::cli) struct Settle {
    wait: Wait,
    settle: Duration,
    sent_at: Instant,
    last_screen: Option<String>,
    changed_at: Instant,
    /// The stall limit, for an agent that reports every prompt.
    stall: Option<Duration>,
    /// The agent reported since the send.
    reported: bool,
}

impl Settle {
    pub(in crate::cli) fn new(wait: Wait, settle: Duration, sent_at: Instant) -> Self {
        Self {
            wait,
            settle,
            sent_at,
            last_screen: None,
            changed_at: sent_at,
            stall: None,
            reported: false,
        }
    }

    /// The wait of a send to an agent that reports every prompt it takes:
    /// [`Verdict::Stalled`] when no report came within `stall`, and never
    /// idle before a report came.
    pub(in crate::cli) fn expecting_report(self, stall: Duration) -> Self {
        Self { stall: Some(stall), ..self }
    }

    /// Whether the agent reported since the send.
    pub(in crate::cli) fn reported(&self) -> bool {
        self.reported
    }

    /// The verdict after `sample`, taken at `now` (the caller's clock).
    pub(in crate::cli) fn observe(&mut self, sample: &Sample, now: Instant) -> Verdict {
        self.reported |= sample.agent_reported;
        let verdict = self.observe_screen(sample, now);
        let Some(stall) = self.stall.filter(|_| !self.reported) else { return verdict };
        match verdict {
            Verdict::Done(AgentState::Idle) | Verdict::Pending
                if now.saturating_duration_since(self.sent_at) >= stall =>
            {
                Verdict::Stalled
            }
            // Before the limit an idle screen is no turn's end: the agent has
            // not reported the prompt yet.
            Verdict::Done(AgentState::Idle) => Verdict::Pending,
            verdict => verdict,
        }
    }

    fn observe_screen(&mut self, sample: &Sample, now: Instant) -> Verdict {
        if self.last_screen.as_deref() != Some(sample.screen.as_str()) {
            if self.last_screen.is_some() {
                self.changed_at = now;
            }
            self.last_screen = Some(sample.screen.clone());
        }
        if sample.exited {
            return Verdict::Exited;
        }
        // The shell said the command ended and drew its prompt: nothing
        // more comes, so the still-screen wait is not needed.
        if self.wait == Wait::Prompt && sample.finished && sample.prompt {
            return Verdict::Done(AgentState::Idle);
        }
        let still = now.saturating_duration_since(self.changed_at) >= self.settle
            && now.saturating_duration_since(self.sent_at) >= self.settle;
        if !still {
            return Verdict::Pending;
        }
        match self.wait {
            Wait::None => Verdict::Done(AgentState::Idle),
            Wait::Prompt if sample.prompt => Verdict::Done(AgentState::Idle),
            Wait::Prompt => Verdict::Pending,
            Wait::Idle if sample.waiting_for_input => Verdict::Done(AgentState::Blocked),
            Wait::Idle if sample.busy => Verdict::Pending,
            Wait::Idle => Verdict::Done(AgentState::Idle),
        }
    }
}

/// A [`Sample`] from the terminal record, its agent records and its
/// screen. Agent records older than `sent_ms` neither hold nor end the wait.
pub(in crate::cli) fn sample(
    terminal: &Value,
    agents: &[Value],
    screen: &Value,
    sent_ms: u64,
) -> Sample {
    let extra = &terminal["extra"];
    let fresh = |record: &Value| {
        let updated = record["updated_at_ms"]
            .as_u64()
            .or_else(|| record["updated_at_ms"].as_str().and_then(|text| text.parse().ok()));
        updated.is_some_and(|updated| updated >= sent_ms)
    };
    let agent_reported = agents
        .iter()
        .filter(|agent| agent["terminal_id"] == terminal["id"])
        .any(|record| roster::reported_by_agent(record) && fresh(record));
    let states: Vec<AgentState> = agents
        .iter()
        .filter(|agent| agent["terminal_id"] == terminal["id"])
        .chain(extra["program_status"].as_array().into_iter().flatten())
        .filter(|record| fresh(record))
        .filter_map(|record| record["state"].as_str().and_then(AgentState::from_record))
        .collect();
    let command = extra["activity"]["state"] == "running";
    let progress = matches!(extra["progress"]["state"].as_str(), Some("normal" | "indeterminate"));
    Sample {
        screen: match &screen["revision"] {
            Value::Null => screen["text"].as_str().unwrap_or_default().to_owned(),
            revision => revision.to_string(),
        },
        busy: command || progress || states.contains(&AgentState::Working),
        waiting_for_input: states.contains(&AgentState::Blocked),
        prompt: extra["prompt"].is_object(),
        exited: terminal["lifecycle"] == "exited",
        finished: false,
        agent_reported,
    }
}

/// Whether the agent in `terminal` reports the prompt `request` sends, so
/// silence after Enter means the prompt was not taken (review B2/M2 on
/// #39027):
/// - its hooks reported a harness session there (the daemon keeps the id on
///   the terminal);
/// - the agent's own newest record for it is `idle` at send time: a working
///   agent queues the message and reports nothing until its turn ends, and
///   an agent that quit leaves the id but no record;
/// - its harness has a hook that starts a turn (`UserPromptSubmit` and the
///   like; Copilot, CodeBuddy, Factory and Qoder have none);
/// - the send waits for the turn (`idle`, no `--pattern`);
/// - the message is not a local `/` command, nor Claude Code's `!` shell or
///   `#` memory input: none of them runs a prompt hook.
fn reports_prompts(terminal: &Value, agents: &[Value], request: &SendRequest) -> bool {
    let hooked = terminal
        .pointer("/extra/agent_session_id")
        .and_then(Value::as_str)
        .is_some_and(|session| !session.is_empty());
    let updated = |record: &Value| {
        let value = record.get("updated_at_ms");
        value
            .and_then(Value::as_u64)
            .or_else(|| value.and_then(Value::as_str).and_then(|text| text.parse().ok()))
            .unwrap_or(0)
    };
    let own = agents
        .iter()
        .filter(|record| {
            record.get("terminal_id") == terminal.get("id") && roster::reported_by_agent(record)
        })
        .max_by_key(|record| updated(record));
    let idle =
        own.is_some_and(|record| record.get("state").and_then(Value::as_str) == Some("idle"));
    let starts_turns = own
        .and_then(|record| {
            record.pointer("/extra/agent").or_else(|| record.get("agent")).and_then(Value::as_str)
        })
        .is_some_and(|harness| {
            roster::harness_hooks_report(harness, cmux_tui_core::agent_hook_event_starts_turn)
        });
    let local_input = request.text.trim_start().starts_with(['/', '!', '#']);
    hooked
        && idle
        && starts_turns
        && request.wait == Wait::Idle
        && request.pattern.is_none()
        && !local_input
}

/// The terminal record's last finished shell command (`extra.last_command`).
pub(in crate::cli) fn last_command(terminal: &Value) -> Option<&Value> {
    terminal.get("extra")?.get("last_command").filter(|last| last.is_object())
}

/// The command the shell finished after the send: the record's last command
/// when it differs from the one the terminal had before the message was
/// typed (compared whole, so no clock is shared with the daemon).
pub(in crate::cli) fn finished_since<'a>(
    terminal: &'a Value,
    before: Option<&Value>,
) -> Option<&'a Value> {
    last_command(terminal).filter(|last| Some(*last) != before)
}

/// The exit status of a finished command record; `None` when the shell
/// reported none.
pub(in crate::cli) fn exit_status(last: &Value) -> Option<i64> {
    last.get("exit_code").and_then(Value::as_i64)
}

/// Sends `request` and waits as it asks; the result is the send receipt.
pub(in crate::cli) fn run<B: Daemon + ?Sized>(
    backend: &B,
    session: Option<&str>,
    request: &SendRequest,
) -> Result<Value, SendFailure> {
    let mut sleep = std::thread::sleep;
    let mut clock = Clock { now: &Instant::now, sleep: &mut sleep, now_ms: super::now_ms() };
    run_on(backend, session, request, &mut clock)
}

/// [`run`] on `clock`: the Enter delay, the polls and the stall limit use it
/// (tests pass a fake one). Agent record times still compare with unix ms.
pub(in crate::cli) fn run_on<B: Daemon + ?Sized>(
    backend: &B,
    session: Option<&str>,
    request: &SendRequest,
    clock: &mut Clock<'_>,
) -> Result<Value, SendFailure> {
    if request.text.trim().is_empty() {
        return Err(SendFailure::local("usage.invalid", "send needs --text", json!({}), 2));
    }
    let pattern = match request.pattern.as_deref() {
        Some(pattern) => Some(cmux_tui_core::wait_pattern::compile(pattern).map_err(|error| {
            SendFailure::local(
                "usage.invalid",
                format!("--pattern is not a valid regular expression: {error}"),
                json!({"pattern": pattern}),
                2,
            )
        })?),
        None => None,
    };
    let snapshot = snapshot(backend, session)?;
    let terminal = find_terminal(&snapshot, &request.target)?;
    let id = terminal["id"].as_str().unwrap_or_default().to_owned();
    let before = last_command(terminal).cloned();
    // A send's durable child keys include this resolved terminal identity.
    // Replaying a title, tab, prefix or "current" after it moves can instead
    // create new keys and apply the prompt to another terminal. Require the
    // exact resource ID whenever the caller supplies a replayable send key.
    if request.idempotency_key.is_some() && request.target != id {
        return Err(SendFailure::local(
            "terminal.send_stable_target_required",
            format!("a keyed send requires the full terminal ID {id}; use that ID on retry"),
            json!({"terminal": id, "target": request.target}),
            2,
        ));
    }
    let agents = snapshot["agents"].as_array().map(Vec::as_slice).unwrap_or_default();
    // Only the blocked check below reads the agent; done-until-seen is moot.
    let agent = roster::agent_of_terminal(terminal, agents, false);
    // The dialog it shows, as a blocked send answers it; a failed read
    // leaves the options out. A stale screen guess of blocked has none.
    let dialog = agent
        .as_ref()
        .filter(|agent| !request.force && agent.state == AgentState::Blocked)
        .and_then(|_| {
            let screen = plan(&["terminal", &id, "screen", "read"])
                .ok()
                .and_then(|read| backend.request(session, read).ok())
                .and_then(|read| read.get("text").and_then(Value::as_str).map(str::to_owned))
                .unwrap_or_default();
            dialog_options::blocked_dialog(terminal, agents, &screen)
        });
    if let Some(agent) = &agent
        && let Some(dialog) = dialog
    {
        let messages = &crate::localization::catalog().pane_cli;
        return Err(SendFailure::local(
            "agent.waiting_for_input",
            dialog_options::dialog_refusal(messages, &request.target, &dialog),
            json!({
                "terminal": id,
                "harness": agent.harness,
                "state": agent.state.as_str(),
                "status": "blocked",
                "dialog": dialog,
            }),
            BLOCKED_EXIT,
        ));
    }
    let send_id = match request.idempotency_key.as_deref() {
        Some(key) => {
            cmux_tui_core::resource::validate_idempotency_key(key).map_err(|error| {
                SendFailure::local("usage.invalid", error.message, json!({}), 2)
            })?;
            key.to_owned()
        }
        None => super::super::wire::random_idempotency_key()
            .map_err(|error| SendFailure::local("usage.invalid", error.0, json!({}), 2))?,
    };
    let state = backend.request(session, plan(&["terminal", &id, "state", "read"])?)?;
    let vt = state["state_base64"]
        .as_str()
        .and_then(|text| base64::engine::general_purpose::STANDARD.decode(text).ok())
        .unwrap_or_default();
    let paste = reply::paste_mode_on(&vt);
    let engine = &base64::engine::general_purpose::STANDARD;
    let typed = engine.encode(reply::input_bytes(&request.text, paste));
    let write = |encoded: &str, stage: &str| -> Result<(), SendFailure> {
        let plan = mutation(
            &["terminal", &id, "write", "--bytes-base64", encoded],
            stage_key(&send_id, &id, stage),
        )?;
        backend
            .request(session, plan)
            .map_err(|error| stage_failure(error.into(), &send_id, &id, stage))?;
        Ok(())
    };
    let reads = Reads::new();
    // What the screen shows before the message: an agent whose echo is not
    // found (a pasted message drawn as a placeholder) still answers only
    // what it printed after the send, never the turns already there.
    let shown_before = (request.wait == Wait::Idle)
        .then(|| reads.screen(backend, session, &id, &[]).ok())
        .flatten()
        .map(|screen| reply::lines(screen.get("text").and_then(Value::as_str).unwrap_or_default()));
    let sent_ms = super::now_ms();
    write(&typed, "paste")?;
    (clock.sleep)(request.enter_delay);
    write(&engine.encode(b"\r"), "enter")?;
    let sent_at = (clock.now)();
    let mut receipt = json!({
        "terminal": id,
        "idempotency_key": send_id,
        "harness": agent.as_ref().map(|agent| agent.harness.clone()),
        "bracketed_paste": paste,
        "wait": request.wait.as_str(),
    });
    if request.wait == Wait::None {
        receipt.set("sent", Value::Bool(true));
        return Ok(receipt);
    }
    let waited = wait(
        backend,
        session,
        &id,
        request,
        &Watch {
            sent_at,
            sent_ms,
            before: before.as_ref(),
            pattern: pattern.as_ref(),
            reports_prompts: reports_prompts(terminal, agents, request),
        },
        &reads,
        clock,
    )?;
    let shown_text = waited.screen.get("text").and_then(Value::as_str).unwrap_or_default();
    let unsubmitted = match waited.verdict {
        Verdict::Stalled => Some("no_agent_report"),
        Verdict::Done(AgentState::Idle)
            if request.wait == Wait::Idle
                && pattern.is_none()
                && !waited.agent_reported
                && reply::input_box_holds(shown_text, &request.text) =>
        {
            Some("input_box")
        }
        _ => None,
    };
    if let Some(reason) = unsubmitted {
        let message = crate::localization::catalog().terminal_input.send_not_submitted;
        return Err(SendFailure::local(
            "send.not_submitted",
            message.replace("{terminal}", &id),
            json!({
                "terminal": id,
                "idempotency_key": send_id,
                "typed": true,
                "reason": reason,
                "stall_ms": request.stall.as_millis().to_string(),
            }),
            1,
        ));
    }
    let lines = reply_lines(backend, session, &id, &waited.screen, &request.text, &reads);
    let screen =
        reply::lines(waited.screen.get("text").and_then(Value::as_str).unwrap_or_default());
    let Reply { text, anchored } =
        reply::reply_since(&lines, &request.text, shown_before.as_deref(), &screen);
    let (state, timed_out) = match waited.verdict {
        Verdict::Done(state) => (state.as_str(), false),
        Verdict::Exited => ("exited", false),
        // A stalled send already failed with send.not_submitted above.
        Verdict::Pending | Verdict::Stalled => (AgentState::Working.as_str(), true),
    };
    // `status` is the word `terminal list --agents` says for this turn: a
    // finished turn nobody viewed yet (an unread notification, read after
    // the wait) is `done`; `state` keeps the wait's own word. The snapshot
    // from before the send cannot tell (its unread notification is an older
    // turn's), so a failed read is tried once more. When that fails too, a
    // finished turn is `unknown`: `idle` would claim somebody viewed it.
    let status = match waited.verdict {
        Verdict::Done(state) => {
            let after =
                self::snapshot(backend, session).or_else(|_| self::snapshot(backend, session));
            match after {
                Ok(after) => roster::status_of(state.as_str(), roster::unseen(&after, &id))
                    .map_or(state.as_str(), |status| status.as_str()),
                Err(_) if state == AgentState::Idle => cmux_tui_core::AgentStatus::Unknown.as_str(),
                Err(_) => roster::status_of(state.as_str(), false)
                    .map_or(state.as_str(), |status| status.as_str()),
            }
        }
        Verdict::Exited => AgentState::Ended.as_str(),
        Verdict::Pending | Verdict::Stalled => AgentState::Working.as_str(),
    };
    receipt.set("sent", Value::Bool(true));
    if let Some(code) = waited.finished.as_ref().and_then(exit_status) {
        receipt.set("exit_status", json!(code));
    }
    if pattern.is_some() {
        receipt.set("matched", Value::Bool(waited.matched));
    }
    receipt.set("state", Value::String(state.to_owned()));
    receipt.set("status", Value::String(status.to_owned()));
    receipt.set("timed_out", Value::Bool(timed_out));
    receipt.set("waited_ms", json!(sent_at.elapsed().as_millis().to_string()));
    receipt.set("anchored", Value::Bool(anchored));
    if waited.verdict == Verdict::Done(AgentState::Blocked) {
        // A dialog is no reply: the receipt says what it asks instead.
        let dialog = dialog_options::blocked_dialog(&waited.terminal, &waited.records, shown_text)
            .unwrap_or_else(|| dialog_options::dialog_json(AGENT_QUESTION.id, None, shown_text));
        let messages = &crate::localization::catalog().pane_cli;
        let reason = dialog_options::dialog_reason(messages, &request.target, &dialog);
        receipt.set("reason", json!(reason));
        receipt.set("dialog", dialog);
        receipt.set("reply", Value::Null);
        receipt.set("reply_source", Value::Null);
        receipt.set("output", Value::String(text));
        return Ok(receipt);
    }
    let hooked = (waited.verdict == Verdict::Done(AgentState::Idle))
        .then(|| hook_reply(&waited.records, sent_ms))
        .flatten();
    let (reply, source) = match hooked {
        Some(reply) => (reply, "hook"),
        None => (text.clone(), "screen"),
    };
    receipt.set("reply", Value::String(reply));
    receipt.set("reply_source", json!(source));
    receipt.set("output", Value::String(text));
    Ok(receipt)
}

/// What the wait after Enter watches for.
struct Watch<'a> {
    sent_at: Instant,
    sent_ms: u64,
    /// The terminal's last finished command before the message was typed.
    before: Option<&'a Value>,
    pattern: Option<&'a Regex>,
    /// The terminal's agent reports every prompt it takes (its hooks).
    reports_prompts: bool,
}

/// How the wait ended.
struct Waited {
    verdict: Verdict,
    /// The last terminal record read (`terminal show`).
    terminal: Value,
    /// The last screen read.
    screen: Value,
    /// The command the shell finished after the send, if it reported one.
    finished: Option<Value>,
    /// `--pattern` matched output after the echo.
    matched: bool,
    /// The last agent records read (`agent list --terminal`).
    records: Vec<Value>,
    /// The agent itself (hooks, socket) wrote a record after the send.
    agent_reported: bool,
}

/// Whether this daemon joins soft wraps on reads (`terminal-read-unwrap-v1`);
/// learned from the first read, which an older daemon refuses.
struct Reads {
    unwrap: Cell<Option<bool>>,
}

impl Reads {
    fn new() -> Self {
        Self { unwrap: Cell::new(None) }
    }

    /// One `terminal.screen.read` with `extra` words, unwrapped when the
    /// daemon can.
    fn screen<B: Daemon + ?Sized>(
        &self,
        backend: &B,
        session: Option<&str>,
        id: &str,
        extra: &[&str],
    ) -> Result<Value, SendFailure> {
        let mut words = vec!["terminal", id, "screen", "read"];
        words.extend_from_slice(extra);
        if self.unwrap.get() != Some(false) {
            let mut unwrapped = words.clone();
            unwrapped.push("--unwrap");
            match backend.request(session, plan(&unwrapped)?) {
                Ok(screen) => {
                    self.unwrap.set(Some(true));
                    return Ok(screen);
                }
                Err(failure) if self.unwrap.get().is_none() && is_unknown_field(&failure) => {
                    self.unwrap.set(Some(false));
                }
                Err(failure) => return Err(failure.into()),
            }
        }
        if !extra.is_empty() {
            return Err(SendFailure::local("usage.invalid", "reads need unwrap", json!({}), 1));
        }
        Ok(backend.request(session, plan(&words)?)?)
    }
}

/// A daemon without the field refuses it as invalid (it names no field it
/// does not know), so any validation refusal of the first read falls back.
fn is_unknown_field(failure: &CallFailure) -> bool {
    failure
        .error
        .get("code")
        .and_then(Value::as_str)
        .is_some_and(|code| code.starts_with("validation"))
}

/// The output after the message's echo on `screen`: the lines after the
/// echo, or the whole screen once the echo scrolled off it.
fn new_output(screen: &Value, message: &str) -> String {
    let lines = reply::lines(screen.get("text").and_then(Value::as_str).unwrap_or_default());
    match reply::anchor(&lines, message) {
        Some(start) => lines.get(start..).unwrap_or_default().join("\n"),
        None => lines.join("\n"),
    }
}

/// Polls until the verdict is in or the timeout passes (`Pending`), and
/// answers the last screen read.
fn wait<B: Daemon + ?Sized>(
    backend: &B,
    session: Option<&str>,
    id: &str,
    request: &SendRequest,
    watch: &Watch<'_>,
    reads: &Reads,
    clock: &mut Clock<'_>,
) -> Result<Waited, SendFailure> {
    let mut settle = Settle::new(request.wait, request.settle, watch.sent_at);
    if watch.reports_prompts {
        settle = settle.expecting_report(request.stall);
    }
    let deadline = watch.sent_at + request.timeout;
    let show = plan(&["terminal", id, "show"])?;
    let agents = plan(&["agent", "list", "--terminal", id])?;
    loop {
        let terminal = backend.request(session, show.clone())?;
        // An agent list failure (an older daemon) leaves the screen and
        // the program status to decide.
        let records = backend.request(session, agents.clone()).unwrap_or(Value::Null);
        let records = records.as_array().cloned().unwrap_or_default();
        let shown = reads.screen(backend, session, id, &[])?;
        let now = (clock.now)();
        let finished = finished_since(&terminal, watch.before).cloned();
        let mut sample = sample(&terminal, &records, &shown, watch.sent_ms);
        sample.finished = finished.is_some();
        let matched = watch
            .pattern
            .is_some_and(|pattern| pattern.is_match(&new_output(&shown, &request.text)));
        let verdict = if matched {
            Verdict::Done(AgentState::Idle)
        } else if watch.pattern.is_some() {
            // Waiting on a pattern: only a match, the command's end, the
            // terminal's exit or the timeout end it.
            match settle.observe(&sample, now) {
                Verdict::Exited => Verdict::Exited,
                _ if sample.finished && sample.prompt => Verdict::Done(AgentState::Idle),
                _ => Verdict::Pending,
            }
        } else {
            settle.observe(&sample, now)
        };
        if verdict != Verdict::Pending || now >= deadline {
            let agent_reported = settle.reported();
            return Ok(Waited {
                verdict,
                terminal,
                screen: shown,
                finished,
                matched,
                records,
                agent_reported,
            });
        }
        (clock.sleep)(request.poll.min(deadline.saturating_duration_since(now)));
    }
}

/// The whole last reply a record of `records` carries, when the daemon kept
/// it at or after `since_ms` (the send): an older one is another turn's.
fn hook_reply(records: &[Value], since_ms: u64) -> Option<String> {
    let number = |value: &Value| {
        value.as_u64().or_else(|| value.as_str().and_then(|text| text.parse().ok()))
    };
    records.iter().find_map(|record| {
        let extra = record.get("extra")?;
        let at = extra.get("last_reply_at_ms").and_then(number)?;
        let text = extra.get("last_reply_text")?.as_str()?.trim();
        (at >= since_ms && !text.is_empty()).then(|| text.to_owned())
    })
}

/// The screen's lines, with history pages before them until the message's
/// echo is among them (or [`HISTORY_PAGES`] pages were read).
fn reply_lines<B: Daemon + ?Sized>(
    backend: &B,
    session: Option<&str>,
    id: &str,
    screen: &Value,
    message: &str,
    reads: &Reads,
) -> Vec<String> {
    let mut lines = reply::lines(screen["text"].as_str().unwrap_or_default());
    if reads.unwrap.get() == Some(true) {
        // Logical lines of scrollback and screen, growing until the echo
        // is among them.
        let most = REPLY_LINES_MAX;
        let mut count = REPLY_LINES;
        while reply::anchor(&lines, message).is_none() {
            let count_text = count.to_string();
            match reads.screen(backend, session, id, &["--lines", &count_text]) {
                Ok(read) => {
                    lines =
                        reply::lines(read.get("text").and_then(Value::as_str).unwrap_or_default());
                }
                Err(_) => break,
            }
            if count >= most {
                break;
            }
            count = count.saturating_mul(2).min(most);
        }
        return lines;
    }
    let mut before: Option<String> = None;
    let limit = HISTORY_PAGE_ROWS.to_string();
    for _ in 0..HISTORY_PAGES {
        if reply::anchor(&lines, message).is_some() {
            break;
        }
        let mut words = vec!["terminal", id, "history", "read", "--limit", limit.as_str()];
        if let Some(cursor) = before.as_deref() {
            words.extend(["--before", cursor]);
        }
        let Ok(page) = plan(&words) else { break };
        let Ok(page) = backend.request(session, page) else { break };
        let rows = page["rows"].as_array().map(Vec::as_slice).unwrap_or_default();
        if rows.is_empty() {
            break;
        }
        let mut older: Vec<String> = rows
            .iter()
            .map(|row| {
                row["runs"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(|run| run["text"].as_str())
                    .collect::<String>()
            })
            .collect();
        older.append(&mut lines);
        lines = older;
        match &page["next"] {
            Value::String(next) => before = Some(next.clone()),
            Value::Number(next) => before = Some(next.to_string()),
            _ => break,
        }
    }
    lines
}
