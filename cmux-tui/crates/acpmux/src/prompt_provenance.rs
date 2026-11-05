//! A prompt's provenance (`_meta.acpmux.provenance` on `session/prompt`, cx-55d27): who sent
//! a prompt that is not the person's own, today one agent's message to another (`cmux agent
//! message`): `{kind: "agent_message", from, fromName?, to, msgId, threadId, replyTo?}`.
//! acpmux records it as `_meta.provenance` on the prompt's `user_message` (and its `queued`
//! record), so a client shows the prompt as that agent's message instead of as the person's
//! words. The agent gets the prompt's blocks only.
//!
//! Only the unix socket may send it (`remote_guard.rs` refuses every other origin with
//! `provenance.origin_refused`), so a remote client cannot pass its words off as an agent's.
//! The app's own pane included: its reply in place to an agent message is no prompt, it is
//! checked and signed by `_acpmux/app_reply` (`server/app_reply.rs`) and sent by the app as the
//! replying chat's cmux agent message, which the daemon's pump delivers here.
//! A queued prompt keeps it, across a restart too (`queue.rs`); an edit of a waiting prompt
//! (`_acpmux/queue_edit`) drops it: the person rewrote the prompt.
//!
//! The hub sets two more kinds itself, never taken from a client: `{kind: "offer_result",
//! offerId, childSessionId, title}` on the prompt that brings a suggested task's first reply
//! back to the chat that offered it (`hub/offer_results.rs`, cx-lo9yf), `{kind:
//! "auto_resume", promptId, attempt, turnId}` on the prompt that continues a turn a
//! connection error cut off (`hub/auto_resume.rs`), `{kind: "session_message", from,
//! fromName, to}` on a prompt another session sent with none (`session_message` below), and
//! `{kind: "task_result", from, fromName, to, taskId, state}` on the prompt that brings a task's
//! result to the chat that gave it (`hub/tasks.rs`), and `{kind: "turn_cap", turnId, capMs}` on
//! the one notice steered into a turn past its turn cap (`hub/turn_cap.rs`), and `{kind:
//! "who_else", ...}` with a tool notice's fields on the one notice that another live session
//! edits the same files (`hub/touched.rs`).
//!
//! A tool's or reconciler's notice (`_meta.acpmux.notice`, [`notice_of`]: `acpmux send --notice`,
//! the MCP `send` tool's `notice`) is stamped `{kind: "notice", from: "fromAgent", fromName:
//! sender, to, notice: {sender, host?, severity, title, links?}}` ([`notice`]). Its body is the
//! prompt's own blocks, which the client renders ([`notice_text`]) so a daemon or page that
//! knows no notice still reads it. For delivery it is a named sender's message, as `acpmux send
//! --from` is. It comes over the unix socket or from a peer forwarding one its own socket took;
//! a Web client, the app's pane or a peer forwarding for its Web client is refused
//! (`notice.origin_refused`, `remote_guard.rs`), and a bad field refuses the prompt
//! (`notice.value_refused`, naming the field), never silently dropped.

use cmux_json::JsonSet as _;
use serde_json::{Map, Value, json};

use crate::rpc::RpcError;

/// Longest id or address field, in bytes.
pub const MAX_FIELD_BYTES: usize = 256;
/// Longest sender name, in characters (`cmux agent message --from`).
pub const MAX_NAME_CHARS: usize = 64;

/// The fields a provenance names, each a one-line string, and whether it is required.
const FIELDS: &[(&str, bool)] = &[
    ("from", true),
    ("fromName", false),
    ("to", true),
    ("msgId", true),
    ("threadId", true),
    ("replyTo", false),
];

fn refusal(reason: &str, message: &str) -> RpcError {
    RpcError::invalid_params(message.to_owned()).with_data(json!({"reason": reason}))
}

/// Whether `meta` (`_meta.acpmux`) carries a provenance.
pub fn present(meta: Option<&Value>) -> bool {
    meta.and_then(|m| m.get("provenance")).is_some_and(|p| !p.is_null())
}

/// The refusal for a provenance sent over any connection but the unix socket.
pub fn origin_refused() -> RpcError {
    refusal(
        "provenance.origin_refused",
        "a prompt provenance is accepted only over the local unix socket",
    )
}

/// The refusal for `_acpmux/prompt_withdraw` over any connection but the unix socket: only the
/// socket that may say an agent sent a message may take one back (`hub/withdraw.rs`).
pub fn withdraw_origin_refused() -> RpcError {
    refusal(
        "withdraw.origin_refused",
        "withdrawing an agent message is accepted only over the local unix socket",
    )
}

/// Who sent a `session/prompt`, as far as its provenance goes.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Sender {
    /// The unix socket: any provenance.
    Local,
    /// A connection admitted by the dedicated Cloud trigger gate.
    Trigger,
    /// Anything else: none.
    Other,
}

/// The provenance of a `session/prompt`'s `params`, with only the fields above: `None` when
/// absent or null. `server/app_reply.rs` checks the app pane's reply in place with it too, as a
/// unix-socket provenance, before `Hub::app_reply_fits` checks the message it answers.
pub fn of(params: &Value, sender: Sender) -> Result<Option<Value>, RpcError> {
    let raw = match params.pointer("/_meta/acpmux/provenance") {
        None | Some(Value::Null) => return Ok(None),
        Some(Value::Object(raw)) => raw,
        Some(_) => return Err(refusal("provenance.value_refused", "provenance must be an object")),
    };
    if !matches!(sender, Sender::Local | Sender::Trigger) {
        return Err(origin_refused());
    }
    let kind = raw.get("kind").and_then(Value::as_str);
    // Trigger prompts are issued by a Cloud machine's short-lived trigger
    // principal. The platform has already bound that principal to one owner,
    // machine, chat and delivery before the guest reaches this local socket.
    // Keep only the bounded, non-secret binding in the transcript; the token
    // itself is never accepted as provenance or persisted in a record.
    if kind == Some("trigger") {
        if sender != Sender::Trigger {
            return Err(refusal(
                "provenance.trigger_refused",
                "trigger provenance requires a verified trigger connection",
            ));
        }
        const TRIGGER_FIELDS: &[(&str, bool)] = &[
            ("triggerId", true),
            ("deliveryId", true),
            ("owner", true),
            ("team", true),
            ("machine", true),
            ("workspace", false),
            ("session", false),
        ];
        let mut out = Map::new();
        out.insert("kind".to_owned(), json!("trigger"));
        for &(key, required) in TRIGGER_FIELDS {
            let value = match raw.get(key) {
                None | Some(Value::Null) if !required => continue,
                Some(Value::String(value)) if valid(key, value) => value,
                _ => {
                    let message = format!(
                        "trigger provenance {key} must be one line of 1 to {MAX_FIELD_BYTES} bytes"
                    );
                    return Err(refusal("provenance.value_refused", &message));
                }
            };
            out.insert(key.to_owned(), json!(value));
        }
        return Ok(Some(Value::Object(out)));
    }
    if kind != Some("agent_message") {
        return Err(refusal(
            "provenance.value_refused",
            "provenance kind must be agent_message or trigger",
        ));
    }
    let mut out = Map::new();
    out.insert("kind".to_owned(), json!("agent_message"));
    for &(key, required) in FIELDS {
        let value = match raw.get(key) {
            None | Some(Value::Null) if !required => continue,
            Some(Value::String(value)) if valid(key, value) => value,
            _ => {
                let need = if key == "fromName" {
                    format!("1 to {MAX_NAME_CHARS} characters")
                } else {
                    format!("1 to {MAX_FIELD_BYTES} bytes")
                };
                let message = format!("provenance {key} must be one line of {need}");
                return Err(refusal("provenance.value_refused", &message));
            }
        };
        out.insert(key.to_owned(), json!(value));
    }
    Ok(Some(Value::Object(out)))
}

/// Whether a prompt was admitted by the Cloud trigger principal. Trigger turns
/// are work performed on behalf of a configured automation, so they do not set
/// the person's unread marker when they complete normally.
pub fn is_trigger(provenance: Option<&Value>) -> bool {
    provenance.and_then(|p| p.get("kind")).and_then(Value::as_str) == Some("trigger")
}

fn valid(key: &str, value: &str) -> bool {
    let fits = if key == "fromName" {
        value.chars().count() <= MAX_NAME_CHARS
    } else {
        value.len() <= MAX_FIELD_BYTES
    };
    fits && !value.trim().is_empty() && !value.chars().any(unshown)
}

/// A character that breaks the one line or changes how it reads: a control, a line or
/// paragraph separator, or a bidi or zero-width format mark.
fn unshown(c: char) -> bool {
    c.is_control()
        || (c.is_whitespace() && c != ' ')
        || matches!(
            c,
            '\u{200B}'..='\u{200F}' | '\u{202A}'..='\u{202E}' | '\u{2066}'..='\u{2069}' | '\u{FEFF}'
        )
}

/// The provenance of a suggested task's result (`hub/offer_results.rs`): the offer, the chat
/// it started, and the task's title.
pub fn offer_result(offer_id: &str, child_session_id: &str, title: &str) -> Value {
    json!({"kind": "offer_result", "offerId": offer_id, "childSessionId": child_session_id, "title": title})
}

/// The provenance of a prompt a session sent another with none of its own: `acpmux send` (or
/// any client) run inside an acpmux session, which proved that session with its caller token
/// (`hub/person.rs` (a), `server/requests.rs`). Never for the person, nor a prompt to the sender
/// itself. `from` is the sender's session id, so the receiver's transcript opens its chat.
pub fn session_message(from: &str, from_name: &str, to: &str) -> Value {
    json!({"kind": "session_message", "from": from, "fromName": from_name, "to": to})
}

/// On a session a Chief host made for one of its turns (optchat-chief `acpmux::turn_tags`): the
/// Chief's participant id (`agent_mux`, `agent_…`), the key the app finds that Chief's name and
/// picture by.
pub const CHIEF_PARTICIPANT_TAG: &str = "cmux.chief.participant";
/// What a Chief's session is called where it is shown: its `mux.label` (the Chief's own name).
const LABEL_TAG: &str = "mux.label";
/// On a message from a Chief's turn session: that Chief's participant id, so the receiving chat
/// draws the Chief's name and picture, not the turn's session name (`optchat-<home>-<n>`,
/// manaflow-ai/cmux#27914).
pub const FROM_CHIEF: &str = "fromChief";

/// `provenance` with its sender's Chief, when the sender is a Chief's turn session of this daemon
/// (`meta_of` reads one by its id): `fromChief` its participant id and `fromName` the Chief's own
/// name. Both kinds a Chief's turn sends with: an `agent_message` (`agents_chat_send` through the
/// cmux daemon's pump, `from` `acp:<id>`) and a `session_message` (`acpmux send` from inside the
/// turn, `from` its id). Any other provenance is left as it is.
pub fn stamp_chief(
    mut provenance: Value,
    meta_of: impl Fn(&str) -> Option<crate::store::SessionMeta>,
) -> Value {
    let kind = provenance.get("kind").and_then(Value::as_str);
    if !matches!(kind, Some("agent_message" | "session_message")) {
        return provenance;
    }
    let Some(from) = provenance.get("from").and_then(Value::as_str) else {
        return provenance;
    };
    let Some(meta) = meta_of(from.strip_prefix("acp:").unwrap_or(from)) else {
        return provenance;
    };
    let live = |key: &str| {
        let tag = meta.tags.get(key)?;
        if tag.expires_at.is_some_and(|e| e <= crate::store::now_ms()) {
            return None;
        }
        Some(tag.value.trim().to_owned()).filter(|v| !v.is_empty() && !v.chars().any(unshown))
    };
    let Some(chief) = live(CHIEF_PARTICIPANT_TAG).filter(|c| c.len() <= MAX_FIELD_BYTES) else {
        return provenance;
    };
    provenance.set(FROM_CHIEF, json!(chief));
    if let Some(label) = live(LABEL_TAG).filter(|l| l.chars().count() <= MAX_NAME_CHARS) {
        provenance.set("fromName", json!(label));
    }
    provenance
}

/// The provenance of a task's result on the prompt that brings it to the chat that gave the task
/// (`hub/tasks.rs`): from the lane's session, `from` its id as in [`session_message`].
pub fn task_result(from: &str, from_name: &str, to: &str, task_id: &str, state: &str) -> Value {
    json!({"kind": "task_result", "from": from, "fromName": from_name, "to": to, "taskId": task_id, "state": state})
}

/// What `from` says in [`named_sender`]: the sender named itself and is no address here.
pub const NAMED_SENDER: &str = "fromAgent";

/// The provenance of a prompt whose sender named itself (`_meta.acpmux.fromAgent`) with no
/// provenance and no caller proof here: `acpmux send --from NAME`, `ACPMUX_FROM`, a peer daemon
/// forwarding a prompt its own session sent (`server/peer_forward.rs`; `cli/sender.rs`). An
/// agent's message, never the person's own: the transcript draws its sender's
/// chip, found by name (`from` opens no chat, as a person at a shell's `cli` does not).
pub fn named_sender(name: &str, to: &str) -> Value {
    json!({"kind": "agent_message", "from": NAMED_SENDER, "fromName": name, "to": to})
}

/// The provenance kind of a tool's notice ([`notice`]).
pub const NOTICE_KIND: &str = "notice";
/// Longest notice title, in characters.
pub const MAX_NOTICE_TITLE_CHARS: usize = 200;
/// Most links one notice carries.
pub const MAX_NOTICE_LINKS: usize = 16;
/// Longest notice link URL, in bytes.
pub const MAX_NOTICE_URL_BYTES: usize = 2048;
/// The severities a notice may have, quietest first.
pub const NOTICE_SEVERITIES: &[&str] = &["info", "warn", "fire"];

fn notice_refused(field: &str, need: &str) -> RpcError {
    RpcError::invalid_params(format!("notice {field} must be {need}"))
        .with_data(json!({"reason": "notice.value_refused", "field": field}))
}

/// The refusal for a notice from a Web client, the app's pane or a peer forwarding for its Web
/// client: no remote text passes as a tool's fire.
pub fn notice_origin_refused() -> RpcError {
    refusal(
        "notice.origin_refused",
        "a notice is accepted only over the local unix socket or from a peer daemon",
    )
}

/// Whether a `session/prompt`'s params carry a notice (`_meta.acpmux.notice`, not null).
pub fn notice_present(params: &Value) -> bool {
    params.pointer("/_meta/acpmux/notice").is_some_and(|n| !n.is_null())
}

/// One line of 1 to `max` characters with nothing [`unshown`], trimmed.
fn one_line(value: Option<&Value>, max: usize) -> Option<String> {
    let value = value?.as_str()?.trim();
    (!value.is_empty() && value.chars().count() <= max && !value.chars().any(unshown))
        .then(|| value.to_owned())
}

/// A host name as acpmux names one: 1 to 64 letters, digits, `.`, `-` or `_`.
fn host_fits(host: &str) -> bool {
    (1..=MAX_NAME_CHARS).contains(&host.len())
        && host.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_'))
}

/// An `https://` URL with a host, of at most [`MAX_NOTICE_URL_BYTES`], with no whitespace,
/// control or format mark in it.
fn https_url(url: &str) -> bool {
    let Some(rest) = url.strip_prefix("https://") else { return false };
    let authority = rest.split(['/', '?', '#']).next().unwrap_or_default();
    url.len() <= MAX_NOTICE_URL_BYTES
        && !authority.is_empty()
        && !url.chars().any(|c| c.is_whitespace() || unshown(c))
}

/// The notice a `session/prompt`'s params carry (`_meta.acpmux.notice`), checked and with only
/// its known fields: `None` when absent or null. Any bad field refuses the prompt
/// (`notice.value_refused`, `field` naming it).
pub fn notice_of(params: &Value) -> Result<Option<Value>, RpcError> {
    let raw = match params.pointer("/_meta/acpmux/notice") {
        None | Some(Value::Null) => return Ok(None),
        Some(Value::Object(raw)) => raw,
        Some(_) => return Err(notice_refused("notice", "an object")),
    };
    let names = format!("one line of 1 to {MAX_NAME_CHARS} characters");
    let sender = one_line(raw.get("sender"), MAX_NAME_CHARS)
        .ok_or_else(|| notice_refused("sender", &names))?;
    let mut out = Map::new();
    out.insert("sender".to_owned(), json!(sender));
    match raw.get("host") {
        None | Some(Value::Null) => {}
        Some(Value::String(host)) if host_fits(host) => {
            out.insert("host".to_owned(), json!(host));
        }
        Some(_) => {
            let need = format!("1 to {MAX_NAME_CHARS} letters, digits, '.', '-' or '_'");
            return Err(notice_refused("host", &need));
        }
    }
    let severity = raw.get("severity").and_then(Value::as_str);
    let severity = severity
        .filter(|s| NOTICE_SEVERITIES.contains(s))
        .ok_or_else(|| notice_refused("severity", "info, warn or fire"))?;
    out.insert("severity".to_owned(), json!(severity));
    let title = one_line(raw.get("title"), MAX_NOTICE_TITLE_CHARS).ok_or_else(|| {
        notice_refused("title", &format!("one line of 1 to {MAX_NOTICE_TITLE_CHARS} characters"))
    })?;
    out.insert("title".to_owned(), json!(title));
    match raw.get("links") {
        None | Some(Value::Null) => {}
        Some(Value::Array(links)) if links.len() <= MAX_NOTICE_LINKS => {
            let mut kept = Vec::with_capacity(links.len());
            for link in links {
                let url = link.get("url").and_then(Value::as_str).filter(|u| https_url(u));
                let url = url.ok_or_else(|| {
                    let need = format!("an https URL of at most {MAX_NOTICE_URL_BYTES} bytes");
                    notice_refused("links.url", &need)
                })?;
                let mut one = json!({"url": url});
                match link.get("label") {
                    None | Some(Value::Null) => {}
                    label => {
                        let label = one_line(label, MAX_NAME_CHARS)
                            .ok_or_else(|| notice_refused("links.label", &names))?;
                        one.set("label", json!(label));
                    }
                }
                kept.push(one);
            }
            if !kept.is_empty() {
                out.insert("links".to_owned(), Value::Array(kept));
            }
        }
        Some(_) => {
            let need = format!("an array of at most {MAX_NOTICE_LINKS} {{url, label?}} objects");
            return Err(notice_refused("links", &need));
        }
    }
    Ok(Some(Value::Object(out)))
}

/// [`notice_of`], and a notice beside a caller's own provenance refused: a notice carries its
/// own. Every place that admits a prompt checks it (the dispatch, `_acpmux/send_queue`, a peer
/// forward, which drops the caller's provenance).
pub fn notice_checked(params: &Value) -> Result<Option<Value>, RpcError> {
    let notice = notice_of(params)?;
    if notice.is_some() && present(params.pointer("/_meta/acpmux")) {
        return Err(notice_refused(
            "provenance",
            "sent alone: a notice carries its own provenance",
        ));
    }
    Ok(notice)
}

/// The provenance of a tool's notice ([`notice_of`] checked it) to session `to`: a named
/// sender's message, as [`named_sender`] is, that carries the notice itself.
pub fn notice(notice: &Value, to: &str) -> Value {
    let sender = notice.get("sender").and_then(Value::as_str).unwrap_or_default();
    json!({"kind": NOTICE_KIND, "from": NAMED_SENDER, "fromName": sender, "to": to, "notice": notice})
}

/// Whether a provenance is a tool's notice's ([`notice`]).
pub fn is_notice(provenance: Option<&Value>) -> bool {
    provenance.and_then(|p| p.get("kind")).and_then(Value::as_str) == Some(NOTICE_KIND)
}

/// The text a notice's prompt carries, rendered by its client (the CLI, the MCP `send` tool) so
/// a daemon or page that knows no notice still reads it:
/// `[notice from SENDER on HOST · FIRE] TITLE`, then the body, then `Links: URL (LABEL), URL`.
/// Info has no severity tag; `on HOST` only with a host; the Links line only with links.
pub fn notice_text(notice: &Value, body: &str) -> String {
    let field = |k: &str| notice.get(k).and_then(Value::as_str).unwrap_or_default();
    let mut head = format!("[notice from {}", field("sender"));
    if let Some(host) = notice.get("host").and_then(Value::as_str) {
        head.push_str(&format!(" on {host}"));
    }
    match field("severity") {
        "info" | "" => {}
        severity => head.push_str(&format!(" · {}", severity.to_uppercase())),
    }
    head.push_str(&format!("] {}", field("title")));
    let body = body.trim_matches(['\n', '\r']);
    if !body.trim().is_empty() {
        head.push('\n');
        head.push_str(body);
    }
    let links: Vec<String> = notice
        .get("links")
        .and_then(Value::as_array)
        .map(|links| {
            links
                .iter()
                .filter_map(|l| {
                    let url = l.get("url")?.as_str()?;
                    Some(match l.get("label").and_then(Value::as_str) {
                        Some(label) => format!("{url} ({label})"),
                        None => url.to_owned(),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    if !links.is_empty() {
        head.push_str(&format!("\nLinks: {}", links.join(", ")));
    }
    head
}

/// A `--link` value, `URL` or `URL=LABEL`, as a notice link. With no query (`?`) before the
/// first `=`, that `=` starts the label. In a query each `name=value` keeps its `=`, so only an
/// `=` past them starts the label: `https://x/run?id=5` has none, `https://x/run?id=5=run 5` has
/// one. Not checked here: [`notice_of`] checks what goes out.
pub fn notice_link(arg: &str) -> Value {
    let first = arg.find('=');
    let query = arg.find('?');
    let at = match (first, query) {
        (Some(eq), Some(q)) if q < eq => {
            let query_part = arg.get(q..).unwrap_or_default();
            let params = query_part.matches('&').count() + 1;
            (query_part.matches('=').count() > params).then(|| arg.rfind('=')).flatten()
        }
        (eq, _) => eq,
    };
    let Some(at) = at else { return json!({"url": arg}) };
    let (url, label) = (arg.get(..at).unwrap_or(arg), arg.get(at + 1..).unwrap_or_default());
    let label = label.trim();
    if label.is_empty() { json!({"url": url}) } else { json!({"url": url, "label": label}) }
}

/// The machine a person's own `acpmux send` ran on (`_meta.acpmux.cliHost`, `cli/sender.rs`), when
/// it reads as a host name: 1 to 64 letters, digits, `.`, `-` or `_`.
pub fn cli_host(params: &Value) -> Option<&str> {
    let host = params.pointer("/_meta/acpmux/cliHost")?.as_str()?;
    let fits = (1..=MAX_NAME_CHARS).contains(&host.len())
        && host.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_'));
    fits.then_some(host)
}

/// The durable copy of a session-to-session message a prompt's in-memory provenance carries
/// (`hub/message_events.rs`). A record keeps it as `_meta._acpmuxMessage`, beside
/// `_meta.provenance` and never inside it, so the provenance a client reads stays the sender's.
pub const MESSAGE_META: &str = "_acpmuxMessage";

/// `record` with `_meta.provenance` when the prompt has one (a `user_message` or `queued`). Its
/// message copies (its own, and each joined message's in a digest) go to `_meta._acpmuxMessage`.
pub fn marked(mut record: Value, provenance: Option<&Value>) -> Value {
    if let (Some(p), Some(fields)) = (provenance, record.as_object_mut()) {
        let mut p = p.clone();
        let messages = take_message_meta(&mut p);
        let mut meta = json!({"provenance": p});
        if let Some(messages) = messages {
            meta.set(MESSAGE_META, messages);
        }
        fields.insert("_meta".to_owned(), meta);
    }
    record
}

/// A `queued` or `user_message` record's provenance as the prompt carried it: [`marked`] undone,
/// with its message copies back in place.
pub fn recorded(record: &Value) -> Option<Value> {
    let mut provenance = record.pointer("/_meta/provenance")?.clone();
    if let Some(messages) = record.get("_meta").and_then(|meta| meta.get(MESSAGE_META)) {
        put_message_meta(&mut provenance, messages);
    }
    Some(provenance)
}

/// Takes every message copy out of `provenance`: `{message?, messages?}`, where `messages` holds
/// one entry (or null) per joined message of a digest, in its order.
fn take_message_meta(provenance: &mut Value) -> Option<Value> {
    let fields = provenance.as_object_mut()?;
    let own = fields.remove(MESSAGE_META);
    let joined: Vec<Value> = fields
        .get_mut("messages")
        .and_then(Value::as_array_mut)
        .map(|messages| {
            messages
                .iter_mut()
                .map(|m| m.get_mut("provenance").and_then(take_message_meta).unwrap_or(Value::Null))
                .collect()
        })
        .unwrap_or_default();
    let any_joined = joined.iter().any(|m| !m.is_null());
    if own.is_none() && !any_joined {
        return None;
    }
    let mut taken = Map::new();
    if let Some(own) = own {
        taken.insert("message".to_owned(), own);
    }
    if any_joined {
        taken.insert("messages".to_owned(), Value::Array(joined));
    }
    Some(Value::Object(taken))
}

/// Puts back what [`take_message_meta`] took.
fn put_message_meta(provenance: &mut Value, taken: &Value) {
    let Some(fields) = provenance.as_object_mut() else { return };
    if let Some(own) = taken.get("message") {
        fields.insert(MESSAGE_META.to_owned(), own.clone());
    }
    let joined = taken.get("messages").and_then(Value::as_array);
    let messages = fields.get_mut("messages").and_then(Value::as_array_mut);
    if let (Some(joined), Some(messages)) = (joined, messages) {
        for (message, taken) in messages.iter_mut().zip(joined) {
            if let Some(p) = message.get_mut("provenance").filter(|_| !taken.is_null()) {
                put_message_meta(p, taken);
            }
        }
    }
}

#[cfg(test)]
mod message_meta_tests {
    use super::{MESSAGE_META, marked, recorded};
    use serde_json::json;

    /// A record's provenance is the sender's alone: its message copies (one of its own, one per
    /// joined message of a digest) sit beside it, and reading the record puts them back.
    #[test]
    fn a_record_keeps_its_message_copies_beside_its_provenance() {
        let copy =
            |id: &str| json!({"messageId": id, "sender": {"name": "lane", "sessionId": "s"}});
        let own = json!({"kind": "agent_message", "from": "acp:s", "to": "acp:t", MESSAGE_META: copy("m-0")});
        let digest = json!({"kind": "agent_digest", "messages": [
            {"promptId": "p-1", "from": "lane", "provenance": {"kind": "session_message", MESSAGE_META: copy("m-1")}},
            {"promptId": "p-2", "from": "person"},
            {"promptId": "p-3", "from": "lane", "provenance": {"kind": "session_message"}},
            {"promptId": "p-4", "from": "lane", "provenance": {"kind": "session_message", MESSAGE_META: copy("m-4")}},
        ]});
        for provenance in [own, digest] {
            let record = marked(json!({"promptId": "p"}), Some(&provenance));
            let shown = record.pointer("/_meta/provenance").unwrap();
            assert!(!shown.to_string().contains(MESSAGE_META), "{record}");
            assert!(record.pointer(&format!("/_meta/{MESSAGE_META}")).is_some(), "{record}");
            assert_eq!(recorded(&record), Some(provenance));
        }
        // No copy: the record is as before, and so is what reading it gives.
        let plain = json!({"kind": "agent_message", "from": "acp:s", "to": "acp:t"});
        let record = marked(json!({"promptId": "p"}), Some(&plain));
        assert_eq!(record["_meta"], json!({"provenance": plain}));
        assert_eq!(recorded(&record), Some(plain));
    }
}

/// `_meta.acpmux.fromSessionId` and `fromHarness`: which session sent an agent's message and on
/// what harness family (`claude`, `codex`, ...), so a client draws its sender's icon and opens
/// its chat. Display only: nothing decides who may do what by them.
///
/// The daemon binds them; a client never names them. The session a connection proved it runs in
/// (its caller token, `hub/person.rs`) is the sender. Over a peer link (`Origin::Peer`, a peer
/// daemon forwarding its own proven caller's prompt, `server/peer_forward.rs`, or the mesh relay
/// delivering a hub message, `server/mesh_relay.rs`) they are that daemon's word, taken only from
/// a prompt it sent as its own (no `via`): a prompt it forwards for its Web, app or paired-device
/// client names no sender. From anywhere else, or malformed, they are dropped, never refused.
/// They are stamped on the prompt's provenance (`stamp_sender`), so its `queued` and
/// `user_message` records and the queue list carry them, and an edit drops them with it.
pub const FROM_SESSION_ID: &str = "fromSessionId";
/// See [`FROM_SESSION_ID`].
pub const FROM_HARNESS: &str = "fromHarness";

/// The sending session's id and harness family, as far as the daemon bound them.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct BoundSender {
    pub session_id: Option<String>,
    pub harness: Option<String>,
}

impl BoundSender {
    /// A session of this daemon: its id and its harness family (`web_modes::family_of`).
    pub fn of_session(id: &str, meta: &crate::store::SessionMeta) -> Self {
        Self {
            session_id: fits(id, MAX_FIELD_BYTES).then(|| id.to_owned()),
            harness: Some(crate::web_modes::family_of(meta)).filter(|h| harness_fits(h)),
        }
    }

    fn is_empty(&self) -> bool {
        self.session_id.is_none() && self.harness.is_none()
    }

    /// The `_meta.acpmux` fields that carry it to a peer.
    pub fn mux_fields(&self) -> Value {
        let mut out = Map::new();
        if let Some(id) = &self.session_id {
            out.insert(FROM_SESSION_ID.to_owned(), json!(id));
        }
        if let Some(harness) = &self.harness {
            out.insert(FROM_HARNESS.to_owned(), json!(harness));
        }
        Value::Object(out)
    }
}

fn fits(value: &str, max_bytes: usize) -> bool {
    value.len() <= max_bytes && !value.trim().is_empty() && !value.chars().any(unshown)
}

/// A harness family as acpmux names one: 1 to 64 letters, digits, `.`, `-` or `_`.
fn harness_fits(value: &str) -> bool {
    (1..=MAX_NAME_CHARS).contains(&value.len())
        && value.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_'))
}

/// The sender a peer link named for a prompt (see [`FROM_SESSION_ID`]): `None` for a prompt it
/// forwarded for a client of its own (`_meta.acpmux.via`), and each field only when well formed.
pub fn peer_sender(params: &Value) -> Option<BoundSender> {
    let mux = params.pointer("/_meta/acpmux")?;
    if mux.get("via").is_some_and(|v| !v.is_null()) {
        return None;
    }
    let field = |k: &str| mux.get(k).and_then(Value::as_str);
    let sender = BoundSender {
        session_id: field(FROM_SESSION_ID)
            .filter(|id| fits(id, MAX_FIELD_BYTES))
            .map(str::to_owned),
        harness: field(FROM_HARNESS).filter(|h| harness_fits(h)).map(str::to_owned),
    };
    (!sender.is_empty()).then_some(sender)
}

/// Takes `fromSessionId` and `fromHarness` out of a prompt's `_meta.acpmux`: what a client wrote
/// never goes on to a peer as this daemon's word.
pub fn drop_sender_fields(params: &mut Value) {
    if let Some(mux) = params.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut) {
        mux.remove(FROM_SESSION_ID);
        mux.remove(FROM_HARNESS);
    }
}

/// `provenance` with the bound sender's fields set (replacing any it had).
pub fn stamp_sender(mut provenance: Value, sender: Option<&BoundSender>) -> Value {
    if let (Some(sender), Some(fields)) = (sender, provenance.as_object_mut()) {
        for (key, value) in [(FROM_SESSION_ID, &sender.session_id), (FROM_HARNESS, &sender.harness)]
        {
            if let Some(value) = value {
                fields.insert(key.to_owned(), json!(value));
            }
        }
    }
    provenance
}

/// The `fromSessionId` and `fromHarness` a prompt's provenance carries (`stamp_sender`).
pub fn sender_of(provenance: Option<&Value>) -> (Option<String>, Option<String>) {
    let field = |k: &str| provenance?.get(k)?.as_str().map(str::to_owned);
    (field(FROM_SESSION_ID), field(FROM_HARNESS))
}

#[cfg(test)]
mod sender_tests {
    use super::*;

    #[test]
    fn a_peer_link_names_a_sender_only_for_its_own_prompt_and_only_well_formed() {
        let sent = |mux: Value| json!({"_meta": {"acpmux": mux}});
        let both = sent(json!({"fromSessionId": "s-1", "fromHarness": "claude"}));
        let bound = BoundSender { session_id: Some("s-1".into()), harness: Some("claude".into()) };
        assert_eq!(peer_sender(&both), Some(bound.clone()));
        assert_eq!(sent(bound.mux_fields())["_meta"]["acpmux"], both["_meta"]["acpmux"]);
        // Forwarded for the peer's own Web, app or device client: no sender.
        let via = sent(json!({"fromSessionId": "s-1", "fromHarness": "claude", "via": "web"}));
        assert_eq!(peer_sender(&via), None);
        // Malformed fields are dropped one by one, never refused.
        let odd = sent(json!({"fromSessionId": "s-1\nx", "fromHarness": "co dex"}));
        assert_eq!(peer_sender(&odd), None);
        let half = sent(json!({"fromSessionId": "s-2", "fromHarness": 7}));
        assert_eq!(peer_sender(&half).and_then(|s| s.session_id).as_deref(), Some("s-2"));
        assert_eq!(peer_sender(&json!({})), None);
    }

    #[test]
    fn a_chief_turn_session_signs_with_the_chief_name_and_id() {
        let tag = |v: &str| crate::store::Tag { value: v.into(), expires_at: None };
        let mut meta: crate::store::SessionMeta = serde_json::from_value(json!({
            "schema": "acpmux.session.v1", "id": "s-1", "name": "optchat-b902d10e-2991",
            "harness": "claude", "family": "claude", "cwd": "/tmp", "status": "idle",
            "createdAt": 1, "updatedAt": 2,
        }))
        .unwrap();
        let found = |meta: &crate::store::SessionMeta| {
            let meta = meta.clone();
            move |id: &str| (id == "s-1").then(|| meta.clone())
        };
        let pumped = json!({"kind": "agent_message", "from": "acp:s-1", "to": "acp:s-2", "msgId": "m", "threadId": "t"});
        let sent = session_message("s-1", "optchat-b902d10e-2991", "s-2");
        // A session no Chief made: as it was.
        meta.tags.insert(LABEL_TAG.into(), tag("lane"));
        assert_eq!(stamp_chief(sent.clone(), found(&meta)), sent);
        assert_eq!(stamp_chief(pumped.clone(), found(&meta)), pumped);
        // A Chief's turn: the Chief's name and participant id, on both kinds.
        meta.tags.insert(LABEL_TAG.into(), tag("Ops Chief"));
        meta.tags.insert(CHIEF_PARTICIPANT_TAG.into(), tag("agent_ops"));
        for given in [sent, pumped] {
            let stamped = stamp_chief(given.clone(), found(&meta));
            assert_eq!(stamped["fromName"], "Ops Chief");
            assert_eq!(stamped[FROM_CHIEF], "agent_ops");
            assert_eq!(stamped["from"], given["from"]);
        }
        // Another sender, a person's prompt, or a sender this daemon does not have: untouched.
        let other = json!({"kind": "agent_message", "from": "acp:s-9", "to": "acp:s-2", "msgId": "m", "threadId": "t"});
        assert_eq!(stamp_chief(other.clone(), found(&meta)), other);
        let person = json!({"kind": "person_message", "from": "s-1", "fromName": "Ana"});
        assert_eq!(stamp_chief(person.clone(), found(&meta)), person);
    }

    #[test]
    fn a_stamp_replaces_what_the_provenance_had_and_reads_back() {
        let given = json!({"kind": "agent_message", "from": "fromAgent", "fromHarness": "fake"});
        let bound = BoundSender { session_id: Some("s-1".into()), harness: Some("codex".into()) };
        let stamped = stamp_sender(given.clone(), Some(&bound));
        assert_eq!(sender_of(Some(&stamped)), (Some("s-1".into()), Some("codex".into())));
        assert_eq!(stamp_sender(given.clone(), None), given);
        assert_eq!(sender_of(None), (None, None));
        let mut params = json!({"_meta": {"acpmux": {"fromSessionId": "x", "fromHarness": "y", "promptId": "p"}}});
        drop_sender_fields(&mut params);
        assert_eq!(params, json!({"_meta": {"acpmux": {"promptId": "p"}}}));
    }
}

#[cfg(test)]
mod trigger_tests {
    use super::*;

    fn params(provenance: Value) -> Value {
        json!({"_meta": {"acpmux": {"provenance": provenance}}})
    }

    #[test]
    fn trigger_provenance_is_bounded_and_is_not_a_person_message() {
        let value = params(json!({
            "kind": "trigger",
            "triggerId": "tr_1",
            "deliveryId": "gh-123",
            "owner": "user_1",
            "team": "team_1",
            "machine": "machine_1",
            "workspace": "workspace_1",
            "session": "session_1"
        }));
        assert!(of(&value, Sender::Local).is_err());
        let parsed = of(&value, Sender::Trigger).unwrap().unwrap();
        assert_eq!(parsed["kind"], "trigger");
        assert!(is_trigger(Some(&parsed)));
        assert!(crate::author::of_provenance(Some(&parsed)).is_none());
    }

    #[test]
    fn trigger_provenance_cannot_arrive_from_a_remote_or_carry_newlines() {
        let remote = params(
            json!({"kind": "trigger", "triggerId": "tr", "deliveryId": "d", "owner": "o", "team": "t", "machine": "m"}),
        );
        assert!(of(&remote, Sender::Other).is_err());
        let malformed = params(
            json!({"kind": "trigger", "triggerId": "tr\n", "deliveryId": "d", "owner": "o", "team": "t", "machine": "m"}),
        );
        assert!(of(&malformed, Sender::Local).is_err());
    }
}

#[cfg(test)]
mod notice_tests {
    use super::*;

    fn params(notice: Value) -> Value {
        json!({"_meta": {"acpmux": {"notice": notice}}})
    }

    fn fire() -> Value {
        json!({"sender": "base-red-watch", "host": "ci-mini-3", "severity": "fire",
               "title": "cmux-next fast tier failed on 3 PRs",
               "links": [{"url": "https://github.com/manaflow-ai/cmux/pull/32827", "label": "#32827"}]})
    }

    fn field_of(e: &RpcError) -> (&Value, &Value) {
        let data = e.data.as_ref().expect("refusal data");
        (&data["reason"], &data["field"])
    }

    #[test]
    fn a_notice_is_checked_and_keeps_only_its_known_fields() {
        let mut sent = fire();
        sent["extra"] = json!("dropped");
        sent["links"][0]["extra"] = json!(1);
        let checked = notice_of(&params(sent)).unwrap().unwrap();
        assert_eq!(checked, fire());
        // Only the required fields.
        let bare = json!({"sender": "next-autoland", "severity": "info", "title": "LANDED #1"});
        assert_eq!(notice_of(&params(bare.clone())).unwrap(), Some(bare));
        assert_eq!(notice_of(&json!({})).unwrap(), None);
        assert_eq!(notice_of(&params(Value::Null)).unwrap(), None);
    }

    #[test]
    fn a_bad_notice_field_refuses_the_prompt_naming_the_field() {
        let with = |key: &str, value: Value| {
            let mut n = fire();
            n[key] = value;
            n
        };
        let without = |key: &str| {
            let mut n = fire();
            n.as_object_mut().unwrap().remove(key);
            n
        };
        let link = |l: Value| with("links", json!([l]));
        let cases = [
            (json!("text"), "notice"),
            (without("sender"), "sender"),
            (with("sender", json!("a\nb")), "sender"),
            (with("sender", json!("s".repeat(65))), "sender"),
            (with("sender", json!("x\u{202E}y")), "sender"),
            (with("host", json!("cosmic gray")), "host"),
            (with("host", json!("h".repeat(65))), "host"),
            (without("severity"), "severity"),
            (with("severity", json!("critical")), "severity"),
            (without("title"), "title"),
            (with("title", json!("   ")), "title"),
            (with("title", json!("t".repeat(201))), "title"),
            (with("title", json!("one\ntwo")), "title"),
            (with("links", json!("https://x")), "links"),
            (with("links", json!(vec![json!({"url": "https://x.dev"}); 17])), "links"),
            (link(json!({"url": "http://x.dev"})), "links.url"),
            (link(json!({"url": "javascript:alert(1)"})), "links.url"),
            (link(json!({"url": "https://"})), "links.url"),
            (link(json!({"url": "https://x.dev/a b"})), "links.url"),
            (link(json!({"label": "#1"})), "links.url"),
            (link(json!({"url": "https://x.dev", "label": "l".repeat(65)})), "links.label"),
            (link(json!({"url": "https://x.dev", "label": 7})), "links.label"),
        ];
        for (notice, field) in cases {
            let e = notice_of(&params(notice.clone())).unwrap_err();
            assert_eq!(field_of(&e), (&json!("notice.value_refused"), &json!(field)), "{notice}");
        }
        // At the bounds: accepted.
        let longest = with("title", json!("t".repeat(200)));
        assert!(notice_of(&params(longest)).is_ok());
        let sixteen = with("links", json!(vec![json!({"url": "https://x.dev"}); 16]));
        assert!(notice_of(&params(sixteen)).is_ok());
    }

    #[test]
    fn a_notice_is_stamped_as_a_named_senders_message_that_carries_it() {
        let checked = notice_of(&params(fire())).unwrap().unwrap();
        let stamped = notice(&checked, "s-1");
        assert_eq!(
            stamped,
            json!({"kind": "notice", "from": "fromAgent", "fromName": "base-red-watch", "to": "s-1",
                   "notice": fire()})
        );
        assert!(is_notice(Some(&stamped)));
        assert!(!is_notice(Some(&named_sender("x", "s-1"))));
        // It survives a record: marked and read back whole.
        let record = marked(json!({"promptId": "p"}), Some(&stamped));
        assert_eq!(recorded(&record), Some(stamped));
    }

    #[test]
    fn a_notice_renders_its_text_for_the_model_and_old_pages() {
        let checked = notice_of(&params(fire())).unwrap().unwrap();
        assert_eq!(
            notice_text(&checked, "fast tier red on #32827, #32830, #32831\n"),
            "[notice from base-red-watch on ci-mini-3 · FIRE] cmux-next fast tier failed on 3 PRs\n\
             fast tier red on #32827, #32830, #32831\n\
             Links: https://github.com/manaflow-ai/cmux/pull/32827 (#32827)"
        );
        let warn = json!({"sender": "s", "severity": "warn", "title": "T",
                          "links": [{"url": "https://a.dev"}, {"url": "https://b.dev", "label": "b"}]});
        assert_eq!(
            notice_text(&warn, ""),
            "[notice from s · WARN] T\nLinks: https://a.dev, https://b.dev (b)"
        );
        let info = json!({"sender": "s", "severity": "info", "title": "T"});
        assert_eq!(notice_text(&info, "body"), "[notice from s] T\nbody");
    }

    #[test]
    fn a_link_argument_splits_its_label_off_and_keeps_a_querys_equals() {
        let pr = "https://github.com/manaflow-ai/cmux/pull/32827";
        assert_eq!(notice_link(pr), json!({"url": pr}));
        assert_eq!(notice_link(&format!("{pr}=#32827")), json!({"url": pr, "label": "#32827"}));
        assert_eq!(notice_link(&format!("{pr}=")), json!({"url": pr}));
        let run = "https://x.dev/run?id=5&attempt=2";
        assert_eq!(notice_link(run), json!({"url": run}));
        assert_eq!(notice_link(&format!("{run}=run 5")), json!({"url": run, "label": "run 5"}));
    }

    #[test]
    fn a_notice_beside_a_callers_provenance_is_refused() {
        let mut both = params(fire());
        both["_meta"]["acpmux"]["provenance"] = json!({"kind": "agent_message"});
        let e = notice_checked(&both).unwrap_err();
        assert_eq!(field_of(&e), (&json!("notice.value_refused"), &json!("provenance")));
        assert!(notice_checked(&params(fire())).unwrap().is_some());
    }

    #[test]
    fn only_the_unix_socket_or_a_peer_may_send_a_notice() {
        let e = notice_origin_refused();
        assert_eq!(e.data.as_ref().unwrap()["reason"], "notice.origin_refused");
        assert!(notice_present(&params(fire())));
        assert!(!notice_present(&params(Value::Null)));
    }
}
