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
        input_scale: 1.0,
        touch: false,
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

/// Lawrence (2026-10-22, #24413): all agents can use all tabs by default.
/// An enabled extension with access to the page is not an access gate: the
/// call reaches the app, and the person's sign-in state is the point of
/// handing a tab over. Coordination between agents is the lease's job.
fn assert_reached(app: &FakeApp, driver: &ProviderDriver, method: &str, target: &str) {
    let result = driver.call(method, &json!({"targetId": target}));
    assert_eq!(result.expect("an agent may drive the tab")["method"], method);
    assert!(app.saw(method, target), "{method} never reached the app");
}

#[test]
fn an_extension_with_access_to_the_page_never_refuses_an_agent() {
    let (app, driver) = FakeApp::start(vec![tab("C", "cef"), tab("W", "webkit")]);
    app.access(&driver, "C", true, false);
    for method in ["tab.info", "frame.evaluate", "input.mouse", "tab.screenshot", "tabs.close"] {
        assert_reached(&app, &driver, method, "C");
    }
}

#[test]
fn cef_tabs_need_no_access_report_before_an_agent_drives_them() {
    let (app, driver) = FakeApp::start(vec![tab("C", "cef"), tab("W", "webkit")]);
    assert_reached(&app, &driver, "tab.navigate", "C");
    app.send(
        &driver,
        Frame::Event {
            name: "tab.announced".into(),
            payload: serde_json::to_value(tab("C2", "cef")).unwrap(),
        },
    );
    assert_reached(&app, &driver, "tab.info", "C2");
}

#[test]
fn webkit_tabs_and_tab_less_calls_need_no_access_report() {
    let (app, driver) = FakeApp::start(vec![tab("W", "webkit")]);
    assert_eq!(driver.call("tab.info", &json!({"targetId": "W"})).unwrap()["method"], "tab.info");
    assert_eq!(driver.call("tabs.list", &json!({})).unwrap()["method"], "tabs.list");
    assert!(app.saw("tab.info", "W"));
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
