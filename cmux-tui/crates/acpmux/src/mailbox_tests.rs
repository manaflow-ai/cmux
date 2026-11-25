use super::*;
use std::time::{SystemTime, UNIX_EPOCH};

struct TempDir(std::path::PathBuf);
impl TempDir {
    fn new() -> Self {
        let name = format!(
            "acpmux-mailbox-test-{}",
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
        );
        let path = std::env::temp_dir().join(name);
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
    }
    fn path(&self) -> &std::path::Path {
        &self.0
    }
}
impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
fn input(id: &str, to: &str, body: &str) -> SendInput {
    SendInput {
        id: id.into(),
        sender: "a".into(),
        recipient: to.into(),
        body: body.into(),
        metadata: BTreeMap::new(),
    }
}
#[test]
fn idempotent_retry_and_conflict() {
    let b = Mailbox::memory();
    assert_eq!(b.send(input("m1", "b", "one")).unwrap().outcome, SendOutcome::Created);
    assert_eq!(b.send(input("m1", "b", "one")).unwrap().outcome, SendOutcome::Duplicate);
    assert!(matches!(b.send(input("m1", "b", "two")), Err(MailboxError::IdConflict(_))));
}
#[test]
fn recipient_only_ack_and_cursor_order() {
    let b = Mailbox::memory();
    b.send(input("m1", "b", "one")).unwrap();
    b.send(input("m2", "b", "two")).unwrap();
    let page = b.page("b", 0, 1).unwrap();
    assert_eq!(page.rows[0].message.id, "m1");
    assert_eq!(page.next_cursor, Some(1));
    assert!(matches!(b.acknowledge("c", "m1"), Err(MailboxError::NotRecipient(_))));
    assert_eq!(b.acknowledge("b", "m1").unwrap().state, DeliveryState::Acknowledged);
}
#[test]
fn restart_preserves_messages_and_delivery() {
    let d = TempDir::new();
    let b = Mailbox::open(d.path()).unwrap();
    b.send(input("m1", "b", "one")).unwrap();
    b.acknowledge("b", "m1").unwrap();
    let reopened = Mailbox::open(d.path()).unwrap();
    let row = &reopened.page("b", 0, 10).unwrap().rows[0];
    assert_eq!(row.message.id, "m1");
    assert_eq!(row.delivery.state, DeliveryState::Acknowledged);
}
#[cfg(unix)]
#[test]
fn persistent_mailbox_narrows_its_directory_and_state_file() {
    use std::os::unix::fs::PermissionsExt;

    let d = TempDir::new();
    std::fs::set_permissions(d.path(), std::fs::Permissions::from_mode(0o755)).unwrap();
    let state = d.path().join("mailbox.json");
    std::fs::write(
        &state,
        r#"{"schema":"acpmux.mailbox.v1","next_seq":1,"messages":[],"deliveries":[]}"#,
    )
    .unwrap();
    std::fs::set_permissions(&state, std::fs::Permissions::from_mode(0o644)).unwrap();
    let b = Mailbox::open(d.path()).unwrap();
    b.send(input("m1", "b", "private message")).unwrap();
    let mode = |path: &std::path::Path| {
        std::fs::symlink_metadata(path).unwrap().permissions().mode() & 0o777
    };
    assert_eq!(mode(d.path()), 0o700);
    assert_eq!(mode(&d.path().join("mailbox.json")), 0o600);
}
#[cfg(unix)]
#[test]
fn persistent_mailbox_refuses_a_symlinked_state_file() {
    let d = TempDir::new();
    let target = d.path().join("outside.json");
    std::fs::write(
        &target,
        r#"{"schema":"acpmux.mailbox.v1","next_seq":1,"messages":[],"deliveries":[]}"#,
    )
    .unwrap();
    std::os::unix::fs::symlink(&target, d.path().join("mailbox.json")).unwrap();
    assert!(Mailbox::open(d.path()).is_err());
}
#[test]
fn repeated_ack_is_idempotent() {
    let b = Mailbox::memory();
    b.send(input("m1", "b", "one")).unwrap();
    let first = b.acknowledge("b", "m1").unwrap();
    let second = b.acknowledge("b", "m1").unwrap();
    assert_eq!(first.message_id, second.message_id);
    assert_eq!(second.state, DeliveryState::Acknowledged);
}

#[tokio::test]
async fn wait_wakes_after_durable_append() {
    let b = Mailbox::memory();
    let waiter = b.clone();
    let task = tokio::spawn(async move { waiter.wait("b", 0, 10, 1_000).await.unwrap() });
    tokio::task::yield_now().await;
    b.send(input("m1", "b", "one")).unwrap();
    let page = task.await.unwrap();
    assert_eq!(page.rows[0].message.id, "m1");
}

#[tokio::test]
async fn quiet_delivery_wakes_reports_waiters_without_model_injection() {
    let b = Mailbox::memory();
    let waiter = b.clone();
    let task = tokio::spawn(async move { waiter.wait("reports:leo", 0, 10, 1_000).await.unwrap() });
    tokio::task::yield_now().await;
    b.deliver_quiet(input("report-1", "reports:leo", "one")).unwrap();
    let page = task.await.unwrap();
    assert_eq!(page.rows[0].message.body, "one");
    assert_eq!(page.rows[0].message.recipient, "reports:leo");
}

#[tokio::test]
async fn wait_registers_before_a_send_after_the_empty_page() {
    let b = Mailbox::memory();
    let hook_mailbox = b.clone();
    b.set_wait_page_hook(move || {
        hook_mailbox.send(input("window", "b", "sent in the page/await window")).unwrap();
    });
    let page = b.wait("b", 0, 10, 1_000).await.unwrap();
    assert_eq!(page.rows.len(), 1);
    assert_eq!(page.rows[0].message.id, "window");
}

#[test]
fn missing_recipient_and_unknown_ack_are_rejected() {
    let b = Mailbox::memory();
    assert!(matches!(b.page("", 0, 1), Err(MailboxError::MissingRecipient)));
    assert!(matches!(b.acknowledge("b", "unknown"), Err(MailboxError::NotFound(_))));
}

#[tokio::test]
async fn wait_deadline_is_not_reset_by_unrelated_notifications() {
    let b = Mailbox::memory();
    let notifier = b.clone();
    let task = tokio::spawn(async move { notifier.wait("recipient-b", 0, 1, 50).await.unwrap() });
    for _ in 0..5 {
        tokio::task::yield_now().await;
        b.send(input("other", "recipient-a", "unrelated")).ok();
    }
    let page = task.await.unwrap();
    assert!(page.rows.is_empty());
}

#[test]
fn corrupt_state_is_rejected_before_use() {
    let d = TempDir::new();
    std::fs::write(d.path().join("mailbox.json"), r#"{"schema":"acpmux.mailbox.v1","next_seq":1,"messages":[{"id":"m1","seq":1,"sender":"a","recipient":"b","body":"x","createdAt":1,"metadata":{}}],"deliveries":[]}"#).unwrap();
    assert!(Mailbox::open(d.path()).is_err());
}

fn test_message(id: &str, seq: u64) -> MailMessage {
    MailMessage {
        id: id.into(),
        seq,
        sender: "a".into(),
        recipient: "b".into(),
        body: "body".into(),
        created_at: 1,
        metadata: BTreeMap::new(),
    }
}

fn test_delivery(message_id: &str) -> DeliveryReceipt {
    DeliveryReceipt {
        message_id: message_id.into(),
        recipient: "b".into(),
        state: DeliveryState::Queued,
        updated_at: 1,
    }
}

#[test]
fn validate_state_rejects_duplicate_and_missing_deliveries() {
    let duplicate = PersistedState {
        schema: SCHEMA.into(),
        next_seq: 3,
        messages: vec![test_message("m1", 1), test_message("m2", 2)],
        deliveries: vec![test_delivery("m1"), test_delivery("m1")],
    };
    let error = validate_state(&duplicate).unwrap_err().to_string();
    assert!(error.contains("duplicate delivery m1"), "{error}");

    let missing = PersistedState {
        schema: SCHEMA.into(),
        next_seq: 3,
        messages: vec![test_message("m1", 1), test_message("m2", 2)],
        deliveries: vec![test_delivery("m1")],
    };
    let error = validate_state(&missing).unwrap_err().to_string();
    assert!(error.contains("missing delivery m2"), "{error}");
}

#[test]
fn rejects_oversized_body() {
    let b = Mailbox::memory();
    assert!(matches!(
        b.send(input("m1", "b", &"x".repeat(MAX_BODY_BYTES + 1))),
        Err(MailboxError::BodyTooLarge)
    ));
}
