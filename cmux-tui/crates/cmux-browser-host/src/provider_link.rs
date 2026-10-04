//! The host side of the app's provider connection (step c).
//!
//! The app dials the host and authenticates with the per-launch provider
//! secret in `hello`; the host answers `hello.ack` with the page agent
//! bundle. After that, [`ProviderDriver`] forwards driver protocol calls on
//! the provider's WebKit tabs and receives their results and events.

use crate::cdp::{CdpConnection, CdpWire};
use crate::driver::{Driver, EventSink};
use crate::protocol::{DriverError, DriverEvent, timeout_of};
use crate::provider::{
    Frame, MAX_HELLO_BYTES, ProviderSecret, TabAnnounce, read_frame, read_frame_limited,
    write_frame,
};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError, mpsc};

/// The `hello` the provider sent, once accepted.
#[derive(Debug, Clone)]
pub struct ProviderInfo {
    pub provider_id: String,
    pub install_id: String,
    pub engines: Vec<String>,
    pub tabs: Vec<TabAnnounce>,
}

/// Reads and checks `hello`, then sends `hello.ack`. Frames before
/// authentication are limited to [`MAX_HELLO_BYTES`].
pub fn accept(
    reader: &mut impl Read,
    writer: &mut impl Write,
    expected: &ProviderSecret,
    agent_bundle: &str,
) -> Result<ProviderInfo, DriverError> {
    let first = read_frame_limited(reader, MAX_HELLO_BYTES)
        .map_err(|e| DriverError::closed(format!("provider hello: {e}")))?
        .ok_or_else(|| DriverError::closed("provider closed before hello"))?;
    let Frame::Hello { version, provider_id, install_id, secret, engines, tabs } = first else {
        return Err(DriverError::new(
            crate::protocol::ErrorCode::Forbidden,
            "provider must start with hello",
        ));
    };
    if !secret.matches(expected) {
        return Err(DriverError::new(
            crate::protocol::ErrorCode::Forbidden,
            "provider secret does not match",
        ));
    }
    if version != crate::provider::PROVIDER_VERSION {
        return Err(DriverError::invalid(format!("provider version {version} is not supported")));
    }
    let sha = format!("{:016x}", fnv1a(agent_bundle.as_bytes()));
    write_frame(
        writer,
        &Frame::HelloAck { agent_bundle: agent_bundle.to_owned(), agent_bundle_sha: sha },
    )
    .map_err(|e| DriverError::closed(format!("provider hello.ack: {e}")))?;
    Ok(ProviderInfo { provider_id, install_id, engines, tabs })
}

/// A cheap content fingerprint so the app can skip reinstalling an unchanged bundle.
fn fnv1a(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
        (hash ^ u64::from(*byte)).wrapping_mul(0x0100_0000_01b3)
    })
}

type Waiters = Arc<Mutex<HashMap<u64, mpsc::SyncSender<Result<Value, DriverError>>>>>;

/// `errorName` of a call refused by the interim extension rule.
pub const EXTENSION_HOST_ACCESS: &str = "extension_host_access";

/// `errorName` of a call on a tab that shows a browser page (chrome://,
/// first-party cmux-page hosts: `policy::is_browser_page`).
pub const BROWSER_PAGE: &str = "browser_page";

/// The password lead's text (2026-10-04), the same as the app's control
/// path (`AppBrowserPage.agentExtensionRefusal`). Names go in `data`.
const EXTENSION_REFUSAL: &str = "the tab's profile has an enabled extension with access to this \
     page; open the tab with openBrowser profile \"agent\" (a profile without extensions), or ask \
     the person to allow agents in this tab";
const EXTENSION_REFUSAL_HINT: &str = "open the tab with openBrowser profile \"agent\" (a profile \
     without extensions), or ask the person to allow agents in this tab";

/// The provider's tabs as the app reports them: engine per tab, and for CEF
/// tabs the last `tab.access` report (interim extension rule).
#[derive(Default)]
struct TabTable {
    engines: HashMap<String, String>,
    /// The main-frame URL of each tab (hello, tab.announced, tab.navigated).
    urls: HashMap<String, String>,
    /// targetId -> (extension_host_access, user_override, extension names).
    access: HashMap<String, (bool, bool, Vec<String>)>,
    /// Every announced tab, in announce order (`tabs.list`).
    info: Vec<TabAnnounce>,
}

impl TabTable {
    fn announce(&mut self, tab: &TabAnnounce) {
        self.engines.insert(tab.target_id.clone(), tab.engine.clone());
        self.urls.insert(tab.target_id.clone(), tab.url.clone());
        match self.info.iter_mut().find(|known| known.target_id == tab.target_id) {
            Some(known) => *known = tab.clone(),
            None => self.info.push(tab.clone()),
        }
    }

    fn forget(&mut self, target_id: &str) {
        self.engines.remove(target_id);
        self.urls.remove(target_id);
        self.access.remove(target_id);
        self.info.retain(|tab| tab.target_id != target_id);
    }

    /// Updates the table from a provider event (`tab.announced`, `tab.gone`).
    fn apply_event(&mut self, name: &str, payload: &Value) {
        match name {
            "tab.announced" => {
                if let Ok(tab) = serde_json::from_value::<TabAnnounce>(payload.clone()) {
                    self.announce(&tab);
                }
            }
            // Provider tab.navigated is the main frame's (a sub-frame one
            // names its frameId).
            "tab.navigated" => {
                let main =
                    matches!(payload.get("frameId").and_then(Value::as_str), None | Some("main"));
                if main
                    && let (Some(target_id), Some(url)) = (
                        payload.get("targetId").and_then(Value::as_str),
                        payload.get("url").and_then(Value::as_str),
                    )
                {
                    self.urls.insert(target_id.to_owned(), url.to_owned());
                    if let Some(tab) = self.info.iter_mut().find(|t| t.target_id == target_id) {
                        tab.url = url.to_owned();
                    }
                }
            }
            "tab.gone" => {
                if let Some(target_id) = payload.get("targetId").and_then(Value::as_str) {
                    self.forget(target_id);
                }
            }
            _ => {}
        }
    }

    /// Why an agent call on `target_id` is refused, or `None`. WebKit tabs
    /// have no extensions. Every other tab (CEF, or one the app did not
    /// announce) needs a `tab.access` report that says no enabled extension
    /// holds host access on its page, or the person's override: fail closed.
    fn refusal(&self, method: &str, target_id: &str) -> Option<DriverError> {
        // D1: a tab that shows a browser page is never driven, on any engine.
        if let Some(url) = self.urls.get(target_id)
            && crate::policy::is_browser_page(url)
        {
            let mut error = DriverError::new(
                crate::protocol::ErrorCode::Forbidden,
                format!("{method}: {} is a browser page, not available to agents", url.trim()),
            );
            error.error_name = Some(BROWSER_PAGE.to_owned());
            return Some(error);
        }
        if self.engines.get(target_id).map(String::as_str) == Some("webkit") {
            return None;
        }
        let (message, names) = match self.access.get(target_id) {
            Some((false, _, _) | (true, true, _)) => return None,
            Some((true, false, names)) => (EXTENSION_REFUSAL.to_owned(), names.clone()),
            None => (
                format!(
                    "{method}: the cmux app has not reported this tab's extension access yet; {EXTENSION_REFUSAL_HINT}"
                ),
                Vec::new(),
            ),
        };
        let mut error = DriverError::new(crate::protocol::ErrorCode::Forbidden, message);
        error.error_name = Some(EXTENSION_HOST_ACCESS.to_owned());
        error.data = Some(json!({"reason": EXTENSION_HOST_ACCESS, "extensions": names}));
        Some(error)
    }
}

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
}

type Leases = Arc<Mutex<crate::lease::LeaseTable>>;

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX))
}

/// Applies a lease operation and sends a `lease` frame for every target
/// whose rendered lease changed.
fn apply_lease(
    leases: &Leases,
    writer: &SharedWriter,
    op: &crate::lease::LeaseOp,
    caller: &crate::lease::LeaseCaller,
) -> Result<(), crate::lease::LeaseError> {
    let frames =
        leases.lock().unwrap_or_else(PoisonError::into_inner).apply(op, caller, now_ms())?;
    let mut writer = writer.lock().unwrap_or_else(PoisonError::into_inner);
    for frame in frames {
        let _ = write_frame(
            &mut *writer,
            &Frame::Lease { target_id: frame.target, lease: frame.lease },
        );
    }
    Ok(())
}

/// A person's lease action from the app (`lease.user`), origin `user`.
fn user_lease_op(
    op: &str,
    target_id: Option<String>,
    session: Option<String>,
) -> Option<crate::lease::LeaseOp> {
    use crate::lease::LeaseOp;
    Some(match (op, target_id, session) {
        ("take_over", Some(target), _) => LeaseOp::TakeOver { target },
        ("hand_back", Some(target), _) => LeaseOp::HandBack { target },
        ("stop", Some(target), _) => LeaseOp::Stop { target },
        ("allow", _, Some(session)) => LeaseOp::Allow { session },
        _ => return None,
    })
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
                    Ok(Some(Frame::LeaseUser { op, target_id, session })) => {
                        if let Some(op) = user_lease_op(&op, target_id, session) {
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
        self.table().engines.get(target_id).cloned()
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
mod tests {
    use super::*;
    use std::os::unix::net::UnixStream;

    fn hello(secret: &str) -> Frame {
        Frame::Hello {
            version: crate::provider::PROVIDER_VERSION,
            provider_id: "app".into(),
            install_id: "inst".into(),
            secret: ProviderSecret::new(secret),
            engines: vec!["webkit".into()],
            tabs: Vec::new(),
        }
    }

    fn tab(target_id: &str, engine: &str) -> TabAnnounce {
        TabAnnounce {
            target_id: target_id.into(),
            engine: engine.into(),
            workspace: "w".into(),
            profile: "p".into(),
            url: "https://a.test/".into(),
            title: String::new(),
            visible: true,
        }
    }

    /// A fake app that answers every call with `{"method": ...}` and records
    /// the methods it saw. Frames the test sends go through `send`.
    struct FakeApp {
        writer: Arc<Mutex<UnixStream>>,
        seen: Arc<Mutex<Vec<(String, Value)>>>,
    }

    impl FakeApp {
        fn start(tabs: Vec<TabAnnounce>) -> (FakeApp, Arc<ProviderDriver>) {
            let (app, host) = UnixStream::pair().unwrap();
            let driver = ProviderDriver::start(
                host.try_clone().unwrap(),
                host,
                crate::driver::discard_events(),
                tabs,
            )
            .unwrap();
            let writer = Arc::new(Mutex::new(app.try_clone().unwrap()));
            let seen = Arc::new(Mutex::new(Vec::new()));
            let (thread_writer, thread_seen) = (writer.clone(), seen.clone());
            let mut reader = app;
            std::thread::spawn(move || {
                while let Ok(Some(Frame::Call { id, method, params })) = read_frame(&mut reader) {
                    thread_seen.lock().unwrap().push((method.clone(), params));
                    let frame =
                        Frame::Result { id, result: Some(json!({"method": method})), error: None };
                    if write_frame(&mut *thread_writer.lock().unwrap(), &frame).is_err() {
                        break;
                    }
                }
            });
            (FakeApp { writer, seen }, driver)
        }

        /// Sends `frame`, then a round trip on the WebKit tab "W", so the
        /// driver has read `frame` when this returns.
        fn send(&self, driver: &ProviderDriver, frame: Frame) {
            write_frame(&mut *self.writer.lock().unwrap(), &frame).unwrap();
            driver.call("tab.info", &json!({"targetId": "W"})).unwrap();
        }

        fn access(&self, driver: &ProviderDriver, target: &str, exposed: bool, user: bool) {
            self.send(
                driver,
                Frame::TabAccess {
                    target_id: target.into(),
                    extension_host_access: exposed,
                    user_override: user,
                    extensions: if exposed { vec!["Pass Keeper".into()] } else { Vec::new() },
                },
            );
        }

        fn saw(&self, method: &str, target: &str) -> bool {
            self.seen.lock().unwrap().iter().any(|(m, p)| m == method && p["targetId"] == target)
        }
    }

    /// The refusal text the password lead fixed (2026-10-04), the same in
    /// the app's control path (`AppBrowserPage.agentExtensionRefusal`).
    const REFUSAL_TEXT: &str = "the tab's profile has an enabled extension with access to this page; \
        open the tab with openBrowser profile \"agent\" (a profile without extensions), or ask the \
        person to allow agents in this tab";

    fn assert_refused(result: Result<Value, DriverError>) -> DriverError {
        let error = result.expect_err("the call must be refused");
        assert_eq!(error.code, crate::protocol::ErrorCode::Forbidden, "{error}");
        assert_eq!(error.error_name.as_deref(), Some("extension_host_access"), "{error}");
        let wire = error.to_json();
        assert_eq!(wire["data"]["reason"], "extension_host_access", "{wire}");
        assert!(wire["data"]["extensions"].is_array(), "{wire}");
        error
    }

    #[test]
    fn the_refusal_uses_the_agreed_text_and_names_the_extensions_in_data() {
        let (app, driver) = FakeApp::start(vec![tab("C", "cef"), tab("W", "webkit")]);
        app.access(&driver, "C", true, false);
        let error = assert_refused(driver.call("tab.info", &json!({"targetId": "C"})));
        assert_eq!(error.message, REFUSAL_TEXT);
        assert_eq!(
            error.to_json()["data"],
            json!({"reason": "extension_host_access", "extensions": ["Pass Keeper"]})
        );
        // Before the app reports the tab: same reason, no names.
        app.send(
            &driver,
            Frame::Event {
                name: "tab.announced".into(),
                payload: serde_json::to_value(tab("C2", "cef")).unwrap(),
            },
        );
        let unreported = assert_refused(driver.call("tab.info", &json!({"targetId": "C2"})));
        assert_eq!(unreported.to_json()["data"]["extensions"], json!([]));
        assert!(unreported.message.ends_with("or ask the person to allow agents in this tab"));
    }

    #[test]
    fn cef_tabs_are_refused_until_the_app_reports_clean_access() {
        let (app, driver) = FakeApp::start(vec![tab("C", "cef"), tab("W", "webkit")]);
        // No tab.access frame yet: fail closed, and the app never sees the call.
        assert_refused(
            driver.call("tab.navigate", &json!({"targetId": "C", "url": "https://b.test/"})),
        );
        assert!(!app.saw("tab.navigate", "C"));
        // An enabled extension holds host access on the page.
        app.access(&driver, "C", true, false);
        let named = assert_refused(driver.call("tab.info", &json!({"targetId": "C"})));
        assert_eq!(named.to_json()["data"]["extensions"], json!(["Pass Keeper"]), "{named}");
        for method in ["frame.evaluate", "input.mouse", "tab.screenshot", "cdp", "tabs.close"] {
            assert_refused(driver.call(method, &json!({"targetId": "C"})));
            assert!(!app.saw(method, "C"), "{method} reached the app");
        }
        // The profile is clean now.
        app.access(&driver, "C", false, false);
        assert_eq!(
            driver.call("tab.info", &json!({"targetId": "C"})).unwrap()["method"],
            "tab.info"
        );
        // An extension gains access again: refused from the next call.
        app.access(&driver, "C", true, false);
        assert_refused(driver.call("tab.info", &json!({"targetId": "C"})));
    }

    #[test]
    fn the_override_comes_only_from_the_app() {
        let (app, driver) = FakeApp::start(vec![tab("C", "cef"), tab("W", "webkit")]);
        app.access(&driver, "C", true, false);
        // Override fields in the agent's own params change nothing.
        assert_refused(driver.call(
            "tab.info",
            &json!({"targetId": "C", "user_override": true, "extension_host_access": false}),
        ));
        // The person confirmed in the app: the tab may be driven.
        app.access(&driver, "C", true, true);
        assert_eq!(
            driver.call("tab.info", &json!({"targetId": "C"})).unwrap()["method"],
            "tab.info"
        );
        // The app withdraws the override.
        app.access(&driver, "C", true, false);
        assert_refused(driver.call("tab.info", &json!({"targetId": "C"})));
    }

    #[test]
    fn webkit_tabs_and_tab_less_calls_need_no_access_report() {
        let (app, driver) = FakeApp::start(vec![tab("W", "webkit")]);
        assert_eq!(
            driver.call("tab.info", &json!({"targetId": "W"})).unwrap()["method"],
            "tab.info"
        );
        assert_eq!(driver.call("tabs.list", &json!({})).unwrap()["method"], "tabs.list");
        assert!(app.saw("tab.info", "W"));
    }

    #[test]
    fn announced_tabs_follow_their_engine_and_unknown_tabs_fail_closed() {
        let (app, driver) = FakeApp::start(vec![tab("W", "webkit")]);
        // A tab the app never announced: refused, like a CEF tab.
        assert_refused(driver.call("tab.info", &json!({"targetId": "X"})));
        // tab.announced registers a WebKit tab: no report needed.
        app.send(
            &driver,
            Frame::Event {
                name: "tab.announced".into(),
                payload: serde_json::to_value(tab("W2", "webkit")).unwrap(),
            },
        );
        assert_eq!(
            driver.call("tab.info", &json!({"targetId": "W2"})).unwrap()["method"],
            "tab.info"
        );
        // A new CEF tab needs its report.
        app.send(
            &driver,
            Frame::Event {
                name: "tab.announced".into(),
                payload: serde_json::to_value(tab("C2", "cef")).unwrap(),
            },
        );
        assert_refused(driver.call("tab.info", &json!({"targetId": "C2"})));
        app.access(&driver, "C2", false, false);
        assert_eq!(
            driver.call("tab.info", &json!({"targetId": "C2"})).unwrap()["method"],
            "tab.info"
        );
        // tab.gone forgets the tab and its report.
        app.send(&driver, Frame::Event { name: "tab.gone".into(), payload: target_payload("C2") });
        assert_refused(driver.call("tab.info", &json!({"targetId": "C2"})));
    }

    fn assert_browser_page(result: Result<Value, DriverError>) {
        let error = result.expect_err("the call must be refused");
        assert_eq!(error.code, crate::protocol::ErrorCode::Forbidden, "{error}");
        assert_eq!(error.error_name.as_deref(), Some(BROWSER_PAGE), "{error}");
    }

    /// D1 (coordinator, 2026-10-04): an agent never drives a tab that already
    /// shows a browser page (chrome://, a reserved cmux-page host), on any
    /// engine, whatever its extension report says.
    #[test]
    fn open_browser_page_tabs_are_refused() {
        let mut settings = tab("S", "webkit");
        settings.url = "chrome://settings/".into();
        let (app, driver) = FakeApp::start(vec![tab("W", "webkit"), settings, tab("C", "cef")]);
        assert_browser_page(driver.call("tab.info", &json!({"targetId": "S"})));
        assert!(!app.saw("tab.info", "S"));
        // A clean CEF tab navigates to a browser page: refused from then on.
        app.access(&driver, "C", false, false);
        assert_eq!(
            driver.call("tab.info", &json!({"targetId": "C"})).unwrap()["method"],
            "tab.info"
        );
        app.send(
            &driver,
            Frame::Event {
                name: "tab.navigated".into(),
                payload: json!({"targetId": "C", "url": "chrome://extensions/", "sameDocument": false}),
            },
        );
        assert_browser_page(driver.call("cdp", &json!({"targetId": "C"})));
        // A sub-frame navigation does not change the tab's page.
        app.send(
            &driver,
            Frame::Event {
                name: "tab.navigated".into(),
                payload: json!({"targetId": "C", "frameId": "F2", "url": "https://a.test/"}),
            },
        );
        assert_browser_page(driver.call("tab.info", &json!({"targetId": "C"})));
        // Back on a web page: allowed again.
        app.send(
            &driver,
            Frame::Event {
                name: "tab.navigated".into(),
                payload: json!({"targetId": "C", "url": "https://a.test/", "sameDocument": false}),
            },
        );
        assert_eq!(
            driver.call("tab.info", &json!({"targetId": "C"})).unwrap()["method"],
            "tab.info"
        );
    }

    /// D1: first-party cmux-page tabs (reserved hosts: cmux and cmux.*) are
    /// browser pages too. Red until policy::is_browser_page refuses them (the
    /// password lead's change to the shared rule and vectors).
    #[test]
    fn open_first_party_cmux_page_tabs_are_refused() {
        let mut page = tab("P", "cef");
        page.url = "cmux-page://cmux.settings/".into();
        let mut agent = tab("A", "webkit");
        agent.url = "cmux-page://cmux.agent/index.html".into();
        let (app, driver) = FakeApp::start(vec![tab("W", "webkit"), page, agent]);
        app.access(&driver, "P", false, false);
        assert_browser_page(driver.call("frame.evaluate", &json!({"targetId": "P"})));
        assert_browser_page(driver.call("cdp", &json!({"targetId": "A"})));
    }

    #[test]
    fn hello_needs_the_secret_and_gets_the_bundle() {
        let (mut app, host) = UnixStream::pair().unwrap();
        write_frame(&mut app, &hello("right")).unwrap();
        let (mut r, mut w) = (host.try_clone().unwrap(), host);
        let info = accept(&mut r, &mut w, &ProviderSecret::new("right"), "agent();").unwrap();
        assert_eq!(info.engines, vec!["webkit".to_string()]);
        match read_frame(&mut app).unwrap() {
            Some(Frame::HelloAck { agent_bundle, .. }) => assert_eq!(agent_bundle, "agent();"),
            other => panic!("expected hello.ack, got {other:?}"),
        }

        let (mut app, host) = UnixStream::pair().unwrap();
        write_frame(&mut app, &hello("wrong")).unwrap();
        let (mut r, mut w) = (host.try_clone().unwrap(), host);
        let refused = accept(&mut r, &mut w, &ProviderSecret::new("right"), "x").unwrap_err();
        assert_eq!(refused.code, crate::protocol::ErrorCode::Forbidden);
    }

    #[test]
    fn calls_round_trip_and_events_arrive() {
        let (app, host) = UnixStream::pair().unwrap();
        let events = Arc::new(Mutex::new(Vec::new()));
        let sink = events.clone();
        let driver = ProviderDriver::start(
            host.try_clone().unwrap(),
            host,
            Arc::new(move |e: DriverEvent| sink.lock().unwrap().push(e)),
            vec![tab("T", "webkit")],
        )
        .unwrap();
        let mut app_reader = app.try_clone().unwrap();
        let mut app_writer = app;
        let fake_app = std::thread::spawn(move || {
            let Some(Frame::Call { id, method, .. }) = read_frame(&mut app_reader).unwrap() else {
                panic!("call")
            };
            assert_eq!(method, "tab.info");
            write_frame(
                &mut app_writer,
                &Frame::Event { name: "tab.loadState".into(), payload: target_payload("T") },
            )
            .unwrap();
            write_frame(
                &mut app_writer,
                &Frame::Result { id, result: Some(json!({"url": "https://a.test/"})), error: None },
            )
            .unwrap();
            drop(app_writer);
        });
        let info = driver.call("tab.info", &json!({"targetId": "T"})).unwrap();
        assert_eq!(info["url"], "https://a.test/");
        fake_app.join().unwrap();
        assert_eq!(events.lock().unwrap()[0].name, "tab.loadState");
    }

    #[test]
    fn a_disconnect_fails_pending_and_later_calls() {
        let (app, host) = UnixStream::pair().unwrap();
        let driver = ProviderDriver::start(
            host.try_clone().unwrap(),
            host,
            crate::driver::discard_events(),
            vec![tab("T", "webkit")],
        )
        .unwrap();
        drop(app);
        let error =
            driver.call("tab.info", &json!({"targetId": "T", "timeoutMs": 2000})).unwrap_err();
        assert!(
            matches!(
                error.code,
                crate::protocol::ErrorCode::Closed | crate::protocol::ErrorCode::Ambiguous
            ),
            "{error}"
        );
    }
}
