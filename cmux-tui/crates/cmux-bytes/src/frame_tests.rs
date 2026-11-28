use super::*;

fn noise(n: usize) -> Vec<u8> {
    let mut x = 0x1234_5678_9abc_def0u64;
    (0..n)
        .map(|_| {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            x as u8
        })
        .collect()
}

/// The bug in hybrid-edge-cases.md: 1 MiB of random bytes became 1.40 MB.
#[test]
fn a_payload_never_grows() {
    for n in [0, 1, 7, 100, 4096, 1 << 20] {
        let raw = noise(n);
        for want in
            [Encoding::Store, Encoding::Zstd(1), Encoding::Zstd(19), Encoding::ZstdDict(3, 9)]
        {
            let (frame, _) = encode(&raw, want, 0.97, &());
            assert!(frame.len() <= raw.len() + MAX_OVERHEAD, "{n} {want:?}: {}", frame.len());
            match decode(&frame, &()).unwrap() {
                Decoded::Bytes(b) => assert_eq!(b, raw),
                Decoded::Ref { .. } => panic!(),
            }
        }
    }
}

#[test]
fn text_shrinks_and_round_trips() {
    let raw = b"use std::io;\nfn main() {}\n".repeat(5000);
    let (frame, used) = encode(&raw, Encoding::Zstd(3), 0.97, &());
    assert_eq!(used, Encoding::Zstd(3));
    assert!(frame.len() * 50 < raw.len());
    let Decoded::Bytes(back) = decode(&frame, &()).unwrap() else { panic!() };
    assert_eq!(back, raw);
}

#[test]
fn a_ref_is_constant_size() {
    let (frame, _) = encode(&noise(1 << 20), Encoding::Ref, 0.97, &());
    assert_eq!(frame.len(), 1 + 3 + 32);
}

#[test]
fn garbage_is_refused_not_panicked() {
    for bad in [&[][..], &[9, 0], &[1, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f], &[3, 5, 1]] {
        assert!(decode(bad, &()).is_err());
    }
}
