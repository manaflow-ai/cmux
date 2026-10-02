//! The driver trait: one engine behind the driver protocol.

use crate::protocol::{DriverError, DriverEvent};
use serde_json::Value;
use std::sync::Arc;

/// Receives driver events. Called on the driver's own threads; it must not
/// block on a driver call.
pub type EventSink = Arc<dyn Fn(DriverEvent) + Send + Sync>;

/// One engine behind the driver protocol. Calls block the calling thread
/// until the result arrives or the call's deadline (`timeoutMs`, else
/// [`crate::protocol::DEFAULT_TIMEOUT`]) passes.
pub trait Driver: Send + Sync {
    /// Runs one driver protocol method.
    fn call(&self, method: &str, params: &Value) -> Result<Value, DriverError>;

    /// Capability names beyond the core protocol (`cdp`, `route`, `history`, `tabGroups`).
    fn capabilities(&self) -> Vec<&'static str>;
}

/// An event sink that drops every event.
pub fn discard_events() -> EventSink {
    Arc::new(|_| {})
}
