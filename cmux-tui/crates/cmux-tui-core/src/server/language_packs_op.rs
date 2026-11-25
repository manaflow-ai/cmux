//! `language_packs.ensure` on a connection (`crate::language_packs`). A download takes up to two
//! minutes, so the reader thread only checks and parses the request: the run is on a worker
//! thread that answers through the connection's writer, as `cloud_api.rs` does (perf-lead.md
//! rule D1). Origin user is already required (`request_origin::USER_ONLY_OPERATIONS`); a
//! connection that is not a local socket (a link, a WebSocket) is refused here, so no remote
//! device makes the Mac download or write its files.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use serde_json::json;

use super::{MessageWriter, Mux, ResourceError, send_resource_response};
use crate::resource_router::ParsedResourceRequest;

/// Runs at once in the whole daemon. The app asks once per launch and per language change;
/// requests for one pack share one download (`language_packs::shared`).
const MAX_WORKERS: usize = 8;
static WORKERS: AtomicUsize = AtomicUsize::new(0);

pub(super) fn handle(
    mux: &Arc<Mux>,
    client: u64,
    request: ParsedResourceRequest,
    writer: &MessageWriter,
) -> bool {
    let id = request.envelope.id.clone();
    let operation = request.envelope.operation;
    let parsed = super::resource_trust::trusted_local_resource_client(mux, client, operation)
        .and_then(|()| crate::language_packs::parse_request(&request.fields));
    let parsed = match parsed {
        Ok(parsed) => parsed,
        Err(error) => return send_resource_response(writer, id, operation, Err(error)),
    };
    let limit = json!({"limit": MAX_WORKERS});
    let busy = || ResourceError::operation_failed(operation.wire_name(), "busy", limit.clone());
    if WORKERS
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| {
            (n < MAX_WORKERS).then(|| n.saturating_add(1))
        })
        .is_err()
    {
        return send_resource_response(writer, id, operation, Err(busy()));
    }
    let worker_writer = writer.clone();
    let worker_id = id.clone();
    let spawned = std::thread::Builder::new().name("language-packs".into()).spawn(move || {
        struct Done;
        impl Drop for Done {
            fn drop(&mut self) {
                WORKERS.fetch_sub(1, Ordering::AcqRel);
            }
        }
        let _done = Done;
        let outcome = crate::language_packs::ensure(&parsed);
        send_resource_response(&worker_writer, worker_id, operation, Ok(outcome.to_json()));
    });
    match spawned {
        Ok(_) => true,
        Err(_) => {
            WORKERS.fetch_sub(1, Ordering::AcqRel);
            send_resource_response(writer, id, operation, Err(busy()))
        }
    }
}
