use super::*;
use cmux_rd_proto::app_line::LinePath;

fn session() -> HostSession {
    HostSession {
        id: "s1".into(),
        viewer_id: "v1".into(),
        view_only: true,
        stun: vec!["stun.example:3478".into()],
        turn: vec![Turn {
            addr: "t:3478".into(),
            username: "u".into(),
            password: "p".into(),
            transport: Default::default(),
        }],
    }
}

fn offer() -> String {
    RdDocument {
        key: "ab".repeat(32),
        candidates: vec!["c1".into()],
        display: Some(1),
        max_fps: Some(240),
        max_kbps: Some(9000),
        cursor: Some(false),
        ..RdDocument::default()
    }
    .text()
}

fn line(f: impl FnOnce(&mut AppLine)) -> HostInput {
    let mut line = AppLine::default();
    f(&mut line);
    HostInput::ProcessLine { line: Box::new(line) }
}

fn started() -> Host {
    let mut host = Host::new(session());
    host.apply(HostInput::Offer { text: offer() });
    host.apply(HostInput::ServeStarted { error: None });
    host
}

#[test]
fn a_cmux_rd_offer_starts_serve_with_its_setup_and_candidates() {
    let mut host = Host::new(session());
    assert_eq!(host.apply(HostInput::Offer { text: offer() }), [HostEffect::StartServe]);
    let fx = host.apply(HostInput::ServeStarted { error: None });
    let setup = serde_json::json!({
        "session": "s1", "peer_key": "ab".repeat(32), "viewer": {"user": "v1", "install": "v1"},
        "scope": "view", "stun": ["stun.example:3478"],
        "turn": [{"addr": "t:3478", "username": "u", "password": "p"}],
        "display": "1", "max_fps": 120, "max_kbps": 9000, "cursor": false
    });
    assert_eq!(
        fx,
        [
            HostEffect::ScheduleAnswerDeadline { ms: 15_000 },
            HostEffect::ProcessSend { line: setup },
            HostEffect::WatchExclusions,
            HostEffect::ProcessSend { line: serde_json::json!({"candidate": "c1"}) },
        ]
    );
    assert_eq!(
        host.apply(HostInput::Offer { text: offer() }),
        [HostEffect::OfferIgnored { why: "already serving".into() }]
    );
    let late = HostInput::Candidate { candidate: "c2".into(), sdp_mid: Some("cmux-rd".into()) };
    assert_eq!(
        host.apply(late),
        [HostEffect::ProcessSend { line: serde_json::json!({"candidate": "c2"}) }]
    );
    assert!(
        host.apply(HostInput::Candidate { candidate: "x".into(), sdp_mid: Some("0".into()) })
            .is_empty()
    );
}

#[test]
fn the_main_display_and_control_scope_are_the_defaults() {
    let offer = RdDocument { key: "k".into(), ..RdDocument::default() };
    let s = setup(&HostSession { view_only: false, ..session() }, &offer);
    assert_eq!((s.display.as_str(), s.scope.as_str(), s.max_fps), ("main", "control", None));
    let json = serde_json::to_value(&s).unwrap();
    assert!(json.get("cursor").is_none() && json.get("encode_profile").is_none());
}

#[test]
fn a_webrtc_offer_forwards_every_later_signal() {
    let mut host = Host::new(session());
    assert_eq!(host.apply(HostInput::Offer { text: "v=0\r\n".into() }), [HostEffect::ServeWebRtc]);
    assert!(host.web_rtc && !host.process_started);
    for input in [
        HostInput::Offer { text: offer() },
        HostInput::Candidate { candidate: "c".into(), sdp_mid: Some("cmux-rd".into()) },
        HostInput::Other,
        HostInput::Bye,
    ] {
        assert_eq!(host.apply(input), [HostEffect::Forward]);
    }
}

#[test]
fn the_answer_waits_for_candidates_done_and_later_candidates_trickle() {
    let mut host = started();
    assert!(
        host.apply(line(|l| {
            l.displays = Some(vec![(100, 50)]);
            l.current = Some(0);
        }))
        .is_empty()
    );
    assert!(host.apply(line(|l| l.key = Some("cd".repeat(32)))).is_empty());
    assert!(host.apply(line(|l| l.candidate = Some("h1".into()))).is_empty());
    let fx = host.apply(line(|l| l.candidates_done = true));
    let [HostEffect::CancelAnswerDeadline, HostEffect::SendAnswer { text }] = fx.as_slice() else {
        panic!("{fx:?}")
    };
    let answer = RdDocument::parse(text).unwrap();
    assert_eq!(
        (answer.key, answer.candidates, answer.displays, answer.current_display),
        ("cd".repeat(32), vec!["h1".to_owned()], vec![(100, 50)], Some(0))
    );
    assert!(host.apply(line(|l| l.candidates_done = true)).is_empty(), "one answer");
    assert_eq!(
        host.apply(line(|l| l.candidate = Some("srflx".into()))),
        [HostEffect::SendCandidate { candidate: "srflx".into() }]
    );
    assert!(host.apply(HostInput::AnswerTimedOut).is_empty(), "answered");
}

#[test]
fn connected_path_and_ended_read_like_the_mac() {
    let mut host = started();
    let fx = host.apply(line(|l| {
        l.connected = true;
        l.path = Some(LinePath { kind: Some("direct_lan".into()), rtt_ms: None });
    }));
    assert_eq!(
        fx,
        [
            HostEffect::Emit { event: HostEvent::ViewerConnected },
            HostEffect::SendPath { relay: false }
        ]
    );
    assert!(host.apply(line(|l| l.connected = true)).is_empty());
    let fx = host.apply(line(|l| l.ended = Some("the viewer left".into())));
    assert_eq!(fx, [HostEffect::Emit { event: HostEvent::ViewerEnded("the viewer left".into()) }]);
    assert!(host.apply(line(|l| l.connected = true)).is_empty(), "no lines after ended");
    assert!(
        host.apply(HostInput::ProcessExited { stderr_tail: String::new(), cancelled: false })
            .is_empty()
    );

    let mut host = started();
    let fx = host.apply(line(|l| l.ended = Some("capture: denied".into())));
    assert_eq!(fx, [HostEffect::Emit { event: HostEvent::SourceFailed("capture: denied".into()) }]);
}

#[test]
fn a_host_that_dies_or_never_answers_fails_with_its_words() {
    let mut host = started();
    let fx = host.apply(HostInput::ProcessExited { stderr_tail: "panic".into(), cancelled: false });
    assert_eq!(
        fx,
        [HostEffect::Emit {
            event: HostEvent::SourceFailed(
                "the screen host exited without saying why: panic".into()
            )
        }]
    );
    let mut host = started();
    assert!(
        host.apply(HostInput::ProcessExited { stderr_tail: String::new(), cancelled: true })
            .is_empty()
    );
    let mut host = started();
    assert_eq!(
        host.apply(HostInput::AnswerTimedOut),
        [
            HostEffect::StopProcess,
            HostEffect::Emit {
                event: HostEvent::SourceFailed("the screen host did not answer".into())
            }
        ]
    );
    let mut host = Host::new(session());
    host.apply(HostInput::Offer { text: offer() });
    assert_eq!(
        host.apply(HostInput::ServeStarted { error: Some("not staged".into()) }),
        [
            HostEffect::Emit {
                event: HostEvent::SourceFailed(
                    "the screen host could not start: not staged".into()
                )
            },
            HostEffect::EndServe
        ]
    );
    let mut host = started();
    assert_eq!(host.apply(HostInput::Bye), [HostEffect::StopProcess, HostEffect::EndServe]);
    assert_eq!(
        host.apply(HostInput::Disconnect),
        [HostEffect::CancelAnswerDeadline, HostEffect::StopProcess]
    );
}

#[test]
fn line_kinds_and_the_stderr_tail() {
    assert_eq!(line_kinds(&AppLine::default()), "unknown");
    let mut l = AppLine { key: Some("k".into()), candidates_done: true, ..AppLine::default() };
    l.ended = Some("x".into());
    assert_eq!(line_kinds(&l), "key candidates_done ended");
    let mut tail = Vec::new();
    push_stderr_tail(&mut tail, &[b'a'; 4000]);
    push_stderr_tail(&mut tail, &[b'b'; 200]);
    assert_eq!(tail.len(), 4096);
    assert_eq!((tail[0], tail[4095]), (b'a', b'b'));
    assert_eq!(tail.iter().filter(|&&c| c == b'b').count(), 200);
}

#[test]
fn inputs_and_effects_speak_json() {
    let input: HostInput = serde_json::from_value(serde_json::json!({
        "input": "process_line", "line": {"key": "k", "candidates_done": true}
    }))
    .unwrap();
    assert!(matches!(input, HostInput::ProcessLine { .. }));
    let fx = serde_json::to_value(HostEffect::Emit { event: HostEvent::ViewerEnded("x".into()) })
        .unwrap();
    assert_eq!(
        fx,
        serde_json::json!({"effect": "emit", "event": {"kind": "viewer_ended", "reason": "x"}})
    );
}
