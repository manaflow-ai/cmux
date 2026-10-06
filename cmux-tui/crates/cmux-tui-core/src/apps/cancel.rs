//! Run cancel (plans/cmux-next/app-op-routing.md "Op cancel").
//!
//! Every `apps-run` caller is kept by connection and request id. A caller
//! that cancels (`cancel-request`) or closes its connection is answered
//! `cmux.op.cancelled` once, and a later answer of its op is dropped. The op
//! itself is cancelled when no other caller waits for it (callers with one
//! idempotency key share one op): a server op that was sent gets
//! `{"type":"op.cancel","id"}`, a queued one loses its line, and the op's
//! keyed waiters are released, so a same-key retry runs again. A QuickJS
//! host run cannot be stopped: its callers are answered, and its own answer
//! is stored for the key as usual.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, PoisonError};

use serde_json::{Value, json};

use super::runs::{Caller, RunKey};
use super::supervisor::{ApiError, Inner, Out, Responder, Supervisor};

type Slot = Arc<Mutex<Option<Responder>>>;

/// Callers and the ops they wait for.
#[derive(Default)]
pub(super) struct Calls {
    next: u64,
    /// By connection and request id (`serde_json` text of the id).
    callers: HashMap<(u64, String), Waiter>,
    ops: HashMap<u64, OpCall>,
    /// A pending keyed op by its run key (`app\nop\nkey`).
    keyed: HashMap<String, u64>,
}

struct Waiter {
    serial: u64,
    op: u64,
    slot: Slot,
}

struct OpCall {
    /// Every waiter, cancellable or not; the op is cancelled at zero.
    waiters: usize,
    /// The app and wire id of a server op.
    wire: Option<(String, String)>,
    key: Option<String>,
}

pub(super) fn cancelled() -> ApiError {
    ApiError::new("cmux.op.cancelled", "the caller cancelled the op")
}

/// The callers map key of a request id.
fn request_key(request: &Value) -> String {
    serde_json::to_string(request).unwrap_or_default()
}

impl Supervisor {
    /// Tracks a run before it starts and returns its op and the responder to
    /// pass on. A run whose key is pending joins that op; one whose key is
    /// answered is not tracked (it is answered now).
    pub(super) fn track_run_locked(
        &self,
        inner: &mut Inner,
        run_key: Option<&str>,
        caller: Option<Caller>,
        respond: Responder,
    ) -> (Option<u64>, Responder) {
        let calls = &mut inner.calls;
        let joined = match run_key.map(|key| (key, inner.run_keys.get(key))) {
            Some((_, Some(RunKey::Done(_)))) => return (None, respond),
            Some((key, Some(RunKey::Pending(_)))) => {
                match calls.keyed.get(key).and_then(|op| calls.ops.get_mut(op).map(|c| (*op, c))) {
                    Some((op, call)) => {
                        call.waiters += 1;
                        Some(op)
                    }
                    None => return (None, respond),
                }
            }
            _ => None,
        };
        let op = match joined {
            Some(op) => op,
            None => {
                calls.next += 1;
                let op = calls.next;
                let key = run_key.map(str::to_string);
                if let Some(key) = &key {
                    calls.keyed.insert(key.clone(), op);
                }
                calls.ops.insert(op, OpCall { waiters: 1, wire: None, key });
                op
            }
        };
        let Some(Caller { client, request }) = caller else { return (Some(op), respond) };
        calls.next += 1;
        let serial = calls.next;
        // A request without an id cannot be targeted; it still ends with its
        // connection.
        let id = if request.is_null() { format!("\0{serial}") } else { request_key(&request) };
        let slot: Slot = Arc::new(Mutex::new(Some(respond)));
        calls.callers.insert((client, id.clone()), Waiter { serial, op, slot: slot.clone() });
        let me = self.me.clone();
        let respond: Responder = Box::new(move |result| {
            let Some(respond) = slot.lock().unwrap_or_else(PoisonError::into_inner).take() else {
                return;
            };
            if let Some(me) = me.upgrade() {
                let mut inner = me.inner.lock().unwrap_or_else(PoisonError::into_inner);
                let key = (client, id);
                if inner.calls.callers.get(&key).is_some_and(|w| w.serial == serial) {
                    inner.calls.callers.remove(&key);
                }
            }
            respond(result);
        });
        (Some(op), respond)
    }

    /// Wraps the responder of a new op: its answer ends the op.
    pub(super) fn finish_op(&self, op: u64, respond: Responder) -> Responder {
        let me = self.me.clone();
        Box::new(move |result| {
            if let Some(me) = me.upgrade() {
                let mut inner = me.inner.lock().unwrap_or_else(PoisonError::into_inner);
                if let Some(call) = inner.calls.ops.remove(&op)
                    && let Some(key) = call.key
                {
                    inner.calls.keyed.remove(&key);
                }
            }
            respond(result);
        })
    }

    /// Records the wire id of a server op.
    pub(super) fn op_sent_locked(inner: &mut Inner, op: u64, app: &str, wire: String) {
        if let Some(call) = inner.calls.ops.get_mut(&op) {
            call.wire = Some((app.to_string(), wire));
        }
    }

    /// `client` cancels its request `request` (`cancel-request`). An unknown
    /// or answered request changes nothing.
    pub fn cancel_request(&self, client: u64, request: &Value) {
        let outs = {
            let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
            self.cancel_locked(&mut inner, (client, request_key(request)))
        };
        self.emit(outs);
    }

    /// A closed connection cancels every run it waits for.
    pub(super) fn cancel_client_locked(&self, inner: &mut Inner, client: u64) -> Vec<Out> {
        let keys: Vec<(u64, String)> =
            inner.calls.callers.keys().filter(|(c, _)| *c == client).cloned().collect();
        keys.into_iter().flat_map(|key| self.cancel_locked(inner, key)).collect()
    }

    fn cancel_locked(&self, inner: &mut Inner, key: (u64, String)) -> Vec<Out> {
        let Some(waiter) = inner.calls.callers.remove(&key) else { return vec![] };
        let Some(respond) = waiter.slot.lock().unwrap_or_else(PoisonError::into_inner).take()
        else {
            return vec![];
        };
        let mut outs = vec![Out::Respond(respond, Err(cancelled()))];
        let Some(call) = inner.calls.ops.get_mut(&waiter.op) else { return outs };
        call.waiters -= 1;
        if call.waiters > 0 {
            return outs;
        }
        let Some((app, wire)) = call.wire.clone() else { return outs };
        let Some(server) = inner.servers.get_mut(&app) else { return outs };
        let Some(pending) = server.pending.remove(&wire) else { return outs };
        let queued = server.queued.len();
        server.queued.retain(|(id, _)| *id != wire);
        if server.queued.len() == queued {
            server.process.send(super::servers::line(&json!({ "type": "op.cancel", "id": wire })));
        }
        // Ends the op and releases its key: a same-key retry runs again.
        outs.push(Out::Respond(pending, Err(cancelled())));
        outs.extend(self.server_idle_check_locked(inner, &app));
        outs
    }
}
