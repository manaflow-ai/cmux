//! Routes an app's catalog op into this daemon's own `cmux.protocol/2`
//! dispatcher, the same validation and owner code every client goes
//! through, and bridges daemon change events to app subscriptions.
//!
//! Gap: the protocol has no actor field yet, so `actor = app:<id>` and the
//! call's origin are enforced here (scopes, gesture-gated focus ops) and not
//! stamped on the owner's records. When the dispatcher grows an actor, pass
//! `app` and `origin` through.

use std::sync::{Arc, Weak};

use serde_json::{Value, json};

use super::mirror::Origin;
use super::supervisor::OpRouter;
use crate::mux::Mux;
use crate::request_origin::RequestOrigin;
use crate::supervised::{self, Fatal, ShutdownBehavior};
use crate::{Actor, MuxEvent, resource_router};

use super::envelope::error;
pub(crate) use super::envelope::{answer, error_answer, is_daemon_op, request};

pub struct MuxRouter {
    mux: Weak<Mux>,
}

impl MuxRouter {
    pub fn new(mux: &Arc<Mux>) -> Self {
        Self { mux: Arc::downgrade(mux) }
    }
}

impl OpRouter for MuxRouter {
    fn route(
        &self,
        app: &str,
        op: &str,
        params: Value,
        idempotency_key: Option<String>,
        _origin: Origin,
    ) -> Result<Value, Value> {
        let mux = self
            .mux
            .upgrade()
            .ok_or_else(|| error("operation.failed", "the daemon is shutting down"))?;
        // The supervisor calls in on its own threads: what an app's op sets
        // off is automation, as its origin below is `app`, and it runs at
        // automation's class (crate::request_qos).
        let _cause = mux.request_qos().enter(RequestOrigin::App.event_cause());
        // An app's call has origin app (request-origin.md): gate A2 refuses
        // the operations that need the user.
        crate::request_origin::require_origin(op, RequestOrigin::App)
            .map_err(|e| json!({ "code": e.code, "message": e.message, "details": e.details, "retryable": e.retryable }))?;
        let message = request(op, params, idempotency_key)?;
        let parsed = resource_router::parse_resource_request_as(
            &message,
            Actor::App { id: app.to_string() },
        )
        .map_err(|e| error_answer(&json!(e)))?;
        if resource_router::requires_connection_context(parsed.envelope.operation) {
            return Err(error(
                "operation.unsupported",
                format!("{op} needs a client connection and is not available to apps"),
            ));
        }
        let response = resource_router::handle_parsed_resource_request(&mux, parsed)
            .map_err(|e| error_answer(&json!(e)))?;
        answer(op, response)
    }

    fn owns(&self, op: &str) -> bool {
        is_daemon_op(op)
    }

    fn start_events(&self, publish: Box<dyn Fn(&str) + Send + Sync>) {
        let Some(mux) = self.mux.upgrade() else { return };
        let events = mux.subscribe();
        drop(mux);
        let _ = supervised::spawn_at(
            "cmux-apps-events",
            cmux_threads::ThreadQos::Utility,
            Fatal,
            ShutdownBehavior::Continue,
            move || {
                while let Ok(event) = events.recv() {
                    for stream in streams(&event) {
                        publish(stream);
                    }
                }
            },
        );
    }

    fn spawn_backend_terminal(
        &self,
        side: crate::terminal_backend::pty::BackendSide,
    ) -> anyhow::Result<crate::mux::app_terminals::BackendTerminal> {
        let mux = self.mux.upgrade().ok_or_else(|| anyhow::anyhow!("the daemon is stopping"))?;
        mux.spawn_backend_terminal(side)
    }

    fn backend_terminal_viewed(&self, surface: crate::SurfaceId) -> bool {
        self.mux.upgrade().is_some_and(|mux| mux.backend_terminal_viewed(surface))
    }

    fn close_backend_terminal(&self, surface: crate::SurfaceId) {
        if let Some(mux) = self.mux.upgrade() {
            mux.close_backend_terminal(surface);
        }
    }
}

/// The app streams a daemon event invalidates (`cmux.live` re-reads on them).
fn streams(event: &MuxEvent) -> &'static [&'static str] {
    match event {
        MuxEvent::TreeChanged | MuxEvent::TreeSelectionChanged | MuxEvent::TreeDelta(_) => &[
            "workspace.changed",
            "screen.changed",
            "pane.changed",
            "tab.changed",
            "terminal.changed",
        ],
        MuxEvent::AgentChanged { .. } => &["agent.changed"],
        _ => &[],
    }
}

#[cfg(test)]
#[path = "routing_event_cause_tests.rs"]
mod event_cause_tests;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn requests_fill_current_selectors_only_where_the_op_takes_them() {
        let message: Value =
            serde_json::from_str(&request("workspace.list", json!({}), None).unwrap()).unwrap();
        assert_eq!(message["params"], json!({ "machine": "current", "session": "current" }));
        assert!(message.get("idempotency_key").is_none());
        let focus: Value = serde_json::from_str(
            &request("tab.focus", json!({ "tab": "tab_1" }), Some("k".into())).unwrap(),
        )
        .unwrap();
        assert_eq!(focus["idempotency_key"], "k");
        assert_eq!(
            request("made.up", json!({}), None).unwrap_err()["code"],
            "operation.unsupported"
        );
    }

    #[test]
    fn answers_wrap_reads_and_pass_mutation_results_through() {
        assert_eq!(
            answer("workspace.list", json!({ "ok": true, "result": [1] })).unwrap(),
            json!({ "value": [1] })
        );
        let mutation =
            json!({ "value": {}, "revision": "3", "replayed": false, "generation": "g" });
        assert_eq!(
            answer("tab.focus", json!({ "ok": true, "result": mutation.clone() })).unwrap(),
            mutation
        );
        let err = answer("tab.focus", json!({ "ok": false, "error": { "code": "selector.not_found", "message": "no tab", "retryable": false } })).unwrap_err();
        assert_eq!(err["code"], "selector.not_found");
    }
}
