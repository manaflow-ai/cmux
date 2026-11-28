//! Surface notifications: unread state, view acknowledgement, and the bounded ledger.

use super::*;

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
