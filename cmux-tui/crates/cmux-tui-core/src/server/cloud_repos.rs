//! The shared repo actions on local sockets and authenticated Cloud links.
use super::{ClientTransport, MessageWriter, Mux};
use serde_json::{Value, json};
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};
static WORKERS: AtomicUsize = AtomicUsize::new(0);
const MAX_WORKERS: usize = 16;

pub(super) fn try_handle(
    mux: &Arc<Mux>,
    client: u64,
    line: &super::line_value::LineValue<'_>,
    writer: &MessageWriter,
) -> Option<bool> {
    let cmd = crate::cloud_repos::frame_command_of(line.value()?)?;
    let request = line.value()?.clone();
    let id = request.get("id").cloned().unwrap_or(Value::Null);
    let permitted = permitted(mux, client, &cmd, &request);
    if !permitted {
        return Some(writer.send_control(&json!({"id":id,"ok":false,"error_code":"remote_denied","error":"permission denied"})).is_ok());
    }
    if WORKERS
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| (n < MAX_WORKERS).then_some(n + 1))
        .is_err()
    {
        return Some(writer.send_control(&json!({"id":id,"ok":true,"data":{"code":"seed.clone_failed","message":"Repository actions are busy. Retry after the current action finishes."}})).is_ok());
    }
    let mux = mux.clone();
    let writer = writer.clone();
    let fallback = writer.clone();
    let fallback_id = id.clone();
    match std::thread::Builder::new().name("cloud-repo".into()).spawn(move || {
        struct Done;
        impl Drop for Done {
            fn drop(&mut self) {
                WORKERS.fetch_sub(1, Ordering::AcqRel);
            }
        }
        let _done = Done;
        let result = crate::cloud_repos::handle(&mux, &cmd, &request);
        let _ = writer.send_control(&json!({"id":id,"ok":true,"data":result}));
    }) {
        Ok(_) => Some(true),
        Err(_) => {
            WORKERS.fetch_sub(1, Ordering::AcqRel);
            Some(fallback.send_control(&json!({"id":fallback_id,"ok":false,"error_code":"seed.clone_failed","error":"Retry the repository action; the worker could not start."})).is_ok())
        }
    }
}

/// Local user and linked Mac requests retain their existing access. A
/// presented agent identity, however, may address only its own chat, and a
/// linked Mac frame must name the chat its surface currently shows.
fn permitted(mux: &Mux, client: u64, cmd: &str, request: &Value) -> bool {
    let transport = mux.control_clients.transport_of(client);
    let principal = mux.frame_principal(client);
    if !matches!(transport, Some(ClientTransport::Unix | ClientTransport::Remote))
        || principal.is_none()
        || (matches!(cmd, "cloud.repo.local" | "cloud.repo.remember")
            && !matches!(transport, Some(ClientTransport::Unix)))
    {
        return false;
    }
    if matches!(principal, Some(super::remote_relay::Principal::Remote(_)))
        && cmd != "cloud.repo.sync"
        && !session_matches_surface(mux, request)
    {
        return false;
    }
    let credential = match request.get("credential") {
        None => None,
        Some(Value::String(value)) if !value.is_empty() => Some(value.as_str()),
        Some(_) => return false,
    };
    match mux.request_actor(super::origin_gate::connection_actor(mux, client), credential) {
        Ok(crate::Actor::AcpSession { id, .. }) => {
            request.get("session").and_then(Value::as_str) == Some(id.as_str())
        }
        Ok(_) => true,
        Err(_) => false,
    }
}

/// A linked Mac frame names the session currently shown by its surface.
/// The principal and transport checks still apply independently; sync has no chat.
fn session_matches_surface(mux: &Mux, request: &Value) -> bool {
    let session = request.get("session").and_then(Value::as_str).filter(|s| !s.is_empty());
    let stored = request
        .get("surface")
        .and_then(Value::as_u64)
        .and_then(|surface| super::agent_session_attach::tab_session(mux, surface));
    session.is_some() && session == stored.as_deref()
}

#[cfg(test)]
mod tests;
