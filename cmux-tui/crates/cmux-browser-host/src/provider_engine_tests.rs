//! Tests and the fake app for the provider engine (split out of
//! provider_engine.rs, which the god-file budget limits).

use super::*;
use crate::provider::{Frame, TabAnnounce, read_frame, write_frame};
use crate::provider_source::rename_target;
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
                    Frame::Call { id, params, .. } if params["failForTest"] == true => {
                        Some(Frame::Result {
                            id,
                            result: None,
                            error: Some(DriverError::invalid("the app failed the call")),
                        })
                    }
                    // tabs.open answers the tab named by the URL's last
                    // path segment (tests announce it up front).
                    Frame::Call { id, method, params } if method == "tabs.open" => {
                        let url = params["url"].as_str().unwrap_or("");
                        let target = url.rsplit('/').next().unwrap_or("").to_owned();
                        Some(Frame::Result {
                            id,
                            result: Some(json!({"method": method, "targetId": target})),
                            error: None,
                        })
                    }
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

pub(super) fn session(provider: &Arc<ProviderDriver>, kind: &str, name: &str) -> ProviderEngine {
    let lease = LeaseCaller {
        session: name.into(),
        actor: "uid:501".into(),
        on_behalf_of: None,
        origin: "mcp".into(),
        label: "task".into(),
        ..LeaseCaller::default()
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

/// Waits (bounded, no sleep) until the last lease frame the app recorded
/// for `target` matches: frames the host's reader thread writes can
/// reach the app after the reply to a barrier call.
pub(super) fn wait_for_lease(
    app: &FakeApp,
    target: &str,
    what: &str,
    matches: impl Fn(&Option<crate::provider::Lease>) -> bool,
) {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    loop {
        let seen = leases(app, target);
        if seen.last().is_some_and(&matches) {
            return;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "the app never recorded the lease {what} for {target} within 5 s: {seen:?}"
        );
        std::thread::yield_now();
    }
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
    // The host's reader writes this lease frame; the app may record it
    // after the barrier call's reply, so wait for it.
    wait_for_lease(&app, "W", "Paused", |lease| {
        lease.as_ref().is_some_and(|lease| lease.state == LeaseState::Paused)
    });
    let paused = first.call("input.key", &json!({"targetId": "W"})).unwrap_err();
    assert_eq!(paused.error_name.as_deref(), Some("paused_by_user"), "{paused}");
    app.send(Frame::LeaseUser { op: "hand_back".into(), target_id: Some("W".into()), actor: None });
    provider.call("tab.info", &json!({"targetId": "W"})).unwrap();
    let stale = first.call("input.key", &json!({"targetId": "W"})).unwrap_err();
    assert_eq!(stale.error_name.as_deref(), Some("stale_after_hand_back"), "{stale}");
    first.call("tab.info", &json!({"targetId": "W"})).unwrap();
    first.call("input.key", &json!({"targetId": "W"})).unwrap();
    drop(first);
    second.call("tab.info", &json!({"targetId": "W"})).unwrap();
    wait_for_lease(&app, "W", "cleared at session end", Option::is_none);
}

#[test]
fn request_filters_apply_per_app_tab_on_cef_relays() {
    let (app, provider) =
        FakeApp::start(vec![tab("C", "cef"), tab("D", "cef"), tab("W", "webkit")]);
    app.access(&provider, "C");
    app.access(&provider, "D");
    let a = session(&provider, "cef", "a");
    let b = session(&provider, "cef", "b");
    let seen = Arc::new(Mutex::new(Vec::<String>::new()));
    let record = seen.clone();
    let filter: crate::driver::RequestFilter = Arc::new(move |request| {
        let (target, url) = (request.target, request.url);
        record.lock().unwrap().push(target.to_owned());
        url.contains("evil.test").then(|| "prohibited by evil.test".to_owned())
    });
    assert!(a.set_request_filter(Some(filter)), "CEF relays enforce a session's filter");
    a.call("tab.info", &json!({"targetId": "C", "timeoutMs": 5000})).unwrap();
    b.call("tab.info", &json!({"targetId": "D", "timeoutMs": 5000})).unwrap();
    // Session a's policy applies to the tab it drives, not to b's.
    assert!(app.cdp_messages("C").iter().any(|m| m["method"] == "Fetch.enable"));
    assert!(!app.cdp_messages("D").iter().any(|m| m["method"] == "Fetch.enable"));
    app.send(Frame::Cdp {
        target_id: "C".into(),
        message: json!({"method": "Fetch.requestPaused", "params": {"requestId": "r1", "request": {"url": "https://evil.test/x"}}}).to_string(),
    });
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    while !app
        .cdp_messages("C")
        .iter()
        .any(|m| m["method"] == "Fetch.failRequest" && m["params"]["requestId"] == "r1")
    {
        assert!(
            std::time::Instant::now() < deadline,
            "the request was not blocked: {:?}",
            app.cdp_messages("C")
        );
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    // The filter is keyed by the app's tab id, never the page's CDP id.
    assert_eq!(*seen.lock().unwrap(), vec!["C".to_owned()]);
    // The session's end removes its filter from the tab.
    drop(a);
    let _ = b.call("tab.info", &json!({"targetId": "D", "timeoutMs": 5000}));
    assert!(app.cdp_messages("C").iter().any(|m| m["method"] == "Fetch.disable"));
    // WebKit tabs cannot take a filter yet: the gate fails closed.
    let w = session(&provider, "webkit", "w");
    assert!(!w.set_request_filter(Some(Arc::new(|_| None))));
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

/// One `tabs.list` shape for every source (driver-protocol.md): the
/// headless source checks the same contract in tests/chromium.rs.
#[test]
fn provider_tabs_list_has_the_protocol_shape() {
    let (_app, provider) = FakeApp::start(vec![tab("W", "webkit"), tab("C", "cef")]);
    for kind in ["webkit", "cef"] {
        let tabs = engine(&provider, kind).call("tabs.list", &json!({})).unwrap();
        crate::tab_source::check_tabs_list_shape(&tabs).unwrap();
        assert_eq!(tabs.as_array().map(Vec::len), Some(1), "{tabs}");
    }
}

#[test]
fn sessions_list_their_engine_tabs_and_webkit_calls_go_to_the_app() {
    let (app, provider) = FakeApp::start(vec![tab("W", "webkit"), tab("C", "cef")]);
    let webkit = engine(&provider, "webkit");
    let tabs = webkit.call("tabs.list", &json!({})).unwrap();
    assert_eq!(tabs.as_array().unwrap().len(), 1);
    assert_eq!(tabs[0]["targetId"], "W");
    assert_eq!(webkit.call("tab.info", &json!({"targetId": "W"})).unwrap()["method"], "tab.info");
    assert_eq!(app.attaches("W"), 0);
    let cef = engine(&provider, "cef");
    assert_eq!(cef.call("tabs.list", &json!({})).unwrap()[0]["targetId"], "C");
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
    app.send(Frame::Event { name: "tab.relay.closed".into(), payload: json!({"targetId": "C"}) });
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
        assert!(app.cdp_messages("C").iter().all(|m| m["method"] != method), "{method} went out");
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
    assert_eq!(error.error_name.as_deref(), Some(crate::provider_link::BROWSER_PAGE), "{error}");
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

/// A CEF tab's automation.input names the tab as the app knows it, so
/// the app routes the agent cursor (snake_case `target_id` too).
#[test]
fn cef_input_events_name_the_app_tab() {
    let mut payload = json!({"session_id": "s1", "target_id": "CDP1",
        "nested": {"targetId": "CDP1"}, "other": "CDP1"});
    rename_target(&mut payload, "CDP1", "c1");
    assert_eq!(
        payload,
        json!({"session_id": "s1", "target_id": "c1", "nested": {"targetId": "c1"}, "other": "CDP1"})
    );
}

/// The policy log entry of an unrouted event (item 4c D2 log) comes only
/// from the host's own source hook: an app event with that name never
/// reaches the session, so no page or app writes a session's policy log.
#[test]
fn a_source_event_cannot_write_the_policy_log() {
    let (app, provider) = FakeApp::start(vec![tab("W", "webkit")]);
    let seen: Arc<Mutex<Vec<String>>> = Arc::default();
    let sink_seen = seen.clone();
    let lease =
        LeaseCaller { session: "s1".into(), origin: "mcp".into(), ..LeaseCaller::default() };
    let _engine = ProviderEngine::new(
        provider,
        "webkit",
        Arc::from("/* agent */"),
        Arc::new(move |event: DriverEvent| sink_seen.lock().unwrap().push(event.name)),
        lease,
    )
    .unwrap();
    app.send(Frame::Event {
        name: "host.policyLog".into(),
        payload: json!({"targetId": "W", "reason": "forged"}),
    });
    // Events arrive in order: once the barrier is here, the forged one was handled.
    app.send(Frame::Event {
        name: "tab.navigated".into(),
        payload: json!({"targetId": "W", "url": "https://a.test/next"}),
    });
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    while !seen.lock().unwrap().iter().any(|name| name == "tab.navigated") {
        assert!(
            std::time::Instant::now() < deadline,
            "no barrier event: {:?}",
            seen.lock().unwrap()
        );
        std::thread::yield_now();
    }
    assert!(
        !seen.lock().unwrap().iter().any(|name| name == "host.policyLog"),
        "{:?}",
        seen.lock().unwrap()
    );
}
