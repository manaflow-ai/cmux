use super::{QueueLimits, bytes, room};
use crate::config::Config;
use serde_json::json;

#[test]
fn limits_default_and_zero_is_no_limit() {
    let mut cfg = Config::default();
    assert_eq!(
        QueueLimits::of(&cfg),
        QueueLimits {
            prompts: Some(QueueLimits::DEFAULT_PROMPTS),
            bytes: Some(QueueLimits::DEFAULT_BYTES)
        }
    );
    cfg.queue_max_prompts = Some(0);
    cfg.queue_max_bytes = Some(5);
    assert_eq!(QueueLimits::of(&cfg), QueueLimits { prompts: None, bytes: Some(5) });
}

#[test]
fn bytes_follow_the_json_size() {
    let image = "A".repeat(1 << 20);
    let block = json!({"type": "image", "mimeType": "image/png", "data": image});
    let json_len = block.to_string().len() as u64;
    let counted = bytes(&block);
    assert!(counted >= json_len, "{counted} < {json_len}");
    assert!(counted < json_len + 64, "{counted} vs {json_len}");
    // Separators, numbers at any length and nesting are never counted below their JSON.
    for v in [
        json!(["", ""]),
        json!([12345678901234567890u64, -1.5e300, true, null, {}]),
        json!({"a": [[], {"b": [1, 2, 3]}], "c": "d"}),
        json!(["line\none\ttab \"quoted\" back\\slash \u{1}"]),
        json!({"\"key\"": "\n\n\n"}),
    ] {
        assert!(bytes(&v) >= v.to_string().len() as u64, "{v}: {}", bytes(&v));
    }
}

#[test]
fn prompts_waiting_for_the_turn_lock_count_against_the_limit() {
    let limits = QueueLimits { prompts: Some(2), bytes: None };
    // None in the queue yet, but two wait for the turn lock.
    let error = room(&[], 2, 0, 1, |_| false, limits).expect_err("room past the limit");
    assert_eq!(error.data.unwrap()["reason"], "queue.full");
    room(&[], 1, 0, 1, |_| false, limits).unwrap();
}

#[test]
fn what_waiting_digests_took_counts_against_the_byte_limit() {
    let limits = QueueLimits { prompts: None, bytes: Some(100) };
    let error = room(&[], 0, 90, 11, |_| false, limits).expect_err("room past the limit");
    let data = error.data.unwrap();
    assert_eq!(data["reason"], "queue.bytes");
    assert_eq!(data["queuedBytes"], 90);
    room(&[], 0, 90, 10, |_| false, limits).unwrap();
}
