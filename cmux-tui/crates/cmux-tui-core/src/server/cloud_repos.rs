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
    line: &str,
    writer: &MessageWriter,
) -> Option<bool> {
    let cmd = crate::cloud_repos::frame_command(line)?;
    let request: Value = serde_json::from_str(line).ok()?;
    let id = request.get("id").cloned().unwrap_or(Value::Null);
    let transport = mux.control_clients.transport_of(client);
    let permitted = matches!(transport, Some(ClientTransport::Unix | ClientTransport::Remote))
        && mux.frame_principal(client).is_some()
        && (!matches!(cmd.as_str(), "cloud.repo.local" | "cloud.repo.remember")
            || matches!(transport, Some(ClientTransport::Unix)));
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
