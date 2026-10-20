//! cx-on7iu: a terminal bell marks its tab for attention like a notification
//! (Lawrence 2026-10-14). A program that rings several
//! times at once, or again while the mark is unread, posts one notification.

use super::*;

/// The daemon's `Bell` notifications.
fn bell_notifications(harness: &RecoveryHarness, round: usize) -> Vec<serde_json::Value> {
    let listed = resource_request(
        &harness.socket,
        &format!("bell-notifications-{round}"),
        "notification.list",
        serde_json::json!({"machine":"current","session":"current"}),
        None,
    );
    listed.as_array().unwrap().iter().filter(|n| n["title"] == "Bell").cloned().collect()
}

#[test]
fn a_terminal_bell_posts_one_attention_notification_for_its_terminal() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("bell-notification");
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": ["/bin/sh", "-c", "printf '\\a\\a\\a'; printf 'rang\\r\\n'; sleep 11; printf '\\a'; printf 'again\\r\\n'; sleep 600"],
            "new_workspace": true,
            "name": "bell",
            "cols": 80,
            "rows": 8,
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    assert!(wait_for_screen(&harness.socket, surface, "rang").contains("rang"));
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    let mut round = 0;
    let bells = loop {
        let bells = bell_notifications(&harness, round);
        if !bells.is_empty() {
            break bells;
        }
        assert!(Instant::now() < deadline, "the bell posted no notification");
        round += 1;
        std::thread::sleep(Duration::from_millis(50));
    };
    // The run reply names the terminal by its internal id; the notification by its public `term_` id.
    let terminals = resource_request(
        &harness.socket,
        "bell-terminals",
        "terminal.list",
        serde_json::json!({"machine":"current","session":"current"}),
        None,
    );
    assert_eq!(
        terminals.as_array().map(Vec::len),
        Some(1),
        "one terminal ({terminal_id}): {terminals}"
    );
    assert_eq!(
        bells[0]["terminal_id"], terminals[0]["id"],
        "the bell notification names its terminal: {bells:?}"
    );
    assert_eq!(bells[0]["unread"], true, "{bells:?}");
    // A bell after the cooldown while the first mark is still unread posts nothing new.
    std::thread::sleep(Duration::from_secs(11));
    assert!(wait_for_screen(&harness.socket, surface, "again").contains("again"));
    let bells = bell_notifications(&harness, round + 1);
    assert_eq!(bells.len(), 1, "four bells, one unread mark: {bells:?}");
}
