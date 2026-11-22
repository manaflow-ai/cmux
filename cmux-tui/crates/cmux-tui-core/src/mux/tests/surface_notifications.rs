//! Surface notifications: unread state, view acknowledgement, and the bounded ledger.

use super::*;

#[test]
fn notification_sets_unread_and_clears_when_tab_is_viewed() {
    let mux = test_mux();
    let first = mux.new_workspace(None, None).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let second = mux.new_tab(Some(pane), None, None).unwrap();
    let notification = mux
        .post_notification(
            "Build".to_string(),
            "ok".to_string(),
            NotificationLevel::Warning,
            Some(first.id),
        )
        .unwrap();

    let state = mux.surface_notification(first.id).unwrap();
    assert_eq!(state.notification, notification);
    assert_eq!(state.level, NotificationLevel::Warning);
    assert!(state.unread);

    mux.select_tab(Some(pane), Some(1), None);
    assert!(mux.surface_notification(first.id).is_some());
    mux.select_tab(Some(pane), Some(0), None);
    assert!(mux.surface_notification(first.id).is_none());
    assert!(mux.surface_notification(second.id).is_none());
}

#[test]
fn browser_notification_is_owned_by_its_placement_and_clears_when_viewed() {
    let mux = test_mux();
    let terminal = mux.new_workspace(None, None).unwrap();
    let pane = mux.with_state(|state| state.pane_of(terminal.id).unwrap());
    let browser = mux.new_browser_tab("about:blank#notification".into(), Some(pane), None).unwrap();
    mux.select_tab(Some(pane), Some(0), None);

    let notification = mux
        .post_notification(
            "Browser".into(),
            "ready".into(),
            NotificationLevel::Info,
            Some(browser.id),
        )
        .unwrap();
    let unread = mux.surface_notification(browser.id).unwrap();
    assert_eq!(unread.notification, notification);
    assert!(unread.unread);
    assert!(mux.surface_notification(terminal.id).is_none());

    mux.select_tab(Some(pane), Some(1), None);
    assert!(mux.surface_notification(browser.id).is_none());
}

#[test]
fn notification_to_shared_default_surface_waits_for_explicit_view_acknowledgement() {
    let mux = test_mux();
    let events = mux.subscribe();
    let surface = mux.new_workspace(None, None).unwrap();
    assert_eq!(mux.active_surface(), Some(surface.id));

    let notification = mux
        .post_notification(
            "Build".to_string(),
            "ok".to_string(),
            NotificationLevel::Info,
            Some(surface.id),
        )
        .unwrap();

    let unread = mux.surface_notification(surface.id).unwrap();
    assert_eq!(unread.notification, notification);
    assert!(unread.unread);
    assert!(events.try_iter().any(|event| {
        matches!(
            event,
            MuxEvent::Notification(note)
                if note.notification == notification && note.surface == Some(surface.id)
        )
    }));

    mux.select_tab(None, Some(0), None);
    assert!(mux.surface_notification(surface.id).is_none());
}

#[test]
fn notification_ledger_is_bounded_newest_first_and_uses_public_ids() {
    let mux = test_mux();
    let terminal = mux.new_workspace(None, None).unwrap();
    let terminal_id = terminal.terminal_public_id().cloned().unwrap();
    mux.post_notification(
        "attached".into(),
        "terminal".into(),
        NotificationLevel::Info,
        Some(terminal.id),
    )
    .unwrap();
    assert_eq!(mux.resource_notifications(1)[0].terminal_id, Some(terminal_id));

    for index in 0..300 {
        mux.post_notification(
            format!("notice-{index}"),
            String::new(),
            NotificationLevel::Info,
            None,
        )
        .unwrap();
    }
    let notifications = mux.resource_notifications(1_000);
    assert_eq!(notifications.len(), 256);
    assert_eq!(notifications.first().unwrap().title, "notice-299");
    assert_eq!(notifications.last().unwrap().title, "notice-44");
    assert_eq!(
        notifications.iter().map(|notification| &notification.id).collect::<HashSet<_>>().len(),
        256
    );
    assert!(notifications.windows(2).all(|pair| pair[0].created_at_ms >= pair[1].created_at_ms));
}
