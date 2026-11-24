//! The cold batch's decisions (`cold_wake.rs`): when a chat is cold, how long its window is, and
//! when it compacts first. End to end through the inbox: `inbox_tests.rs`
//! `fifty_messages_to_a_cold_large_idle_chat_go_in_as_one_notice_at_its_batch`.

use super::*;

fn meta(expires: Option<u64>, ended: Option<u64>, used: u64) -> SessionMeta {
    let mut usage = json!({"sessionUpdate": "usage_update", "used": used, "size": 1_000_000});
    if let Some(at) = expires {
        usage["_meta"] = json!({"acpmux": {"cacheExpiresAt": at}});
    }
    let m = json!({"schema": crate::store::META_SCHEMA, "id": "c", "name": "c", "harness": "claude",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 2});
    let mut m: SessionMeta = serde_json::from_value(m).unwrap();
    m.usage = Some(usage);
    m.last_turn = ended.map(|e| json!({"turnId": "t", "endedAt": e}));
    m
}

#[test]
fn a_chat_is_cold_once_its_cache_lapsed() {
    let now = 10_000_000;
    let (big, bigger) = (MIN_BATCH_TOKENS, MIN_BATCH_TOKENS + 9);
    assert_eq!(coldness(&meta(Some(now + 1), None, big), now), None, "warm");
    assert_eq!(coldness(&meta(Some(now - 7), None, big), now), Some((7, big)));
    assert_eq!(coldness(&meta(Some(now - 7), None, big - 1), now), None, "too small to batch");
    assert_eq!(coldness(&meta(None, None, big), now), None, "nothing says when it lapses");
    let ended = now - NO_EXPIRY_TTL_MS - 3;
    assert_eq!(
        coldness(&meta(None, Some(ended), bigger), now),
        Some((3, bigger)),
        "the default lifetime"
    );
    // A later turn that named no expiry still warmed it.
    assert_eq!(coldness(&meta(Some(now - 100), Some(now - 1), bigger), now), None);
}

#[test]
fn the_window_grows_with_the_context_and_the_cold() {
    assert_eq!(window_ms(0, 0), MIN_WINDOW_MS);
    assert_eq!(window_ms(0, SIZE_FULL_TOKENS), MAX_WINDOW_MS);
    assert_eq!(window_ms(COLD_FULL_MS, 0), MAX_WINDOW_MS);
    assert_eq!(window_ms(10 * COLD_FULL_MS, 10 * SIZE_FULL_TOKENS), MAX_WINDOW_MS, "capped");
    let half = window_ms(0, SIZE_FULL_TOKENS / 2);
    assert_eq!(half, MIN_WINDOW_MS + (MAX_WINDOW_MS - MIN_WINDOW_MS) / 2);
    assert_eq!(window_ms(COLD_FULL_MS / 2, SIZE_FULL_TOKENS / 4), half, "the larger share");
}

#[test]
fn a_large_cold_batch_compacts_first_and_its_compaction_is_acpmuxs() {
    assert!(compacts(COMPACT_ABOVE_TOKENS));
    assert!(!compacts(COMPACT_ABOVE_TOKENS - 1));
    let ours = json!({"kind": KIND});
    assert!(is_own(Some(&ours)));
    assert!(!super::super::inbox::persons_prompt(None, Some(&ours)), "nobody's words");
}

#[test]
fn both_settings_are_on_by_default_and_compacting_first_needs_batching() {
    assert_eq!(settings(None), (true, true));
    assert_eq!(settings(Some(&json!({}))), (true, true));
    let no_compact = json!({"agents": {"coldWake": {"compact": false}}});
    assert_eq!(settings(Some(&no_compact)), (true, false));
    let off = json!({"agents.coldWake.enabled": false});
    assert_eq!(settings(Some(&off)), (false, false));
}
