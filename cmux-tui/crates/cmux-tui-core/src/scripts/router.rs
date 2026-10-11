//! Routes a script's ops into this daemon's dispatcher and turns committed
//! resource changes into script event streams.

use std::sync::{Arc, Weak};

use cmux_app_host::script::ScriptRouter;
use serde_json::{Value, json};

use crate::apps::routing::{answer, is_daemon_op, request};
use crate::mux::Mux;
use crate::request_origin::{RequestOrigin, require_origin};
use crate::stream_interrupt::StreamInterrupt;
use crate::{Actor, resource_router};

/// Streams a committed resource change publishes. The journal epoch does not
/// say which family changed, so every family stream fires; scripts re-check
/// their predicate (`cmux.wait`).
pub(crate) const STREAMS: [&str; 6] = [
    "resource.changed",
    "workspace.changed",
    "screen.changed",
    "pane.changed",
    "tab.changed",
    "terminal.changed",
];

pub(crate) struct DaemonRouter {
    mux: Weak<Mux>,
    /// Prefix of every idempotency key: `script:<daemon nonce>:<session>:`.
    key_prefix: String,
}

impl DaemonRouter {
    pub(crate) fn new(mux: &Arc<Mux>, session: &str) -> Self {
        Self { mux: Arc::downgrade(mux), key_prefix: format!("script:{session}:") }
    }
}

fn error(code: &str, message: impl Into<String>) -> Value {
    json!({ "code": code, "message": message.into(), "retryable": false })
}

fn mint_key() -> Result<String, Value> {
    let mut bytes = [0u8; 12];
    getrandom::fill(&mut bytes).map_err(|e| {
        error("operation.failed", format!("could not mint an idempotency key: {e}"))
    })?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}

/// The ops a script may call: the ops this daemon's dispatcher owns.
pub(crate) fn admits(op: &str) -> bool {
    is_daemon_op(op)
}

impl ScriptRouter for DaemonRouter {
    fn call(&self, op: &str, params: Value, options: Value) -> Result<Value, Value> {
        if !admits(op) {
            return Err(error(
                "operation.unsupported",
                format!("{op} is not available to scripts on this cmux"),
            ));
        }
        let mux = self
            .mux
            .upgrade()
            .ok_or_else(|| error("operation.failed", "the daemon is shutting down"))?;
        // A script has the rights of the CLI that started it: a plain local
        // connection, which derives origin `agent` (request-origin.md).
        require_origin(op, RequestOrigin::Agent)
            .map_err(|e| json!({ "code": e.code, "message": e.message, "details": e.details, "retryable": e.retryable }))?;
        // Script keys live in their own namespace so they never meet another
        // caller's keys in an owner's replay cache.
        let own = options.get("idempotencyKey").and_then(Value::as_str).filter(|k| !k.is_empty());
        let own = match own {
            Some(own) => own.to_string(),
            None => mint_key()?,
        };
        let key = format!("{}{own}", self.key_prefix);
        let message = request(op, params, Some(key))?;
        let parsed = resource_router::parse_resource_request_as(&message, Actor::local_user())
            .map_err(|e| answer(op, json!({ "ok": false, "error": e })).unwrap_err())?;
        if resource_router::requires_connection_context(parsed.envelope.operation) {
            return Err(error(
                "operation.unsupported",
                format!("{op} needs a client connection and is not available to scripts"),
            ));
        }
        let response = resource_router::handle_parsed_resource_request(&mux, parsed)
            .map_err(|e| answer(op, json!({ "ok": false, "error": e })).unwrap_err())?;
        answer(op, response)
    }

    fn watch(&self, publish: Arc<dyn Fn(&str) + Send + Sync>) -> Box<dyn Send> {
        let interrupt = StreamInterrupt::new();
        let guard = Box::new(FireOnDrop(interrupt.clone()));
        let Some(mux) = self.mux.upgrade() else { return guard };
        mux.wake_journal_waiters_on(&interrupt);
        // Without a thread the session gets no events: `cmux.wait` then ends
        // at its own timeout.
        let _ = std::thread::Builder::new().name("cmux-script-events".into()).spawn(move || {
            let mut epoch = mux.journal_event_epoch();
            loop {
                let next = mux.wait_for_journal_event_until_interrupted(epoch, &interrupt);
                if interrupt.is_fired() {
                    return;
                }
                if next != epoch {
                    epoch = next;
                    for stream in STREAMS {
                        publish(stream);
                    }
                }
            }
        });
        guard
    }
}

/// Fires the watcher's interrupt when the session drops its guard.
struct FireOnDrop(Arc<StreamInterrupt>);

impl Drop for FireOnDrop {
    fn drop(&mut self) {
        self.0.fire();
    }
}
