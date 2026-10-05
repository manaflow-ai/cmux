//! Provider link tests (fake app over a socket pair).

use super::*;
use crate::provider::ProviderSecret;
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
    assert_eq!(driver.call("tab.info", &json!({"targetId": "C"})).unwrap()["method"], "tab.info");
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
    assert_eq!(driver.call("tab.info", &json!({"targetId": "C"})).unwrap()["method"], "tab.info");
    // The app withdraws the override.
    app.access(&driver, "C", true, false);
    assert_refused(driver.call("tab.info", &json!({"targetId": "C"})));
}

#[test]
fn webkit_tabs_and_tab_less_calls_need_no_access_report() {
    let (app, driver) = FakeApp::start(vec![tab("W", "webkit")]);
    assert_eq!(driver.call("tab.info", &json!({"targetId": "W"})).unwrap()["method"], "tab.info");
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
    assert_eq!(driver.call("tab.info", &json!({"targetId": "W2"})).unwrap()["method"], "tab.info");
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
    assert_eq!(driver.call("tab.info", &json!({"targetId": "C2"})).unwrap()["method"], "tab.info");
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
    assert_eq!(driver.call("tab.info", &json!({"targetId": "C"})).unwrap()["method"], "tab.info");
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
    assert_eq!(driver.call("tab.info", &json!({"targetId": "C"})).unwrap()["method"], "tab.info");
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
    let error = driver.call("tab.info", &json!({"targetId": "T", "timeoutMs": 2000})).unwrap_err();
    assert!(
        matches!(
            error.code,
            crate::protocol::ErrorCode::Closed | crate::protocol::ErrorCode::Ambiguous
        ),
        "{error}"
    );
}
