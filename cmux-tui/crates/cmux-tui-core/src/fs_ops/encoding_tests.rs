use std::io::Write as _;

use super::{Encoding, inflate};
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
    assert!(Encoding::parse(Some("zstd"), Some(7)).is_err());
}
