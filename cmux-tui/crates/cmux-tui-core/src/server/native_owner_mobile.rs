//! A phone-marked Native owner connection has a narrower vocabulary than the
//! Mac owner's carrier. Consume every frame before broad owner dispatch so a
//! refusal can never fall through to create, trust, settings or permissions.

use super::*;

pub(super) const CAPABILITY: &str = agent_session_attach::CLOUD_MOBILE_CHAT_CAPABILITY;

pub(super) fn supported(mux: &Mux) -> bool {
    mux.serves_agent_session_attach()
}

/// `None` means this is not a mobile connection. For a marked connection every
/// result, including an invalid frame, is final. The marker restricts an
/// already authenticated owner; it never supplies an owner role.
pub(in crate::server) fn try_handle(
    mux: &Arc<Mux>,
    client: u64,
    message: &str,
    writer: &MessageWriter,
) -> Option<bool> {
    if !mux.control_clients.supports_capability(client, CAPABILITY) {
        return None;
    }
    let denied = || writer.send_control(&remote_relay::refusal(message, "remote_denied")).is_ok();
    if !supported(mux) || !mux.is_native_agent_owner(client) {
        return Some(denied());
    }
    let Ok(Value::Object(fields)) = serde_json::from_str::<Value>(message) else {
        return Some(denied());
    };
    let command = fields.get("cmd").and_then(Value::as_str).unwrap_or_default();
    let params: &[&str] = match command {
        "identify" => &["machine_metadata", "revisions"],
        "set-client-info" => &["name", "kind", "capabilities", "device_kind", "device_name"],
        "list-workspaces" => &[],
        "agent-session-attach" | "agent-session-events" => {
            &["surface", "after_seq", "before_seq", "limit", "kinds"]
        }
        "agent-session-prompt" => &["surface", "prompt_id", "text"],
        "agent-session-cancel" | "agent-session-detach" => &["surface"],
        _ => return Some(denied()),
    };
    if fields.keys().any(|key| key != "cmd" && key != "id" && !params.contains(&key.as_str())) {
        return Some(denied());
    }
    // Every accepted verb is still parsed and scoped by the original typed
    // handler. In particular a surface resolves through this daemon's store;
    // the phone cannot choose a raw session, socket, command or directory.
    Some(super::try_handle(mux, client, message, writer).unwrap_or_else(denied))
}
