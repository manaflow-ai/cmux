//! One client request's task (`serve_connection_from`). Its handler changes the hub's
//! shared state inline (a session's map, its turn, a queue), so it runs under the hub's
//! supervisor as `Fatal`, as the hub's own tasks that start the same work do: a panic
//! in it, which may leave a hub lock poisoned or its state half-changed, ends the
//! daemon, which its supervisor starts again; never a daemon that answers every later
//! request with an internal error (`crate::supervised`;
//! `content/browser/browser_main_loop.cc`). Decoding the line is the connection's,
//! before the request starts, and a malformed line gets its parse error there.
//! Shutdown: Skip, as the hub's other tasks.

use std::sync::Arc;
use std::sync::atomic::Ordering;

use cmux_panic_log::crash_keys::{self, Key};
use futures::future::BoxFuture;
use serde_json::Value;

use super::{Conn, agent_mcp, chats, list_reply};
use crate::hub::Hub;
use crate::rpc::{Id, Message, RpcError, method as rpc_method};
use crate::supervised::{Fatal, ShutdownBehavior, Supervisor};
use crate::trace_layer::RequestSlice;

/// The supervised worker of one client request.
pub(crate) const REQUEST_WORKER: &str = "server.request";

/// What runs when a request ends, given its result and whether a shared session list
/// was its reply, sent already: then whether it went whole into an open queue
/// (`list_reply.rs`).
type AfterReply = Box<dyn FnOnce(&Result<Value, RpcError>, Option<bool>) + Send>;

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
    let watch = method == rpc_method::MUX_WATCH;
    let (owner_hub, owner_conn) = (hub.clone(), conn.clone());
    let after: AfterReply = Box::new(move |result, sent| {
        // Its answer went whole into an open queue: one sent as its too-large error, or
        // to a reader that is gone, opened nothing.
        let watched = watch && result.is_ok() && sent == Some(true);
        // A Mac that lends GitHub counts from here: its watch answer is queued, so
        // no action reaches it before the answer that opens its side.
        if watched
            && owner_conn.watch_all.load(Ordering::SeqCst)
            && owner_conn.client_requests.lends_github.load(Ordering::SeqCst)
        {
            owner_hub.add_github_owner(&owner_conn);
        }
    });
    let route = {
        let (hub, conn, method) = (hub.clone(), conn.clone(), method.clone());
        Box::pin(async move {
            let params = params.unwrap_or(Value::Null);
            match conn.agent_tools() {
                // Boxed: the tool calls hold a whole `chats::route` of their own.
                Some(tools) => {
                    Box::pin(agent_mcp::handle(&hub, &conn, tools, &method, params)).await
                }
                None => chats::route(&hub, &conn, &method, params).await,
            }
        })
    };
    start_then(hub.supervisor(), conn, id, &method, slot, route, Some(after));
}

/// Runs `route`, request `id`'s handler, under `supervisor` and sends its answer on
/// `conn`. A start the supervisor refuses (its shutdown began) answers at once.
/// `route` comes boxed: the handlers' futures are large, and each wrapper below
/// then moves only a pointer.
#[cfg(test)]
fn start(
    supervisor: &Supervisor,
    conn: &Arc<Conn>,
    id: Id,
    method: &str,
    slot: Option<tokio::sync::OwnedSemaphorePermit>,
    route: BoxFuture<'static, Result<Value, RpcError>>,
) {
    start_then(supervisor, conn, id, method, slot, route, None);
}

/// [`start`], then `after` with the request's result once its answer is queued.
fn start_then(
    supervisor: &Supervisor,
    conn: &Arc<Conn>,
    id: Id,
    method: &str,
    slot: Option<tokio::sync::OwnedSemaphorePermit>,
    route: BoxFuture<'static, Result<Value, RpcError>>,
    after: Option<AfterReply>,
) {
    // From the dispatch to the reply queued, on every path out of the task.
    let slice = RequestSlice::begin(&conn.id, &id, method);
    // A panic in the request names its method (cmux-panic-log crash keys): set on
    // whichever worker polls it, for each poll.
    let method_key = crash_keys::stable_key(method);
    let (refused_conn, refused_id) = (conn.clone(), id.clone());
    let conn = conn.clone();
    let work: BoxFuture<'static, ()> =
        Box::pin(slice.wrap(crash_keys::keyed(Key::ActionId, method_key, async move {
            let _slot = slot;
            let (result, sent) = list_reply::scope(id.clone(), route).await;
            // Acts only on a shared list that `list_reply` queued already, so it runs
            // after that answer is queued.
            if let Some(after) = after {
                after(&result, sent);
            }
            // A shared session list, sent already as the bytes it was serialized to.
            if !(sent.is_some() && result.is_ok()) {
                conn.send(&match result {
                    Ok(v) => Message::ok(id, v),
                    Err(mut e) => {
                        // What kind of failure, and what to do (`recovery.rs`).
                        crate::recovery::annotate(&mut e, None);
                        Message::err(id, e)
                    }
                });
            }
        })));
    let started =
        supervisor.supervise_task(REQUEST_WORKER, Fatal, ShutdownBehavior::Skip, move |_stop| work);
    if let Err(error) = started {
        let refusal = RpcError::internal(format!("the request was not started: {error}"));
        refused_conn.send(&Message::err(refused_id, refusal));
    }
}

#[cfg(test)]
#[path = "request_task_tests.rs"]
mod tests;
