//! Graphics and notification events, and subscription overflow recovery.

use super::*;

#[cfg(unix)]
#[test]
fn graphics_status_event_preserves_localization_fields() {
    let (client, _server) = UnixStream::pair().unwrap();
    let session = socket_test_session(client);
    let events = session.subscribe();

    session.handle_line(json!({
        "event": "graphics-status",
        "kind": "kitty-image-budget-update-failed",
        "retry_exhausted": true,
        "summary": "surface 7: offline",
    }));

    assert!(events.try_iter().any(|event| matches!(
        event,
        MuxEvent::GraphicsStatus(
            GraphicsStatus::KittyImageBudgetUpdateFailed {
                retry_exhausted: true,
                summary,
            }
        ) if summary.as_ref() == "surface 7: offline"
    )));
}

#[cfg(unix)]
#[test]
fn notification_event_preserves_payload_without_invalidating_tree() {
    let (client, _server) = UnixStream::pair().unwrap();
    let session = socket_test_session(client);
    let events = session.subscribe();
    session.tree_stale.store(false, Ordering::Release);

    session.handle_line(json!({
        "event": "notification",
        "notification": 42,
        "title": "Build",
        "body": "finished",
        "level": "warning",
        "surface": 7,
    }));

    assert!(!session.tree_is_stale());
    assert!(events.try_iter().any(|event| {
        matches!(
            event,
            MuxEvent::Notification(notification)
                if notification.notification == 42
                    && notification.title == "Build"
                    && notification.body == "finished"
                    && notification.level == NotificationLevel::Warning
                    && notification.surface == Some(7)
        )
    }));
}

#[cfg(unix)]
#[test]
fn subscription_overflow_resubscribes_and_invalidates_authoritative_snapshots() {
    let (client, server) = UnixStream::pair().unwrap();
    let session = socket_test_session(client);
    let events = session.subscribe();
    session.tree_stale.store(false, Ordering::Release);

    session.handle_line(json!({
        "event": "overflow",
        "error": "subscriber fell behind",
    }));

    let mut line = String::new();
    BufReader::new(server).read_line(&mut line).unwrap();
    let command: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(command.get("cmd").and_then(Value::as_str), Some("subscribe"));
    session.handle_line(json!({"id": command["id"], "ok": true, "data": {}}));
    assert!(session.tree_is_stale());
    let mut saw_status = false;
    let mut saw_tree = false;
    let mut saw_clients = false;
    while !saw_tree || !saw_clients {
        match events.recv_timeout(Duration::from_secs(1)).unwrap() {
            MuxEvent::Status(_) => saw_status = true,
            MuxEvent::TreeChanged => saw_tree = true,
            MuxEvent::ClientListInvalidated => saw_clients = true,
            _ => {}
        }
    }
    assert!(saw_status);
}

#[cfg(unix)]
#[test]
fn subscription_overflow_during_recovery_forces_another_resubscribe() {
    let (client, server) = UnixStream::pair().unwrap();
    let session = socket_test_session(client);
    let events = session.subscribe();
    let mut server = BufReader::new(server);

    session.handle_line(json!({"event": "overflow", "error": "first stream overflow"}));
    let mut line = String::new();
    server.read_line(&mut line).unwrap();
    let first: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(first.get("cmd").and_then(Value::as_str), Some("subscribe"));

    session.handle_line(json!({"event": "overflow", "error": "replacement overflow"}));
    session.handle_line(json!({"id": first["id"], "ok": true, "data": {}}));

    line.clear();
    server.read_line(&mut line).unwrap();
    let second: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(second.get("cmd").and_then(Value::as_str), Some("subscribe"));
    assert_ne!(second["id"], first["id"]);
    session.handle_line(json!({"id": second["id"], "ok": true, "data": {}}));

    loop {
        if matches!(
            events.recv_timeout(Duration::from_secs(1)).unwrap(),
            MuxEvent::ClientListInvalidated
        ) {
            break;
        }
    }
    let recovery = session.subscription_recovery.lock().unwrap();
    assert!(!recovery.in_flight);
    assert_eq!(recovery.generation, 2);
}

#[cfg(unix)]
#[test]
fn rejected_subscription_recovery_retries_then_closes_session() {
    let (client, server) = UnixStream::pair().unwrap();
    let session = socket_test_session(client);
    let events = session.subscribe();

    session.handle_line(json!({"event": "overflow", "error": "subscriber fell behind"}));

    let mut line = String::new();
    let mut server = BufReader::new(server);
    server.read_line(&mut line).unwrap();
    let command: Value = serde_json::from_str(&line).unwrap();
    session.handle_line(json!({
        "id": command["id"],
        "ok": false,
        "error": "replacement rejected",
    }));

    line.clear();
    server.read_line(&mut line).unwrap();
    let retry: Value = serde_json::from_str(&line).unwrap();
    session.handle_line(json!({
        "id": retry["id"],
        "ok": false,
        "error": "replacement rejected again",
    }));

    loop {
        if matches!(events.recv_timeout(Duration::from_secs(1)).unwrap(), MuxEvent::Empty) {
            break;
        }
    }
    assert!(!session.subscription_recovery.lock().unwrap().in_flight);
}

#[test]
fn subscription_recovery_retries_only_explicit_rejection() {
    let rejected = anyhow::Error::new(RemoteRequestError::Rejected {
        error: "no capacity".to_string(),
        code: None,
        delivery: None,
    });
    let timeout = anyhow::Error::new(RemoteRequestError::Timeout);
    let shutdown = anyhow::Error::new(RemoteRequestError::Shutdown);

    assert!(RemoteSession::subscription_recovery_is_retryable(&rejected));
    assert!(!RemoteSession::subscription_recovery_is_retryable(&timeout));
    assert!(!RemoteSession::subscription_recovery_is_retryable(&shutdown));
}
