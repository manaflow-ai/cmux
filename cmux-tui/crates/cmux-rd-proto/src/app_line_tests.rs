use super::*;

#[test]
fn a_line_split_across_two_chunks_comes_out_once_whole() {
    let mut splitter = LineSplitter::default();
    assert!(splitter.push(b"{\"key\":\"ab").is_empty());
    assert_eq!(splitter.pending_len(), 10);
    let lines = splitter.push(b"cd\"}\n{\"connected\":true}\n{\"lis");
    assert_eq!(lines, vec![b"{\"key\":\"abcd\"}".to_vec(), b"{\"connected\":true}".to_vec()]);
    assert_eq!(splitter.pending_len(), 5);
    assert_eq!(splitter.push(b"tening\":true}\n"), vec![b"{\"listening\":true}".to_vec()]);
    assert_eq!(splitter.pending_len(), 0);
}

#[test]
fn an_empty_line_is_a_line() {
    let mut splitter = LineSplitter::default();
    assert_eq!(splitter.push(b"\n\n"), vec![Vec::<u8>::new(), Vec::new()]);
}

#[test]
fn what_the_host_prints_reads_back_the_same() {
    let lines = [
        AppLine { key: Some("ab".repeat(32)), ..AppLine::default() },
        AppLine { candidate: Some("host 192.168.1.4:51000".into()), ..AppLine::default() },
        AppLine { candidates_done: true, ..AppLine::default() },
        AppLine { connected: true, ..AppLine::default() },
        AppLine { listening: true, ..AppLine::default() },
        AppLine {
            path: Some(LinePath { kind: Some("direct_wan".into()), rtt_ms: Some(3.2) }),
            ..AppLine::default()
        },
        AppLine { path: Some(LinePath::default()), ..AppLine::default() },
        AppLine {
            displays: Some(vec![(3024, 1964), (2560, 1440)]),
            current: Some(1),
            ..AppLine::default()
        },
        AppLine {
            displays: Some(Vec::new()),
            current: Some(0),
            error: Some("no screen".into()),
            ..AppLine::default()
        },
        AppLine { ended: Some("the viewer left".into()), ..AppLine::default() },
    ];
    for line in lines {
        assert_eq!(
            AppLine::decode(line.to_json().as_bytes()),
            Some(line.clone()),
            "{}",
            line.to_json()
        );
    }
}

#[test]
fn a_path_prints_null_for_what_it_does_not_know() {
    let line = AppLine { path: Some(LinePath::default()), ..AppLine::default() };
    assert_eq!(line.to_json(), r#"{"path":{"kind":null,"rtt_ms":null}}"#);
}

#[test]
fn unknown_fields_read_as_an_empty_line_and_other_text_reads_as_none() {
    assert_eq!(AppLine::decode(br#"{"newer":1}"#), Some(AppLine::default()));
    assert_eq!(AppLine::decode(b"not json"), None);
    assert_eq!(AppLine::decode(b"[1,2]"), None);
    assert_eq!(AppLine::decode(br#"{"connected":"yes"}"#), None);
}

#[test]
fn fallback_decision_round_trips_and_rejects_authorization_failures() {
    let line = AppLine {
        fallback: Some(CarrierFallback {
            carrier: CarrierKind::RdWg,
            reason: WgFallbackReason::Timeout,
            retry: RetryCarrier::WebRtc,
        }),
        ..AppLine::default()
    };
    assert_eq!(
        line.to_json(),
        r#"{"fallback":{"carrier":"rd_wg","reason":"timeout","retry":"web_rtc"}}"#
    );
    assert_eq!(AppLine::decode(line.to_json().as_bytes()), Some(line));
    for reason in ["revoked", "consent_denied", "peer_mismatch", "unknown"] {
        let input = format!(
            r#"{{"fallback":{{"carrier":"rd_wg","reason":"{reason}","retry":"web_rtc"}}}}"#
        );
        assert_eq!(AppLine::decode(input.as_bytes()), None);
    }
}
