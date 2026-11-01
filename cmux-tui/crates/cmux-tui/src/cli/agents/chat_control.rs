//! `cmux agents chat new|state|interrupt|continue` and their MCP tools
//! (#23026, #23016): an agent starts a GUI agent chat in a given workspace or
//! pane without moving the person's focus, reads a chat's state, stops its
//! turn, and nudges it on.
//!
//! `new` creates the chat in the app's own acpmux (else the one `cmux acp` reaches, as
//! `chat send|read` read), with the harness, model, effort, mode and
//! permission policy given, and `CMUX_WORKSPACE_ID` naming the workspace it
//! belongs to (`_meta.acpmux.env`), so `chat send|read` reach it afterwards.
//! The app then shows it as a chat tab (`agent.openSessionTab`, or
//! `agent.openSessionWorkspace` for a new workspace): in the
//! given pane, the given workspace's focused pane (else its first), or a new workspace. Either
//! way nothing takes focus or switches the shown workspace. A first prompt goes in as the
//! chat's own, as a person types it into New Agent Chat and presses Return.
//!
//! The chat runs in the app's own acpmux (`agent.acpmux`) when the caller's is another one: a
//! Chief turn's chats run in its home's acpmux, so without this its "new chat" was a subagent
//! the app could not attach. Then `send|read|state|interrupt` find it there too (`chat::Chat`).
//!
//! `state` reads `_acpmux/info` (status, pending permissions, queued turns,
//! harness, model, mode). `interrupt` cancels the running turn
//! (`session/cancel`). `continue` is `send` with a default text. All three
//! reach only chats of this cmux session, as `send` and `read` do.

use serde_json::{Map, Value, json};

use super::super::app::{self, ActionName};
use super::super::mcp::{self, CallFailure, FailureKind};
use super::super::{GlobalArgs, UsageError};
use super::chat;
use cmux_json::JsonSet as _;

/// The permission policies an agent may start a chat with.
pub(in crate::cli) const AGENT_POLICIES: [&str; 3] = ["ask", "approve-reads", "deny-all"];

/// What `continue` sends when no text is given.
pub(in crate::cli) const CONTINUE_TEXT: &str = "Continue.";

/// A new chat's settings (`chat new` flags).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(in crate::cli) struct NewChat {
    /// An existing workspace (`ws_` id) whose focused pane (else its first) gets the tab.
    pub workspace: Option<String>,
    /// An existing pane (`pane_` id) that gets the tab.
    pub pane: Option<String>,
    /// The chat's name, and a new workspace's.
    pub name: Option<String>,
    /// The acpmux harness (`claude`, `codex`, a profile).
    pub harness: Option<String>,
    pub model: Option<String>,
    /// Thinking effort: default, low, medium, high, xhigh, max.
    pub effort: Option<String>,
    /// The harness mode to start in; acpmux decides whether a caller may.
    pub mode: Option<String>,
    /// Permission policy: ask, approve-reads or deny-all (``AGENT_POLICIES``).
    pub policy: Option<String>,
    /// The chat's folder, absolute; the caller's folder when absent.
    pub cwd: Option<String>,
    /// A first prompt, the chat's own (as a person types it into New Agent Chat).
    pub prompt: Option<String>,
    /// The new workspace goes first in the sidebar (below Home), whatever
    /// `workspaces.newPlacement` says (`--top`, #29875).
    pub top: bool,
}

const NEW_USAGE: &str = "agents chat new [--workspace <ws>|--pane <pane>|--top] [--harness <h>] \
     [--model <m>] [--effort <e>] [--mode <m>] [--policy <p>] [--cwd <dir>] [--name <n>] \
     [--] [<prompt>]";

/// `chat new ...` (the words after `new`).
pub(in crate::cli) fn parse_new(words: &[&str]) -> Result<NewChat, UsageError> {
    let mut chat = NewChat::default();
    let mut index = 0;
    while let Some(&word) = words.get(index) {
        if word == "--" {
            let rest = words.get(index + 1..).unwrap_or_default();
            match rest {
                [] => {}
                [text] => chat.prompt = Some((*text).to_owned()),
                _ => {
                    return Err(UsageError::new(
                        "agents chat new: give the prompt as one quoted argument after --",
                    ));
                }
            }
            break;
        }
        if !word.starts_with("--") {
            if index + 1 != words.len() {
                return Err(UsageError::new(format!(
                    "agents chat new: unexpected argument {word:?}; usage: {NEW_USAGE}"
                )));
            }
            chat.prompt = Some(word.to_owned());
            break;
        }
        if word == "--top" {
            chat.top = true;
            index += 1;
            continue;
        }
        let (flag, inline) = match word.split_once('=') {
            Some((flag, value)) => (flag, Some(value)),
            None => (word, None),
        };
        let value = match inline {
            Some(value) => value,
            None => {
                index += 1;
                *words.get(index).ok_or_else(|| {
                    UsageError::new(format!("agents chat new: {flag} needs a value"))
                })?
            }
        };
        if value.is_empty() {
            return Err(UsageError::new(format!("agents chat new: {flag} needs a value")));
        }
        let slot = match flag {
            "--workspace" => &mut chat.workspace,
            "--pane" => &mut chat.pane,
            "--name" => &mut chat.name,
            "--harness" => &mut chat.harness,
            "--model" => &mut chat.model,
            "--effort" => &mut chat.effort,
            "--mode" => &mut chat.mode,
            "--policy" => &mut chat.policy,
            "--cwd" => &mut chat.cwd,
            other => {
                return Err(UsageError::new(format!(
                    "agents chat new: unknown flag {other:?}; usage: {NEW_USAGE}"
                )));
            }
        };
        *slot = Some(value.to_owned());
        index += 1;
    }
    if chat.workspace.is_some() && chat.pane.is_some() {
        return Err(UsageError::new("agents chat new: name --workspace or --pane, not both"));
    }
    if chat.top && (chat.workspace.is_some() || chat.pane.is_some()) {
        return Err(UsageError::new(
            "agents chat new: --top places a new workspace; it does not go with --workspace or --pane",
        ));
    }
    // A policy that approves edits or everything without asking is a person's choice in
    // cmux; an agent may only start chats that ask, approve reads, or deny.
    if let Some(policy) = &chat.policy
        && !AGENT_POLICIES.contains(&policy.as_str())
    {
        return Err(UsageError::new(format!(
            "agents chat new: --policy {policy:?} is chosen by a person in cmux; an agent may \
             pick {}",
            AGENT_POLICIES.join(", ")
        )));
    }
    if let Some(cwd) = &chat.cwd
        && !cwd.starts_with('/')
    {
        return Err(UsageError::new("agents chat new: --cwd must be an absolute folder"));
    }
    if let Some(prompt) = &chat.prompt {
        super::super::agent_message::read_body(super::super::agent_message::Body::Text(
            prompt.clone(),
        ))
        .map_err(|error| UsageError::new(format!("agents chat new: {}", error.0)))?;
    }
    Ok(chat)
}

fn not_run(code: &str, message: impl Into<String>) -> CallFailure {
    CallFailure {
        kind: FailureKind::NotRun,
        error: json!({"code": code, "message": message.into(), "details": {},
                      "retryable": false}),
        idempotency_key: None,
    }
}

/// Where a new chat goes: its workspace's key (for the chat's
/// `CMUX_WORKSPACE_ID`), the pane, and the `agent.openSessionWorkspace` arguments that
/// name the place.
struct Place {
    /// The workspace's key, for the chat's `CMUX_WORKSPACE_ID`.
    key: String,
    /// The pane (`pane_` id) the tab opens in (`agent.openSessionTab`); None: the app makes a
    /// new workspace for it (`agent.openSessionWorkspace`), and a chat it never shows reaches
    /// nothing.
    pane: Option<String>,
    arguments: Map<String, Value>,
}

impl Place {
    fn new_workspace(&self) -> bool {
        self.pane.is_none()
    }
}

fn place(global: &GlobalArgs, chat: &NewChat) -> Result<Place, CallFailure> {
    let mut arguments = Map::new();
    if chat.workspace.is_none() && chat.pane.is_none() {
        // A new workspace whose key the chat knows before the app makes it.
        let key = uuid::Uuid::new_v4().to_string();
        arguments.insert("key".into(), json!(key));
        if let Some(name) = &chat.name {
            arguments.insert("name".into(), json!(name));
        }
        if let Some(cwd) = &chat.cwd {
            arguments.insert("cwd".into(), json!(cwd));
        }
        if chat.top {
            arguments.insert("placement".into(), json!("top"));
        }
        return Ok(Place { key, pane: None, arguments });
    }
    let snapshot = mcp::agent_resource(global, super::snapshot_plan())
        .map_err(|error| CallFailure { kind: FailureKind::NotRun, error, idempotency_key: None })?;
    let list =
        |name: &str| snapshot.get(name).and_then(Value::as_array).cloned().unwrap_or_default();
    let (workspaces, screens, panes) = (list("workspaces"), list("screens"), list("panes"));
    let by_id = |items: &[Value], id: &Value| items.iter().find(|item| &item["id"] == id).cloned();
    // The app gets the ids the snapshot names, never the caller's spelling.
    let (scope, found) = match (&chat.workspace, &chat.pane) {
        (Some(id), _) => {
            let workspace = workspaces.iter().find(|workspace| {
                workspace["id"] == id.as_str()
                    || workspace["extra"]["key"]
                        .as_str()
                        .is_some_and(|key| chat::workspace_key(key) == chat::workspace_key(id))
            });
            // Its focused pane, else its first.
            let found = workspace.and_then(|workspace| {
                let own: Vec<&Value> = panes
                    .iter()
                    .filter(|pane| {
                        by_id(&screens, &pane["screen_id"])
                            .is_some_and(|screen| screen["workspace_id"] == workspace["id"])
                    })
                    .collect();
                let pane = own.iter().find(|pane| pane["focused"] == true).or(own.first())?;
                Some((workspace.clone(), pane["id"].clone()))
            });
            ("workspace", found)
        }
        (None, Some(id)) => {
            // A pane names its screen, and the screen its workspace.
            let pane = panes.iter().find(|pane| pane["id"] == id.as_str());
            let found = pane.and_then(|pane| {
                let screen = by_id(&screens, &pane["screen_id"])?;
                let workspace = by_id(&workspaces, &screen["workspace_id"])?;
                Some((workspace, pane["id"].clone()))
            });
            ("pane", found)
        }
        // Handled above (a new workspace); answered as usage, never a panic.
        (None, None) => return Err(not_run("usage.invalid", "name --workspace or --pane")),
    };
    let target = chat.workspace.as_deref().or(chat.pane.as_deref()).unwrap_or_default();
    let named = found.and_then(|(workspace, id)| {
        Some((workspace["extra"]["key"].as_str()?.to_owned(), id.as_str()?.to_owned()))
    });
    let Some((key, id)) = named else {
        return Err(CallFailure {
            kind: FailureKind::NotRun,
            error: json!({"code": "selector.not_found",
                          "message": format!("no {scope} {target:?} in this cmux session"),
                          "details": {"scope": scope, "selector": target},
                          "retryable": false}),
            idempotency_key: None,
        });
    };
    Ok(Place { key, pane: Some(id), arguments })
}

/// A workspace key in the dashed UUID form acpmux takes for
/// `CMUX_WORKSPACE_ID`.
fn uuid_form(key: &str) -> String {
    let hex: String = key.chars().filter(char::is_ascii_hexdigit).collect();
    if hex.len() != 32 {
        return key.to_owned();
    }
    let dashed = || {
        let (time_low, rest) = hex.split_at_checked(8)?;
        let (time_mid, rest) = rest.split_at_checked(4)?;
        let (time_high, rest) = rest.split_at_checked(4)?;
        let (clock, node) = rest.split_at_checked(4)?;
        Some([time_low, time_mid, time_high, clock, node].join("-"))
    };
    dashed().unwrap_or_else(|| key.to_owned())
}

/// `chat new`: the chat, its tab, and its first prompt.
pub(in crate::cli) fn new(
    global: &GlobalArgs,
    chat: &NewChat,
    origin: &str,
) -> Result<Value, CallFailure> {
    // The app's own acpmux when the caller's is another one (a Chief turn): the chat is one
    // of the app's ordinary chats, as New Agent Chat makes, not a subagent of the caller's.
    let app_socket = chat::app_acpmux(global);
    let socket = app_socket.as_deref();
    let place = place(global, chat)?;
    let cwd = match &chat.cwd {
        Some(cwd) => cwd.clone(),
        None => std::env::current_dir()
            .map_err(|error| not_run("usage.invalid", format!("no current folder: {error}")))?
            .to_string_lossy()
            .into_owned(),
    };
    let mut meta = Map::new();
    for (name, value) in [
        ("harness", &chat.harness),
        ("model", &chat.model),
        ("effort", &chat.effort),
        ("mode", &chat.mode),
        ("policy", &chat.policy),
        ("name", &chat.name),
    ] {
        if let Some(value) = value {
            meta.insert(name.into(), json!(value));
        }
    }
    meta.insert("env".into(), json!({"CMUX_WORKSPACE_ID": uuid_form(&place.key)}));
    let created = chat::acp::new_session(&cwd, Value::Object(meta), socket).map_err(|error| {
        not_run("chat.create_failed", format!("cannot start the chat: {error}"))
    })?;
    let session = created["sessionId"].as_str().unwrap_or_default().to_owned();
    if session.is_empty() {
        return Err(not_run(
            "chat.create_failed",
            format!("acpmux answered no session: {created}"),
        ));
    }
    let mut result = json!({
        "chat": session,
        "name": created.pointer("/_meta/acpmux/name").cloned().unwrap_or(Value::Null),
        "harness": created.pointer("/_meta/acpmux/harness").cloned().unwrap_or(Value::Null),
    });

    // The tab, in the background: neither action takes focus for a script's run.
    let new_workspace = place.new_workspace();
    let pane = place.pane;
    // The app takes cli, mcp, script or remote; `agents` is this surface's receipt label.
    let app_origin = if origin == "mcp" { "mcp" } else { "cli" };
    // A pane: `agent.openSessionTab` adds the tab there (shown or not) and keeps the person's
    // selected tab; none: `agent.openSessionWorkspace` makes the workspace.
    let action = if pane.is_some() { "agent.openSessionTab" } else { "agent.openSessionWorkspace" };
    let mut params = app::action_run_params(action, ActionName::Any, app_origin);
    if let Some(pane) = &pane {
        params.insert("target".into(), json!(format!("pane:{pane}")));
    }
    let mut arguments = place.arguments;
    arguments.insert("session".into(), json!(session));
    params.insert("args".into(), Value::Object(arguments));
    params.insert("background".into(), json!(true));
    // No key: a retry starts another chat, so it must not get the first one's tab.
    match mcp::agent_app(
        global,
        "action.run",
        Value::Object(params),
        app::WAITING_RUN_TIMEOUT,
        None,
    ) {
        Ok(run) => {
            result.set("opened", json!(true));
            for field in ["tab", "pane", "workspace"] {
                if let Some(value) = run["result"].get(field).filter(|value| !value.is_null())
                    && let Some(result) = result.as_object_mut()
                {
                    result.insert(field.to_owned(), value.clone());
                }
            }
        }
        // The app took the run but did not answer in time: the tab may still come (a slow
        // agent tab create), so the chat stays and the receipt says so.
        Err(error) if matches!(error["code"].as_str(), Some("timeout" | "app.transport")) => {
            result.set("opened", json!("pending"));
            result.set("open_error", error);
        }
        Err(error) if new_workspace => {
            // No workspace has the chat's key, so no chat verb could ever reach it: it ends.
            let _ = chat::acp::kill(&session, socket);
            return Err(CallFailure { kind: FailureKind::NotRun, error, idempotency_key: None });
        }
        Err(error) => {
            // The chat runs in that workspace and `chat send|read` reach it; the receipt
            // says why no tab shows it, so the caller can `agent open` it later.
            result.set("opened", json!(false));
            result.set("open_error", error);
        }
    }

    // The first prompt goes in as the chat's own, as a person types it into New Agent Chat
    // and presses Return (a chat this caller just started, as `cmux acp new PROMPT` does).
    if let Some(prompt) = &chat.prompt {
        let id = uuid::Uuid::new_v4().to_string();
        result.set(
            "prompt",
            match chat::acp::prompt(&session, prompt, &id, None, socket) {
                Ok(_) => json!({"state": "accepted", "prompt_id": id}),
                Err(error) => json!({"state": "failed", "prompt_id": id, "error": error}),
            },
        );
    }
    Ok(json!({
        "schema_version": 1,
        "action": "chat.new",
        "origin": origin,
        "result": result,
    }))
}

/// `chat state <chat>`: what the chat is doing, from `_acpmux/info`.
pub(in crate::cli) fn state(global: &GlobalArgs, target: &str) -> Result<Value, CallFailure> {
    let found = chat::scoped_chat(global, target)?;
    let chat = &found.id;
    let (_, info) = chat::acp::lookup(chat, found.socket()).map_err(|error| {
        not_run("chat.unavailable", format!("cannot read chat {chat}: {error}"))
    })?;
    let mut state = Map::new();
    state.insert("chat".into(), json!(chat));
    for (from, to) in [
        ("name", "name"),
        ("status", "status"),
        ("harness", "harness"),
        ("model", "model"),
        ("currentModeId", "mode"),
        ("effort", "effort"),
        ("policy", "policy"),
        ("cwd", "cwd"),
        ("pendingPermissions", "pending_permissions"),
        ("queued", "queued"),
    ] {
        if let Some(value) = info.get(from).filter(|value| !value.is_null()) {
            state.insert(to.into(), value.clone());
        }
    }
    // acpmux clears the turn before it reports the turn's end, then sets the status.
    let running = info.get("turn").is_some_and(|turn| !turn.is_null());
    state.insert("running".into(), json!(running));
    Ok(json!({"schema_version": 1, "action": "chat.state", "result": state}))
}

/// `chat interrupt <chat>`: cancels its running turn.
pub(in crate::cli) fn interrupt(
    global: &GlobalArgs,
    target: &str,
    origin: &str,
) -> Result<Value, CallFailure> {
    let found = chat::scoped_chat(global, target)?;
    let chat = &found.id;
    chat::refuse_own_chat(chat, target)?;
    chat::acp::cancel(chat, found.socket()).map_err(|error| {
        not_run("chat.unavailable", format!("cannot interrupt {chat}: {error}"))
    })?;
    Ok(json!({
        "schema_version": 1,
        "action": "chat.interrupt",
        "origin": origin,
        "result": {"chat": chat, "state": "cancel_requested"},
    }))
}
