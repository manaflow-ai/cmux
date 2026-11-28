use super::{Edit, checked_display_parts, moved_display_parts};
use serde_json::{Value, json};

/// Image bytes `bytes` as an ACP image block, and its attachment id.
fn image(bytes: &[u8], name: &str) -> (Value, String) {
    use base64::Engine;
    let data = base64::engine::general_purpose::STANDARD.encode(bytes);
    let block = json!({"type": "image", "mimeType": "image/png", "data": data, "name": name});
    let id = super::super::prompt_images::id_of(&block).expect("an image id");
    (block, id)
}

fn link(name: &str) -> Value {
    json!({"type": "resource_link", "uri": format!("file:///originals/{name}"), "name": name})
}

/// A text edit moves every block after the new text: each image keeps its display part and
/// its original file (`companionOf`) still names it, at its new place.
#[test]
fn a_text_edit_moves_display_parts_with_their_blocks() {
    let (a, _) = image(b"first", "a.png");
    let (b, _) = image(b"second", "b.png");
    let before =
        vec![a, link("a.png"), json!({"type": "text", "text": "look at these"}), b, link("b.png")];
    let parts = json!([
        {"kind": "image", "blockIndex": 0, "name": "Screenshot A.png"},
        {"kind": "file", "blockIndex": 1, "name": "a.png", "companionOf": 0},
        {"kind": "pasted", "blockIndex": 2, "start": 0, "end": 4},
        {"kind": "image", "blockIndex": 3, "name": "Screenshot B.png"},
        {"kind": "file", "blockIndex": 4, "name": "b.png", "companionOf": 3}
    ]);
    let edit = Edit::Text { text: "look again".into(), images: None };
    let (blocks, origin) = edit.blocks(&before);
    assert_eq!(origin, [None, Some(0), Some(1), Some(3), Some(4)]);
    let (moved, dropped) = moved_display_parts(Some(&parts), &origin);
    // The pasted range named the old words, which the edit replaced.
    assert_eq!(dropped, 1);
    assert_eq!(
        moved,
        Some(json!([
            {"kind": "image", "blockIndex": 1, "name": "Screenshot A.png"},
            {"kind": "file", "blockIndex": 2, "name": "a.png", "companionOf": 1},
            {"kind": "image", "blockIndex": 3, "name": "Screenshot B.png"},
            {"kind": "file", "blockIndex": 4, "name": "b.png", "companionOf": 3}
        ]))
    );
    let moved = moved.unwrap();
    for part in moved.as_array().unwrap() {
        let at = part["blockIndex"].as_u64().unwrap() as usize;
        let was = origin[at].unwrap();
        assert_eq!(blocks[at], before[was], "{part} is on another block");
    }
}

/// An edit that keeps one image only: the other's part and its original file's relation are
/// dropped, never moved onto the image that stays (both are named like it).
#[test]
fn a_dropped_image_takes_its_display_parts_with_it() {
    let (a, _) = image(b"first", "shot.png");
    let (b, b_id) = image(b"second", "shot.png");
    let before = vec![a, link("shot.png"), b, link("shot.png")];
    let parts = json!([
        {"kind": "image", "blockIndex": 0, "name": "shot.png"},
        {"kind": "file", "blockIndex": 1, "name": "shot.png", "companionOf": 0},
        {"kind": "image", "blockIndex": 2, "name": "shot.png"},
        {"kind": "file", "blockIndex": 3, "name": "shot.png", "companionOf": 2}
    ]);
    let edit = Edit::Text { text: "the second".into(), images: Some(vec![b_id]) };
    let (blocks, origin) = edit.blocks(&before);
    assert_eq!(origin, [None, Some(1), Some(2), Some(3)]);
    assert_eq!(blocks.len(), 4);
    let (moved, dropped) = moved_display_parts(Some(&parts), &origin);
    assert_eq!(dropped, 2);
    assert_eq!(
        moved,
        Some(json!([
            {"kind": "image", "blockIndex": 2, "name": "shot.png"},
            {"kind": "file", "blockIndex": 3, "name": "shot.png", "companionOf": 2}
        ]))
    );
}

/// A whole new prompt names none of the old blocks, and a part that is not one is dropped.
#[test]
fn a_prompt_edit_and_a_malformed_part_keep_nothing() {
    let (a, _) = image(b"first", "a.png");
    let parts = json!([{"kind": "image", "blockIndex": 0, "name": "a.png"}]);
    let edit = Edit::Prompt(vec![a.clone()]);
    let (_, origin) = edit.blocks(std::slice::from_ref(&a));
    assert_eq!(moved_display_parts(Some(&parts), &origin), (None, 1));
    let origin = [None, Some(0)];
    let bad = json!([
        "image",
        {"kind": "image"},
        {"kind": "image", "blockIndex": "0"},
        {"kind": "file", "blockIndex": 0, "companionOf": 7}
    ]);
    assert_eq!(moved_display_parts(Some(&bad), &origin), (None, 4));
    assert_eq!(moved_display_parts(None, &origin), (None, 0));
}

/// What an edit keeps is checked against the blocks it names now: a part from the log that
/// does not fit its block is refused, and no `companionOf` is kept that does not name the
/// image just before its file.
#[test]
fn kept_parts_are_checked_against_their_blocks() {
    let (a, _) = image(b"first", "a.png");
    let blocks = vec![json!({"type": "text", "text": "hi"}), a, link("a.png")];
    let parts = json!([
        {"kind": "image", "blockIndex": 0, "name": "on the text"},
        {"kind": "image", "blockIndex": 1, "name": "a.png"},
        {"kind": "file", "blockIndex": 2, "name": "a.png", "companionOf": 0},
        {"kind": "file", "blockIndex": 2, "name": "again"}
    ]);
    let (kept, refused) = checked_display_parts(Some(&parts), &blocks);
    let kept = kept.expect("the image's part");
    let kept = kept.as_array().unwrap();
    assert!(kept.iter().all(|p| p.get("companionOf").is_none()), "{kept:?}");
    assert_eq!(kept[0], json!({"kind": "image", "blockIndex": 1, "name": "a.png"}));
    // The text's image part and the second part of block 2 always; the file whose
    // `companionOf` names the text too, where the relation is checked (cmux#25717).
    assert!(refused >= 2, "{refused}");
    assert_eq!(checked_display_parts(None, &blocks), (None, 0));
}
