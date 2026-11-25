//! A held message's deadline across a restart, and the expiry of what no turn can take
//! (`inbox_deadline.rs`).

use super::*;
use crate::prompt_class::RESULT_DEADLINE_MS;

/// A hub with idle chats `ids` that ran turns before, its store in memory and no agent.
fn hub_with_chats(ids: &[&str]) -> (Arc<Hub>, Vec<Arc<Session>>) {
    hub_with_chats_in(ids, "/tmp")
}

/// [`hub_with_chats`], the chats' folder `cwd`.
fn hub_with_chats_in(ids: &[&str], cwd: &str) -> (Arc<Hub>, Vec<Arc<Session>>) {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    for id in ids {
        let meta = json!({"schema": crate::store::META_SCHEMA, "id": id, "name": id,
            "harness": "claude", "cwd": cwd, "status": "idle", "turnCount": 3,
            "createdAt": 1, "updatedAt": 2});
        store.save(&serde_json::from_value(meta).unwrap()).unwrap();
    }
    let hub = Hub::new(cfg, store);
    hub.begin_startup(false);
    let sessions = ids.iter().map(|id| hub.resolve(id).unwrap()).collect();
    (hub, sessions)
}

/// A notice went: it is in flight, or it went and the chat (no agent here) refused it.
fn tried(session: &Session) -> bool {
    let inbox = session.inbox();
    inbox.in_flight.is_some()
        || inbox.refused_at != 0
        || inbox.items.iter().any(|i| i.noticed || i.answered.is_some())
}

/// A new message `id` from chat `from`, of `class`, that came at `at`.
fn held(id: &str, from: &str, class: PromptClass, at: u64) -> Item {
    let mut item = Item::carried(id, from, "PR #1 is green\nmore detail");
    item.from_session = Some(from.to_owned());
    item.class = class;
    item.at = at;
    item.noticed = false;
    item
}

/// The restart this module fixes: a blocker held for an idle chat, then the daemon restarts. Its
/// inbox comes back from the log with no timer and no arrival to review it; before the fix it
/// sat until something else started a turn (NOW, 2026-11-25: 219 messages, the soonest 46 hours
/// past its deadline). The restore's own review delivers it.
#[tokio::test]
async fn a_restored_inbox_is_reviewed_so_a_held_messages_deadline_survives_a_restart() {
    let (hub, sessions) = hub_with_chats(&["lane-restored"]);
    let session = &sessions[0];
    let record = json!({"promptId": "b1", "threadId": "t", "from": "lane-a", "class": "block",
        "kind": "blocker", "text": "blocked on your review"});
    hub.append(session, "mux", "inbox", record);
    // The restart: the in-memory inbox, its timer included, is gone; the log is read again.
    *session.inbox() = Default::default();
    hub.restore_inbox(session);
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(5);
    while !tried(session) {
        assert!(tokio::time::Instant::now() < deadline, "the restored blocker was never delivered");
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
}

/// The sweep reviews a chat whose inbox holds a due message nothing reviewed (no timer, no
/// arrival, no turn): it goes in.
#[tokio::test]
async fn the_sweep_delivers_a_due_message_no_timer_waits_for() {
    let (hub, sessions) = hub_with_chats(&["lane-swept"]);
    let session = &sessions[0];
    let at = now_ms().saturating_sub(RESULT_DEADLINE_MS + 1);
    session.inbox().items.push(held("r1", "other", PromptClass::Result, at));
    assert_eq!(hub.inbox_deadline_sweep(), 0, "nothing is a day past its deadline");
    assert!(tried(session), "the sweep's review delivered the overdue result");
}

/// What no turn can take (here a person's Stop holds other agents' messages): a message a day
/// past its deadline expires, with the reason in its record, and its sender chat hears of it in
/// one FYI. A newer one stays, and nothing expires under a running turn.
#[tokio::test]
async fn a_message_no_turn_can_take_expires_a_day_past_its_deadline_and_goes_back_to_its_sender() {
    let (hub, sessions) = hub_with_chats(&["lane-held", "lane-sender"]);
    let (receiver, sender) = (&sessions[0], &sessions[1]);
    receiver.stop_hold.store(1, std::sync::atomic::Ordering::SeqCst);
    let old = now_ms().saturating_sub(RESULT_DEADLINE_MS + EXPIRE_AFTER_MS + 60_000);
    receiver.inbox().items.push(held("old", &sender.id, PromptClass::Result, old));
    receiver.inbox().items.push(held("new", &sender.id, PromptClass::Result, now_ms()));

    let turn = TurnInfo::prompted("test", "go", "t-run", "p-run", Control::Local);
    *receiver.turn.lock().unwrap() = Some(turn);
    assert_eq!(hub.inbox_expire(receiver), 0, "a running turn takes its inbox at its end");
    *receiver.turn.lock().unwrap() = None;

    assert_eq!(hub.inbox_deadline_sweep(), 1);
    {
        let inbox = receiver.inbox();
        let ids: Vec<&str> = inbox.items.iter().map(|i| i.prompt_id.as_str()).collect();
        assert_eq!(ids, ["new"], "only the one a day past its deadline expired");
        assert!(inbox.removed.contains("old"), "a resend of it answers withdrawn");
    }
    let events = hub.events(&receiver.id, 0, 100).unwrap();
    let removed = events.iter().find(|e| e.kind == "inbox_removed").expect("its record");
    assert_eq!(removed.msg["promptId"], "old");
    assert_eq!(removed.msg["reason"], "expired");
    assert!(removed.msg["why"].as_str().unwrap().contains("Stop"), "{}", removed.msg);

    let inbox = sender.inbox();
    let bounce = inbox.items.iter().find(|i| i.thread == BOUNCE_THREAD).expect("a bounce");
    assert_eq!(bounce.class, PromptClass::Fyi);
    assert!(bounce.from_session.is_none(), "a bounce never bounces again");
    assert!(bounce.text.contains("lane-held"), "{}", bounce.text);
    assert!(bounce.text.contains("PR #1 is green"), "it names what did not arrive");
    drop(inbox);
    let logged = hub.events(&sender.id, 0, 100).unwrap();
    assert!(logged.iter().any(|e| e.kind == "inbox" && e.msg["threadId"] == BOUNCE_THREAD));
}

/// A chat whose folder is gone (a probe's folder under /tmp, seen 2026-11-25) refuses every
/// wake: its expiry says so.
#[test]
fn an_expiry_names_a_missing_folder_as_why_no_turn_took_it() {
    let (_hub, sessions) =
        hub_with_chats_in(&["lane-gone"], "/tmp/acpmux-deadline-test-folder-gone");
    let inbox = sessions[0].inbox();
    assert!(why_undelivered(&sessions[0], &inbox).contains("folder no longer exists"));
}

#[test]
fn only_new_messages_a_day_past_their_deadline_expire() {
    let now = 10 * EXPIRE_AFTER_MS;
    let past = now - RESULT_DEADLINE_MS - EXPIRE_AFTER_MS - 1;
    let mut seen = held("seen", "a", PromptClass::Result, past);
    seen.noticed = true;
    let mut surge = held("surge", "a", PromptClass::Result, past);
    surge.surge_held = true;
    let items = vec![
        held("past", "a", PromptClass::Result, past),
        held("inside", "a", PromptClass::Result, past + 2),
        seen,
        surge,
    ];
    assert_eq!(expired_ids(&items, now, Item::due), ["past"]);
}
