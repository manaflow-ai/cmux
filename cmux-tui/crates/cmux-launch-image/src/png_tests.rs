use super::*;

fn header(width: u32, height: u32) -> Vec<u8> {
    let mut bytes = SIGNATURE.to_vec();
    bytes.extend_from_slice(&13_u32.to_be_bytes());
    bytes.extend_from_slice(b"IHDR");
    bytes.extend_from_slice(&width.to_be_bytes());
    bytes.extend_from_slice(&height.to_be_bytes());
    bytes
}

#[test]
fn reads_the_size() {
    assert_eq!(png_pixel_size(&header(2880, 1800)), Some((2880, 1800)));
}

#[test]
fn refuses_what_is_not_a_png_with_a_size() {
    assert_eq!(png_pixel_size(&header(0, 10)), None);
    assert_eq!(png_pixel_size(&header(10, 0x8000_0000)), None);
    assert_eq!(png_pixel_size(&header(10, 10)[..23]), None);
    assert_eq!(png_pixel_size(b"GIF89a................................"), None);
    let mut wrong_chunk = header(10, 10);
    wrong_chunk[12..16].copy_from_slice(b"IDAT");
    assert_eq!(png_pixel_size(&wrong_chunk), None);
}
