//! `cmux agents chat send|read` and the `agents_chat_send` and
//! `agents_chat_read` tools (bead cx-ncc.96): one agent prompts another
//! agent chat and reads its transcript.
//!
//! A send is an agent message (agent_message.rs): the daemon stores it
//! under its policy and limits (sender, workspace rule, burst, duplicates),
//! then it reaches the chat as an acpmux `session/prompt` whose id is the
//! message id and whose `_meta.acpmux.provenance` names the sender, so the
//! chat shows it as another agent's message, never as the person's words.
//! The prompt text says the same thing to the receiving agent
//! (`agent_message_prompt::render`).
//!
//! Every chat verb reaches only chats of this cmux session (in the caller's
//! acpmux, or the app's own when that is another one, `scoped_chat`): a chat whose acpmux
//! session runs in one of the session's workspaces (`sessionEnv.
//! CMUX_WORKSPACE_ID`, as the daemon's agent message policy reads it). A
//! send never goes to the caller's own chat.
//!
//! Waiting for a reply is `agents_wait` (`until: idle`, the chat as
//! target, `agents/wait.rs`); then read on from the last `next_after`.
//!
//! `new`, `state`, `interrupt` and `continue` (#23026) live in
//! `chat_control.rs`.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

use serde_json::{Map, Value, json};

use super::super::agent_message::{self, Body, MessagePlan};
use super::super::mcp::{self, CallFailure, FailureKind};
use super::super::{GlobalArgs, UsageError, wire};
use cmux_json::JsonSet as _;

/// Items one read returns by default and at most.
pub(in crate::cli) const DEFAULT_READ_LIMIT: usize = 50;
pub(in crate::cli) const MAX_READ_LIMIT: usize = 200;
/// Text one item carries; longer text is cut and marked `truncated`.
const MAX_ITEM_TEXT_BYTES: usize = 8 * 1024;
/// Text one read carries in all, so a page fits an MCP result.
const MAX_READ_TEXT_BYTES: usize = 160 * 1024;
/// acpmux events one read takes per request, and requests per read.
const EVENT_PAGE: u64 = 500;
const MAX_EVENT_PAGES: usize = 20;
/// The most event pages [`turn_items`] reads for one turn.
const MAX_TURN_PAGES: usize = 100;

/// One `cmux agents chat` verb.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(in crate::cli) enum ChatCommand {
    Send {
        target: String,
        text: String,
        /// `--attach` files: an agent message carries text only, so a send with any is refused
        /// (`chat.attach_send_unsupported`) and names `chat new --attach`.
        attach: Vec<String>,
    },
    Read {
        target: String,
        after: u64,
        limit: usize,
    },
    /// Start a GUI agent chat (chat_control.rs); boxed, as the largest variant by far.
    New(Box<super::chat_control::NewChat>),
    /// What a chat is doing.
    State {
        target: String,
    },
    /// Cancel a chat's running turn.
    Interrupt {
        target: String,
    },
}

/// `chat send <chat> [--] <text>`, `chat read <chat> [--after N]
/// [--limit N]`, `chat new ...`, `chat state <chat>`, `chat interrupt
/// <chat>` and `chat continue <chat> [[--] <text>]` (the words after `chat`).
pub(in crate::cli) fn parse(words: &[&str]) -> Result<ChatCommand, UsageError> {
    match words {
        ["new", rest @ ..] => {
            super::chat_control::parse_new(rest).map(|chat| ChatCommand::New(Box::new(chat)))
        }
        ["state", target] => Ok(ChatCommand::State { target: chat_word(target)? }),
        ["interrupt", target] => Ok(ChatCommand::Interrupt { target: chat_word(target)? }),
        // A nudge: a send whose text defaults to "Continue.".
        ["continue", target] => Ok(ChatCommand::Send {
            target: chat_word(target)?,
            text: super::chat_control::CONTINUE_TEXT.to_owned(),
            attach: Vec::new(),
        }),
        ["continue", target, rest @ ..] => {
            let mut words = vec!["send", *target];
            words.extend_from_slice(rest);
            parse(&words)
        }
        ["send", target, rest @ ..] => {
            let target = chat_word(target)?;
            let (attach, rest) = super::chat_control::take_attach(rest, "agents chat send")?;
            // One argument: cmux reads its own flags (`--session`, `--json`)
            // anywhere before `--`, so unquoted words could lose one to it.
            let text = match rest {
                ["--", text] => *text,
                [text] if !text.starts_with('-') => *text,
                [text] if *text != "--" => {
                    return Err(UsageError::new(
                        "agents chat send: put text that starts with a dash after --",
                    ));
                }
                _ => {
                    return Err(UsageError::new(
                        "agents chat send: give the text as one quoted argument, or after --",
                    ));
                }
            };
            // The body rules of `cmux agent message`: not empty, at most 32 KiB.
            let text = agent_message::read_body(Body::Text(text.to_owned()))
                .map_err(|error| UsageError::new(format!("agents chat send: {}", error.0)))?;
            Ok(ChatCommand::Send { target, text, attach })
        }
        ["read", target, rest @ ..] => {
            let target = chat_word(target)?;
            let mut after = 0;
            let mut limit = DEFAULT_READ_LIMIT;
            let mut index = 0;
            while index < rest.len() {
                let (flag, inline) = match rest[index].split_once('=') {
                    Some((flag, value)) => (flag, Some(value)),
                    None => (rest[index], None),
                };
                let value = match inline {
                    Some(value) => value,
                    None => {
                        index += 1;
                        rest.get(index).copied().ok_or_else(|| {
                            UsageError::new(format!("agents chat read: {flag} needs a value"))
                        })?
                    }
                };
                match flag {
                    "--after" => {
                        after = value.parse().map_err(|_| {
                            UsageError::new("agents chat read: --after must be an item id")
                        })?;
                    }
                    "--limit" => {
                        limit = value
                            .parse()
                            .ok()
                            .filter(|limit| (1..=MAX_READ_LIMIT).contains(limit))
                            .ok_or_else(|| {
                                UsageError::new(format!(
                                    "agents chat read: --limit must be from 1 to {MAX_READ_LIMIT}"
                                ))
                            })?;
                    }
                    other => {
                        return Err(UsageError::new(format!(
                            "agents chat read: unexpected argument {other:?}"
                        )));
                    }
                }
                index += 1;
            }
            Ok(ChatCommand::Read { target, after, limit })
        }
        _ => Err(UsageError::new(
            "agents chat: use `chat new [flags] [<prompt>]`, `chat send <chat> <text>`, \
             `chat read <chat> [--after N] [--limit N]`, `chat state <chat>`, \
             `chat interrupt <chat>` or `chat continue <chat> [<text>]`",
        )),
    }
}

fn chat_word(target: &str) -> Result<String, UsageError> {
    if target.is_empty() || target.starts_with('-') {
        return Err(UsageError::new("agents chat: name the chat (its acpmux session id or name)"));
    }
    Ok(target.strip_prefix("acp:").unwrap_or(target).to_owned())
}

/// Runs one chat verb for the CLI and the MCP tools alike. `origin` names
/// the caller in the receipt (`agents` for the CLI, `mcp` for tools).
pub(in crate::cli) fn run(
    global: &GlobalArgs,
    command: &ChatCommand,
    idempotency_key: Option<&str>,
    origin: &str,
) -> Result<Value, CallFailure> {
    match command {
        ChatCommand::Send { attach, .. } if !attach.is_empty() => {
            Err(super::chat_control::attach_send_unsupported())
        }
        ChatCommand::Send { target, text, .. } => {
            send(global, target, text, idempotency_key, origin)
        }
        ChatCommand::Read { target, after, limit } => read(global, target, *after, *limit),
        ChatCommand::New(chat) => super::chat_control::new(global, chat, origin),
        ChatCommand::State { target } => super::chat_control::state(global, target),
        ChatCommand::Interrupt { target } => super::chat_control::interrupt(global, target, origin),
    }
}

fn not_run(code: &str, message: impl Into<String>, details: Value) -> CallFailure {
    CallFailure {
        kind: FailureKind::NotRun,
        error: json!({"code": code, "message": message.into(), "details": details,
                      "retryable": false}),
        idempotency_key: None,
    }
}

/// A chat a verb reaches: its acpmux session id, and the app's acpmux socket when the chat runs
/// there and not in the caller's own acpmux (read, state and interrupt reach it there; a send
/// goes through the daemon, whose acpmux it is).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(in crate::cli) struct Chat {
    pub id: String,
    pub app: Option<PathBuf>,
}

impl Chat {
    /// The acpmux to reach this chat at: the app's, else the caller's own.
    pub(in crate::cli) fn socket(&self) -> Option<&Path> {
        self.app.as_deref()
    }
}

/// The chat this process's `chat new` started here, in a workspace of this cmux session
/// (`chat_control::new`), and the acpmux it runs in.
static STARTED: std::sync::Mutex<Option<Chat>> = std::sync::Mutex::new(None);

/// Notes `chat` as the one this process just started in a workspace of this cmux session.
pub(in crate::cli) fn note_started(chat: Chat) {
    *STARTED.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(chat);
}

/// The chat this process last started here ([`note_started`]), whatever its id: the hybrid
/// start (chat_start/hybrid_start.rs) hands it to the driver that moves it to Cloud.
pub(in crate::cli) fn last_started() -> Option<Chat> {
    STARTED.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone()
}

/// The chat `id` names when this process started it here ([`note_started`]): its scope is
/// known and its acpmux too, so `cmux chat --prompt … --wait` reaches it with no lookup, no
/// app call and no session snapshot (goal local-instant-start).
pub(in crate::cli) fn started(id: &str) -> Option<Chat> {
    STARTED
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .as_ref()
        .filter(|chat| chat.id == id)
        .cloned()
}

/// The chat `target` names (an id, a name or a unique prefix), when it is a chat of this cmux
/// session: its acpmux session runs in one of the session's workspaces (`sessionEnv.
/// CMUX_WORKSPACE_ID`). It is looked up in the caller's own acpmux, then in the cmux app's own
/// (`agent.acpmux`) when that is another one, as a Chief turn's is (its home's; its `cmux`
/// calls reach the app's daemon session, #23026). Either way the same scope check applies.
pub(super) fn scoped_chat(global: &GlobalArgs, target: &str) -> Result<Chat, CallFailure> {
    let not_found = |error: String| {
        not_run(
            "selector.not_found",
            format!("no agent chat matches {target:?}: {error}"),
            json!({"scope": "chat", "selector": target}),
        )
    };
    let ((chat, info), app) = match acp::lookup(target, None) {
        Ok(found) => (found, None),
        Err(error) => {
            let Some(app) = app_acpmux(global) else { return Err(not_found(error)) };
            (acp::lookup(target, Some(&app)).map_err(not_found)?, Some(app))
        }
    };
    let workspace =
        info.pointer("/sessionEnv/CMUX_WORKSPACE_ID").and_then(Value::as_str).map(workspace_key);
    let snapshot = session_snapshot(global)?;
    let in_workspace =
        workspace.as_ref().is_some_and(|key| session_workspace_keys(&snapshot).contains(key));
    // A chat that came here by a move (Bring Back Local, `cmux link agent move`) runs with no
    // workspace in its env: the move's guard clears the env it brought (`transfer_guard.rs`), and
    // the app shows it in a workspace it opened for it. Its tab there puts it in this session.
    if !in_workspace && !shown_in_session(global, &snapshot, &chat) {
        return Err(not_run(
            "chat.out_of_scope",
            format!("chat {chat} does not run in a workspace of this cmux session"),
            json!({"scope": "chat", "selector": target, "chat": chat}),
        ));
    }
    Ok(Chat { id: chat, app })
}

/// The socket of the acpmux the cmux app's own chats use (`agent.acpmux`), when the app
/// answers and it is not the one `cmux acp` reaches from here; None otherwise.
pub(in crate::cli) fn app_acpmux(global: &GlobalArgs) -> Option<PathBuf> {
    let answer =
        mcp::agent_app(global, "agent.acpmux", json!({}), super::super::app::READ_TIMEOUT, None)
            .ok()?;
    let app = PathBuf::from(answer["socket_path"].as_str().filter(|path| !path.is_empty())?);
    // One daemon can be named two ways (`/tmp` and `/private/tmp`, a relative path).
    let same = |path: &Path| std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    (same(&acp::own_socket()) != same(&app)).then_some(app)
}

/// The peers of the acpmux `chat new` starts chats in (the app's own, else the one `cmux acp`
/// reaches): its `_acpmux/peers` answer, the machines New Agent Chat's Environment picker lists.
pub(in crate::cli) fn chat_peers(global: &GlobalArgs) -> Result<Value, String> {
    acp::peers(app_acpmux(global).as_deref())
}

/// Where the acpmux the app's chats use would place new work (`_acpmux/place`): a new chat's Auto
/// reads this Mac's room from it (`chat_start/auto_place.rs`).
pub(in crate::cli) fn chat_place_verdict(global: &GlobalArgs) -> Result<Value, String> {
    acp::place(app_acpmux(global).as_deref())
}

/// A workspace key in one comparable form: lowercase, without dashes (the
/// app hands sessions the key's uppercase UUID form). As the daemon's
/// `agent_message_policy::workspace_key`.
pub(super) fn workspace_key(value: &str) -> String {
    value.chars().filter(|ch| *ch != '-').flat_map(char::to_lowercase).collect()
}

/// This cmux session's snapshot (its workspaces and tabs), as `agents_snapshot` reads it from
/// the daemon.
fn session_snapshot(global: &GlobalArgs) -> Result<Value, CallFailure> {
    mcp::agent_resource(global, super::snapshot_plan()).map_err(|error| CallFailure {
        kind: FailureKind::NotRun,
        error,
        idempotency_key: None,
    })
}

/// The keys of this cmux session's workspaces (`extra.key`), from its daemon snapshot.
fn session_workspace_keys(snapshot: &Value) -> HashSet<String> {
    snapshot["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|workspace| workspace["extra"]["key"].as_str())
        .map(workspace_key)
        .collect()
}

/// Whether a tab of this cmux session shows chat `chat`: a workspace of the app's topology
/// (`snapshot.get`) whose tabs show the chat (`agent_session`), and that workspace one of this
/// session's (the daemon snapshot's, which holds only this session's workspaces). No app (CI, a
/// headless agent): no tab shows it.
fn shown_in_session(global: &GlobalArgs, snapshot: &Value, chat: &str) -> bool {
    let Ok(app) =
        mcp::agent_app(global, "snapshot.get", json!({}), super::super::app::READ_TIMEOUT, None)
    else {
        return false;
    };
    let Some(topology) = app.get("topology") else { return false };
    shown_in_workspace(snapshot, topology, chat)
}

/// [`shown_in_session`]'s check on the two snapshots: the daemon's SNAPSHOT of this session and
/// the app's TOPOLOGY.
pub(super) fn shown_in_workspace(snapshot: &Value, topology: &Value, chat: &str) -> bool {
    fn shows(value: &Value, chat: &str) -> bool {
        match value {
            Value::Object(object) => {
                object
                    .get("agent_session")
                    .and_then(Value::as_str)
                    .is_some_and(|session| session.strip_prefix("acp:").unwrap_or(session) == chat)
                    || object.values().any(|child| shows(child, chat))
            }
            Value::Array(values) => values.iter().any(|value| shows(value, chat)),
            _ => false,
        }
    }
    let ours: HashSet<&str> = snapshot["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|workspace| workspace["id"].as_str())
        .collect();
    topology["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|workspace| workspace["id"].as_str().is_some_and(|id| ours.contains(id)))
        .any(|workspace| shows(workspace, chat))
}

/// The caller's own chat: the acpmux session acpmux started it in.
fn own_chat() -> Option<String> {
    ["CMUX_AGENT_SESSION", "ACPMUX_SESSION_ID"]
        .into_iter()
        .find_map(|name| std::env::var(name).ok().filter(|value| !value.trim().is_empty()))
}

/// The name the caller's own chat goes by, sent as its message's sender name. The daemon knows
/// a chat's sender only by its launch credential, which a chat the app's acpmux starts lacks
/// (that acpmux has no `CMUX_TUI_SOCKET` to mint one), so without a name the receiving chat
/// showed every chat's message, a Chief's too, as `cli`, the person's shell
/// (manaflow-ai/cmux#51004). A name claims what `--from` claims and proves nothing more: the
/// daemon still treats the send as unverified. None from a shell, which has no chat.
fn own_sender_name() -> Option<String> {
    let own = own_chat()?;
    let (_, info) = acp::lookup(&own, None).ok()?;
    sender_name_of(&info)
}

/// The longest sender name the daemon stores (cmux-tui-core `MAX_SENDER_NAME_CHARS`) and acpmux
/// shows (`prompt_provenance` `MAX_NAME_CHARS`).
const MAX_SENDER_NAME_CHARS: usize = 64;

/// A chat's shown name from its `_acpmux/info`: its `mux.label` (a Chief turn's: the Chief's own
/// name, optchat-chief `acpmux::turn_tags`), else its name; one line, spaces collapsed, at most
/// [`MAX_SENDER_NAME_CHARS`] characters. A Chief turn's session name (`optchat-<home>-<n>`) is
/// never shown.
fn sender_name_of(info: &Value) -> Option<String> {
    let shown = |value: &Value| {
        let words: Vec<&str> = value
            .as_str()?
            .split(|c: char| c.is_whitespace() || c.is_control())
            .filter(|word| !word.is_empty())
            .collect();
        let line = words.join(" ");
        let line: String =
            line.chars().filter(|c| !format_mark(*c)).take(MAX_SENDER_NAME_CHARS).collect();
        let line = line.trim().to_owned();
        (!line.is_empty()).then_some(line)
    };
    info.pointer("/tags/mux.label").and_then(shown).or_else(|| shown(&info["name"]))
}

/// A bidi or zero-width format mark, which acpmux refuses in a provenance name.
fn format_mark(c: char) -> bool {
    matches!(
        c,
        '\u{200B}'..='\u{200F}' | '\u{202A}'..='\u{202E}' | '\u{2066}'..='\u{2069}' | '\u{FEFF}'
    )
}

/// Refuses `chat` when it is the caller's own: a chat never prompts or
/// interrupts itself.
pub(super) fn refuse_own_chat(chat: &str, target: &str) -> Result<(), CallFailure> {
    if let Some(own) = own_chat()
        && (own == chat || acp::lookup(&own, None).is_ok_and(|(id, _)| id == chat))
    {
        return Err(not_run(
            "chat.own_chat",
            "a chat cannot prompt or interrupt itself; name another chat",
            json!({"scope": "chat", "selector": target, "chat": chat}),
        ));
    }
    Ok(())
}

fn send(
    global: &GlobalArgs,
    target: &str,
    text: &str,
    idempotency_key: Option<&str>,
    origin: &str,
) -> Result<Value, CallFailure> {
    let found = scoped_chat(global, target)?;
    refuse_own_chat(&found.id, target)?;
    let chat = found.id;
    let key = match idempotency_key {
        Some(key) => key.to_owned(),
        None => wire::random_idempotency_key()
            .map_err(|error| not_run("usage.invalid", error.0, json!({})))?,
    };
    let recipient = format!("acp:{chat}");
    // The daemon stores the message under its policy and its pump hands it to the chat in the
    // daemon's acpmux, the app's own for a chat found there (`Chat::app`).
    let plan = MessagePlan {
        target: Some(recipient.clone()),
        body: Body::Text(text.to_owned()),
        from: own_sender_name(),
        thread: None,
        reply_to: None,
        idempotency_key: Some(key.clone()),
        target_resolved: true,
    };
    let sent =
        agent_message::send_and_deliver(global, &plan, text.to_owned()).map_err(|failure| {
            let (kind, error) = match failure {
                super::super::resolve::Failure::Resource(error) => (FailureKind::Rejected, error),
                super::super::resolve::Failure::Local { error, .. } => (FailureKind::NotRun, error),
                // The message may be stored: retrying with the key is safe.
                super::super::resolve::Failure::Transport(message) => (
                    FailureKind::InProgress,
                    json!({"code": "transport.failed", "message": message, "details": {},
                           "retryable": true}),
                ),
                super::super::resolve::Failure::Refused => (
                    FailureKind::NotRun,
                    json!({"code": "session.busy", "message": "session is busy", "details": {},
                           "retryable": true}),
                ),
                super::super::resolve::Failure::AppAction { action, .. } => (
                    FailureKind::NotRun,
                    json!({"code": "usage.invalid", "message": format!("{action} is an app action"),
                           "details": {}, "retryable": false}),
                ),
            };
            CallFailure { kind, error, idempotency_key: Some(key.clone()) }
        })?;
    let delivery = sent.message["deliveries"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|delivery| delivery["recipient"] == recipient.as_str());
    let mut result = json!({
        "chat": chat,
        "message_id": sent.message["id"],
        "state": delivery.map_or(Value::Null, |delivery| delivery["state"].clone()),
    });
    if let Some(reason) =
        delivery.and_then(|delivery| delivery.get("reason")).filter(|r| !r.is_null())
    {
        result.set("reason", reason.clone());
    }
    // Stored but not handed to the chat: the receipt says so, and the CLI
    // and the tool report it as an error (`delivery_failed`).
    if sent.failed {
        result.set("state", json!("failed"));
    }
    if !sent.problems.is_empty() {
        result.set("problems", json!(sent.problems));
    }
    Ok(json!({
        "schema_version": 1,
        "action": "chat.send",
        "origin": origin,
        "result": result,
        "idempotency_key": key,
    }))
}

/// Whether a `chat.send` receipt reports a message that was stored but
/// could not be handed to its chat.
pub(in crate::cli) fn delivery_failed(receipt: &Value) -> bool {
    (receipt["action"] == "chat.send" && receipt["result"]["state"] == "failed")
        || (receipt["action"] == "chat.new" && receipt["result"]["prompt"]["state"] == "failed")
}

fn read(global: &GlobalArgs, target: &str, after: u64, limit: usize) -> Result<Value, CallFailure> {
    let found = scoped_chat(global, target)?;
    let chat = &found.id;
    let (transcript, more, cursor) =
        load(after, limit, |cursor| acp::events(chat, cursor, EVENT_PAGE, found.socket()))
            .map_err(|error| {
                not_run("chat.unavailable", format!("cannot read chat {chat}: {error}"), json!({}))
            })?;
    Ok(transcript.page(chat, after, limit, more, cursor))
}

/// A read page (`cmux chat read`'s shape) of `events`, a chat's records oldest first that another
/// place read: a chat on a Cloud VM, whose records its machine prints (cloud_start_chat.rs
/// `read_existing`). `more_before`: older records exist that `events` does not hold.
pub(in crate::cli) fn page_of_events(
    chat: &str,
    events: &[Value],
    after: u64,
    limit: usize,
    more_before: bool,
) -> Value {
    let mut once = Some(json!({"events": events, "hasMore": false}));
    let read = load(after, limit, |_| {
        Ok(once.take().unwrap_or_else(|| json!({"events": [], "hasMore": false})))
    });
    let (transcript, more, cursor) = match read {
        Ok(read) => read,
        Err(_) => (Transcript::default(), false, after),
    };
    let mut page = transcript.page(chat, after, limit, more, cursor);
    if more_before {
        page.set("older_not_read", json!(true));
    }
    page
}

/// The transcript items of a chat already found (and scope-checked) with [`scoped_chat`] after
/// `after`, each whole (no per-item cut) and masked as a read masks them: the turn `cmux chat
/// --wait` waited on, read from its prompt on. It finds its chat once and reads it with no second
/// lookup (turn.rs).
pub(in crate::cli) fn turn_items_of(found: &Chat, after: u64) -> Result<Vec<Value>, CallFailure> {
    let chat = &found.id;
    // Every event from the turn's prompt on, not a read's page: the turn's end must be in it,
    // however much text the turn wrote. The cost is the turn's, never the whole chat's.
    let mut transcript = Transcript::default();
    let mut cursor = after.saturating_sub(1);
    let mut read_all = false;
    for _ in 0..MAX_TURN_PAGES {
        let page = acp::events(chat, cursor, EVENT_PAGE, found.socket()).map_err(|error| {
            not_run("chat.unavailable", format!("cannot read chat {chat}: {error}"), json!({}))
        })?;
        let events =
            page.get("events").and_then(Value::as_array).map(Vec::as_slice).unwrap_or_default();
        for event in events {
            transcript.apply(event);
            cursor = cursor.max(event["seq"].as_u64().unwrap_or(cursor));
        }
        if page.get("hasMore").and_then(Value::as_bool) != Some(true) || events.is_empty() {
            read_all = true;
            break;
        }
    }
    // A turn of more events than that: say so, never answer a turn without its end.
    if !read_all {
        return Err(not_run(
            "chat.turn_too_long",
            format!(
                "chat {chat}'s turn is too long to read in one answer; read it with `cmux chat read {chat}`"
            ),
            json!({"after": after}),
        ));
    }
    Ok(transcript
        .items
        .iter()
        .enumerate()
        .filter(|(_, item)| item.id > after)
        .map(|(index, item)| {
            let partial = !transcript.complete(index);
            let mut value = item.json(partial);
            // Whole: `json` cuts a read's item at 8 KiB.
            value.set("text", json!(visible_text(&item.text, partial)));
            if let Some(value) = value.as_object_mut() {
                value.remove("truncated");
            }
            value
        })
        .collect())
}

/// The transcript of the events after `after`, read a page at a time from
/// `events` (the page after a cursor), whether events remain past it, and
/// the last event read.
fn load(
    after: u64,
    limit: usize,
    mut events: impl FnMut(u64) -> Result<Value, String>,
) -> Result<(Transcript, bool, u64), String> {
    let mut transcript = Transcript::default();
    // From the event before `after`, so the item `after` names is rebuilt
    // whole and its continuation is not read as a new item.
    let mut cursor = after.saturating_sub(1);
    let mut more = true;
    for _ in 0..MAX_EVENT_PAGES {
        let page = events(cursor)?;
        let events = page["events"].as_array().cloned().unwrap_or_default();
        for event in &events {
            transcript.apply(event);
            cursor = cursor.max(event["seq"].as_u64().unwrap_or(cursor));
        }
        more = page["hasMore"] == true && !events.is_empty();
        let ready = transcript.items.iter().filter(|item| item.id > after).count();
        let full = ready > limit || transcript.text_bytes > MAX_READ_TEXT_BYTES;
        // A tool call the read returns holds `next_after` until its turn
        // ends, so the read loads on to that turn end (or the newest event,
        // for a tool in the running turn). Capping this lower strands a
        // reader on a tool whose turn end is further on: every read restarts
        // at `after` and never reaches it.
        if !more || (full && !transcript.held_on_tool(after, limit)) {
            break;
        }
    }
    Ok((transcript, more, cursor))
}

/// One transcript item as a read returns it.
#[derive(Debug)]
struct Item {
    /// The acpmux event sequence number that started it.
    id: u64,
    role: &'static str,
    text: String,
    extra: Map<String, Value>,
}

impl Item {
    fn json(&self, partial: bool) -> Value {
        let mut value = Map::new();
        value.insert("id".into(), json!(self.id));
        value.insert("role".into(), json!(self.role));
        let text = visible_text(&self.text, partial);
        let mut end = text.len().min(MAX_ITEM_TEXT_BYTES);
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        value.insert("text".into(), json!(&text[..end]));
        if end < text.len() {
            value.insert("truncated".into(), json!(true));
        }
        value.extend(self.extra.clone());
        if partial {
            value.insert("partial".into(), json!(true));
        }
        Value::Object(value)
    }
}

/// An item's text as another chat's agent may see it: every secret
/// `secret_scan` finds masked (as `cmux-sessions` masks `read_session`), so
/// a key pasted into one chat does not reach another chat's agent. Masked
/// whole, before the cut, so the cut cannot split a secret past the masker.
/// An unfinished answer drops its last word, which may be a secret only
/// partly written; it comes back whole on the next read.
fn visible_text(text: &str, partial: bool) -> String {
    let masked = acpmux::secret_scan::mask(text);
    if !partial {
        return masked;
    }
    let end = masked.rfind(char::is_whitespace).unwrap_or(0);
    masked[..end].to_owned()
}

/// A chat's acpmux events as plain items: the person's or another agent's
/// prompts (`user`), the agent's text (`assistant`, its chunks joined), each
/// tool call as one summary (`tool`: kind and status only; never its
/// title, which harnesses fill with the input, such as a command or a path,
/// nor its input or output) and each turn's end (`turn_end`). Thoughts,
/// plans and acpmux bookkeeping are left out.
#[derive(Default)]
struct Transcript {
    items: Vec<Item>,
    /// The item the next text chunk extends.
    open_text: Option<usize>,
    tools: HashMap<String, usize>,
    /// The last `turn_end` item; a tool call before it is finished.
    last_turn_end: Option<usize>,
    text_bytes: usize,
}

impl Transcript {
    fn apply(&mut self, event: &Value) {
        let seq = event["seq"].as_u64().unwrap_or(0);
        let msg = &event["msg"];
        let kind = event["kind"].as_str().unwrap_or_default();
        match event["dir"].as_str() {
            Some("mux") => match kind {
                "user_message" => {
                    let mut extra = Map::new();
                    if msg["steer"] == true {
                        extra.insert("steer".into(), json!(true));
                    }
                    // Only another agent's message; the hub's own prompts
                    // (`auto_resume`, `offer_result`) carry provenance too.
                    let provenance = &msg["_meta"]["provenance"];
                    if provenance["kind"] == "agent_message" {
                        extra.insert("origin".into(), json!("agent_message"));
                        for (from, to) in
                            [("from", "from"), ("fromName", "from_name"), ("msgId", "message_id")]
                        {
                            if let Some(value) = provenance[from].as_str() {
                                extra.insert(to.into(), json!(acpmux::secret_scan::mask(value)));
                            }
                        }
                    }
                    // Several agents' messages that went in as one turn (acpmux `hub/digest.rs`).
                    if provenance["kind"] == "agent_digest" {
                        extra.insert("origin".into(), json!("agent_digest"));
                        let senders: Vec<Value> = provenance["messages"]
                            .as_array()
                            .into_iter()
                            .flatten()
                            .filter_map(|m| m["from"].as_str())
                            .map(|from| json!(acpmux::secret_scan::mask(from)))
                            .collect();
                        extra.insert("senders".into(), Value::Array(senders));
                    }
                    let text = msg["text"].as_str().unwrap_or_default().to_owned();
                    self.push(seq, "user", text, extra);
                }
                "turn_result" => {
                    let status = msg["status"].as_str().unwrap_or("completed");
                    let mut extra = Map::new();
                    extra.insert("status".into(), json!(status));
                    self.push(seq, "turn_end", String::new(), extra);
                }
                _ => {}
            },
            Some("in") if !kind.ends_with(".replay") && msg["method"] == "session/update" => {
                // A subagent's words (`_meta.acpmux.subagent`) are its own, never the chat's answer.
                let words = matches!(
                    msg["params"]["update"]["sessionUpdate"].as_str(),
                    Some("agent_message_chunk" | "agent_thought_chunk")
                );
                if !words || msg["params"]["_meta"]["acpmux"]["subagent"].is_null() {
                    self.apply_update(seq, &msg["params"]["update"]);
                }
            }
            _ => {}
        }
    }

    fn apply_update(&mut self, seq: u64, update: &Value) {
        match update["sessionUpdate"].as_str().unwrap_or_default() {
            "agent_message_chunk" => {
                let text = update["content"]["text"].as_str().unwrap_or_default();
                match self.open_text {
                    Some(index) => {
                        self.text_bytes += text.len();
                        self.items[index].text.push_str(text);
                    }
                    None => {
                        self.push(seq, "assistant", text.to_owned(), Map::new());
                        self.open_text = Some(self.items.len() - 1);
                    }
                }
            }
            "tool_call" => {
                let id = update["toolCallId"].as_str().unwrap_or_default().to_owned();
                let tool = json!({
                    "id": id,
                    "kind": update["kind"].as_str().unwrap_or("other"),
                    "status": update["status"].as_str().unwrap_or("pending"),
                });
                let mut extra = Map::new();
                extra.insert("tool".into(), tool);
                self.push(seq, "tool", String::new(), extra);
                self.tools.insert(id, self.items.len() - 1);
            }
            "tool_call_update" => {
                let id = update["toolCallId"].as_str().unwrap_or_default();
                let Some(&index) = self.tools.get(id) else { return };
                let item = &mut self.items[index];
                if let Some(status) = update["status"].as_str() {
                    item.extra.set_path(&["tool", "status"], json!(status));
                }
            }
            _ => {}
        }
    }

    fn push(&mut self, id: u64, role: &'static str, text: String, extra: Map<String, Value>) {
        self.open_text = None;
        self.text_bytes += text.len();
        if role == "turn_end" {
            self.last_turn_end = Some(self.items.len());
        }
        self.items.push(Item { id, role, text, extra });
    }

    /// Whether item `index` is finished: an answer once another item
    /// follows it, a tool call once it completed or failed, or once its turn
    /// ended (a stopped turn, or a harness that never sent the last update).
    fn complete(&self, index: usize) -> bool {
        let item = &self.items[index];
        match item.role {
            "assistant" => self.open_text != Some(index),
            "tool" => {
                matches!(item.extra["tool"]["status"].as_str(), Some("completed" | "failed"))
                    || self.last_turn_end.is_some_and(|end| end > index)
            }
            _ => true,
        }
    }

    /// Whether a read returns an unfinished tool call, which holds its
    /// `next_after`: the read loads on, so a turn end that settles it is
    /// seen. A tool call past the returned items holds nothing.
    fn held_on_tool(&self, after: u64, limit: usize) -> bool {
        self.returned(after, limit)
            .into_iter()
            .any(|index| self.items[index].role == "tool" && !self.complete(index))
    }

    /// The indices of the items a read after `after` returns: at most
    /// `limit`, and no more once they pass `MAX_READ_TEXT_BYTES`. Counted
    /// as JSON, escapes included, so the page stays under the MCP result cap
    /// and `fit` never drops items `next_after` passed.
    fn returned(&self, after: u64, limit: usize) -> Vec<usize> {
        let mut indices = Vec::new();
        let mut bytes = 0;
        for (index, item) in self.items.iter().enumerate().filter(|(_, item)| item.id > after) {
            if indices.len() == limit || (!indices.is_empty() && bytes > MAX_READ_TEXT_BYTES) {
                break;
            }
            bytes += item.json(!self.complete(index)).to_string().len();
            indices.push(index);
        }
        indices
    }

    /// The items after `after`, at most `limit`. `next_after` never passes
    /// an unfinished item (an answer being written, a tool call running), so
    /// it is read again whole next time, with what follows it. When every
    /// item read is finished and returned, it moves to `scanned`, the last
    /// event read, so a long run of events with no item is not read again.
    fn page(&self, chat: &str, after: u64, limit: usize, more_events: bool, scanned: u64) -> Value {
        let candidates = self.items.iter().filter(|item| item.id > after).count();
        let returned = self.returned(after, limit);
        let mut items = Vec::new();
        let mut next_after = after;
        let mut settled = true;
        for &index in &returned {
            let item = &self.items[index];
            let complete = self.complete(index);
            settled &= complete;
            if settled {
                next_after = item.id;
            }
            items.push(item.json(!complete));
        }
        let returned = returned.len();
        if settled && returned == candidates {
            next_after = next_after.max(scanned);
        }
        json!({
            "schema_version": 1,
            "chat": chat,
            "items": items,
            "next_after": next_after,
            "has_more": returned < candidates || more_events,
        })
    }
}

#[cfg(unix)]
pub(in crate::cli) mod acp {
    //! The acpmux linked into this binary: the one at `socket` (the app's own, `agent.acpmux`),
    //! else the one at the home `cmux acp` uses (`ACPMUX_SOCKET` first). A chat verb never starts
    //! the acpmux daemon.

    use std::path::Path;
    use std::sync::Arc;

    use serde_json::{Value, json};

    fn block_on<T>(work: impl Future<Output = anyhow::Result<T>>) -> Result<T, String> {
        crate::acp::configure_home();
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|error| error.to_string())?
            .block_on(work)
            .map_err(|error| format!("{error:#}"))
    }

    /// The socket `cmux acp` reaches from here (`ACPMUX_SOCKET`, else its home's).
    pub(super) fn own_socket() -> std::path::PathBuf {
        crate::acp::configure_home();
        acpmux::config::socket_path()
    }

    async fn client(socket: Option<&Path>) -> anyhow::Result<Arc<acpmux::client::Client>> {
        match socket {
            Some(path) => acpmux::client::Client::connect(path).await,
            None => acpmux::deliver::connect().await,
        }
    }

    /// One runtime and one connection per acpmux for this process's reads (a lookup, a wait, a
    /// page of events), kept across calls: `cmux chat --wait` waits, reads the turn's start and
    /// reads the turn, and each read used to build a runtime and dial, hello and all, again
    /// (goal local-instant-start). Only reads share it: a prompt, a kill or a new chat keeps its
    /// own connection, which closes when it answers, as before. Statics, never dropped: its one
    /// worker drives the connections between calls and from any thread, and ends with the
    /// process.
    static READS: std::sync::OnceLock<tokio::runtime::Runtime> = std::sync::OnceLock::new();
    type Reader = (Option<std::path::PathBuf>, Arc<acpmux::client::Client>);
    static READERS: std::sync::Mutex<Vec<Reader>> = std::sync::Mutex::new(Vec::new());

    fn readers() -> std::sync::MutexGuard<'static, Vec<Reader>> {
        READERS.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// `work` on the shared connection to the acpmux at `socket` (see [`READS`]): dialed once,
    /// again once the daemon closed it (a restart, an update), and then `work` runs again.
    fn read_on<T>(
        socket: Option<&Path>,
        work: impl AsyncFn(Arc<acpmux::client::Client>) -> anyhow::Result<T>,
    ) -> Result<T, String> {
        crate::acp::configure_home();
        let runtime = match READS.get() {
            Some(runtime) => runtime,
            None => {
                let runtime = tokio::runtime::Builder::new_multi_thread()
                    .worker_threads(1)
                    .thread_name("cmux-acpmux-reads")
                    .enable_all()
                    .build()
                    .map_err(|error| error.to_string())?;
                READS.get_or_init(|| runtime)
            }
        };
        let key = socket.map(Path::to_path_buf);
        runtime
            .block_on(async {
                let known = {
                    let mut readers = readers();
                    readers.retain(|(_, client)| !client.is_closed());
                    readers.iter().find(|(at, _)| *at == key).map(|(_, client)| client.clone())
                };
                if let Some(client) = known {
                    let answer = work(client.clone()).await;
                    if answer.is_ok() || !client.is_closed() {
                        return answer;
                    }
                    readers().retain(|(_, kept)| !Arc::ptr_eq(kept, &client));
                }
                let client = client(socket).await?;
                readers().push((key.clone(), client.clone()));
                work(client).await
            })
            .map_err(|error| format!("{error:#}"))
    }

    /// The id and `_acpmux/info` of the session `key` names.
    pub(in crate::cli) fn lookup(
        key: &str,
        socket: Option<&Path>,
    ) -> Result<(String, Value), String> {
        read_on(socket, async |client| {
            let (id, _name) = acpmux::deliver::resolve_session(&client, key).await?;
            let info =
                client.request(acpmux::rpc::method::MUX_INFO, json!({"sessionId": id})).await?;
            Ok((id, info))
        })
    }

    /// Starts a chat in `cwd` with `meta` as its `_meta.acpmux`; the
    /// `session/new` reply. No `cwd`: the peer `meta` names picks the folder (`acpmux new --on`).
    pub(in crate::cli) fn new_session(
        cwd: Option<&str>,
        meta: Value,
        socket: Option<&Path>,
    ) -> Result<Value, String> {
        let mut params = json!({"mcpServers": [], "_meta": {"acpmux": meta}});
        if let (Some(cwd), Some(object)) = (cwd, params.as_object_mut()) {
            object.insert("cwd".into(), json!(cwd));
        }
        block_on(async {
            client(socket).await?.request(acpmux::rpc::method::SESSION_NEW, params).await
        })
    }

    /// The acpmux's placement verdict (`_acpmux/place`), as `acpmux machine pick` reads it.
    pub(super) fn place(socket: Option<&Path>) -> Result<Value, String> {
        block_on(async { client(socket).await?.request("_acpmux/place", json!({})).await })
    }

    /// The acpmux's peers (`_acpmux/peers`), as `acpmux host` reads them.
    pub(super) fn peers(socket: Option<&Path>) -> Result<Value, String> {
        block_on(async { client(socket).await?.request("_acpmux/peers", json!({})).await })
    }

    /// Queues `text` as a prompt of `session` and returns once acpmux accepted it (started, or
    /// queued behind a running turn), as `acpmux send --no-wait` does. With no `provenance` it
    /// is the chat's own prompt, as a person types it; with one, another agent's message
    /// (`prompt_provenance.rs`). `id` is the prompt id: a resend with it runs once.
    pub(in crate::cli) fn prompt(
        session: &str,
        text: &str,
        id: &str,
        provenance: Option<&Value>,
        socket: Option<&Path>,
    ) -> Result<Value, String> {
        block_on(async {
            let client = client(socket).await?;
            acpmux::deliver::deliver(client, session, text, id, false, provenance).await
        })
    }

    /// [`prompt`] with the files at `paths` (`acpmux::attach::blocks_for`, as `acpmux send
    /// --attach` adds them); the uploads' progress lines go to stderr.
    pub(in crate::cli) fn prompt_attached(
        session: &str,
        text: &str,
        id: &str,
        paths: &[std::path::PathBuf],
        socket: Option<&Path>,
    ) -> Result<Value, String> {
        block_on(async {
            let client = client(socket).await?;
            let say = |line: &str| eprintln!("{line}");
            acpmux::deliver::deliver_attached(client, session, text, id, false, None, paths, &say)
                .await
        })
    }

    /// Ends the session and deletes its record (`_acpmux/kill` with purge).
    pub(in crate::cli) fn kill(session: &str, socket: Option<&Path>) -> Result<(), String> {
        block_on(async {
            client(socket)
                .await?
                .request(
                    acpmux::rpc::method::MUX_KILL,
                    json!({"sessionId": session, "purge": true}),
                )
                .await?;
            Ok(())
        })
    }

    /// Cancels the session's running turn (`session/cancel`).
    pub(in crate::cli) fn cancel(session: &str, socket: Option<&Path>) -> Result<(), String> {
        block_on(async {
            client(socket)
                .await?
                .request(acpmux::rpc::method::SESSION_CANCEL, json!({"sessionId": session}))
                .await?;
            Ok(())
        })
    }

    /// `_acpmux/wait` on `session` until its turn ended, it asks for a permission or it
    /// closed, at most `timeout`: the daemon answers on the chat's own events, as `acpmux wait`
    /// does, so the caller learns of the turn's end when acpmux records it (turn.rs).
    pub(in crate::cli) fn wait_turn(
        session: &str,
        timeout: std::time::Duration,
        socket: Option<&Path>,
    ) -> Result<Value, String> {
        let timeout_ms = u64::try_from(timeout.as_millis()).unwrap_or(u64::MAX);
        read_on(socket, async |client| {
            client
                .request(
                    acpmux::rpc::method::MUX_WAIT,
                    json!({"sessions": [session], "until": ["ready", "permission", "closed"],
                           "timeoutMs": timeout_ms}),
                )
                .await
        })
    }

    /// `_acpmux/wait` on `session` until it reaches one of `until` (`running`, `ready`,
    /// `closed`, ...), at most `timeout`: the daemon answers on the chat's own events, so a
    /// waiter learns of a turn's start or end when acpmux records it, with no polling.
    pub(in crate::cli) fn wait_until(
        session: &str,
        until: &[&str],
        timeout: std::time::Duration,
        socket: Option<&Path>,
    ) -> Result<Value, String> {
        let timeout_ms = u64::try_from(timeout.as_millis()).unwrap_or(u64::MAX);
        read_on(socket, async |client| {
            client
                .request(
                    acpmux::rpc::method::MUX_WAIT,
                    json!({"sessions": [session], "until": until, "timeoutMs": timeout_ms}),
                )
                .await
        })
    }

    /// Sets `session`'s tags `set` (`_acpmux/tag`), each living `ttl_seconds`.
    pub(in crate::cli) fn set_tags(
        session: &str,
        set: &Value,
        ttl_seconds: u64,
        socket: Option<&Path>,
    ) -> Result<Value, String> {
        read_on(socket, async |client| {
            client
                .request(
                    acpmux::rpc::method::MUX_TAG,
                    json!({"sessionId": session, "set": set, "ttlSeconds": ttl_seconds}),
                )
                .await
        })
    }

    /// The acpmux's harness catalog (`_acpmux/harnesses`: `harnesses`, `families`,
    /// `defaultHarness`, `defaults`), the one a new chat there resolves its agent from; the dial
    /// and the answer together at most `timeout` (a daemon still reading its login shell answers
    /// once it has; a dial waits for a daemon that is starting). Its own connection, as
    /// [`new_session`] has: it runs on a thread of its own beside the start's other reads.
    pub(in crate::cli) fn harnesses(
        socket: Option<&Path>,
        timeout: std::time::Duration,
    ) -> Result<Value, String> {
        block_on(async {
            tokio::time::timeout(timeout, async {
                client(socket).await?.request(acpmux::rpc::method::MUX_HARNESSES, json!({})).await
            })
            .await
            .map_err(|_| anyhow::anyhow!("no answer in {} ms", timeout.as_millis()))?
        })
    }

    /// Follows `session`'s live `session/update`s on a connection of its own (`_acpmux/attach`,
    /// hidden, no history: the attach subscribes it) and hands each update's params to `each`
    /// until `each` says stop, the daemon closes the connection, or `deadline` passes.
    pub(in crate::cli) fn follow_updates(
        session: &str,
        socket: Option<&Path>,
        deadline: std::time::Instant,
        mut each: impl FnMut(&Value) -> bool,
    ) -> Result<(), String> {
        use acpmux::rpc::{Message, method};
        block_on(async {
            let client = client(socket).await?;
            let mut notes = client
                .notifications()
                .await
                .ok_or_else(|| anyhow::anyhow!("notifications already taken"))?;
            client
                .request(
                    method::MUX_ATTACH,
                    json!({"sessionId": session, "limit": 0, "visible": false}),
                )
                .await?;
            let end = tokio::time::Instant::from_std(deadline);
            loop {
                let Ok(Some(note)) = tokio::time::timeout_at(end, notes.recv()).await else {
                    return Ok(());
                };
                let Message::Notification { method: name, params } = note else { continue };
                if name == method::MUX_DISCONNECTED {
                    return Ok(());
                }
                let params = params.unwrap_or(Value::Null);
                let ours = params.get("sessionId").and_then(Value::as_str) == Some(session);
                if name == method::SESSION_UPDATE && ours && !each(&params) {
                    return Ok(());
                }
            }
        })
    }

    /// One page of the session's events after `after_seq`.
    pub(in crate::cli) fn events(
        session: &str,
        after_seq: u64,
        limit: u64,
        socket: Option<&Path>,
    ) -> Result<Value, String> {
        read_on(socket, async |client| {
            client
                .request(
                    acpmux::rpc::method::MUX_EVENTS,
                    json!({"sessionId": session, "afterSeq": after_seq, "limit": limit,
                           "maxBytes": 4 << 20}),
                )
                .await
        })
    }

    /// The newest `limit` of the session's events before `before_seq` (newest first), as `acp last`
    /// reads back from the end.
    pub(in crate::cli) fn events_before(
        session: &str,
        before_seq: u64,
        limit: u64,
        socket: Option<&Path>,
    ) -> Result<Value, String> {
        read_on(socket, async |client| {
            client
                .request(
                    acpmux::rpc::method::MUX_EVENTS,
                    json!({"sessionId": session, "beforeSeq": before_seq, "limit": limit,
                           "maxBytes": 4 << 20}),
                )
                .await
        })
    }
}

#[cfg(test)]
#[path = "chat_tests.rs"]
mod tests;
