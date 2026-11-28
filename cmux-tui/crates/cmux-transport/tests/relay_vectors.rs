//! Golden vectors for the relay frame. The TypeScript `HostDO` relay reads
//! the same file, so both sides agree byte for byte.

use cmux_transport::{FrameKind, PeerId, RelayFrame, RelayFrameError, RelaySender, TaggedRecord};

const VECTORS: &str = include_str!("vectors/relay-frames.json");

fn hex(text: &str) -> Vec<u8> {
    (0..text.len())
        .step_by(2)
        .map(|index| u8::from_str_radix(&text[index..index + 2], 16).expect("hex"))
        .collect()
}

/// Reads `"key": "value"` pairs line by line; the vector file is written in
/// that one-object-per-line shape so no JSON dependency is needed.
fn field<'a>(line: &'a str, key: &str) -> Option<&'a str> {
    let marker = format!("\"{key}\": \"");
    let start = line.find(&marker)? + marker.len();
    let end = line[start..].find('"')? + start;
    Some(&line[start..end])
}

#[test]
fn valid_vectors_round_trip() {
    let mut checked = 0;
    for line in VECTORS.lines().filter(|line| line.contains("\"valid\": \"yes\"")) {
        let bytes = hex(field(line, "hex").expect("hex field"));
        let frame = RelayFrame::decode(&bytes).expect("valid vector decodes");
        let kind = match field(line, "kind").expect("kind field") {
            "datagrams" => FrameKind::Datagrams,
            "candidates" => FrameKind::Candidates,
            "wake" => FrameKind::Wake,
            other => panic!("unknown kind {other}"),
        };
        assert_eq!(frame.kind, kind);
        assert_eq!(
            frame.peer,
            PeerId(hex(field(line, "peer").expect("peer field")).try_into().expect("16 bytes"))
        );
        assert_eq!(frame.payload, hex(field(line, "payload").expect("payload field")));
        if let Some(records) = field(line, "records") {
            let expected: Vec<Vec<u8>> = records.split(',').map(hex).collect();
            let split: Vec<Vec<u8>> = frame
                .split_datagrams()
                .expect("valid batch")
                .into_iter()
                .map(<[u8]>::to_vec)
                .collect();
            assert_eq!(split, expected);
        }
        assert_eq!(frame.encode().expect("encodes"), bytes);
        checked += 1;
    }
    assert!(checked >= 3, "vector file lost its valid cases");
}

#[test]
fn invalid_vectors_are_refused() {
    let mut checked = 0;
    for line in VECTORS.lines().filter(|line| line.contains("\"valid\": \"no\"")) {
        let bytes = hex(field(line, "hex").expect("hex field"));
        let error = RelayFrame::decode(&bytes).expect_err("invalid vector is refused");
        let expected = field(line, "error").expect("error field");
        let matches = match error {
            RelayFrameError::Short => expected == "short",
            RelayFrameError::Version(_) => expected == "version",
            RelayFrameError::Kind(_) => expected == "kind",
            RelayFrameError::TooLarge(_) => expected == "too_large",
            RelayFrameError::BadBatch => expected == "bad_batch",
            RelayFrameError::BadHub => expected == "bad_hub",
        };
        assert!(matches, "vector expected {expected}, got {error:?}");
        checked += 1;
    }
    assert!(checked >= 3, "vector file lost its invalid cases");
}

/// One tagged record: class, optional (key, key seq), body.
type Rec = (u8, Option<(u32, u32)>, Vec<u8>);

const TAGGED: &str = include_str!("vectors/relay-tagged-frames.json");

fn tagged_error_matches(error: RelayFrameError, expected: &str) -> bool {
    match error {
        RelayFrameError::Short => expected == "short",
        RelayFrameError::Version(_) => expected == "version",
        RelayFrameError::Kind(_) => expected == "kind",
        RelayFrameError::TooLarge(_) => expected == "too_large",
        RelayFrameError::BadBatch => expected == "bad_batch",
        RelayFrameError::BadHub => expected == "bad_hub",
    }
}

#[test]
fn tagged_valid_vectors_round_trip() {
    let mut checked = 0;
    for line in TAGGED.lines().filter(|line| line.contains("\"valid\": \"yes\"")) {
        let bytes = hex(field(line, "hex").expect("hex field"));
        let frame = RelayFrame::decode(&bytes).expect("valid vector decodes");
        assert_eq!(frame.kind, FrameKind::TaggedDatagrams);
        assert_eq!(field(line, "kind"), Some("tagged-datagrams"));
        assert_eq!(frame.payload, hex(field(line, "payload").expect("payload field")));
        let records = frame.split_tagged().expect("valid records");
        let expected: Vec<Rec> = field(line, "records")
            .expect("records field")
            .split(',')
            .map(|record| {
                let mut parts = record.splitn(3, ':');
                let class: u8 = parts.next().expect("class").parse().expect("class number");
                let tag = match parts.next().expect("tag") {
                    "-" => None,
                    tag => {
                        let (key, seq) = tag.split_once('.').expect("key.seq");
                        Some((
                            u32::from_str_radix(key, 16).expect("key"),
                            u32::from_str_radix(seq, 16).expect("seq"),
                        ))
                    }
                };
                (class, tag, hex(parts.next().expect("data")))
            })
            .collect();
        let got: Vec<Rec> =
            records.iter().map(|record| (record.class, record.tag, record.data.to_vec())).collect();
        assert_eq!(got, expected);
        assert_eq!(frame.encode().expect("encodes"), bytes);
        let peer = PeerId(hex(field(line, "peer").expect("peer")).try_into().expect("16 bytes"));
        assert_eq!(RelayFrame::tagged_datagrams(peer, &records).expect("repacks"), frame);
        checked += 1;
    }
    assert!(checked >= 5, "tagged vector file lost its valid cases");
}

#[test]
fn tagged_invalid_vectors_are_refused() {
    let mut checked = 0;
    for line in TAGGED.lines().filter(|line| line.contains("\"valid\": \"no\"")) {
        let bytes = hex(field(line, "hex").expect("hex field"));
        let error = RelayFrame::decode(&bytes).expect_err("invalid vector is refused");
        let expected = field(line, "error").expect("error field");
        assert!(tagged_error_matches(error, expected), "vector expected {expected}, got {error:?}");
        checked += 1;
    }
    assert!(checked >= 8, "tagged vector file lost its invalid cases");
}

#[test]
fn an_old_relay_refuses_kind_4_and_the_sender_falls_back_to_plain_datagrams() {
    let peer = PeerId([7; 16]);
    let records = [
        TaggedRecord { class: 1, tag: Some((7, 9)), data: b"state" },
        TaggedRecord { class: 0, tag: None, data: b"ctl" },
    ];
    let mut sender = RelaySender::new(true);
    assert_eq!(sender.frame(peer, &records).expect("tagged").kind, FrameKind::TaggedDatagrams);
    // The text of an unrelated notice changes nothing.
    assert!(!sender.on_notice(r#"{"type":"peer","online":false}"#));
    assert!(!sender.on_notice(r#"{"type":"error","code":"bad_frame:bad_batch"}"#));
    assert!(sender.is_tagged());
    // What an old LinkRelay sends for a kind it does not know (its `bad_frame:${error}` notice).
    assert!(sender.on_notice(r#"{"type":"error","code":"bad_frame:kind"}"#));
    let plain = sender.frame(peer, &records).expect("plain");
    assert_eq!(plain.kind, FrameKind::Datagrams);
    assert_eq!(plain.split_datagrams().expect("batch"), vec![&b"state"[..], &b"ctl"[..]]);
    assert!(!sender.on_notice(r#"{"type":"error","code":"bad_frame:kind"}"#));
    // Old frame, new relay: a plain Datagrams frame decodes exactly as before.
    assert_eq!(RelayFrame::decode(&plain.encode().expect("encodes")).expect("decodes"), plain);
}

/// This crate's record parser and hop's decoder (`HopMsg::decode`) agree on every tagged vector's payload: the same
/// records when valid, and a refusal from both when not. Both are one wire (docs/cmux-next/relay-pop-hop.md).
#[test]
fn the_tagged_parser_agrees_with_hops_record_decoder() {
    let mut checked = 0;
    for line in TAGGED.lines().filter(|line| line.contains("\"hex\"")) {
        let bytes = hex(field(line, "hex").expect("hex field"));
        let Some(payload) = bytes.get(18..) else { continue };
        let mut hop_bytes = vec![0xC1, 1, 0, 0, 0, 1];
        hop_bytes.extend_from_slice(payload);
        let hop = cmux_transport::HopMsg::decode(&hop_bytes);
        let ours =
            RelayFrame::decode(&bytes).ok().map(|frame| frame.split_tagged().map(|r| r.len()));
        match (hop, ours) {
            (Ok(cmux_transport::HopMsg::Data { records, .. }), Some(Ok(count))) => {
                assert_eq!(records.len(), count);
                let frame = RelayFrame::decode(&bytes).expect("decodes");
                for (theirs, mine) in records.iter().zip(frame.split_tagged().expect("records")) {
                    assert_eq!(theirs.class as u8, mine.class);
                    assert_eq!(theirs.tag.map(|t| (t.key, t.seq)), mine.tag);
                    assert_eq!(theirs.bytes, mine.data);
                }
            }
            (Err(_), None | Some(Err(_))) => {}
            (hop, ours) => panic!("hop and relay_frame disagree: {hop:?} vs {ours:?} for {line}"),
        }
        checked += 1;
    }
    assert!(checked >= 15);
}
