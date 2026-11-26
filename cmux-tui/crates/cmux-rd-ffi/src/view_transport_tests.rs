//! Parity tests for the stream transport rules (`view/control.rs`,
//! `view/handshake.rs`, `view/cursor.rs`, `view/transport.rs`), ported from
//! the Swift suites they replace: RemoteRdControlTests (the golden vectors),
//! RemoteRdHandshakeTests, RemoteRdSessionEndReasonTests, RemoteCursorTests,
//! RemoteClipboardTests, CloudDesktopLinkTests, RemoteRdStreamSplitterTests and
//! RemoteRdSurfaceStreamsTests. The JSON tests go through `cmux_rd_view_call`.

use cmux_rd_proto::{STREAM_CONTROL, STREAM_DATAGRAM, base64_encode, encode_stream_frame};
use serde_json::{Value, json};

use crate::view::control::{self, Hello, Incoming};
use crate::view::cursor::{self, CursorFeed, CursorState, DatagramResult};
use crate::view::handshake::{Handshake, Phase, host_end};
use crate::view::pane::{SessionEnd, SessionState, UpstreamKind, UpstreamStatus};
use crate::view::transport::{
    StreamSplitter, SurfaceChange, SurfacePlan, SurfaceStreams, Transport, UpstreamAnswer,
};
use crate::{CMUX_RD_OK, cmux_rd_view_call, cmux_rd_view_free, cmux_rd_view_new};

const VECTORS: &str = include_str!("../../cmux-rd-proto/tests/vectors/control.json");
const TOKEN: &str = "abababababababababababababababababababababababababababababababab";

fn call(request: Value) -> Value {
    let view = cmux_rd_view_new();
    let bytes = request.to_string();
    let mut out: *const u8 = std::ptr::null();
    let mut len = 0usize;
    // SAFETY: a live handle and readable bytes; out pointers are writable.
    let code = unsafe { cmux_rd_view_call(view, bytes.as_ptr(), bytes.len(), &mut out, &mut len) };
    assert_eq!(code, CMUX_RD_OK, "{request}");
    // SAFETY: valid until the next call on `view`.
    let value = serde_json::from_slice(unsafe { std::slice::from_raw_parts(out, len) }).unwrap();
    // SAFETY: from cmux_rd_view_new, not used again.
    unsafe { cmux_rd_view_free(view) };
    value
}

fn vectors() -> Vec<(String, Value)> {
    let all: Vec<Value> = serde_json::from_str(VECTORS).unwrap();
    all.into_iter().map(|v| (v["name"].as_str().unwrap().to_owned(), v["json"].clone())).collect()
}

fn vector(name: &str) -> Value {
    vectors().into_iter().find(|(n, _)| n == name).unwrap().1
}

fn incoming(value: Value) -> Incoming {
    control::parse(value.to_string().as_bytes()).unwrap()
}

fn welcome(service: Option<&str>, caps: Option<&[&str]>) -> Value {
    let mut w = json!({"t": "welcome", "encoder": "h264", "width": 1280, "height": 800, "max_datagram": 1200, "carrier": "stream"});
    if let Some(service) = service {
        w["service"] = json!(service);
    }
    if let Some(caps) = caps {
        w["caps"] = json!(caps);
    }
    w
}

fn started() -> Value {
    json!({"t": "started", "session": 7})
}

// MARK: - RemoteRdControlTests (golden vectors)

#[test]
fn every_golden_vector_parses_as_the_viewer_reads_it() {
    for (name, value) in vectors() {
        let parsed = incoming(value.clone());
        match (name.as_str(), &parsed) {
            ("welcome", Incoming::Welcome { welcome }) => {
                assert_eq!(welcome.service.as_deref(), Some("desktop"));
                assert_eq!(welcome.caps.as_deref(), Some(&[][..]));
                assert_eq!(
                    (welcome.width, welcome.height, welcome.max_datagram),
                    (1920, 1080, 1152)
                );
            }
            (_, Incoming::Control { control }) => {
                // Re-encoding gives back the vector, less the nulls Swift leaves out.
                let mut expected = value.clone();
                expected.as_object_mut().unwrap().retain(|_, v| !v.is_null());
                if name == "hello_before_c1" {
                    // Rust's typed hello fills the C1 defaults in.
                    expected["service"] = json!("desktop");
                    expected["caps"] = json!([]);
                }
                if name == "stream_open_newer_kind" {
                    expected["kind"] = json!("unknown");
                }
                assert_eq!(control::encode(control), expected, "{name}");
            }
            _ => panic!("{name}: {parsed:?}"),
        }
    }
}

#[test]
fn an_unknown_tag_is_ignored_not_an_error() {
    let parsed = incoming(json!({"t": "hologram", "x": 1}));
    assert!(matches!(parsed, Incoming::Unknown { ref tag } if tag == "hologram"));
    assert!(control::parse(b"{\"x\":1}").is_err());
    assert!(control::parse(b"not json").is_err());
    // A known tag whose fields do not parse is an error (skipped by the transport).
    assert!(control::parse(br#"{"t":"started"}"#).is_err());
}

#[test]
fn a_welcome_from_before_c1_has_no_service_or_caps() {
    let Incoming::Welcome { welcome } = incoming(welcome(None, None)) else { panic!() };
    assert_eq!(welcome.service, None);
    assert_eq!(welcome.caps, None);
    assert!(!welcome.has_cap("clock"));
}

#[test]
fn control_parse_op_round_trips() {
    let out = call(json!({"op": "control.parse", "json": vector("started").to_string()}));
    assert_eq!(
        out,
        json!({"ok": true, "incoming": {"kind": "control", "control": {"t": "started", "session": 7}}})
    );
    let out = call(json!({"op": "control.parse", "json": "{}"}));
    assert_eq!(out["ok"], json!(false));
    let out = call(
        json!({"op": "control.encode", "control": {"t": "service", "service": "rb/1", "body": null}}),
    );
    assert_eq!(out, json!({"t": "service", "service": "rb/1", "body": null}));
}

// MARK: - CloudDesktopLinkTests / RemoteClipboardTests (hello)

#[test]
fn a_tokenless_hello_has_no_token_key() {
    let hello = Hello::cloud_desktop(Some("cmux-next-1"));
    let value = control::encode(&hello.control());
    assert!(value.get("token").is_none());
    assert!(value.get("udp_port").is_none());
    assert_eq!(value["user"], json!("cmux"));
    assert_eq!(value["caps"], json!(["cursor", "fec.blocks"]));
    assert_eq!(value["service"], json!("desktop"));
    assert_eq!(value["max_datagram"], json!(1152));
    assert!(Hello::cloud_desktop(None).install.starts_with("cmux-next-"));
}

#[test]
fn a_hello_with_a_token_sends_it_and_never_prints_it() {
    let hello = Hello::new("u", "i", Some(TOKEN), "desktop", &["stream.open"]);
    let value = control::encode(&hello.control());
    let mut expected = vector("hello");
    expected.as_object_mut().unwrap().remove("udp_port");
    assert_eq!(value, expected);
    assert!(!format!("{hello:?}").contains(TOKEN));
    assert!(!hello.redacted_description().contains(TOKEN));
    assert_eq!(
        call(json!({"op": "hello.redacted", "hello": hello})),
        json!("RemoteRdHello(user: u, install: i, service: desktop, token: <redacted>)")
    );
}

#[test]
fn the_stream_hello_lists_the_clipboard_cap_only_when_asked_and_once() {
    let hello = Hello::cloud_desktop(Some("x"));
    assert_eq!(hello.clone().for_stream(false).caps, ["cursor", "fec.blocks"]);
    let once = hello.for_stream(true);
    assert_eq!(once.caps, ["cursor", "fec.blocks", "clipboard.text"]);
    assert_eq!(once.clone().for_stream(true).caps, once.caps);
    let mut udp = Hello::new("u", "i", None, "desktop", &[]);
    udp.udp_port = Some(5000);
    assert_eq!(udp.for_stream(false).udp_port, None);
}

#[test]
fn hello_then_start_in_the_right_mode() {
    let mut t = Transport::new(Hello::cloud_desktop(Some("x")), "display:0", true, false);
    assert!(t.connect());
    assert!(!t.connect(), "starts once");
    t.progress("dialing");
    assert_eq!(t.connecting_reason.as_deref(), Some("dialing"));
    let send = t.ready();
    assert_eq!(t.connecting_reason, None);
    assert_eq!(send[0]["t"], json!("hello"));
    assert_eq!(send[1], json!({"t": "start", "key": "display:0", "mode": "control"}));
    let mut view = Transport::new(Hello::cloud_desktop(Some("x")), "display:0", false, false);
    assert_eq!(view.ready()[1]["mode"], json!("view"));
}

#[test]
fn the_remote_browser_hello_asks_for_rb1_with_service_input() {
    let out =
        call(json!({"op": "hello.remoteBrowser", "user": "u", "install": "i", "token": TOKEN}));
    assert_eq!(out["service"], json!("rb/1"));
    assert_eq!(out["caps"], json!(["input.service"]));
    let encoded = call(json!({"op": "hello.encode", "hello": out}));
    assert_eq!(encoded["token"], json!(TOKEN));
}

// MARK: - RemoteRdHandshakeTests

#[test]
fn welcome_then_started_streams() {
    let mut h = Handshake::new("desktop");
    assert_eq!(h.session_state(), SessionState::Connecting);
    h.receive(&incoming(welcome(Some("desktop"), Some(&[]))));
    assert_eq!(h.phase, Phase::AwaitingStarted);
    h.receive(&incoming(started()));
    assert_eq!(h.phase, Phase::Streaming { session: 7 });
    assert_eq!(h.session_state(), SessionState::Streaming);
}

#[test]
fn a_host_before_c1_streams_without_a_service() {
    let mut h = Handshake::new("desktop");
    h.receive(&incoming(welcome(None, None)));
    h.receive(&incoming(started()));
    assert!(h.is_streaming());
}

#[test]
fn a_welcome_for_another_service_is_a_protocol_error() {
    let mut h = Handshake::new("rb/1");
    h.receive(&incoming(welcome(Some("desktop"), Some(&[]))));
    assert_eq!(h.phase, Phase::Ended { end: SessionEnd::ConnectionLost });
}

#[test]
fn out_of_order_messages_end_the_session() {
    for first in [started(), welcome(Some("desktop"), Some(&[]))] {
        let mut h = Handshake::new("desktop");
        if first["t"] == "welcome" {
            h.receive(&incoming(first.clone()));
        }
        // started before welcome, or a second welcome.
        h.receive(&incoming(if first["t"] == "welcome" { first } else { started() }));
        assert_eq!(h.phase, Phase::Ended { end: SessionEnd::ConnectionLost });
    }
    // A viewer-side message from the host.
    let mut h = Handshake::new("desktop");
    h.receive(&incoming(vector("stop")));
    assert_eq!(h.phase, Phase::Ended { end: SessionEnd::ConnectionLost });
}

#[test]
fn refused_is_consent_denied_and_ended_after_stop_is_the_viewer() {
    let mut h = Handshake::new("desktop");
    h.receive(&incoming(vector("refused")));
    assert_eq!(h.phase, Phase::Ended { end: SessionEnd::ConsentDenied });

    let mut h = Handshake::new("desktop");
    h.receive(&incoming(welcome(Some("desktop"), Some(&[]))));
    h.receive(&incoming(started()));
    h.viewer_stopped();
    h.receive(&incoming(vector("ended")));
    assert_eq!(h.phase, Phase::Ended { end: SessionEnd::StoppedByViewer });
    // Nothing moves an ended session.
    h.receive(&incoming(started()));
    h.connection_closed();
    assert_eq!(h.phase, Phase::Ended { end: SessionEnd::StoppedByViewer });
}

#[test]
fn side_messages_and_unknown_tags_pass_through_while_streaming() {
    let mut h = Handshake::new("desktop");
    h.receive(&incoming(welcome(Some("desktop"), Some(&[]))));
    h.receive(&incoming(started()));
    for name in [
        "stats",
        "stats_profile",
        "service",
        "bulk_credit",
        "stream_open",
        "stream_open_newer_kind",
        "stream_opened",
        "stream_refused",
        "stream_close",
        "clipboard",
        "clipboard_part",
        // The Swift reducer ended the session here (its pass-through list left
        // cursor_shape out): the Rust rule keeps streaming.
        "cursor_shape",
    ] {
        h.receive(&incoming(vector(name)));
        assert!(h.is_streaming(), "{name}");
    }
    h.receive(&incoming(json!({"t": "hologram"})));
    assert!(h.is_streaming());
}

#[test]
fn closed_without_stop_is_connection_lost() {
    let mut h = Handshake::new("desktop");
    h.connection_closed();
    assert_eq!(h.phase, Phase::Ended { end: SessionEnd::ConnectionLost });
    let mut h = Handshake::new("desktop");
    h.viewer_stopped();
    h.connection_closed();
    assert_eq!(h.phase, Phase::Ended { end: SessionEnd::StoppedByViewer });
}

#[test]
fn handshake_receive_op() {
    let state = call(json!({"op": "handshake.new", "service": "desktop"}));
    let out = call(
        json!({"op": "handshake.receive", "state": state, "message": welcome(Some("desktop"), Some(&["clock"]))}),
    );
    assert_eq!(out["parsed"], json!(true));
    assert_eq!(out["state"]["phase"], json!({"kind": "awaitingStarted"}));
    let out = call(json!({"op": "handshake.receive", "state": out["state"], "message": started()}));
    assert_eq!(out["session"], json!({"kind": "streaming"}));
    let out = call(json!({"op": "handshake.receive", "state": out["state"], "message": {"t": 3}}));
    assert_eq!(out["parsed"], json!(false));
    assert_eq!(out["session"], json!({"kind": "streaming"}));
}

// MARK: - RemoteRdSessionEndReasonTests

#[test]
fn host_end_keeps_the_hosts_failure() {
    assert_eq!(host_end("stop"), SessionEnd::HostStoppedSharing);
    assert_eq!(host_end(""), SessionEnd::HostStoppedSharing);
    assert_eq!(host_end("failedish"), SessionEnd::HostStoppedSharing);
    assert_eq!(host_end("failed"), SessionEnd::HostFailed { reason: String::new() });
    assert_eq!(
        host_end("  failed: no display  "),
        SessionEnd::HostFailed { reason: "no display".into() }
    );
    assert_eq!(host_end("failed:x"), SessionEnd::HostFailed { reason: "x".into() });
    assert_eq!(
        call(json!({"op": "handshake.hostEnd", "reason": "failed: capture"})),
        json!({"kind": "hostFailed", "reason": "capture"})
    );
}

// MARK: - Transport bookkeeping

fn transport(clipboard: bool) -> Transport {
    Transport::new(Hello::cloud_desktop(Some("x")), "display:0", true, clipboard)
}

fn receive(t: &mut Transport, value: Value) -> crate::view::transport::ControlActions {
    t.receive_control(value.to_string().as_bytes())
}

#[test]
fn the_welcome_creates_the_consent_and_the_clipboard_both_sides_list() {
    let mut t = transport(true);
    let a = receive(&mut t, welcome(Some("desktop"), Some(&["clock", "clipboard.text"])));
    assert!(a.parsed && a.enable_clock && a.create_clipboard);
    assert_eq!(a.create_upstream, Some(vec!["clock".to_owned(), "clipboard.text".to_owned()]));
    // Created once.
    let a = receive(&mut t, started());
    assert_eq!(a.create_upstream, None);
    assert!(!a.create_clipboard && !a.enable_clock);

    // The host lists clipboard.text but the viewer did not offer it.
    let mut t = transport(false);
    assert!(!receive(&mut t, welcome(Some("desktop"), Some(&["clipboard.text"]))).create_clipboard);
    // An older host: consent with no caps, no clock.
    let mut t = transport(true);
    let a = receive(&mut t, welcome(None, None));
    assert_eq!(a.create_upstream, Some(vec![]));
    assert!(!a.enable_clock && !a.create_clipboard);
}

#[test]
fn upstream_answers_use_the_welcome_max_datagram() {
    let mut t = transport(false);
    assert_eq!(receive(&mut t, vector("stream_opened")).upstream, None, "no consent yet");
    receive(&mut t, welcome(Some("desktop"), Some(&[])));
    receive(&mut t, started());
    assert_eq!(
        receive(&mut t, vector("stream_opened")).upstream,
        Some(UpstreamAnswer::Opened { stream: 100, max_datagram: 1200 })
    );
    assert_eq!(
        receive(&mut t, vector("stream_refused")).upstream,
        Some(UpstreamAnswer::Refused { stream: 101 })
    );
    assert_eq!(
        receive(&mut t, vector("stream_close")).upstream,
        Some(UpstreamAnswer::ClosedByHost { stream: 100 })
    );
}

#[test]
fn service_stats_and_cursor_shape_go_to_their_streams() {
    let mut t = Transport::new(Hello::remote_browser("u", "i", None), "tab", true, false);
    receive(&mut t, welcome(Some("rb/1"), Some(&["input.service"])));
    receive(&mut t, started());
    let a = receive(&mut t, vector("service"));
    assert_eq!(a.service, Some(vector("service")["body"].clone()));
    assert_eq!(a.surface, None);
    let show = json!({"t": "service", "service": "rb/1", "body": {"t": "rb.surface.show", "surface": 2, "stream": 5}});
    assert_eq!(receive(&mut t, show).surface, Some(SurfaceChange::Show { surface: 2, stream: 5 }));
    // Another service's body is not this session's.
    let other = json!({"t": "service", "service": "desktop", "body": {}});
    assert_eq!(receive(&mut t, other).service, None);
    assert_eq!(receive(&mut t, vector("stats")).host_stats, Some(vector("stats")));
    let shape = receive(&mut t, vector("cursor_shape")).cursor_shape.unwrap();
    assert_eq!(
        (shape.id, shape.width, shape.height, shape.hot_x, shape.hot_y),
        (0xdead_beef, 2, 1, 1, 0)
    );
    assert!(t.handshake.is_streaming(), "a cursor shape does not end the session");
    assert!(!receive(&mut t, json!("nope")).parsed);
}

#[test]
fn service_input_needs_the_hosts_cap_and_a_live_session() {
    let mut t = Transport::new(Hello::remote_browser("u", "i", None), "tab", true, false);
    assert!(!t.allows_service_input());
    receive(&mut t, welcome(Some("rb/1"), Some(&["input.service"])));
    assert!(t.allows_service_input());
    assert!(!t.allows_upstream_request(), "not streaming yet");
    receive(&mut t, started());
    assert!(t.allows_upstream_request());
    assert_eq!(
        t.service_message(json!({"t": "rb.key"})),
        Some(json!({"t": "service", "service": "rb/1", "body": {"t": "rb.key"}}))
    );
    let mut old = transport(false);
    receive(&mut old, welcome(None, None));
    assert!(!old.allows_service_input());
}

#[test]
fn stop_goes_out_once_and_the_host_end_is_the_viewers() {
    let mut t = transport(false);
    receive(&mut t, welcome(Some("desktop"), Some(&[])));
    receive(&mut t, started());
    assert_eq!(t.stop(), Some(json!({"t": "stop"})));
    let a = receive(&mut t, vector("ended"));
    assert!(a.ended);
    assert_eq!(
        t.handshake.session_state(),
        SessionState::Ended { reason: SessionEnd::StoppedByViewer }
    );
    assert_eq!(t.stop(), None);
    assert_eq!(t.service_message(json!({})), None);
    assert!(!t.connect(), "never starts after the end");
    t.progress("late");
    assert_eq!(t.connecting_reason, None);
    assert!(!t.accepts_data());
}

#[test]
fn only_the_close_that_ends_the_session_keeps_its_reason() {
    let mut t = transport(false);
    t.closed("reset by peer");
    t.closed("second");
    let status = t.status(None);
    assert_eq!(status.end_reason.as_deref(), Some("reset by peer"));
    assert_eq!(status.state, SessionState::Ended { reason: SessionEnd::ConnectionLost });

    // After the host ended the session, a close says nothing.
    let mut t = transport(false);
    receive(&mut t, vector("refused"));
    t.closed("eof");
    assert_eq!(t.status(None).end_reason, None);
    assert_eq!(Transport::rejected_reason("bad frame"), "rd stream bytes rejected: bad frame");
}

#[test]
fn status_shows_the_upstream_only_while_streaming_with_a_consent() {
    let consent = UpstreamStatus {
        offered: true,
        requested: [UpstreamKind::Microphone].into(),
        active: [].into(),
    };
    let mut t = transport(false);
    assert_eq!(t.status(Some(consent.clone())).upstream, UpstreamStatus::default());
    receive(&mut t, welcome(Some("desktop"), Some(&[])));
    let s = t.status(Some(consent.clone()));
    assert_eq!((s.stream_width, s.stream_height), (Some(1280), Some(800)));
    assert_eq!(s.upstream, UpstreamStatus::default());
    receive(&mut t, started());
    assert_eq!(t.status(Some(consent.clone())).upstream, consent);
    t.finish();
    assert_eq!(t.status(Some(consent)).upstream, UpstreamStatus::default());
}

#[test]
fn transport_ops_round_trip_through_the_abi() {
    let hello = call(json!({"op": "hello.cloudDesktop", "install": "x"}));
    let state = call(
        json!({"op": "transport.new", "hello": hello, "startKey": "display:0", "control": true, "clipboard": true}),
    );
    let out = call(json!({"op": "transport.connect", "state": state}));
    assert_eq!(out["start"], json!(true));
    let out = call(json!({"op": "transport.ready", "state": out["state"]}));
    assert_eq!(out["send"][0]["caps"], json!(["cursor", "fec.blocks", "clipboard.text"]));
    let w = welcome(Some("desktop"), Some(&["clock", "clipboard.text"])).to_string();
    let out = call(json!({"op": "transport.control", "state": out["state"], "json": w}));
    assert_eq!(out["actions"]["enableClock"], json!(true));
    assert_eq!(out["actions"]["createClipboard"], json!(true));
    let out = call(
        json!({"op": "transport.control", "state": out["state"], "json": started().to_string()}),
    );
    let gates = call(json!({"op": "transport.gates", "state": out["state"]}));
    assert_eq!(gates["streaming"], json!(true));
    assert_eq!(gates["upstreamRequest"], json!(true));
    let status = call(json!({"op": "transport.status", "state": out["state"]}));
    assert_eq!(status["state"], json!({"kind": "streaming"}));
    let out = call(json!({"op": "transport.stop", "state": out["state"]}));
    assert_eq!(out["revokeUpstream"], json!(true));
    assert_eq!(out["send"], json!({"t": "stop"}));
    let out = call(json!({"op": "transport.closed", "state": out["state"], "reason": "eof"}));
    let status = call(json!({"op": "transport.status", "state": out["state"]}));
    assert_eq!(status["state"], json!({"kind": "ended", "reason": {"kind": "stoppedByViewer"}}));
    assert_eq!(status["endReason"], json!("eof"));
}

// MARK: - RemoteRdStreamSplitterTests

fn frames() -> (Vec<u8>, Vec<usize>) {
    let mut bytes = Vec::new();
    let mut control_ends = Vec::new();
    encode_stream_frame(STREAM_DATAGRAM, &[9; 40], &mut bytes).unwrap();
    encode_stream_frame(STREAM_CONTROL, br#"{"t":"stats"}"#, &mut bytes).unwrap();
    control_ends.push(bytes.len());
    encode_stream_frame(STREAM_DATAGRAM, &[1; 3], &mut bytes).unwrap();
    encode_stream_frame(STREAM_CONTROL, b"", &mut bytes).unwrap();
    control_ends.push(bytes.len());
    encode_stream_frame(STREAM_CONTROL, b"{}", &mut bytes).unwrap();
    control_ends.push(bytes.len());
    encode_stream_frame(STREAM_DATAGRAM, &[2; 7], &mut bytes).unwrap();
    (bytes, control_ends)
}

#[test]
fn the_splitter_cuts_after_every_control_frame_in_any_chunking() {
    let (bytes, control_ends) = frames();
    for chunk in [1, 2, 3, 5, 7, 13, bytes.len()] {
        let mut splitter = StreamSplitter::default();
        let mut cuts = Vec::new();
        let mut covered = 0;
        for (i, piece) in bytes.chunks(chunk).enumerate() {
            let base = i * chunk;
            let segments = splitter.split(piece);
            assert_eq!(segments.last().unwrap().end, piece.len(), "covers the chunk");
            for s in segments {
                assert!(base + s.end > covered || s.end == 0);
                covered = base + s.end;
                if s.ends_control_frame {
                    cuts.push(base + s.end);
                }
            }
        }
        assert_eq!(cuts, control_ends, "chunk {chunk}");
        assert!(splitter.header.is_empty() && !splitter.in_payload, "ends between frames");
    }
}

#[test]
fn splitter_op_takes_base64() {
    let (bytes, control_ends) = frames();
    let out = call(json!({"op": "splitter.split", "data": base64_encode(&bytes)}));
    let ends: Vec<usize> = out["segments"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|s| s["endsControlFrame"] == json!(true))
        .map(|s| s["end"].as_u64().unwrap() as usize)
        .collect();
    assert_eq!(ends, control_ends);
    assert_eq!(out["segments"].as_array().unwrap().last().unwrap()["end"], json!(bytes.len()));
    assert!(call(json!({"op": "splitter.split", "data": "!"}))["error"].is_string());
}

// MARK: - RemoteCursorTests

#[test]
fn the_cursor_shape_vector_becomes_an_image() {
    let v = vector("cursor_shape");
    let image = cursor::image(0xdead_beef, 2, 1, 1, 0, v["rgba"].as_str().unwrap()).unwrap();
    assert_eq!((image.width, image.height, image.hot_x, image.hot_y), (2, 1, 1, 0));
    let out = call(
        json!({"op": "cursor.image", "shape": 1, "width": 2, "height": 1, "hotX": 9, "hotY": 9, "rgba": v["rgba"]}),
    );
    assert_eq!((out["hotX"].clone(), out["hotY"].clone()), (json!(1), json!(0)), "hotspot clamped");
}

#[test]
fn a_shape_whose_pixels_do_not_match_is_refused() {
    let four = base64_encode(&[0; 4]);
    assert!(cursor::image(1, 2, 1, 0, 0, &four).is_none(), "mismatched pixels");
    assert!(cursor::image(1, 0, 1, 0, 0, "").is_none(), "width 0");
    let big = base64_encode(&vec![0; 257 * 4]);
    assert!(cursor::image(1, 257, 1, 0, 0, &big).is_none(), "side 257");
    let max = base64_encode(&vec![0; 256 * 4]);
    assert!(cursor::image(1, 256, 1, 0, 0, &max).is_some(), "side 256");
    assert!(cursor::image(1, 1, 1, 0, 0, "@@@@").is_none(), "not base64");
}

fn datagram(seq: u32, shape: u32, x: i32, y: i32, flags: u8) -> Vec<u8> {
    let mut d = vec![0u8; 16];
    d[0] = 0x10;
    d[1] = 6;
    d[4..8].copy_from_slice(&seq.to_le_bytes());
    d.extend_from_slice(&shape.to_le_bytes());
    d.extend_from_slice(&x.to_le_bytes());
    d.extend_from_slice(&y.to_le_bytes());
    d.push(flags);
    d
}

fn state(feed: &mut CursorFeed, d: &[u8]) -> CursorState {
    match feed.receive_datagram(d) {
        DatagramResult::State { state } => state,
        other => panic!("{other:?}"),
    }
}

#[test]
fn the_proto_encoder_and_the_feed_agree() {
    let pos = cmux_rd_proto::CursorPos { shape: 5, x: -3, y: 40, visible: true };
    let mut feed = CursorFeed::default();
    let s = state(&mut feed, &pos.datagram(1));
    assert_eq!((s.x, s.y, s.visible, s.shape_hash), (-3, 40, true, Some(5)));
}

#[test]
fn positions_are_latest_wins() {
    let mut feed = CursorFeed::default();
    state(&mut feed, &datagram(10, 0, 1, 1, 1));
    assert_eq!(feed.receive_datagram(&datagram(9, 0, 2, 2, 1)), DatagramResult::Dropped);
    assert_eq!(feed.receive_datagram(&datagram(10, 0, 2, 2, 1)), DatagramResult::Dropped);
    let s = state(&mut feed, &datagram(11, 0, -4, 7, 0));
    assert_eq!((s.x, s.y, s.visible, s.shape_hash, s.shape), (-4, 7, false, None, None));
    // Wraps.
    let mut feed = CursorFeed::default();
    state(&mut feed, &datagram(u32::MAX, 0, 0, 0, 1));
    state(&mut feed, &datagram(0, 0, 0, 0, 1));
}

#[test]
fn malformed_and_other_datagrams() {
    let mut feed = CursorFeed::default();
    assert_eq!(feed.receive_datagram(&[0x10]), DatagramResult::NotCursor);
    let mut video = datagram(1, 0, 0, 0, 1);
    video[1] = 1;
    assert_eq!(feed.receive_datagram(&video), DatagramResult::NotCursor);
    let good = datagram(1, 0, 0, 0, 1);
    assert_eq!(feed.receive_datagram(&good[..28]), DatagramResult::Dropped, "short");
    let mut version = good.clone();
    version[0] = 0x20;
    assert_eq!(feed.receive_datagram(&version), DatagramResult::Dropped, "version 2");
    assert_eq!(
        feed.receive_datagram(&datagram(1, 0, 0, 0, 2)),
        DatagramResult::Dropped,
        "unknown flag"
    );
    assert_eq!(feed.seq, None, "nothing applied");
}

#[test]
fn a_late_shape_updates_the_state_that_named_it_and_the_old_shape_stays_meanwhile() {
    let mut feed = CursorFeed::default();
    assert_eq!(feed.receive_shape(1).state, None);
    assert_eq!(state(&mut feed, &datagram(1, 1, 0, 0, 1)).shape, Some(1));
    // Shape 2 named before it arrives: keep wearing 1.
    let s = state(&mut feed, &datagram(2, 2, 5, 5, 1));
    assert_eq!((s.shape_hash, s.shape), (Some(2), Some(1)));
    let r = feed.receive_shape(2);
    assert_eq!(r.state.map(|s| (s.shape, s.x)), Some((Some(2), 5)));
    // The same shape again changes nothing.
    assert_eq!(feed.receive_shape(2).state, None);
    // Shape 0: no shape.
    assert_eq!(state(&mut feed, &datagram(3, 0, 0, 0, 1)).shape, None);
}

#[test]
fn the_shape_cache_keeps_64_oldest_out_first() {
    let mut feed = CursorFeed::default();
    for id in 1..=64 {
        assert_eq!(feed.receive_shape(id).evicted, None);
    }
    assert_eq!(feed.receive_shape(1).evicted, None, "already cached");
    assert_eq!(feed.receive_shape(65).evicted, Some(1));
    assert!(!feed.has_shape(1) && feed.has_shape(65));
    let s = state(&mut feed, &datagram(1, 1, 0, 0, 1));
    assert_eq!((s.shape_hash, s.shape), (Some(1), None));
}

#[test]
fn cursor_feed_ops() {
    let out = call(json!({"op": "cursorFeed.shape", "id": 7}));
    let out = call(
        json!({"op": "cursorFeed.datagram", "state": out["state"], "data": base64_encode(&datagram(1, 7, 3, 4, 1))}),
    );
    assert_eq!(
        out["result"],
        json!({"kind": "state", "state": {"x": 3, "y": 4, "visible": true, "shapeHash": 7, "shape": 7}})
    );
    let out = call(
        json!({"op": "cursorFeed.datagram", "state": out["state"], "data": base64_encode(&datagram(1, 7, 3, 4, 1))}),
    );
    assert_eq!(out["result"], json!({"kind": "dropped"}));
}

// MARK: - RemoteRdSurfaceStreamsTests

#[test]
fn surface_bodies_parse_as_show_and_hide() {
    let show = |body: Value| SurfaceChange::parse(&body);
    assert_eq!(
        show(json!({"t": "rb.surface.show", "surface": 3, "stream": 4})),
        Some(SurfaceChange::Show { surface: 3, stream: 4 })
    );
    assert_eq!(
        show(json!({"t": "rb.surface.show", "surface": 3.0, "stream": 4.0})),
        Some(SurfaceChange::Show { surface: 3, stream: 4 })
    );
    assert_eq!(
        show(json!({"t": "rb.surface.show", "surface": 3, "stream": 0})),
        None,
        "stream 0 is the page"
    );
    assert_eq!(show(json!({"t": "rb.surface.show", "surface": 3, "stream": 4.5})), None);
    assert_eq!(show(json!({"t": "rb.surface.show", "surface": -1, "stream": 4})), None);
    assert_eq!(show(json!({"t": "rb.surface.show", "surface": 3, "stream": 70000})), None);
    assert_eq!(show(json!({"t": "rb.surface.show", "surface": 3})), None);
    assert_eq!(
        show(json!({"t": "rb.surface.hide", "surface": 3})),
        Some(SurfaceChange::Hide { surface: 3 })
    );
    assert_eq!(show(json!({"t": "rb.open", "surface": 3})), None);
    assert_eq!(show(json!(null)), None);
}

#[test]
fn a_resized_surface_moves_streams_and_hide_closes() {
    let mut s = SurfaceStreams::default();
    assert_eq!(
        s.apply(SurfaceChange::Show { surface: 1, stream: 4 }),
        SurfacePlan { close: vec![], open: Some(4) }
    );
    s.start(4, 1);
    assert_eq!(
        s.apply(SurfaceChange::Show { surface: 1, stream: 4 }),
        SurfacePlan { close: vec![], open: Some(4) }
    );
    assert_eq!(
        s.apply(SurfaceChange::Show { surface: 1, stream: 5 }),
        SurfacePlan { close: vec![4], open: Some(5) }
    );
    s.start(5, 1);
    s.start(6, 2);
    assert_eq!(
        s.apply(SurfaceChange::Hide { surface: 1 }),
        SurfacePlan { close: vec![5], open: None }
    );
    assert_eq!(s.apply(SurfaceChange::Hide { surface: 9 }), SurfacePlan::default());
    assert_eq!(s.end_all(), vec![6]);
    let out = call(json!({"op": "surfaces.apply", "change": {"kind": "hide", "surface": 1}}));
    assert_eq!(out, json!({"state": {"open": []}, "plan": {"close": [], "open": null}}));
    let out = call(json!({"op": "surfaces.start", "stream": 3, "surface": 8}));
    assert_eq!(out["state"], json!({"open": [{"stream": 3, "surface": 8}]}));
    let out = call(json!({"op": "surfaces.endAll", "state": out["state"]}));
    assert_eq!(out["ended"], json!([3]));
}
