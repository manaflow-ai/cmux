//! Golden vectors for the relay frame. The TypeScript `HostDO` relay reads
//! the same file, so both sides agree byte for byte.

use cmux_transport::{FrameKind, PeerId, RelayFrame, RelayFrameError};

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
        };
        assert!(matches, "vector expected {expected}, got {error:?}");
        checked += 1;
    }
    assert!(checked >= 3, "vector file lost its invalid cases");
}

#[test]
fn batches_round_trip_in_order() {
    let peer = PeerId([7; 16]);
    let first = [4u8, 0, 0, 0, 1, 2];
    let second = [1u8; 148];
    let frame = RelayFrame::datagrams(peer, &[&first, &second]).expect("fits");
    let decoded = RelayFrame::decode(&frame.encode().expect("encodes")).expect("decodes");
    assert_eq!(decoded.split_datagrams().expect("valid batch"), vec![&first[..], &second[..]]);
}

#[test]
fn batches_that_do_not_fit_are_refused() {
    let big = vec![0u8; 9000];
    let error = RelayFrame::datagrams(PeerId([0; 16]), &[&big, &big]).expect_err("over 16 KiB");
    assert!(matches!(error, RelayFrameError::TooLarge(_)));
    assert_eq!(RelayFrame::datagrams(PeerId([0; 16]), &[]), Err(RelayFrameError::BadBatch));
}
