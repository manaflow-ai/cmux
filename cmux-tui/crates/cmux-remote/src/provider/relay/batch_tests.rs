//! A relay batch from the peer decodes by checked bounds: a short, wrong or
//! truncated batch is a protocol error, never a panic.

use super::*;

#[test]
fn a_batch_round_trips() {
    let frames = [Bytes::from_static(b"one"), Bytes::from_static(b"second")];
    let decoded = decode_relay_batch(encode_relay_batch(&frames).unwrap(), 64).unwrap();
    assert_eq!(decoded, VecDeque::from(frames.to_vec()));
}

#[test]
fn malformed_batches_are_protocol_errors() {
    let valid = encode_relay_batch(&[Bytes::from_static(b"frame")]).unwrap();
    let mut wrong_version = valid.to_vec();
    wrong_version[4] = RELAY_BATCH_VERSION.wrapping_add(1);
    let mut reserved_set = valid.to_vec();
    reserved_set[7] = 1;
    let mut no_frames = valid.to_vec();
    no_frames[5] = 0;
    let cases: [(&str, Vec<u8>); 7] = [
        ("empty", Vec::new()),
        ("short header", valid[..RELAY_BATCH_HEADER_BYTES - 1].to_vec()),
        ("wrong version", wrong_version),
        ("reserved bytes", reserved_set),
        ("no frames", no_frames),
        ("truncated length", valid[..RELAY_BATCH_HEADER_BYTES + 2].to_vec()),
        ("truncated frame", valid[..valid.len() - 1].to_vec()),
    ];
    for (name, encoded) in cases {
        let error = decode_relay_batch(Bytes::from(encoded), 64).unwrap_err();
        assert!(matches!(error, LinkError::Protocol(_)), "{name}: {error:?}");
    }
    let mut trailing = valid.to_vec();
    trailing.push(0);
    assert!(matches!(decode_relay_batch(Bytes::from(trailing), 64), Err(LinkError::Protocol(_))));
}

#[test]
fn a_frame_over_the_maximum_is_too_large() {
    let encoded = encode_relay_batch(&[Bytes::from_static(b"too long")]).unwrap();
    assert!(matches!(decode_relay_batch(encoded, 4), Err(LinkError::FrameTooLarge { .. })));
}
