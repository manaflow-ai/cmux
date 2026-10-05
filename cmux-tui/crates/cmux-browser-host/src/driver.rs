//! The driver trait: one engine behind the driver protocol.

use crate::protocol::{DriverError, DriverEvent};
use serde_json::Value;
use std::sync::Arc;

/// Receives driver events. Called on the driver's own threads; it must not
/// block on a driver call.
pub type EventSink = Arc<dyn Fn(DriverEvent) + Send + Sync>;

/// One network request for the [`RequestFilter`].
#[derive(Debug, Clone, Copy)]
pub struct RequestInfo<'a> {
    /// The tab the request belongs to as the session names it (the app's
    /// tab id on provider engines, never the page's CDP id), or "" for a
    /// request no tab owns (a shared worker): a filter keyed by tab must
    /// decide those fail-closed.
    pub target: &'a str,
    pub url: &'a str,
    pub kind: RequestKind,
}

/// What kind of request it is. It changes only how a refusal is logged,
/// never whether the request is allowed.
#[non_exhaustive]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RequestKind {
    /// A main-frame document, each redirect hop included (CDP resourceType
    /// "Document" in the tab's main frame; the provider's navigation
    /// checks). Refusals of these are logged (`blocked: before`), as main.
    Document,
    /// A sub-frame (iframe) document, each redirect hop included.
    SubframeDocument,
    /// Everything else (scripts, fetch, WebSocket, ping, prefetch, unknown).
    Subresource,
}

/// Decides one network request: `Some(reason)` blocks it. Called on a
/// driver worker thread; it must not make driver calls.
pub type RequestFilter = Arc<dyn Fn(&RequestInfo<'_>) -> Option<String> + Send + Sync>;

/// One engine behind the driver protocol. Calls block the calling thread
/// until the result arrives or the call's deadline (`timeoutMs`, else
/// [`crate::protocol::DEFAULT_TIMEOUT`]) passes.
pub trait Driver: Send + Sync {
    /// Runs one driver protocol method.
    fn call(&self, method: &str, params: &Value) -> Result<Value, DriverError>;

    /// Capability names beyond the core protocol (`cdp`, `route`, `history`, `tabGroups`).
    fn capabilities(&self) -> Vec<&'static str>;

    /// Installs (or removes, with `None`) a filter that the engine applies
    /// to every request of every tab, before the request is sent: document
    /// navigations from page script, links, popups and redirects included.
    /// Returns false when the engine cannot filter requests.
    fn set_request_filter(&self, filter: Option<RequestFilter>) -> bool {
        let _ = filter;
        false
    }

    /// The session that opened this driver ends (`browser.repl.close`, a
    /// reset). A driver that holds per-session state (automation leases)
    /// releases it here, at once, not when the last reference drops.
    fn end_session(&self) {}

    /// Sends an event the gate publishes for this session (for example
    /// `automation.input`) down the driver's own event path for the
    /// session, so the engine's taps see it once (the provider engine tees
    /// inputs to the app). Returns false when the driver has no such path;
    /// the gate then delivers the event to the session itself.
    fn send_session_event(&self, event: DriverEvent) -> bool {
        let _ = event;
        false
    }

    /// One call that runs `announce` once, after the driver's own checks
    /// passed (a provider engine's lease and session state) and right
    /// before it dispatches; a call the driver refuses never runs it. The
    /// gate publishes `automation.input` there. The default has no checks
    /// of its own.
    fn call_announced(
        &self,
        method: &str,
        params: &Value,
        announce: &mut dyn FnMut(),
    ) -> Result<Value, DriverError> {
        announce();
        self.call(method, params)
    }
}

/// An event sink that drops every event.
pub fn discard_events() -> EventSink {
    Arc::new(|_| {})
}
