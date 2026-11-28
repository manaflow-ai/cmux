use std::io::Write as _;

use super::{Codec, Encoding, decode, inflate};
use crate::fs_ops::FsError;

fn deflate(bytes: &[u8]) -> Vec<u8> {
    let mut encoder = flate2::write::DeflateEncoder::new(Vec::new(), flate2::Compression::new(3));
    encoder.write_all(bytes).unwrap();
    encoder.finish().unwrap()
}

#[test]
fn deflate_round_trips_exactly() {
    let text = "fn main() { println!(\"hello\"); }\n".repeat(4000);
    let wire = deflate(text.as_bytes());
    assert!(wire.len() * 10 < text.len(), "{} -> {}", text.len(), wire.len());
    let decoded = inflate(&wire, text.len() as u64, usize::MAX).unwrap();
    assert_eq!(decoded, text.as_bytes());
}

/// A small payload that decodes past its declared size (a zip bomb) is
/// refused once it reaches the bound, never held whole.
#[test]
fn decoding_past_decoded_size_is_refused() {
    let wire = deflate(&vec![0u8; 64 << 20]);
    let error = inflate(&wire, 1024, usize::MAX).unwrap_err();
    assert!(matches!(error, FsError::ParamsInvalid(ref m) if m.contains("more")), "{error:?}");
}

#[test]
fn short_or_foreign_bytes_are_refused() {
    let wire = deflate(b"twelve bytes");
    let short = inflate(&wire, 13, usize::MAX).unwrap_err();
    assert!(matches!(short, FsError::ParamsInvalid(ref m) if m.contains("less")), "{short:?}");
    let cut = wire.get(..wire.len() / 2).unwrap();
    assert!(inflate(cut, 12, usize::MAX).is_err());
    assert!(inflate(&[0xff; 64], 12, usize::MAX).is_err());
}

#[test]
fn a_decoded_size_over_the_line_limit_is_too_large() {
    let wire = deflate(&[1u8; 16]);
    assert!(matches!(inflate(&wire, 1 << 30, 12 << 20), Err(FsError::TooLarge { .. })));
}

#[test]
fn the_encoding_fields_go_together() {
    assert_eq!(Encoding::parse(None, None).unwrap(), Encoding::Identity);
    assert_eq!(
        Encoding::parse(Some("deflate"), Some(7)).unwrap(),
        Encoding::Deflate { decoded_size: 7 }
    );
    assert!(Encoding::parse(Some("deflate"), None).is_err());
    assert!(Encoding::parse(None, Some(7)).is_err());
    assert_eq!(Encoding::parse(Some("zstd"), Some(7)).unwrap(), Encoding::Zstd { decoded_size: 7 });
    assert!(Encoding::parse(Some("zstd"), None).is_err());
    assert!(Encoding::parse(Some("brotli"), Some(7)).is_err());
}

fn zstd(bytes: &[u8], level: i32) -> Vec<u8> {
    zstd::bulk::compress(bytes, level).unwrap()
}

#[test]
fn zstd_round_trips_exactly() {
    let text = "fn main() { println!(\"hello\"); }\n".repeat(4000);
    for level in [1, 3, 9, 19] {
        let wire = zstd(text.as_bytes(), level);
        assert!(wire.len() * 20 < text.len(), "{} -> {}", text.len(), wire.len());
        let decoded = decode(&wire, Codec::Zstd, text.len() as u64, usize::MAX).unwrap();
        assert_eq!(decoded, text.as_bytes());
    }
}

/// A zstd bomb (64 MiB of zeros in a few hundred bytes) is refused at the
/// declared size, never held whole.
#[test]
fn zstd_past_decoded_size_is_refused() {
    let wire = zstd(&vec![0u8; 64 << 20], 3);
    assert!(wire.len() < 64 << 10);
    let error = decode(&wire, Codec::Zstd, 1024, usize::MAX).unwrap_err();
    assert!(matches!(error, FsError::ParamsInvalid(ref m) if m.contains("more")), "{error:?}");
}

#[test]
fn short_or_foreign_zstd_is_refused() {
    let wire = zstd(b"twelve bytes", 3);
    let short = decode(&wire, Codec::Zstd, 13, usize::MAX).unwrap_err();
    assert!(matches!(short, FsError::ParamsInvalid(ref m) if m.contains("less")), "{short:?}");
    let cut = wire.get(..wire.len() / 2).unwrap();
    assert!(decode(cut, Codec::Zstd, 12, usize::MAX).is_err());
    assert!(decode(&[0xff; 64], Codec::Zstd, 12, usize::MAX).is_err());
    // Deflate bytes are not zstd.
    assert!(decode(&deflate(b"twelve bytes"), Codec::Zstd, 12, usize::MAX).is_err());
    // Trailing garbage after a whole frame is refused.
    let mut trailing = wire.clone();
    trailing.extend_from_slice(&[0xff; 16]);
    assert!(decode(&trailing, Codec::Zstd, 12, usize::MAX).is_err());
}

/// A frame that asks for a window past [`super::ZSTD_WINDOW_LOG_MAX`] is refused.
#[test]
fn a_zstd_window_past_the_limit_is_refused() {
    let data: Vec<u8> =
        (0..(40u32 << 20)).map(|i| (i.wrapping_mul(2_654_435_761) >> 13) as u8).collect();
    let mut encoder = zstd::stream::write::Encoder::new(Vec::new(), 1).unwrap();
    encoder.window_log(27).unwrap();
    encoder.long_distance_matching(true).unwrap();
    std::io::Write::write_all(&mut encoder, &data).unwrap();
    let wire = encoder.finish().unwrap();
    assert!(decode(&wire, Codec::Zstd, data.len() as u64, usize::MAX).is_err());
}
