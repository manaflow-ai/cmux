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
//! - Idempotent: a text with a line that starts `Sent-by: ` already (a lane VM's broker relay
//!   stamps first) gets no second one.
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

/// Appends `line` to a `session/prompt`'s `prompt` blocks: to its last text block after a blank
/// line, or as a text block of its own when it has no text. A prompt whose first text is a slash
/// command is left as it is: a harness reads the command's words as its arguments, and an adapter
/// that sends only the last text block would send the line in place of the command. Nothing when a
/// text block has a [`PREFIX`] line already. Returns whether it stamped.
pub fn stamp_blocks(prompt: &mut Value, line: &str) -> bool {
    fn text_of(b: &Value) -> Option<&str> {
        (b.get("type").and_then(Value::as_str) == Some("text"))
            .then(|| b.get("text").and_then(Value::as_str))
            .flatten()
    }
    let Some(blocks) = prompt.get_mut("prompt").and_then(Value::as_array_mut) else {
        return false;
    };
    if blocks.iter().filter_map(text_of).any(has_line) {
        return false;
    }
    if blocks.iter().find_map(text_of).is_some_and(is_command) {
        return false;
    }
    let last = blocks.iter().rposition(|b| text_of(b).is_some());
    match last.and_then(|i| blocks.get_mut(i)) {
        Some(block) => {
            let text = block.get("text").and_then(Value::as_str).unwrap_or_default();
            let text = format!("{}\n\n{line}", text.trim_end_matches(['\n', '\r']));
            block["text"] = json!(text);
        }
        None => blocks.push(json!({"type": "text", "text": line})),
    }
    true
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
pub(crate) fn stamp_send(hub: &crate::hub::Hub, prompt: &mut Value, caller: &str) {
    if prompt.pointer("/_meta/acpmux/notice").is_some_and(|n| !n.is_null()) {
        return;
    }
    let target = crate::server::session_key(prompt).ok().and_then(|key| hub.resolve(key).ok());
    if target.is_some_and(|t| t.id == caller) {
        return;
    }
    if let Some(sender) = of_session(hub, caller) {
        stamp_blocks(prompt, &line(&sender));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lane_x(model: Option<&str>) -> Sender {
        Sender {
            host: Some("devbox".into()),
            session: "lane-x".into(),
            harness: Some("claude".into()),
            model: model.map(str::to_owned),
            handle: None,
        }
    }

    #[test]
    fn names_host_session_harness_and_model() {
        assert_eq!(
            line(&lane_x(Some("claude-opus-5-5"))),
            "Sent-by: devbox/lane-x harness=claude model=claude-opus-5-5"
        );
    }

    #[test]
    fn a_given_handle_rides_last() {
        let sender = Sender { handle: Some("Mango".into()), ..lane_x(Some("claude-opus-5")) };
        assert!(line(&sender).ends_with(" handle=Mango"), "{}", line(&sender));
    }

    #[test]
    fn an_unknown_field_is_left_out() {
        assert_eq!(line(&lane_x(None)), "Sent-by: devbox/lane-x harness=claude");
        let bare = Sender { session: "lane-x".into(), ..Sender::default() };
        assert_eq!(line(&bare), "Sent-by: lane-x");
    }

    #[test]
    fn appends_after_a_blank_line() {
        let mut p =
            json!({"sessionId": "b", "prompt": [{"type": "text", "text": "PR #1 is green.\n"}]});
        assert!(stamp_blocks(&mut p, &line(&lane_x(Some("claude-opus-5-5")))));
        assert_eq!(
            p["prompt"][0]["text"],
            "PR #1 is green.\n\nSent-by: devbox/lane-x harness=claude \
             model=claude-opus-5-5"
        );
    }

    #[test]
    fn a_text_with_a_line_already_gets_no_second() {
        let first = "hi\n\nSent-by: lane-vm/lane-a harness=codex model=gpt-6.2-astra";
        let mut p = json!({"prompt": [{"type": "text", "text": first}]});
        assert!(!stamp_blocks(&mut p, &line(&lane_x(Some("claude-opus-5-5")))));
        assert_eq!(p["prompt"][0]["text"], first);
        // Stamping twice is stamping once.
        let mut p = json!({"prompt": [{"type": "text", "text": "hi"}]});
        stamp_blocks(&mut p, "Sent-by: a/b");
        stamp_blocks(&mut p, "Sent-by: a/b");
        assert_eq!(p["prompt"][0]["text"], "hi\n\nSent-by: a/b");
        // Prose that only mentions it is no line.
        assert!(!has_line("see the Sent-by: trailer"));
    }

    #[test]
    fn a_slash_command_is_left_as_it_is_and_no_text_gets_a_block_of_its_own() {
        for command in ["/compact", "/model opus", "  /review 12"] {
            let mut p = json!({"prompt": [{"type": "text", "text": command}]});
            assert!(!stamp_blocks(&mut p, "Sent-by: a/b"), "{command}");
            assert_eq!(p["prompt"], json!([{"type": "text", "text": command}]));
        }
        // A path is text, not a command: the line joins its block, so an adapter that sends the
        // last text block sends both.
        let mut p = json!({"prompt": [{"type": "text", "text": "/tmp/report.txt"}]});
        assert!(stamp_blocks(&mut p, "Sent-by: a/b"));
        assert_eq!(
            p["prompt"],
            json!([{"type": "text", "text": "/tmp/report.txt\n\nSent-by: a/b"}])
        );
        let mut p = json!({"prompt": [{"type": "image", "data": "", "mimeType": "image/png"}]});
        stamp_blocks(&mut p, "Sent-by: a/b");
        assert_eq!(p["prompt"][1], json!({"type": "text", "text": "Sent-by: a/b"}));
    }

    #[test]
    fn an_alias_is_no_model_id() {
        assert_eq!(model_id("claude-opus-5-5").as_deref(), Some("claude-opus-5-5"));
        assert_eq!(model_id("claude-opus-5-5[1m]").as_deref(), Some("claude-opus-5-5"));
        assert_eq!(model_id("gpt-6.2-astra").as_deref(), Some("gpt-6.2-astra"));
        for alias in ["opus", "sonnet[1m]", "default", "gpt", "", "  "] {
            assert_eq!(model_id(alias), None, "{alias}");
        }
    }

    #[test]
    fn the_model_is_the_harness_report_before_the_request() {
        let raw = json!({"schema": crate::store::META_SCHEMA, "id": "s", "name": "lane-x",
            "harness": "claude", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 2});
        let mut meta: crate::store::SessionMeta =
            serde_json::from_value(raw).unwrap_or_else(|e| panic!("meta: {e}"));
        assert_eq!(meta_model(&meta), None);
        meta.model_request = Some("opus".into());
        assert_eq!(meta_model(&meta), None);
        meta.models = Some(json!({"currentModelId": "claude-opus-5-5"}));
        assert_eq!(meta_model(&meta).as_deref(), Some("claude-opus-5-5"));
        // Switched to an alias after starting: the old id is not named.
        meta.model_request = Some("claude-opus-5-5".into());
        meta.models = None;
        meta.config_options = Some(
            serde_json::from_value(json!([{"id": "model", "currentValue": "sonnet"}]))
                .unwrap_or_else(|e| panic!("config options: {e}")),
        );
        assert_eq!(meta_model(&meta), None);
    }
}
