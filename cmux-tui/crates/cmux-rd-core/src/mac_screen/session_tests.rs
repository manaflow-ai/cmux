use super::*;
use cmux_rd_proto::app_line::LinePath;

const KEY: &str = "abababababababababababababababababababababababababababababababab";

fn connected() -> (Session, Vec<Effect>) {
    let mut s = Session::new();
    let fx = s.apply(Event::Connect { signaling: true, process_started: true });
    (s, fx)
}

fn line(f: impl FnOnce(&mut AppLine)) -> Event {
    let mut line = AppLine::default();
    f(&mut line);
    Event::ProcessLine { line: Box::new(line), inputs: OfferInputs::default() }
}

fn answer_text(f: impl FnOnce(&mut RdDocument)) -> String {
    let mut doc = RdDocument { key: "cd".repeat(32), ..RdDocument::default() };
    f(&mut doc);
    doc.text()
}

fn streaming() -> Event {
    Event::Transport { state: TransportState::Streaming, rtt_ms: Some(4.0), stream_size: None }
}

/// MacScreenHostEndTests.theHostsFailedEndKeepsItsReason
#[test]
fn the_hosts_failed_end_keeps_its_reason() {
    assert_eq!(
        host_end("failed: capture: no frame"),
        HostEnd::HostFailed("capture: no frame".into())
    );
    assert_eq!(host_end("failed"), HostEnd::HostFailed(String::new()));
    assert_eq!(host_end("stopped by the host"), HostEnd::HostStoppedSharing);
    assert_eq!(host_end("failedness"), HostEnd::HostStoppedSharing);
}

/// MacScreenHostEndTests.theLinkBridgesEndNamesWhoFailed
#[test]
fn the_link_bridges_end_names_who_failed() {
    let cause = failure_cause_of_ended;
    assert_eq!(
        cause("host: failed: capture: denied"),
        Some(FailureCause::Host("capture: denied".into()))
    );
    assert_eq!(cause("host: stopped by the host"), None);
    assert_eq!(
        cause("link failed: no route (2 routes)"),
        Some(FailureCause::Link("no route (2 routes)".into()))
    );
    assert_eq!(cause("failed: pane socket"), Some(FailureCause::Link("pane socket".into())));
    assert_eq!(cause("the host ended the session"), None);
    assert_eq!(cause("stopped by the viewer"), None);
}

#[test]
fn path_kinds_label_and_relay() {
    assert_eq!(path_label(Some("direct_lan")).unwrap().text, "Direct (local network)");
    assert_eq!(
        path_label(Some("direct_wan")).unwrap().key.as_deref(),
        Some("macScreen.rd.pathDirect")
    );
    for kind in ["turn_relay", "do_relay", "via_cloud_region"] {
        assert_eq!(path_label(Some(kind)).unwrap().text, "Relayed");
    }
    assert_eq!(path_label(Some("tailnet")), None);
    assert_eq!(path_label(None), None);
}

#[test]
fn a_connect_without_a_ticket_or_a_viewer_fails_with_its_words() {
    let mut s = Session::new();
    s.apply(Event::Connect { signaling: false, process_started: false });
    assert_eq!(s.phase, Phase::failed(Message::no_ticket()));
    s.apply(Event::Connect { signaling: true, process_started: false });
    assert_eq!(s.phase, Phase::failed(Message::no_binary()));
    let (s, fx) = connected();
    assert_eq!(s.phase, Phase::Connecting);
    assert_eq!(fx, [Effect::Teardown, Effect::ScheduleDeadline { ms: 15_000 }]);
}

/// The offer waits for the socket's hello; the answer goes to the link process once, and a
/// candidate trickled before it waits until the process has it.
#[test]
fn the_offer_waits_for_hello_and_candidates_wait_for_the_answer() {
    let (mut s, _) = connected();
    assert!(s.apply(line(|l| l.key = Some(KEY.into()))).is_empty());
    assert_eq!(s.stats.target_fps, Some(60));
    let fx = s.apply(Event::Hello);
    let [Effect::SendOffer { text }] = fx.as_slice() else { panic!("{fx:?}") };
    assert!(text.starts_with("cmux.rd/1\r\n") && text.contains(KEY));
    // A second key line makes no second offer.
    assert!(s.apply(line(|l| l.key = Some(KEY.into()))).is_empty());
    let early = Event::Candidate { candidate: "c1".into(), sdp_mid: Some("cmux-rd".into()) };
    assert!(s.apply(early).is_empty());
    assert!(
        s.apply(Event::Candidate { candidate: "x".into(), sdp_mid: Some("0".into()) }).is_empty()
    );
    let fx = s.apply(Event::Answer { text: answer_text(|d| d.candidates = vec!["h".into()]) });
    assert_eq!(
        fx,
        [
            Effect::Reached { stage: Stage::Link },
            Effect::SendAnswer { peer_key: "cd".repeat(32), candidates: vec!["h".into()] }
        ]
    );
    assert_eq!(s.apply(Event::AnswerHanded), [Effect::ProcessCandidate { candidate: "c1".into() }]);
    let late = Event::Candidate { candidate: "c2".into(), sdp_mid: Some("cmux-rd".into()) };
    assert_eq!(s.apply(late), [Effect::ProcessCandidate { candidate: "c2".into() }]);
    // A repeated answer is not handed again, and the stage never moves back.
    assert!(s.apply(Event::Answer { text: answer_text(|_| {}) }).is_empty());
    assert!(matches!(
        s.apply(Event::Answer { text: "v=0".into() }).as_slice(),
        [Effect::BadAnswer]
    ));
}

#[test]
fn an_open_socket_sends_the_offer_at_once() {
    let (mut s, _) = connected();
    s.apply(Event::Hello);
    let fx = s.apply(line(|l| l.key = Some(KEY.into())));
    assert!(matches!(fx.as_slice(), [Effect::SendOffer { .. }]));
}

/// MacScreenConnectDeadlineTests: the deadline fails naming the stage; a picture cancels it.
#[test]
fn the_deadline_names_the_stage_and_a_picture_cancels_it() {
    let (mut s, _) = connected();
    s.apply(Event::DeadlinePassed);
    assert_eq!(s.timed_out_stage, Some(Stage::Answer));
    let Phase::Failed { message, .. } = &s.phase else { panic!() };
    assert_eq!(message.key.as_deref(), Some("macScreen.card.noAnswer"));
    assert!(message.names_host);

    let (mut s, _) = connected();
    s.apply(Event::Answer { text: answer_text(|_| {}) });
    s.apply(line(|l| l.connected = true));
    assert!(s.link_connected);
    s.apply(Event::DeadlinePassed);
    assert_eq!(s.timed_out_stage, Some(Stage::Frame));

    let (mut s, _) = connected();
    let fx =
        s.apply(Event::FramePresented { size: Size { width: 10.0, height: 5.0 }, now_ms: 0.0 });
    assert_eq!(fx, [Effect::Reached { stage: Stage::Shown }, Effect::CancelDeadline]);
    assert!(s.apply(Event::DeadlinePassed).is_empty());
    assert_eq!(s.phase, Phase::Connecting);
    // A new connect starts over.
    s.apply(Event::Connect { signaling: true, process_started: true });
    assert_eq!(
        (s.connect_stage, s.timed_out_stage, s.frame_size),
        (Stage::Answer, None, Size::default())
    );
}

#[test]
fn streaming_asks_one_keyframe_and_connects() {
    let (mut s, _) = connected();
    let fx = s.apply(streaming());
    assert_eq!(
        fx,
        [
            Effect::RequestKeyframe,
            Effect::Reached { stage: Stage::Frame },
            Effect::SampleRtt { ms: Some(4.0) }
        ]
    );
    assert_eq!((s.phase.clone(), s.stats.latency_ms), (Phase::Connected, Some(4.0)));
    assert_eq!(s.apply(streaming()), [Effect::SampleRtt { ms: Some(4.0) }]);
    let size = Some(Size { width: 1920.0, height: 1080.0 });
    s.apply(Event::Transport {
        state: TransportState::Connecting,
        rtt_ms: None,
        stream_size: size,
    });
    assert_eq!(Some(s.stream_size), size);
}

/// An end after the picture is a plain end; before it, a failure; the host's failure is
/// always a failure with its reason.
#[test]
fn transport_ends_read_like_the_mac() {
    let (mut s, _) = connected();
    s.apply(streaming());
    s.apply(Event::Transport {
        state: TransportState::Ended { why: TransportEnd::HostStoppedSharing },
        rtt_ms: None,
        stream_size: None,
    });
    assert_eq!(s.phase, Phase::Ended);

    let (mut s, _) = connected();
    s.apply(Event::Bye);
    assert_eq!(s.phase, Phase::failed(Message::host_ended()));

    let (mut s, _) = connected();
    s.apply(streaming());
    let host = TransportEnd::HostFailed { reason: "capture".into() };
    s.apply(Event::Transport {
        state: TransportState::Ended { why: host },
        rtt_ms: None,
        stream_size: None,
    });
    assert_eq!(s.phase, Phase::failed(Message::said("capture")));
    assert_eq!(s.failure_cause, Some(FailureCause::Host("capture".into())));

    let (mut s, _) = connected();
    s.apply(streaming());
    let lost = TransportState::Ended { why: TransportEnd::ConnectionLost };
    s.apply(Event::Transport { state: lost, rtt_ms: None, stream_size: None });
    assert_eq!(s.phase, Phase::failed(Message::lost()));
}

#[test]
fn the_links_ended_line_names_who_failed() {
    let (mut s, _) = connected();
    s.apply(line(|l| l.ended = Some("link failed: no route".into())));
    assert_eq!(s.phase, Phase::failed(Message::said("link failed: no route")));
    assert_eq!(s.failure_cause, Some(FailureCause::Link("no route".into())));

    let (mut s, _) = connected();
    s.apply(streaming());
    s.apply(line(|l| l.ended = Some("failed: pane socket".into())));
    assert_eq!(
        (s.phase.clone(), s.failure_cause.clone()),
        (Phase::Ended, None),
        "after the picture"
    );

    let (mut s, _) = connected();
    s.apply(streaming());
    s.apply(line(|l| l.ended = Some("host: failed: capture: denied".into())));
    assert_eq!(s.failure_cause, Some(FailureCause::Host("capture: denied".into())));

    let (mut s, _) = connected();
    s.apply(line(|l| l.ended = Some("stopped by the viewer".into())));
    assert_eq!(
        (s.phase.clone(), s.failure_cause.clone()),
        (Phase::failed(Message::said("stopped by the viewer")), None)
    );
    // A new connect forgets the cause.
    s.apply(Event::Connect { signaling: true, process_started: true });
    assert_eq!(s.failure_cause, None);
}

#[test]
fn process_and_signaling_ends_fail_only_while_connecting() {
    let (mut s, _) = connected();
    s.apply(Event::ProcessExited { stderr_tail: String::new() });
    assert_eq!(s.phase, Phase::failed(Message::viewer_stopped()));
    let (mut s, _) = connected();
    s.apply(Event::ProcessExited { stderr_tail: "boom".into() });
    assert_eq!(s.phase, Phase::failed(Message::said("boom")));
    let (mut s, _) = connected();
    s.apply(streaming());
    assert!(s.apply(Event::ProcessExited { stderr_tail: "boom".into() }).is_empty());
    assert!(s.apply(Event::SignalingFailed).is_empty());
    assert_eq!(s.phase, Phase::Connected);
    s.apply(Event::OfferFailed);
    assert_eq!(s.phase, Phase::failed(Message::signaling_failed()));
}

#[test]
fn the_path_line_labels_signals_and_samples() {
    let (mut s, _) = connected();
    let fx = s.apply(line(|l| {
        l.path = Some(LinePath { kind: Some("turn_relay".into()), rtt_ms: Some(30.0) });
        l.candidate = Some("srflx".into());
        l.listening = true;
    }));
    assert_eq!(
        fx,
        [
            Effect::SignalCandidate { candidate: "srflx".into() },
            Effect::AttachTransport,
            Effect::SampleRtt { ms: Some(30.0) },
            Effect::SignalPath { relay: true }
        ]
    );
    assert_eq!(s.path_label().unwrap().text, "Relayed");
    assert_eq!(s.stats.latency_ms, Some(30.0));
}

/// The run's linked display: asked for by id until a pick; a host that lacks it says so.
#[test]
fn the_linked_display_is_asked_for_until_a_pick() {
    let (mut s, _) = connected();
    s.apply(Event::LinkDisplay { id: Some(77) });
    s.apply(Event::Hello);
    let fx = s.apply(line(|l| l.key = Some(KEY.into())));
    let [Effect::SendOffer { text }] = fx.as_slice() else { panic!() };
    assert!(text.contains("a=cmux-rd-display-id:77\r\n"));
    let fx = s.apply(Event::Answer {
        text: answer_text(|d| {
            d.displays = vec![(100, 50), (200, 100)];
            d.display_ids = vec![1, 2];
            d.current_display = Some(1);
        }),
    });
    assert!(
        fx.contains(&Effect::StreamDisplays { displays: vec![(100, 50), (200, 100)], current: 1 })
    );
    assert!(s.linked_display_gone);
    assert_eq!(s.apply(Event::SelectDisplay { index: 1 }), [Effect::Restart]);
    assert_eq!((s.wanted_display, s.linked_display, s.linked_display_gone), (Some(1), None, false));
    s.apply(Event::Disconnect);
    assert_eq!(s.phase, Phase::Ended);
    assert!(s.apply(Event::ApplyQuality).is_empty(), "no session to restart");
}

#[test]
fn frames_count_once_a_second() {
    let (mut s, _) = connected();
    let size = Size { width: 100.0, height: 50.0 };
    for i in 0..30 {
        s.apply(Event::FramePresented { size, now_ms: f64::from(i) * 30.0 });
    }
    assert_eq!(s.stats.fps, 0.0);
    s.apply(Event::FramePresented { size, now_ms: 1250.0 });
    assert!((s.stats.fps - 31.0 / 1.25).abs() < 1e-9);
    assert_eq!((s.stats.frames_decoded, s.frame_size), (31.0, size));
    s.apply(Event::HostStats {
        kbps: 8000.0,
        loss_percent: Some(1.5),
        encode_ms_p50: None,
        encode_profile: Some("ultra".into()),
    });
    assert_eq!((s.stats.host_kbps, s.stats.kilobytes_per_second), (Some(8000.0), 1000.0));
}

#[test]
fn the_state_and_events_speak_json() {
    let (s, _) = connected();
    let json = serde_json::to_value(&s).unwrap();
    assert_eq!(json["phase"], "connecting");
    assert_eq!(json["connect_stage"], "answer");
    let event: Event = serde_json::from_value(serde_json::json!({
        "event": "transport", "state": "ended", "why": "host_failed", "reason": "x"
    }))
    .unwrap();
    assert_eq!(
        event,
        Event::Transport {
            state: TransportState::Ended { why: TransportEnd::HostFailed { reason: "x".into() } },
            rtt_ms: None,
            stream_size: None
        }
    );
    let line: Event = serde_json::from_value(serde_json::json!({
        "event": "process_line", "line": {"key": KEY}, "inputs": {"quality": "high", "refresh": 120}
    }))
    .unwrap();
    let mut s = Session::new();
    s.apply(Event::Connect { signaling: true, process_started: true });
    s.apply(Event::Hello);
    let fx = s.apply(line);
    let [Effect::SendOffer { text }] = fx.as_slice() else { panic!() };
    assert!(text.contains("a=cmux-rd-max-fps:60\r\n") && !text.contains("max-width"));
    let failed = serde_json::to_value(Phase::failed(Message::lost())).unwrap();
    assert_eq!(failed["phase"], "failed");
    assert_eq!(failed["message"]["key"], "macScreen.rd.lost");
}
