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
    assert!(compacts(COMPACT_ABOVE_TOKENS, COMPACT_ABOVE_TOKENS));
    assert!(!compacts(COMPACT_ABOVE_TOKENS - 1, COMPACT_ABOVE_TOKENS));
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

#[test]
fn the_compaction_line_is_a_setting_clamped_to_its_range() {
    assert_eq!(compact_above(None), COMPACT_ABOVE_TOKENS);
    assert_eq!(compact_above(Some(&json!({}))), COMPACT_ABOVE_TOKENS);
    let nested = json!({"agents": {"coldWake": {"compactAboveTokens": 80_000}}});
    assert_eq!(compact_above(Some(&nested)), 80_000);
    let flat = json!({"agents.coldWake.compactAboveTokens": 30_000.0});
    assert_eq!(compact_above(Some(&flat)), 30_000);
    let low = json!({"agents.coldWake.compactAboveTokens": 5});
    assert_eq!(compact_above(Some(&low)), COMPACT_ABOVE_RANGE.0, "never under the batch line");
    let high = json!({"agents.coldWake.compactAboveTokens": 9e9});
    assert_eq!(compact_above(Some(&high)), COMPACT_ABOVE_RANGE.1);
    let junk = json!({"agents.coldWake.compactAboveTokens": "lots"});
    assert_eq!(compact_above(Some(&junk)), COMPACT_ABOVE_TOKENS);
    // The line moves both decisions.
    assert!(compacts(80_000, 80_000) && !compacts(79_999, 80_000));
    assert!(surgery_suffices(&dry(3, Some(79_999)), 80_000));
    assert!(!surgery_suffices(&dry(3, Some(80_000)), 80_000));
}

// Surgery before `/compact` (`surgery.rs`): a cold batch masks old tool output when that alone
// takes the chat under the compaction line, and compacts as before otherwise.

fn dry(masked: u64, after: Option<u64>) -> Result<Value, RpcError> {
    Ok(json!({"applied": false, "dryRun": true, "maskedResults": masked, "tokensAfter": after}))
}

#[test]
fn surgery_applied_sends_no_compact() {
    // Masking takes 150K under the line: surgery runs.
    assert!(surgery_suffices(&dry(12, Some(COMPACT_ABOVE_TOKENS - 1)), COMPACT_ABOVE_TOKENS));
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
        assert!(!surgery_suffices(&refused, COMPACT_ABOVE_TOKENS), "{reason}: no dry run answer");
        assert!(!surgery_applied(&refused), "{reason}: /compact");
    }
    let failed: Result<Value, RpcError> = Err(RpcError::internal("boom"));
    assert!(!surgery_suffices(&failed, COMPACT_ABOVE_TOKENS));
    assert!(!surgery_applied(&failed));
    // A dry run is never an applied surgery.
    assert!(!surgery_applied(&dry(12, Some(1))));
}

#[test]
fn surgery_that_leaves_the_chat_above_the_line_compacts_instead() {
    assert!(
        !surgery_suffices(&dry(12, Some(COMPACT_ABOVE_TOKENS)), COMPACT_ABOVE_TOKENS),
        "still at the line"
    );
    assert!(!surgery_suffices(&dry(12, None), COMPACT_ABOVE_TOKENS), "no estimate");
    assert!(!surgery_suffices(&dry(0, Some(1)), COMPACT_ABOVE_TOKENS), "nothing masked");
}

#[test]
fn surgery_switched_off_compacts() {
    let off = json!({"agents": {"harnessMagic": {"surgery": {"enabled": false}}}});
    assert!(!super::super::surgery::enabled_with(Some(&off), None));
    assert!(!super::super::surgery::enabled_with(None, Some("0")));
    // `Hub::surgery` answers a switched-off chat this way, dry run or not.
    let answer = Ok(json!({"applied": false, "reason": "off"}));
    assert!(!surgery_suffices(&answer, COMPACT_ABOVE_TOKENS));
    assert!(!surgery_applied(&answer));
}

/// A queue entry as `enqueue` makes it: another agent's message when `agent`, else a person's.
fn queued(prompt_id: &str, agent: Option<&str>) -> super::super::queue::QueuedPrompt {
    let run = super::super::queue::PromptRun {
        size: Default::default(),
        blocks: vec![json!({"type": "text", "text": "waits"})],
        display_parts: None,
        control: Control::Local,
        cloud_mobile: false,
        trust_gate: false,
        provenance: None,
        agent: agent.map(str::to_owned),
        class: None,
        supersede: None,
        full_access_device: None,
        message_id: None,
        message_sender: None,
    };
    super::super::queue::QueuedPrompt {
        prompt_id: prompt_id.into(),
        turn_id: format!("t-{prompt_id}"),
        client: "test".into(),
        preview: "waits".into(),
        queued_at: 0,
        withdraw: Arc::new(tokio::sync::Notify::new()),
        run: Arc::new(run),
        restored: false,
        resume: false,
        steer: false,
        steer_on_start: false,
        held: false,
        awaiting_owner: false,
        revision: 0,
        declined: Default::default(),
        sent_now: false,
        joined: Arc::new(std::sync::Mutex::new(None)),
        requeued: false,
        retries: 0,
    }
}

fn idle_hub(id: &str) -> (Arc<Hub>, Arc<Session>) {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let meta = json!({"schema": crate::store::META_SCHEMA, "id": id, "name": id,
        "harness": "claude", "cwd": "/tmp", "status": "idle", "turnCount": 3,
        "createdAt": 1, "updatedAt": 2});
    store.save(&serde_json::from_value(meta).unwrap()).unwrap();
    let hub = Hub::new(cfg, store);
    hub.begin_startup(false);
    let session = hub.resolve(id).unwrap();
    session.meta.lock().unwrap().last_turn = Some(json!({"turnId": "t0", "endedAt": 1}));
    (hub, session)
}

/// The batch's own gathered message waits in the queue (`agent_gather.rs`): the batch's
/// compaction goes ahead of it. Before, the continuation check refused every cold compaction
/// with `auto_resume.superseded` (15 of 15 on one lane VM over 48 h), so none ran.
#[tokio::test]
async fn a_cold_batchs_compaction_goes_ahead_of_the_batch_but_not_a_persons_prompt() {
    let ours = json!({"kind": KIND});
    let (_hub, session) = idle_hub("cold-q1");
    let check = |prov: Option<&Value>| {
        super::super::auto_resume::check_cut(&session, Some("t0"), false, prov).is_ok()
    };
    assert!(check(Some(&ours)), "an empty queue");
    session.queue.lock().unwrap().push(queued("lane-msg", Some("lane")));
    assert!(goes_ahead_of_batch(&session, Some(&ours)));
    assert!(check(Some(&ours)), "the batch's gathered message waits behind its compaction");
    assert!(!check(None), "another continuation still yields to what waits");
    assert!(!goes_ahead_of_batch(&session, None), "only the batch's own compaction");
    session.queue.lock().unwrap().push(queued("persons", None));
    assert!(!goes_ahead_of_batch(&session, Some(&ours)));
    assert!(!check(Some(&ours)), "a person's prompt waits: the compaction yields to it");
    // The chat moved on: superseded, as before.
    session.queue.lock().unwrap().clear();
    session.meta.lock().unwrap().last_turn = Some(json!({"turnId": "t1", "endedAt": 2}));
    assert!(!check(Some(&ours)));
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
    assert!(!surgery_suffices(&answer, COMPACT_ABOVE_TOKENS), "{answer:?}");
    assert!(
        !hub.cold_wake_surgery(&session, 150_000, COMPACT_ABOVE_TOKENS).await,
        "refused: /compact as before"
    );
}
