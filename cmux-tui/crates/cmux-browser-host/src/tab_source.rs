//! Where a session's tabs come from (item 4, ff decision D1, 2026-10-06).
//!
//! The session engine ([`crate::provider_engine::ProviderEngine`]) holds the
//! ownership rules every tab engine shares: tabs a session created close at
//! its end unless kept, automation leases (observe vs act), the session's
//! request filter on the tabs it drives, and events fanned out to the
//! sessions. A `TabSource` supplies the tabs and runs the calls: the app's
//! provider link (WebKit and CEF tabs) today, the shared headless browser
//! and the remote tab host later. Engine-neutral: nothing here names an
//! engine's transport.

use crate::driver::{EventSink, RequestFilter};
use crate::lease::{LeaseCaller, LeaseError, LeaseOp};
use crate::protocol::DriverError;
use crate::provider::{LeaseState, TabAnnounce};
use serde_json::Value;
use std::sync::Arc;

/// One call on one tab, after the session engine's checks passed.
pub struct TabCall<'a> {
    /// The session's subscription id (its filter and driven tabs).
    pub session: u64,
    /// The session's engine name (`cef`, `webkit`, `headless`).
    pub engine: &'a str,
    pub method: &'a str,
    pub target_id: &'a str,
    pub params: &'a Value,
    /// For `frame.observe`: the agent-world `frame.evaluate` it runs as.
    pub observe: Option<&'a Value>,
    /// The page agent bundle, for a source that attaches tabs lazily.
    pub agent_source: &'a Arc<str>,
}

pub trait TabSource: Send + Sync {
    /// Why the source can serve no call, if it closed.
    fn closed_reason(&self) -> Option<String>;
    /// Adds a session's event receiver; returns its id.
    fn subscribe(&self, sink: EventSink) -> u64;
    fn unsubscribe(&self, id: u64);
    /// The tabs of one engine.
    fn tab_list(&self, engine: &str) -> Vec<TabAnnounce>;
    /// The engine of a tab, `None` when the tab is unknown.
    fn tab_engine(&self, target_id: &str) -> Option<String>;
    /// A refusal for `method` on the tab (browser pages, extension tabs).
    fn refusal(&self, method: &str, target_id: &str) -> Option<DriverError>;
    fn lease(&self, op: &LeaseOp, caller: &LeaseCaller) -> Result<(), LeaseError>;
    fn lease_state(&self, target_id: &str) -> Option<LeaseState>;
    /// Calls that are not one tab's: `tabs.open`, the session end's
    /// `tabs.close` with its reason.
    fn call(&self, method: &str, params: &Value) -> Result<Value, DriverError>;
    /// A call on one tab.
    fn tab_call(&self, call: &TabCall<'_>) -> Result<Value, DriverError>;
    /// Installs (or with `None` removes) a session's request filter; false
    /// when the engine cannot filter (the gate then fails closed).
    fn set_request_filter(&self, session: u64, engine: &str, filter: Option<RequestFilter>)
    -> bool;
    /// The session ended: its filter goes.
    fn session_ended(&self, session: u64);
    fn capabilities(&self, engine: &str) -> Vec<&'static str>;
}
