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
