use base64::Engine as _;
use ghostty_vt::{Callbacks, KittyImageFormat, Terminal};
use png::{BitDepth, ColorType, Compression, Encoder, FilterType};

fn terminal() -> Terminal {
    let mut terminal = Terminal::new(20, 8, 100, Callbacks::default()).unwrap();
    terminal.resize(20, 8, 10, 20).unwrap();
    terminal
}

fn encode_png(
    width: u32,
    height: u32,
    color: ColorType,
    depth: BitDepth,
    pixels: &[u8],
    palette: Option<&[u8]>,
    transparency: Option<&[u8]>,
) -> Vec<u8> {
    let mut encoded = Vec::new();
    {
        let mut encoder = Encoder::new(&mut encoded, width, height);
        encoder.set_color(color);
        encoder.set_depth(depth);
        encoder.set_compression(Compression::Fast);
        encoder.set_filter(FilterType::NoFilter);
        if let Some(palette) = palette {
            encoder.set_palette(palette.to_vec());
        }
        if let Some(transparency) = transparency {
            encoder.set_trns(transparency.to_vec());
        }
        let mut writer = encoder.write_header().unwrap();
        writer.write_image_data(pixels).unwrap();
    }
    encoded
}

fn kitty_png(image_id: u32, encoded: &[u8]) -> Vec<u8> {
    let payload = base64::engine::general_purpose::STANDARD.encode(encoded);
    format!("\x1b_Ga=t,t=d,f=100,i={image_id},q=2;{payload}\x1b\\").into_bytes()
}

fn assert_image(terminal: &Terminal, image_id: u32, size: (u32, u32), expected_rgba: &[u8]) {
    let snapshot = terminal.kitty_graphics_snapshot().unwrap();
    let image = snapshot.image(image_id).unwrap_or_else(|| panic!("missing image {image_id}"));
    assert_eq!(image.format, KittyImageFormat::Rgba, "image {image_id}");
    assert_eq!((image.width, image.height), size, "image {image_id}");
    assert_eq!(&*image.data, expected_rgba, "image {image_id}");
}

fn chunk_offsets(encoded: &[u8], expected_kind: &[u8; 4]) -> (usize, usize) {
    let mut offset = 8;
    while offset + 12 <= encoded.len() {
        let data_len = u32::from_be_bytes(encoded[offset..offset + 4].try_into().unwrap()) as usize;
        let data_start = offset + 8;
        let data_end = data_start.checked_add(data_len).expect("chunk length");
        let crc_end = data_end.checked_add(4).expect("chunk checksum");
        assert!(crc_end <= encoded.len(), "well-formed generated PNG");
        if &encoded[offset + 4..offset + 8] == expected_kind {
            return (data_start, data_end);
        }
        offset = crc_end;
    }
    panic!("missing {} chunk", String::from_utf8_lossy(expected_kind));
}

#[test]
fn eight_bit_rgb_grayscale_and_grayscale_alpha_decode_to_rgba() {
    let rgb =
        encode_png(2, 1, ColorType::Rgb, BitDepth::Eight, &[1, 2, 3, 250, 251, 252], None, None);
    let grayscale =
        encode_png(3, 1, ColorType::Grayscale, BitDepth::Eight, &[0, 127, 255], None, None);
    let grayscale_alpha = encode_png(
        2,
        1,
        ColorType::GrayscaleAlpha,
        BitDepth::Eight,
        &[32, 64, 200, 128],
        None,
        None,
    );
    let mut terminal = terminal();

    terminal.vt_write(&kitty_png(1, &rgb));
    terminal.vt_write(&kitty_png(2, &grayscale));
    terminal.vt_write(&kitty_png(3, &grayscale_alpha));

    assert_image(&terminal, 1, (2, 1), &[1, 2, 3, 255, 250, 251, 252, 255]);
    assert_image(&terminal, 2, (3, 1), &[0, 0, 0, 255, 127, 127, 127, 255, 255, 255, 255, 255]);
    assert_image(&terminal, 3, (2, 1), &[32, 32, 32, 64, 200, 200, 200, 128]);
}

#[test]
fn indexed_palette_and_transparency_expand_to_rgba() {
    let indexed = encode_png(
        3,
        1,
        ColorType::Indexed,
        BitDepth::Eight,
        &[0, 1, 2],
        Some(&[255, 0, 0, 0, 255, 0, 0, 0, 255]),
        Some(&[255, 0, 128]),
    );
    let transparent_rgb = encode_png(
        2,
        1,
        ColorType::Rgb,
        BitDepth::Eight,
        &[255, 0, 0, 0, 0, 255],
        None,
        Some(&[0, 255, 0, 0, 0, 0]),
    );
    let mut terminal = terminal();

    terminal.vt_write(&kitty_png(10, &indexed));
    terminal.vt_write(&kitty_png(11, &transparent_rgb));

    assert_image(&terminal, 10, (3, 1), &[255, 0, 0, 255, 0, 255, 0, 0, 0, 0, 255, 128]);
    assert_image(&terminal, 11, (2, 1), &[255, 0, 0, 0, 0, 0, 255, 255]);
}

#[test]
fn sixteen_bit_samples_are_stripped_to_eight_bit_rgba() {
    let rgb_16 = encode_png(
        1,
        1,
        ColorType::Rgb,
        BitDepth::Sixteen,
        &[0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc],
        None,
        None,
    );
    let mut terminal = terminal();

    terminal.vt_write(&kitty_png(20, &rgb_16));

    assert_image(&terminal, 20, (1, 1), &[0x12, 0x56, 0x9a, 255]);
}

#[test]
fn truncated_idat_and_bad_checksum_are_rejected_before_parser_recovery() {
    let valid = encode_png(2, 1, ColorType::Rgb, BitDepth::Eight, &[9, 8, 7, 6, 5, 4], None, None);
    let (data_start, data_end) = chunk_offsets(&valid, b"IDAT");
    let mut truncated = valid.clone();
    truncated.truncate(data_start + (data_end - data_start).div_ceil(2));
    let mut bad_checksum = valid.clone();
    bad_checksum[data_end + 3] ^= 0x01;
    let mut terminal = terminal();

    terminal.vt_write(&kitty_png(30, &truncated));
    terminal.vt_write(&kitty_png(31, &bad_checksum));

    let rejected = terminal.kitty_graphics_snapshot().unwrap();
    assert!(rejected.image(30).is_none(), "truncated IDAT must be rejected");
    assert!(rejected.image(31).is_none(), "bad IDAT checksum must be rejected");

    terminal.vt_write(&kitty_png(32, &valid));
    assert_image(&terminal, 32, (2, 1), &[9, 8, 7, 255, 6, 5, 4, 255]);
}

#[test]
fn valid_png_with_oversized_decoded_rgba_is_rejected_and_parser_recovers() {
    const WIDTH: u32 = 2_501;
    const HEIGHT: u32 = 1_000;
    let oversized = encode_png(
        WIDTH,
        HEIGHT,
        ColorType::Grayscale,
        BitDepth::Eight,
        &vec![0; WIDTH as usize * HEIGHT as usize],
        None,
        None,
    );
    assert!(
        oversized.len() < 100_000,
        "fixture must be rejected for decoded size, not encoded payload size"
    );
    let valid = encode_png(1, 1, ColorType::Rgb, BitDepth::Eight, &[4, 5, 6], None, None);
    let mut terminal = terminal();

    terminal.vt_write(&kitty_png(40, &oversized));
    assert!(
        terminal.kitty_graphics_snapshot().unwrap().image(40).is_none(),
        "decoded RGBA above the decoder limit must be rejected"
    );

    terminal.vt_write(&kitty_png(41, &valid));
    assert_image(&terminal, 41, (1, 1), &[4, 5, 6, 255]);
}
