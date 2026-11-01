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
//!   An agent that stops on a dialog ends the wait as `waiting-for-input`.
//! - `prompt`: the shell shows its prompt again (OSC 133) and the screen
//!   is still.
//! - A terminal whose agent waits on a dialog is refused without `force`:
//!   the typed text would answer the dialog.

use std::time::{Duration, Instant};

use base64::Engine as _;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::super::Surface;
use super::super::command::{self, CommandPlan, RequestPlan};
use super::super::mcp::{Backend, CallFailure, FailureKind};
use super::reply::{self, Reply};
use super::roster::{self, AgentState};
use cmux_json::JsonSet as _;

pub(in crate::cli) const DEFAULT_TIMEOUT: Duration = Duration::from_secs(300);
pub(in crate::cli) const DEFAULT_SETTLE: Duration = Duration::from_secs(3);
const DEFAULT_ENTER_DELAY: Duration = Duration::from_millis(300);
const DEFAULT_POLL: Duration = Duration::from_millis(250);
/// History rows one page reads while the message's echo is not found.
const HISTORY_PAGE_ROWS: u32 = 200;
/// History pages at most read for one reply.
const HISTORY_PAGES: usize = 10;

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
fn stage_failure(mut failure: SendFailure, send_id: &str, terminal: &str, phase: &str) -> SendFailure {
    if !failure.failure.error["details"].is_object() {
        failure.failure.error.set("details", json!({}));
    }
    failure.failure.error.set_path(&["details", "send_id"], json!(send_id));
    failure.failure.error.set_path(&["details", "phase"], json!(phase));
    failure.failure.error.set_path(&["details", "terminal"], json!(terminal));
    if failure.failure.kind == FailureKind::InProgress {
        let original = failure.failure.error["message"]
            .as_str()
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
/// `tab_` id it shows in, `current` (the caller's terminal), or an exact
/// title.
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
}

/// The wait's verdict on the samples so far.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::cli) enum Verdict {
    Pending,
    Done(AgentState),
    Exited,
}

/// The wait after Enter: [`Settle::observe`] each sample with its time.
#[derive(Debug)]
pub(in crate::cli) struct Settle {
    wait: Wait,
    settle: Duration,
    sent_at: Instant,
    last_screen: Option<String>,
    changed_at: Instant,
}

impl Settle {
    pub(in crate::cli) fn new(wait: Wait, settle: Duration, sent_at: Instant) -> Self {
        Self { wait, settle, sent_at, last_screen: None, changed_at: sent_at }
    }

    pub(in crate::cli) fn observe(&mut self, sample: &Sample, now: Instant) -> Verdict {
        if self.last_screen.as_deref() != Some(sample.screen.as_str()) {
            if self.last_screen.is_some() {
                self.changed_at = now;
            }
            self.last_screen = Some(sample.screen.clone());
        }
        if sample.exited {
            return Verdict::Exited;
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
            Wait::Idle if sample.waiting_for_input => Verdict::Done(AgentState::WaitingForInput),
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
        busy: command || progress || states.contains(&AgentState::Busy),
        waiting_for_input: states.contains(&AgentState::WaitingForInput),
        prompt: extra["prompt"].is_object(),
        exited: terminal["lifecycle"] == "exited",
    }
}

/// Sends `request` and waits as it asks; the result is the send receipt.
pub(in crate::cli) fn run<B: Daemon + ?Sized>(
    backend: &B,
    session: Option<&str>,
    request: &SendRequest,
) -> Result<Value, SendFailure> {
    if request.text.trim().is_empty() {
        return Err(SendFailure::local("usage.invalid", "send needs --text", json!({}), 2));
    }
    let snapshot = snapshot(backend, session)?;
    let terminal = find_terminal(&snapshot, &request.target)?;
    let id = terminal["id"].as_str().unwrap_or_default().to_owned();
    // A send's durable child keys include this resolved terminal identity.
    // Replaying a title, tab, prefix or "current" after it moves can instead
    // create new keys and apply the prompt to another terminal. Require the
    // exact resource ID whenever the caller supplies a replayable send key.
    if request.idempotency_key.is_some() && request.target != id {
        return Err(SendFailure::local(
            "terminal.send_stable_target_required",
            format!(
                "a keyed send requires the full terminal ID {id}; use that ID on retry"
            ),
            json!({"terminal": id, "target": request.target}),
            2,
        ));
    }
    let agents = snapshot["agents"].as_array().map(Vec::as_slice).unwrap_or_default();
    let agent = roster::agent_of_terminal(terminal, agents);
    if !request.force
        && let Some(agent) = &agent
        && agent.state == AgentState::WaitingForInput
    {
        return Err(SendFailure::local(
            "agent.waiting_for_input",
            format!(
                "the {} agent in {id} waits on a dialog; typed text would answer it. Answer the \
                 dialog (agents_dialog_list), or pass --force to type anyway",
                agent.harness
            ),
            json!({"terminal": id, "harness": agent.harness, "state": agent.state.as_str()}),
            1,
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
    let sent_ms = super::now_ms();
    write(&typed, "paste")?;
    std::thread::sleep(request.enter_delay);
    write(&engine.encode(b"\r"), "enter")?;
    let sent_at = Instant::now();
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
    let (verdict, screen) = wait(backend, session, &id, request, sent_at, sent_ms)?;
    let lines = reply_lines(backend, session, &id, &screen, &request.text);
    let Reply { text, anchored } = reply::reply_after(&lines, &request.text);
    let (state, timed_out) = match verdict {
        Verdict::Done(state) => (state.as_str(), false),
        Verdict::Exited => ("exited", false),
        Verdict::Pending => ("busy", true),
    };
    receipt.set("sent", Value::Bool(true));
    receipt.set("state", Value::String(state.to_owned()));
    receipt.set("timed_out", Value::Bool(timed_out));
    receipt.set("waited_ms", json!(sent_at.elapsed().as_millis().to_string()));
    receipt.set("anchored", Value::Bool(anchored));
    receipt.set("output", Value::String(text));
    Ok(receipt)
}

/// Polls until the verdict is in or the timeout passes (`Pending`), and
/// answers the last screen read.
fn wait<B: Daemon + ?Sized>(
    backend: &B,
    session: Option<&str>,
    id: &str,
    request: &SendRequest,
    sent_at: Instant,
    sent_ms: u64,
) -> Result<(Verdict, Value), SendFailure> {
    let mut settle = Settle::new(request.wait, request.settle, sent_at);
    let deadline = sent_at + request.timeout;
    let show = plan(&["terminal", id, "show"])?;
    let agents = plan(&["agent", "list", "--terminal", id])?;
    let screen = plan(&["terminal", id, "screen", "read"])?;
    loop {
        let terminal = backend.request(session, show.clone())?;
        // An agent list failure (an older daemon) leaves the screen and
        // the program status to decide.
        let records = backend.request(session, agents.clone()).unwrap_or(Value::Null);
        let records = records.as_array().map(Vec::as_slice).unwrap_or_default();
        let shown = backend.request(session, screen.clone())?;
        let now = Instant::now();
        let verdict = settle.observe(&sample(&terminal, records, &shown, sent_ms), now);
        if verdict != Verdict::Pending || now >= deadline {
            return Ok((verdict, shown));
        }
        std::thread::sleep(request.poll.min(deadline.saturating_duration_since(now)));
    }
}

/// The screen's lines, with history pages before them until the message's
/// echo is among them (or [`HISTORY_PAGES`] pages were read).
fn reply_lines<B: Daemon + ?Sized>(
    backend: &B,
    session: Option<&str>,
    id: &str,
    screen: &Value,
    message: &str,
) -> Vec<String> {
    let mut lines = reply::lines(screen["text"].as_str().unwrap_or_default());
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
