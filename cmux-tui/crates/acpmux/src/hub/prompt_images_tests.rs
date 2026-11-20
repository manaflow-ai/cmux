use super::{
    checked_source, decode, inline_parts, name_image_sources, sniffed_type, validated_display_parts,
};
use serde_json::{Value, json};

#[test]
fn a_kept_files_type_comes_from_its_magic_number() {
    let png = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR";
    assert_eq!(sniffed_type(png), Some("image/png"));
    assert_eq!(sniffed_type(b"\xff\xd8\xff\xe0\0\x10JFIF"), Some("image/jpeg"));
    assert_eq!(sniffed_type(b"GIF89a\x01\0\x01\0"), Some("image/gif"));
    assert_eq!(sniffed_type(b"GIF87a\x01\0\x01\0"), Some("image/gif"));
    assert_eq!(sniffed_type(b"RIFF\x24\0\0\0WEBPVP8 "), Some("image/webp"));
    assert_eq!(sniffed_type(b"BM\x36\0\0\0\0\0\0\0\x36\0\0\0"), Some("image/bmp"));
    assert_eq!(sniffed_type(b"II*\0\x08\0\0\0"), Some("image/tiff"));
    assert_eq!(sniffed_type(b"MM\0*\0\0\0\x08"), Some("image/tiff"));
    assert_eq!(sniffed_type(&ftyp(b"heic", &[b"mif1", b"heic"])), Some("image/heic"));
    assert_eq!(sniffed_type(&ftyp(b"mif1", &[b"mif1", b"miaf"])), Some("image/heif"));
    assert_eq!(sniffed_type(&ftyp(b"avif", &[b"avif", b"mif1", b"miaf"])), Some("image/avif"));
    assert_eq!(sniffed_type(b"%PDF-1.7\n"), Some("application/pdf"));
    // Text, a short or truncated header, another ISO brand, or nothing: no type.
    assert_eq!(sniffed_type(b"<svg xmlns='http://www.w3.org/2000/svg'/>"), None);
    assert_eq!(sniffed_type(b"\x89PNG"), None);
    assert_eq!(sniffed_type(b"BM"), None);
    assert_eq!(sniffed_type(&ftyp(b"isom", &[b"isom", b"mp41"])), None);
    assert_eq!(sniffed_type(b"\0\0\0\x18ftyp"), None);
    assert_eq!(sniffed_type(b""), None);
}

/// An ISO-BMFF `ftyp` box with `major` and `compatible` brands, its size its own length,
/// followed by the start of the next box (as a file's `meta` follows its `ftyp`).
fn ftyp(major: &[u8; 4], compatible: &[&[u8; 4]]) -> Vec<u8> {
    let size = 16 + 4 * compatible.len() as u32;
    let mut out = size.to_be_bytes().to_vec();
    out.extend_from_slice(b"ftyp");
    out.extend_from_slice(major);
    out.extend_from_slice(&0u32.to_be_bytes());
    for brand in compatible {
        out.extend_from_slice(*brand);
    }
    out.extend_from_slice(b"\0\0\0\x08meta");
    out
}

/// An HEIF file's type is its whole `ftyp` box (major and compatible brands, as libavif's
/// read.c reads it), never its major brand alone; a box cut short names no type.
#[test]
fn an_iso_media_files_type_comes_from_its_whole_ftyp_box() {
    // AVIF named only among the compatible brands, behind an HEIF major brand.
    assert_eq!(sniffed_type(&ftyp(b"mif1", &[b"mif1", b"avif", b"miaf"])), Some("image/avif"));
    assert_eq!(sniffed_type(&ftyp(b"msf1", &[b"msf1", b"avis"])), Some("image/avif"));
    // HEIC the same way.
    assert_eq!(sniffed_type(&ftyp(b"mif1", &[b"mif1", b"heic"])), Some("image/heic"));
    // A brand past the end of the box is the next box's, not this one's.
    let mut outside = ftyp(b"mif1", &[b"mif1"]);
    outside.truncate(20);
    outside.extend_from_slice(b"avif");
    assert_eq!(sniffed_type(&outside), Some("image/heif"));
    // Cut short: 12 bytes of an AVIF header, a box longer than the file, a box shorter than
    // its header, and compatible brands that are not whole.
    assert_eq!(sniffed_type(b"\0\0\0\x18ftypavif"), None);
    let whole = ftyp(b"avif", &[b"avif", b"mif1"]);
    assert_eq!(sniffed_type(&whole[..20]), None);
    assert_eq!(sniffed_type(b"\0\0\0\x08ftypavif\0\0\0\0"), None);
    assert_eq!(sniffed_type(b"\0\0\0\x12ftypavif\0\0\0\0av"), None);
    // A box that runs to the end of the file (size 0), and one with a 64-bit size.
    assert_eq!(sniffed_type(b"\0\0\0\0ftypmif1\0\0\0\0mif1avif"), Some("image/avif"));
    let mut large = 1u32.to_be_bytes().to_vec();
    large.extend_from_slice(b"ftyp");
    large.extend_from_slice(&28u64.to_be_bytes());
    large.extend_from_slice(b"mif1\0\0\0\0heic");
    assert_eq!(sniffed_type(&large), Some("image/heic"));
    // A 64-bit size cut off, one below its own header and brands, and one past any file.
    assert_eq!(sniffed_type(&large[..12]), None);
    let mut small = large.clone();
    small[8..16].copy_from_slice(&20u64.to_be_bytes());
    assert_eq!(sniffed_type(&small), None);
    let mut huge = large.clone();
    huge[8..16].copy_from_slice(&u64::MAX.to_be_bytes());
    assert_eq!(sniffed_type(&huge), None);
}

#[test]
fn an_attachments_source_is_kept_only_when_it_is_one() {
    let image = json!({"type": "image", "mimeType": "image/png", "data": "AQID"});
    let link = json!({"type": "resource_link", "uri": "file:///tmp/a.png", "name": "a.png"});
    let blocks = [image.clone(), link];
    let chrome =
        json!({"name": "Google Chrome", "bundleId": "com.google.Chrome", "site": "github.com"});
    let finder = json!({"name": "Finder", "bundleId": "com.apple.finder"});
    let display = json!([
        {"kind": "image", "blockIndex": 0, "source": chrome},
        {"kind": "file", "blockIndex": 1, "name": "a.png", "source": finder},
    ]);
    let parts = inline_parts(&blocks, &[], Some(&display));
    assert_eq!(parts[0]["source"], chrome);
    assert_eq!(parts[1]["source"], finder);
    let mut images = vec![(0, decode(&image).unwrap().1)];
    name_image_sources(&mut images, &blocks, Some(&display));
    assert_eq!(images[0].1["source"], chrome);
    // Byte-identical images share an id; each record keeps only its own block's source.
    let twins = [image.clone(), image.clone(), image.clone()];
    let display = json!([
        {"kind": "image", "blockIndex": 1, "source": chrome},
        {"kind": "image", "blockIndex": 2, "source": finder},
    ]);
    let mut images: Vec<_> = (0..3).map(|index| (index, decode(&image).unwrap().1)).collect();
    name_image_sources(&mut images, &twins, Some(&display));
    assert!(images[0].1.get("source").is_none());
    assert_eq!(images[1].1["source"], chrome);
    assert_eq!(images[2].1["source"], finder);
    assert_eq!(checked_source(&json!({"name": " cmux "})), Some(json!({"name": "cmux"})));
    for bad in [
        json!({"name": ""}),
        json!({"name": "x".repeat(65)}),
        json!({"name": "A", "bundleId": "no dots"}),
        json!({"name": "A", "bundleId": ".com.x"}),
        json!({"name": "A", "bundleId": 7}),
        json!({"name": "A", "site": "Example.com"}),
        json!({"name": "A", "site": "a.com/path"}),
        json!("cmux"),
    ] {
        assert_eq!(checked_source(&bad), None, "{bad}");
        let display = json!([{"kind": "image", "blockIndex": 0, "source": bad}]);
        let parts = inline_parts(&blocks[..1], &[], Some(&display));
        assert!(parts[0].get("source").is_none());
    }
    // A block's own `_meta` names no source: it never reaches the record.
    let meta = json!({"type": "image", "mimeType": "image/png", "data": "AQID", "_meta": {"cmux": {"source": chrome}}});
    assert!(decode(&meta).unwrap().1.get("source").is_none());
}

#[test]
fn inline_parts_keep_acp_order_without_attachment_bytes() {
    let image = json!({
        "type": "image",
        "mimeType": "image/png",
        "name": "one.png",
        "data": "AQID"
    });
    let kept = vec![decode(&image).unwrap().1];
    let blocks = vec![
        json!({"type": "text", "text": "before", "_meta": {"cmux": {"pasted": true}}}),
        image,
        json!({"type": "text", "text": "after"}),
        json!({"type": "document", "mimeType": "application/pdf", "name": "brief.pdf", "data": "JVBERi0="}),
        json!({"type": "resource_link", "uri": "attachment://notes.txt", "name": "notes.txt"}),
    ];

    let parts = inline_parts(&blocks, &kept, None);
    assert_eq!(
        parts.iter().map(|part| part["kind"].as_str().unwrap()).collect::<Vec<_>>(),
        ["text", "image", "text", "document", "file"]
    );
    assert_eq!(parts[0]["pasted"], true);
    assert_eq!(parts[1]["id"], kept[0]["id"]);
    assert_eq!(parts[3]["size"], 5);
    assert!(parts.iter().all(|part| part.get("data").is_none()));
}

#[test]
fn inline_parts_preserve_a_failed_middle_image_identity() {
    let image = |data: &str, name: &str| json!({"type": "image", "mimeType": "image/png", "name": name, "data": data});
    let first = image("AQID", "first.png");
    let middle = image("BAUG", "middle.png");
    let last = image("BwgJ", "last.png");
    let blocks =
        vec![first.clone(), json!({"type": "text", "text": "caption"}), middle, last.clone()];
    let kept = vec![decode(&first).unwrap().1, decode(&last).unwrap().1];

    let parts = inline_parts(&blocks, &kept, None);
    let ids: Vec<_> =
        parts.iter().filter_map(|part| part.get("id").and_then(Value::as_str)).collect();
    assert_eq!(ids.len(), 3, "all image slots retain their content ids");
    assert_eq!(parts[1]["kind"], "text");
    assert_eq!(parts[2]["persisted"], false);
    assert_eq!(parts[3]["id"], kept[1]["id"]);
}

#[test]
fn inline_parts_rehydrate_text_file_chip_from_display_metadata() {
    let blocks = vec![json!({"type": "text", "text": "notes.txt\n```\nbody\n```"})];
    let display = json!([{"kind": "file", "blockIndex": 0, "name": "notes.txt", "mimeType": "text/plain", "size": 4}]);
    let parts = inline_parts(&blocks, &[], Some(&display));
    assert_eq!(
        parts,
        vec![
            json!({"kind": "file", "name": "notes.txt", "mimeType": "text/plain", "size": 4, "text": "notes.txt\n```\nbody\n```"})
        ]
    );
}

#[test]
fn nameless_text_file_metadata_falls_back_to_text() {
    let blocks = vec![json!({"type": "text", "text": "body"})];
    let display = json!([{"kind": "file", "blockIndex": 0}]);
    assert_eq!(
        inline_parts(&blocks, &[], Some(&display)),
        vec![json!({"kind": "text", "text": "body"})]
    );
}

#[test]
fn display_metadata_matches_blocks_and_bounds_ranges() {
    let blocks = vec![
        json!({"type": "text", "text": "abcd"}),
        json!({"type": "image", "mimeType": "image/png", "data": "AQID"}),
    ];
    let valid = json!([
        {"kind": "pasted", "blockIndex": 0, "name": "Pasted text", "start": 1, "end": 3},
        {"kind": "image", "blockIndex": 1, "name": "one.png"}
    ]);
    assert_eq!(validated_display_parts(Some(&valid), &blocks).len(), 2);
    let wrong_kind = json!([{"kind": "image", "blockIndex": 0}]);
    assert!(validated_display_parts(Some(&wrong_kind), &blocks).is_empty());
    let out_of_bounds = json!([{"kind": "pasted", "blockIndex": 0, "start": 1, "end": 5}]);
    assert!(validated_display_parts(Some(&out_of_bounds), &blocks).is_empty());
    let empty_resource = json!([{"kind": "file", "blockIndex": 0, "name": "archive.zip"}]);
    let resource_block = vec![json!({"type": "resource_link", "uri": "", "name": "archive.zip"})];
    assert!(validated_display_parts(Some(&empty_resource), &resource_block).is_empty());
}
/// The app marks the attachments its composer placed in the text (`placed`); the web
/// transcript draws only those prompts in their recorded order. The marker survives
/// validation and the copy onto every part kind it can name; a prompt without it (the old
/// unplaced shape, or one recorded before the marker) never gains one, and only `true` counts.
#[test]
fn inline_parts_keep_the_placed_marker_only_when_sent() {
    let image =
        json!({"type": "image", "mimeType": "image/png", "name": "one.png", "data": "AQID"});
    let blocks = vec![
        json!({"type": "text", "text": "look"}),
        image,
        json!({"type": "text", "text": "pasted", "_meta": {"cmux": {"pasted": true}}}),
        json!({"type": "resource_link", "uri": "file:///tmp/key.pem", "name": "key.pem"}),
    ];
    let placed = json!([
        {"kind": "image", "blockIndex": 1, "name": "one.png", "placed": true},
        {"kind": "pasted", "blockIndex": 2, "name": "Pasted text", "placed": true},
        {"kind": "file", "blockIndex": 3, "name": "key.pem", "placed": true}
    ]);
    let validated = validated_display_parts(Some(&placed), &blocks);
    assert!((1..=3).all(|index| validated[&index]["placed"] == true));
    let parts = inline_parts(&blocks, &[], Some(&placed));
    assert_eq!(
        parts.iter().map(|part| part.get("placed").cloned()).collect::<Vec<_>>(),
        [None, Some(json!(true)), Some(json!(true)), Some(json!(true))]
    );

    let unplaced = json!([{"kind": "file", "blockIndex": 3, "name": "key.pem"}]);
    assert!(
        inline_parts(&blocks, &[], Some(&unplaced)).iter().all(|part| part.get("placed").is_none())
    );
    assert!(inline_parts(&blocks, &[], None).iter().all(|part| part.get("placed").is_none()));
    for invalid in [json!(false), json!("yes"), json!(1)] {
        let display = json!([{"kind": "image", "blockIndex": 1, "placed": invalid}]);
        assert!(
            inline_parts(&blocks, &[], Some(&display))
                .iter()
                .all(|part| part.get("placed").is_none())
        );
    }
}

#[test]
fn inline_parts_validate_companion_relation() {
    let image = json!({"type": "image", "mimeType": "image/png", "data": "AQID"});
    let file = json!({"type": "resource_link", "name": "one.png", "uri": "file:///tmp/one.png"});
    let blocks =
        vec![image.clone(), file.clone(), json!({"type": "text", "text": "between"}), image, file];
    let display = json!([
        {"kind": "file", "blockIndex": 1, "companionOf": 0},
        {"kind": "file", "blockIndex": 4, "companionOf": 3}
    ]);
    let parts = inline_parts(&blocks, &[], Some(&display));
    assert_eq!(parts[0]["id"], parts[3]["id"], "same bytes, distinct block identities");
    assert_eq!(parts[0]["blockIndex"], 0);
    assert_eq!(parts[1]["companionOf"], 0);
    assert_eq!(parts[3]["blockIndex"], 3);
    assert_eq!(parts[4]["companionOf"], 3);
    assert_eq!(parts[1]["uri"], "file:///tmp/one.png", "the file is still delivered");
    for (block, target) in [(1, 2), (1, 99), (1, -1), (0, 3), (4, 0)] {
        let invalid = json!([{"kind": if block == 0 { "image" } else { "file" }, "blockIndex": block, "companionOf": target}]);
        let parts = inline_parts(&blocks, &[], Some(&invalid));
        assert!(parts.iter().all(|part| part.get("companionOf").is_none()));
    }
}
