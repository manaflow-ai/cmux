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

use crate::driver::{EventSink, Reply, RequestFilter};
use crate::lease::{LeaseCaller, LeaseError, LeaseOp};
use crate::protocol::DriverError;
use crate::provider::LeaseState;
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
    /// The caller takes a script's value as the engine sent it
    /// ([`Reply::Json`], the page's key order).
    pub raw: bool,
    /// The session's origin (`user` is the person, who also reads the
    /// host's own diagnostics in `tab.info`).
    pub origin: &'a str,
}

/// Where a source sends an entry for one session's policy log.
pub type PolicyLogSink = Arc<dyn Fn(Value) + Send + Sync>;

/// The `tabs.list` answer every source gives (driver-protocol.md, `tabs.list`):
/// an array of `{ targetId, title, url, active, windowId, state, dataStore,
/// openerTargetId? }`. Err names the first row or field that breaks it.
/// One row of `tabs.list` (driver-protocol.md), whatever the source.
#[derive(Debug, Clone, PartialEq)]
pub struct TabRow {
    pub target_id: String,
    pub title: String,
    pub url: String,
    pub active: bool,
    /// The workspace (app tabs) or the browser window (headless).
    pub window_id: Value,
    /// `live`, `hibernated`, `waking` or `crashed`.
    pub state: String,
    /// Tabs with equal `dataStore` share cookies and storage.
    pub data_store: String,
    pub opener: Option<String>,
    /// In an in-memory store that keeps nothing (private data P1).
    pub incognito: bool,
}

impl TabRow {
    pub fn to_json(&self) -> Value {
        let mut row = serde_json::json!({
            "targetId": self.target_id, "title": self.title, "url": self.url,
            "active": self.active, "windowId": self.window_id, "state": self.state,
            "dataStore": self.data_store,
        });
        if let Some(opener) = &self.opener {
            row["openerTargetId"] = Value::String(opener.clone());
        }
        if self.incognito {
            row["incognito"] = Value::Bool(true);
        }
        row
    }
}

pub fn check_tabs_list_shape(value: &Value) -> Result<(), String> {
    let rows = value.as_array().ok_or_else(|| format!("tabs.list is not an array: {value}"))?;
    for row in rows {
        let field = |name: &str| row.get(name).ok_or_else(|| format!("row without {name}: {row}"));
        field("targetId")?.as_str().ok_or_else(|| format!("targetId is not a string: {row}"))?;
        field("title")?.as_str().ok_or_else(|| format!("title is not a string: {row}"))?;
        field("url")?.as_str().ok_or_else(|| format!("url is not a string: {row}"))?;
        field("active")?.as_bool().ok_or_else(|| format!("active is not a boolean: {row}"))?;
        field("windowId")?;
        let state = field("state")?.as_str().unwrap_or("");
        if !matches!(state, "live" | "hibernated" | "waking" | "crashed") {
            return Err(format!("state is not live, hibernated, waking or crashed: {row}"));
        }
        field("dataStore")?.as_str().ok_or_else(|| format!("dataStore is not a string: {row}"))?;
        if let Some(opener) = row.get("openerTargetId") {
            opener.as_str().ok_or_else(|| format!("openerTargetId is not a string: {row}"))?;
        }
    }
    Ok(())
}

pub trait TabSource: Send + Sync {
    /// Why the source can serve no call, if it closed.
    fn closed_reason(&self) -> Option<String>;
    /// Adds a session's event receiver; returns its id.
    fn subscribe(&self, sink: EventSink) -> u64;
    fn unsubscribe(&self, id: u64);
    /// The policy log of subscriber `id` (until it unsubscribes): where the
    /// source logs what it did for the session on its own (D2).
    fn policy_log(&self, _id: u64, _sink: PolicyLogSink) {}
    /// The tabs of one engine, as `tabs.list` rows.
    fn tab_rows(&self, engine: &str) -> Vec<TabRow>;
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
    fn tab_call(&self, call: &TabCall<'_>) -> Result<Reply, DriverError>;
    /// A call that names no tab, when the source serves it (`None`: the
    /// session engine refuses it; the person's tabs answer no tab-less call).
    fn session_call(
        &self,
        _session: u64,
        _method: &str,
        _params: &Value,
    ) -> Option<Result<Value, DriverError>> {
        None
    }
    /// `tabs.open` for a session (a source applies the session's
    /// `session.configure` options to the new tab here).
    fn open_tab(&self, _session: u64, params: &Value) -> Result<Value, DriverError> {
        self.call("tabs.open", params)
    }
    /// The session opened `target_id` (`tabs.open`): it drives it.
    fn opened(&self, _session: u64, _target_id: &str) {}
    /// The session kept `target_id` (`tab.keep`): it is the person's now.
    fn kept(&self, _session: u64, _target_id: &str) {}
    /// Installs (or with `None` removes) a session's request filter; false
    /// when the engine cannot filter (the gate then fails closed).
    fn set_request_filter(&self, session: u64, engine: &str, filter: Option<RequestFilter>)
    -> bool;
    /// The session ended: its filter goes.
    fn session_ended(&self, session: u64);
    fn capabilities(&self, engine: &str) -> Vec<&'static str>;
}
