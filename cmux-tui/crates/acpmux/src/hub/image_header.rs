//! An image's size from its header, read when a prompt image is kept (`prompt_images.rs`
//! `decode`), so the record names it with its bytes and the transcript reserves the image's box
//! before the bytes are read back and decoded: a reopened chat's image never changes height as
//! it loads (cmuxterm-hq docs/design/agent-transcript-clean-slate.md, step 2: "image decode
//! shifts 0 px").
//!
//! PNG, GIF, WebP (lossy, lossless and extended) and JPEG, with a JPEG's EXIF orientation applied
//! as a browser draws it (`image-orientation: from-image`): a phone photo taken upright is taller
//! than its stored pixels are. Anything else (HEIC, AVIF, TIFF, BMP, an SVG) names no size, and
//! the pane measures it as it did before.

/// Width and height in pixels as the image draws, or `None` when the header is not one this reads
/// or names a zero side.
pub(crate) fn image_size(bytes: &[u8]) -> Option<(u32, u32)> {
    let size = png(bytes).or_else(|| gif(bytes)).or_else(|| webp(bytes)).or_else(|| jpeg(bytes))?;
    (size.0 > 0 && size.1 > 0).then_some(size)
}

fn be16(bytes: &[u8], at: usize) -> Option<u32> {
    Some(u32::from(u16::from_be_bytes(bytes.get(at..at + 2)?.try_into().ok()?)))
}

fn le16(bytes: &[u8], at: usize) -> Option<u32> {
    Some(u32::from(u16::from_le_bytes(bytes.get(at..at + 2)?.try_into().ok()?)))
}

fn be32(bytes: &[u8], at: usize) -> Option<u32> {
    Some(u32::from_be_bytes(bytes.get(at..at + 4)?.try_into().ok()?))
}

fn le24(bytes: &[u8], at: usize) -> Option<u32> {
    let b = bytes.get(at..at + 3)?;
    Some(u32::from(b[0]) | u32::from(b[1]) << 8 | u32::from(b[2]) << 16)
}

/// The IHDR chunk, always first: width and height big-endian after its type.
fn png(bytes: &[u8]) -> Option<(u32, u32)> {
    if bytes.get(..8)? != b"\x89PNG\r\n\x1a\n" || bytes.get(12..16)? != b"IHDR" {
        return None;
    }
    Some((be32(bytes, 16)?, be32(bytes, 20)?))
}

/// The logical screen size, little-endian after the signature.
fn gif(bytes: &[u8]) -> Option<(u32, u32)> {
    if !matches!(bytes.get(..6)?, b"GIF87a" | b"GIF89a") {
        return None;
    }
    Some((le16(bytes, 6)?, le16(bytes, 8)?))
}

/// The first chunk of the RIFF container: `VP8X` names the canvas, `VP8 ` a lossy key frame and
/// `VP8L` a lossless bitstream.
fn webp(bytes: &[u8]) -> Option<(u32, u32)> {
    if bytes.get(..4)? != b"RIFF" || bytes.get(8..12)? != b"WEBP" {
        return None;
    }
    match bytes.get(12..16)? {
        b"VP8X" => Some((le24(bytes, 24)? + 1, le24(bytes, 27)? + 1)),
        b"VP8 " => {
            if bytes.get(23..26)? != [0x9d, 0x01, 0x2a] {
                return None;
            }
            Some((le16(bytes, 26)? & 0x3fff, le16(bytes, 28)? & 0x3fff))
        }
        b"VP8L" => {
            if *bytes.get(20)? != 0x2f {
                return None;
            }
            let b = bytes.get(21..25)?;
            let (b0, b1, b2, b3) =
                (u32::from(b[0]), u32::from(b[1]), u32::from(b[2]), u32::from(b[3]));
            Some((1 + (b0 | (b1 & 0x3f) << 8), 1 + (b1 >> 6 | b2 << 2 | (b3 & 0x0f) << 10)))
        }
        _ => None,
    }
}

/// The first start-of-frame marker's size, swapped when the EXIF orientation (APP1) turns the
/// image a quarter turn (5 to 8).
fn jpeg(bytes: &[u8]) -> Option<(u32, u32)> {
    if bytes.get(..3)? != [0xff, 0xd8, 0xff] {
        return None;
    }
    let mut at = 2;
    let mut turned = false;
    loop {
        if *bytes.get(at)? != 0xff {
            return None;
        }
        // Fill bytes before a marker.
        while *bytes.get(at + 1)? == 0xff {
            at += 1;
        }
        let marker = *bytes.get(at + 1)?;
        // Markers that stand alone, with no length.
        if marker == 0x01 || (0xd0..=0xd8).contains(&marker) {
            at += 2;
            continue;
        }
        if marker == 0xd9 || marker == 0xda {
            return None;
        }
        let len = be16(bytes, at + 2)? as usize;
        if len < 2 {
            return None;
        }
        let segment = bytes.get(at + 4..at + 2 + len)?;
        if marker == 0xe1 {
            turned |= exif_orientation(segment).is_some_and(|o| (5..=8).contains(&o));
        }
        // SOF0..SOF15, except DHT (C4), JPG (C8) and DAC (CC).
        if (0xc0..=0xcf).contains(&marker) && !matches!(marker, 0xc4 | 0xc8 | 0xcc) {
            let (height, width) = (be16(segment, 1)?, be16(segment, 3)?);
            return Some(if turned { (height, width) } else { (width, height) });
        }
        at += 2 + len;
    }
}

/// The orientation tag (0x0112) of IFD0 in an APP1 Exif segment.
fn exif_orientation(segment: &[u8]) -> Option<u32> {
    let tiff = segment.strip_prefix(b"Exif\0\0")?;
    let little = match tiff.get(..2)? {
        b"II" => true,
        b"MM" => false,
        _ => return None,
    };
    let u16_at = |at: usize| if little { le16(tiff, at) } else { be16(tiff, at) };
    let u32_at = |at: usize| -> Option<u32> {
        let b: [u8; 4] = tiff.get(at..at + 4)?.try_into().ok()?;
        Some(if little { u32::from_le_bytes(b) } else { u32::from_be_bytes(b) })
    };
    let ifd = u32_at(4)? as usize;
    let count = u16_at(ifd)? as usize;
    (0..count.min(256)).find_map(|n| {
        let entry = ifd + 2 + n * 12;
        (u16_at(entry)? == 0x0112).then(|| u16_at(entry + 8)).flatten()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn png_of(width: u32, height: u32) -> Vec<u8> {
        let mut bytes = b"\x89PNG\r\n\x1a\n\0\0\0\x0dIHDR".to_vec();
        bytes.extend(width.to_be_bytes());
        bytes.extend(height.to_be_bytes());
        bytes.extend([8, 6, 0, 0, 0]);
        bytes
    }

    /// A JPEG's SOI, an optional APP1 Exif with `orientation`, then SOF0 of `width` by `height`.
    fn jpeg_of(width: u16, height: u16, orientation: Option<u16>, little: bool) -> Vec<u8> {
        let mut bytes = vec![0xff, 0xd8];
        if let Some(o) = orientation {
            let (w16, w32): (fn(u16) -> [u8; 2], fn(u32) -> [u8; 4]) = if little {
                (u16::to_le_bytes, u32::to_le_bytes)
            } else {
                (u16::to_be_bytes, u32::to_be_bytes)
            };
            let mut tiff = if little { b"II".to_vec() } else { b"MM".to_vec() };
            tiff.extend(w16(42));
            tiff.extend(w32(8));
            tiff.extend(w16(1));
            tiff.extend(w16(0x0112));
            tiff.extend(w16(3));
            tiff.extend(w32(1));
            tiff.extend(w16(o));
            tiff.extend([0, 0]);
            tiff.extend(w32(0));
            let mut app1 = b"Exif\0\0".to_vec();
            app1.extend(tiff);
            bytes.extend([0xff, 0xe1]);
            bytes.extend(u16::try_from(app1.len() + 2).unwrap().to_be_bytes());
            bytes.extend(app1);
        }
        // A quantization table first, as encoders write it.
        bytes.extend([0xff, 0xdb, 0x00, 0x04, 0x00, 0x00]);
        bytes.extend([0xff, 0xc0, 0x00, 0x11, 0x08]);
        bytes.extend(height.to_be_bytes());
        bytes.extend(width.to_be_bytes());
        bytes.extend([3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1]);
        bytes.extend([0xff, 0xd9]);
        bytes
    }

    #[test]
    fn png_gif_and_webp_headers_name_their_size() {
        assert_eq!(image_size(&png_of(640, 160)), Some((640, 160)));
        let mut gif = b"GIF89a".to_vec();
        gif.extend(300u16.to_le_bytes());
        gif.extend(200u16.to_le_bytes());
        gif.extend([0, 0, 0]);
        assert_eq!(image_size(&gif), Some((300, 200)));

        let riff = |chunk: &[u8], body: &[u8]| {
            let mut bytes = b"RIFF\0\0\0\0WEBP".to_vec();
            bytes.extend(chunk);
            bytes.extend(u32::try_from(body.len()).unwrap().to_le_bytes());
            bytes.extend(body);
            bytes
        };
        // Extended: 24-bit canvas width and height, each less one.
        let mut vp8x = vec![0u8; 4];
        vp8x.extend(&1919u32.to_le_bytes()[..3]);
        vp8x.extend(&1079u32.to_le_bytes()[..3]);
        assert_eq!(image_size(&riff(b"VP8X", &vp8x)), Some((1920, 1080)));
        // Lossy key frame: frame tag, start code, 14-bit sides.
        let mut vp8 = vec![0u8; 3];
        vp8.extend([0x9d, 0x01, 0x2a]);
        vp8.extend(800u16.to_le_bytes());
        vp8.extend(600u16.to_le_bytes());
        assert_eq!(image_size(&riff(b"VP8 ", &vp8)), Some((800, 600)));
        // Lossless: 14-bit sides less one, packed after the signature byte.
        let (w, h) = (1000u32 - 1, 250u32 - 1);
        let packed = w | h << 14;
        let mut vp8l = vec![0x2f];
        vp8l.extend(packed.to_le_bytes());
        assert_eq!(image_size(&riff(b"VP8L", &vp8l)), Some((1000, 250)));
    }

    #[test]
    fn a_jpeg_names_its_frame_size_turned_as_its_exif_orientation_says() {
        assert_eq!(image_size(&jpeg_of(4032, 3024, None, false)), Some((4032, 3024)));
        // Orientation 1 (upright) leaves it; 6 (a phone held upright) turns it a quarter.
        assert_eq!(image_size(&jpeg_of(4032, 3024, Some(1), true)), Some((4032, 3024)));
        assert_eq!(image_size(&jpeg_of(4032, 3024, Some(6), true)), Some((3024, 4032)));
        assert_eq!(image_size(&jpeg_of(4032, 3024, Some(8), false)), Some((3024, 4032)));
    }

    #[test]
    fn other_or_cut_bytes_name_no_size() {
        assert_eq!(image_size(b"<svg xmlns='http://www.w3.org/2000/svg'/>"), None);
        assert_eq!(image_size(&png_of(640, 160)[..20]), None);
        assert_eq!(image_size(&png_of(0, 160)), None);
        let jpeg = jpeg_of(10, 10, None, false);
        assert_eq!(image_size(&jpeg[..12]), None);
        assert_eq!(image_size(&[]), None);
    }
}
