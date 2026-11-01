//! `cmux agents wait` and the `agents_wait` MCP tool: wait until a named
//! agent stops working (`idle`), a permission or question dialog is pending
//! (`dialog`), or text reaches a terminal's screen (`text`), then answer a
//! receipt with a fresh composed snapshot. A timeout is an answer
//! (`matched: false`), not an error, so an agent never polls snapshots.
//!
//! Waits wake on events. `text` is the daemon's own `terminal.wait`, which
//! wakes on terminal output. `idle` and `dialog` hold the daemon's
//! `session.events` stream open and check again on each event; they also
//! check every second for what only the app knows (an agent chat's state,
//! the pending dialogs), because the app publishes no event for it.

use std::time::{Duration, Instant};

use cmux_tui_core::resource::ResourceOperation;
use serde_json::{Value, json};

use super::super::command::{RequestPlan, ResponseView, WireOperation};
use super::super::mcp::{Backend, CallFailure, FailureKind};
use super::super::{UsageError, app};
use super::{AgentFailure, fresh_state, snapshot_plan};

pub(in crate::cli) const DEFAULT_TIMEOUT_SECONDS: u64 = 30;
/// Below the tool-call timeout of MCP clients.
pub(in crate::cli) const MAX_TIMEOUT_SECONDS: u64 = 120;
/// How often a wait checks what no event announces.
const RECHECK: Duration = Duration::from_secs(1);
/// A burst of events checks once.
const MIN_CHECK_GAP: Duration = Duration::from_millis(200);
/// The fields of a dialog that `--target` may name.
const DIALOG_IDS: [&str; 7] = [
    "request_id",
    "workstream_id",
    "session_id",
    "agent_session",
    "terminal_id",
    "tab_id",
    "source",
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::cli) enum Until {
    Idle,
    Dialog,
    Text,
}

impl Until {
    pub(in crate::cli) fn name(self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::Dialog => "dialog",
            Self::Text => "text",
        }
    }
}

/// What `cmux agents wait` waits for, and how long.
#[derive(Clone, Debug, PartialEq)]
pub(in crate::cli) struct WaitRequest {
    pub until: Until,
    pub target: Option<String>,
    pub text: Option<String>,
    pub regex: bool,
    pub timeout: Duration,
}

impl WaitRequest {
    /// What a progress note says it waits for: `idle term_…`, `dialog`.
    pub(in crate::cli) fn describe(&self) -> String {
        match &self.target {
            Some(target) => format!("{} {target}", self.until.name()),
            None => self.until.name().to_owned(),
        }
    }
}

/// Parses the words after `cmux agents wait`.
pub(super) fn parse(args: &[&str]) -> Result<WaitRequest, UsageError> {
    let usage = |message: String| UsageError::new(format!("agents wait: {message}"));
    let (mut until, mut target, mut text, mut regex, mut timeout) = (None, None, None, false, None);
    let mut index = 0;
    while index < args.len() {
        let (flag, inline) = match args[index].split_once('=') {
            Some((flag, value)) if flag.starts_with("--") => (flag, Some(value)),
            _ => (args[index], None),
        };
        if flag == "--regex" {
            if inline.is_some() || regex {
                return Err(usage("--regex takes no value and comes once".into()));
            }
            regex = true;
            index += 1;
            continue;
        }
        let slot = match flag {
            "--until" => &mut until,
            "--target" => &mut target,
            "--text" => &mut text,
            "--timeout" => &mut timeout,
            other => return Err(usage(format!("unexpected argument {other:?}"))),
        };
        if slot.is_some() {
            return Err(usage(format!("{flag} comes once")));
        }
        let value = match inline {
            Some(value) => value,
            None => {
                index += 1;
                // A separate value never starts with `-`; `--text=-x` keeps one.
                args.get(index)
                    .copied()
                    .filter(|value| !value.starts_with('-'))
                    .ok_or_else(|| usage(format!("{flag} needs a value")))?
            }
        };
        if value.is_empty() {
            return Err(usage(format!("{flag} needs a value")));
        }
        *slot = Some(value.to_owned());
        index += 1;
    }
    let until = match until.as_deref() {
        Some("idle") => Until::Idle,
        Some("dialog") => Until::Dialog,
        Some("text") => Until::Text,
        Some(other) => {
            return Err(usage(format!("--until is idle, dialog or text, not {other:?}")));
        }
        None => return Err(usage("--until idle|dialog|text is required".into())),
    };
    if target.as_deref().is_some_and(|target| target.starts_with('-')) {
        return Err(usage("--target must not start with '-'".into()));
    }
    match until {
        Until::Idle | Until::Text if target.is_none() => {
            return Err(usage(format!("--until {} needs --target", until.name())));
        }
        Until::Text if text.is_none() => return Err(usage("--until text needs --text".into())),
        Until::Idle | Until::Dialog if text.is_some() || regex => {
            return Err(usage("--text and --regex go with --until text".into()));
        }
        _ => {}
    }
    // The daemon's terminal.wait compiles it with the same crate and limits;
    // a pattern it would refuse never starts a wait.
    if regex && let Some(pattern) = &text {
        regex::Regex::new(pattern)
            .map_err(|error| usage(format!("--text is not a valid regular expression: {error}")))?;
    }
    let timeout = match timeout {
        None => Duration::from_secs(DEFAULT_TIMEOUT_SECONDS),
        Some(value) => match value.parse::<f64>() {
            Ok(seconds)
                if seconds.is_finite() && (0.0..=MAX_TIMEOUT_SECONDS as f64).contains(&seconds) =>
            {
                Duration::from_secs_f64(seconds)
            }
            _ => {
                return Err(usage(format!(
                    "--timeout is a number of seconds from 0 to {MAX_TIMEOUT_SECONDS}"
                )));
            }
        },
    };
    Ok(WaitRequest { until, target, text, regex, timeout })
}

/// Waits as `request` says and answers the receipt `{until, matched,
/// waited_seconds, match, state}`. Only a request that names nothing, or an
/// owner that refuses the first read, fails.
pub(in crate::cli) fn run<B: Backend>(
    backend: &B,
    session: Option<&str>,
    request: &WaitRequest,
) -> Result<Value, AgentFailure> {
    let started = Instant::now();
    let deadline = started + request.timeout;
    let found = match request.until {
        Until::Text => wait_text(backend, session, request, deadline)?,
        Until::Idle => {
            let target = request.target.as_deref().unwrap_or_default();
            wait_for(backend, session, deadline, |first| idle(backend, session, target, first))?
        }
        Until::Dialog => {
            let target = request.target.as_deref();
            wait_for(backend, session, deadline, |first| dialog(backend, session, target, first))?
        }
    };
    let waited = started.elapsed().as_millis() as f64 / 1000.0;
    Ok(json!({
        "schema_version": 1,
        "until": request.until.name(),
        "matched": found.is_some(),
        "waited_seconds": waited,
        "match": found.unwrap_or(Value::Null),
        "state": fresh_state(backend, session),
    }))
}

/// Checks once, then on each daemon event and every [`RECHECK`] until the
/// deadline. Without an event stream (no daemon) it checks every
/// [`RECHECK`]. `check(true)` is the first check: its failure is the call's.
fn wait_for<B: Backend>(
    backend: &B,
    session: Option<&str>,
    deadline: Instant,
    mut check: impl FnMut(bool) -> Result<Option<Value>, AgentFailure>,
) -> Result<Option<Value>, AgentFailure> {
    if let Some(found) = check(true)? {
        return Ok(Some(found));
    }
    let mut outcome = None;
    let mut last = Instant::now();
    let _ = backend.session_events(session, None, deadline, RECHECK, &mut |item| {
        if item.is_some() && last.elapsed() < MIN_CHECK_GAP {
            return false;
        }
        last = Instant::now();
        match check(false) {
            Ok(None) => false,
            other => {
                outcome = Some(other);
                true
            }
        }
    });
    if let Some(outcome) = outcome {
        return outcome;
    }
    // The stream did not open or ended early: check on a timer instead.
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return Ok(None);
        }
        std::thread::sleep(left.min(RECHECK));
        if let Some(found) = check(false)? {
            return Ok(Some(found));
        }
    }
}

fn not_found(target: &str) -> AgentFailure {
    AgentFailure::Owner(CallFailure {
        kind: FailureKind::NotRun,
        error: json!({
            "code": "selector.not_found",
            "message": format!("no terminal, tab, agent or agent chat is {target:?}; \
                                agents_snapshot lists them"),
            "details": {"target": target},
            "retryable": false,
        }),
        idempotency_key: None,
    })
}

/// `text`: the daemon's `terminal.wait` on the target's terminal, which
/// wakes on its output. The text is literal unless `regex`.
fn wait_text<B: Backend>(
    backend: &B,
    session: Option<&str>,
    request: &WaitRequest,
    deadline: Instant,
) -> Result<Option<Value>, AgentFailure> {
    let target = request.target.as_deref().unwrap_or_default();
    let text = request.text.as_deref().unwrap_or_default();
    let daemon = backend.resource(session, snapshot_plan(), &[]).map_err(AgentFailure::Owner)?;
    let terminal = terminals(&daemon)
        .find(|terminal| names_terminal(terminal, target))
        .and_then(|terminal| terminal["id"].as_str())
        .ok_or_else(|| not_found(target))?
        .to_owned();
    let pattern = if request.regex { text.to_owned() } else { literal(text) };
    let left = deadline.saturating_duration_since(Instant::now());
    let plan = RequestPlan {
        operation: WireOperation::Typed(ResourceOperation::TerminalWait),
        params: json!({
            "machine": "current",
            "session": "current",
            "terminal": terminal,
            "pattern": pattern,
            "timeout_ms": left.as_millis().to_string(),
        }),
        idempotency_key: None,
        stream: false,
        resolve: Vec::new(),
        view: ResponseView::Full,
    };
    let result = match backend.resource(session, plan, &[]) {
        Ok(result) => result,
        // A terminal that closed mid-wait ends it as `idle` reports one.
        Err(failure) => {
            let closed = backend.resource(session, snapshot_plan(), &[]).is_ok_and(|daemon| {
                !terminals(&daemon).any(|shown| shown["id"] == terminal.as_str())
            });
            if closed {
                return Ok(Some(
                    json!({"target": target, "terminal": terminal, "state": "closed"}),
                ));
            }
            return Err(AgentFailure::Owner(failure));
        }
    };
    Ok((result["matched"] == true).then(|| {
        json!({
            "target": target,
            "terminal": terminal,
            "text": text,
            "regex": request.regex,
            "screen": result["text"],
        })
    }))
}

/// `text` as a regular expression that matches only itself.
fn literal(text: &str) -> String {
    let mut pattern = String::with_capacity(text.len());
    for character in text.chars() {
        if "\\.+*?()|[]{}^$#&-~".contains(character) {
            pattern.push('\\');
        }
        pattern.push(character);
    }
    pattern
}

fn terminals(daemon: &Value) -> impl Iterator<Item = &Value> {
    daemon["terminals"].as_array().into_iter().flatten()
}

/// The terminal is `target`, or shows the tab `target`.
fn names_terminal(terminal: &Value, target: &str) -> bool {
    terminal["id"] == target
        || terminal["tab_id"] == target
        || terminal["tab_ids"].as_array().is_some_and(|tabs| tabs.iter().any(|tab| tab == target))
}

/// `idle`: the target's agent stopped working. The target is a terminal,
/// a tab, a daemon agent (`agent_…`) or an agent chat's session.
fn idle<B: Backend>(
    backend: &B,
    session: Option<&str>,
    target: &str,
    first: bool,
) -> Result<Option<Value>, AgentFailure> {
    let daemon = backend.resource(session, snapshot_plan(), &[]);
    let app = backend.app("snapshot.get", json!({}), app::READ_TIMEOUT, None, false);
    let complete = daemon.is_ok() && app.is_ok();
    if first && let (Err(failure), Err(_)) = (&daemon, &app) {
        return Err(AgentFailure::Owner(failure.clone()));
    }
    let tabs = app.as_ref().map(|app| app_tabs(&app["topology"])).unwrap_or_default();
    // acpmux owns a chat's turn even while the GUI has its tab. A visible
    // conversation tab may omit agent_state until the app's next refresh;
    // treating that missing UI field as idle would finish the wait early.
    let current = match chat_wait_target(target, &tabs) {
        Some(chat) => chat_activity(backend, session, &chat, target, first)?,
        None => activity(target, daemon.as_ref().ok(), &tabs),
    };
    match current {
        Activity::Working => Ok(None),
        Activity::Stopped(found) => Ok(Some(found)),
        Activity::Missing if first => Err(not_found(target)),
        // Both owners answered and neither knows it any more: it closed.
        Activity::Missing if complete => Ok(Some(json!({"target": target, "state": "closed"}))),
        Activity::Missing => Ok(None),
    }
}

enum Activity {
    Missing,
    Working,
    Stopped(Value),
}

/// A chat UUID is independent of a terminal/tab id. We only make the extra
/// acpmux read for UUIDs, so an unknown terminal selector never starts a
/// daemon lookup and a tab prefix cannot be confused with a chat.
fn is_chat_session_id(target: &str) -> bool {
    let target = target.strip_prefix("acp:").unwrap_or(target);
    uuid::Uuid::parse_str(target).is_ok()
}

/// A direct chat session or a visible conversation tab that belongs to one.
/// In either case, acpmux is the source of its turn's activity. Preserve the
/// requested tab id for the receipt but use the session id to read its state.
fn chat_wait_target(target: &str, tabs: &[&Value]) -> Option<String> {
    if is_chat_session_id(target) {
        return Some(target.strip_prefix("acp:").unwrap_or(target).to_owned());
    }
    tabs.iter()
        .find(|tab| tab.get("id").and_then(Value::as_str) == Some(target))
        .and_then(|tab| tab.get("agent_session").and_then(Value::as_str))
        .filter(|session| is_chat_session_id(session))
        .map(str::to_owned)
}

/// Acpmux, rather than app topology, owns the turn and queue of a tabless
/// chat. The same scoped chat-state route used by agents_chat_state enforces
/// the workspace and session boundary before any activity is disclosed.
fn chat_activity<B: Backend>(
    backend: &B,
    session: Option<&str>,
    chat_session: &str,
    target: &str,
    first: bool,
) -> Result<Activity, AgentFailure> {
    let command = super::chat::ChatCommand::State { target: chat_session.to_owned() };
    let info = match backend.chat_in_session(session, &command, None, "agents") {
        Ok(info) => info,
        Err(failure)
            if failure.error.get("code").and_then(Value::as_str) == Some("selector.not_found") =>
        {
            return Ok(Activity::Missing);
        }
        Err(failure)
            if failure.error.get("code").and_then(Value::as_str) == Some("chat.out_of_scope")
                || first =>
        {
            return Err(AgentFailure::Owner(failure));
        }
        // A transient read failure during an existing wait cannot prove the
        // chat closed. Keep waiting for the next event or scheduled check.
        Err(_) => return Ok(Activity::Working),
    };
    let state = info.get("result").unwrap_or(&info);
    let chat = state.get("chat").and_then(Value::as_str).ok_or_else(|| {
        AgentFailure::Owner(CallFailure {
            kind: FailureKind::NotRun,
            error: json!({
                "code": "chat.invalid_state",
                "message": "acpmux returned no chat identity for its activity",
                "details": {},
                "retryable": true,
            }),
            idempotency_key: None,
        })
    })?;
    let pending = state.get("pending_permissions").is_some_and(has_pending);
    let status = state.get("status").and_then(Value::as_str).unwrap_or_default();
    let reason = if pending || matches!(status, "waiting" | "waiting-for-input") {
        Some("blocked")
    } else if state.get("running").and_then(Value::as_bool) == Some(true)
        || state.get("queued").is_some_and(has_pending)
        || matches!(status, "running" | "starting" | "pending")
    {
        None
    } else {
        match status {
            "closed" => Some("closed"),
            "failed" => Some("failed"),
            "disconnected" => Some("disconnected"),
            "ready" | "idle" | "done" => Some("idle"),
            // An unfamiliar state is still active until its owner says it is done.
            _ => None,
        }
    };
    Ok(match reason {
        None => Activity::Working,
        Some(state) => Activity::Stopped(json!({
            "target": target, "chat": chat, "state": state,
        })),
    })
}

fn has_pending(value: &Value) -> bool {
    match value {
        Value::Bool(pending) => *pending,
        Value::Number(count) => count.as_u64().is_some_and(|count| count > 0),
        Value::Array(items) => !items.is_empty(),
        Value::Object(items) => !items.is_empty(),
        _ => false,
    }
}

/// Whether `target`'s agent works: a daemon agent record, a program
/// status record (OSC 7501) or the app's tab state says `working`. A plain
/// shell command with no agent record works while it runs.
fn activity(target: &str, daemon: Option<&Value>, app_tabs: &[&Value]) -> Activity {
    let empty = Value::Null;
    let daemon = daemon.unwrap_or(&empty);
    let agents = daemon["agents"].as_array().map(Vec::as_slice).unwrap_or_default();
    let agent = agents.iter().find(|agent| agent["id"] == target);
    let terminal = terminals(daemon).find(|terminal| {
        names_terminal(terminal, target)
            || agent.is_some_and(|agent| agent["terminal_id"] == terminal["id"])
    });
    let terminal_id =
        terminal.map(|terminal| &terminal["id"]).or(agent.map(|agent| &agent["terminal_id"]));
    let app_tab = app_tabs.iter().find(|tab| {
        tab["id"] == target
            || tab["agent_session"] == target
            || terminal_id.is_some_and(|id| !id.is_null() && tab["terminal"] == *id)
    });
    if terminal.is_none() && agent.is_none() && app_tab.is_none() {
        return Activity::Missing;
    }
    let mut states = agents
        .iter()
        .filter(|agent| terminal_id.is_some_and(|id| agent["terminal_id"] == *id))
        .filter_map(|agent| agent["state"].as_str())
        .collect::<Vec<_>>();
    if let Some(terminal) = terminal {
        let records = terminal["extra"]["program_status"].as_array();
        states.extend(records.into_iter().flatten().filter_map(|record| record["state"].as_str()));
    }
    states.extend(app_tab.and_then(|tab| tab["agent_state"].as_str()));
    let shell_runs = states.is_empty()
        && terminal.is_some_and(|terminal| terminal["extra"]["activity"]["state"] == "running");
    if shell_runs || states.contains(&"working") {
        return Activity::Working;
    }
    let state = if states.iter().any(|state| matches!(*state, "blocked" | "input")) {
        "blocked"
    } else {
        states.first().copied().unwrap_or("idle")
    };
    Activity::Stopped(json!({
        "target": target,
        "terminal": terminal_id.cloned().unwrap_or(Value::Null),
        "tab": app_tab.map(|tab| tab["id"].clone()).unwrap_or(Value::Null),
        "state": state,
    }))
}

/// `term_…`, `tab_…` or `agent_…`: an id the snapshot shows for an agent.
fn names_agent(target: &str) -> bool {
    ["term_", "tab_", "agent_"].iter().any(|prefix| target.starts_with(prefix))
}

/// Every tab object under the app's topology.
fn app_tabs(topology: &Value) -> Vec<&Value> {
    fn visit<'a>(value: &'a Value, out: &mut Vec<&'a Value>) {
        match value {
            Value::Object(object) => {
                for (key, child) in object {
                    if key == "tabs"
                        && let Value::Array(tabs) = child
                    {
                        out.extend(tabs.iter().filter(|tab| tab.is_object()));
                    }
                    visit(child, out);
                }
            }
            Value::Array(values) => values.iter().for_each(|value| visit(value, out)),
            _ => {}
        }
    }
    let mut tabs = Vec::new();
    visit(topology, &mut tabs);
    tabs
}

/// `dialog`: the app's pending permission and question dialogs (the
/// `agents_dialog_list` read), those of `target` when given.
fn dialog<B: Backend>(
    backend: &B,
    session: Option<&str>,
    target: Option<&str>,
    first: bool,
) -> Result<Option<Value>, AgentFailure> {
    // A target that names an agent (a terminal, tab or agent id) must exist,
    // as for idle and text. Any other target (a request id, a chat session,
    // a harness name) may belong to a dialog that has not appeared yet.
    if first && let Some(target) = target.filter(|target| names_agent(target)) {
        let daemon = backend.resource(session, snapshot_plan(), &[]);
        let app = backend.app("snapshot.get", json!({}), app::READ_TIMEOUT, None, false);
        let tabs = app.as_ref().map(|app| app_tabs(&app["topology"])).unwrap_or_default();
        if daemon.is_ok()
            && matches!(activity(target, daemon.as_ref().ok(), &tabs), Activity::Missing)
        {
            return Err(not_found(target));
        }
    }
    let feed = match backend.app(
        "feed.list",
        json!({"pending_only": true}),
        app::READ_TIMEOUT,
        None,
        false,
    ) {
        Ok(feed) => feed,
        Err(failure) if first => return Err(AgentFailure::Owner(failure)),
        Err(_) => return Ok(None),
    };
    let items = feed.get("items").unwrap_or(&feed).as_array().map(Vec::as_slice);
    let dialogs = items
        .unwrap_or_default()
        .iter()
        .filter(|item| item["status"].as_str().is_none_or(|status| status == "pending"))
        .filter(|item| target.is_none_or(|target| DIALOG_IDS.iter().any(|id| item[*id] == target)))
        .cloned()
        .collect::<Vec<_>>();
    Ok((!dialogs.is_empty()).then(|| json!({"target": target, "dialogs": dialogs})))
}
