//! The driver trait: one engine behind the driver protocol.

use crate::protocol::{DriverError, DriverEvent};
use serde_json::Value;
use std::sync::Arc;

/// Receives driver events. Called on the driver's own threads; it must not
/// block on a driver call.
pub type EventSink = Arc<dyn Fn(DriverEvent) + Send + Sync>;

/// Decides one network request: `(target id, url)`, `Some(reason)` blocks
/// it. The target id is the tab the request belongs to as the session names
/// it (the app's tab id on provider engines, never the page's CDP id), or ""
/// for a request no tab owns (a shared worker): a filter keyed by tab must
/// decide those fail-closed. Called on a driver worker thread; it must not
/// make driver calls.
pub type RequestFilter = Arc<dyn Fn(&str, &str) -> Option<String> + Send + Sync>;

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
}

/// An event sink that drops every event.
pub fn discard_events() -> EventSink {
    Arc::new(|_| {})
}
