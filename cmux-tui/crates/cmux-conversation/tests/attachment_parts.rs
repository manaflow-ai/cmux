//! RED tests for the `attachment` part on the local owner
//! (plans/cmux-next/home-messaging.md section 10.2). They compile against
//! today's crate and fail at run time until the part and its two reject
//! reasons exist. The store-backed checks (`unknown_attachment`,
//! `attachment_mismatch`) run in cmux-tui-core `server/attachment_tests.rs`.

use cmux_conversation::{Op, Reject};
use serde_json::json;

const HASH: &str = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08";
const POSTER: &str = "2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae";

/// RED today: `Part` has no `attachment` variant, so the op does not
/// deserialize ("unknown variant `attachment`").
#[test]
fn an_attachment_part_has_the_cloud_wire_shape_and_round_trips() {
    let wire = json!({
        "kind": "message.send",
        "client_msg_id": "c1",
        "parts": [
            {"type": "text", "text": "clip"},
            {"type": "attachment", "hash": HASH, "name": "clip.mov", "mime_type": "video/quicktime",
             "byte_count": 52_000_000, "width": 1920, "height": 1080, "duration_ms": 12_500,
             "poster": {"hash": POSTER, "mime_type": "image/jpeg", "byte_count": 180_000}}
        ]
    });
    let op: Op =
        serde_json::from_value(wire.clone()).expect("RED today: Part has no `attachment` variant");
    assert_eq!(serde_json::to_value(&op).unwrap(), wire, "absent optionals stay absent");

    let minimal = json!({
        "kind": "message.send",
        "client_msg_id": "c2",
        "parts": [{"type": "attachment", "hash": HASH, "name": "a.pdf",
                   "mime_type": "application/pdf", "byte_count": 10}]
    });
    let op: Op = serde_json::from_value(minimal.clone()).unwrap();
    assert_eq!(serde_json::to_value(&op).unwrap(), minimal);
}

/// RED today: `Reject::ALL` has 20 reasons and neither attachment reason.
#[test]
fn reject_reasons_include_the_cloud_attachment_reasons() {
    let codes: Vec<&str> = Reject::ALL.iter().map(|reject| reject.code()).collect();
    assert!(codes.contains(&"unknown_attachment"), "{codes:?}");
    assert!(codes.contains(&"attachment_mismatch"), "{codes:?}");
    assert_eq!(Reject::ALL.len(), 22);
}
