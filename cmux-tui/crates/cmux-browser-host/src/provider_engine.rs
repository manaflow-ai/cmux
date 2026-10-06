//! The engine of a session over a [`TabSource`]: today the app's provider
//! (`cef` or `webkit`, [`crate::provider_source`]).
//!
//! The source announces its tabs; a session lists them with `tabs.list` and
//! names one by `targetId` in every call. Tab lifecycle calls (`tabs.open`,
//! `tabs.close`, `tabs.activate`) go to the source, which owns tabs. Every
//! call that names a tab passes the source's refusal rules first (browser
//! pages, the interim extension rule). The ownership rules live here, once
//! for every source: created tabs close at the session's end unless kept,
//! automation leases, the session's request filter, its events.

use crate::driver::{Driver, EventSink, Reply};
use crate::lease::{LeaseCaller, LeaseError, LeaseOp};
use crate::protocol::{DriverError, DriverEvent};
use crate::provider_link::ProviderDriver;
use crate::tab_source::{TabCall, TabSource};
use serde_json::{Value, json};
use std::collections::BTreeSet;
use std::sync::{Arc, Mutex, PoisonError};

/// A session's view of the provider: `engine` is `cef` or `webkit`.
pub struct ProviderEngine {
    provider: Arc<dyn TabSource>,
    engine: String,
    agent_source: Arc<str>,
    subscription: u64,
    /// The session's own event sink (the one the provider subscription
    /// holds, tee'd to the app for automation.input).
    events: EventSink,
    /// The session's lease identity (stamped from its connection).
    lease: LeaseCaller,
    /// Tabs the session created (`tabs.open` and their popups) and did not
    /// keep (`tab.keep`): they close when the session ends.
    created: Arc<Mutex<BTreeSet<String>>>,
    /// Set once the session's end released its leases (close, or the
    /// backstop drop), so a late drop of a closed engine never clears the
    /// leases of a new session with the same name.
    ended: std::sync::atomic::AtomicBool,
}

/// Driver methods that only read a tab: they never take or block a lease
/// (automation lease contract, `observe`). Every other call on a tab is an
/// `act`.
const OBSERVE_METHODS: &[&str] = &[
    "frame.observe",
    "tab.info",
    "tab.screenshot",
    "frames.list",
    "frame.contentFrame",
    "frame.contentFrames",
    "frame.ownerBox",
    "frame.focused",
];

fn lease_refusal(method: &str, error: LeaseError) -> DriverError {
    let reason = match error {
        LeaseError::LeaseHeld => "another agent session holds this tab",
        LeaseError::PausedByUser => "the person used this tab; wait for them to hand it back",
        LeaseError::UserDriving => "the person is driving this tab; wait for them to hand it back",
        LeaseError::StaleAfterHandBack => "the person handed the tab back; observe it again first",
        LeaseError::StoppedByUser => "the person stopped this agent",
        LeaseError::SessionRequired => "the person's tabs need a named session",
        _ => "the tab's automation lease refused the call",
    };
    let mut refusal =
        DriverError::new(crate::protocol::ErrorCode::Forbidden, format!("{method}: {reason}"));
    refusal.error_name = Some(error.code().to_owned());
    refusal
}

impl ProviderEngine {
    /// A session on the app's provider link.
    pub fn new(
        provider: Arc<ProviderDriver>,
        engine: &str,
        agent_source: Arc<str>,
        events: EventSink,
        lease: LeaseCaller,
    ) -> Result<ProviderEngine, DriverError> {
        let source: Arc<dyn TabSource> = Arc::new(crate::provider_source::ProviderSource(provider));
        ProviderEngine::with_source(source, engine, agent_source, events, lease)
    }

    /// A session on any tab source.
    pub fn with_source(
        provider: Arc<dyn TabSource>,
        engine: &str,
        agent_source: Arc<str>,
        events: EventSink,
        lease: LeaseCaller,
    ) -> Result<ProviderEngine, DriverError> {
        if let Some(reason) = provider.closed_reason() {
            return Err(DriverError::closed(reason));
        }
        // A popup of a tab the session created is the session's too.
        let created: Arc<Mutex<BTreeSet<String>>> = Arc::default();
        let popups = created.clone();
        let session_events = events.clone();
        let subscription = provider.subscribe(Arc::new(move |event: DriverEvent| {
            // Only the source's policy log hook writes the policy log.
            if event.name == crate::driver::POLICY_LOG_EVENT {
                return;
            }
            if event.name == "tab.created"
                && let (Some(target), Some(opener)) = (
                    event.payload.get("targetId").and_then(Value::as_str),
                    event.payload.get("openerTargetId").and_then(Value::as_str),
                )
            {
                let mut created = popups.lock().unwrap_or_else(PoisonError::into_inner);
                if created.contains(opener) {
                    created.insert(target.to_owned());
                }
            }
            session_events(event);
        }));
        let log_events = events.clone();
        provider.policy_log(
            subscription,
            Arc::new(move |entry: Value| {
                log_events(DriverEvent {
                    name: crate::driver::POLICY_LOG_EVENT.to_owned(),
                    payload: entry,
                });
            }),
        );
        Ok(ProviderEngine {
            created,
            provider,
            engine: engine.to_owned(),
            agent_source,
            subscription,
            events,
            lease,
            ended: std::sync::atomic::AtomicBool::new(false),
        })
    }

    /// `tabs.list`: one shape for every source (driver-protocol.md).
    fn tabs_list(&self) -> Value {
        Value::Array(self.provider.tab_rows(&self.engine).iter().map(|row| row.to_json()).collect())
    }
}

impl ProviderEngine {
    /// `Driver::call` with `announce` run after every check, right before
    /// the dispatch (never for a refused call).
    fn call_with(
        &self,
        method: &str,
        params: &Value,
        announce: &mut dyn FnMut(),
        raw: bool,
    ) -> Result<Reply, DriverError> {
        // A closed session's engine can outlive the close (a timed-out cell
        // still runs); it must not take a lease nobody will end.
        if self.ended.load(std::sync::atomic::Ordering::SeqCst) {
            return Err(DriverError::closed("the session was closed"));
        }
        if let Some(reason) = self.provider.closed_reason() {
            return Err(DriverError::closed(reason));
        }
        match method {
            "tabs.list" => return Ok(Reply::Value(self.tabs_list())),
            // The app owns tabs: it opens them in the session's engine. Only
            // the URL and background pass; profile, workspace and focus are
            // never the agent's to pick (D12).
            "tabs.open" => {
                let mut open = serde_json::Map::new();
                for key in ["url", "background", "timeoutMs"] {
                    if let Some(value) = params.get(key) {
                        open.insert(key.into(), value.clone());
                    }
                }
                open.insert("engine".into(), Value::String(self.engine.clone()));
                announce();
                let opened = self.provider.call(method, &Value::Object(open))?;
                if let Some(target) = opened.get("targetId").and_then(Value::as_str) {
                    self.created_tabs().insert(target.to_owned());
                    self.provider.opened(self.subscription, target);
                }
                return Ok(Reply::Value(opened));
            }
            _ => {}
        }
        // Every other call names a tab: nothing tab-less (cookies of the
        // person's profile, for example) reaches the app.
        let target_id = match params.get("targetId") {
            Some(Value::String(id)) => id.as_str(),
            Some(_) => {
                return Err(DriverError::invalid(format!("{method}: targetId must be a string")));
            }
            None => {
                if let Some(result) = self.provider.session_call(self.subscription, method, params)
                {
                    announce();
                    return result.map(Reply::Value);
                }
                return Err(DriverError::new(
                    crate::protocol::ErrorCode::Unsupported,
                    format!("{method}: not available on the person's tabs without a targetId"),
                ));
            }
        };
        let Some(engine) = self.provider.tab_engine(target_id) else {
            return Err(DriverError::not_found(format!("{method}: no tab {target_id}")));
        };
        if engine != self.engine {
            return Err(DriverError::not_found(format!(
                "{method}: tab {target_id} is a {engine} tab; this session runs on {}",
                self.engine
            )));
        }
        if let Some(error) = self.provider.refusal(method, target_id) {
            return Err(error);
        }
        // Kept: the tab stays open when the session ends (the host owns the
        // session's tabs; the app has no part in it).
        if method == "tab.keep" {
            self.created_tabs().remove(target_id);
            self.provider.kept(self.subscription, target_id);
            return Ok(Reply::Value(Value::Null));
        }
        // A structured read: refused before the lease sees it unless it
        // calls an allowlisted page agent function.
        let observe = match method {
            "frame.observe" => Some(crate::observe::evaluate_params(params)?),
            _ => None,
        };
        // The automation lease: any call that is not a read acts (and takes
        // the lease when the tab has none) before it runs.
        let reads = OBSERVE_METHODS.contains(&method);
        // A handler registration, and the answer to a dialog or chooser the
        // source routed to this session, are neither inputs nor reads: they
        // never take, block or refresh a lease (the session that listens for
        // a tab's dialogs is often not the one that drives it; the source
        // refuses an answer from a session the event did not go to).
        let registration =
            matches!(method, "tab.handleEvents" | "dialog.respond" | "filechooser.respond");
        if !reads && !registration {
            let act = LeaseOp::Act { target: target_id.to_owned() };
            self.provider.lease(&act, &self.lease).map_err(|error| lease_refusal(method, error))?;
            // A close that ran between the check at the top and this lease
            // call must not leave a lease that nothing ends.
            if self.ended.load(std::sync::atomic::Ordering::SeqCst) {
                let release = LeaseOp::Release { target: target_id.to_owned() };
                let _ = self.provider.lease(&release, &self.lease);
                return Err(DriverError::closed("the session was closed"));
            }
        }
        // Every check passed (an ended session was refused above, also after
        // the lease): the caller's announcement goes out, then the dispatch.
        if self.ended.load(std::sync::atomic::Ordering::SeqCst) {
            return Err(DriverError::closed("the session was closed"));
        }
        announce();
        // Only the session's end names a close reason (it keeps those tabs
        // out of Reopen Closed); the agent's own close never does.
        let mut params = std::borrow::Cow::Borrowed(params);
        if method == "tabs.close"
            && params.get("reason").is_some()
            && let Some(fields) = params.to_mut().as_object_mut()
        {
            fields.remove("reason");
        }
        let result = self.provider.tab_call(&TabCall {
            session: self.subscription,
            engine: &engine,
            method,
            target_id,
            params: &params,
            observe: observe.as_ref(),
            agent_source: &self.agent_source,
            raw,
            origin: &self.lease.origin,
        });
        // A read is never blocked; only a read that succeeded is the fresh
        // observe after a hand back.
        if reads && result.is_ok() {
            let observe = LeaseOp::Observe { target: target_id.to_owned() };
            let _ = self.provider.lease(&observe, &self.lease);
        }
        result
    }
}

impl Driver for ProviderEngine {
    fn call(&self, method: &str, params: &Value) -> Result<Value, DriverError> {
        self.call_with(method, params, &mut || {}, false).and_then(reply_value)
    }

    fn call_announced(
        &self,
        method: &str,
        params: &Value,
        announce: &mut dyn FnMut(),
    ) -> Result<Value, DriverError> {
        self.call_with(method, params, announce, false).and_then(reply_value)
    }

    /// A script's value as the engine sent it (the page's key order).
    fn call_reply_announced(
        &self,
        method: &str,
        params: &Value,
        announce: &mut dyn FnMut(),
    ) -> Result<Reply, DriverError> {
        self.call_with(method, params, announce, true)
    }

    fn end_session(&self) {
        self.release_session();
    }

    /// The gate's events for this session go through the session's sink
    /// only (never `publish`, which reaches every subscribed session).
    /// An ended session's events are dropped here (true: the gate must not
    /// deliver them elsewhere either).
    fn send_session_event(&self, event: DriverEvent) -> bool {
        if !self.ended.load(std::sync::atomic::Ordering::SeqCst) {
            (self.events)(event);
        }
        true
    }

    /// The session's filter on the tabs it drives, where the source can
    /// filter (the gate fails closed where it cannot).
    fn set_request_filter(&self, filter: Option<crate::driver::RequestFilter>) -> bool {
        self.provider.set_request_filter(self.subscription, &self.engine, filter)
    }

    fn capabilities(&self) -> Vec<&'static str> {
        self.provider.capabilities(&self.engine)
    }
}

impl ProviderEngine {
    /// The session ends: its leases go (the app clears the badges). Runs
    /// once, from `end_session` (close) or, as a backstop, from drop.
    fn created_tabs(&self) -> std::sync::MutexGuard<'_, BTreeSet<String>> {
        self.created.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The session's end (close, reset, idle, the backstop drop), one path:
    /// the tabs it created and did not keep close (classic main), except a
    /// tab whose lease the person has taken (driving or paused), which stays
    /// as theirs; then every lease of the session is released.
    fn release_session(&self) {
        if !self.ended.swap(true, std::sync::atomic::Ordering::SeqCst) {
            let created = std::mem::take(&mut *self.created_tabs());
            for target in created {
                let users = matches!(
                    self.provider.lease_state(&target),
                    Some(
                        crate::provider::LeaseState::UserDriving
                            | crate::provider::LeaseState::Paused
                    )
                );
                if !users && self.provider.tab_engine(&target).is_some() {
                    let _ = self.provider.call(
                        "tabs.close",
                        &json!({
                            "targetId": target,
                            "timeoutMs": SESSION_END_CLOSE_MS,
                            "reason": SESSION_END_REASON,
                        }),
                    );
                }
            }
            let _ = self.provider.lease(&LeaseOp::SessionEnd, &self.lease);
            self.provider.session_ended(self.subscription);
        }
    }
}

fn reply_value(reply: Reply) -> Result<Value, DriverError> {
    match reply {
        Reply::Value(value) => Ok(value),
        Reply::Json(raw) => {
            serde_json::from_str(raw.get()).map_err(|e| DriverError::invalid(e.to_string()))
        }
    }
}

/// How long the session's end waits for the app to close one tab.
const SESSION_END_CLOSE_MS: u64 = 5000;

/// The `tabs.close` reason of the session's end: the app closes the tab
/// through the store without a closed-history record (`close-reason-v1`).
const SESSION_END_REASON: &str = "session_end";

impl Drop for ProviderEngine {
    fn drop(&mut self) {
        self.provider.unsubscribe(self.subscription);
        self.release_session();
    }
}

#[cfg(test)]
#[path = "provider_engine_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "provider_engine_lease_tests.rs"]
mod lease_tests;

#[cfg(test)]
#[path = "provider_engine_input_tests.rs"]
mod input_tests;

#[cfg(test)]
#[path = "provider_engine_reaper_tests.rs"]
mod reaper_tests;
