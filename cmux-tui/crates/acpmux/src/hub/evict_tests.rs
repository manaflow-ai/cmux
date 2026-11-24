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
    assert_eq!(hub.evict_idle_chats(), 1);
}
