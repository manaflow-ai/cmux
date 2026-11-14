// Leo, 2026-11-14: "picture dimensions were forgotten then reloaded. this is another cause of
// layout shift". A prompt record names each image with its pixel size, and a record from before
// that is sent with its kept image's size, so a view reserves the image's box before its bytes.
use super::{fill_record_sizes, kept_size, pixel_size};
use serde_json::{Value, json};

/// A PNG's signature and IHDR chunk saying `width`×`height` (all a header read needs).
fn png(width: u32, height: u32) -> Vec<u8> {
    let mut out = b"\x89PNG\r\n\x1a\n\0\0\0\x0dIHDR".to_vec();
    out.extend_from_slice(&width.to_be_bytes());
    out.extend_from_slice(&height.to_be_bytes());
    out.extend_from_slice(&[8, 6, 0, 0, 0, 0, 0, 0, 0]);
    out
}

fn image_block(bytes: &[u8], name: &str) -> Value {
    use base64::Engine as _;
    json!({"type": "image", "mimeType": "image/png", "name": name,
           "data": base64::engine::general_purpose::STANDARD.encode(bytes)})
}

#[test]
fn every_header_a_chat_image_has_names_its_size() {
    assert_eq!(pixel_size(&png(1280, 228)), Some((1280, 228)));
    assert_eq!(pixel_size(b"GIF89a\x40\x01\xf0\x00\0\0"), Some((320, 240)));
    // WebP: lossy, lossless and extended.
    let mut vp8 = b"RIFF\0\0\0\0WEBPVP8 \0\0\0\0\0\0\0\x9d\x01\x2a".to_vec();
    vp8.extend_from_slice(&[0x80, 0x02, 0xe0, 0x01]);
    assert_eq!(pixel_size(&vp8), Some((640, 480)));
    let mut vp8l = b"RIFF\0\0\0\0WEBPVP8L\0\0\0\0\x2f".to_vec();
    let bits: u32 = 639 | (479 << 14);
    vp8l.extend_from_slice(&bits.to_le_bytes());
    assert_eq!(pixel_size(&vp8l), Some((640, 480)));
    let mut vp8x = b"RIFF\0\0\0\0WEBPVP8X\0\0\0\0\0\0\0\0".to_vec();
    vp8x.extend_from_slice(&[0x7f, 0x02, 0x00, 0xdf, 0x01, 0x00]);
    assert_eq!(pixel_size(&vp8x), Some((640, 480)));
    // BMP, bottom-up and top-down.
    let mut bmp = b"BM\0\0\0\0\0\0\0\0\x36\0\0\0\x28\0\0\0".to_vec();
    bmp.extend_from_slice(&800i32.to_le_bytes());
    bmp.extend_from_slice(&(-600i32).to_le_bytes());
    assert_eq!(pixel_size(&bmp), Some((800, 600)));
    // JPEG: its frame header past an APP0, then one whose EXIF turns it a quarter (orientation 6).
    let sof = [0xff, 0xc0, 0, 17, 8, 0x02, 0x58, 0x03, 0x20, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    let mut jpeg = b"\xff\xd8\xff\xe0\0\x10JFIF\0\x01\x01\0\0\x01\0\x01\0\0".to_vec();
    jpeg.extend_from_slice(&sof);
    assert_eq!(pixel_size(&jpeg), Some((800, 600)));
    let mut exif = b"Exif\0\0II*\0\x08\0\0\0\x01\0".to_vec();
    exif.extend_from_slice(&[0x12, 0x01, 3, 0, 1, 0, 0, 0, 6, 0, 0, 0]);
    let mut rotated = b"\xff\xd8\xff\xe1".to_vec();
    rotated.extend_from_slice(&((exif.len() + 2) as u16).to_be_bytes());
    rotated.extend_from_slice(&exif);
    rotated.extend_from_slice(&sof);
    assert_eq!(pixel_size(&rotated), Some((600, 800)));
    // Cut short, not an image, or a zero size: none.
    assert_eq!(pixel_size(&png(1280, 228)[..20]), None);
    assert_eq!(pixel_size(&png(0, 228)), None);
    assert_eq!(pixel_size(b"<svg/>"), None);
    assert_eq!(pixel_size(b""), None);
}

/// The record a sent prompt's images get (`images` and `inlineParts`) names each one's size, so
/// the bubble's first frame is its final one: Leo's 1280×228 screenshot drew as a 120 px square
/// slot, then a 320×57 strip once its bytes were read.
#[test]
fn a_sent_images_record_names_its_pixel_size() {
    let bytes = png(1280, 228);
    let blocks = vec![
        image_block(&bytes, "image.png"),
        json!({"type": "text", "text": "what even is this? idk if we shuold have this"}),
    ];
    let images = super::super::prompt_images::named_sourced(&blocks, None);
    assert_eq!(images.len(), 1);
    assert_eq!(
        (images[0]["width"].clone(), images[0]["height"].clone()),
        (json!(1280), json!(228))
    );
    let parts = super::super::prompt_images::inline_parts(&blocks, &images, None);
    let image = parts.iter().find(|part| part["kind"] == "image").expect("an image part");
    assert_eq!((image["width"].clone(), image["height"].clone()), (json!(1280), json!(228)));
    // The webviews browser test (chat-image-first-frame-browser.test.ts) mounts the bubble from
    // this record: it is what acpmux records, field for field.
    let fixture: Value =
        serde_json::from_str(include_str!("image_size_fixture.json")).expect("fixture is JSON");
    let id = images[0]["id"].as_str().unwrap();
    let recorded = json!({"images": images, "inlineParts": parts});
    let expected = serde_json::to_string(&fixture["msg"]).unwrap().replace("{{id}}", id);
    assert_eq!(recorded["images"], serde_json::from_str::<Value>(&expected).unwrap()["images"]);
    assert_eq!(
        recorded["inlineParts"],
        serde_json::from_str::<Value>(&expected).unwrap()["inlineParts"]
    );
}

/// A record written before images carried their size is sent with its kept image's size, read
/// once from the kept file's header; a record that has one, or names an image this machine does
/// not keep, is left as it is.
#[test]
fn an_old_record_is_sent_with_its_kept_images_size() {
    let bytes = png(1280, 229);
    let id = crate::attach::sha256(&bytes);
    let path = super::super::prompt_images::image_path(&id).unwrap();
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(&path, &bytes).unwrap();
    let missing = "0".repeat(64);
    let written = json!({
        "turnId": "t1",
        "text": "what even is this?",
        "images": [{"id": id, "mimeType": "image/png", "name": "image.png"},
                   {"id": missing, "mimeType": "image/png"}],
        "inlineParts": [{"kind": "image", "id": id, "mimeType": "image/png"},
                        {"kind": "text", "text": "what even is this?"}],
    });
    // As every events page, live event and session open sends it.
    let record = crate::store::EventRecord {
        seq: 7,
        at: 1,
        dir: "mux".into(),
        kind: "user_message".into(),
        msg: written.clone(),
        host_seq: None,
    };
    for sent in [
        crate::server::event_value("s", &record),
        crate::server::into_event_value("s", record.clone()),
    ] {
        assert_eq!(sent["msg"]["images"][0]["width"], json!(1280));
        assert_eq!(sent["msg"]["inlineParts"][0]["height"], json!(229));
    }
    let mut old = written;
    fill_record_sizes("user_message", &mut old);
    assert_eq!(old["images"][0]["width"], json!(1280));
    assert_eq!(old["images"][0]["height"], json!(229));
    assert_eq!(old["inlineParts"][0]["width"], json!(1280));
    assert_eq!(old["inlineParts"][0]["height"], json!(229));
    assert!(old["images"][1].get("width").is_none());
    assert!(old["inlineParts"][1].get("width").is_none());
    // An image not kept yet is not remembered as sizeless: once a restore writes it, it is read.
    let late = super::super::prompt_images::image_path(&missing).unwrap();
    std::fs::write(&late, png(640, 100)).unwrap();
    assert_eq!(kept_size(&missing), Some((640, 100)));
    std::fs::remove_file(&late).unwrap();
    // Kept: the file going away does not take the size with it (an id names its bytes).
    std::fs::remove_file(&path).unwrap();
    assert_eq!(kept_size(&id), Some((1280, 229)));
    // A record's own size wins, and only prompt records are read.
    let mut sized =
        json!({"images": [{"id": id, "mimeType": "image/png", "width": 2, "height": 1}]});
    fill_record_sizes("queued", &mut sized);
    assert_eq!(sized["images"][0]["width"], json!(2));
    let mut other = json!({"images": [{"id": id, "mimeType": "image/png"}]});
    fill_record_sizes("agent_message_chunk", &mut other);
    assert!(other["images"][0].get("width").is_none());
}
