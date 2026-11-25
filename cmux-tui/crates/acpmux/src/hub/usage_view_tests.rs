//! `usage_view.rs`: a whole pass reads its candidates (the live chats and the kept order's rows
//! of the last day), and finds the same chats a walk of every session finds.

use super::*;
use crate::config::Config;
use serde_json::json;

fn meta(id: &str, family: &str, sid: Option<&str>, status: &str, at: u64) -> SessionMeta {
    serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": id, "harness": "claude",
        "cwd": "/tmp", "status": status, "createdAt": 1, "updatedAt": at,
        "family": family, "agentSessionId": sid,
    }))
    .unwrap()
}

fn ids(sources: &[(String, Source)]) -> Vec<String> {
    let mut ids: Vec<String> = sources.iter().map(|(id, _)| id.clone()).collect();
    ids.sort();
    ids
}

/// Decision 288 (c): one hub with an open Claude chat, open chats of two other families, a
/// Claude chat closed today, one closed two days ago, one closed two days ago and dated today
/// by a record, one closed two days ago with a draft set today (a date no record carries), and
/// one with no agent session id. The pass's sources are what a walk of every session finds, and
/// a prune by them drops the same chats.
#[tokio::test]
async fn a_pass_reads_the_chats_a_walk_of_every_session_reads() {
    let hub = Hub::new(Config::default(), Box::new(crate::store::MemoryStore::default()));
    let now = crate::store::now_ms();
    let two_days = now - 2 * DAY_MS;
    let chats = [
        meta("open-claude", "claude", Some("s1"), "idle", now - 1_000),
        meta("open-codex", "codex", Some("s2"), "idle", two_days),
        meta("open-gemini", "gemini", Some("s3"), "idle", now - 2_000),
        meta("closed-today", "claude", Some("s4"), "closed", now - 3_600_000),
        meta("closed-old", "claude", Some("s5"), "closed", two_days),
        meta("closed-old-dated", "claude", Some("s6"), "closed", two_days - 1),
        meta("closed-old-draft", "claude", Some("s7"), "closed", two_days - 2),
        meta("no-sid", "claude", None, "idle", now - 3_000),
    ];
    for meta in chats {
        hub.store.save(&meta).unwrap();
        hub.insert_test_session(meta);
    }
    // The order is built first: the writes below reach it as a read's patch, not a new sort.
    let _ = hub.kept_order_for_test();
    let built = hub.list_order_rebuilds_for_test();
    let session = |id: &str| hub.session_by_id(id).unwrap();
    hub.append(&session("closed-old-dated"), "mux", "tags", json!({"tags": {}}));
    hub.set_composer_draft(&session("closed-old-draft"), "a draft").unwrap();

    let now = crate::store::now_ms();
    let candidates = hub.usage_candidates(now);
    assert_eq!(hub.list_order_rebuilds_for_test(), built, "the candidates came from a patch");
    let read = hub.usage_sources(&candidates, now).await;
    let walked = hub.usage_sources(&hub.sessions(), now).await;
    assert_eq!(ids(&read), ids(&walked), "the pass reads what a walk of every session reads");
    assert_eq!(
        ids(&read),
        ["closed-old-dated", "closed-old-draft", "closed-today", "open-claude", "open-codex"],
    );
    assert!(
        !candidates.iter().any(|s| s.id == "closed-old"),
        "a chat closed two days ago is no candidate"
    );

    let every: Vec<String> = hub.session_handles().iter().map(|s| s.id.clone()).collect();
    let gone = |sources: &[(String, Source)]| {
        let mut trackers: HashMap<String, ()> = every.iter().map(|id| (id.clone(), ())).collect();
        let stats: HashSet<String> = every.iter().cloned().collect();
        let mut gone = prune_unlisted(&mut trackers, &stats, sources);
        gone.sort();
        gone
    };
    assert_eq!(gone(&read), gone(&walked), "a prune by the pass drops the walk's chats");
    assert_eq!(gone(&read), ["closed-old", "no-sid", "open-gemini"]);
}

/// A whole pass runs over its candidates and reads each of them it should, once.
#[tokio::test]
async fn a_whole_pass_counts_the_chats_it_read() {
    let hub = Hub::new(Config::default(), Box::new(crate::store::MemoryStore::default()));
    let now = crate::store::now_ms();
    for n in 0..3 {
        let live = meta(&format!("live-{n}"), "claude", Some("s"), "idle", now - n);
        let old = meta(&format!("old-{n}"), "claude", Some("s"), "closed", now - 2 * DAY_MS - n);
        for meta in [live, old] {
            hub.store.save(&meta).unwrap();
            hub.insert_test_session(meta);
        }
    }
    hub.refresh_usage_stats().await;
    assert_eq!(hub.usage_passes_for_test(), (1, 3));
    // Inside `REFRESH_EVERY_MS` with no turn ended: no pass.
    hub.refresh_usage_stats().await;
    assert_eq!(hub.usage_passes_for_test(), (1, 3));
    hub.usage_pass_due_for_test();
    hub.refresh_usage_stats().await;
    assert_eq!(hub.usage_passes_for_test(), (2, 3));
}

/// Stats a pass found for chat `id`, as if one did.
fn stats_found(hub: &Hub, id: &str) {
    let stats: UsageStats =
        serde_json::from_value(json!({"autocompact": "unknown", "updatedAt": 1})).unwrap();
    hub.usage_stats.stats.lock().unwrap().insert_for_test(id, stats);
}

fn every_row_generation(hub: &Hub) -> u64 {
    hub.events.summary_generation.load(Ordering::SeqCst)
}

/// Decision 293 (i): a chat closed today and aged past the day before the next pass is no
/// candidate of that pass, yet its stats go as on base: its own row is told (its `summary_gen`
/// rises and it takes a list position), and no other closed row goes stale.
#[tokio::test]
async fn a_chat_aged_out_between_passes_tells_its_own_row_only() {
    let hub = Hub::new(Config::default(), Box::new(crate::store::MemoryStore::default()));
    let now = crate::store::now_ms();
    let chat = meta("aging", "claude", Some("s1"), "closed", now - 3_600_000);
    hub.store.save(&chat).unwrap();
    let session = hub.insert_test_session(chat);
    stats_found(&hub, "aging");
    hub.refresh_usage_stats().await;
    assert!(hub.usage_stats.stats.lock().unwrap().get("aging").is_some(), "read today: kept");
    assert_eq!(hub.usage_passes_for_test(), (1, 1));

    hub.edit_test_meta(&session, |m| m.updated_at = now - 2 * DAY_MS);
    let head = hub.events.list_head();
    let (own, every) = (session.summary_gen.load(Ordering::SeqCst), every_row_generation(&hub));
    hub.usage_pass_due_for_test();
    hub.refresh_usage_stats().await;
    assert_eq!(hub.usage_passes_for_test(), (2, 0), "no chat to read");
    assert!(hub.usage_stats.stats.lock().unwrap().get("aging").is_none(), "its stats went");
    assert!(session.summary_gen.load(Ordering::SeqCst) > own, "its own row was told");
    assert_eq!(every_row_generation(&hub), every, "no other closed row went stale");
    let told = hub.events.list_since(head).unwrap().rows;
    assert!(
        told.iter().any(|(_, key, _)| *key == crate::hub::row_log::RowKey::Own("aging".into())),
        "it took a list position: {told:?}"
    );
}

/// Decision 293 (ii): stats of a chat in no map (purged) go with every closed row stale, as on
/// base: no row of its own is left to tell.
#[tokio::test]
async fn a_purged_chats_stats_make_every_closed_row_stale() {
    let hub = Hub::new(Config::default(), Box::new(crate::store::MemoryStore::default()));
    stats_found(&hub, "purged");
    let every = every_row_generation(&hub);
    hub.refresh_usage_stats().await;
    assert!(hub.usage_stats.stats.lock().unwrap().get("purged").is_none());
    assert!(every_row_generation(&hub) > every, "every closed row went stale");
}

/// Decision 292: a pass on a hub whose list order is not sorted yet (a deferred start before
/// its logs are read) sorts it once; the next pass and the next page read patch it.
#[tokio::test]
async fn a_pass_before_the_order_is_sorted_sorts_it_once() {
    let hub = Hub::new(Config::default(), Box::new(crate::store::MemoryStore::default()));
    let now = crate::store::now_ms();
    for n in 0..4 {
        let chat = meta(&format!("c{n}"), "claude", Some("s"), "closed", now - n * 1_000);
        hub.store.save(&chat).unwrap();
        hub.insert_test_session(chat);
    }
    hub.unsort_list_order_for_test();
    assert_eq!(hub.list_order_rebuilds_for_test(), 0, "not sorted yet");
    hub.refresh_usage_stats().await;
    assert_eq!(hub.list_order_rebuilds_for_test(), 1, "the pass sorted it");
    hub.usage_pass_due_for_test();
    hub.refresh_usage_stats().await;
    assert_eq!(hub.list_order_rebuilds_for_test(), 1, "the next pass patched it");
    let _ = hub.own_rows_from(None, 20);
    assert_eq!(hub.list_order_rebuilds_for_test(), 1, "a page read patched it");
    assert_eq!(hub.usage_passes_for_test(), (2, 4));
}

/// Session Info's usage read (`_acpmux/sessions {usage: true}`, `acpmux ls -w`) with a cache
/// already filled: it answers with what is cached at once and the pass runs behind it, never
/// waiting on a slow read (hq#13932). A cold read, with nothing cached yet, still waits for its
/// pass. The pass's read is a stub that takes `SLOW` longer than its own.
#[tokio::test(flavor = "multi_thread")]
async fn a_warm_usage_read_answers_before_its_slow_pass() {
    const SLOW: u64 = 400;
    let hub = Hub::new(Config::default(), Box::new(crate::store::MemoryStore::default()));
    let now = crate::store::now_ms();
    for n in 0..3 {
        let live = meta(&format!("live-{n}"), "claude", Some("s"), "idle", now - n);
        hub.store.save(&live).unwrap();
        hub.insert_test_session(live);
    }
    hub.slow_usage_reads_for_test(SLOW);
    let cold = std::time::Instant::now();
    hub.read_usage_for_list().await;
    let cold = cold.elapsed();
    assert_eq!(hub.usage_passes_for_test(), (1, 3), "a cold read waits for its pass");
    assert!(cold >= Duration::from_millis(SLOW), "the cold read waited: {cold:?}");

    hub.usage_pass_due_for_test();
    let warm = std::time::Instant::now();
    hub.read_usage_for_list().await;
    let warm = warm.elapsed();
    eprintln!("usage read with a {SLOW} ms pass: cold {cold:?}, warm {warm:?}");
    assert!(warm < Duration::from_millis(SLOW / 4), "the warm read waited for its pass: {warm:?}");
    // The pass the warm read started runs behind it.
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while hub.usage_passes_for_test().0 < 2 && std::time::Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert_eq!(hub.usage_passes_for_test(), (2, 3), "the revalidation ran behind the read");
}

/// A chat's cached stats carry its tags: its turn's end and a change the chat index's file watch
/// saw in its transcript each leave them stale, one write whatever is cached, and a stale entry
/// is still what a row draws until the read behind it writes the new one.
#[tokio::test]
async fn a_chats_stats_go_stale_by_its_turn_and_its_transcript() {
    let hub = Hub::new(Config::default(), Box::new(crate::store::MemoryStore::default()));
    let chat = meta("c", "claude", Some("s1"), "idle", crate::store::now_ms());
    hub.store.save(&chat).unwrap();
    let session = hub.insert_test_session(chat);
    let key = ChatKey { harness: AdapterKind::ClaudeCode, session_id: "s1".into() };
    let other = ChatKey { harness: AdapterKind::ClaudeCode, session_id: "s2".into() };
    let write = || {
        let stats: UsageStats =
            serde_json::from_value(json!({"autocompact": "unknown", "updatedAt": 1})).unwrap();
        let tags = vec![UsageTag::Chat("c".into()), UsageTag::Transcript(key.clone())];
        let mut cache = hub.usage_stats.stats();
        let now = cache.cache.stamp();
        cache.insert_at("c".into(), stats, tags, now);
    };
    let fresh = || hub.usage_stats.stats().fresh("c").is_some();
    let kept = || hub.usage_stats.stats().get("c").is_some();
    write();
    assert!(fresh());

    hub.usage_transcripts_changed(std::iter::once(&ChatChange::Removed { key: other }));
    assert!(fresh(), "another chat's transcript leaves it fresh");
    hub.usage_stats.dirty.store(false, Ordering::SeqCst);
    hub.usage_transcripts_changed(std::iter::once(&ChatChange::Removed { key: key.clone() }));
    assert!(!fresh() && kept(), "its transcript changed: stale, still served");
    assert!(hub.usage_stats.dirty.load(Ordering::SeqCst), "the next read starts a pass");
    assert!(hub.usage_stats_of(&session, &session.meta()).is_some(), "the row draws it");

    write();
    assert!(fresh(), "read again: fresh");
    hub.refresh_usage_stats_of(&session);
    assert!(!fresh() && kept(), "its turn ended: stale, still served");
}
// clippy-195 probe
