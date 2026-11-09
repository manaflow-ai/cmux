//! `agent-session-side` (`agent-session-side-v1`): New side chat and `/side [prompt]` of an
//! attached chat on this machine, the owner's only. acpmux forks the tab's own session (`live`:
//! as it is now, its running turn going on; else through the turn `through_seq` ends), tags the
//! fork the chat's side chat (`_acpmux/side`, which keeps it off the lists), and with `prompt`
//! sends it there. The side chat runs here, in the chat's folder, as a local side chat runs on
//! the Mac; the app opens it beside the chat. A fork acpmux made but could not tag is taken back,
//! so no untagged copy shows in the lists.
use super::*;

/// `agent-session-side`: the boundary of the fork and the side chat's first prompt.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Params {
    pub(super) surface: SurfaceId,
    #[serde(default)]
    through_seq: Option<u64>,
    #[serde(default)]
    live: bool,
    /// The side chat's first prompt (`/side <prompt>`), with its id as `agent-session-prompt`'s.
    #[serde(default)]
    prompt: Option<String>,
    #[serde(default)]
    prompt_id: Option<String>,
}

/// The `acp.session.fork` boundary of `session`: `live` or a positive `through_seq`, never both.
fn boundary(session: &str, live: bool, through_seq: Option<u64>) -> Option<Value> {
    match (live, through_seq) {
        (true, None) => Some(json!({"sessionId": session, "live": true})),
        (false, Some(seq)) if seq > 0 => Some(json!({"sessionId": session, "throughSeq": seq})),
        _ => None,
    }
}

/// The side chat's first prompt as one text block and its id, `None` without one; a prompt with
/// no id, an id without a prompt, a blank or oversized text or a malformed id is a bad request.
fn first_prompt(
    text: Option<String>,
    id: Option<String>,
) -> Result<Option<(String, String)>, Refusal> {
    match (text, id) {
        (None, None) => Ok(None),
        (Some(text), Some(id))
            if !text.trim().is_empty()
                && text.len() <= MAX_PROMPT_BYTES
                && (1..=128).contains(&id.len())
                && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_') =>
        {
            Ok(Some((text, id)))
        }
        _ => Err(Refusal::BadRequest),
    }
}

pub(super) fn call(attachment: &Attachment, params: Params) -> Result<Value, Refusal> {
    let Params { through_seq, live, prompt, prompt_id, .. } = params;
    let session = attachment.session.as_str();
    let fork = boundary(session, live, through_seq).ok_or(Refusal::BadRequest)?;
    let prompt = first_prompt(prompt, prompt_id)?;
    let link = &attachment.link;
    let forked =
        link.call("acp.session.fork", attachment.stamp(fork), CALL_TIMEOUT).map_err(Refusal::of)?;
    // The fork's id is this machine's acpmux answer, never the request's.
    let Some(side) = forked
        .get("sessionId")
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty())
        .map(str::to_owned)
    else {
        return Err(Refusal::Refused);
    };
    let tag = json!({"sessionId": side, "chat": session});
    if let Err(error) = link.call("_acpmux/side", attachment.stamp(tag), CALL_TIMEOUT) {
        let purge = json!({"sessionId": side, "purge": true, "cancelFork": true});
        let _ = link.send_ignoring_reply("_acpmux/kill", attachment.stamp(purge));
        return Err(Refusal::of(error));
    }
    // Followed and remembered like a listed child, so `new-conversation-tab` admits its tab
    // beside the chat and its changes stream on this attachment.
    attachment.follow_children(std::slice::from_ref(&side));
    let Some((text, id)) = prompt else {
        return Ok(json!({"sessionId": side, "prompted": false}));
    };
    // Sent and confirmed as `agent-session-prompt`'s (a phone's keeps its asking policy). The side
    // chat is open either way; a prompt acpmux did not take answers `prompted: false` and why, so
    // the app opens the side chat and keeps the text for the user to send again.
    let blocks = vec![json!({"type": "text", "text": text})];
    Ok(match submit_prompt(attachment, &side, blocks, id) {
        Ok(_) => json!({"sessionId": side, "prompted": true}),
        Err(refusal) => json!({"sessionId": side, "prompted": false, "notSent": refusal.code()}),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_fork_is_live_or_through_one_positive_turn() {
        assert_eq!(boundary("s", true, None), Some(json!({"sessionId": "s", "live": true})));
        assert_eq!(boundary("s", false, Some(4)), Some(json!({"sessionId": "s", "throughSeq": 4})));
        assert_eq!(boundary("s", false, Some(0)), None);
        assert_eq!(boundary("s", false, None), None);
        assert_eq!(boundary("s", true, Some(4)), None);
    }

    #[test]
    fn a_first_prompt_needs_text_and_an_id() {
        assert!(matches!(first_prompt(None, None), Ok(None)));
        assert!(matches!(
            first_prompt(Some("look".into()), Some("p-1".into())),
            Ok(Some((text, id))) if text == "look" && id == "p-1"
        ));
        for (text, id) in [
            (Some("look"), None),
            (None, Some("p-1")),
            (Some("  "), Some("p-1")),
            (Some("look"), Some("")),
            (Some("look"), Some("p 1")),
        ] {
            assert!(
                matches!(
                    first_prompt(text.map(Into::into), id.map(Into::into)),
                    Err(Refusal::BadRequest)
                ),
                "{text:?} {id:?}"
            );
        }
        let long = "x".repeat(MAX_PROMPT_BYTES + 1);
        assert!(matches!(first_prompt(Some(long), Some("p".into())), Err(Refusal::BadRequest)));
    }
}
