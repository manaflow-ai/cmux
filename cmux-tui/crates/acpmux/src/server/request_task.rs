//! One client request's task (`serve_connection_from`): a panic in its handler ends that
//! request with an internal error, never the connection or the daemon (Chromium's
//! `mojo::ReportBadMessage` scope: the failing message, not the process). Handlers that
//! change the hub's shared state start their work under the hub's supervisor
//! (`Hub::supervise`), where a panic is fatal.

use std::sync::Arc;

use cmux_panic_log::crash_keys::{self, Key};
use serde_json::Value;

use super::{Conn, chats};
use crate::hub::Hub;
use crate::rpc::{Id, Message, RpcError};
use crate::trace_layer::RequestSlice;

/// Answers request `id` (`method` with `params`) on `conn` from its own task. `slot`
/// is the connection's work permit, held until the request ends.
pub(super) fn spawn(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    id: Id,
    method: String,
    params: Option<Value>,
    slot: Option<tokio::sync::OwnedSemaphorePermit>,
) {
    // From the dispatch to the reply queued, on every path out of the task.
    let slice = RequestSlice::begin(&conn.id, &id, &method);
    // A panic in the request names its method (cmux-panic-log crash keys): set on
    // whichever worker polls it, for each poll.
    let method_key = crash_keys::stable_key(&method);
    let (hub, conn, failed_conn, failed_id) = (hub.clone(), conn.clone(), conn.clone(), id.clone());
    let work = slice.wrap(crash_keys::keyed(Key::ActionId, method_key, async move {
        let _slot = slot;
        let result = chats::route(&hub, &conn, &method, params.unwrap_or(Value::Null)).await;
        conn.send(&match result {
            Ok(v) => Message::ok(id, v),
            Err(e) => Message::err(id, e),
        });
    }));
    crate::supervised::spawn_request(work, async move {
        failed_conn.send(&Message::err(failed_id, RpcError::internal("the request failed")));
    });
}
