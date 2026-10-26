use std::io::Cursor;

use flate2::{Compress, Compression, FlushCompress};

use super::*;

const RED: [u8; 4] = [255, 0, 0, 255];
const GREEN: [u8; 4] = [0, 255, 0, 255];
const BLUE: [u8; 4] = [0, 0, 255, 255];

fn rgbx(c: [u8; 4]) -> [u8; 4] {
    [c[0], c[1], c[2], 0]
}

fn rgb(c: [u8; 4]) -> [u8; 3] {
    [c[0], c[1], c[2]]
}

fn decode(
    encoding: i32,
    rect: Rect,
    wire: &[u8],
    fb: &mut Framebuffer,
    decoders: &mut Decoders,
) -> Result<()> {
    let mut reader = WireReader::new(Cursor::new(wire.to_vec()));
    decoders.decode(&mut reader, fb, &PixelFormat::RGBX, encoding, &rect)
}

fn pixel(fb: &Framebuffer, x: usize, y: usize) -> [u8; 4] {
    let at = (y * usize::from(fb.width()) + x) * 4;
    fb.pixels()[at..at + 4].try_into().unwrap()
}

/// Compresses `data` on `stream` with a sync flush, as servers do per rectangle.
fn deflate(stream: &mut Compress, data: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(data.len() + 64);
    stream.compress_vec(data, &mut out, FlushCompress::Sync).unwrap();
    while out.len() == out.capacity() {
        out.reserve(64);
        stream.compress_vec(&[], &mut out, FlushCompress::Sync).unwrap();
    }
    out
}

#[test]
fn raw_and_copy_rect() {
    let mut fb = Framebuffer::new(4, 2).unwrap();
    let mut decoders = Decoders::default();
    let wire: Vec<u8> = [RED, GREEN, BLUE, RED].iter().flat_map(|&c| rgbx(c)).collect();
    decode(encoding::RAW, Rect::new(0, 0, 2, 2), &wire, &mut fb, &mut decoders).unwrap();
    assert_eq!(pixel(&fb, 1, 0), GREEN);
    assert_eq!(pixel(&fb, 0, 1), BLUE);
    decode(encoding::COPY_RECT, Rect::new(2, 0, 2, 2), &[0, 0, 0, 0], &mut fb, &mut decoders)
        .unwrap();
    assert_eq!(pixel(&fb, 3, 0), GREEN);
    assert_eq!(pixel(&fb, 3, 1), RED);
    // A source outside the framebuffer is refused.
    assert!(
        decode(encoding::COPY_RECT, Rect::new(0, 0, 2, 2), &[0, 3, 0, 0], &mut fb, &mut decoders)
            .is_err()
    );
}

#[test]
fn rre_fills_background_then_subrects() {
    let mut fb = Framebuffer::new(4, 4).unwrap();
    let mut wire = vec![0, 0, 0, 1];
    wire.extend_from_slice(&rgbx(BLUE));
    wire.extend_from_slice(&rgbx(RED));
    wire.extend_from_slice(&[0, 1, 0, 1, 0, 2, 0, 2]);
    decode(encoding::RRE, Rect::new(0, 0, 4, 4), &wire, &mut fb, &mut Decoders::default()).unwrap();
    assert_eq!(pixel(&fb, 0, 0), BLUE);
    assert_eq!(pixel(&fb, 1, 1), RED);
    assert_eq!(pixel(&fb, 2, 2), RED);
    assert_eq!(pixel(&fb, 3, 3), BLUE);
    // A subrectangle past its rectangle is refused.
    let mut bad = vec![0, 0, 0, 1];
    bad.extend_from_slice(&rgbx(BLUE));
    bad.extend_from_slice(&rgbx(RED));
    bad.extend_from_slice(&[0, 3, 0, 3, 0, 2, 0, 2]);
    assert!(
        decode(encoding::RRE, Rect::new(0, 0, 4, 4), &bad, &mut fb, &mut Decoders::default())
            .is_err()
    );
}

#[test]
fn hextile_raw_and_subrect_tiles() {
    // 20x16: one full 16x16 tile and one 4x16 tile.
    let mut fb = Framebuffer::new(20, 16).unwrap();
    let mut wire = vec![2 | 4 | 8];
    wire.extend_from_slice(&rgbx(BLUE)); // background
    wire.extend_from_slice(&rgbx(RED)); // foreground
    wire.push(1);
    wire.extend_from_slice(&[0x23, 0x10]); // x 2, y 3, 2x1
    wire.push(1); // raw tile 4x16
    for _ in 0..64 {
        wire.extend_from_slice(&rgbx(GREEN));
    }
    decode(encoding::HEXTILE, Rect::new(0, 0, 20, 16), &wire, &mut fb, &mut Decoders::default())
        .unwrap();
    assert_eq!(pixel(&fb, 0, 0), BLUE);
    assert_eq!(pixel(&fb, 2, 3), RED);
    assert_eq!(pixel(&fb, 3, 3), RED);
    assert_eq!(pixel(&fb, 4, 3), BLUE);
    assert_eq!(pixel(&fb, 19, 15), GREEN);
}

#[test]
fn zlib_keeps_its_stream_across_rectangles() {
    let mut fb = Framebuffer::new(2, 2).unwrap();
    let mut decoders = Decoders::default();
    let mut stream = Compress::new(Compression::default(), true);
    for color in [RED, GREEN] {
        let raw: Vec<u8> = (0..4).flat_map(|_| rgbx(color)).collect();
        let data = deflate(&mut stream, &raw);
        let mut wire = (data.len() as u32).to_be_bytes().to_vec();
        wire.extend_from_slice(&data);
        decode(encoding::ZLIB, Rect::new(0, 0, 2, 2), &wire, &mut fb, &mut decoders).unwrap();
        assert_eq!(pixel(&fb, 1, 1), color);
    }
}

#[test]
fn zrle_subencodings() {
    // 70x2: two tiles (64 and 6 wide) in one rectangle, then more rectangles
    // on the same stream.
    let mut fb = Framebuffer::new(70, 2).unwrap();
    let mut decoders = Decoders::default();
    let mut stream = Compress::new(Compression::default(), true);
    let mut send = |payload: &[u8], rect: Rect, fb: &mut Framebuffer, decoders: &mut Decoders| {
        let data = deflate(&mut stream, payload);
        let mut wire = (data.len() as u32).to_be_bytes().to_vec();
        wire.extend_from_slice(&data);
        decode(encoding::ZRLE, rect, &wire, fb, decoders)
    };

    // Tile 1 solid red, tile 2 raw.
    let mut payload = vec![1];
    payload.extend_from_slice(&rgb(RED));
    payload.push(0);
    for i in 0..12 {
        payload.extend_from_slice(&rgb(if i % 2 == 0 { GREEN } else { BLUE }));
    }
    send(&payload, Rect::new(0, 0, 70, 2), &mut fb, &mut decoders).unwrap();
    assert_eq!(pixel(&fb, 63, 1), RED);
    assert_eq!(pixel(&fb, 64, 0), GREEN);
    assert_eq!(pixel(&fb, 65, 0), BLUE);

    // Packed palette of 2 (1 bit per pixel), 6x2: rows 0b101010.., 0b010101..
    let mut payload = vec![2];
    payload.extend_from_slice(&rgb(RED));
    payload.extend_from_slice(&rgb(BLUE));
    payload.extend_from_slice(&[0b1010_1000, 0b0101_0100]);
    send(&payload, Rect::new(0, 0, 6, 2), &mut fb, &mut decoders).unwrap();
    assert_eq!(pixel(&fb, 0, 0), BLUE);
    assert_eq!(pixel(&fb, 1, 0), RED);
    assert_eq!(pixel(&fb, 0, 1), RED);
    assert_eq!(pixel(&fb, 5, 1), BLUE);

    // Plain RLE on a 64x2 tile (128 pixels): 100 green, then 28 red.
    let mut payload = vec![128];
    payload.extend_from_slice(&rgb(GREEN));
    payload.push(99); // 100 pixels
    payload.extend_from_slice(&rgb(RED));
    payload.push(27); // 28 pixels
    send(&payload, Rect::new(0, 0, 64, 2), &mut fb, &mut decoders).unwrap();
    assert_eq!(pixel(&fb, 35, 1), GREEN);
    assert_eq!(pixel(&fb, 36, 1), RED);

    // Palette RLE: palette [blue, red]; one blue, then red run of 5 on 6x1.
    let mut payload = vec![130];
    payload.extend_from_slice(&rgb(BLUE));
    payload.extend_from_slice(&rgb(RED));
    payload.extend_from_slice(&[0, 0x81, 4]);
    send(&payload, Rect::new(0, 0, 6, 1), &mut fb, &mut decoders).unwrap();
    assert_eq!(pixel(&fb, 0, 0), BLUE);
    assert_eq!(pixel(&fb, 5, 0), RED);

    // A run past the tile is refused.
    let mut payload = vec![128];
    payload.extend_from_slice(&rgb(GREEN));
    payload.push(200);
    assert!(send(&payload, Rect::new(0, 0, 6, 1), &mut fb, &mut decoders).is_err());
}

#[test]
fn tight_fill_palette_copy_and_gradient() {
    let mut fb = Framebuffer::new(8, 8).unwrap();
    let mut decoders = Decoders::default();

    // Fill.
    let mut wire = vec![0x80];
    wire.extend_from_slice(&rgb(BLUE));
    decode(encoding::TIGHT, Rect::new(0, 0, 8, 8), &wire, &mut fb, &mut decoders).unwrap();
    assert_eq!(pixel(&fb, 7, 7), BLUE);

    // Copy filter, short (uncompressed): 2x1 pixels, 6 bytes.
    let mut wire = vec![0x00];
    wire.extend_from_slice(&rgb(RED));
    wire.extend_from_slice(&rgb(GREEN));
    decode(encoding::TIGHT, Rect::new(0, 0, 2, 1), &wire, &mut fb, &mut decoders).unwrap();
    assert_eq!(pixel(&fb, 0, 0), RED);
    assert_eq!(pixel(&fb, 1, 0), GREEN);

    // Two-color palette on stream 1, 8x4 = 4 bytes (uncompressed, < 12).
    let mut wire = vec![0x50, 1, 1];
    wire.extend_from_slice(&rgb(RED));
    wire.extend_from_slice(&rgb(GREEN));
    wire.extend_from_slice(&[0xF0, 0x0F, 0xFF, 0x00]);
    decode(encoding::TIGHT, Rect::new(0, 0, 8, 4), &wire, &mut fb, &mut decoders).unwrap();
    assert_eq!(pixel(&fb, 0, 0), GREEN);
    assert_eq!(pixel(&fb, 7, 0), RED);
    assert_eq!(pixel(&fb, 7, 1), GREEN);
    assert_eq!(pixel(&fb, 3, 3), RED);

    // Copy filter, compressed on stream 2: 4x4 of blue (48 bytes), compact length.
    let mut stream = Compress::new(Compression::default(), true);
    let raw: Vec<u8> = (0..16).flat_map(|_| rgb(BLUE)).collect();
    let data = deflate(&mut stream, &raw);
    assert!(data.len() < 128);
    let mut wire = vec![0x20, data.len() as u8];
    wire.extend_from_slice(&data);
    decode(encoding::TIGHT, Rect::new(4, 4, 4, 4), &wire, &mut fb, &mut decoders).unwrap();
    assert_eq!(pixel(&fb, 7, 7), BLUE);

    // Gradient: a 2x2 where every sent value is 10: (0,0) = 10, (1,0) = 20,
    // (0,1) = 20, (1,1) = 20 + 20 - 10 + 10 = 40.
    let gradient: Vec<u8> = vec![10; 12];
    let mut stream = Compress::new(Compression::default(), true);
    let data = deflate(&mut stream, &gradient);
    let mut wire = vec![0x40 | 0x10, 2, data.len() as u8];
    wire.extend_from_slice(&data);
    decode(encoding::TIGHT, Rect::new(0, 0, 2, 2), &wire, &mut fb, &mut decoders).unwrap();
    assert_eq!(pixel(&fb, 0, 0), [10, 10, 10, 255]);
    assert_eq!(pixel(&fb, 1, 0), [20, 20, 20, 255]);
    assert_eq!(pixel(&fb, 0, 1), [20, 20, 20, 255]);
    assert_eq!(pixel(&fb, 1, 1), [40, 40, 40, 255]);

    // JPEG was never requested.
    assert!(
        decode(encoding::TIGHT, Rect::new(0, 0, 2, 2), &[0x90, 0], &mut fb, &mut decoders).is_err()
    );
}

#[test]
fn cursor_mask_sets_alpha() {
    let mut wire = Vec::new();
    for _ in 0..4 {
        wire.extend_from_slice(&rgbx(RED));
    }
    wire.extend_from_slice(&[0b1000_0000, 0b0100_0000]);
    let mut reader = WireReader::new(Cursor::new(wire));
    let cursor = cursor(&mut reader, &PixelFormat::RGBX, &Rect::new(1, 0, 2, 2)).unwrap();
    assert_eq!(cursor.hotspot_x, 1);
    assert_eq!(cursor.rgba[3], 255);
    assert_eq!(cursor.rgba[7], 0);
    assert_eq!(cursor.rgba[11], 0);
    assert_eq!(cursor.rgba[15], 255);
}

#[test]
fn unrequested_encodings_and_out_of_bounds_rects_are_refused() {
    let mut fb = Framebuffer::new(4, 4).unwrap();
    assert!(decode(99, Rect::new(0, 0, 1, 1), &[], &mut fb, &mut Decoders::default()).is_err());
    assert!(
        decode(encoding::RAW, Rect::new(3, 3, 2, 2), &[0; 16], &mut fb, &mut Decoders::default())
            .is_err()
    );
}

#[test]
fn a_zlib_bomb_stops_at_the_rectangle_size() {
    let mut fb = Framebuffer::new(2, 2).unwrap();
    let mut stream = Compress::new(Compression::default(), true);
    let data = deflate(&mut stream, &vec![0u8; 1 << 20]);
    let mut wire = (data.len() as u32).to_be_bytes().to_vec();
    wire.extend_from_slice(&data);
    assert!(
        decode(encoding::ZLIB, Rect::new(0, 0, 2, 2), &wire, &mut fb, &mut Decoders::default())
            .is_err()
    );
}
