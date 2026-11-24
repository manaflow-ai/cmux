use super::*;

#[test]
fn rgbx_round_trips_its_wire_form() {
    assert_eq!(PixelFormat::parse(&PixelFormat::RGBX.encode()), PixelFormat::RGBX);
    assert_eq!(PixelFormat::RGBX.rgba(&[1, 2, 3, 99]), [1, 2, 3, 255]);
    assert_eq!(PixelFormat::RGBX.cpixel_len(), 3);
    assert_eq!(PixelFormat::RGBX.cpixel_rgba(&[1, 2, 3]), [1, 2, 3, 255]);
}

#[test]
fn big_endian_bgr_and_rgb565_decode() {
    // macOS's native format: 32 bpp big endian, red in bits 16..24.
    let mut format = PixelFormat::RGBX;
    format.big_endian = true;
    format.red_shift = 16;
    format.blue_shift = 0;
    assert_eq!(format.rgba(&[0, 0x10, 0x20, 0x30]), [0x10, 0x20, 0x30, 255]);
    assert_eq!(format.cpixel_rgba(&[0x10, 0x20, 0x30]), [0x10, 0x20, 0x30, 255]);
    let rgb565 = PixelFormat {
        bits_per_pixel: 16,
        depth: 16,
        big_endian: false,
        true_color: true,
        red_max: 31,
        green_max: 63,
        blue_max: 31,
        red_shift: 11,
        green_shift: 5,
        blue_shift: 0,
    };
    assert_eq!(rgb565.rgba(&0xF800u16.to_le_bytes()), [255, 0, 0, 255]);
    assert_eq!(rgb565.rgba(&0x07E0u16.to_le_bytes()), [0, 255, 0, 255]);
    assert_eq!(rgb565.cpixel_len(), 2);
}

#[test]
fn high_byte_cpixels_read_the_top_three_bytes() {
    let mut format = PixelFormat::RGBX;
    format.red_shift = 8;
    format.green_shift = 16;
    format.blue_shift = 24;
    assert_eq!(format.cpixel_len(), 3);
    assert_eq!(format.cpixel_rgba(&[7, 8, 9]), [7, 8, 9, 255]);
}

#[test]
fn invalid_formats_are_refused() {
    let mut format = PixelFormat::RGBX;
    format.true_color = false;
    assert!(format.validate().is_err());
    let mut format = PixelFormat::RGBX;
    format.bits_per_pixel = 24;
    assert!(format.validate().is_err());
    let mut format = PixelFormat::RGBX;
    format.red_shift = 40;
    assert!(format.validate().is_err());
}
