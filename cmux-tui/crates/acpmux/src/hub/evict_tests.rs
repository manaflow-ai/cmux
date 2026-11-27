use super::super::list_guard::BuiltRow;
use super::*;
use serde_json::json;

fn meta(id: &str, name: &str, updated: u64) -> SessionMeta {
    serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": name, "harness": "claude",
        "cwd": "/tmp", "status": "closed", "createdAt": 1, "updatedAt": updated
    }))
    .unwrap()
}

/// A hub with eviction after 1 ns and `n` closed chats, stored and in memory, none held.
fn hub_with(n: usize) -> Arc<Hub> {
    let hub = Hub::new(Config::default(), Box::new(crate::store::MemoryStore::default()));
    hub.evicted.set_after(Some(std::time::Duration::from_nanos(1)));
    for i in 0..n {
        let meta = meta(&format!("s{i}"), &format!("chat-{i}"), 10 + i as u64);
        hub.store.save(&meta).unwrap();
        drop(hub.insert_test_session(meta));
    }
    hub.warm_list_order_for_test();
    std::thread::sleep(std::time::Duration::from_millis(2));
    for i in 0..n {
        let id = format!("s{i}");
        let why = hub.kept_for_test(&id);
        assert!(why.is_none(), "{id} would stay in memory: {why:?}");
    }
    hub
}

impl Hub {
    /// Why chat `id` stays in memory now, evicting nothing.
    fn kept_for_test(&self, id: &str) -> Option<&'static str> {
        let after = u64::try_from(self.evicted.after()?.as_nanos()).unwrap_or(u64::MAX);
        let session = self.sessions.lock().unwrap().get(id).cloned()?;
        self.kept_because(&session, self.clock_now(), after)
    }
}

fn page(hub: &Hub) -> Vec<String> {
    let (rows, _) = hub.session_page_rows(&json!({"limit": 50}), false).unwrap();
    rows.iter()
        .map(|row| match row {
            BuiltRow::Tree(value) => value.to_string(),
            BuiltRow::Peer(text, _) => text.to_string(),
        })
        .collect()
}

fn in_map(hub: &Hub, id: &str) -> bool {
    hub.sessions.lock().unwrap().contains_key(id)
}

#[tokio::test]
async fn an_evicted_chat_lists_as_it_did_and_counts_as_a_chat() {
    let hub = hub_with(4);
    let before = page(&hub);
    let whole = hub.session_list_text(&json!({}), false, true, usize::MAX).unwrap();
    assert_eq!(hub.evict_now_for_test("s0"), None, "s0 leaves memory");
    assert_eq!(hub.evict_idle_chats(), 3);
    assert!(!in_map(&hub, "s1"));
    assert_eq!(hub.session_count(), 4);
    assert_eq!(page(&hub), before, "the first page reads the same");
    assert_eq!(
        hub.session_list_text(&json!({}), false, true, usize::MAX).unwrap(),
        whole,
        "the whole list reads the same"
    );
    assert_eq!(hub.eviction_counts(), (4, 4, 0));
    assert_eq!(hub.evict_now_for_test("s0"), None, "an evicted chat is not in the map");
}

#[tokio::test]
async fn a_read_by_id_brings_an_evicted_chat_back_with_its_metadata() {
    let hub = hub_with(2);
    let kept = hub.session_get("s0").unwrap().meta();
    hub.evict_idle_chats();
    assert!(!in_map(&hub, "s0"));
    let back = hub.session_get("s0").expect("rehydrated");
    assert!(in_map(&hub, "s0"));
    assert_eq!(back.meta().name, kept.name);
    assert_eq!(back.meta().updated_at, kept.updated_at);
    assert!(!hub.evicted.contains("s0"));
    assert!(hub.evicted.contains("s1"), "only the chat read comes back");
    assert_eq!(hub.eviction_counts(), (1, 2, 1));
    assert!(hub.session_get("nope").is_none());
}

#[tokio::test]
async fn a_resolve_by_name_brings_an_evicted_chat_back() {
    let hub = hub_with(3);
    hub.evict_idle_chats();
    let found = hub.resolve_here("chat-2").expect("resolved by name");
    assert_eq!(found.id, "s2");
    assert!(in_map(&hub, "s2"));
}

#[tokio::test]
async fn a_held_chat_stays_in_memory() {
    let hub = hub_with(2);
    let held = hub.session_get("s0").unwrap();
    assert_eq!(hub.evict_idle_chats(), 1);
    assert!(in_map(&hub, "s0"), "a handle somebody holds keeps its chat");
    assert!(!in_map(&hub, "s1"));
    drop(held);
    assert_eq!(hub.evict_idle_chats(), 1);
    assert!(!in_map(&hub, "s0"));
}

#[tokio::test]
async fn eviction_is_off_by_default_and_spares_an_attached_chat() {
    let hub = hub_with(2);
    hub.evicted.set_after(None);
    assert_eq!(hub.evict_idle_chats(), 0);
    hub.evicted.set_after(Some(std::time::Duration::from_nanos(1)));
    hub.session_get("s0").unwrap().attached.fetch_add(1, Ordering::SeqCst);
    assert_eq!(hub.evict_idle_chats(), 1);
    assert!(in_map(&hub, "s0"));
}

#[tokio::test]
async fn the_kept_order_matches_a_sort_after_evictions_and_rehydrates() {
    let hub = hub_with(5);
    let want = hub.kept_order_for_test();
    hub.evict_idle_chats();
    assert_eq!(hub.kept_order_for_test(), want);
    drop(hub.session_get("s3"));
    assert_eq!(hub.kept_order_for_test(), want);
}

#[tokio::test]
async fn a_replay_or_newest_window_brings_an_evicted_chat_back() {
    let hub = hub_with(2);
    hub.evict_idle_chats();
    assert!(!in_map(&hub, "s0") && !in_map(&hub, "s1"));
    hub.scan_events("s0", 0, &mut |_| true).unwrap();
    assert!(in_map(&hub, "s0"), "a replay reads it through its session (a cold log warms first)");
    hub.newest_window("s1", 400).unwrap();
    assert!(in_map(&hub, "s1"), "so does the open's newest window");
}

#[tokio::test]
async fn an_evicted_chat_counts_live_or_closed_as_it_did_in_memory() {
    let hub = Hub::new(Config::default(), Box::new(crate::store::MemoryStore::default()));
    hub.evicted.set_after(Some(std::time::Duration::from_nanos(1)));
    for (i, status) in ["closed", "idle", "closed"].into_iter().enumerate() {
        let mut meta = meta(&format!("s{i}"), &format!("chat-{i}"), 10 + i as u64);
        meta.status = serde_json::from_value(json!(status)).unwrap();
        hub.store.save(&meta).unwrap();
        let session = hub.insert_test_session(meta);
        // An idle chat with no agent is hibernated (`idle.rs`).
        session.hibernated_at.store(1, Ordering::SeqCst);
    }
    hub.warm_list_order_for_test();
    std::thread::sleep(std::time::Duration::from_millis(2));
    let before = hub.session_counts();
    assert_eq!(before, (3, 1), "one idle chat, two closed");
    assert_eq!(hub.evict_idle_chats(), 3, "{:?}", hub.kept_for_test("s1"));
    assert_eq!(hub.session_counts(), before, "the hidden closed count does not move");
    assert_eq!(hub.eviction_counts(), (3, 3, 0));
}

/// A chat past its deadline that stays (held here) must not leave the reaper a deadline in the
/// past: it would wake at once, find it kept, and loop (98% CPU idle in the n=100 bench).
#[tokio::test]
async fn a_kept_chat_past_its_deadline_is_retried_later_not_at_once() {
    let hub = hub_with(1);
    let after = std::time::Duration::from_millis(1);
    hub.evicted.set_after(Some(after));
    let held = hub.session_get("s0").unwrap();
    std::thread::sleep(std::time::Duration::from_millis(5));
    let now = std::time::Duration::from_nanos(hub.clock_now());
    let due = std::time::Duration::from_nanos(held.last_active.load(Ordering::SeqCst)) + after;
    assert!(due < now, "s0 is past its deadline");
    assert_eq!(hub.evict_idle_chats(), 0, "the handle keeps it");
    let next = hub.next_evict_deadline().expect("a candidate");
    assert!(next > now, "a kept chat's retry is in the future: {next:?} <= {now:?}");
    drop(held);
    // Tried and kept: it waits out one idle period before the next try.
    std::thread::sleep(after * 2);
    assert_eq!(hub.evict_idle_chats(), 1);
}

/// More kept chats than one pass takes (n=1,000 bench: 98.8% CPU, 374 wakeups/s idle): a pass
/// whose chats all stayed must not ask for another at once, and the next pass reaches the chats
/// behind them instead of trying the same kept ones again.
#[tokio::test]
async fn a_full_batch_of_kept_chats_neither_spins_the_reaper_nor_starves_the_rest() {
    let n = EVICT_AT_ONCE + 40;
    let hub = hub_with(n);
    let after = std::time::Duration::from_millis(50);
    hub.evicted.set_after(Some(after));
    std::thread::sleep(after * 2);
    // Every chat is held but the last 40, which the first pass may never reach.
    let mut ids: Vec<String> = hub.session_handles().iter().map(|s| s.id.clone()).collect();
    ids.sort();
    let held: Vec<_> =
        ids.iter().take(EVICT_AT_ONCE).map(|id| hub.session_get(id).unwrap()).collect();
    let first = hub.evict_idle_chats();
    assert!(
        !hub.evicted.more_due.load(Ordering::Relaxed),
        "a pass that left chats behind is not 'more due'"
    );
    let now = std::time::Duration::from_nanos(hub.clock_now());
    let next = hub.next_evict_deadline().expect("candidates");
    assert!(next > now, "no deadline in the past: {next:?} <= {now:?}");
    // The next pass comes after the held chats are due again (a slow host): the chats it never
    // tried still go first.
    std::thread::sleep(after * 2);
    let second = hub.evict_idle_chats();
    assert_eq!(first + second, 40, "the unheld chats all leave within two passes");
    assert_eq!(hub.eviction_counts().0, 40);
    drop(held);
}

/// An idle chat's inbound loop runs as long as the chat (it ends at a close): it held two strong
/// handles, so no idle chat that ever started could leave ("held elsewhere (4 handles)" for every
/// chat at n=1,000). It holds the chat weakly between items now, and ends once the chat leaves.
#[tokio::test]
async fn an_idle_chat_with_its_inbound_loop_running_leaves_memory() {
    let hub = Hub::new(Config::default(), Box::new(crate::store::MemoryStore::default()));
    hub.evicted.set_after(Some(std::time::Duration::from_nanos(1)));
    let mut meta = meta("s0", "chat-0", 10);
    meta.status = serde_json::from_value(json!("idle")).unwrap();
    hub.store.save(&meta).unwrap();
    let session = hub.insert_test_session(meta);
    session.hibernated_at.store(1, Ordering::SeqCst);
    hub.spawn_inbound_loop(&session).await;
    // Let the loop start and park on its receiver.
    for _ in 0..20 {
        tokio::task::yield_now().await;
    }
    assert!(session.inbound_rx().lock().await.is_none(), "the loop holds the receiver");
    let weak = Arc::downgrade(&session);
    drop(session);
    hub.warm_list_order_for_test();
    tokio::time::sleep(std::time::Duration::from_millis(2)).await;
    assert_eq!(hub.evict_now_for_test("s0"), None, "the inbound loop does not keep it");
    for _ in 0..20 {
        tokio::task::yield_now().await;
    }
    assert!(weak.upgrade().is_none(), "nothing holds the evicted session, its loop ended");
    let back = hub.session_get("s0").expect("rehydrated");
    assert!(back.inbound_rx().lock().await.is_some(), "a new start spawns its loop again");
}

/// An item queued for the inbound loop keeps its chat: it is still to be handled.
#[tokio::test]
async fn a_chat_with_an_inbound_item_queued_stays() {
    let hub = hub_with(1);
    let session = hub.session_get("s0").unwrap();
    let extra = session.inbound_tx().clone();
    drop(session);
    assert_eq!(hub.kept_for_test("s0"), Some("inbound"), "a second sender is a producer");
    drop(extra);
    assert_eq!(hub.kept_for_test("s0"), None);
}

/// An evicted chat holds its keys and its rows packed against a shared row, not its metadata
/// and two whole rows: at n=1,000 that came to 27 kB a chat, about what its session held.
#[tokio::test]
async fn an_evicted_row_holds_a_fraction_of_its_rows_and_reads_back_whole() {
    let hub = hub_with(20);
    let texts: Vec<(Arc<str>, Arc<str>)> = (0..20)
        .map(|i| {
            let session = hub.session_get(&format!("s{i}")).unwrap();
            (hub.own_row_text(&session, false), hub.own_row_text(&session, true))
        })
        .collect();
    std::thread::sleep(std::time::Duration::from_millis(2));
    assert_eq!(hub.evict_idle_chats(), 20);
    for (i, (list, full)) in texts.iter().enumerate() {
        let row = hub.evicted.get(&format!("s{i}")).unwrap();
        assert_eq!(row.row_text(false), *list, "s{i}'s list row reads back whole");
        assert_eq!(row.row_text(true), *full, "s{i}'s full row reads back whole");
        assert_eq!(row.keys.name, format!("chat-{i}"));
        let whole = list.len() + full.len();
        assert!(row.rows_held() * 4 < whole, "s{i} holds {} of {whole} bytes", row.rows_held());
    }
}

/// The cap alone (no idle period): `hub_with` made the chats, then eviction by idle time is off.
fn capped(n: usize, cap: usize) -> Arc<Hub> {
    let hub = hub_with(n);
    hub.evicted.set_after(None);
    hub.evicted.set_cap(Some(cap));
    hub
}

fn resident(hub: &Hub) -> usize {
    hub.sessions.lock().unwrap().len()
}

#[tokio::test]
async fn a_cap_of_10_with_50_idle_chats_leaves_10_resident() {
    let hub = capped(50, 10);
    assert_eq!(hub.evict_idle_chats(), 0, "no idle period: that pass leaves them");
    assert_eq!(hub.evict_over_cap(), 40);
    assert_eq!(resident(&hub), 10);
    assert_eq!(hub.eviction_counts().0, 40);
    assert_eq!(hub.evict_over_cap(), 0, "at the cap nothing more leaves");
    // Off by default: with no cap nothing leaves.
    hub.evicted.set_cap(None);
    assert_eq!(hub.evict_over_cap(), 0);
}

#[tokio::test]
async fn the_cap_takes_the_least_recently_used_first() {
    let hub = capped(12, 10);
    // s0 and s1 were used last.
    let now = hub.clock_now();
    for id in ["s0", "s1"] {
        hub.session_get(id).unwrap().last_active.store(now + 1_000_000_000, Ordering::SeqCst);
    }
    assert_eq!(hub.evict_over_cap(), 2);
    assert!(in_map(&hub, "s0") && in_map(&hub, "s1"));
    assert_eq!(resident(&hub), 10);
}

#[tokio::test]
async fn a_busy_chat_is_never_evicted_for_the_cap() {
    let hub = capped(20, 5);
    // Ten chats a client is attached to: the oldest, so the first the cap would take.
    let held: Vec<_> = (0..10).map(|i| format!("s{i}")).collect();
    for id in &held {
        hub.session_get(id).unwrap().attached.fetch_add(1, Ordering::SeqCst);
    }
    hub.evict_over_cap();
    for id in &held {
        assert!(in_map(&hub, id), "{id} is attached and stays");
    }
    assert_eq!(resident(&hub), 10, "over the cap while ten are held; the rest left");
    assert_eq!(hub.evict_over_cap(), 0);
}

#[tokio::test]
async fn a_chat_evicted_for_the_cap_and_touched_comes_back_whole() {
    let hub = capped(5, 1);
    let before: Vec<_> = (0..5)
        .map(|i| {
            let s = hub.session_get(&format!("s{i}")).unwrap();
            (hub.own_row_text(&s, false), hub.own_row_text(&s, true))
        })
        .collect();
    assert_eq!(hub.evict_over_cap(), 4);
    let gone = (0..5).map(|i| format!("s{i}")).find(|id| !in_map(&hub, id)).unwrap();
    let i: usize = gone[1..].parse().unwrap();
    let session = hub.session_get(&gone).expect("rehydrates");
    assert_eq!(session.read_meta(|m| m.name.clone()), format!("chat-{i}"));
    assert_eq!(hub.own_row_text(&session, false), before[i].0);
    assert_eq!(hub.own_row_text(&session, true), before[i].1);
    let (samples, p50, p99) = hub.evicted.rehydrate_quantiles();
    assert_eq!(samples, 1, "its rehydrate was timed");
    assert!(p50 > 0 && p99 >= p50);
}
