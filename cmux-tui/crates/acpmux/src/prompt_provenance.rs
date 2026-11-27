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
//! (`_acpmux/queue_edit`) keeps it and names its editor (`editedBy`).
//!
//! Who sent a prompt is kept apart from what it claims (Leo, 2026-11-05: "why is it sending it as
//! if it were me?"): `verified` says whether the daemon bound the sender (a caller-proven session,
//! the hub's own prompt) or the sender only named itself; `transport` is how it came (`unix`,
//! `app`, `web`, `peer`, `trigger`); `claimed` holds labels it gave that prove nothing (`cliHost`,
//! `fromHarness`). No label or environment variable makes a prompt the person's: a connection
//! that proved the person (`hub/person.rs`), an authenticated paired client, a peer attesting its
//! own proven connection, or the owner's own terminal send (a plain unix connection with no caller
//! token that claims no sender, harness or relay, `server/requests.rs` `owner_terminal`). Any
//! other prompt naming no sender is `unverified` ([`unverified`]), and the person's own record
//! says `_meta.origin` ([`ORIGIN`]).
//! What a prompt may do (permissions, approvals) is decided elsewhere and never from these.
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
    json!({"kind": "session_message", "from": from, "fromName": from_name, "to": to, VERIFIED: true})
}

/// On a [`session_message`]: the Claude Code subagent in the sending session that sent it,
/// `{id, type}` (`cli/sender.rs` `SUBAGENT_ENV`, marked by acpmux's Bash hook). The session is
/// still the one its caller token proves (`from`, `verified`); this says only which of its
/// agents, so the receiver knows its reply reaches that subagent through the send it answers,
/// and a later `acpmux send` to the session reaches the lead.
pub const FROM_SUBAGENT: &str = "fromSubagent";

/// `provenance` (a [`session_message`] the daemon bound to the caller's proven session) with the
/// subagent the send named (`_meta.acpmux.callerSubagent`), when well formed; else unchanged.
pub fn with_subagent(mut provenance: Value, params: &Value) -> Value {
    if provenance.get("kind").and_then(Value::as_str) != Some("session_message") {
        return provenance;
    }
    let Some(sub) = subagent_of(params) else { return provenance };
    provenance.set(FROM_SUBAGENT, sub);
    provenance
}

/// Set beside [`FROM_SUBAGENT`] when the subagent's message starts a turn of a lane of its own
/// lead: that turn's answer reaches the subagent (`hub/lane_report_subagents.rs`).
pub const SUBAGENT_GETS_REPLY: &str = "subagentGetsReply";

/// `provenance` marked [`SUBAGENT_GETS_REPLY`] when it names a subagent ([`FROM_SUBAGENT`]).
pub fn subagent_gets_reply(mut provenance: Value) -> Value {
    if provenance.get(FROM_SUBAGENT).is_some() {
        provenance.set(SUBAGENT_GETS_REPLY, json!(true));
    }
    provenance
}

/// The subagent a send names (`_meta.acpmux.callerSubagent`), `{id, type}`, when both are plain
/// words (`cli::sender::subagent_word`).
pub fn subagent_of(params: &Value) -> Option<Value> {
    let sub = params.pointer("/_meta/acpmux/callerSubagent")?;
    let word = |key: &str| {
        sub.get(key).and_then(Value::as_str).filter(|w| crate::cli::sender::subagent_word(w))
    };
    let (id, kind) = (word("id")?, word("type")?);
    Some(json!({"id": id, "type": kind}))
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
    json!({"kind": "agent_message", "from": NAMED_SENDER, "fromName": name, "to": to, VERIFIED: false})
}

/// Whether the daemon itself bound the sender's identity (`true`: a caller-proven session, the
/// hub's own prompt), or the sender only claimed it (`false`: a name, a peer's label, a
/// provenance a client sent). Set by the daemon only: a client's own `verified` is never read
/// ([`of`] keeps only its listed fields), and the person's prompt carries none (see [`ORIGIN`]).
pub const VERIFIED: &str = "verified";
/// How the prompt reached this daemon, as the daemon saw it: `unix` (the socket, any local
/// process of the user), `app` (the app's own connection), `web`, `peer`, `carrier`, `trigger`.
pub const TRANSPORT: &str = "transport";
/// Labels a sender gave about itself that prove nothing (`cliHost`, `fromHarness`): kept apart
/// from who the daemon knows sent it.
pub const CLAIMED: &str = "claimed";

/// The provenance kind of a prompt no proof attributes: not the proven person's (the app's own
/// connection, a paired device, the owner's own terminal send), and naming no sender. A local
/// process that claims a harness or relay, or holds a caller token it could not prove, may send
/// it, so it is shown as an unknown sender, never as the person (Leo, 2026-11-05: "why is it
/// sending it as if it were me?").
pub const UNVERIFIED_KIND: &str = "unverified";

/// Who started a handoff whose start is not the proven person's (`hub/handoff/ops.rs`): its
/// first prompt is [`unverified`], over `transport`.
#[derive(Clone, Copy, Debug)]
pub struct HandoffSender {
    pub transport: &'static str,
}

/// The provenance of a prompt no proof attributes ([`UNVERIFIED_KIND`]), with the transport it
/// came over and the labels it claimed.
pub fn unverified(to: &str, transport: &str, claimed: Map<String, Value>) -> Value {
    let mut out = json!({"kind": UNVERIFIED_KIND, "to": to, TRANSPORT: transport, VERIFIED: false});
    if !claimed.is_empty() {
        out.set(CLAIMED, Value::Object(claimed));
    }
    out
}

/// `provenance` with labels its sender claimed ([`CLAIMED`]), beside any it had.
pub fn with_claimed<'a>(
    mut provenance: Value,
    labels: impl IntoIterator<Item = (&'a str, String)>,
) -> Value {
    if let Some(fields) = provenance.as_object_mut() {
        let claimed = fields.entry(CLAIMED).or_insert_with(|| json!({}));
        if let Some(claimed) = claimed.as_object_mut() {
            for (key, value) in labels {
                claimed.insert(key.to_owned(), json!(value));
            }
        }
    }
    provenance
}

/// `provenance` with `verified` false unless the daemon set it, and the transport it came over.
pub fn observed(mut provenance: Value, transport: &str) -> Value {
    if let Some(fields) = provenance.as_object_mut() {
        fields.entry(VERIFIED).or_insert(json!(false));
        fields.entry(TRANSPORT).or_insert(json!(transport));
    }
    provenance
}

/// Who edited a waiting prompt (`hub/queue_edit.rs`): `{actor: "owner"}`, or `{actor: "person",
/// id}` for another person (`author.rs`). The prompt keeps its sender's provenance; this says
/// only who changed the words, and authorizes nothing.
pub const EDITED_BY: &str = "editedBy";

/// `provenance` with its editor ([`EDITED_BY`]) for `editor` (`author::Editor`).
pub fn edited_by(mut provenance: Value, editor: crate::author::Editor<'_>) -> Value {
    let by = match editor {
        Some(Some(id)) => json!({"actor": "person", "id": id}),
        Some(None) => json!({"actor": "owner"}),
        None => return provenance,
    };
    if let Some(fields) = provenance.as_object_mut() {
        fields.insert(EDITED_BY.to_owned(), by);
    }
    provenance
}

/// Whether `provenance` is [`UNVERIFIED_KIND`]: no one's for sure. It is never the person's (no
/// protected hold goes on for it, `hub/turns.rs`, and the apps draw no person's bubble), and it names
/// no other sender either, so what acpmux does for an unnamed prompt's activity (the person's
/// presence, the CLI host on its record, a withdraw's refusal) stays as it was.
pub fn is_unverified(provenance: Option<&Value>) -> bool {
    provenance.and_then(|p| p.get("kind")).and_then(Value::as_str) == Some(UNVERIFIED_KIND)
}

/// Who passed the prompt on to this daemon when its sender is elsewhere: `{actor: "peer"}` and the
/// peer's `via` (`server/remote_guard.rs` `mark_forwarded`) for a prompt a peer daemon forwarded.
/// Kept beside the original sender, never in its place, and it authorizes nothing.
pub const FORWARDED_BY: &str = "forwardedBy";

/// `provenance` with the peer that forwarded it ([`FORWARDED_BY`]); `via` is the peer's word for
/// where it came from there (`web`, `app`, `device`), kept as a claim.
pub fn forwarded_by_peer(mut provenance: Value, via: Option<&str>) -> Value {
    let mut by = json!({"actor": "peer"});
    if let Some(via) = via.filter(|v| !v.is_empty() && v.len() <= MAX_FIELD_BYTES) {
        by.set("via", json!(via));
    }
    if let Some(fields) = provenance.as_object_mut() {
        fields.insert(FORWARDED_BY.to_owned(), by);
    }
    provenance
}

/// On a `user_message` or `queued` record with no provenance: the daemon admitted the prompt as
/// the proven person's (`_meta.origin`). A record with neither predates it and is shown as
/// unverified, never as the person.
pub const ORIGIN: &str = "origin";

/// The provenance kind of a tool's notice ([`notice`]).
pub const NOTICE_KIND: &str = "notice";
/// A peer-carried proof that the originating connection was a verified person.
pub const PERSON_VERIFIED: &str = "personVerified";
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
    let Some(fields) = record.as_object_mut() else { return record };
    let Some(p) = provenance else {
        // Every prompt the daemon cannot attribute to the proven person carries a provenance
        // (`unverified` at the least), so one without is the person's: say so positively.
        let meta = fields.entry("_meta").or_insert_with(|| json!({}));
        if let Some(meta) = meta.as_object_mut() {
            meta.insert(ORIGIN.to_owned(), json!({"actor": "person", VERIFIED: true}));
        }
        return record;
    };
    let mut p = p.clone();
    let messages = take_message_meta(&mut p);
    let mut meta = json!({"provenance": p});
    if let Some(messages) = messages {
        meta.set(MESSAGE_META, messages);
    }
    fields.insert("_meta".to_owned(), meta);
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

/// `_meta.acpmux.fromRelay`: `{"by", "machine", "session"}`, a relay's word on where a message it
/// carries came from: the lane-gh broker relays a lane VM's `lane-gh send` and knows the calling
/// machine by its own link to it (the session is that machine's word, as a peer's `fromSessionId`
/// is the peer's). Display only, as [`FROM_SESSION_ID`] is.
///
/// Taken from a relay only on this machine's unix socket, from a connection that proved no
/// session (`relay_sender`): the broker runs `acpmux send` there outside any session. An agent's
/// send always proves its session (its caller token), so a `fromRelay` it writes is dropped, as a
/// Web, app or guest client's is; over a peer link it is that daemon's word, as `fromSessionId` is.
/// A process of this machine's user that drops its caller token can write one too: the trust is
/// the machine's user, as the unix socket's is.
pub const FROM_RELAY: &str = "fromRelay";

/// Where a relayed message came from ([`FROM_RELAY`]).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RelaySender {
    /// The relay, as it names itself (`lane-gh`).
    pub by: String,
    /// The machine the relay took the message from.
    pub machine: String,
    /// The session on that machine that sent it, in that machine's word.
    pub session: Option<String>,
}

impl RelaySender {
    /// The relay record in `value`, each field one name of at most [`MAX_NAME_CHARS`] (a
    /// session at most [`MAX_FIELD_BYTES`]); anything else is no relay record.
    fn of(value: &Value) -> Option<Self> {
        let field = |k: &str| value.get(k).and_then(Value::as_str);
        let by = field("by").filter(|b| harness_fits(b))?;
        let machine = field("machine").filter(|m| harness_fits(m))?;
        let session = match value.get("session") {
            None | Some(Value::Null) => None,
            Some(Value::String(s)) if fits(s, MAX_FIELD_BYTES) => Some(s.clone()),
            Some(_) => return None,
        };
        Some(Self { by: by.to_owned(), machine: machine.to_owned(), session })
    }

    fn to_value(&self) -> Value {
        json!({"by": self.by, "machine": self.machine, "session": self.session})
    }

    /// How the sender reads as its label (`fromAgent`): `MACHINE/SESSION`, or the machine alone,
    /// cut to [`relayed_label`]'s length. The record keeps the whole name.
    pub fn name(&self) -> String {
        match &self.session {
            Some(session) => relayed_label(&format!("{}/{session}", self.machine)),
            None => self.machine.clone(),
        }
    }
}

/// A relayed `MACHINE/SESSION` as a sender label: one line within `fromAgent`'s length
/// (`hub::declared_sender`), so a long session name never refuses the send. Who sent it is the
/// relay record's ([`FROM_RELAY`]), whole; the label only names it.
pub fn relayed_label(name: &str) -> String {
    let name: String =
        name.chars().filter(|c| !unshown(*c)).take(crate::hub::MAX_FROM_AGENT_CHARS).collect();
    name.trim().to_owned()
}

/// The relay record a prompt's provenance carries ([`FROM_RELAY`]).
pub fn relay_of(provenance: Option<&Value>) -> Option<RelaySender> {
    RelaySender::of(provenance?.get(FROM_RELAY)?)
}

/// A caller-supplied sender label kept beside authenticated provenance.  It is deliberately
/// separate from `fromName`: the latter is the daemon's name for a proven session.
pub const DECLARED_LABEL: &str = "declared";

/// The sending session's id and harness family, as far as the daemon bound them.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct BoundSender {
    pub session_id: Option<String>,
    pub harness: Option<String>,
    /// A relay's word on the machine and session it took the message from ([`FROM_RELAY`]).
    pub relay: Option<RelaySender>,
}

impl BoundSender {
    /// A session of this daemon: its id and its harness family (`web_modes::family_of`).
    pub fn of_session(id: &str, meta: &crate::store::SessionMeta) -> Self {
        Self {
            session_id: fits(id, MAX_FIELD_BYTES).then(|| id.to_owned()),
            harness: Some(crate::web_modes::family_of(meta)).filter(|h| harness_fits(h)),
            relay: None,
        }
    }

    fn is_empty(&self) -> bool {
        self.session_id.is_none() && self.harness.is_none() && self.relay.is_none()
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
        if let Some(relay) = &self.relay {
            out.insert(FROM_RELAY.to_owned(), relay.to_value());
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
        relay: mux.get(FROM_RELAY).and_then(RelaySender::of),
    };
    (!sender.is_empty()).then_some(sender)
}

/// The sender a relay on this machine named for a prompt ([`FROM_RELAY`]): its relay record and
/// the harness it named with it, never a session id of this daemon's (a relay proves none).
/// `None` without a well-formed relay record. Only for a unix-socket connection that proved no
/// session (`server/requests.rs` `stamp_bound_sender`, `server/peer_forward.rs`).
pub fn relay_sender(params: &Value) -> Option<BoundSender> {
    let mux = params.pointer("/_meta/acpmux")?;
    let relay = RelaySender::of(mux.get(FROM_RELAY)?)?;
    let harness = mux.get(FROM_HARNESS).and_then(Value::as_str).filter(|h| harness_fits(h));
    Some(BoundSender { session_id: None, harness: harness.map(str::to_owned), relay: Some(relay) })
}

/// Takes `fromSessionId`, `fromHarness` and `fromRelay` out of a prompt's `_meta.acpmux`: what a
/// client wrote never goes on to a peer as this daemon's word.
pub fn drop_sender_fields(params: &mut Value) {
    if let Some(mux) = params.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut) {
        mux.remove(FROM_SESSION_ID);
        mux.remove(FROM_HARNESS);
        mux.remove(FROM_RELAY);
    }
}

/// The harness a local named sender declared for itself (`_meta.acpmux.fromHarness`, an agent
/// harness's own shell, `cli/sender.rs`): only a label the card draws, never a proof of anything,
/// and only beside a sender name (`fromAgent`). `None` when absent or not a harness family name.
pub fn declared_harness(params: &Value) -> Option<BoundSender> {
    let mux = params.pointer("/_meta/acpmux")?;
    mux.get("fromAgent").and_then(Value::as_str)?;
    let harness = mux.get(FROM_HARNESS)?.as_str().filter(|h| harness_fits(h))?;
    Some(BoundSender { session_id: None, harness: Some(harness.to_owned()), relay: None })
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
        if let Some(relay) = &sender.relay {
            fields.insert(FROM_RELAY.to_owned(), relay.to_value());
        }
    }
    provenance
}

/// The `fromSessionId` and `fromHarness` a prompt's provenance carries (`stamp_sender`).
pub fn sender_of(provenance: Option<&Value>) -> (Option<String>, Option<String>) {
    let field = |k: &str| provenance?.get(k)?.as_str().map(str::to_owned);
    (field(FROM_SESSION_ID), field(FROM_HARNESS))
}

/// The label a caller declared with `--from`/`ACPMUX_FROM`, when it survived alongside a
/// caller-token or peer-stamped provenance.  Older named-sender records use `fromName`.
pub fn declared_label(provenance: Option<&Value>) -> Option<String> {
    let provenance = provenance?;
    provenance
        .get(DECLARED_LABEL)
        .or_else(|| {
            (provenance.get("from").and_then(Value::as_str) == Some(NAMED_SENDER))
                .then(|| provenance.get("fromName"))
                .flatten()
        })
        .and_then(Value::as_str)
        .filter(|label| !label.trim().is_empty())
        .map(str::to_owned)
}

/// Keep a caller's self-declared label when the daemon also has authenticated provenance.
pub fn stamp_declared(mut provenance: Value, label: Option<&str>) -> Value {
    if let Some(label) = label.filter(|label| !label.trim().is_empty()) {
        provenance.set(DECLARED_LABEL, json!(label));
    }
    provenance
}

/// The additive sender projection carried by an inbox message.  `legacy_session` is the old
/// `from`/`fromSession` value and is retained for historical records, but it never upgrades a
/// record to authenticated.  Only `fromSessionId` (stamped by this daemon or an authenticated
/// peer) does that.
pub fn sender_record(
    provenance: Option<&Value>,
    legacy_session: Option<&str>,
    meta: Option<&crate::store::SessionMeta>,
) -> Value {
    sender_record_with_auth(provenance, legacy_session, meta, false)
}

/// Sender projection with the connection proof for a human author. Agent provenance remains
/// authenticated only through the daemon-stamped session fields; a `kind` label alone is not
/// proof of a person.
pub fn sender_record_with_auth(
    provenance: Option<&Value>,
    legacy_session: Option<&str>,
    meta: Option<&crate::store::SessionMeta>,
    human_authenticated: bool,
) -> Value {
    let empty = Value::Null;
    let provenance = provenance.unwrap_or(&empty);
    let (stamped_session, harness) = sender_of(Some(provenance));
    let relay = relay_of(Some(provenance));
    let authenticated = stamped_session.is_some() || relay.is_some() || human_authenticated;
    let session = stamped_session.clone().or_else(|| legacy_session.map(str::to_owned));
    let label = declared_label(Some(provenance));
    // A named sender this host's sender token proved (`sender_token.rs`): its name is verified,
    // though no session is (`authenticated` stays the session's or relay's proof).
    let token = crate::sender_token::verified_by_token(provenance);
    let verification = if authenticated || token {
        "verified"
    } else if label.is_some() {
        "declared"
    } else {
        "legacy"
    };
    let family = harness.clone().or_else(|| meta.map(crate::web_modes::family_of));
    let has_parent = meta.is_some_and(|m| m.lineage.is_some() || m.subsession.is_some());
    let actor_kind = if human_authenticated {
        "authenticated_human"
    } else if authenticated && meta.is_some() && !has_parent {
        "root_assistant"
    } else if authenticated && family.as_deref().is_some_and(|f| f.eq_ignore_ascii_case("codex")) {
        "codex_worker"
    } else {
        "other_agent"
    };
    let actor_id = stamped_session
        .as_ref()
        .map(|id| {
            provenance
                .get("peer")
                .or_else(|| provenance.get("fromPeer"))
                .and_then(Value::as_str)
                .map_or_else(|| id.clone(), |peer| format!("{peer}:{id}"))
        })
        .or_else(|| {
            human_authenticated
                .then(|| provenance.get("from").and_then(Value::as_str).map(str::to_owned))
                .flatten()
        });
    let parent = meta
        .and_then(|m| m.lineage.as_ref().map(|lineage| lineage.parent.clone()))
        .or_else(|| provenance.get("parent").and_then(Value::as_str).map(str::to_owned));
    let delegator = meta
        .and_then(|m| m.delegator.clone())
        .or_else(|| provenance.get("delegator").and_then(Value::as_str).map(str::to_owned));

    // A message copy records the original sender beside the authenticated forwarder.  This is
    // additive and intentionally accepts only daemon-carried objects, never a --from string.
    let author = provenance
        .get("author")
        .or_else(|| provenance.get("originalAuthor"))
        .or_else(|| provenance.pointer("/_acpmuxMessage/sender"))
        .cloned();
    let forwarded_by = provenance
        .get("forwardedBy")
        .or_else(|| provenance.get("forwarder"))
        .or_else(|| provenance.pointer("/_acpmuxMessage/forwardedBy"))
        .cloned()
        .or_else(|| {
            author.as_ref().and_then(|author| {
                let author_session = author
                    .get("sessionId")
                    .or_else(|| author.get("session"))
                    .and_then(Value::as_str)
                    .or_else(|| author.as_str());
                (authenticated
                    && author_session.is_some_and(|id| Some(id) != stamped_session.as_deref()))
                .then(|| json!({"session": stamped_session}))
            })
        });

    let mut record = json!({
        "session": session,
        "authenticated": authenticated,
        "harness": harness,
        "relay": relay.as_ref().map(RelaySender::to_value),
        "label": label,
        "labelDeclared": label.is_some(),
        "author": author,
        "forwardedBy": forwarded_by,
        "actorKind": actor_kind,
        "actorId": actor_id,
        "parent": parent,
        "delegator": delegator,
        "verification": verification,
    });
    // The sending subagent ([`FROM_SUBAGENT`]) only where there is one: other records stay as
    // they were.
    if let Some(sub) = provenance.get(FROM_SUBAGENT).filter(|s| s.is_object()) {
        record.set("subagent", sub.clone());
    }
    if token {
        record.set(crate::sender_token::VERIFIED_BY_KEY, json!(crate::sender_token::VERIFIED_BY));
    }
    record
}

#[cfg(test)]
mod sender_tests {
    use super::*;

    #[test]
    fn a_named_local_sender_may_say_its_harness_and_nothing_else() {
        let sent = |mux: Value| json!({"_meta": {"acpmux": mux}});
        let named = sent(json!({"fromAgent": "codex@workstation", "fromHarness": "codex"}));
        let harness = declared_harness(&named);
        assert_eq!(
            harness,
            Some(BoundSender { session_id: None, harness: Some("codex".into()), relay: None })
        );
        let stamped = stamp_sender(named_sender("codex@workstation", "s-2"), harness.as_ref());
        assert_eq!(stamped["kind"], "agent_message");
        assert_eq!(sender_of(Some(&stamped)), (None, Some("codex".into())));
        // No name, or a harness that is not a family name: no label.
        assert_eq!(declared_harness(&sent(json!({"fromHarness": "codex"}))), None);
        assert_eq!(
            declared_harness(&sent(json!({"fromAgent": "a", "fromHarness": "co dex"}))),
            None
        );
    }

    #[test]
    fn a_peer_link_names_a_sender_only_for_its_own_prompt_and_only_well_formed() {
        let sent = |mux: Value| json!({"_meta": {"acpmux": mux}});
        let both = sent(json!({"fromSessionId": "s-1", "fromHarness": "claude"}));
        let bound = BoundSender {
            session_id: Some("s-1".into()),
            harness: Some("claude".into()),
            relay: None,
        };
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
        let bound = BoundSender {
            session_id: Some("s-1".into()),
            harness: Some("codex".into()),
            relay: None,
        };
        let stamped = stamp_sender(given.clone(), Some(&bound));
        assert_eq!(sender_of(Some(&stamped)), (Some("s-1".into()), Some("codex".into())));
        assert_eq!(stamp_sender(given.clone(), None), given);
        assert_eq!(sender_of(None), (None, None));
        let mut params = json!({"_meta": {"acpmux": {"fromSessionId": "x", "fromHarness": "y", "promptId": "p"}}});
        drop_sender_fields(&mut params);
        assert_eq!(params, json!({"_meta": {"acpmux": {"promptId": "p"}}}));
    }

    #[test]
    fn sender_records_accept_peer_stamps_but_not_client_written_sender_fields() {
        let raw = json!({
            "_meta": {"acpmux": {
                "provenance": {"kind": "agent_message", "from": "fromAgent", "fromName": "dot",
                    "to": "target", "msgId": "m", "threadId": "t"},
                "fromSessionId": "claimed", "fromHarness": "codex"
            }}
        });
        let parsed = of(&raw, Sender::Local).unwrap().unwrap();
        assert_eq!(sender_of(Some(&parsed)), (None, None));
        assert_eq!(sender_record(Some(&parsed), None, None)["authenticated"], false);

        let peer = json!({
            "_meta": {"acpmux": {
                "fromSessionId": "peer-session", "fromHarness": "codex",
                "provenance": parsed
            }}
        });
        let stamped = stamp_sender(
            peer["_meta"]["acpmux"]["provenance"].clone(),
            peer_sender(&peer).as_ref(),
        );
        let record = sender_record(Some(&stamped), None, None);
        assert_eq!(record["session"], "peer-session");
        assert_eq!(record["authenticated"], true);
        assert_eq!(record["verification"], "verified");
    }

    #[test]
    fn sender_records_keep_declared_labels_separate_from_authenticated_sessions() {
        let declared = named_sender("dot", "target");
        let record = sender_record(Some(&declared), None, None);
        assert_eq!(record["session"], Value::Null);
        assert_eq!(record["authenticated"], false);
        assert_eq!(record["label"], "dot");
        assert_eq!(record["labelDeclared"], true);
        assert_eq!(record["verification"], "declared");

        let authenticated = stamp_declared(
            stamp_sender(
                session_message("s-1", "worker", "target"),
                Some(&BoundSender {
                    session_id: Some("s-1".into()),
                    harness: Some("codex".into()),
                    relay: None,
                }),
            ),
            Some("dot"),
        );
        let record = sender_record(Some(&authenticated), None, None);
        assert_eq!(record["session"], "s-1");
        assert_eq!(record["authenticated"], true);
        assert_eq!(record["label"], "dot");
        assert_eq!(record["verification"], "verified");
        assert_eq!(declared_label(Some(&authenticated)).as_deref(), Some("dot"));

        let person =
            json!({"kind": crate::author::PERSON_MESSAGE, "from": "user-1", "fromName": "Ana"});
        let unproven = sender_record(Some(&person), None, None);
        assert_eq!(unproven["authenticated"], false);
        assert_eq!(unproven["actorId"], Value::Null);
        let proven = sender_record_with_auth(Some(&person), None, None, true);
        assert_eq!(proven["actorKind"], "authenticated_human");
        assert_eq!(proven["actorId"], "user-1");
    }

    /// A relay's MACHINE/SESSION past `fromAgent`'s length (review of #37652, F1): the record
    /// keeps the whole name and is a verified relay sender; the name it gives the sender label
    /// fits `fromAgent`, so the send is never refused for it.
    #[test]
    fn a_long_relayed_name_is_recorded_whole_and_named_within_from_agent() {
        let relayed = |session: &str| json!({"_meta": {"acpmux": {"fromRelay": {"by": "lane-gh", "machine": "vm-1", "session": session}}}});
        let session = format!("cloud-start-matrix-{}", "x".repeat(60));
        let bound = relay_sender(&relayed(&session)).unwrap();
        let relay = bound.relay.clone().unwrap();
        assert_eq!(relay.session.as_deref(), Some(session.as_str()));
        let name = relay.name();
        assert_eq!(name.chars().count(), crate::hub::MAX_FROM_AGENT_CHARS);
        assert!(format!("vm-1/{session}").starts_with(&name), "{name}");
        let label = json!({"_meta": {"acpmux": {"fromAgent": name}}});
        assert_eq!(crate::hub::declared_sender(&label).unwrap(), Some(name.clone()));
        let stamped =
            stamp_sender(stamp_declared(named_sender(&name, "t"), Some(&name)), Some(&bound));
        let record = sender_record(Some(&stamped), None, None);
        assert_eq!(
            (&record["verification"], &record["relay"]["session"]),
            (&json!("verified"), &json!(session))
        );
        // A short one is named whole; a session past what a relay record holds is no record.
        assert_eq!(relay_sender(&relayed("coord")).unwrap().relay.unwrap().name(), "vm-1/coord");
        assert_eq!(relay_sender(&relayed(&"x".repeat(MAX_FIELD_BYTES + 1))), None);
    }

    #[test]
    fn sender_records_keep_a_relay_author_and_forwarder_distinct() {
        let provenance = json!({
            "kind": "agent_message", "from": "fromAgent", "fromName": "worker",
            "fromSessionId": "forwarder", "fromHarness": "codex",
            "_acpmuxMessage": {"sender": {"sessionId": "author", "name": "original"},
                "forwardedBy": {"session": "forwarder"}},
        });
        let record = sender_record(Some(&provenance), None, None);
        assert_eq!(record["author"]["sessionId"], "author");
        assert_eq!(record["forwardedBy"]["session"], "forwarder");
        assert_eq!(record["actorId"], "forwarder");
    }

    #[test]
    fn sender_records_keep_worker_and_delegator_distinct() {
        let meta: crate::store::SessionMeta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": "worker", "name": "worker",
            "harness": "codex", "cwd": "/tmp", "status": "idle",
            "createdAt": 1, "updatedAt": 1,
            "lineage": {"parent": "root", "root": "root", "depth": 1},
            "delegator": "root"
        }))
        .expect("session metadata");
        let provenance = stamp_sender(
            session_message("worker", "worker", "receiver"),
            Some(&BoundSender {
                session_id: Some("worker".into()),
                harness: Some("codex".into()),
                relay: None,
            }),
        );
        let record = sender_record(Some(&provenance), None, Some(&meta));
        assert_eq!(record["actorKind"], "codex_worker");
        assert_eq!(record["actorId"], "worker");
        assert_eq!(record["parent"], "root");
        assert_eq!(record["delegator"], "root");
    }

    #[test]
    fn sender_actor_metadata_uses_the_stamped_session_not_provenance_from() {
        let meta: crate::store::SessionMeta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": "worker", "name": "worker",
            "harness": "codex", "cwd": "/tmp", "status": "idle",
            "createdAt": 1, "updatedAt": 1,
            "lineage": {"parent": "root", "root": "root", "depth": 1},
            "delegator": "root"
        }))
        .expect("session metadata");
        let provenance = stamp_sender(
            json!({"kind": "session_message", "from": "acp:root", "fromName": "root", "to": "receiver"}),
            Some(&BoundSender {
                session_id: Some("worker".into()),
                harness: Some("codex".into()),
                relay: None,
            }),
        );
        let record = sender_record_with_auth(Some(&provenance), Some("root"), Some(&meta), false);
        assert_eq!(record["actorId"], "worker");
        assert_eq!(record["actorKind"], "codex_worker");
        assert_eq!(record["parent"], "root");
        assert_eq!(record["delegator"], "root");
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

    #[test]
    fn a_record_with_no_provenance_says_it_is_the_proven_persons_and_one_with_keeps_its_own() {
        let own = marked(json!({"promptId": "p", "_meta": {"x": 1}}), None);
        assert_eq!(own["_meta"]["origin"], json!({"actor": "person", "verified": true}));
        assert_eq!(own["_meta"]["x"], 1, "the rest of its _meta stays");
        let theirs = marked(json!({"promptId": "p"}), Some(&named_sender("lane-a", "s")));
        assert!(theirs["_meta"].get("origin").is_none(), "{theirs}");
        assert_eq!(theirs["_meta"]["provenance"]["verified"], false);
    }

    #[test]
    fn an_unverified_prompt_names_no_one_and_keeps_its_claims_apart() {
        let mut claimed = Map::new();
        claimed.insert("cliHost".into(), json!("workstation"));
        let p = unverified("s", "unix", claimed);
        assert_eq!(
            p,
            json!({"kind": "unverified", "to": "s", "transport": "unix", "verified": false,
                   "claimed": {"cliHost": "workstation"}})
        );
        assert!(p.get("fromName").is_none());
        assert!(unverified("s", "unix", Map::new()).get("claimed").is_none());
    }

    #[test]
    fn observed_never_raises_what_the_daemon_set() {
        let session = observed(session_message("a", "lane-a", "b"), "unix");
        assert_eq!(session["verified"], true);
        assert_eq!(session["transport"], "unix");
        let named = observed(named_sender("lane-a", "b"), "peer");
        assert_eq!(named["verified"], false);
        assert_eq!(named["transport"], "peer");
    }

    #[test]
    fn an_edit_and_a_forward_are_named_beside_the_sender_not_in_its_place() {
        let p = named_sender("lane-a", "s");
        let owner = edited_by(p.clone(), Some(None));
        assert_eq!(owner["fromName"], "lane-a");
        assert_eq!(owner["editedBy"], json!({"actor": "owner"}));
        let guest = edited_by(p.clone(), Some(Some("guest:ana")));
        assert_eq!(guest["editedBy"], json!({"actor": "person", "id": "guest:ana"}));
        assert_eq!(edited_by(p.clone(), None), p);
        let forwarded = forwarded_by_peer(p, Some("device"));
        assert_eq!(forwarded["fromName"], "lane-a");
        assert_eq!(forwarded["forwardedBy"], json!({"actor": "peer", "via": "device"}));
    }

    #[test]
    fn a_client_cannot_send_verified_or_an_editor_or_a_forwarder() {
        let params = json!({"_meta": {"acpmux": {"provenance": {
            "kind": "agent_message", "from": "acp:x", "to": "acp:y", "msgId": "m", "threadId": "t",
            "verified": true, "editedBy": {"actor": "owner"}, "forwardedBy": {"actor": "peer"}}}}});
        let p = of(&params, Sender::Local).unwrap().unwrap();
        assert!(p.get("verified").is_none(), "{p}");
        assert!(p.get("editedBy").is_none(), "{p}");
        assert!(p.get("forwardedBy").is_none(), "{p}");
        let unverified = json!({"_meta": {"acpmux": {"provenance": {"kind": "unverified"}}}});
        assert!(of(&unverified, Sender::Local).is_err());
    }
}
