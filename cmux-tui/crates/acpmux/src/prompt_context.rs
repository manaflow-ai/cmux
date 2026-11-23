//! A prompt's hidden context (`_meta.acpmux.context` on `session/prompt`, cx-ihyx2): text a
//! client adds for the agent beside the person's words, such as the app's workspace context
//! on the first prompt of a chat opened with Cmd-I. acpmux appends it to the prompt as one
//! text block marked `_meta.acpmux.context`. The agent reads it; the recorded `user_message`
//! text leaves it out ([`is_context`] in `hub::prompt_text`), so the transcript, the chat list
//! preview and the title show only what the person wrote. The harness's own log keeps the
//! whole prompt, so a resumed agent still has it.
//!
//! Only a local client (the unix socket, the app's agent pane) or a peer daemon relaying one
//! may send it. A remote web client is refused (`context.origin_refused`), so a viewer on
//! another device cannot hide text from the person. A block that a client marks by itself
//! loses the mark: the one way in is this field. An edit of a waiting prompt
//! (`_acpmux/queue_edit`) keeps no context: its new blocks lose any mark.
//!
//! One context block comes from acpmux itself, for every origin, a remote web client and a
//! relaying peer included: the tools note (`tool_mentions.rs`) for an `@computer-use` or
//! `@browser-use` the person wrote. Its text is fixed by acpmux and follows from the person's
//! visible words, so it hides nothing a client chose. `session/prompt` adds it after this
//! field's context, unless that context already holds it; a queue edit adds it again from the
//! edited words.

use serde_json::{Value, json};

use crate::rpc::RpcError;

/// Longest context, in bytes.
pub const MAX_BYTES: usize = 16 * 1024;

/// Whether `block` is a context block acpmux added.
pub fn is_context(block: &Value) -> bool {
    block.pointer("/_meta/acpmux/context").and_then(Value::as_bool) == Some(true)
}

/// Whether a text item of a harness's own log is a client context: clients wrap it in one
/// `<cmux-…-context>` element (the app's `<cmux-workspace-context>`). An adopted or replayed
/// chat reads the harness log, which keeps no `_meta`, so it drops such items by this shape.
pub fn is_context_text(text: &str) -> bool {
    let text = text.trim_start();
    text.strip_prefix("<cmux-")
        .and_then(|rest| rest.split_once('>'))
        .is_some_and(|(name, _)| name.ends_with("-context") && !name.contains(char::is_whitespace))
}

/// `text` without the `<cmux-…-context>` elements it ends with ([`is_context_text`]'s shape, each
/// with its closing tag), nor the blank lines before them: a prompt's hidden notes, which a harness
/// log keeps in the one text a bridged chat's app was sent (`hub/watch.rs`). Text with nothing
/// before the element is kept as it is, and so is one in the middle of the person's words.
pub fn without_trailing_context(text: &str) -> &str {
    let mut rest = text;
    loop {
        let trimmed = rest.trim_end();
        let Some(close_at) = trimmed.rfind("</cmux-") else { return rest };
        let Some(name) =
            trimmed[close_at..].strip_prefix("</cmux-").and_then(|n| n.strip_suffix('>'))
        else {
            return rest;
        };
        if !name.ends_with("-context") || name.contains(|c: char| c.is_whitespace() || c == '<') {
            return rest;
        }
        let Some(open_at) = trimmed[..close_at].rfind(&format!("<cmux-{name}>")) else {
            return rest;
        };
        let before = trimmed[..open_at].trim_end();
        if before.is_empty() {
            return rest;
        }
        rest = before;
    }
}

/// Removes every client-made context mark from `blocks`: only [`apply`] marks a block.
pub fn strip_marks(blocks: &mut [Value]) {
    for block in blocks.iter_mut() {
        if let Some(mux) = block.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut) {
            mux.remove("context");
        }
    }
}

fn refusal(reason: &str, message: &str) -> RpcError {
    RpcError::invalid_params(message.to_owned()).with_data(json!({"reason": reason}))
}

/// Removes every client-made context mark from `blocks`, then appends the context of `meta`
/// (`_meta.acpmux`) as one marked text block. `web`: the prompt is a remote web client's,
/// directly or relayed by a peer (`remote_guard::control_of`).
pub fn apply(meta: Option<&Value>, web: bool, blocks: &mut Vec<Value>) -> Result<(), RpcError> {
    strip_marks(blocks);
    let text = match meta.and_then(|m| m.get("context")) {
        None | Some(Value::Null) => return Ok(()),
        Some(Value::String(text)) => text,
        Some(_) => return Err(refusal("context.value_refused", "context must be a string")),
    };
    if web {
        return Err(refusal(
            "context.origin_refused",
            "a prompt context is accepted only from a local client",
        ));
    }
    if text.trim().is_empty() || text.len() > MAX_BYTES {
        return Err(refusal(
            "context.value_refused",
            &format!("context must be 1 to {MAX_BYTES} bytes of text"),
        ));
    }
    blocks.push(json!({"type": "text", "text": text, "_meta": {"acpmux": {"context": true}}}));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::without_trailing_context as strip;

    #[test]
    fn trailing_context_elements_and_their_blank_lines_go() {
        let note = "<cmux-tools-context>\nnote\n</cmux-tools-context>";
        assert_eq!(strip(&format!("ask\n\n{note}")), "ask");
        assert_eq!(
            strip(&format!(
                "ask\n\n<cmux-workspace-context>W</cmux-workspace-context>\n\n{note}\n"
            )),
            "ask"
        );
        // Nothing before it, one in the middle, an unclosed or other element: kept.
        assert_eq!(strip(note), note);
        let middle = format!("a\n{note}\nb");
        assert_eq!(strip(&middle), middle);
        assert_eq!(strip("a <cmux-tools-context> b"), "a <cmux-tools-context> b");
        assert_eq!(strip("a\n<cmux-x>y</cmux-x>"), "a\n<cmux-x>y</cmux-x>");
        assert_eq!(strip("plain words"), "plain words");
    }
}
