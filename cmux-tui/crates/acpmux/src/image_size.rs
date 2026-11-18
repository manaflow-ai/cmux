//! An image's pixel size from the first bytes of its file: PNG, GIF, WebP and JPEG (with its EXIF
//! orientation, so a rotated photo is the shape it draws at). The prompt's `user_message` records it
//! with each image (`prompt_images.rs`), so a client reserves the image's own box before it reads the
//! bytes, and nothing moves when they land. Leo, 2026-11-18: "I was thinking we'd be able to
//! calculate each beforehand everything that would move and just go ok well nothing else usually
//! should". The web pane reads the same header for a data URL it holds (imageEntries.ts
//! `dataUrlImageSize`); this is that reader for the bytes acpmux keeps.

/// The width and height `bytes`' header declares, or `None` for another format or a header too
/// short to read. Reads at most the JPEG segments before its first frame header.
pub(crate) fn pixel_size(bytes: &[u8]) -> Option<(u32, u32)> {
    let sized = |width: u32, height: u32| (width > 0 && height > 0).then_some((width, height));
    if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        // The IHDR chunk comes first: its width and height.
        if bytes.get(12..16)? != b"IHDR" {
            return None;
        }
        return sized(u32_be(bytes, 16)?, u32_be(bytes, 20)?);
    }
    if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        // The logical screen size.
        return sized(u16_le(bytes, 6)?, u16_le(bytes, 8)?);
    }
    if bytes.starts_with(b"RIFF") && bytes.get(8..12)? == b"WEBP" {
        return match bytes.get(12..16)? {
            b"VP8 " => sized(u16_le(bytes, 26)? & 0x3fff, u16_le(bytes, 28)? & 0x3fff),
            b"VP8L" => {
                let bits = u32_le(bytes, 21)?;
                sized((bits & 0x3fff) + 1, ((bits >> 14) & 0x3fff) + 1)
            }
            b"VP8X" => sized(1 + u24_le(bytes, 24)?, 1 + u24_le(bytes, 27)?),
            _ => None,
        };
    }
    if bytes.starts_with(b"\xff\xd8") {
        return jpeg_size(bytes);
    }
    None
}

/// A JPEG's size from its first start-of-frame segment, its sides swapped when an EXIF orientation
/// before it turns the image a quarter turn (5 to 8).
fn jpeg_size(bytes: &[u8]) -> Option<(u32, u32)> {
    let mut rotated = false;
    let mut at = 2;
    loop {
        if *bytes.get(at)? != 0xff {
            return None;
        }
        let marker = *bytes.get(at + 1)?;
        // Fill bytes, and the markers that carry no length.
        if marker == 0xff {
            at += 1;
            continue;
        }
        if marker == 0x01 || (0xd0..=0xd7).contains(&marker) {
            at += 2;
            continue;
        }
        let length = usize::try_from(u16_be(bytes, at + 2)?).ok()?;
        if length < 2 {
            return None;
        }
        if marker == 0xe1 {
            rotated |= bytes.get(at + 4..at + 2 + length).is_some_and(exif_rotates);
        }
        // SOF0 to SOF15, but not DHT (C4), JPG (C8) or DAC (CC).
        if (0xc0..=0xcf).contains(&marker) && !matches!(marker, 0xc4 | 0xc8 | 0xcc) {
            let (height, width) = (u16_be(bytes, at + 5)?, u16_be(bytes, at + 7)?);
            let (width, height) = if rotated { (height, width) } else { (width, height) };
            return (width > 0 && height > 0).then_some((width, height));
        }
        at += 2 + length;
    }
}

/// Whether an APP1 segment's EXIF orientation (tag 0x0112 in IFD0) turns the image a quarter turn.
fn exif_rotates(segment: &[u8]) -> bool {
    let Some(tiff) = segment.strip_prefix(b"Exif\0\0") else { return false };
    let little = tiff.starts_with(b"II");
    let u16_at = |at: usize| if little { u16_le(tiff, at) } else { u16_be(tiff, at) };
    let u32_at = |at: usize| if little { u32_le(tiff, at) } else { u32_be(tiff, at) };
    let Some(ifd) = u32_at(4).and_then(|offset| usize::try_from(offset).ok()) else { return false };
    let Some(count) = u16_at(ifd) else { return false };
    (0..count as usize)
        .map(|index| ifd + 2 + index * 12)
        .map_while(|entry| Some((u16_at(entry)?, u16_at(entry + 8)?)))
        .find(|(tag, _)| *tag == 0x0112)
        .is_some_and(|(_, orientation)| (5..=8).contains(&orientation))
}

fn u16_be(bytes: &[u8], at: usize) -> Option<u32> {
    Some(u32::from(u16::from_be_bytes(bytes.get(at..at + 2)?.try_into().ok()?)))
}

fn u16_le(bytes: &[u8], at: usize) -> Option<u32> {
    Some(u32::from(u16::from_le_bytes(bytes.get(at..at + 2)?.try_into().ok()?)))
}

fn u24_le(bytes: &[u8], at: usize) -> Option<u32> {
    let b = bytes.get(at..at + 3)?;
    Some(u32::from(b[0]) | u32::from(b[1]) << 8 | u32::from(b[2]) << 16)
}

fn u32_be(bytes: &[u8], at: usize) -> Option<u32> {
    Some(u32::from_be_bytes(bytes.get(at..at + 4)?.try_into().ok()?))
}

fn u32_le(bytes: &[u8], at: usize) -> Option<u32> {
    Some(u32::from_le_bytes(bytes.get(at..at + 4)?.try_into().ok()?))
}

#[cfg(test)]
mod tests {
    use super::pixel_size;

    fn png(width: u32, height: u32) -> Vec<u8> {
        let mut bytes = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR".to_vec();
        bytes.extend(width.to_be_bytes());
        bytes.extend(height.to_be_bytes());
        bytes.extend([8, 6, 0, 0, 0]);
        bytes
    }

    /// A JPEG with an APP1 EXIF orientation (when given) and a SOF0 of `width`x`height`.
    fn jpeg(width: u16, height: u16, orientation: Option<u16>) -> Vec<u8> {
        let mut bytes = vec![0xff, 0xd8];
        if let Some(orientation) = orientation {
            let mut exif = b"Exif\0\0MM\0\x2a\0\0\0\x08".to_vec();
            exif.extend([0, 1]); // one IFD0 entry
            exif.extend([0x01, 0x12, 0, 3, 0, 0, 0, 1]);
            exif.extend(orientation.to_be_bytes());
            exif.extend([0, 0]);
            exif.extend([0, 0, 0, 0]);
            bytes.extend([0xff, 0xe1]);
            bytes.extend(u16::try_from(exif.len() + 2).unwrap().to_be_bytes());
            bytes.extend(exif);
        }
        bytes.extend([0xff, 0xc0, 0, 17, 8]);
        bytes.extend(height.to_be_bytes());
        bytes.extend(width.to_be_bytes());
        bytes.extend([3; 10]);
        bytes
    }

    #[test]
    fn a_png_gif_and_webp_name_their_size() {
        assert_eq!(pixel_size(&png(1568, 74)), Some((1568, 74)));
        let mut gif = b"GIF89a".to_vec();
        gif.extend([0x20, 0x03, 0x58, 0x02]);
        assert_eq!(pixel_size(&gif), Some((800, 600)));
        let mut lossless = b"RIFF\0\0\0\0WEBPVP8L\0\0\0\0\x2f".to_vec();
        // 400x300: width-1 in 14 bits, then height-1.
        lossless.extend(((399u32) | (299u32 << 14)).to_le_bytes());
        assert_eq!(pixel_size(&lossless), Some((400, 300)));
        let mut extended = b"RIFF\0\0\0\0WEBPVP8X\0\0\0\0\0\0\0\0".to_vec();
        extended.extend([0x1f, 0x05, 0x00, 0xcf, 0x02, 0x00]);
        assert_eq!(pixel_size(&extended), Some((1312, 720)));
    }

    #[test]
    fn a_jpeg_is_the_shape_it_draws_at() {
        assert_eq!(pixel_size(&jpeg(4032, 3024, None)), Some((4032, 3024)));
        assert_eq!(pixel_size(&jpeg(4032, 3024, Some(1))), Some((4032, 3024)));
        // Orientation 6: the camera held upright, drawn portrait.
        assert_eq!(pixel_size(&jpeg(4032, 3024, Some(6))), Some((3024, 4032)));
    }

    #[test]
    fn a_short_or_unknown_header_names_no_size() {
        assert_eq!(pixel_size(b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR"), None);
        assert_eq!(pixel_size(&png(0, 10)), None);
        assert_eq!(pixel_size(b"<svg width='4' height='4'/>"), None);
        assert_eq!(pixel_size(&[0xff, 0xd8, 0xff]), None);
        assert_eq!(pixel_size(&[]), None);
    }
}
