//! The host side of the app's provider connection (step c).
//!
//! The app dials the host and authenticates with the per-launch provider
//! secret in `hello`; the host answers `hello.ack` with the page agent
//! bundle. After that, [`ProviderDriver`] forwards driver protocol calls on
//! the provider's WebKit tabs and receives their results and events.

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

const EXTENSION_REFUSAL: &str = "the tab's profile has an enabled extension with access to this \
     page; use a browser profile without extensions, or ask the person to allow agents in this tab";
const EXTENSION_REFUSAL_HINT: &str =
    "use a browser profile without extensions, or ask the person to allow agents in this tab";

/// The provider's tabs as the app reports them: engine per tab, and for CEF
/// tabs the last `tab.access` report (interim extension rule).
#[derive(Default)]
struct TabTable {
    engines: HashMap<String, String>,
    /// targetId -> (extension_host_access, user_override, extension names).
    access: HashMap<String, (bool, bool, Vec<String>)>,
}

impl TabTable {
    fn announce(&mut self, tab: &TabAnnounce) {
        self.engines.insert(tab.target_id.clone(), tab.engine.clone());
    }

    fn forget(&mut self, target_id: &str) {
        self.engines.remove(target_id);
        self.access.remove(target_id);
    }

    /// Updates the table from a provider event (`tab.announced`, `tab.gone`).
    fn apply_event(&mut self, name: &str, payload: &Value) {
        match name {
            "tab.announced" => {
                if let Ok(tab) = serde_json::from_value::<TabAnnounce>(payload.clone()) {
                    self.announce(&tab);
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
        if self.engines.get(target_id).map(String::as_str) == Some("webkit") {
            return None;
        }
        // The text the coordinator fixed (2026-10-04); extension names follow.
        let message = match self.access.get(target_id) {
            Some((false, _, _) | (true, true, _)) => return None,
            Some((true, false, names)) if !names.is_empty() => {
                format!("{method}: {EXTENSION_REFUSAL} (extensions: {})", names.join(", "))
            }
            Some((true, false, _)) => format!("{method}: {EXTENSION_REFUSAL}"),
            None => format!(
                "{method}: the cmux app has not reported this tab's extension access yet; {EXTENSION_REFUSAL_HINT}"
            ),
        };
        let mut error = DriverError::new(crate::protocol::ErrorCode::Forbidden, message);
        error.error_name = Some(EXTENSION_HOST_ACCESS.to_owned());
        Some(error)
    }
}

/// Driver protocol calls forwarded to the app's driver for provider tabs.
/// Calls on a CEF tab follow the interim extension rule (`tab.access`).
pub struct ProviderDriver {
    writer: Mutex<Box<dyn Write + Send>>,
    waiters: Waiters,
    next_id: AtomicU64,
    closed: Arc<Mutex<Option<String>>>,
    tabs: Arc<Mutex<TabTable>>,
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
        let (thread_waiters, thread_closed, thread_tabs) =
            (waiters.clone(), closed.clone(), tabs.clone());
        std::thread::Builder::new().name("cmux-browser-host-provider".into()).spawn(move || {
            let reason = loop {
                match read_frame(&mut reader) {
                    Ok(Some(Frame::Event { name, payload })) => {
                        thread_tabs
                            .lock()
                            .unwrap_or_else(PoisonError::into_inner)
                            .apply_event(&name, &payload);
                        events(DriverEvent { name, payload });
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
            for (_, waiter) in thread_waiters.lock().unwrap_or_else(PoisonError::into_inner).drain()
            {
                let _ = waiter.try_send(Err(DriverError::closed(reason.clone())));
            }
        })?;
        Ok(Arc::new(ProviderDriver {
            writer: Mutex::new(Box::new(writer)),
            waiters,
            next_id: AtomicU64::new(1),
            closed,
            tabs,
        }))
    }

    fn closed_reason(&self) -> Option<String> {
        self.closed.lock().unwrap_or_else(PoisonError::into_inner).clone()
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

    fn assert_refused(result: Result<Value, DriverError>) {
        let error = result.expect_err("the call must be refused");
        assert_eq!(error.code, crate::protocol::ErrorCode::Forbidden, "{error}");
        assert_eq!(error.error_name.as_deref(), Some("extension_host_access"), "{error}");
        assert!(error.message.contains("ask the person to allow agents in this tab"), "{error}");
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
        let named = driver.call("tab.info", &json!({"targetId": "C"})).unwrap_err();
        assert!(named.message.contains("Pass Keeper"), "{named}");
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
