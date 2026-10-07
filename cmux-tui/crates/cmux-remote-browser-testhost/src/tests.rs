//! Loopback tests: a viewer built on cmux-rd-ffi's session (the core the Mac
//! client links) talks to the test host over a real TCP connection.

use std::io::{Read, Write};
use std::net::{Ipv4Addr, TcpListener, TcpStream};
use std::thread;
use std::time::{Duration, Instant};

use cmux_rd_ffi::{Carrier, Session};
use cmux_rd_proto::control::Control;
use cmux_rd_proto::flags;
use cmux_rd_proto::{SERVICE_REMOTE_BROWSER, STREAM_CONTROL, encode_stream_frame};

use super::{Options, Page, parse, session};

fn options(frames: u64) -> Options {
    Options { port: 4103, width: 320, height: 240, fps: 60, frames, once: true }
}

/// A connected viewer socket and the host thread serving it.
fn connect(o: Options) -> (TcpStream, thread::JoinHandle<String>) {
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).expect("bind");
    let port = listener.local_addr().expect("addr").port();
    let host = thread::spawn(move || {
        let (conn, _) = listener.accept().expect("accept");
        session(conn, o).map_err(|e| e.to_string()).unwrap_or_else(|e| format!("error: {e}"))
    });
    let viewer = TcpStream::connect((Ipv4Addr::LOCALHOST, port)).expect("connect");
    viewer.set_read_timeout(Some(Duration::from_secs(10))).expect("timeout");
    (viewer, host)
}

fn hello(viewer: &mut TcpStream, service: &str) {
    hello_with(viewer, service, &[]);
}

fn hello_with(viewer: &mut TcpStream, service: &str, caps: &[&str]) {
    let control = Control::Hello {
        user: "test".into(),
        install: "test".into(),
        class: "viewer".into(),
        interactive: true,
        udp_port: None,
        max_datagram: 1332,
        token: None,
        service: service.into(),
        caps: caps.iter().map(|c| (*c).to_string()).collect(),
    };
    let mut out = Vec::new();
    encode_stream_frame(STREAM_CONTROL, &serde_json::to_vec(&control).expect("json"), &mut out)
        .expect("frame");
    viewer.write_all(&out).expect("write hello");
}

#[test]
fn a_viewer_gets_welcome_started_rb_opened_and_a_complete_keyframe() {
    let (mut viewer, host) = connect(options(20));
    hello(&mut viewer, SERVICE_REMOTE_BROWSER);
    let mut core = Session::new(Carrier::Stream, 500_000, 50_000);
    let t0 = Instant::now();
    let now = || u64::try_from(t0.elapsed().as_micros()).unwrap_or(u64::MAX);
    let mut controls: Vec<serde_json::Value> = Vec::new();
    let mut keyframe = false;
    let mut buf = [0u8; 16 * 1024];
    while !(keyframe && controls.len() >= 3) {
        let n = viewer.read(&mut buf).expect("read");
        assert!(n > 0, "the host closed before a keyframe; controls {controls:?}");
        core.push_stream(&buf[..n], now()).expect("push");
        while let Some(message) = core.pop_message() {
            if message.kind == STREAM_CONTROL {
                controls.push(serde_json::from_slice(&message.bytes).expect("control json"));
            }
        }
        while let Some((stream, frame)) = core.pop_frame() {
            assert_eq!(stream, 0);
            keyframe |= frame.flags & flags::KEYFRAME != 0;
        }
    }
    assert_eq!(controls[0]["t"], "welcome");
    assert_eq!(controls[0]["service"], SERVICE_REMOTE_BROWSER);
    assert_eq!(controls[0]["width"], 320);
    assert_eq!(controls[1], serde_json::json!({"t": "started", "session": 1}));
    assert_eq!(controls[2]["t"], "service");
    assert_eq!(controls[2]["body"]["t"], "rb.opened");
    drop(viewer);
    let reason = host.join().expect("host thread");
    assert!(reason == "viewer left" || reason == "sent 20 frames", "{reason}");
}

#[test]
fn the_welcome_grants_service_input_when_the_viewer_offers_it() {
    let (mut viewer, host) = connect(options(1));
    hello_with(&mut viewer, SERVICE_REMOTE_BROWSER, &["input.service", "tile"]);
    let mut core = Session::new(Carrier::Stream, 500_000, 50_000);
    let mut buf = [0u8; 4096];
    let welcome = loop {
        let n = viewer.read(&mut buf).expect("read");
        assert!(n > 0, "the host closed before welcome");
        core.push_stream(&buf[..n], 0).expect("push");
        if let Some(message) = core.pop_message() {
            break serde_json::from_slice::<serde_json::Value>(&message.bytes).expect("json");
        }
    };
    assert_eq!(welcome["t"], "welcome");
    assert_eq!(welcome["caps"], serde_json::json!(["input.service"]));
    drop(viewer);
    let _ = host.join();
}

#[test]
fn a_hello_for_another_service_is_refused() {
    let (mut viewer, host) = connect(options(1));
    hello(&mut viewer, "desktop");
    let mut core = Session::new(Carrier::Stream, 500_000, 50_000);
    let mut buf = [0u8; 4096];
    let n = viewer.read(&mut buf).expect("read");
    core.push_stream(&buf[..n], 0).expect("push");
    let message = core.pop_message().expect("a control message");
    let control: serde_json::Value = serde_json::from_slice(&message.bytes).expect("json");
    assert_eq!(control, serde_json::json!({"t": "refused", "reason": "service"}));
    assert!(host.join().expect("host").starts_with("refused hello"));
}

#[test]
fn options_refuse_privileged_ports_and_odd_sizes() {
    let args = |s: &[&str]| s.iter().map(|a| (*a).to_string()).collect::<Vec<_>>();
    assert!(parse(&args(&["--port", "80"])).is_err());
    assert!(parse(&args(&["--width", "641"])).is_err());
    assert!(parse(&args(&["--fps", "0"])).is_err());
    assert!(parse(&args(&["--bogus", "1"])).is_err());
    let o = parse(&args(&["--port", "5000", "--frames", "3", "--once"])).expect("valid");
    assert_eq!((o.port, o.frames, o.once, o.width, o.height), (5000, 3, true, 1280, 720));
}

#[test]
fn right_click_opens_a_context_menu_with_increasing_tokens() {
    let mut page = Page::default();
    let right = br#"{"e":"pointer","surface":0,"kind":"down","x":12.0,"y":30.0,"button":2,"buttons":2,"click_count":1,"modifiers":0,"pointer_type":"mouse"}"#;
    let first = page.input(right).expect("menu");
    assert_eq!(first["t"], "rb.menu.show");
    assert_eq!(first["token"], 1);
    assert_eq!(first["menu"]["anchor"]["x"], 12.0);
    assert_eq!(page.input(right).expect("menu")["token"], 2);
}

#[test]
fn cmd_click_opens_a_background_tab_and_a_plain_click_does_nothing() {
    let mut page = Page::default();
    let click = |modifiers: u32| {
        format!(
            r#"{{"e":"pointer","surface":0,"kind":"down","x":5.0,"y":5.0,"button":0,"buttons":1,"click_count":1,"modifiers":{modifiers},"pointer_type":"mouse"}}"#
        )
    };
    assert_eq!(page.input(click(0).as_bytes()), None);
    let tab = page.input(click(8).as_bytes()).expect("open_tab");
    assert_eq!(tab["t"], "rb.open_tab");
    assert_eq!(tab["request"], 1);
    assert_eq!(tab["disposition"], "background_tab");
    let up = br#"{"e":"pointer","surface":0,"kind":"up","x":5.0,"y":5.0,"button":0,"buttons":0,"click_count":1,"modifiers":8,"pointer_type":"mouse"}"#;
    assert_eq!(page.input(up), None);
}

#[test]
fn navigate_answers_with_the_page_and_other_messages_are_ignored() {
    let mut page = Page::default();
    let reply = page
        .control(&serde_json::json!({"t": "rb.navigate", "url": "https://example.com/typed"}))
        .expect("page");
    assert_eq!(reply["t"], "rb.page");
    assert_eq!(reply["url"], "https://example.com/typed");
    assert_eq!(reply["loading"], false);
    assert_eq!(page.control(&serde_json::json!({"t": "rb.visibility", "visible": true})), None);
    assert_eq!(page.input(b"not json"), None);
}
