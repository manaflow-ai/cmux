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

/// One `cmux agents chat` verb.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(in crate::cli) enum ChatCommand {
    Send {
        target: String,
        text: String,
    },
    Read {
        target: String,
        after: u64,
        limit: usize,
    },
    /// Start a GUI agent chat (chat_control.rs).
    New(super::chat_control::NewChat),
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
        ["new", rest @ ..] => super::chat_control::parse_new(rest).map(ChatCommand::New),
        ["state", target] => Ok(ChatCommand::State { target: chat_word(target)? }),
        ["interrupt", target] => Ok(ChatCommand::Interrupt { target: chat_word(target)? }),
        // A nudge: a send whose text defaults to "Continue.".
        ["continue", target] => Ok(ChatCommand::Send {
            target: chat_word(target)?,
            text: super::chat_control::CONTINUE_TEXT.to_owned(),
        }),
        ["continue", target, rest @ ..] => {
            let mut words = vec!["send", *target];
            words.extend_from_slice(rest);
            parse(&words)
        }
        ["send", target, rest @ ..] => {
            let target = chat_word(target)?;
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
            Ok(ChatCommand::Send { target, text })
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
        ChatCommand::Send { target, text } => send(global, target, text, idempotency_key, origin),
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
    let keys = session_workspace_keys(global)?;
    if !workspace.as_ref().is_some_and(|key| keys.contains(key)) {
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

/// A workspace key in one comparable form: lowercase, without dashes (the
/// app hands sessions the key's uppercase UUID form). As the daemon's
/// `agent_message_policy::workspace_key`.
pub(super) fn workspace_key(value: &str) -> String {
    value.chars().filter(|ch| *ch != '-').flat_map(char::to_lowercase).collect()
}

/// The keys of this cmux session's workspaces (`extra.key`), from the
/// session snapshot `agents_snapshot` reads.
fn session_workspace_keys(global: &GlobalArgs) -> Result<HashSet<String>, CallFailure> {
    let snapshot = mcp::agent_resource(global, super::snapshot_plan())
        .map_err(|error| CallFailure { kind: FailureKind::NotRun, error, idempotency_key: None })?;
    Ok(snapshot["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|workspace| workspace["extra"]["key"].as_str())
        .map(workspace_key)
        .collect())
}

/// The caller's own chat: the acpmux session acpmux started it in.
fn own_chat() -> Option<String> {
    ["CMUX_AGENT_SESSION", "ACPMUX_SESSION_ID"]
        .into_iter()
        .find_map(|name| std::env::var(name).ok().filter(|value| !value.trim().is_empty()))
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
        from: None,
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
        result["reason"] = reason.clone();
    }
    // Stored but not handed to the chat: the receipt says so, and the CLI
    // and the tool report it as an error (`delivery_failed`).
    if sent.failed {
        result["state"] = json!("failed");
    }
    if !sent.problems.is_empty() {
        result["problems"] = json!(sent.problems);
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
                    item.extra["tool"]["status"] = json!(status);
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
pub(super) mod acp {
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

    /// The id and `_acpmux/info` of the session `key` names.
    pub(in crate::cli) fn lookup(
        key: &str,
        socket: Option<&Path>,
    ) -> Result<(String, Value), String> {
        block_on(async {
            let client = client(socket).await?;
            let (id, _name) = acpmux::deliver::resolve_session(&client, key).await?;
            let info =
                client.request(acpmux::rpc::method::MUX_INFO, json!({"sessionId": id})).await?;
            Ok((id, info))
        })
    }

    /// Starts a chat in `cwd` with `meta` as its `_meta.acpmux`; the
    /// `session/new` reply.
    pub(in crate::cli) fn new_session(
        cwd: &str,
        meta: Value,
        socket: Option<&Path>,
    ) -> Result<Value, String> {
        block_on(async {
            client(socket)
                .await?
                .request(
                    acpmux::rpc::method::SESSION_NEW,
                    json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": meta}}),
                )
                .await
        })
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

    /// One page of the session's events after `after_seq`.
    pub(super) fn events(
        session: &str,
        after_seq: u64,
        limit: u64,
        socket: Option<&Path>,
    ) -> Result<Value, String> {
        block_on(async {
            client(socket)
                .await?
                .request(
                    acpmux::rpc::method::MUX_EVENTS,
                    json!({"sessionId": session, "afterSeq": after_seq, "limit": limit,
                           "maxBytes": 4 << 20}),
                )
                .await
        })
    }
}

#[cfg(test)]
mod tests {
    use super::{MAX_EVENT_PAGES, Transcript, load};
    use serde_json::{Value, json};

    fn update(seq: u64, update: Value) -> Value {
        json!({"seq": seq, "dir": "in", "kind": "session/update",
            "msg": {"method": "session/update", "params": {"update": update}}})
    }

    fn mux(seq: u64, kind: &str, msg: Value) -> Value {
        json!({"seq": seq, "dir": "mux", "kind": kind, "msg": msg})
    }

    fn transcript(events: &[Value]) -> Transcript {
        let mut transcript = Transcript::default();
        for event in events {
            transcript.apply(event);
        }
        transcript
    }

    /// An event source serving `events` one page of `per_page` at a time,
    /// then, when `live`, one new answer chunk per request forever (a chat
    /// still writing its turn); `loads` counts the requests.
    fn source(
        events: Vec<Value>,
        per_page: usize,
        live: bool,
        loads: &mut usize,
    ) -> impl FnMut(u64) -> Result<Value, String> + '_ {
        move |cursor| {
            *loads += 1;
            let rest: Vec<Value> = events
                .iter()
                .filter(|event| event["seq"].as_u64() > Some(cursor))
                .cloned()
                .collect();
            if rest.is_empty() && live {
                let chunk = update(
                    cursor + 1,
                    json!({"sessionUpdate": "agent_message_chunk", "content": {"text": "."}}),
                );
                return Ok(json!({"events": [chunk], "hasMore": true}));
            }
            let page: Vec<Value> = rest.iter().take(per_page).cloned().collect();
            Ok(json!({"events": page, "hasMore": live || rest.len() > per_page}))
        }
    }

    fn running_tool(seq: u64, id: &str) -> Value {
        update(
            seq,
            json!({"sessionUpdate": "tool_call", "toolCallId": id, "kind": "execute", "status": "in_progress"}),
        )
    }

    fn chunk(seq: u64) -> Value {
        update(seq, json!({"sessionUpdate": "agent_message_chunk", "content": {"text": "."}}))
    }

    #[test]
    fn a_read_of_a_live_turn_with_a_running_tool_stops_at_the_newest_event() {
        // The tool holds `next_after`, and its turn is still being written:
        // no turn end settles it yet, so the read stops where acpmux says
        // the log ends and holds `next_after` at the item before the tool.
        let mut events =
            vec![mux(1, "user_message", json!({"text": "run it"})), running_tool(2, "t1")];
        events.extend((3..=9).map(chunk));
        let mut loads = 0;
        let (transcript, more, cursor) = load(0, 2, source(events, 3, false, &mut loads)).unwrap();
        assert_eq!(loads, 3);
        assert!(!more);
        let page = transcript.page("c", 0, 2, more, cursor);
        assert_eq!(page["items"][1]["partial"], true, "{page}");
        assert_eq!(page["next_after"], 1, "{page}");
        assert_eq!(page["has_more"], true);
    }

    #[test]
    fn a_tool_whose_turn_ends_pages_past_a_full_read_still_settles_in_it() {
        // A harness that never finishes a tool call leaves its turn end to
        // settle it. Were the read to stop a few pages after it is full, a
        // turn end further on would never be read: every read restarts at
        // `after`, so `next_after` would stay at the tool for good.
        let mut events =
            vec![mux(1, "user_message", json!({"text": "run it"})), running_tool(2, "t1")];
        events.extend((3..=12).map(chunk));
        events.push(mux(13, "turn_result", json!({"status": "cancelled"})));
        let mut loads = 0;
        let (transcript, more, cursor) = load(0, 2, source(events, 3, false, &mut loads)).unwrap();
        assert_eq!(loads, 5);
        assert!(loads < MAX_EVENT_PAGES);
        let page = transcript.page("c", 0, 2, more, cursor);
        assert_eq!(page["items"][1]["partial"], Value::Null, "{page}");
        assert_eq!(page["next_after"], 2, "{page}");
        assert_eq!(page["has_more"], true);
    }

    #[test]
    fn a_running_tool_past_the_items_a_read_returns_does_not_extend_it() {
        let events = vec![
            mux(1, "user_message", json!({"text": "one"})),
            mux(2, "user_message", json!({"text": "two"})),
            running_tool(3, "t1"),
        ];
        let mut loads = 0;
        let (transcript, more, cursor) = load(0, 1, source(events, 3, true, &mut loads)).unwrap();
        assert_eq!(loads, 1);
        let page = transcript.page("c", 0, 1, more, cursor);
        assert_eq!(page["next_after"], 1, "{page}");
        assert_eq!(page["has_more"], true);
    }

    #[test]
    fn a_read_loads_on_to_the_turn_end_that_settles_a_tool_it_returns() {
        let events = vec![
            mux(1, "user_message", json!({"text": "run it"})),
            running_tool(2, "t1"),
            update(3, json!({"sessionUpdate": "agent_message_chunk", "content": {"text": "a"}})),
            update(4, json!({"sessionUpdate": "agent_message_chunk", "content": {"text": "b"}})),
            mux(5, "turn_result", json!({"status": "cancelled"})),
        ];
        let mut loads = 0;
        let (transcript, more, cursor) = load(0, 2, source(events, 3, false, &mut loads)).unwrap();
        assert_eq!(loads, 2);
        let page = transcript.page("c", 0, 2, more, cursor);
        assert_eq!(page["items"][1]["partial"], Value::Null, "{page}");
        assert_eq!(page["next_after"], 2, "{page}");
        assert_eq!(page["has_more"], true);
    }

    #[test]
    fn a_tool_call_left_running_by_an_ended_turn_does_not_hold_the_read() {
        let mut events = vec![
            mux(1, "user_message", json!({"text": "run it"})),
            update(
                2,
                json!({"sessionUpdate": "tool_call", "toolCallId": "t1", "kind": "execute", "status": "in_progress"}),
            ),
            mux(3, "turn_result", json!({"status": "cancelled"})),
        ];
        for seq in 4..10 {
            events.push(mux(seq, "user_message", json!({"text": format!("prompt {seq}")})));
        }
        let transcript = transcript(&events);
        let page = transcript.page("c", 1, 2, false, 9);
        assert_eq!(page["items"][0]["role"], "tool");
        assert_eq!(page["items"][0]["partial"], Value::Null);
        assert_eq!(page["next_after"], 3, "{page}");
        assert_eq!(page["has_more"], true);
    }

    #[test]
    fn a_tool_call_in_a_running_turn_still_holds_the_read() {
        let events = vec![
            update(
                2,
                json!({"sessionUpdate": "tool_call", "toolCallId": "t1", "kind": "execute", "status": "in_progress"}),
            ),
            update(
                3,
                json!({"sessionUpdate": "agent_message_chunk", "content": {"text": "still going"}}),
            ),
            update(
                4,
                json!({"sessionUpdate": "tool_call", "toolCallId": "t2", "kind": "read", "status": "completed"}),
            ),
        ];
        let page = transcript(&events).page("c", 1, 10, false, 4);
        assert_eq!(page["items"][0]["partial"], true);
        assert_eq!(page["next_after"], 1, "{page}");
    }

    #[test]
    fn only_agent_message_provenance_marks_a_prompt_as_another_agents() {
        let events = vec![
            mux(
                1,
                "user_message",
                json!({"text": "hi", "_meta": {"provenance": {"kind": "agent_message", "from": "chat-a", "fromName": "A", "msgId": "m1"}}}),
            ),
            mux(
                2,
                "user_message",
                json!({"text": "resume", "_meta": {"provenance": {"kind": "auto_resume", "promptId": "p", "attempt": 1, "turnId": "t"}}}),
            ),
            mux(
                3,
                "user_message",
                json!({"text": "result", "_meta": {"provenance": {"kind": "offer_result", "offerId": "o", "childSessionId": "c2", "title": "x"}}}),
            ),
        ];
        let page = transcript(&events).page("c", 0, 10, false, 3);
        let items = page["items"].as_array().unwrap();
        assert_eq!(items[0]["origin"], "agent_message");
        assert_eq!(items[0]["from"], "chat-a");
        assert_eq!(items[0]["from_name"], "A");
        assert_eq!(items[0]["message_id"], "m1");
        for item in &items[1..] {
            assert_eq!(item["origin"], Value::Null, "{item}");
            assert_eq!(item["from"], Value::Null, "{item}");
        }
    }

    #[test]
    fn a_turn_of_agent_messages_names_its_senders() {
        let events = vec![mux(
            1,
            "user_message",
            json!({"text": "2 messages", "_meta": {"provenance": {"kind": "agent_digest", "messages": [{"promptId": "p1", "from": "lane-a"}, {"promptId": "p2", "from": "lane-b"}]}}}),
        )];
        let page = transcript(&events).page("c", 0, 10, false, 1);
        let item = &page["items"][0];
        assert_eq!(item["origin"], "agent_digest", "{item}");
        assert_eq!(item["senders"], json!(["lane-a", "lane-b"]), "{item}");
    }

    #[test]
    fn a_read_masks_a_secret_split_across_chunks_and_holds_back_a_half_written_one() {
        let key = format!("AKIA{}", "Q7ZJ4XK2MD5P3WRT");
        let (head, tail) = key.split_at(9);
        let chunk = |seq, text: &str| {
            update(seq, json!({"sessionUpdate": "agent_message_chunk", "content": {"text": text}}))
        };
        let mut events = vec![
            mux(
                1,
                "user_message",
                json!({"text": format!("use {key} now"),
                "_meta": {"provenance": {"kind": "agent_message", "from": "c1",
                                         "fromName": format!("bot {key}"), "msgId": "m1"}}}),
            ),
            chunk(2, &format!("set {head}")),
        ];
        // Still being written: the half of the key is not shown.
        let page = transcript(&events).page("c", 0, 10, false, 2);
        assert_eq!(page["items"][1]["partial"], true, "{page}");
        assert_eq!(page["items"][1]["text"], "set", "{page}");
        events.push(chunk(3, &format!("{tail} done")));
        events.push(mux(4, "turn_result", json!({"status": "completed"})));
        let page = transcript(&events).page("c", 0, 10, false, 4);
        assert!(!page.to_string().contains(head), "{page}");
        assert_eq!(page["items"][0]["text"], "use [AWS access key] now", "{page}");
        assert_eq!(page["items"][0]["from_name"], "bot [AWS access key]", "{page}");
        assert_eq!(page["items"][1]["text"], "set [AWS access key] done", "{page}");
    }
}
