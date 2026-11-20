//! App Store read projection of the existing acpmux forum. The supervisor checks
//! `forum:read` before routing here. No writes, peer forwarding, caller token or
//! fabricated person proof: only this daemon's trusted local owner socket.

use crate::apps::envelope::error;
use serde_json::{Value, json};

fn validate(params: &Value) -> Result<&str, Value> {
    let fields = params
        .as_object()
        .ok_or_else(|| error("validation.invalid", "expected forum parameters"))?;
    for (key, value) in fields {
        if !matches!(key.as_str(), "sessionId" | "channel" | "thread") {
            return Err(error("validation.invalid", "unsupported forum parameter"));
        }
        if !value.as_str().is_some_and(|s| {
            !s.trim().is_empty() && s.len() <= 512 && !s.chars().any(char::is_control)
        }) {
            return Err(error(
                "validation.invalid",
                "forum parameters must be bounded nonempty strings",
            ));
        }
    }
    if fields.contains_key("thread") && !fields.contains_key("channel") {
        return Err(error("validation.invalid", "a thread requires its channel"));
    }
    fields
        .get("sessionId")
        .and_then(Value::as_str)
        .ok_or_else(|| error("validation.invalid", "sessionId is required"))
}

impl crate::mux::Mux {
    pub(crate) fn app_forum_threads(&self, params: Value) -> Result<Value, Value> {
        let session = validate(&params)?;
        // A peer can have the same session id. Never borrow this daemon's owner
        // access to satisfy a remote-chat read or a caller-selected address.
        if !self.chat_rows().iter().any(|row| {
            row.get("id").and_then(Value::as_str) == Some(session)
                && row.get("machine").is_none_or(Value::is_null)
        }) {
            return Err(error("forum.unavailable", "select a local chat listed on this machine"));
        }
        #[cfg(unix)]
        {
            use super::agent_session_attach::agent_session_link::AcpmuxLink;
            let socket = self.control_clients.agent_sessions.socket().ok_or_else(|| {
                error("forum.unavailable", "the local forum service is unavailable")
            })?;
            let link = AcpmuxLink::connect(&socket, |_| {}).map_err(|_| {
                error("forum.unavailable", "the local forum service is unavailable")
            })?;
            let result =
                link.call("_acpmux/forum/threads", params, std::time::Duration::from_secs(2));
            link.close();
            result.map(|value| json!({"value": value})).map_err(|_| {
                error(
                    "forum.unavailable",
                    "the forum could not be read; check access and the service version",
                )
            })
        }
        #[cfg(not(unix))]
        Err(error("operation.unsupported", "the local forum is unavailable on this platform"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn forum_threads_requires_explicit_bounded_recipient_and_known_fields() {
        for invalid in [
            json!(null),
            json!({}),
            json!({"sessionId":""}),
            json!({"sessionId":"s", "peer":"other"}),
            json!({"sessionId":"s", "callerToken":"t"}),
            json!({"sessionId":"s", "thread":"t"}),
            json!({"sessionId":"s", "channel":"x\ny"}),
            json!({"sessionId":"s", "channel":"x".repeat(513)}),
        ] {
            assert!(validate(&invalid).is_err(), "{invalid}");
        }
        assert_eq!(
            validate(
                &json!({"sessionId":"s", "channel":"ops/runner-capacity", "thread":"ubuntu-24"})
            )
            .unwrap(),
            "s"
        );
    }
}
