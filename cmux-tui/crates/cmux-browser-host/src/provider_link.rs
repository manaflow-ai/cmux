//! The host side of the app's provider connection (step c).
//!
//! The app dials the host and authenticates with the per-launch provider
//! secret in `hello`; the host answers `hello.ack` with the page agent
//! bundle. After that, [`ProviderDriver`] forwards driver protocol calls on
//! the provider's WebKit tabs and receives their results and events.

use crate::cdp::{CdpConnection, CdpWire};
use crate::driver::{Driver, EventSink};
use crate::protocol::{DriverError, DriverEvent, timeout_of};
use crate::provider::{Frame, TabAnnounce, read_frame, write_frame};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError, mpsc};

mod handshake;
mod input_wire;
mod lease_wire;
mod tab_table;
pub use handshake::{ProviderInfo, accept};
pub use input_wire::{AUTOMATION_INPUT, tee_inputs};
use lease_wire::{Leases, apply_lease, user_lease_op};
use tab_table::TabTable;
pub use tab_table::{BROWSER_PAGE, EXTENSION_HOST_ACCESS};

type Waiters = Arc<Mutex<HashMap<u64, mpsc::SyncSender<Result<Value, DriverError>>>>>;

/// Driver protocol calls forwarded to the app's driver for provider tabs.
/// Calls on a CEF tab follow the interim extension rule (`tab.access`).
pub struct ProviderDriver {
    writer: SharedWriter,
    waiters: Waiters,
    next_id: AtomicU64,
    closed: Arc<Mutex<Option<String>>>,
    tabs: Arc<Mutex<TabTable>>,
    /// Open CDP relays of CEF tabs, by targetId (`cdp.attach`).
    relays: Relays,
    /// Sessions that receive the provider's events (`subscribe`).
    subscribers: Subscribers,
    next_subscriber: AtomicU64,
    /// Per-tab CDP drivers of CEF tabs (`crate::provider_engine`).
    pub(crate) cef_tabs: CefTabs,
    /// Serializes relay attaches (the reader thread never takes it, so an
    /// attach waiting for its first reply cannot block the reader).
    pub(crate) attach_lock: Mutex<()>,
    /// The automation leases of the provider's tabs (the host owns them).
    leases: Leases,
    /// Each session's request filter and the CEF tabs it applies to
    /// (`crate::provider_engine`), by subscription id.
    pub(crate) request_filters: Mutex<HashMap<u64, crate::provider_engine::SessionFilter>>,
}

pub(crate) type CefTabs = Arc<Mutex<HashMap<String, Arc<crate::provider_engine::CefTab>>>>;

type SharedWriter = Arc<Mutex<Box<dyn Write + Send>>>;
type Relays = Arc<Mutex<HashMap<String, Arc<CdpConnection>>>>;
type Subscribers = Arc<Mutex<Vec<(u64, EventSink)>>>;

/// Sends a relayed CEF tab's CDP messages as `cdp` frames.
struct RelayWire {
    writer: SharedWriter,
    target_id: String,
}

impl CdpWire for RelayWire {
    fn send(&self, message: &str) -> std::io::Result<()> {
        let frame = Frame::Cdp { target_id: self.target_id.clone(), message: message.to_owned() };
        write_frame(&mut *self.writer.lock().unwrap_or_else(PoisonError::into_inner), &frame)
            .map_err(|error| std::io::Error::other(error.to_string()))
    }
}

impl ProviderDriver {
    /// Starts the reader thread on an accepted connection. `tabs` are the
    /// tabs the app announced in `hello`.
    pub fn start(
        mut reader: impl Read + Send + 'static,
        writer: impl Write + Send + 'static,
        events: EventSink,
        tabs: Vec<TabAnnounce>,
    ) -> std::io::Result<Arc<ProviderDriver>> {
        let waiters: Waiters = Arc::new(Mutex::new(HashMap::new()));
        let closed = Arc::new(Mutex::new(None));
        let mut table = TabTable::default();
        for tab in &tabs {
            table.announce(tab);
        }
        let tabs = Arc::new(Mutex::new(table));
        let relays: Relays = Arc::new(Mutex::new(HashMap::new()));
        let subscribers: Subscribers = Arc::new(Mutex::new(Vec::new()));
        let (thread_waiters, thread_closed, thread_tabs) =
            (waiters.clone(), closed.clone(), tabs.clone());
        let cef_tabs: CefTabs = Arc::new(Mutex::new(HashMap::new()));
        let writer: SharedWriter = Arc::new(Mutex::new(Box::new(writer)));
        let leases: Leases = Arc::default();
        let (thread_writer, thread_leases) = (writer.clone(), leases.clone());
        let (thread_relays, thread_subscribers, thread_cef_tabs) =
            (relays.clone(), subscribers.clone(), cef_tabs.clone());
        std::thread::Builder::new().name("cmux-browser-host-provider".into()).spawn(move || {
            let reason = loop {
                match read_frame(&mut reader) {
                    Ok(Some(Frame::Event { name, payload })) => {
                        thread_tabs
                            .lock()
                            .unwrap_or_else(PoisonError::into_inner)
                            .apply_event(&name, &payload);
                        // The tab went away, or the app replaced its Chromium
                        // browser (`tab.relay.closed`): its relay and driver go;
                        // the next call attaches again.
                        if matches!(name.as_str(), "tab.gone" | "tab.relay.closed")
                            && let Some(target_id) = payload.get("targetId").and_then(Value::as_str)
                        {
                            let relay = thread_relays
                                .lock()
                                .unwrap_or_else(PoisonError::into_inner)
                                .remove(target_id);
                            if let Some(relay) = relay {
                                relay.close("the tab closed");
                            }
                            thread_cef_tabs
                                .lock()
                                .unwrap_or_else(PoisonError::into_inner)
                                .remove(target_id);
                        }
                        // A gone tab takes its automation lease with it.
                        if name == "tab.gone"
                            && let Some(target_id) = payload.get("targetId").and_then(Value::as_str)
                        {
                            let op =
                                crate::lease::LeaseOp::TargetGone { target: target_id.to_owned() };
                            let caller = crate::lease::LeaseCaller::default();
                            let _ = apply_lease(&thread_leases, &thread_writer, &op, &caller);
                        }
                        let event = DriverEvent { name, payload };
                        let sinks: Vec<EventSink> = thread_subscribers
                            .lock()
                            .unwrap_or_else(PoisonError::into_inner)
                            .iter()
                            .map(|(_, sink)| sink.clone())
                            .collect();
                        for sink in sinks {
                            sink(event.clone());
                        }
                        events(event);
                    }
                    // A person used a tab: its driving lease pauses.
                    Ok(Some(Frame::UserInput { target_id })) => {
                        let op = crate::lease::LeaseOp::UserInput { target: target_id };
                        let caller = crate::lease::LeaseCaller::default();
                        let _ = apply_lease(&thread_leases, &thread_writer, &op, &caller);
                    }
                    Ok(Some(Frame::LeaseUser { op, target_id, actor })) => {
                        if let Some(op) = user_lease_op(&op, target_id, actor) {
                            let caller = crate::lease::LeaseCaller {
                                origin: "user".into(),
                                ..crate::lease::LeaseCaller::default()
                            };
                            let _ = apply_lease(&thread_leases, &thread_writer, &op, &caller);
                        }
                    }
                    Ok(Some(Frame::Cdp { target_id, message })) => {
                        let relay = thread_relays
                            .lock()
                            .unwrap_or_else(PoisonError::into_inner)
                            .get(&target_id)
                            .cloned();
                        if let Some(relay) = relay {
                            relay.receive(&message);
                        }
                    }
                    Ok(Some(Frame::TabAccess {
                        target_id,
                        extension_host_access,
                        user_override,
                        extensions,
                    })) => {
                        thread_tabs
                            .lock()
                            .unwrap_or_else(PoisonError::into_inner)
                            .access
                            .insert(target_id, (extension_host_access, user_override, extensions));
                    }
                    Ok(Some(frame @ Frame::Result { .. })) => {
                        if let Some((id, result)) = frame.into_call_result()
                            && let Some(waiter) = thread_waiters
                                .lock()
                                .unwrap_or_else(PoisonError::into_inner)
                                .remove(&id)
                        {
                            let _ = waiter.try_send(result);
                        }
                    }
                    Ok(Some(_)) => {}
                    Ok(None) => break "the cmux app disconnected".to_owned(),
                    Err(error) => break format!("provider connection failed: {error}"),
                }
            };
            *thread_closed.lock().unwrap_or_else(PoisonError::into_inner) = Some(reason.clone());
            let relays: Vec<_> =
                thread_relays.lock().unwrap_or_else(PoisonError::into_inner).drain().collect();
            for (_, relay) in relays {
                relay.close(&reason);
            }
            thread_cef_tabs.lock().unwrap_or_else(PoisonError::into_inner).clear();
            for (_, waiter) in thread_waiters.lock().unwrap_or_else(PoisonError::into_inner).drain()
            {
                let _ = waiter.try_send(Err(DriverError::closed(reason.clone())));
            }
        })?;
        Ok(Arc::new(ProviderDriver {
            writer,
            waiters,
            next_id: AtomicU64::new(1),
            closed,
            tabs,
            relays,
            subscribers,
            next_subscriber: AtomicU64::new(1),
            cef_tabs,
            attach_lock: Mutex::new(()),
            request_filters: Mutex::new(HashMap::new()),
            leases,
        }))
    }

    pub fn closed_reason(&self) -> Option<String> {
        self.closed.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    fn table(&self) -> std::sync::MutexGuard<'_, TabTable> {
        self.tabs.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The announced tabs, in announce order; only `engine`'s when given.
    pub fn tab_list(&self, engine: Option<&str>) -> Vec<TabAnnounce> {
        self.table()
            .info
            .iter()
            .filter(|tab| engine.is_none_or(|e| tab.engine == e))
            .cloned()
            .collect()
    }

    /// The engine the app announced for a tab.
    pub fn tab_engine(&self, target_id: &str) -> Option<String> {
        self.table().engine(target_id)
    }

    /// Why an agent call on `target_id` is refused (browser page, the
    /// interim extension rule), or `None`.
    pub fn refusal(&self, method: &str, target_id: &str) -> Option<DriverError> {
        self.table().refusal(method, target_id)
    }

    /// Opens the CDP relay of a CEF tab: a page-rooted connection whose
    /// messages travel as `cdp` frames, after `cdp.attach`.
    pub fn open_relay(
        &self,
        target_id: &str,
        alias: &str,
    ) -> Result<Arc<CdpConnection>, DriverError> {
        if let Some(reason) = self.closed_reason() {
            return Err(DriverError::closed(reason));
        }
        let conn = CdpConnection::page_rooted(
            Box::new(RelayWire { writer: self.writer.clone(), target_id: target_id.to_owned() }),
            alias,
        );
        let previous = self
            .relays
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(target_id.to_owned(), conn.clone());
        if let Some(previous) = previous {
            previous.close("the relay was reopened");
        }
        let frame = Frame::CdpAttach { target_id: target_id.to_owned() };
        write_frame(&mut *self.writer.lock().unwrap_or_else(PoisonError::into_inner), &frame)
            .map_err(|e| DriverError::closed(format!("provider write failed: {e}")))?;
        Ok(conn)
    }

    /// Closes a CEF tab's relay and tells the app (`cdp.detach`).
    pub fn close_relay(&self, target_id: &str) {
        let relay = self.relays.lock().unwrap_or_else(PoisonError::into_inner).remove(target_id);
        if let Some(relay) = relay {
            relay.close("the relay was closed");
            let frame = Frame::CdpDetach { target_id: target_id.to_owned() };
            let _ = write_frame(
                &mut *self.writer.lock().unwrap_or_else(PoisonError::into_inner),
                &frame,
            );
        }
    }

    /// Applies an agent's lease operation (act, observe, release, session
    /// end) and sends the changed `lease` frames to the app.
    pub fn lease(
        &self,
        op: &crate::lease::LeaseOp,
        caller: &crate::lease::LeaseCaller,
    ) -> Result<(), crate::lease::LeaseError> {
        apply_lease(&self.leases, &self.writer, op, caller)
    }

    /// Adds an event receiver (one per session); returns its id.
    /// The lease state of a tab, if it has a lease.
    pub fn lease_state(&self, target_id: &str) -> Option<crate::provider::LeaseState> {
        self.leases
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(target_id)
            .map(|record| record.lease.state)
    }

    pub fn subscribe(&self, sink: EventSink) -> u64 {
        let id = self.next_subscriber.fetch_add(1, Ordering::Relaxed);
        self.subscribers.lock().unwrap_or_else(PoisonError::into_inner).push((id, sink));
        id
    }

    pub fn unsubscribe(&self, id: u64) {
        self.subscribers.lock().unwrap_or_else(PoisonError::into_inner).retain(|(s, _)| *s != id);
    }

    /// Delivers an event to every subscriber (per-tab CDP driver events).
    pub fn publish(&self, event: DriverEvent) {
        let sinks: Vec<EventSink> = self
            .subscribers
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .map(|(_, sink)| sink.clone())
            .collect();
        for sink in sinks {
            sink(event.clone());
        }
    }
}

impl Driver for ProviderDriver {
    fn call(&self, method: &str, params: &Value) -> Result<Value, DriverError> {
        if let Some(reason) = self.closed_reason() {
            return Err(DriverError::closed(reason));
        }
        // Interim extension rule: checked on every call that names a tab,
        // before anything reaches the app. Tab-less calls (tabs.list,
        // tabs.open) pass; a new tab needs its own report before its first
        // call.
        if let Some(target_id) = params.get("targetId").and_then(Value::as_str)
            && let Some(error) =
                self.tabs.lock().unwrap_or_else(PoisonError::into_inner).refusal(method, target_id)
        {
            return Err(error);
        }
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = mpsc::sync_channel(1);
        self.waiters.lock().unwrap_or_else(PoisonError::into_inner).insert(id, tx);
        if let Some(reason) = self.closed_reason() {
            self.waiters.lock().unwrap_or_else(PoisonError::into_inner).remove(&id);
            return Err(DriverError::closed(reason));
        }
        let frame = Frame::Call { id, method: method.to_owned(), params: params.clone() };
        let written =
            write_frame(&mut *self.writer.lock().unwrap_or_else(PoisonError::into_inner), &frame);
        if let Err(error) = written {
            self.waiters.lock().unwrap_or_else(PoisonError::into_inner).remove(&id);
            return Err(DriverError::closed(format!("provider write failed: {error}")));
        }
        // A little longer than the call's own deadline, so the app's timeout wins.
        let wait = timeout_of(params) + std::time::Duration::from_secs(5);
        match rx.recv_timeout(wait) {
            Ok(result) => result,
            Err(_) => {
                self.waiters.lock().unwrap_or_else(PoisonError::into_inner).remove(&id);
                // The app may still act on it: input must not be replayed.
                Err(DriverError::new(
                    crate::protocol::ErrorCode::Ambiguous,
                    format!("{method}: no answer from the cmux app; the call may have run"),
                ))
            }
        }
    }

    fn capabilities(&self) -> Vec<&'static str> {
        vec!["history"]
    }
}

/// `{targetId}` payload helper for provider events.
pub fn target_payload(target_id: &str) -> Value {
    json!({"targetId": target_id})
}

#[cfg(test)]
mod tests;

#[cfg(test)]
mod input_tests;

#[cfg(test)]
#[path = "provider_link_table_tests.rs"]
mod table_tests;
