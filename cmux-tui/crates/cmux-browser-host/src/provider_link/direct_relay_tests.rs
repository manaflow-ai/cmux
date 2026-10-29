//! Direct relay tests: a fake app and a fake Chromium Host, each on a
//! socket pair with the provider.

use super::*;
use crate::provider::{Frame, ProviderSecret, TabAnnounce};
use serde_json::json;
use std::os::unix::net::UnixStream;
use std::sync::mpsc::Receiver;
use std::time::Duration;

const WAIT: Duration = Duration::from_secs(5);

fn cef_tab(target_id: &str) -> TabAnnounce {
    TabAnnounce {
        target_id: target_id.into(),
        engine: "cef".into(),
        workspace: "w".into(),
        profile: "p".into(),
        url: "https://a.test/".into(),
        title: String::new(),
        visible: false,
        input_scale: 1.0,
        touch: false,
    }
}

/// How the fake app answers `cdp.prepare`.
#[derive(Clone, Copy)]
enum Prepare {
    /// `tab.relay.direct` naming browser 7 of the Chromium Host the app gave `link`.
    Direct {
        link: &'static str,
    },
    Fail,
}

/// The app: records every frame, answers `cdp.prepare`, and plays the page
/// for `cdp` frames it gets (a relay that fell back to it).
struct FakeApp {
    frames: Arc<Mutex<Vec<Frame>>>,
    /// The app's end of its connection (a kill ends it).
    stream: UnixStream,
}

impl FakeApp {
    fn start(prepare: Prepare) -> (FakeApp, Arc<ProviderDriver>) {
        let (app, host) = UnixStream::pair().unwrap();
        let provider = ProviderDriver::start(
            host.try_clone().unwrap(),
            host,
            crate::driver::discard_events(),
            vec![cef_tab("C")],
        )
        .unwrap();
        let frames = Arc::new(Mutex::new(Vec::new()));
        let thread_frames = frames.clone();
        let mut writer = app.try_clone().unwrap();
        let stream = app.try_clone().unwrap();
        let mut reader = app;
        std::thread::spawn(move || {
            while let Ok(Some(frame)) = read_frame(&mut reader) {
                thread_frames.lock().unwrap().push(frame.clone());
                let reply = match frame {
                    Frame::CdpPrepare { target_id } => Some(match prepare {
                        Prepare::Direct { link } => Frame::Event {
                            name: "tab.relay.direct".into(),
                            payload: json!({"targetId": target_id, "browser": 7, "link": link}),
                        },
                        Prepare::Fail => Frame::Event {
                            name: "tab.relay.failed".into(),
                            payload: json!({"targetId": target_id, "reason": "the page did not start"}),
                        },
                    }),
                    Frame::Cdp { target_id, message } => {
                        Some(Frame::Cdp { target_id, message: page_reply(&message, "app") })
                    }
                    _ => None,
                };
                if let Some(reply) = reply
                    && write_frame(&mut writer, &reply).is_err()
                {
                    break;
                }
            }
        });
        (FakeApp { frames, stream }, provider)
    }

    fn frames(&self) -> Vec<Frame> {
        self.frames.lock().unwrap().clone()
    }

    fn cdp_count(&self) -> usize {
        self.frames().iter().filter(|frame| matches!(frame, Frame::Cdp { .. })).count()
    }
}

/// The page's answer to a command: `{"id", "result": {"via": via}}`.
fn page_reply(message: &str, via: &str) -> String {
    let id = reply_id(message).expect("a command with an id");
    json!({"id": id, "result": {"via": via}}).to_string()
}

/// The Chromium Host: its relay link, answering each `cdp` frame as the
/// page, and reporting the frames it got.
struct FakeHost {
    frames: Receiver<Frame>,
    stream: UnixStream,
}

impl FakeHost {
    fn link(provider: &ProviderDriver, link: &str) -> FakeHost {
        let (host_end, provider_end) = UnixStream::pair().unwrap();
        let shutdown_end = provider_end.try_clone().unwrap();
        provider
            .attach_relay_link(
                provider_end.try_clone().unwrap(),
                provider_end,
                link.to_owned(),
                Box::new(move || {
                    let _ = shutdown_end.shutdown(std::net::Shutdown::Both);
                }),
            )
            .unwrap();
        let (tx, rx) = mpsc::channel();
        let mut reader = host_end.try_clone().unwrap();
        let mut writer = host_end.try_clone().unwrap();
        std::thread::spawn(move || {
            while let Ok(Some(frame)) = read_frame(&mut reader) {
                if let Frame::Cdp { target_id, message } = &frame {
                    let reply = Frame::Cdp {
                        target_id: target_id.clone(),
                        message: page_reply(message, "host"),
                    };
                    if write_frame(&mut writer, &reply).is_err() {
                        break;
                    }
                }
                if tx.send(frame).is_err() {
                    break;
                }
            }
        });
        FakeHost { frames: rx, stream: host_end }
    }

    fn next(&self) -> Frame {
        self.frames.recv_timeout(WAIT).expect("a frame from the provider")
    }
}

fn evaluate(conn: &CdpConnection) -> Result<Value, DriverError> {
    conn.call(Some("page"), "Runtime.evaluate", json!({"expression": "1"}), WAIT)
}

#[test]
fn a_linked_chromium_host_relays_cef_tabs_without_the_app() {
    let (app, provider) = FakeApp::start(Prepare::Direct { link: "L1" });
    let host = FakeHost::link(&provider, "L1");
    assert!(matches!(host.next(), Frame::RelayHelloAck {}));
    let conn = provider.open_relay("C", "page").unwrap();
    for _ in 0..3 {
        assert_eq!(evaluate(&conn).unwrap(), json!({"via": "host"}));
    }
    assert!(
        matches!(host.next(), Frame::RelayAttach { target_id, browser: 7 } if target_id == "C")
    );
    let Frame::Cdp { message, .. } = host.next() else { panic!("a command on the link") };
    assert!(reply_id(&message).unwrap() >= DIRECT_FIRST_RAW_ID, "a raw id in the shim's range");
    // The app only prepared the page: no CDP message went through it.
    assert!(app.frames().iter().any(|frame| matches!(frame, Frame::CdpPrepare { .. })));
    assert!(!app.frames().iter().any(|frame| matches!(frame, Frame::CdpAttach { .. })));
    assert_eq!(app.cdp_count(), 0);
}

#[test]
fn a_link_id_that_is_not_the_links_relays_through_the_app() {
    let (app, provider) = FakeApp::start(Prepare::Direct { link: "L0" });
    let host = FakeHost::link(&provider, "L1");
    assert!(matches!(host.next(), Frame::RelayHelloAck {}));
    let conn = provider.open_relay("C", "page").unwrap();
    assert_eq!(evaluate(&conn).unwrap(), json!({"via": "app"}));
    let frames = app.frames();
    let attach = frames.iter().position(|frame| matches!(frame, Frame::CdpAttach { .. }));
    let detach = frames.iter().position(|frame| matches!(frame, Frame::CdpDetach { .. }));
    assert!(detach.unwrap() < attach.unwrap(), "the prepared session ends before the app relays");
    assert_eq!(app.cdp_count(), 1);
    assert!(host.frames.recv_timeout(Duration::from_millis(100)).is_err(), "nothing on the link");
}

#[test]
fn without_a_link_the_relay_goes_through_the_app_as_before() {
    let (app, provider) = FakeApp::start(Prepare::Fail);
    let conn = provider.open_relay("C", "page").unwrap();
    assert_eq!(evaluate(&conn).unwrap(), json!({"via": "app"}));
    assert!(!app.frames().iter().any(|frame| matches!(frame, Frame::CdpPrepare { .. })));
}

#[test]
fn a_page_that_cannot_start_fails_the_waiting_commands() {
    let (app, provider) = FakeApp::start(Prepare::Fail);
    let host = FakeHost::link(&provider, "L1");
    assert!(matches!(host.next(), Frame::RelayHelloAck {}));
    let conn = provider.open_relay("C", "page").unwrap();
    let error = evaluate(&conn).unwrap_err();
    assert!(error.message.contains("the page did not start"), "{}", error.message);
    // The app hears the end, so the next call prepares the tab again.
    let deadline = std::time::Instant::now() + WAIT;
    while !app.frames().iter().any(|frame| matches!(frame, Frame::CdpDetach { .. })) {
        assert!(std::time::Instant::now() < deadline, "cdp.detach reaches the app");
        std::thread::yield_now();
    }
}

#[test]
fn a_screenshot_on_the_link_holds_the_apps_capture_vote_until_its_reply() {
    let (app, provider) = FakeApp::start(Prepare::Direct { link: "L1" });
    let host = FakeHost::link(&provider, "L1");
    assert!(matches!(host.next(), Frame::RelayHelloAck {}));
    let conn = provider.open_relay("C", "page").unwrap();
    conn.call(Some("page"), "Page.captureScreenshot", json!({}), WAIT).unwrap();
    let captures: Vec<(bool, Option<u64>)> = app
        .frames()
        .into_iter()
        .filter_map(|frame| match frame {
            Frame::CdpCapture { capture, active, id, .. } if capture == "screenshot" => {
                Some((active, id))
            }
            _ => None,
        })
        .collect();
    let deadline = std::time::Instant::now() + WAIT;
    let mut captures = captures;
    while captures.len() < 2 && std::time::Instant::now() < deadline {
        std::thread::yield_now();
        captures = app
            .frames()
            .into_iter()
            .filter_map(|frame| match frame {
                Frame::CdpCapture { active, id, .. } => Some((active, id)),
                _ => None,
            })
            .collect();
    }
    assert_eq!(captures.len(), 2, "{captures:?}");
    assert!(captures[0].0 && !captures[1].0, "the vote starts, then ends at the reply");
    assert_eq!(captures[0].1, captures[1].1);
    assert!(captures[0].1.unwrap() >= DIRECT_FIRST_RAW_ID);
}

#[test]
fn a_link_that_ends_ends_its_relays_and_later_relays_go_through_the_app() {
    let (app, provider) = FakeApp::start(Prepare::Direct { link: "L1" });
    let host = FakeHost::link(&provider, "L1");
    assert!(matches!(host.next(), Frame::RelayHelloAck {}));
    let conn = provider.open_relay("C", "page").unwrap();
    evaluate(&conn).unwrap();
    host.stream.shutdown(std::net::Shutdown::Both).unwrap();
    let deadline = std::time::Instant::now() + WAIT;
    while conn.closed_reason().is_none() || provider.direct.linked() {
        assert!(std::time::Instant::now() < deadline, "the relay ends with its link");
        std::thread::yield_now();
    }
    let again = provider.open_relay("C", "page").unwrap();
    assert_eq!(evaluate(&again).unwrap(), json!({"via": "app"}));
    assert!(app.frames().iter().any(|frame| matches!(frame, Frame::CdpAttach { .. })));
}

#[test]
fn a_chromium_host_that_outlives_its_app_dials_again_for_the_next_app() {
    let (first_app, first) = FakeApp::start(Prepare::Direct { link: "L1" });
    let host = FakeHost::link(&first, "L1");
    assert!(matches!(host.next(), Frame::RelayHelloAck {}));
    let conn = first.open_relay("C", "page").unwrap();
    evaluate(&conn).unwrap();
    // The app is killed: its relays and its link end with it.
    first_app.stream.shutdown(std::net::Shutdown::Both).unwrap();
    let deadline = std::time::Instant::now() + WAIT;
    while first.closed_reason().is_none() || conn.closed_reason().is_none() || first.direct.linked()
    {
        assert!(std::time::Instant::now() < deadline, "the relay and the link end with the app");
        std::thread::yield_now();
    }
    // The Chromium Host reads its link's end (its reader thread stops).
    loop {
        match host.frames.recv_timeout(WAIT) {
            Ok(_) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
            Err(mpsc::RecvTimeoutError::Timeout) => panic!("the Chromium Host's link stays open"),
        }
    }
    // A relaunched app mints a new link id (BrowserHostProvider.relayLinkID)
    // and gives it to the host it adopts, which dials with it.
    let (second_app, second) = FakeApp::start(Prepare::Direct { link: "L2" });
    let redialed = FakeHost::link(&second, "L2");
    assert!(matches!(redialed.next(), Frame::RelayHelloAck {}));
    let again = second.open_relay("C", "page").unwrap();
    assert_eq!(
        evaluate(&again).unwrap(),
        json!({"via": "host"}),
        "the agent drives the page again"
    );
    assert_eq!(second_app.cdp_count(), 0, "still never through the app");
    assert!(
        matches!(redialed.next(), Frame::RelayAttach { target_id, browser: 7 } if target_id == "C")
    );
}

#[test]
fn a_new_link_ends_the_relays_of_the_link_it_replaces() {
    let (app, provider) = FakeApp::start(Prepare::Direct { link: "L1" });
    let first = FakeHost::link(&provider, "L1");
    assert!(matches!(first.next(), Frame::RelayHelloAck {}));
    let conn = provider.open_relay("C", "page").unwrap();
    assert_eq!(evaluate(&conn).unwrap(), json!({"via": "host"}));
    // The Chromium Host dials again (a re-dial, or the same app's new link).
    let second = FakeHost::link(&provider, "L1");
    assert!(matches!(second.next(), Frame::RelayHelloAck {}));
    let deadline = std::time::Instant::now() + WAIT;
    while conn.closed_reason().is_none() {
        assert!(std::time::Instant::now() < deadline, "the relay on the replaced link ends");
        std::thread::yield_now();
    }
    assert!(evaluate(&conn).is_err(), "a call on the replaced link's relay fails at once");
    // The app heard the end, so the next call prepares the tab again, on the new link.
    let deadline = std::time::Instant::now() + WAIT;
    while !app.frames().iter().any(|frame| matches!(frame, Frame::CdpDetach { .. })) {
        assert!(std::time::Instant::now() < deadline, "cdp.detach reaches the app");
        std::thread::yield_now();
    }
    let again = provider.open_relay("C", "page").unwrap();
    assert_eq!(evaluate(&again).unwrap(), json!({"via": "host"}));
    assert!(
        matches!(second.next(), Frame::RelayAttach { target_id, browser: 7 } if target_id == "C")
    );
    let prepares =
        app.frames().iter().filter(|frame| matches!(frame, Frame::CdpPrepare { .. })).count();
    assert_eq!(prepares, 2, "the tab was prepared again");
}

#[test]
fn a_reopened_relay_continues_the_raw_ids() {
    let (_app, provider) = FakeApp::start(Prepare::Direct { link: "L1" });
    let host = FakeHost::link(&provider, "L1");
    assert!(matches!(host.next(), Frame::RelayHelloAck {}));
    let first = provider.open_relay("C", "page").unwrap();
    evaluate(&first).unwrap();
    let used = first.next_id();
    provider.close_relay("C");
    let second = provider.open_relay("C", "page").unwrap();
    assert_eq!(second.next_id(), used, "a late reply of the old relay matches no new call");
    assert_eq!(evaluate(&second).unwrap(), json!({"via": "host"}));
}

#[test]
fn the_relay_credential_opens_a_relay_link_and_nothing_else() {
    let secret = ProviderSecret::new("s3cret");
    let credential = secret.relay_credential();
    assert_eq!(credential, ProviderSecret::new("s3cret").relay_credential(), "deterministic");
    assert!(!credential.matches(&secret));
    assert_eq!(format!("{credential:?}"), "ProviderSecret(<redacted>)");
    let open = |frame: Frame| {
        let (mut ours, mut theirs) = UnixStream::pair().unwrap();
        write_frame(&mut ours, &frame).unwrap();
        read_opening(&mut theirs, &secret)
    };
    let relay = |credential: ProviderSecret| Frame::RelayHello {
        version: crate::provider::RELAY_VERSION,
        link: "L9".into(),
        credential,
    };
    let hello = |secret: ProviderSecret| Frame::Hello {
        version: crate::provider::PROVIDER_VERSION,
        provider_id: "app".into(),
        install_id: "inst".into(),
        secret,
        engines: vec!["cef".into()],
        tabs: Vec::new(),
    };
    assert!(
        matches!(open(relay(credential.clone())), Ok(Opening::RelayLink { link }) if link == "L9")
    );
    assert!(open(relay(secret.clone())).is_err(), "the secret is not the relay credential");
    assert!(open(hello(credential)).is_err(), "the relay credential opens no provider");
    assert!(matches!(open(hello(secret.clone())), Ok(Opening::Provider(_))));
}

#[test]
fn the_relay_credential_matches_the_apps_derivation() {
    // HMAC-SHA256(key "test-secret", "cmux-chromium-host-relay-v1"); the
    // app's ProviderSecretRelayTests checks the same value.
    let expected = ProviderSecret::new(RELAY_TEST_VECTOR);
    assert!(ProviderSecret::new("test-secret").relay_credential().matches(&expected));
}

/// The relay credential of the secret `test-secret`.
const RELAY_TEST_VECTOR: &str = "e40644f33ec8afb45205d144cbef8fec286fa012fbb4ecec8da38ae5153cb334";
