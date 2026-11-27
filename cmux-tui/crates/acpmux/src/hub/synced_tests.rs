use super::*;
use serde_json::json;
use std::sync::Arc;

fn exchange(a: &Synced, b: &Synced) {
    // Each pulls what it lacks from the other, as a client's pull then push would.
    let (_, from_b, _) = b.pull(&a.lock().vv().clone());
    a.push(&from_b);
    let (_, from_a, _) = a.pull(&b.lock().vv().clone());
    b.push(&from_a);
}

#[test]
fn two_replicas_editing_offline_converge() {
    let mac = Synced::open(None);
    let phone = Synced::open(None);
    mac.record(title_key("s1"), json!("Release notes"));
    mac.record(read_key("s1"), json!(true));
    phone.record(title_key("s2"), json!("Bug bash"));
    phone.record(read_key("s1"), json!(false));
    exchange(&mac, &phone);
    for key in [title_key("s1"), title_key("s2"), read_key("s1")] {
        assert_eq!(mac.get(&key), phone.get(&key), "{key}");
        assert!(mac.get(&key).is_some(), "{key}");
    }
    // The later edit of the same key wins on both sides.
    assert_eq!(mac.get(&read_key("s1")), Some(json!(false)));
    // Exchanging again changes nothing.
    let (_, again, _) = mac.pull(&phone.lock().vv().clone());
    assert!(again.entries.is_empty());
}

#[test]
fn a_pull_carries_only_the_missed_edits() {
    let daemon = Synced::open(None);
    let phone = Synced::open(None);
    for i in 0..1000 {
        daemon.record(title_key(&format!("s{i}")), json!(format!("chat {i}")));
    }
    exchange(&phone, &daemon);
    assert_eq!(phone.get(&title_key("s999")), Some(json!("chat 999")));
    for i in 0..10 {
        daemon.record(read_key(&format!("s{i}")), json!(true));
    }
    let (_, delta, _) = daemon.pull(&phone.lock().vv().clone());
    assert_eq!(delta.entries.len(), 10, "ten edits behind out of 1010 keys");
}

#[test]
fn recording_the_value_already_there_is_no_edit() {
    let a = Synced::open(None);
    assert!(a.record(title_key("s1"), json!("x")));
    let vv = a.lock().vv().clone();
    assert!(!a.record(title_key("s1"), json!("x")));
    assert_eq!(a.lock().vv(), &vv);
}

#[test]
fn a_restart_keeps_the_replica_and_its_actor() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(FILE);
    let actor = {
        let a = Synced::open(Some(path.clone()));
        a.record(title_key("s1"), json!("Kept"));
        a.record(read_key("s1"), json!(true));
        a.lock().actor().0.clone()
    };
    let b = Synced::open(Some(path));
    assert_eq!(b.lock().actor().0, actor);
    assert_eq!(b.get(&title_key("s1")), Some(json!("Kept")));
    assert_eq!(b.get(&read_key("s1")), Some(json!(true)));
}

#[test]
fn keys_name_their_field() {
    assert_eq!(field(&title_key("a")), Some(Field::Title("a".into())));
    assert_eq!(field(&read_key("b")), Some(Field::Read("b".into())));
    assert_eq!(field(&pin_key("c")), Some(Field::Pin("c".into())));
    assert_eq!(field(&draft_key("d")), Some(Field::Draft("d".into())));
    assert_eq!(field("pin/"), None);
    assert_eq!(field("star/e"), None);
}

#[test]
fn pending_chats_survive_a_restart() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(FILE);
    Synced::open(Some(path.clone())).hold(["c1".to_owned(), "c2".to_owned()]);
    let b = Synced::open(Some(path));
    assert_eq!(b.held_ids(), vec!["c1".to_owned(), "c2".to_owned()]);
    b.release("c1");
    assert!(!b.held("c1") && b.held("c2"));
}

// Two daemons' hubs, each holding chat `CHAT` (or not), exchanging as a peer link does.

const CHAT: &str = "01a15903-0000-7000-8000-00000000c0de";

fn hub() -> Arc<Hub> {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

fn chat_meta() -> crate::store::SessionMeta {
    serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": CHAT, "name": "seeded",
        "harness": "fake", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1
    }))
    .unwrap()
}

fn hub_with_chat() -> (Arc<Hub>, Arc<Session>) {
    let hub = hub();
    let s = hub.insert_test_session(chat_meta());
    (hub, s)
}

/// `hub` pulls from and pushes to `other`, as `synced_on_connect` does over a link.
async fn reconnect(hub: &Arc<Hub>, other: &Arc<Hub>) {
    let other = other.clone();
    let call = move |m: &'static str, params: Value| {
        let other = other.clone();
        async move {
            if m == crate::rpc::method::MUX_SYNC_PULL {
                Ok(serde_json::to_value(other.sync_pull(&params)?).unwrap())
            } else {
                Ok(serde_json::to_value(other.sync_push(&params).await?).unwrap())
            }
        }
    };
    hub.synced_exchange("peer", call).await.unwrap();
}

#[derive(Clone, Copy, Debug)]
enum Kind {
    Title,
    Read,
    Pin,
    Draft,
}

/// A person's edit of `kind` on this daemon, through the path its request takes.
async fn edit(hub: &Hub, s: &Arc<Session>, kind: Kind, n: u32) {
    match kind {
        Kind::Title => {
            hub.rename(s, format!("title-{n}")).await.unwrap();
            hub.synced_record(title_key(&s.id), json!(s.meta().name));
        }
        Kind::Read => {
            let read = n % 2 == 0;
            if read {
                hub.mark_read_answered(s).unwrap();
            } else {
                hub.mark_unread_answered(s).unwrap();
            }
            hub.synced_record(read_key(&s.id), json!(read));
        }
        Kind::Pin => hub.set_pinned(s, n % 2 == 1).unwrap(),
        Kind::Draft => {
            hub.set_composer_draft(s, &format!("draft {n}")).unwrap();
        }
    }
}

/// What the chat shows for `kind`, as the replica would set it after edit `n`.
fn shows(s: &Session, kind: Kind) -> Value {
    let m = s.meta();
    match kind {
        Kind::Title => json!(m.name),
        Kind::Read => json!(!m.unread),
        Kind::Pin => json!(m.pinned),
        Kind::Draft => json!(m.composer_draft),
    }
}

fn expected(kind: Kind, n: u32) -> Value {
    match kind {
        Kind::Title => json!(format!("title-{n}")),
        Kind::Read => json!(n % 2 == 0),
        Kind::Pin => json!(n % 2 == 1),
        Kind::Draft => json!(format!("draft {n}")),
    }
}

fn wait_a_tick() {
    // Wall-clock stamps a millisecond apart: the later edit is later on every replica.
    std::thread::sleep(std::time::Duration::from_millis(3));
}

#[tokio::test]
async fn each_key_kind_converges_to_the_later_edit_in_both_orders() {
    for kind in [Kind::Title, Kind::Read, Kind::Pin, Kind::Draft] {
        for a_first in [true, false] {
            let (a, sa) = hub_with_chat();
            let (b, sb) = hub_with_chat();
            let (first, second) =
                if a_first { ((&a, &sa), (&b, &sb)) } else { ((&b, &sb), (&a, &sa)) };
            edit(first.0, first.1, kind, 1).await;
            wait_a_tick();
            edit(second.0, second.1, kind, 2).await;
            // Either side may start the exchange; the later edit wins on both.
            reconnect(&a, &b).await;
            for (hub, s) in [(&a, &sa), (&b, &sb)] {
                assert_eq!(shows(s, kind), expected(kind, 2), "{kind:?} a_first={a_first}");
                let key = chat_keys(CHAT)[kind as usize].clone();
                assert_eq!(hub.synced().get(&key), Some(expected(kind, 2)), "{kind:?}");
            }
        }
    }
}

#[tokio::test]
async fn a_cleared_draft_clears_it_on_the_other_daemon() {
    let (a, sa) = hub_with_chat();
    let (b, sb) = hub_with_chat();
    a.set_composer_draft(&sa, "half a thought").unwrap();
    reconnect(&b, &a).await;
    assert_eq!(sb.meta().composer_draft.as_deref(), Some("half a thought"));
    wait_a_tick();
    b.set_composer_draft(&sb, "  ").unwrap();
    reconnect(&a, &b).await;
    assert_eq!(sa.meta().composer_draft, None);
    assert_eq!(a.synced().get(&draft_key(CHAT)), None);
    assert_eq!(b.synced().get(&draft_key(CHAT)), None);
}

#[tokio::test]
async fn an_entry_for_a_chat_not_loaded_is_applied_when_it_loads() {
    let (a, sa) = hub_with_chat();
    let b = hub();
    for kind in [Kind::Title, Kind::Read, Kind::Pin, Kind::Draft] {
        edit(&a, &sa, kind, 3).await;
    }
    reconnect(&b, &a).await;
    // Kept, never skipped.
    assert!(b.synced().held(CHAT));
    assert_eq!(b.synced().get(&pin_key(CHAT)), Some(json!(true)));
    let sb = b.insert_test_session(chat_meta());
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    while b.synced().held(CHAT) && std::time::Instant::now() < deadline {
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    assert!(!b.synced().held(CHAT), "applied when the chat came");
    for kind in [Kind::Title, Kind::Read, Kind::Pin, Kind::Draft] {
        assert_eq!(shows(&sb, kind), expected(kind, 3), "{kind:?}");
    }
}

#[tokio::test]
async fn a_pending_chat_read_at_start_gets_its_entries() {
    let (a, sa) = hub_with_chat();
    let b = hub();
    a.set_pinned(&sa, true).unwrap();
    reconnect(&b, &a).await;
    // Installed without a `session_came` (as a start reads the store), then the start's pass.
    let sb = b.insert_test_session(chat_meta());
    b.synced_apply_pending().await;
    assert!(sb.meta().pinned);
    assert!(!b.synced().held(CHAT));
}

#[tokio::test]
async fn an_offline_edit_crosses_on_reconnect() {
    let (a, sa) = hub_with_chat();
    let (b, sb) = hub_with_chat();
    reconnect(&a, &b).await;
    // The link drops; each side edits on its own.
    a.set_pinned(&sa, true).unwrap();
    a.set_composer_draft(&sa, "written on the plane").unwrap();
    wait_a_tick();
    b.rename(&sb, "renamed-on-the-phone".into()).await.unwrap();
    b.synced_record(title_key(CHAT), json!("renamed-on-the-phone"));
    // Nothing crossed yet.
    assert!(!sb.meta().pinned);
    assert_eq!(sa.meta().name, "seeded");
    // A reconnects: it pulls B's rename and pushes its pin and draft.
    reconnect(&a, &b).await;
    for s in [&sa, &sb] {
        assert!(s.meta().pinned);
        assert_eq!(s.meta().composer_draft.as_deref(), Some("written on the plane"));
        assert_eq!(s.meta().name, "renamed-on-the-phone");
    }
    // Converged: a second exchange carries nothing either way.
    let (_, lacking, _) = a.synced().pull(&b.synced().vv());
    assert!(lacking.entries.is_empty());
    let (_, lacking, _) = b.synced().pull(&a.synced().vv());
    assert!(lacking.entries.is_empty());
}

#[test]
fn presence_sync_summary_tracks_acknowledgements_and_disconnects() {
    let hub = hub();
    let synced = hub.synced();
    assert!(hub.here_now(&json!({})).unwrap().sync.is_none());
    assert!(hub.here_now(&json!({"includeSync": true})).unwrap().sync.unwrap().is_empty());
    synced.note_peer("phone", synced.vv());
    synced.record(title_key("one"), json!("first"));
    synced.record(title_key("one"), json!("second"));
    let status = synced.peer_status(|_| true);
    assert!(status[0].connected);
    assert!(!status[0].acknowledged);
    assert_eq!(status[0].unacknowledged_edits, 2);
    synced.note_peer("phone", synced.vv());
    let status = hub.here_now(&json!({"includeSync": true})).unwrap().sync.unwrap();
    assert!(status[0].acknowledged);
    assert!(!status[0].connected, "an acknowledgement is not connectivity");
    assert_eq!(status[0].unacknowledged_edits, 0);
    // A peer ahead of us is not converged even though it covers all our edits.
    let mut ahead = synced.vv();
    ahead.set(Actor::new("remote"), 1);
    synced.note_peer("phone", ahead);
    assert!(!synced.peer_status(|_| true)[0].acknowledged);
}

#[test]
fn presence_sync_summary_large_history() {
    use std::hint::black_box;
    use std::time::Instant;

    let synced = Synced::open(None);
    for i in 0..16 {
        synced.note_peer(&format!("peer-{i:02}"), synced.vv());
    }
    let mut inserted = 0;
    for size in [100, 100_000] {
        for i in inserted..size {
            synced.record(title_key(&format!("chat-{i}")), json!("title"));
        }
        inserted = size;
        let start = Instant::now();
        for _ in 0..1_000 {
            let status = black_box(synced.peer_status(|_| true));
            assert_eq!(status.len(), 16);
            assert!(status.windows(2).all(|pair| pair[0].peer < pair[1].peer));
            assert!(status.iter().all(|peer| !peer.acknowledged
                && peer.connected
                && peer.unacknowledged_edits == size));
        }
        eprintln!(
            "presence_sync_summary: keys={size} peers=16 queries=1000 elapsed_us={}",
            start.elapsed().as_micros()
        );
    }
}
