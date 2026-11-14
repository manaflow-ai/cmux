use super::*;
use crate::protocol::ErrorCode;
use serde_json::json;

fn hello() -> Frame {
    Frame::Hello {
        version: PROVIDER_VERSION,
        provider_id: "app".into(),
        install_id: "inst_1".into(),
        secret: ProviderSecret::new("s3cret-value"),
        engines: vec!["webkit".into(), "cef".into()],
        tabs: vec![TabAnnounce {
            target_id: "tab_1".into(),
            engine: "cef".into(),
            workspace: "ws_1".into(),
            profile: "agent".into(),
            url: "https://example.com/".into(),
            title: "Example".into(),
            visible: false,
            input_scale: 1.0,
            touch: false,
        }],
    }
}

#[test]
fn frames_round_trip_with_protocol_tags() {
    let frames = vec![
        hello(),
        Frame::Call { id: 7, method: "tab.info".into(), params: json!({"targetId": "tab_1"}) },
        Frame::Result { id: 7, result: Some(json!({"url": "about:blank"})), error: None },
        Frame::Event { name: "tab.closed".into(), payload: json!({"targetId": "tab_1"}) },
        Frame::CdpAttach { target_id: "tab_1".into() },
        Frame::Cdp {
            target_id: "tab_1".into(),
            message: r#"{"id":1,"method":"Page.enable"}"#.into(),
        },
        Frame::Lease { target_id: "tab_1".into(), lease: None },
        Frame::UserInput { target_id: "tab_1".into() },
        Frame::TabAccess {
            target_id: "tab_1".into(),
            extension_host_access: true,
            user_override: false,
            extensions: vec!["Ext".into()],
        },
    ];
    let mut stream = Vec::new();
    for frame in &frames {
        write_frame(&mut stream, frame).unwrap();
    }
    let mut reader = stream.as_slice();
    for frame in &frames {
        assert_eq!(read_frame(&mut reader).unwrap().as_ref(), Some(frame));
    }
    assert!(read_frame(&mut reader).unwrap().is_none());

    let value = serde_json::to_value(&frames[5]).unwrap();
    assert_eq!(value["t"], "cdp");
    assert_eq!(value["targetId"], "tab_1");
    assert_eq!(serde_json::to_value(&frames[4]).unwrap()["t"], "cdp.attach");
    let access = serde_json::to_value(&frames[8]).unwrap();
    assert_eq!(access["t"], "tab.access");
    assert_eq!(access["extension_host_access"], true);
    assert_eq!(access["user_override"], false);
    // An app that omits user_override sends no override.
    let parsed: Frame = serde_json::from_value(
        json!({"t": "tab.access", "targetId": "t", "extension_host_access": false}),
    )
    .unwrap();
    assert_eq!(
        parsed,
        Frame::TabAccess {
            target_id: "t".into(),
            extension_host_access: false,
            user_override: false,
            extensions: Vec::new(),
        }
    );
}

#[test]
fn secret_is_redacted_in_debug_output() {
    let text = format!("{:?}", hello());
    assert!(!text.contains("s3cret-value"), "{text}");
    assert!(format!("{:?}", ProviderSecret::new("s3cret-value")).contains("<redacted>"));
    assert!(ProviderSecret::new("abc").matches(&ProviderSecret::new("abc")));
    assert!(!ProviderSecret::new("abc").matches(&ProviderSecret::new("abd")));
    assert!(!ProviderSecret::new("abc").matches(&ProviderSecret::new("abcd")));
}

#[test]
fn debug_output_hides_payloads() {
    let call = Frame::Call {
        id: 1,
        method: "input.insertText".into(),
        params: json!({"text": "hunter2"}),
    };
    let cdp =
        Frame::Cdp { target_id: "t".into(), message: r#"{"params":{"text":"hunter2"}}"#.into() };
    let text = format!("{call:?} {cdp:?}");
    assert!(!text.contains("hunter2"), "{text}");
    assert!(text.contains("input.insertText"));
}

#[test]
fn hello_reads_use_a_small_limit() {
    let mut reader: &[u8] = &((MAX_HELLO_BYTES as u32) + 1).to_be_bytes();
    assert!(matches!(
        read_frame_limited(&mut reader, MAX_HELLO_BYTES),
        Err(CodecError::TooLarge(_))
    ));
}

#[test]
fn result_frames_map_to_call_results() {
    let ok = Frame::Result { id: 1, result: None, error: None };
    assert_eq!(ok.into_call_result(), Some((1, Ok(Value::Null))));
    let error = DriverError::new(ErrorCode::Stale, "gone");
    let failed = Frame::Result { id: 2, result: Some(json!(1)), error: Some(error.clone()) };
    assert_eq!(failed.into_call_result(), Some((2, Err(error))));
    assert_eq!(Frame::UserInput { target_id: "t".into() }.into_call_result(), None);
}

#[test]
fn oversize_and_truncated_frames_are_errors() {
    let mut reader: &[u8] = &((MAX_FRAME_BYTES as u32) + 1).to_be_bytes();
    assert!(matches!(read_frame(&mut reader), Err(CodecError::TooLarge(_))));

    let bytes = encode(&Frame::UserInput { target_id: "t".into() }).unwrap();
    let mut reader: &[u8] = &bytes[..bytes.len() - 1];
    assert!(matches!(read_frame(&mut reader), Err(CodecError::Truncated)));
    let mut reader: &[u8] = &bytes[..2];
    assert!(matches!(read_frame(&mut reader), Err(CodecError::Truncated)));
}

#[test]
fn incremental_decoder_waits_for_whole_frames() {
    let a = encode(&Frame::CdpDetach { target_id: "a".into() }).unwrap();
    let b = encode(&Frame::UserInput { target_id: "b".into() }).unwrap();
    let mut decoder = FrameDecoder::default();
    decoder.push(&a[..3]);
    assert!(decoder.next_frame().unwrap().is_none());
    decoder.push(&a[3..]);
    decoder.push(&b[..b.len() - 1]);
    assert_eq!(decoder.next_frame().unwrap(), Some(Frame::CdpDetach { target_id: "a".into() }));
    assert!(decoder.next_frame().unwrap().is_none());
    decoder.push(&b[b.len() - 1..]);
    assert_eq!(decoder.next_frame().unwrap(), Some(Frame::UserInput { target_id: "b".into() }));
}
