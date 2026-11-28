use super::{CODEC_RAW, CODEC_ZSTD, KIND_EVENTS, decode_chunk, encode_chunk};

#[test]
fn rejects_expanded_lengths_before_allocating() {
    for codec in [CODEC_RAW, CODEC_ZSTD] {
        let mut file = vec![codec, KIND_EVENTS];
        file.extend_from_slice(&u32::MAX.to_le_bytes());
        let err = decode_chunk(&file).unwrap_err().to_string();
        assert!(err.contains("chunk limit"), "{err}");
    }
}

#[test]
fn rejects_raw_body_length_before_copying() {
    let mut file = vec![CODEC_RAW, KIND_EVENTS];
    file.extend_from_slice(&4u32.to_le_bytes());
    file.extend_from_slice(b"too short");
    let err = decode_chunk(&file).unwrap_err().to_string();
    assert!(err.contains("raw chunk"), "{err}");
}

#[test]
fn compressed_chunks_reject_mutated_lengths_and_truncated_frames() {
    let payload = vec![b'x'; 100_000];
    let valid = encode_chunk(KIND_EVENTS, &payload, 3).unwrap();
    assert_eq!(valid[0], CODEC_ZSTD);
    assert_eq!(decode_chunk(&valid).unwrap().1, payload);
    for len in [0u32, 1, 99_999, 100_001, 128 << 20, 256 << 20, u32::MAX] {
        let mut bad = valid.clone();
        bad[2..6].copy_from_slice(&len.to_le_bytes());
        assert!(decode_chunk(&bad).is_err(), "declared length {len}");
    }
    for end in 0..valid.len() {
        assert!(decode_chunk(&valid[..end]).is_err(), "cut {end}");
    }
}

#[test]
fn compressed_chunks_reject_a_window_above_128_mib() {
    // A zstd frame without a content size, window descriptor 0x90 = 256 MiB,
    // followed by an empty final raw block. The decoded payload is empty.
    let mut file = vec![CODEC_ZSTD, KIND_EVENTS, 0, 0, 0, 0];
    file.extend_from_slice(&[0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x90, 1, 0, 0]);
    assert!(decode_chunk(&file).is_err());
}
