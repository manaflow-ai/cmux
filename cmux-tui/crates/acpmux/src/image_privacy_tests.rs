use super::*;
use crate::model_copies::tests::{checker_jpeg, halves, pixels};
use serde_json::json;

const SECRET: &[u8] = b"secret 37.7749N 122.4194W";

fn has(haystack: &[u8], needle: &[u8]) -> bool {
    haystack.windows(needle.len()).any(|w| w == needle)
}

fn segment(marker: u8, body: &[u8]) -> Vec<u8> {
    let mut out = vec![0xff, marker];
    out.extend(u16::try_from(body.len() + 2).unwrap().to_be_bytes());
    out.extend(body);
    out
}

/// A big-endian TIFF with the orientation tag and a GPS-like ASCII tag holding [`SECRET`].
fn tiff_with_gps(turn: u16) -> Vec<u8> {
    let mut t = b"MM\0*".to_vec();
    t.extend(8u32.to_be_bytes());
    t.extend(2u16.to_be_bytes());
    t.extend(ORIENTATION_TAG.to_be_bytes());
    t.extend(3u16.to_be_bytes());
    t.extend(1u32.to_be_bytes());
    t.extend(turn.to_be_bytes());
    t.extend([0, 0]);
    // An ASCII tag (0x8298, Copyright) whose text is past the IFD.
    let text_at = 8 + 2 + 2 * 12 + 4;
    t.extend(0x8298u16.to_be_bytes());
    t.extend(2u16.to_be_bytes());
    t.extend(u32::try_from(SECRET.len()).unwrap().to_be_bytes());
    t.extend(u32::try_from(text_at).unwrap().to_be_bytes());
    t.extend(0u32.to_be_bytes());
    t.extend(SECRET);
    t
}

/// A phone's JPEG: EXIF (orientation `turn` and the secret), XMP, IPTC, a comment, and a second
/// picture (MPF) appended after the first one's end.
fn phone_jpeg(turn: u16) -> Vec<u8> {
    let plain = checker_jpeg(32);
    let mut exif = b"Exif\0\0".to_vec();
    exif.extend(tiff_with_gps(turn));
    let mut xmp = b"http://ns.adobe.com/xap/1.0/\0<x:xmpmeta>".to_vec();
    xmp.extend(SECRET);
    let mut iptc = b"Photoshop 3.0\0".to_vec();
    iptc.extend(SECRET);
    let mut out = plain[..2].to_vec();
    out.extend(segment(0xe0, b"JFIF\0\x01\x01\0\0\x01\0\x01\0\0"));
    out.extend(segment(0xe1, &exif));
    out.extend(segment(0xe1, &xmp));
    out.extend(segment(0xed, &iptc));
    out.extend(segment(0xfe, SECRET));
    out.extend(&plain[2..]);
    // The appended picture, with its own EXIF.
    out.extend([0xff, 0xd8]);
    out.extend(segment(0xe1, &exif));
    out.extend(&plain[2..]);
    out
}

fn png_chunk(kind: &[u8; 4], data: &[u8]) -> Vec<u8> {
    let mut out = u32::try_from(data.len()).unwrap().to_be_bytes().to_vec();
    out.extend(kind);
    out.extend(data);
    let crc = crc32(&out[4..]);
    out.extend(crc.to_be_bytes());
    out
}

/// A screenshot PNG with text chunks, a time and EXIF (orientation `turn` and the secret).
fn tagged_png(w: u32, h: u32, turn: u16) -> Vec<u8> {
    let plain = halves(w, h);
    // Signature (8) and IHDR (4 + 4 + 13 + 4).
    let mut out = plain[..33].to_vec();
    let mut text = b"Comment\0".to_vec();
    text.extend(SECRET);
    out.extend(png_chunk(b"tEXt", &text));
    let mut itxt = b"XML:com.adobe.xmp\0\0\0\0\0".to_vec();
    itxt.extend(SECRET);
    out.extend(png_chunk(b"iTXt", &itxt));
    out.extend(png_chunk(b"tIME", &[0x07, 0xea, 11, 17, 12, 0, 0]));
    out.extend(png_chunk(b"eXIf", &tiff_with_gps(turn)));
    out.extend(&plain[33..]);
    out
}

#[test]
fn a_phone_jpeg_loses_its_gps_xmp_iptc_comment_and_appended_picture() {
    let sent = phone_jpeg(6);
    assert!(has(&sent, SECRET));
    let clean = sanitize(&sent).unwrap();
    assert!(!has(&clean, SECRET), "the secret survived");
    assert!(!has(&clean, b"http://ns.adobe.com"), "XMP survived");
    // One picture: one start and one end.
    assert_eq!(clean.windows(2).filter(|w| *w == [0xff, 0xd9]).count(), 1);
    assert!(clean.ends_with(&[0xff, 0xd9]));
    // Upright as before, by a minimal EXIF of the orientation alone.
    assert_eq!(orientation(&clean), 6);
    assert!(clean.len() < sent.len());
    // Still a picture of the same pixels.
    let size = |b: &[u8]| {
        let mut d = zune_jpeg::JpegDecoder::new(zune_core::bytestream::ZCursor::new(b));
        let px = d.decode().unwrap();
        (d.dimensions().unwrap(), px)
    };
    assert_eq!(size(&clean), size(&checker_jpeg(32)));
}

#[test]
fn an_upright_jpeg_keeps_no_exif_at_all() {
    let clean = sanitize(&phone_jpeg(1)).unwrap();
    assert!(!has(&clean, SECRET));
    assert!(!has(&clean, b"Exif\0\0"));
    assert_eq!(orientation(&clean), 1);
}

#[test]
fn a_png_loses_its_text_time_and_exif_but_not_a_pixel() {
    let sent = tagged_png(40, 20, 6);
    let clean = sanitize(&sent).unwrap();
    assert!(!has(&clean, SECRET), "the secret survived");
    assert!(!has(&clean, b"tEXt") && !has(&clean, b"iTXt") && !has(&clean, b"tIME"));
    assert_eq!(orientation(&clean), 6);
    assert_eq!(pixels(&clean), pixels(&halves(40, 20)));
    // Upright and without a tag, only the text goes.
    let upright = sanitize(&tagged_png(40, 20, 1)).unwrap();
    assert!(!has(&upright, b"eXIf"));
    assert_eq!(pixels(&upright), pixels(&halves(40, 20)));
}

#[test]
fn a_clean_png_is_left_as_it_is() {
    assert_eq!(sanitize(&halves(8, 8)), None);
    assert_eq!(sanitize(b"GIF89a not ours"), None);
}

/// The daemon takes a prompt (`server/requests.rs`) and cleans it before the outbox, a peer or
/// the chat's log sees it.
#[tokio::test]
async fn a_prompt_and_a_queued_send_reach_nothing_with_their_metadata() {
    let b64 = |b: &[u8]| base64::engine::general_purpose::STANDARD.encode(b);
    let image = |b: &[u8], mime: &str| json!({"type": "image", "mimeType": mime, "data": b64(b)});
    let blocks = json!([{"type": "text", "text": "look"}, image(&phone_jpeg(6), "image/jpeg"),
                        image(&tagged_png(40, 20, 3), "image/png")]);
    for (m, mut params, pointer) in [
        (
            crate::rpc::method::SESSION_PROMPT,
            json!({"sessionId": "s", "prompt": blocks}),
            "/prompt",
        ),
        (
            crate::rpc::method::MUX_SEND_QUEUE,
            json!({"sessionId": "s", "request": {"prompt": blocks}}),
            "/request/prompt",
        ),
    ] {
        sanitize_prompt(m, &mut params).await;
        let out = params.pointer(pointer).unwrap().as_array().unwrap();
        assert_eq!(out[0]["text"], "look");
        for block in &out[1..] {
            let bytes = base64::engine::general_purpose::STANDARD
                .decode(block["data"].as_str().unwrap())
                .unwrap();
            assert!(!has(&bytes, SECRET), "{m}: the secret survived");
            assert_ne!(orientation(&bytes), 1);
        }
    }
}

#[test]
fn each_orientation_draws_the_picture_as_it_is_seen() {
    // a b c
    // d e f
    let px: Vec<u8> = b"abcdef".to_vec();
    let seen = |turn| {
        let (out, w, h) = orient(px.clone(), 3, 2, 1, turn);
        (String::from_utf8(out).unwrap(), w, h)
    };
    assert_eq!(seen(1), ("abcdef".into(), 3, 2));
    assert_eq!(seen(2), ("cbafed".into(), 3, 2));
    assert_eq!(seen(3), ("fedcba".into(), 3, 2));
    assert_eq!(seen(4), ("defabc".into(), 3, 2));
    assert_eq!(seen(5), ("adbecf".into(), 2, 3));
    assert_eq!(seen(6), ("daebfc".into(), 2, 3));
    assert_eq!(seen(7), ("fcebda".into(), 2, 3));
    assert_eq!(seen(8), ("cfbead".into(), 2, 3));
}

/// A photo taken sideways reaches the model upright: its copy is turned, as the tag says.
#[test]
fn a_turned_picture_reaches_the_model_upright() {
    let limits = crate::model_copies::limits(Some("claude"));
    let (copy, w, h) =
        crate::model_copies::fitted(&sanitize(&tagged_png(40, 20, 6)).unwrap(), limits).unwrap();
    assert_eq!((w, h), (20, 40));
    let (pw, ph, px) = pixels(&copy);
    assert_eq!((pw, ph), (20, 40));
    assert!(!has(&copy, SECRET) && !has(&copy, b"eXIf"));
    // Turned clockwise: the red left half is now the top.
    assert_eq!(&px[..3], &[255, 0, 0]);
    assert_eq!(&px[px.len() - 3..], &[0, 0, 255]);
    let (_, jw, jh) = crate::model_copies::fitted(&phone_jpeg(6), limits).unwrap();
    assert_eq!((jw, jh), (32, 32));
}
