//! The engine of a session bound to the app's provider (`cef` or `webkit`).
//!
//! The app announces its tabs (`hello`, `tab.announced`); a session lists
//! them with `tabs.list` and names one by `targetId` (the app's store tab
//! id) in every call. WebKit calls go to the app's driver as `call` frames
//! ([`ProviderDriver`]). A CEF tab gets its own [`CdpDriver`] on a
//! page-rooted relay (`cdp.attach`, `cdp` frames), shared by every session;
//! the host translates the app's tab id to the page's CDP target id and back.
//! Tab lifecycle calls (`tabs.open`, `tabs.close`, `tabs.activate`) go to the
//! app, which owns tabs. Every call that names a tab passes the provider's
//! refusal rules first (browser pages, the interim extension rule).

use crate::cdp::CdpDriver;
use crate::driver::{Driver, EventSink};
use crate::lease::{LeaseCaller, LeaseError, LeaseOp};
use crate::protocol::{DriverError, DriverEvent};
use crate::provider_link::ProviderDriver;
use serde_json::{Value, json};
use std::sync::{Arc, PoisonError};

/// The relay alias of a CEF tab's page session.
const PAGE_ALIAS: &str = "cmux-page";

/// One CEF tab's CDP driver on its relay.
pub struct CefTab {
    driver: CdpDriver,
    /// The page's CDP target id (the driver's tab id).
    cdp_id: String,
}

/// A session's view of the provider: `engine` is `cef` or `webkit`.
pub struct ProviderEngine {
    provider: Arc<ProviderDriver>,
    engine: String,
    agent_source: Arc<str>,
    subscription: u64,
    /// The session's lease identity (stamped from its connection).
    lease: LeaseCaller,
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
];

fn lease_refusal(method: &str, error: LeaseError) -> DriverError {
    let reason = match error {
        LeaseError::LeaseHeld => "another agent session holds this tab",
        LeaseError::PausedByUser => "the person used this tab; wait for them to hand it back",
        LeaseError::UserDriving => "the person is driving this tab; wait for them to hand it back",
        LeaseError::StaleAfterHandBack => "the person handed the tab back; observe it again first",
        LeaseError::StoppedByUser => "the person stopped this agent session",
        _ => "the tab's automation lease refused the call",
    };
    let mut refusal =
        DriverError::new(crate::protocol::ErrorCode::Forbidden, format!("{method}: {reason}"));
    refusal.error_name = Some(error.code().to_owned());
    refusal
}

impl ProviderEngine {
    pub fn new(
        provider: Arc<ProviderDriver>,
        engine: &str,
        agent_source: Arc<str>,
        events: EventSink,
        lease: LeaseCaller,
    ) -> Result<ProviderEngine, DriverError> {
        if let Some(reason) = provider.closed_reason() {
            return Err(DriverError::closed(reason));
        }
        let subscription = provider.subscribe(events);
        Ok(ProviderEngine {
            provider,
            engine: engine.to_owned(),
            agent_source,
            subscription,
            lease,
            ended: std::sync::atomic::AtomicBool::new(false),
        })
    }

    fn tabs_list(&self) -> Value {
        let tabs: Vec<Value> = self
            .provider
            .tab_list(Some(&self.engine))
            .into_iter()
            .map(|tab| {
                json!({
                    "targetId": tab.target_id, "engine": tab.engine, "url": tab.url,
                    "title": tab.title, "workspace": tab.workspace, "profile": tab.profile,
                    "visible": tab.visible,
                })
            })
            .collect();
        json!({ "tabs": tabs })
    }

    /// The CEF tab's driver, attaching its relay on first use (or again
    /// after the relay closed).
    fn cef_tab(&self, target_id: &str) -> Result<Arc<CefTab>, DriverError> {
        let cached = |provider: &ProviderDriver| {
            provider
                .cef_tabs
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .get(target_id)
                .filter(|tab| tab.driver.is_open())
                .cloned()
        };
        if let Some(tab) = cached(&self.provider) {
            return Ok(tab);
        }
        let _attaching = self.provider.attach_lock.lock().unwrap_or_else(PoisonError::into_inner);
        let known = self
            .provider
            .cef_tabs
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(target_id)
            .cloned();
        if let Some(tab) = known
            && tab.driver.is_open()
        {
            return Ok(tab);
        }
        let conn = self.provider.open_relay(target_id, PAGE_ALIAS)?;
        let weak = Arc::downgrade(&self.provider);
        let app_id = target_id.to_owned();
        let cdp_id = Arc::new(std::sync::OnceLock::<String>::new());
        let sink_cdp_id = cdp_id.clone();
        let events: EventSink = Arc::new(move |event: DriverEvent| {
            // The provider announces and retires tabs itself.
            if matches!(event.name.as_str(), "tab.created" | "tab.closed") {
                return;
            }
            let (Some(provider), Some(cdp)) = (weak.upgrade(), sink_cdp_id.get()) else { return };
            let mut payload = event.payload;
            rename_target(&mut payload, cdp, &app_id);
            provider.publish(DriverEvent { name: event.name, payload });
        });
        let (driver, id) = CdpDriver::attach_page(conn, self.agent_source.clone(), events)
            .inspect_err(|_| {
                self.provider.close_relay(target_id);
            })?;
        let _ = cdp_id.set(id.clone());
        let tab = Arc::new(CefTab { driver, cdp_id: id });
        let mut tabs = self.provider.cef_tabs.lock().unwrap_or_else(PoisonError::into_inner);
        // The tab went away (tab.gone) or its relay closed while attaching:
        // keep nothing, so no driver outlives its tab.
        if self.provider.tab_engine(target_id).is_none() || !tab.driver.is_open() {
            drop(tabs);
            self.provider.close_relay(target_id);
            return Err(DriverError::closed(format!("tab {target_id} went away while attaching")));
        }
        tabs.insert(target_id.to_owned(), tab.clone());
        Ok(tab)
    }

    fn call_cef(
        &self,
        method: &str,
        target_id: &str,
        params: &Value,
    ) -> Result<Value, DriverError> {
        let tab = self.cef_tab(target_id)?;
        let mut params = params.clone();
        params["targetId"] = Value::String(tab.cdp_id.clone());
        let mut result = tab.driver.call(method, &params)?;
        rename_target(&mut result, &tab.cdp_id, target_id);
        Ok(result)
    }
}

/// Replaces `"targetId": from` (at any depth) with `to`.
fn rename_target(value: &mut Value, from: &str, to: &str) {
    match value {
        Value::Object(map) => {
            for (key, item) in map.iter_mut() {
                if key.ends_with("argetId") && item.as_str() == Some(from) {
                    *item = Value::String(to.to_owned());
                } else {
                    rename_target(item, from, to);
                }
            }
        }
        Value::Array(items) => items.iter_mut().for_each(|item| rename_target(item, from, to)),
        _ => {}
    }
}

impl Driver for ProviderEngine {
    fn call(&self, method: &str, params: &Value) -> Result<Value, DriverError> {
        // A closed session's engine can outlive the close (a timed-out cell
        // still runs); it must not take a lease nobody will end.
        if self.ended.load(std::sync::atomic::Ordering::SeqCst) {
            return Err(DriverError::closed("the session was closed"));
        }
        if let Some(reason) = self.provider.closed_reason() {
            return Err(DriverError::closed(reason));
        }
        match method {
            "tabs.list" => return Ok(self.tabs_list()),
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
                return self.provider.call(method, &Value::Object(open));
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
        // A structured read: refused before the lease sees it unless it
        // calls an allowlisted page agent function.
        let observe = match method {
            "frame.observe" => Some(crate::observe::evaluate_params(params)?),
            _ => None,
        };
        // The automation lease: reads pass, any other call acts (and takes
        // the lease when the tab has none).
        let target = target_id.to_owned();
        let op = if OBSERVE_METHODS.contains(&method) {
            LeaseOp::Observe { target }
        } else {
            LeaseOp::Act { target }
        };
        self.provider.lease(&op, &self.lease).map_err(|error| lease_refusal(method, error))?;
        if engine == "cef" && !matches!(method, "tabs.close" | "tabs.activate") {
            self.call_cef(method, target_id, params)
        } else if let Some(evaluate) = observe {
            // The app's WebKit driver runs it as its agent-world evaluate.
            self.provider.call("frame.evaluate", &evaluate)
        } else {
            self.provider.call(method, params)
        }
    }

    fn end_session(&self) {
        self.release_session();
    }

    fn capabilities(&self) -> Vec<&'static str> {
        if self.engine == "cef" { vec!["cdp"] } else { self.provider.capabilities() }
    }
}

impl ProviderEngine {
    /// The session ends: its leases go (the app clears the badges). Runs
    /// once, from `end_session` (close) or, as a backstop, from drop.
    fn release_session(&self) {
        if !self.ended.swap(true, std::sync::atomic::Ordering::SeqCst) {
            let _ = self.provider.lease(&LeaseOp::SessionEnd, &self.lease);
        }
    }
}

impl Drop for ProviderEngine {
    fn drop(&mut self) {
        self.provider.unsubscribe(self.subscription);
        self.release_session();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::provider::{Frame, TabAnnounce, read_frame, write_frame};
    use std::os::unix::net::UnixStream;
    use std::sync::Mutex;

    pub(super) fn tab(target_id: &str, engine: &str) -> TabAnnounce {
        TabAnnounce {
            target_id: target_id.into(),
            engine: engine.into(),
            workspace: "w".into(),
            profile: "p".into(),
            url: "https://a.test/".into(),
            title: "A".into(),
            visible: true,
        }
    }

    /// The app side: answers WebKit `call` frames, and plays one page per
    /// attached CEF tab on its `cdp` frames (page-level messages carry no
    /// sessionId). Records every frame it got.
    pub(super) struct FakeApp {
        writer: Arc<Mutex<UnixStream>>,
        pub(super) frames: Arc<Mutex<Vec<Frame>>>,
    }

    impl FakeApp {
        pub(super) fn start(tabs: Vec<TabAnnounce>) -> (FakeApp, Arc<ProviderDriver>) {
            let (app, host) = UnixStream::pair().unwrap();
            let provider = ProviderDriver::start(
                host.try_clone().unwrap(),
                host,
                crate::driver::discard_events(),
                tabs,
            )
            .unwrap();
            let writer = Arc::new(Mutex::new(app.try_clone().unwrap()));
            let frames = Arc::new(Mutex::new(Vec::new()));
            let (thread_writer, thread_frames) = (writer.clone(), frames.clone());
            let mut reader = app;
            std::thread::spawn(move || {
                while let Ok(Some(frame)) = read_frame(&mut reader) {
                    thread_frames.lock().unwrap().push(frame.clone());
                    let reply = match frame {
                        Frame::Call { id, method, .. } => Some(Frame::Result {
                            id,
                            result: Some(json!({"method": method})),
                            error: None,
                        }),
                        Frame::Cdp { target_id, message } => {
                            let message: Value = serde_json::from_str(&message).unwrap();
                            let result = match message["method"].as_str().unwrap_or("") {
                                "Target.getTargetInfo" => json!({"targetInfo": {
                                    "targetId": format!("CDP-{target_id}"), "type": "page",
                                    "url": "https://a.test/", "title": "A", "attached": true}}),
                                "Page.getFrameTree" => json!({"frameTree": {"frame": {
                                    "id": format!("CDP-{target_id}"), "loaderId": "L1",
                                    "url": "https://a.test/"}}}),
                                _ => json!({}),
                            };
                            let mut reply = json!({"id": message["id"], "result": result});
                            if let Some(session) = message.get("sessionId") {
                                reply["sessionId"] = session.clone();
                            }
                            Some(Frame::Cdp { target_id, message: reply.to_string() })
                        }
                        _ => None,
                    };
                    if let Some(reply) = reply
                        && write_frame(&mut *thread_writer.lock().unwrap(), &reply).is_err()
                    {
                        break;
                    }
                }
            });
            (FakeApp { writer, frames }, provider)
        }

        pub(super) fn send(&self, frame: Frame) {
            write_frame(&mut *self.writer.lock().unwrap(), &frame).unwrap();
        }

        pub(super) fn access(&self, provider: &ProviderDriver, target: &str) {
            self.send(Frame::TabAccess {
                target_id: target.into(),
                extension_host_access: false,
                user_override: false,
                extensions: Vec::new(),
            });
            // A round trip on a WebKit tab: the access frame was read first.
            provider.call("tab.info", &json!({"targetId": "W"})).unwrap();
        }

        fn attaches(&self, target: &str) -> usize {
            self.frames
                .lock()
                .unwrap()
                .iter()
                .filter(|f| matches!(f, Frame::CdpAttach { target_id } if target_id == target))
                .count()
        }

        fn cdp_messages(&self, target: &str) -> Vec<Value> {
            self.frames
                .lock()
                .unwrap()
                .iter()
                .filter_map(|f| match f {
                    Frame::Cdp { target_id, message } if target_id == target => {
                        serde_json::from_str(message).ok()
                    }
                    _ => None,
                })
                .collect()
        }
    }

    fn engine(provider: &Arc<ProviderDriver>, kind: &str) -> ProviderEngine {
        session(provider, kind, "s1")
    }

    pub(super) fn session(
        provider: &Arc<ProviderDriver>,
        kind: &str,
        name: &str,
    ) -> ProviderEngine {
        let lease = LeaseCaller {
            session: name.into(),
            actor: "uid:501".into(),
            on_behalf_of: None,
            origin: "mcp".into(),
            label: "task".into(),
        };
        ProviderEngine::new(
            provider.clone(),
            kind,
            Arc::from("/* agent */"),
            crate::driver::discard_events(),
            lease,
        )
        .unwrap()
    }

    pub(super) fn leases(app: &FakeApp, target: &str) -> Vec<Option<crate::provider::Lease>> {
        app.frames
            .lock()
            .unwrap()
            .iter()
            .filter_map(|f| match f {
                Frame::Lease { target_id, lease } if target_id == target => Some(lease.clone()),
                _ => None,
            })
            .collect()
    }

    /// The host's lease state machine drives the badge: an act takes the
    /// lease, a person's input pauses it, another session is refused, the
    /// person's hand back needs a fresh observe, and session end clears it.
    #[test]
    fn provider_calls_follow_the_automation_lease() {
        use crate::provider::LeaseState;
        let (app, provider) = FakeApp::start(vec![tab("W", "webkit")]);
        let first = session(&provider, "webkit", "s1");
        first.call("tab.info", &json!({"targetId": "W"})).unwrap();
        assert!(leases(&app, "W").is_empty(), "a read takes no lease");
        first.call("tab.navigate", &json!({"targetId": "W", "url": "https://b.test/"})).unwrap();
        assert_eq!(leases(&app, "W").last().unwrap().as_ref().unwrap().state, LeaseState::Driving);
        let second = session(&provider, "webkit", "s2");
        let held = second.call("input.key", &json!({"targetId": "W"})).unwrap_err();
        assert_eq!(held.error_name.as_deref(), Some("lease_held"), "{held}");
        app.send(Frame::UserInput { target_id: "W".into() });
        provider.call("tab.info", &json!({"targetId": "W"})).unwrap();
        assert_eq!(leases(&app, "W").last().unwrap().as_ref().unwrap().state, LeaseState::Paused);
        let paused = first.call("input.key", &json!({"targetId": "W"})).unwrap_err();
        assert_eq!(paused.error_name.as_deref(), Some("paused_by_user"), "{paused}");
        app.send(Frame::LeaseUser {
            op: "hand_back".into(),
            target_id: Some("W".into()),
            session: None,
        });
        provider.call("tab.info", &json!({"targetId": "W"})).unwrap();
        let stale = first.call("input.key", &json!({"targetId": "W"})).unwrap_err();
        assert_eq!(stale.error_name.as_deref(), Some("stale_after_hand_back"), "{stale}");
        first.call("tab.info", &json!({"targetId": "W"})).unwrap();
        first.call("input.key", &json!({"targetId": "W"})).unwrap();
        drop(first);
        second.call("tab.info", &json!({"targetId": "W"})).unwrap();
        assert_eq!(leases(&app, "W").last().unwrap(), &None, "session end clears the badge");
    }

    #[test]
    fn a_cef_tab_is_driven_through_its_relay_under_the_app_tab_id() {
        let (app, provider) = FakeApp::start(vec![tab("W", "webkit"), tab("C", "cef")]);
        app.access(&provider, "C");
        let cef = engine(&provider, "cef");
        let info = cef.call("tab.info", &json!({"targetId": "C", "timeoutMs": 5000})).unwrap();
        assert_eq!(info["url"], "https://a.test/", "{info}");
        // Results name the app's tab, never the page's CDP target id.
        assert!(!info.to_string().contains("CDP-C"), "{info}");
        assert_eq!(app.attaches("C"), 1);
        let sent = app.cdp_messages("C");
        assert_eq!(sent[0]["method"], "Target.getTargetInfo");
        // The page's own messages carry no session on the wire.
        assert!(sent.iter().all(|m| m.get("sessionId").is_none()), "{sent:?}");
        assert!(sent.iter().any(|m| m["method"] == "Page.enable"));
        // A second session shares the tab's relay.
        let other = engine(&provider, "cef");
        other.call("tab.info", &json!({"targetId": "C", "timeoutMs": 5000})).unwrap();
        assert_eq!(app.attaches("C"), 1);
    }

    #[test]
    fn sessions_list_their_engine_tabs_and_webkit_calls_go_to_the_app() {
        let (app, provider) = FakeApp::start(vec![tab("W", "webkit"), tab("C", "cef")]);
        let webkit = engine(&provider, "webkit");
        let tabs = webkit.call("tabs.list", &json!({})).unwrap();
        assert_eq!(tabs["tabs"].as_array().unwrap().len(), 1);
        assert_eq!(tabs["tabs"][0]["targetId"], "W");
        assert_eq!(
            webkit.call("tab.info", &json!({"targetId": "W"})).unwrap()["method"],
            "tab.info"
        );
        assert_eq!(app.attaches("W"), 0);
        let cef = engine(&provider, "cef");
        assert_eq!(cef.call("tabs.list", &json!({})).unwrap()["tabs"][0]["targetId"], "C");
    }

    #[test]
    fn a_refused_tab_never_opens_a_relay() {
        let (app, provider) = FakeApp::start(vec![tab("W", "webkit"), tab("C", "cef")]);
        let cef = engine(&provider, "cef");
        // No tab.access report yet: refused, and the app saw no cdp.attach.
        let error = cef.call("tab.info", &json!({"targetId": "C"})).unwrap_err();
        assert_eq!(error.error_name.as_deref(), Some("extension_host_access"), "{error}");
        assert_eq!(app.attaches("C"), 0);
        let missing = cef.call("tab.info", &json!({"targetId": "X"})).unwrap_err();
        assert_eq!(missing.code, crate::protocol::ErrorCode::NotFound, "{missing}");
    }

    #[test]
    fn a_closed_relay_attaches_again_and_a_gone_tab_is_not_found() {
        let (app, provider) = FakeApp::start(vec![tab("W", "webkit"), tab("C", "cef")]);
        app.access(&provider, "C");
        let cef = engine(&provider, "cef");
        cef.call("tab.info", &json!({"targetId": "C", "timeoutMs": 5000})).unwrap();
        // The app replaced the tab's browser: the next call attaches again.
        app.send(Frame::Event {
            name: "tab.relay.closed".into(),
            payload: json!({"targetId": "C"}),
        });
        provider.call("tab.info", &json!({"targetId": "W"})).unwrap();
        cef.call("tab.info", &json!({"targetId": "C", "timeoutMs": 5000})).unwrap();
        assert_eq!(app.attaches("C"), 2);
        app.send(Frame::Event { name: "tab.gone".into(), payload: json!({"targetId": "C"}) });
        provider.call("tab.info", &json!({"targetId": "W"})).unwrap();
        let gone = cef.call("tab.info", &json!({"targetId": "C"})).unwrap_err();
        assert_eq!(gone.code, crate::protocol::ErrorCode::NotFound, "{gone}");
    }

    pub(super) fn calls(app: &FakeApp, method: &str) -> usize {
        app.frames
            .lock()
            .unwrap()
            .iter()
            .filter(|f| matches!(f, Frame::Call { method: m, .. } if m == method))
            .count()
    }

    /// Review P0: tab-less calls (cookies of the person's profile) never
    /// reach the app; a session drives only its own engine's tabs.
    #[test]
    fn tab_less_calls_and_other_engine_tabs_are_refused() {
        let (app, provider) = FakeApp::start(vec![tab("W", "webkit"), tab("C", "cef")]);
        app.access(&provider, "C");
        let webkit = engine(&provider, "webkit");
        for method in ["cookies.get", "cookies.set", "cookies.clear", "cdp"] {
            let error = webkit.call(method, &json!({})).unwrap_err();
            assert_eq!(error.code, crate::protocol::ErrorCode::Unsupported, "{method}: {error}");
            assert_eq!(calls(&app, method), 0, "{method} reached the app");
        }
        let bad = webkit.call("tab.info", &json!({"targetId": 7})).unwrap_err();
        assert_eq!(bad.code, crate::protocol::ErrorCode::Invalid, "{bad}");
        let other = webkit.call("tab.info", &json!({"targetId": "C"})).unwrap_err();
        assert_eq!(other.code, crate::protocol::ErrorCode::NotFound, "{other}");
        assert_eq!(app.attaches("C"), 0);
    }

    /// Review P1: raw CDP on a relayed tab cannot reach Target, Browser or
    /// Storage (another tab, the browser target, the profile's cookies).
    #[test]
    fn raw_cdp_on_a_relayed_tab_cannot_leave_the_page() {
        let (app, provider) = FakeApp::start(vec![tab("W", "webkit"), tab("C", "cef")]);
        app.access(&provider, "C");
        let cef = engine(&provider, "cef");
        for method in [
            "Target.attachToTarget",
            "Target.attachToBrowserTarget",
            "Target.createTarget",
            "Storage.getCookies",
            "Browser.close",
        ] {
            let error = cef
                .call(
                    "cdp",
                    &json!({"targetId": "C", "method": method, "params": {}, "timeoutMs": 5000}),
                )
                .unwrap_err();
            assert_eq!(error.code, crate::protocol::ErrorCode::Forbidden, "{method}: {error}");
            assert!(
                app.cdp_messages("C").iter().all(|m| m["method"] != method),
                "{method} went out"
            );
        }
    }

    /// A tab that navigates to a browser page after its relay opened is refused.
    #[test]
    fn a_relayed_tab_that_shows_a_browser_page_is_refused() {
        let (app, provider) = FakeApp::start(vec![tab("W", "webkit"), tab("C", "cef")]);
        app.access(&provider, "C");
        let cef = engine(&provider, "cef");
        cef.call("tab.info", &json!({"targetId": "C", "timeoutMs": 5000})).unwrap();
        app.send(Frame::Event {
            name: "tab.navigated".into(),
            payload: json!({"targetId": "C", "url": "chrome://settings/"}),
        });
        provider.call("tab.info", &json!({"targetId": "W"})).unwrap();
        let error = cef.call("tab.info", &json!({"targetId": "C"})).unwrap_err();
        assert_eq!(
            error.error_name.as_deref(),
            Some(crate::provider_link::BROWSER_PAGE),
            "{error}"
        );
    }

    /// Review P1: a domain policy the provider cannot enforce on the page's
    /// own requests makes every call fail closed.
    #[test]
    fn a_policy_on_a_provider_session_fails_closed() {
        use crate::gate::{Gate, Grants};
        use crate::policy::{DomainPattern, Layer};
        use crate::vm::VmHost;
        let (app, provider) = FakeApp::start(vec![tab("W", "webkit")]);
        let gate = Gate::new(Arc::new(engine(&provider, "webkit")), Grants::default());
        gate.driver_call("tab.info", json!({"targetId": "W"})).unwrap();
        let layer = Layer {
            allowed: Some(vec![DomainPattern::parse("a.test").unwrap()]),
            prohibited: Vec::new(),
            block_ips: false,
        };
        gate.set_owner_policy(layer, false).unwrap();
        let before = calls(&app, "tab.info");
        let error = gate.driver_call("tab.info", json!({"targetId": "W"})).unwrap_err();
        assert_eq!(error.code, crate::protocol::ErrorCode::Forbidden, "{error}");
        assert_eq!(calls(&app, "tab.info"), before);
    }

    /// Review P1: tabs.open passes only url and background; the app picks
    /// the profile and workspace.
    #[test]
    fn tabs_open_drops_agent_chosen_profile_and_workspace() {
        let (app, provider) = FakeApp::start(vec![tab("W", "webkit")]);
        let cef = engine(&provider, "cef");
        cef.call(
            "tabs.open",
            &json!({"url": "https://b.test/", "profile": "signed-in", "workspace": "w2", "focus": true}),
        )
        .unwrap();
        let frames = app.frames.lock().unwrap();
        let open = frames
            .iter()
            .find_map(|f| match f {
                Frame::Call { method, params, .. } if method == "tabs.open" => Some(params.clone()),
                _ => None,
            })
            .unwrap();
        assert_eq!(open, json!({"url": "https://b.test/", "engine": "cef"}));
    }

    #[test]
    fn tabs_open_goes_to_the_app_with_the_session_engine() {
        let (app, provider) = FakeApp::start(vec![tab("W", "webkit")]);
        let cef = engine(&provider, "cef");
        cef.call("tabs.open", &json!({"url": "https://b.test/"})).unwrap();
        let frames = app.frames.lock().unwrap();
        let open = frames
            .iter()
            .find_map(|f| match f {
                Frame::Call { method, params, .. } if method == "tabs.open" => Some(params.clone()),
                _ => None,
            })
            .unwrap();
        assert_eq!(open["engine"], "cef");
    }
}

#[cfg(test)]
#[path = "provider_engine_lease_tests.rs"]
mod lease_tests;
