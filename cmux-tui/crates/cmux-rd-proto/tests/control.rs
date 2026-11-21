//! The typed control messages (rd change C7) against the shared golden
//! vectors in tests/vectors/control.json. The Swift viewer's copy
//! (CmuxNextRemoteView `RemoteRdControl`) reads the same file in
//! RemoteRdControlTests, so the two cannot drift.
#![cfg(feature = "serde")]

use cmux_rd_proto::control::{Control, SecretHex};

fn vectors() -> Vec<serde_json::Value> {
    serde_json::from_str(include_str!("vectors/control.json")).expect("vectors")
}

#[test]
fn every_vector_parses_and_round_trips() {
    for v in vectors() {
        let name = v["name"].as_str().expect("name");
        let control: Control =
            serde_json::from_value(v["json"].clone()).unwrap_or_else(|e| panic!("{name}: {e}"));
        let again = serde_json::to_value(&control).expect("encode");
        let back: Control = serde_json::from_value(again).expect("decode again");
        assert_eq!(format!("{control:?}"), format!("{back:?}"), "{name}");
    }
}

#[test]
fn a_hello_without_service_is_a_desktop_hello() {
    let v = vectors().into_iter().find(|v| v["name"] == "hello_before_c1").expect("vector");
    let Control::Hello { service, caps, .. } =
        serde_json::from_value(v["json"].clone()).expect("hello")
    else {
        panic!("not a hello");
    };
    assert_eq!(service, v["service"].as_str().expect("expected service"));
    assert!(caps.is_empty());
}

#[test]
fn a_secret_never_reaches_debug_output() {
    let token = SecretHex("ab".repeat(32));
    assert_eq!(format!("{token:?}"), "<redacted>");
    let v = vectors().into_iter().find(|v| v["name"] == "hello").expect("vector");
    let hello: Control = serde_json::from_value(v["json"].clone()).expect("hello");
    assert!(!format!("{hello:?}").contains("abab"));
}

#[test]
fn a_service_body_passes_through_untouched() {
    let v = vectors().into_iter().find(|v| v["name"] == "service").expect("vector");
    let control: Control = serde_json::from_value(v["json"].clone()).expect("service");
    let Control::Service { service, body } = &control else { panic!("not a service message") };
    assert_eq!(service, "rb/1");
    assert_eq!(body, &v["json"]["body"]);
    assert_eq!(serde_json::to_value(&control).expect("encode"), v["json"]);
}

#[test]
fn stream_open_matches_its_vectors_byte_for_byte() {
    use cmux_rd_proto::control::StreamKind;
    for name in
        ["stream_open", "stream_open_tiles", "stream_opened", "stream_refused", "stream_close"]
    {
        let v = vectors().into_iter().find(|v| v["name"] == name).expect("vector");
        let control: Control = serde_json::from_value(v["json"].clone()).expect(name);
        assert_eq!(serde_json::to_value(&control).expect("encode"), v["json"], "{name}");
    }
    let v = vectors().into_iter().find(|v| v["name"] == "stream_open").expect("vector");
    let Control::StreamOpen { stream, kind, codec, of } =
        serde_json::from_value(v["json"].clone()).expect("stream_open")
    else {
        panic!("not a stream_open");
    };
    assert_eq!((stream, kind, codec.as_str(), of), (100, StreamKind::UpAudio, "opus", None));
    assert!(kind.is_upstream());
    assert_eq!(kind.codec(), Some("opus"));
}

#[test]
fn a_newer_stream_kind_parses_as_unknown() {
    use cmux_rd_proto::control::StreamKind;
    let v = vectors().into_iter().find(|v| v["name"] == "stream_open_newer_kind").expect("vector");
    let Control::StreamOpen { kind, .. } =
        serde_json::from_value(v["json"].clone()).expect("a newer kind still parses")
    else {
        panic!("not a stream_open");
    };
    assert_eq!(serde_json::to_value(kind).expect("kind"), v["kind"]);
    assert_eq!(kind, StreamKind::Unknown);
    assert!(!kind.is_upstream());
}

#[test]
fn a_cursor_shape_carries_its_pixels_and_its_id() {
    let v = vectors().into_iter().find(|v| v["name"] == "cursor_shape").expect("vector");
    let control: Control = serde_json::from_value(v["json"].clone()).expect("cursor_shape");
    assert_eq!(serde_json::to_value(&control).expect("encode"), v["json"]);
    let Control::CursorShape { shape, width, height, hot_x, hot_y, rgba } = control else {
        panic!("not a cursor_shape");
    };
    assert_eq!((shape, width, height, hot_x, hot_y), (0xdead_beef, 2, 1, 1, 0));
    let pixels = cmux_rd_proto::base64_decode(&rgba).expect("base64");
    assert_eq!(pixels, [0, 0, 0, 255, 255, 255, 255, 255]);
    assert_eq!(pixels.len(), (width * height * 4) as usize);
}

#[test]
fn clipboard_messages_match_their_vectors_byte_for_byte() {
    use cmux_rd_proto::clipboard::ClipboardPart;
    for name in ["clipboard", "clipboard_part"] {
        let v = vectors().into_iter().find(|v| v["name"] == name).expect("vector");
        let control: Control = serde_json::from_value(v["json"].clone()).expect(name);
        assert_eq!(serde_json::to_value(&control).expect("encode"), v["json"], "{name}");
    }
    let v = vectors().into_iter().find(|v| v["name"] == "clipboard").expect("vector");
    let control: Control = serde_json::from_value(v["json"].clone()).expect("clipboard");
    let part = control.into_clipboard_part().expect("a clipboard message");
    assert_eq!(
        part,
        ClipboardPart { seq: 1, text: "héllo \"world\"\n".into(), offset: None, total: None }
    );
    let v = vectors().into_iter().find(|v| v["name"] == "clipboard_part").expect("vector");
    let control: Control = serde_json::from_value(v["json"].clone()).expect("clipboard_part");
    let part = control.into_clipboard_part().expect("a clipboard message");
    assert_eq!((part.offset, part.total), (Some(16384), Some(20000)));
    assert_eq!(serde_json::to_value(Control::from(part)).expect("encode"), v["json"]);
}

/// The largest part a sender makes, as a control record, fits one secure link packet and the
/// stream carrier's frame with room to spare.
#[test]
fn the_largest_clipboard_part_fits_one_record() {
    use cmux_rd_proto::clipboard::{ClipboardSync, MAX_CLIPBOARD_TEXT, MAX_PART_ENCODED};
    // Control characters escape to six bytes each: the worst case per character.
    let text = "\u{1}".repeat(MAX_CLIPBOARD_TEXT);
    let mut sync = ClipboardSync::new();
    sync.offer(&text);
    let mut now = 0;
    let mut largest = 0;
    let mut parts = 0;
    while let Some(due) = sync.next_deadline_us() {
        now = now.max(due);
        if let Some(part) = sync.next_part(now) {
            let record = serde_json::to_vec(&Control::from(part)).expect("encode");
            largest = largest.max(record.len());
            parts += 1;
        }
    }
    assert!(largest <= MAX_PART_ENCODED + 128, "{largest}");
    // 65_000 sits under MAX_STREAM_FRAME (1 MiB), so this bound covers the frame cap too.
    assert!(largest < 65_000, "{largest}");
    assert_eq!(parts, MAX_CLIPBOARD_TEXT.div_ceil(MAX_PART_ENCODED / 6));
}
