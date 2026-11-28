//! Who sent a message between sessions, as one trailer line at the end of its text, written by
//! the daemon and never by the sender. Leo, 2026-11-21: "well i was also saying attribution auto
//! for messages between sessions".
//!
//! ```text
//! <the message>
//!
//! Sent-by: <host>/<session> harness=<harness> model=<model-id>
//! ```
//!
//! - `host` is the short hostname of the machine whose daemon proved the sender; `session` the
//!   sender session's name; `harness` its harness family (`claude`, `codex`, `opencode`, ...);
//!   `model` the model id the harness reports it runs now (its `model` option, else its
//!   `currentModelId`, else the model it was started with). A field the daemon does not know is
//!   left out, and an alias (`opus`, `default`) is never written as a model ([`model_id`]).
//! - Stamped once, where the daemon takes a send from a connection that proved its session (the
//!   caller token, `server/requests.rs`), before the outbox keeps it or a peer gets it: `acpmux
//!   send`, the MCP `send` tool, a fan-out or tag send and a cross-host send all carry it, and the
//!   receiving daemon keeps the sender's line.
//! - Only the daemon's line counts: in a send from a proven session, any line the sender wrote
//!   that starts `Sent-by: ` is quoted (`> Sent-by: ...`) before the true line goes on, so a
//!   reader (`agent_text.rs`, the chat's `agentText.ts`) never takes it for the sender. The line
//!   also rides in `_meta.acpmux.sentBy` ([`META_KEY`]), which only the daemon sets: a slash
//!   command carries it there alone, so its words stay the command's. Stamping the same send
//!   twice is stamping it once. A lane VM's broker relay sends through a connection that proves
//!   no session, so its own line is kept as it wrote it.
//! - Not stamped: a notice (`_meta.acpmux.notice`), acpmux's own prompts (they come from the hub,
//!   not a caller's connection), a session's note to itself, and a send no session proved (the
//!   person's own terminal send).
//!
//! The format is shared with the lane-gh broker relay and the stats parser that read it; do not
//! change it here alone.

use std::sync::LazyLock;

use serde_json::{Value, json};

/// The start of the trailer line.
pub const PREFIX: &str = "Sent-by: ";

/// Where the daemon carries the line in `_meta.acpmux`, beside the text's own: never taken from a
/// client ([`drop_claimed`]).
pub const META_KEY: &str = "sentBy";

/// What a sender's own [`PREFIX`] line becomes: a quote, which no reader takes for the trailer.
const QUOTE: &str = "> ";

/// What the line names; each field but the session may be unknown.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Sender {
    pub host: Option<String>,
    pub session: String,
    pub harness: Option<String>,
    pub model: Option<String>,
    /// The handle a person or the agent gave it (`acpmux rename @ Mango --handle`): the name
    /// people call it, written last (`handle=Mango`) so readers of the first token keep working.
    pub handle: Option<String>,
}

/// The trailer line for `sender`, with no line break.
pub fn line(sender: &Sender) -> String {
    fn field(v: &Option<String>) -> Option<&str> {
        v.as_deref().map(str::trim).filter(|v| !v.is_empty())
    }
    let mut out = String::from(PREFIX);
    if let Some(host) = field(&sender.host) {
        out.push_str(host);
        out.push('/');
    }
    out.push_str(sender.session.trim());
    if let Some(harness) = field(&sender.harness) {
        out.push_str(" harness=");
        out.push_str(harness);
    }
    if let Some(model) = field(&sender.model) {
        out.push_str(" model=");
        out.push_str(model);
    }
    if let Some(handle) = field(&sender.handle) {
        out.push_str(" handle=");
        out.push_str(handle);
    }
    out
}

/// Whether `text` has a line that starts with [`PREFIX`].
pub fn has_line(text: &str) -> bool {
    text.starts_with(PREFIX) || text.contains(&format!("\n{PREFIX}"))
}

/// `raw` as a model id, or None for an alias or nothing: a `[1m]` context suffix is dropped, and
/// an id has a digit and a `-` and no space (`claude-opus-5-5`, `gpt-6.2-astra`), which `opus`,
/// `sonnet`, `default` and `gpt` do not.
pub fn model_id(raw: &str) -> Option<String> {
    let raw = raw.trim();
    let raw = raw.strip_suffix("[1m]").or_else(|| raw.strip_suffix("[1M]")).unwrap_or(raw).trim();
    let id = !raw.is_empty()
        && raw.contains('-')
        && raw.chars().any(|c| c.is_ascii_digit())
        && !raw.chars().any(char::is_whitespace)
        && raw != "default";
    id.then(|| raw.to_owned())
}

/// The model id session `meta` runs, as its harness reported it ([`model_id`]).
pub fn meta_model(meta: &crate::store::SessionMeta) -> Option<String> {
    let option = meta.config_options.as_deref().and_then(Value::as_array).and_then(|opts| {
        opts.iter()
            .find(|o| o.get("id").and_then(Value::as_str) == Some("model"))
            .and_then(|o| o.get("currentValue").and_then(Value::as_str))
    });
    let current =
        meta.models.as_ref().and_then(|m| m.get("currentModelId")).and_then(Value::as_str);
    // The newest report the harness made decides: a session switched to an alias (`sonnet`)
    // names no model rather than the one it was started with.
    [option, current, meta.model_request.as_deref()].into_iter().flatten().next().and_then(model_id)
}

/// This machine's short hostname, read once.
pub fn this_host() -> Option<String> {
    static HOST: LazyLock<Option<String>> = LazyLock::new(|| {
        let full = crate::hand::pair::hostname();
        let short = full.split('.').next().unwrap_or_default().trim().to_owned();
        (!short.is_empty()).then_some(short)
    });
    HOST.clone()
}

/// Whether `text` is a slash command (`/compact`, `/model opus`): a `/` and a command name, never
/// a path (`/tmp/report.txt`, whose first word has a second `/`).
fn is_command(text: &str) -> bool {
    let Some(word) = text.trim_start().strip_prefix('/').and_then(|t| t.split_whitespace().next())
    else {
        return false;
    };
    !word.is_empty()
        && !word.contains('/')
        && word.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | ':'))
}

/// `text` with each line that starts with [`PREFIX`] quoted, or None when it has none. A line is
/// read from the start of the text or after a `\n`, as the readers read it.
fn quote_lines(text: &str) -> Option<String> {
    if !has_line(text) {
        return None;
    }
    let mut out = String::with_capacity(text.len() + 2 * QUOTE.len());
    for (i, line) in text.split('\n').enumerate() {
        if i > 0 {
            out.push('\n');
        }
        if line.starts_with(PREFIX) {
            out.push_str(QUOTE);
        }
        out.push_str(line);
    }
    Some(out)
}

fn text_of(b: &Value) -> Option<&str> {
    (b.get("type").and_then(Value::as_str) == Some("text"))
        .then(|| b.get("text").and_then(Value::as_str))
        .flatten()
}

/// Whether `blocks` end with `line` as their one [`PREFIX`] line: the last text block's last line,
/// after a blank line or as the whole block, and no other line anywhere ([`stamp_blocks`] ran).
fn stamped_with(blocks: &[Value], line: &str) -> bool {
    let Some(last) = blocks.iter().rposition(|b| text_of(b).is_some()) else {
        return false;
    };
    let others = blocks.iter().take(last).filter_map(text_of).any(has_line);
    let Some(text) = blocks.get(last).and_then(text_of) else { return false };
    let body = if text == line {
        Some("")
    } else {
        text.strip_suffix(line).and_then(|t| t.strip_suffix("\n\n"))
    };
    !others && body.is_some_and(|b| !has_line(b))
}

/// Puts `line` on a `session/prompt`'s `prompt` blocks, the only [`PREFIX`] line in them: every
/// line a block already has that starts with it is quoted first ([`QUOTE`]). It goes on the last
/// text block after a blank line, or as a text block of its own when there is no text, and in
/// `_meta.acpmux` ([`META_KEY`]). A prompt whose first text is a slash command carries it in
/// `_meta` alone: a harness reads the command's words as its arguments, and an adapter that sends
/// only the last text block would send the line in place of the command. Stamping an already
/// stamped prompt changes nothing. Returns whether it changed the prompt.
pub fn stamp_blocks(prompt: &mut Value, line: &str) -> bool {
    let Some(blocks) = prompt.get_mut("prompt").and_then(Value::as_array_mut) else {
        return false;
    };
    let command = blocks.iter().find_map(text_of).is_some_and(is_command);
    let mut changed = false;
    if command || !stamped_with(blocks, line) {
        for block in blocks.iter_mut() {
            if let Some(quoted) = text_of(block).and_then(quote_lines) {
                block["text"] = json!(quoted);
                changed = true;
            }
        }
        if !command {
            let last = blocks.iter().rposition(|b| text_of(b).is_some());
            match last.and_then(|i| blocks.get_mut(i)) {
                Some(block) => {
                    let text = block.get("text").and_then(Value::as_str).unwrap_or_default();
                    let text = format!("{}\n\n{line}", text.trim_end_matches(['\n', '\r']));
                    block["text"] = json!(text);
                }
                None => blocks.push(json!({"type": "text", "text": line})),
            }
            changed = true;
        }
    }
    if prompt.pointer("/_meta/acpmux").and_then(|m| m.get(META_KEY)).and_then(Value::as_str)
        != Some(line)
        && let Some(fields) = prompt.as_object_mut()
    {
        let meta = fields.entry("_meta").or_insert_with(|| json!({}));
        if !meta.is_object() {
            *meta = json!({});
        }
        let mux = meta.as_object_mut().map(|m| m.entry("acpmux").or_insert_with(|| json!({})));
        if let Some(mux) = mux {
            if !mux.is_object() {
                *mux = json!({});
            }
            if let Some(mux) = mux.as_object_mut() {
                mux.insert(META_KEY.into(), json!(line));
                changed = true;
            }
        }
    }
    changed
}

/// Quotes every [`PREFIX`] line in `prompt`'s text blocks, stamping nothing: a proven session's
/// notice still names no sender it is not.
fn quote_blocks(prompt: &mut Value) {
    let Some(blocks) = prompt.get_mut("prompt").and_then(Value::as_array_mut) else { return };
    for block in blocks.iter_mut() {
        if let Some(quoted) = text_of(block).and_then(quote_lines) {
            block["text"] = json!(quoted);
        }
    }
}

/// Drops a [`META_KEY`] a client sent: only the daemon sets it. `carried` is a connection whose
/// `_meta.acpmux` is the daemon's own (the outbox, a peer daemon: `sender_harness::check_trust`).
pub(crate) fn drop_claimed(prompt: &mut Value, carried: bool) {
    if carried {
        return;
    }
    if let Some(mux) = prompt.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut) {
        mux.remove(META_KEY);
    }
}

/// The [`Sender`] the daemon knows for session `id`: None when no session here has that id.
pub fn of_session(hub: &crate::hub::Hub, id: &str) -> Option<Sender> {
    let session = hub.resolve(id).ok().filter(|s| s.id == id)?;
    let (name, harness, model, handle) = session.read_meta(|m| {
        let harness = m
            .family
            .clone()
            .filter(|f| !f.trim().is_empty())
            .or_else(|| (!m.harness.trim().is_empty()).then(|| m.harness.clone()));
        let handle = m.handle.clone().filter(|h| crate::session_handle::valid(h));
        (m.name.clone(), harness, meta_model(m), handle)
    });
    let session = if name.trim().is_empty() { id.to_owned() } else { name };
    Some(Sender { host: this_host(), session, harness, model, handle })
}

/// Stamps a send that `caller` (the session the connection proved) makes with `prompt` (a
/// `session/prompt`'s params), unless it is a notice or the caller's note to itself.
/// Any [`PREFIX`] line the sender wrote is quoted either way, so only the daemon's line names who
/// sent it.
pub(crate) fn stamp_send(hub: &crate::hub::Hub, prompt: &mut Value, caller: &str) {
    let target = crate::server::session_key(prompt).ok().and_then(|key| hub.resolve(key).ok());
    if target.is_some_and(|t| t.id == caller) {
        return;
    }
    let sender = of_session(hub, caller);
    match sender {
        Some(sender) if prompt.pointer("/_meta/acpmux/notice").is_none_or(|n| n.is_null()) => {
            stamp_blocks(prompt, &line(&sender));
        }
        _ => quote_blocks(prompt),
    }
}

#[cfg(test)]
#[path = "sent_by_tests.rs"]
mod tests;
