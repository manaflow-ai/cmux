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

// Surgery before `/compact` (`surgery.rs`): a cold batch masks old tool output when that alone
// takes the chat under the compaction line, and compacts as before otherwise.

fn dry(masked: u64, after: Option<u64>) -> Result<Value, RpcError> {
    Ok(json!({"applied": false, "dryRun": true, "maskedResults": masked, "tokensAfter": after}))
}

#[test]
fn surgery_applied_sends_no_compact() {
    // Masking takes 150K under the line: surgery runs.
    assert!(surgery_suffices(&dry(12, Some(COMPACT_ABOVE_TOKENS - 1))));
    let applied = Ok(json!({"applied": true, "agentSessionId": "copy", "maskedResults": 12,
        "tokensBefore": 150_000, "tokensAfter": 90_000}));
    assert!(surgery_applied(&applied), "applied: the batch goes in with no /compact");
}

#[test]
fn surgery_refused_or_failed_compacts_as_before() {
    for reason in
        ["mid-turn", "not a stored Claude conversation", "nothing to mask", "no transcript"]
    {
        let refused = Ok(json!({"applied": false, "reason": reason}));
        assert!(!surgery_suffices(&refused), "{reason}: no dry run answer");
        assert!(!surgery_applied(&refused), "{reason}: /compact");
    }
    let failed: Result<Value, RpcError> = Err(RpcError::internal("boom"));
    assert!(!surgery_suffices(&failed));
    assert!(!surgery_applied(&failed));
    // A dry run is never an applied surgery.
    assert!(!surgery_applied(&dry(12, Some(1))));
}

#[test]
fn surgery_that_leaves_the_chat_above_the_line_compacts_instead() {
    assert!(!surgery_suffices(&dry(12, Some(COMPACT_ABOVE_TOKENS))), "still at the line");
    assert!(!surgery_suffices(&dry(12, None)), "no estimate");
    assert!(!surgery_suffices(&dry(0, Some(1))), "nothing masked");
}

#[test]
fn surgery_switched_off_compacts() {
    let off = json!({"agents": {"harnessMagic": {"surgery": {"enabled": false}}}});
    assert!(!super::super::surgery::enabled_with(Some(&off), None));
    assert!(!super::super::surgery::enabled_with(None, Some("0")));
    // `Hub::surgery` answers a switched-off chat this way, dry run or not.
    let answer = Ok(json!({"applied": false, "reason": "off"}));
    assert!(!surgery_suffices(&answer));
    assert!(!surgery_applied(&answer));
}

/// End to end through `Hub::surgery`: a chat with no stored Claude conversation (or surgery
/// switched off on this machine) is refused, so the cold batch falls back to `/compact`.
#[tokio::test]
async fn a_chat_surgery_refuses_falls_back_to_compact() {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let meta = json!({"schema": crate::store::META_SCHEMA, "id": "cold-s", "name": "cold-s",
        "harness": "claude", "cwd": "/tmp", "status": "idle", "turnCount": 3,
        "createdAt": 1, "updatedAt": 2});
    store.save(&serde_json::from_value(meta).unwrap()).unwrap();
    let hub = Hub::new(cfg, store);
    hub.begin_startup(false);
    let session = hub.resolve("cold-s").unwrap();
    let answer = hub.surgery(&session, None, true).await;
    assert!(!surgery_suffices(&answer), "{answer:?}");
    assert!(!hub.cold_wake_surgery(&session, 150_000).await, "refused: /compact as before");
}
