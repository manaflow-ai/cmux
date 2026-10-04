//! The local feed owner across restarts (feed.md 9.1: B3, B4, B5, B7).

use super::*;
use crate::workspace_registry::WorkspaceMutation;
use cmux_feed_core::ItemState;

struct Root(std::path::PathBuf);

impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn root(name: &str) -> Root {
    Root(
        std::env::temp_dir()
            .join(format!("cmux-feed-local-{name}-{}", WorkspacePublicId::random().unwrap())),
    )
}

fn open(root: &Root, session: &str) -> Arc<Mux> {
    let registry = WorkspaceRegistry::open(&root.0, session).unwrap();
    Mux::from_workspace_registry(
        session.into(),
        SurfaceOptions::default(),
        registry,
        ProviderWorkspaceState::default(),
        true,
    )
    .unwrap()
}

fn all(mux: &Mux) -> Vec<Item> {
    mux.feed_local_list(&ListFilter::default())
}

fn post(mux: &Mux, title: &str, surface: Option<SurfaceId>) -> NotificationPublicId {
    mux.post_notification(title.into(), "".into(), NotificationLevel::Info, surface).unwrap();
    mux.resource_notifications(1)[0].id.clone()
}

/// T1 (B4): a registry written before the local owner existed (ledger rows
/// only) opens under the new daemon. Each retained entry becomes one local
/// item, READ iff a client's `read_by` mark or a persisted ack exists; a
/// second migration and a second open add nothing.
#[test]
fn ledger_migrates_into_local_items_once_with_read_state() {
    let root = root("migrate");
    let session = "feed-migrate";
    let mux = open(&root, session);
    let a = mux.new_workspace(None, None).unwrap();
    let b = mux.new_workspace(None, None).unwrap();
    let c = mux.new_workspace(None, None).unwrap();
    let read_by = post(&mux, "read by a client", Some(a.id));
    let acked = post(&mux, "acked tab", Some(b.id));
    let unread = post(&mux, "unread", Some(c.id));
    let plain = post(&mux, "no terminal", None);
    let mutation = WorkspaceMutation::new("ack-read-by", "test").unwrap();
    mux.ack_notifications(&mutation, None, "mac-a", std::slice::from_ref(&read_by)).unwrap();
    mux.acknowledge_tab_notifications(b.id).unwrap();
    // Make the registry look like one written by the previous daemon.
    mux.workspace_registry.lock().unwrap().forget_feed_local_for_test().unwrap();
    drop(mux);

    let mux = open(&root, session);
    let items = all(&mux);
    let state_of = |id: &NotificationPublicId| {
        let item = items
            .iter()
            .find(|item| item.id == feed_item_id(id))
            .unwrap_or_else(|| panic!("no local item for {id}"));
        let registry = mux.workspace_registry.lock().unwrap();
        let key = notify_dedupe_key(registry.session_id(), id);
        assert_eq!(item.dedupe_key, key);
        assert_eq!(item.state, ItemState::Open);
        item.is_unread()
    };
    assert_eq!(items.len(), 4, "one item per ledger entry: {items:?}");
    assert!(!state_of(&read_by), "a read_by mark migrates as read");
    assert!(!state_of(&acked), "a persisted ack migrates as read");
    assert!(state_of(&unread));
    assert!(state_of(&plain));

    let again = mux.workspace_registry.lock().unwrap().migrate_feed_local_from_ledger().unwrap();
    assert_eq!(again, 0, "the meta marker makes a rerun a no-op");
    drop(mux);
    let mux = open(&root, session);
    assert_eq!(all(&mux), items, "a second open adds nothing");
    // Without the marker the dedupe keys still stop duplicates.
    mux.workspace_registry.lock().unwrap().forget_feed_local_marker_for_test().unwrap();
    let again = mux.workspace_registry.lock().unwrap().migrate_feed_local_from_ledger().unwrap();
    assert_eq!(again, 0, "dedupe keys make a rerun a no-op");
    assert_eq!(mux.workspace_registry.lock().unwrap().feed_local_items().unwrap(), items);
}

/// T2 (B3, B5, daemon side): an item marked `handing_off` survives a
/// restart in that state and is listed by state; `handoff done` moves it to
/// `moved {home: cloud}`; a repeat is idempotent; a read of the moved item
/// is refused with `owner.unreachable` (retryable) and nothing queues.
#[test]
fn handing_off_survives_restart_and_moved_items_refuse_reads() {
    let root = root("handoff");
    let session = "feed-handoff";
    let mux = open(&root, session);
    let surface = mux.new_workspace(None, None).unwrap();
    post(&mux, "agent waiting", Some(surface.id));
    let item = all(&mux).pop().unwrap();
    let begun = mux.feed_local_handoff_begin(&item.id).unwrap();
    assert_eq!(begun.state, ItemState::HandingOff);
    drop(mux);

    let mux = open(&root, session);
    let filter = ListFilter { state: Some(ItemState::HandingOff), ..ListFilter::default() };
    let handing_off = mux.feed_local_list(&filter);
    assert_eq!(handing_off.iter().map(|item| item.id.as_str()).collect::<Vec<_>>(), [&item.id]);
    let error = mux.feed_local_read(std::slice::from_ref(&item.id)).unwrap_err();
    assert_eq!(feed_error_code(&error).as_deref(), Some("feed.moving"));

    let moved = mux.feed_local_handoff_done(&item.id, "cloud").unwrap();
    assert_eq!(moved.state, ItemState::Moved);
    assert_eq!(moved.home.as_deref(), Some("cloud"));
    let repeat = mux.feed_local_handoff_done(&item.id, "cloud").unwrap();
    assert_eq!(repeat, moved, "a repeated done is idempotent");
    let error = mux.feed_local_read(std::slice::from_ref(&item.id)).unwrap_err();
    assert_eq!(feed_error_code(&error).as_deref(), Some("owner.unreachable"));
    assert!(error.downcast_ref::<FeedError>().unwrap().retryable());
    // The tab ack's refusal is covered by server/feed_local_tests.rs (one
    // live mux, so the tab still exists).
    drop(mux);

    let mux = open(&root, session);
    let item = mux.feed_local_list(&ListFilter::default()).pop().unwrap();
    assert_eq!((item.state, item.home.as_deref()), (ItemState::Moved, Some("cloud")));
    assert!(item.is_unread(), "a refused read queues nothing");
}

/// The handoff abort after `feed.adopt.cancel` answered `cancelled: true`:
/// the frozen item is open again, and that survives a restart (B3: the app
/// rebuilds its queue from `handing_off` items, so a reopened item leaves
/// the queue). A moved item cannot be reopened.
#[test]
fn handoff_abort_reopens_the_item_durably() {
    let root = root("abort");
    let session = "feed-abort";
    let mux = open(&root, session);
    let surface = mux.new_workspace(None, None).unwrap();
    post(&mux, "agent waiting", Some(surface.id));
    let item = all(&mux).pop().unwrap();
    mux.feed_local_handoff_begin(&item.id).unwrap();
    drop(mux);

    let mux = open(&root, session);
    let reopened = mux.feed_local_handoff_abort(&item.id).unwrap();
    assert_eq!((reopened.state, reopened.home.as_deref()), (ItemState::Open, None));
    assert_eq!(mux.feed_local_handoff_abort(&item.id).unwrap(), reopened, "a repeat is a no-op");
    drop(mux);

    let mux = open(&root, session);
    let filter = ListFilter { state: Some(ItemState::HandingOff), ..ListFilter::default() };
    assert!(mux.feed_local_list(&filter).is_empty(), "the reopened item left the queue");
    mux.feed_local_read(std::slice::from_ref(&item.id)).unwrap();
    assert!(!all(&mux)[0].is_unread(), "the local owner takes ops on it again");

    post(&mux, "second", Some(surface.id));
    let second = all(&mux).pop().unwrap();
    mux.feed_local_handoff_begin(&second.id).unwrap();
    mux.feed_local_handoff_done(&second.id, "cloud").unwrap();
    let error = mux.feed_local_handoff_abort(&second.id).unwrap_err();
    assert_eq!(feed_error_code(&error).as_deref(), Some("feed.invalid_state"));
}

/// B2 and B7: the post commits with the notification, coalesces per
/// terminal while the item is unread, and the tab ack reads it durably.
#[test]
fn notifications_post_coalesce_and_ack_durably() {
    let root = root("post");
    let session = "feed-post";
    let mux = open(&root, session);
    let surface = mux.new_workspace(None, None).unwrap();
    post(&mux, "first", Some(surface.id));
    post(&mux, "second", Some(surface.id));
    let items = all(&mux);
    assert_eq!(items.len(), 1, "an unread terminal item coalesces: {items:?}");
    assert_eq!((items[0].count, items[0].title.as_str()), (2, "second"));
    let actor = items[0].actor.as_ref().unwrap();
    assert_eq!(actor.kind, "terminal");
    assert_eq!(Some(&actor.id), items[0].context.terminal.as_ref());
    assert!(actor.host.is_some(), "a terminal actor names its host (P8 shape)");
    // Item ids have the cloud owner's shape, so feed.adopt keeps the same id.
    let id = items[0].id.strip_prefix("fi_").expect("fi_ prefix");
    assert!(id.len() == 20 && id.bytes().all(|b| b.is_ascii_digit() || b.is_ascii_lowercase()));
    assert!(items[0].context.workspace.is_some() && items[0].context.tab.is_some());
    // Selecting never reads; the explicit ack does.
    mux.select_tab(None, Some(0), None);
    assert!(all(&mux)[0].is_unread());
    let ack = mux.acknowledge_tab_notifications(surface.id).unwrap();
    assert!(ack.cleared && ack.refused.is_empty());
    post(&mux, "third", Some(surface.id));
    drop(mux);

    let mux = open(&root, session);
    let items = all(&mux);
    assert_eq!(items.len(), 2, "a read item does not coalesce: {items:?}");
    assert!(!items[0].is_unread());
    assert!(items[1].is_unread());
    assert_eq!(items[1].title, "third");
}

/// `feed-local-read` of a terminal's last unread item clears the tab's ring
/// and acknowledges the ledger, so a restart keeps it read.
#[test]
fn reading_the_last_item_clears_the_ring_durably() {
    let root = root("read");
    let session = "feed-read";
    let mux = open(&root, session);
    let surface = mux.new_workspace(None, None).unwrap();
    let notification = post(&mux, "build done", Some(surface.id));
    let item = all(&mux).pop().unwrap();
    assert!(mux.surface_notification(surface.id).is_some());
    mux.feed_local_read(std::slice::from_ref(&item.id)).unwrap();
    assert!(mux.surface_notification(surface.id).is_none(), "the ring follows the item");
    let acked = mux.workspace_registry.lock().unwrap().acked_notification_ids().unwrap();
    assert!(acked.contains(notification.as_str()), "the ledger entry is acknowledged");
    assert!(!all(&mux)[0].is_unread());
}

/// Upgrade A, downgrade B, upgrade C: notifications and acks an older daemon
/// wrote after the marker was set still reach the local owner, because the
/// ledger pass runs on every open. Read is one-way.
#[test]
fn feedfix_ledger_pass_runs_on_every_open_after_a_downgrade() {
    let root = root("downgrade");
    let session = "feed-downgrade";
    // A: the new daemon migrates and posts n1 as a local item.
    let mux = open(&root, session);
    let a = mux.new_workspace(None, None).unwrap();
    let b = mux.new_workspace(None, None).unwrap();
    let c = mux.new_workspace(None, None).unwrap();
    let n1 = post(&mux, "before downgrade", Some(a.id));
    // B: an older daemon writes ledger rows without items, acks n1 durably
    // (persisted ack only) and n2 per client (read_by only).
    let n2 = post(&mux, "older daemon read", Some(b.id));
    let n3 = post(&mux, "older daemon unread", Some(c.id));
    let forgotten = [feed_item_id(&n2), feed_item_id(&n3)];
    let mut registry = mux.workspace_registry.lock().unwrap();
    registry.forget_feed_local_items_for_test(&forgotten).unwrap();
    registry.ack_notifications_durable(&[n1.as_str().to_string()], 1, Vec::new(), None).unwrap();
    drop(registry);
    let mutation = WorkspaceMutation::new("older-ack", "test").unwrap();
    mux.ack_notifications(&mutation, None, "mac-b", std::slice::from_ref(&n2)).unwrap();
    drop(mux);

    // C: the new daemon again.
    let mux = open(&root, session);
    let items = all(&mux);
    let unread = |id: &NotificationPublicId| {
        items
            .iter()
            .find(|item| item.id == feed_item_id(id))
            .unwrap_or_else(|| panic!("no local item for {id}: {items:?}"))
            .is_unread()
    };
    assert!(!unread(&n1), "a persisted ack written by the older daemon reads the item");
    assert!(!unread(&n2), "a read_by mark written by the older daemon migrates as read");
    assert!(unread(&n3), "an unacknowledged notification arrives unread");
    assert_eq!(items.len(), 3);
    drop(mux);
    // Another open changes nothing.
    let mux = open(&root, session);
    assert_eq!(all(&mux), items);
}

/// Review P1: a terminal item that folded more notices than it keeps
/// aliases for must not split into new items on the next open. The ledger
/// pass skips every notification it already folded (the folded set), not
/// only the ones whose dedupe key the item still lists.
#[test]
fn feedfix_ledger_pass_never_reposts_a_folded_notification() {
    let root = root("folded");
    let session = "feed-folded";
    let mux = open(&root, session);
    let surface = mux.new_workspace(None, None).unwrap();
    for index in 0..20 {
        post(&mux, &format!("step {index}"), Some(surface.id));
    }
    let items = all(&mux);
    assert_eq!((items.len(), items[0].count), (1, 20), "{items:?}");
    drop(mux);

    let mux = open(&root, session);
    assert_eq!(all(&mux), items, "a restart adds no item for folded notices");
}

/// Review P1: an item the reducer pruned (moved, or read past retention)
/// stays gone. Its ledger entry is still retained, but the folded set says
/// the local owner already took it, so a restart does not bring back an
/// open copy of an item the cloud owns.
#[test]
fn feedfix_a_pruned_item_does_not_come_back_from_the_ledger() {
    let root = root("pruned");
    let session = "feed-pruned";
    let mux = open(&root, session);
    let surface = mux.new_workspace(None, None).unwrap();
    post(&mux, "agent waiting", Some(surface.id));
    let item = all(&mux).pop().unwrap();
    mux.feed_local_handoff_begin(&item.id).unwrap();
    mux.feed_local_handoff_done(&item.id, "cloud").unwrap();
    // Prune drops the item row only; the ledger entry stays.
    mux.workspace_registry.lock().unwrap().prune_feed_local_rows_for_test(&[item.id]).unwrap();
    drop(mux);

    let mux = open(&root, session);
    assert!(all(&mux).is_empty(), "a pruned item came back: {:?}", all(&mux));
}

/// Review P2: a per-client `read_by` mark (`notification.ack`) does not
/// read an existing item live, so it does not read it on the next open
/// either. Only items the pass creates take `read_by` into account (B4).
#[test]
fn feedfix_read_by_on_an_existing_item_reads_neither_live_nor_after_restart() {
    let root = root("readby");
    let session = "feed-readby";
    let mux = open(&root, session);
    let surface = mux.new_workspace(None, None).unwrap();
    let notification = post(&mux, "seen elsewhere", Some(surface.id));
    let mutation = WorkspaceMutation::new("ack-read-by-live", "test").unwrap();
    mux.ack_notifications(&mutation, None, "mac-a", std::slice::from_ref(&notification)).unwrap();
    assert!(all(&mux)[0].is_unread());
    drop(mux);

    let mux = open(&root, session);
    assert!(all(&mux)[0].is_unread(), "a restart must not change the read state");
}

/// Review P2: reading the only item of a tab without a terminal (a browser
/// tab) clears that tab's marker and acknowledges its ledger entry, so the
/// ring stays clear after a restart.
#[test]
fn feedfix_reading_a_terminal_less_tab_item_clears_its_ring_durably() {
    let root = root("browser");
    let session = "feed-browser";
    let mux = open(&root, session);
    let terminal = mux.new_workspace(None, None).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(terminal)).unwrap();
    let record = crate::workspace_registry::FrontendBrowserRecord {
        engine: "webkit".into(),
        url: "https://example.com/start".into(),
        title: Some("Example".into()),
        favicon_url: None,
        profile_id: Some("default".into()),
        owner: Some("install_mac_a".into()),
    };
    let browser = mux.new_frontend_browser_tab(Some(pane), record, None).unwrap().id;
    let notification = post(&mux, "page done", Some(browser));
    let item = all(&mux).pop().unwrap();
    assert!(item.context.terminal.is_none() && item.context.tab.is_some(), "{item:?}");
    assert!(mux.surface_notification(browser).is_some());
    mux.feed_local_read(std::slice::from_ref(&item.id)).unwrap();
    assert!(mux.surface_notification(browser).is_none(), "the tab ring follows the item");
    let acked = mux.workspace_registry.lock().unwrap().acked_notification_ids().unwrap();
    assert!(acked.contains(notification.as_str()), "the tab's ledger entry is acknowledged");
}

/// Review P2 (second pass): the folded set is bounded by clears and
/// receipts, never by a row count or the clock. A cleared notification
/// loses its row on the next open; the others keep theirs, so a clear that
/// moves the ledger window back brings no coalesced notice back.
#[test]
fn feedfix_folded_rows_follow_clears_not_a_count() {
    let root = root("clears");
    let session = "feed-clears";
    let mux = open(&root, session);
    let a = mux.new_workspace(None, None).unwrap();
    let b = mux.new_workspace(None, None).unwrap();
    let kept: Vec<_> = (0..3).map(|i| post(&mux, &format!("a {i}"), Some(a.id))).collect();
    let cleared = post(&mux, "b", Some(b.id));
    let terminal_b = mux.with_state(|state| {
        state.surfaces.get(&b.id).and_then(|surface| surface.terminal_public_id().cloned())
    });
    let mutation = WorkspaceMutation::new("clear-b", "test").unwrap();
    mux.clear_notifications(&mutation, None, terminal_b.as_ref()).unwrap();
    let items = all(&mux);
    drop(mux);

    let mux = open(&root, session);
    assert_eq!(all(&mux), items, "a restart after a clear adds and changes nothing");
    let folded = mux.workspace_registry.lock().unwrap().feed_local_folded().unwrap();
    for id in &kept {
        assert!(folded.contains_key(id.as_str()), "{id} lost its folded row");
    }
    assert!(!folded.contains_key(cleared.as_str()), "a cleared notification keeps no row");
}
