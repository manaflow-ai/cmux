use super::*;

#[test]
fn the_answer_goes_at_the_first_host_candidate_not_after_stun_and_turn() {
    use cmux_rd_link::net::CandidateKind;
    let mut gate = AnswerGate::default();
    assert!(!gate.due(), "nothing known yet");
    gate.candidate(CandidateKind::Host);
    assert!(gate.due(), "a host candidate is enough to answer");
    // Reflexive, relayed and the end of gathering come later and trickle: no second answer.
    gate.candidate(CandidateKind::ServerReflexive);
    gate.candidate(CandidateKind::Relay);
    gate.gathered();
    assert!(!gate.due());
    // Relay only: no host candidate, so the answer waits for gathering to end.
    let mut relay_only = AnswerGate::default();
    relay_only.candidate(CandidateKind::Relay);
    assert!(!relay_only.due());
    relay_only.gathered();
    assert!(relay_only.due());
}

#[test]
fn serve_preserves_frame_boundaries_before_the_link_connects() {
    let local = KeyPair::generate().unwrap();
    let peer = KeyPair::generate().unwrap();
    let net = Net::start(NetConfig {
        role: Role::Responder,
        session: b"serve-queue-test".to_vec(),
        local,
        expected_remote: peer.public,
        stun: Vec::new(),
        bind: "127.0.0.1:0".parse().unwrap(),
        turn: Vec::new(),
        relay_only: false,
    })
    .unwrap();
    let mut carrier = ServeCarrier {
        link: LinkCarrier::new(
            net,
            crate::wg_carrier::Role::Host,
            crate::carrier::LinkMode::Legacy,
        )
        .unwrap(),
        app: AppLines { buf: Vec::new() },
    };
    carrier.send_datagram_frame(vec![vec![1], vec![2]], true).unwrap();
    carrier.send_datagram_frame(vec![vec![3]], true).unwrap();
    let stats = carrier.media_queue_stats().unwrap();
    assert_eq!(stats.queue_frames, 1);
    assert_eq!(stats.queue_datagrams, 1);
    assert_eq!(stats.dropped_replaced_frames, 1);
    assert_eq!(stats.dropped_replaced_datagrams, 2);
}

#[test]
fn clipboard_sync_is_off_unless_the_setup_turns_it_on() {
    let base =
        r#"{"session":"s","peer_key":"00","viewer":{"user":"u","install":"i"},"scope":"control"}"#;
    let off: Setup = serde_json::from_str(base).expect("setup");
    assert!(!off.clipboard);
    let on = r#"{"session":"s","peer_key":"00","viewer":{"user":"u","install":"i"},"scope":"control","clipboard":true}"#;
    let on: Setup = serde_json::from_str(on).expect("setup");
    assert!(on.clipboard);
}

/// A writer that keeps what reached it only at a flush, as a pipe's reader sees it.
#[derive(Default)]
struct Piped {
    pending: Vec<u8>,
    flushed: Vec<u8>,
}

impl Write for Piped {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.pending.extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        self.flushed.append(&mut self.pending);
        Ok(())
    }
}

#[test]
fn every_app_line_reaches_the_pipe_whole_and_flushed() {
    let mut out = Piped::default();
    let lines = [
        AppLine { displays: Some(vec![(1920, 1080)]), current: Some(0), ..AppLine::default() },
        AppLine { key: Some("ab".repeat(32)), ..AppLine::default() },
        AppLine { candidate: Some("host 192.168.1.4:51000".into()), ..AppLine::default() },
        AppLine { candidates_done: true, ..AppLine::default() },
    ];
    for (i, line) in lines.iter().enumerate() {
        write_line(&mut out, line).unwrap();
        // Nothing waits in a buffer: the reader has every line so far, each ended by one newline.
        assert!(out.pending.is_empty());
        let read: Vec<&[u8]> =
            out.flushed.split(|b| *b == b'\n').filter(|l| !l.is_empty()).collect();
        assert_eq!(read.len(), i + 1);
        assert_eq!(AppLine::decode(read[i]).as_ref(), Some(line));
    }
    assert_eq!(out.flushed.last(), Some(&b'\n'));
}

#[test]
fn the_viewers_profile_wins_and_standard_is_the_default() {
    let setup = |profile: Option<&str>| -> Setup {
        let mut line = serde_json::json!({
            "session": "s1", "peer_key": "ab".repeat(32),
            "viewer": {"user": "v", "install": "v"}, "scope": "view",
        });
        if let Some(p) = profile {
            line["encode_profile"] = p.into();
        }
        serde_json::from_value(line).unwrap()
    };
    let flags = |args: &[&str]| {
        Opts::parse(&args.iter().map(|s| s.to_string()).collect::<Vec<_>>()).unwrap()
    };
    let none = flags(&[]);
    let ultra_flag = flags(&["--encode-profile", "ultra"]);
    // An old viewer sends no profile: the flag decides, else standard.
    assert_eq!(session_profile(&none, &setup(None)), Ok(EncodeProfile::Standard));
    assert_eq!(session_profile(&ultra_flag, &setup(None)), Ok(EncodeProfile::Ultra));
    // The person's choice in the viewer wins over the host's flag, either way.
    assert_eq!(session_profile(&none, &setup(Some("ultra"))), Ok(EncodeProfile::Ultra));
    assert_eq!(session_profile(&ultra_flag, &setup(Some("standard"))), Ok(EncodeProfile::Standard));
    // A profile this host does not know still streams, as standard.
    assert_eq!(session_profile(&ultra_flag, &setup(Some("hyper"))), Ok(EncodeProfile::Standard));
}

#[test]
fn portal_sessions_control_only_with_a_remote_desktop_grant() {
    // Without the grant the portal drops input: a control session there would not be one.
    let x11 = CaptureBackend::X11.applies_input_with(false);
    assert!(view_only_for("view", x11).unwrap());
    assert!(!view_only_for("control", x11).unwrap());
    let portal = CaptureBackend::Portal.applies_input_with(false);
    assert!(view_only_for("view", portal).unwrap());
    assert!(view_only_for("control", portal).unwrap());
    let granted = CaptureBackend::Portal.applies_input_with(true);
    assert!(view_only_for("view", granted).unwrap());
    assert!(!view_only_for("control", granted).unwrap());
    assert!(view_only_for("full", x11).is_err());
}

#[test]
fn a_lan_path_starts_at_the_lan_bitrate() {
    assert_eq!(default_start_kbps(Some("direct_lan"), None, None, 50_000), 30_000);
    assert_eq!(default_start_kbps(Some("direct_wan"), Some("lan"), None, 50_000), 30_000);
    assert_eq!(default_start_kbps(Some("direct_wan"), Some("link"), None, 50_000), 30_000);
    // A peer learned in the handshake is classed WAN; a sub-10 ms round trip is LAN.
    assert_eq!(default_start_kbps(Some("direct_wan"), None, Some(1_200), 50_000), 30_000);
    assert_eq!(default_start_kbps(None, None, Some(9_999), 50_000), 30_000);
}

#[test]
fn other_paths_keep_the_old_start_and_max_caps_both() {
    assert_eq!(default_start_kbps(None, None, None, 50_000), 8_000);
    assert_eq!(default_start_kbps(Some("direct_wan"), Some("routed"), Some(10_000), 50_000), 8_000);
    assert_eq!(default_start_kbps(Some("direct_wan"), None, Some(40_000), 50_000), 8_000);
    // A relay is never LAN, whatever its round trip.
    assert_eq!(default_start_kbps(Some("turn_relay"), Some("lan"), Some(1_000), 50_000), 8_000);
    assert_eq!(default_start_kbps(Some("direct_lan"), None, None, 20_000), 20_000);
    assert_eq!(default_start_kbps(None, None, None, 4_000), 4_000);
}

#[test]
fn later_lines_carry_the_excluded_windows() {
    let later: Later = serde_json::from_str(r#"{"exclude_windows":[123,456]}"#).unwrap();
    assert_eq!(later.exclude_windows, Some(vec![123, 456]));
    assert!(!later.stop && later.candidate.is_none());
    let emptied: Later = serde_json::from_str(r#"{"exclude_windows":[]}"#).unwrap();
    assert_eq!(emptied.exclude_windows, Some(Vec::new()));
    let stop: Later = serde_json::from_str(r#"{"stop":true}"#).unwrap();
    assert_eq!(stop.exclude_windows, None);
}

#[test]
fn the_capturing_line_names_the_pick_the_source_and_the_applied_mode() {
    let setup: Setup = serde_json::from_str(
        r#"{"session":"s","peer_key":"00","viewer":{"user":"u","install":"i"},"scope":"view","display":"2","max_width":480}"#,
    )
    .expect("setup");
    let line = capturing_line(&setup, Some([960, 0, 960, 1080]), (480, 540), Mode::View);
    assert_eq!(
        line.to_json(),
        r#"{"capturing":{"source":"display","display":"2","window":null,"rect":[960,0,960,1080],"width":480,"height":540,"max_width":480,"mode":"view","scope":"view"}}"#
    );
    let window: Setup = serde_json::from_str(
        r#"{"session":"s","peer_key":"00","viewer":{"user":"u","install":"i"},"scope":"control","window":4194305}"#,
    )
    .expect("setup");
    let line = capturing_line(&window, None, (800, 600), Mode::Control);
    let got = line.capturing.expect("capturing");
    assert_eq!(
        (got.source.as_str(), got.window, got.mode.as_str()),
        ("window", Some(4194305), "control")
    );
}
