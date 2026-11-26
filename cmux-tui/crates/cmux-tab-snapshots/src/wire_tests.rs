use super::*;
use crate::row::Kind;

fn row(id: &str) -> Row {
    Row {
        tab_id: id.to_owned(),
        title: format!("Title {id}"),
        kind: Kind::Browser,
        favicon_hash: Some(BlobHash::of(b"fav")),
        thumb_hash: Some(BlobHash::of(id.as_bytes())),
        thumb_w: 516,
        thumb_h: 344,
        thumb_mime: Mime::Jpeg,
        screen_hash: None,
        screen_cols: 0,
        screen_rows: 0,
        frame_hash: None,
        captured_at_ms: 1_700_000_000_000,
    }
}

fn round_trip(msg: &Message) {
    let bytes = msg.encode();
    assert_eq!(bytes.first(), Some(&msg.kind()));
    assert_eq!(&Message::decode(&bytes).unwrap(), msg);
}

#[test]
fn every_message_round_trips() {
    round_trip(&Message::Viewport(Viewport {
        card_pixel_width: 516,
        card_aspect: 0.75,
        display_scale: 3.0,
        screen_pixel_w: 1179,
        screen_pixel_h: 2556,
    }));
    round_trip(&Message::Want(vec![BlobHash::of(b"a"), BlobHash::of(b"b")]));
    round_trip(&Message::Have(vec![]));
    round_trip(&Message::Resume(Resume { epoch: "e1".into(), rev: 42 }));
    round_trip(&Message::Manifest(Manifest {
        epoch: "e1".into(),
        rev: 7,
        rows: vec![row("t1"), row("t2")],
    }));
    let mut patch = RowPatch { tab_id: "t1".into(), ..RowPatch::default() };
    patch.title = Some("New".into());
    patch.thumb_hash = Some(None);
    patch.favicon_hash = Some(Some(BlobHash::of(b"x")));
    round_trip(&Message::Delta(Delta {
        epoch: "e1".into(),
        rev: 9,
        base_rev: 7,
        changed: vec![patch, RowPatch::full(&row("t3"))],
        removed: vec!["t2".into()],
        order: Some(vec!["t3".into(), "t1".into()]),
    }));
    round_trip(&Message::Blob(BlobFrame {
        hash: BlobHash::of(b"img"),
        mime: Mime::Png,
        bytes: b"img".to_vec(),
    }));
    round_trip(&Message::Blob(BlobFrame {
        hash: BlobHash::of(b""),
        mime: Mime::Unknown(200),
        bytes: vec![],
    }));
}

#[test]
fn row_json_uses_agreed_names_and_omits_absent_hashes() {
    let json = serde_json::to_value(row("t1")).unwrap();
    let obj = json.as_object().unwrap();
    for key in [
        "tabId",
        "title",
        "kind",
        "faviconHash",
        "thumbHash",
        "thumbW",
        "thumbH",
        "thumbMime",
        "screenCols",
        "screenRows",
        "capturedAtMs",
    ] {
        assert!(obj.contains_key(key), "{key}");
    }
    assert!(!obj.contains_key("screenHash"));
    assert!(!obj.contains_key("frameHash"));
    assert_eq!(obj["kind"], "browser");
    assert_eq!(obj["thumbMime"], 1);
    assert_eq!(obj["faviconHash"].as_str().unwrap().len(), 64);
}

#[test]
fn delta_patch_null_clears_and_absent_keeps() {
    let mut patch = RowPatch { tab_id: "t1".into(), ..RowPatch::default() };
    patch.thumb_hash = Some(None);
    let text = serde_json::to_string(&patch).unwrap();
    assert_eq!(text, r#"{"tabId":"t1","thumbHash":null}"#);
    let back: RowPatch = serde_json::from_str(&text).unwrap();
    assert_eq!(back.thumb_hash, Some(None));
    assert_eq!(back.favicon_hash, None);
    let mut r = row("t1");
    back.apply(&mut r);
    assert_eq!(r.thumb_hash, None);
    assert!(r.favicon_hash.is_some());
}

#[test]
fn unknown_fields_are_ignored() {
    let mut frame = vec![kind::MANIFEST];
    frame.extend_from_slice(
        br#"{"rev":3,"future":true,"rows":[{"tabId":"a","title":"T","kind":"browser","newThing":{"x":1}}]}"#,
    );
    let Message::Manifest(m) = Message::decode(&frame).unwrap() else { panic!("not a manifest") };
    assert_eq!(m.rev, 3);
    assert_eq!(m.rows[0].tab_id, "a");
    assert_eq!(m.rows[0].kind, Kind::Browser);

    let mut frame = vec![kind::RESUME];
    frame.extend_from_slice(br#"{"rev":5,"why":"reconnect"}"#);
    assert_eq!(
        Message::decode(&frame).unwrap(),
        Message::Resume(Resume { epoch: String::new(), rev: 5 })
    );
}

#[test]
fn epoch_is_on_manifest_delta_and_resume() {
    let m = Message::Manifest(Manifest { epoch: "ab12".into(), rev: 1, rows: vec![] }).encode();
    let json: serde_json::Value = serde_json::from_slice(&m[1..]).unwrap();
    assert_eq!(json["epoch"], "ab12");
    let d = Message::Delta(Delta { epoch: "ab12".into(), ..Delta::default() }).encode();
    let json: serde_json::Value = serde_json::from_slice(&d[1..]).unwrap();
    assert_eq!(json["epoch"], "ab12");
    let r = Message::Resume(Resume { epoch: "ab12".into(), rev: 4 }).encode();
    assert_eq!(&r[1..], br#"{"epoch":"ab12","rev":4}"#);
    // A resume without an epoch omits the field.
    let r = Message::Resume(Resume { epoch: String::new(), rev: 4 }).encode();
    assert_eq!(&r[1..], br#"{"rev":4}"#);
}

#[test]
fn unknown_kind_and_mime_decode_without_failing() {
    let mut frame = vec![kind::MANIFEST];
    frame.extend_from_slice(br#"{"rev":1,"rows":[{"tabId":"a","kind":"canvas","thumbMime":77}]}"#);
    let Message::Manifest(m) = Message::decode(&frame).unwrap() else { panic!("not a manifest") };
    assert_eq!(m.rows[0].kind, Kind::Other("canvas".into()));
    assert_eq!(m.rows[0].thumb_mime, Mime::Unknown(77));
    assert_eq!(serde_json::to_value(&m.rows[0]).unwrap()["kind"], "canvas");

    let mut frame = vec![kind::MANIFEST];
    frame.extend_from_slice(br#"{"rev":1,"rows":[{"tabId":"a","thumbMime":"image/png"}]}"#);
    let Message::Manifest(m) = Message::decode(&frame).unwrap() else { panic!("not a manifest") };
    assert_eq!(m.rows[0].thumb_mime, Mime::Png);
}

#[test]
fn bad_frames_are_typed_errors() {
    assert_eq!(Message::decode(&[]), Err(WireError::Empty));
    assert_eq!(Message::decode(&[0x7f, 1, 2]), Err(WireError::UnknownKind(0x7f)));
    assert_eq!(Message::decode(&[kind::BLOB, 1, 2]), Err(WireError::ShortBlob { len: 2 }));
    assert!(matches!(Message::decode(&[kind::WANT, b'{']), Err(WireError::Json { .. })));
    assert!(matches!(
        Message::decode(&[&[kind::WANT][..], br#"["zz"]"#].concat()),
        Err(WireError::Json { .. })
    ));
}

#[test]
fn blob_frame_is_binary() {
    let bytes = vec![0xffu8; 100];
    let frame = encode_blob(BlobHash::of(&bytes), Mime::Jpeg, &bytes);
    assert_eq!(frame.len(), BLOB_HEADER_LEN + 100);
    assert_eq!(frame[33], 1);
}

#[test]
fn order_is_omitted_when_unchanged() {
    let d = Message::Delta(Delta { epoch: "e".into(), ..Delta::default() }).encode();
    let json: serde_json::Value = serde_json::from_slice(&d[1..]).unwrap();
    assert!(json.get("order").is_none());
    let d = Delta { order: Some(vec!["b".into(), "a".into()]), ..Delta::default() };
    let json: serde_json::Value = serde_json::from_slice(&Message::Delta(d).encode()[1..]).unwrap();
    assert_eq!(json["order"], serde_json::json!(["b", "a"]));
}
