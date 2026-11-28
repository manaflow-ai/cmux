use super::*;
use crate::{ByteString, ProcessEvent, ProcessId, ProcessReplayRange, RpcEvent};

#[test]
fn known_process_event_types_match_the_serde_tags() {
    let process = ProcessId::from_u128(1);
    let data = ByteString::from_bytes(b"x");
    let events = [
        ProcessEvent::Stdout { process, sequence: 1, data: data.clone() },
        ProcessEvent::Stderr { process, sequence: 1, data },
        ProcessEvent::OutputTruncated {
            process,
            sequence: 1,
            reason: crate::ProcessOutputTruncationReason::ReaderTaskFailed {
                message: String::new(),
            },
        },
        ProcessEvent::ReplayGap {
            process,
            requested_after: 0,
            range: ProcessReplayRange { first_available: Some(1), last_produced: 2, exited: false },
        },
        ProcessEvent::Exit { process, code: Some(0), signal: None },
    ];
    let mut tags = Vec::new();
    for event in events {
        // A new variant must be added here and to KNOWN_PROCESS_EVENT_TYPES.
        match &event {
            ProcessEvent::Stdout { .. }
            | ProcessEvent::Stderr { .. }
            | ProcessEvent::OutputTruncated { .. }
            | ProcessEvent::ReplayGap { .. }
            | ProcessEvent::Exit { .. } => {}
        }
        let encoded = serde_json::to_vec(&RpcEvent { sequence: 1, event }).unwrap();
        assert_eq!(unknown_process_event_type(&encoded), None);
        let value: serde_json::Value = serde_json::from_slice(&encoded).unwrap();
        tags.push(value["event"]["type"].as_str().unwrap().to_string());
    }
    assert_eq!(tags, KNOWN_PROCESS_EVENT_TYPES);
}

#[test]
fn an_unknown_event_type_is_named_and_a_non_event_is_not() {
    let newer = br#"{"sequence":9,"event":{"type":"resized","process":"x","cols":80}}"#;
    assert_eq!(unknown_process_event_type(newer).as_deref(), Some("resized"));
    assert_eq!(unknown_process_event_type(br#"{"id":"x"}"#), None);
    assert_eq!(unknown_process_event_type(b"not json"), None);
}

#[test]
fn a_message_id_reads_past_an_unknown_body() {
    let id = RequestId::from_u128(7);
    let encoded = format!(r#"{{"id":"{id}","request":{{"type":"from-the-future","x":1}}}}"#);
    assert_eq!(message_id(encoded.as_bytes()), Some(id));
    assert_eq!(message_id(br#"{"request":{}}"#), None);
}

#[test]
fn the_tally_counts_absorbed_and_reset_apart() {
    let counters = SkewCounters::new();
    counters.unsupported_request();
    counters.unsupported_response();
    counters.skipped_event();
    counters.skipped_event();
    counters.channel_reset();
    let tally = counters.tally();
    assert_eq!(tally.absorbed(), 4);
    assert_eq!(tally.channel_resets, 1);
}
