//! Snapshot request replies, attach parameters and images chunks.

use super::*;

#[test]
fn snapshot_throttled_reply_names_its_request() {
    let reply = request_reply(
        SnapshotAdmission::Throttled { retry_after_ms: 120 },
        7,
        Some("req-42".into()),
        Some("digest_mismatch".into()),
    )
    .unwrap();
    assert_eq!(
        reply,
        json!({
            "status": "snapshot_throttled",
            "retry_after_ms": 120,
            "surface": 7,
            "request_id": "req-42",
            "reason": "digest_mismatch",
        })
    );
    let collapsed =
        request_reply(SnapshotAdmission::Collapsed, 7, Some("req-43".into()), None).unwrap();
    assert_eq!(collapsed["request_id"], "req-43");
    assert!(request_reply(SnapshotAdmission::NotAttached, 7, None, None).is_err());
}

#[test]
fn snapshot_request_accepts_only_spec_reasons_and_bounded_ids() {
    let request =
        |value: Value| -> SnapshotRequestParams { serde_json::from_value(value).unwrap() };
    assert!(validate_request(&request(json!({"surface": 1}))).is_ok());
    for reason in SNAPSHOT_REQUEST_REASONS {
        assert!(validate_request(&request(json!({"surface": 1, "reason": reason}))).is_ok());
    }
    assert!(validate_request(&request(json!({"surface": 1, "reason": "because"}))).is_err());
    let long = "x".repeat(MAX_REQUEST_ID_BYTES + 1);
    assert!(validate_request(&request(json!({"surface": 1, "request_id": long}))).is_err());
    let ok = "x".repeat(MAX_REQUEST_ID_BYTES);
    assert!(validate_request(&request(json!({"surface": 1, "request_id": ok}))).is_ok());
}

/// Images chunks: at most 1 MiB of stream each, at the READY's position,
/// not compressed again; only the last one names `skipped_images`.
#[test]
fn images_chunks_split_the_stream_and_the_last_names_skipped_images() {
    let stream: Vec<u8> = (0..(IMAGES_CHUNK_BYTES * 2 + 17)).map(|i| i as u8).collect();
    let stats = ghostty_vt::KittyReplayStats { images: 1, skipped_images: 2, ..Default::default() };
    let mut pending = PendingImages::of(Arc::new(SnapshotImages { data: stream.clone(), stats }));
    let (mut joined, mut events) = (Vec::new(), Vec::new());
    while let Some((event, done)) = pending.next_chunk(3, (9, 77, 1)) {
        let value = event.into_json();
        assert_eq!(value["phase"], "images");
        assert_eq!((value["generation"].as_u64(), value["offset"].as_u64()), (Some(9), Some(77)));
        assert!(value.get("compression").is_none(), "{value}");
        assert_eq!(value["version"], 1);
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(value["data"].as_str().unwrap())
            .unwrap();
        assert!(bytes.len() <= IMAGES_CHUNK_BYTES);
        joined.extend_from_slice(&bytes);
        assert_eq!(value["done"], done);
        events.push(value);
    }
    assert_eq!(joined, stream);
    assert_eq!(events.len(), 3);
    assert!(events[..2].iter().all(|value| value.get("skipped_images").is_none()));
    assert_eq!(events[2]["skipped_images"], 2);
    assert_eq!(events[2]["done"], true);
}

#[test]
fn snapshot_attach_params_fall_back_on_another_version() {
    let attach = |value: Value| -> SnapshotAttachParams {
        SnapshotAttachParams::of(&serde_json::from_value(value).unwrap())
    };
    let ours = ghostty_vt::snapshot_version();
    let params = attach(json!({"snapshot": "ghostsnp", "snapshot_version": ours}));
    assert!(params.wants_snapshot().unwrap());
    assert_eq!(params.backlog_bytes(), DEFAULT_VIEWER_BACKLOG_BYTES);
    let other = attach(json!({"snapshot": "ghostsnp", "snapshot_version": ours.wrapping_add(1)}));
    assert!(!other.wants_snapshot().unwrap());
    let unknown = attach(json!({"snapshot": "png"}));
    assert!(unknown.wants_snapshot().is_err());
    let tiny = attach(json!({"viewer_backlog_bytes": 1}));
    assert_eq!(tiny.backlog_bytes(), MIN_VIEWER_BACKLOG_BYTES);
    assert_eq!(tiny.images_cap(), None, "images are opt-in");
    let images = attach(json!({"snapshot_images": true}));
    assert_eq!(images.images_cap(), Some(SNAPSHOT_IMAGES_MAX_BYTES));
}
