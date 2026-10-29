//! Durable inter-session mailbox primitives.
//!
//! Mail is committed to one state file before a wait notification is released.
//! A caller supplied id is the idempotency key; retries return the original
//! message, while a changed payload is rejected. Delivery state is scoped to
//! the recipient so one agent cannot acknowledge another agent's message.

use anyhow::{Context, Result, bail};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use tokio::sync::Notify;

pub const MAX_BODY_BYTES: usize = 64 * 1024;
pub const MAX_METADATA_BYTES: usize = 16 * 1024;
pub const MAX_PAGE_SIZE: usize = 100;
const SCHEMA: &str = "acpmux.mailbox.v1";

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DeliveryState {
    Queued,
    Acknowledged,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct MailMessage {
    pub id: String,
    pub seq: u64,
    pub sender: String,
    pub recipient: String,
    pub body: String,
    pub created_at: u64,
    #[serde(default)]
    #[schemars(with = "BTreeMap<String, Value>")]
    pub metadata: BTreeMap<String, Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct DeliveryReceipt {
    pub message_id: String,
    pub recipient: String,
    pub state: DeliveryState,
    pub updated_at: u64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct MailboxRow {
    pub message: MailMessage,
    pub delivery: DeliveryReceipt,
}

#[derive(Debug, Clone, PartialEq)]
pub struct MailboxPage {
    pub cursor: u64,
    pub rows: Vec<MailboxRow>,
    pub next_cursor: Option<u64>,
}

#[derive(Debug, Clone)]
pub struct SendInput {
    pub id: String,
    pub sender: String,
    pub recipient: String,
    pub body: String,
    pub metadata: BTreeMap<String, Value>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SendOutcome {
    Created,
    Duplicate,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SendResult {
    pub message: MailMessage,
    pub receipt: DeliveryReceipt,
    pub outcome: SendOutcome,
}

#[derive(Debug, thiserror::Error)]
pub enum MailboxError {
    #[error("mailbox sender is required")]
    MissingSender,
    #[error("mailbox recipient is required")]
    MissingRecipient,
    #[error("mailbox id is required")]
    MissingId,
    #[error("mailbox body exceeds {MAX_BODY_BYTES} bytes")]
    BodyTooLarge,
    #[error("mailbox metadata exceeds {MAX_METADATA_BYTES} bytes")]
    MetadataTooLarge,
    #[error("mailbox id {0} was already used with different content")]
    IdConflict(String),
    #[error("mailbox message {0} was not found")]
    NotFound(String),
    #[error("mailbox recipient is not allowed to acknowledge message {0}")]
    NotRecipient(String),
    #[error("mailbox cursor must be non-negative")]
    InvalidCursor,
    #[error("mailbox storage: {0}")]
    Storage(#[from] anyhow::Error),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct PersistedState {
    schema: String,
    next_seq: u64,
    messages: Vec<MailMessage>,
    deliveries: Vec<DeliveryReceipt>,
}

#[derive(Debug)]
struct Inner {
    state: PersistedState,
    path: Option<PathBuf>,
}

#[derive(Clone)]
pub struct Mailbox {
    inner: Arc<Mutex<Inner>>,
    notify: Arc<Notify>,
    #[cfg(test)]
    wait_page_hook: Arc<Mutex<Option<Box<dyn FnOnce() + Send>>>>,
}

impl Mailbox {
    pub fn memory() -> Self {
        Self::from_state(
            PersistedState {
                schema: SCHEMA.into(),
                next_seq: 1,
                messages: Vec::new(),
                deliveries: Vec::new(),
            },
            None,
        )
    }

    pub fn open(root: impl AsRef<Path>) -> Result<Self> {
        let root = root.as_ref();
        crate::config::private_state_dir(root)
            .with_context(|| format!("create private mailbox {}", root.display()))?;
        let path = root.join("mailbox.json");
        let state = if path.exists() {
            use std::io::Read;
            let mut bytes = Vec::new();
            crate::config::private_state_file(&path)?
                .read_to_end(&mut bytes)
                .with_context(|| format!("read {}", path.display()))?;
            let state: PersistedState = serde_json::from_slice(&bytes)
                .with_context(|| format!("parse {}", path.display()))?;
            if state.schema != SCHEMA {
                bail!("unsupported mailbox schema {}", state.schema);
            }
            validate_state(&state)?;
            state
        } else {
            PersistedState {
                schema: SCHEMA.into(),
                next_seq: 1,
                messages: Vec::new(),
                deliveries: Vec::new(),
            }
        };
        Ok(Self::from_state(state, Some(path)))
    }

    fn from_state(state: PersistedState, path: Option<PathBuf>) -> Self {
        Self {
            inner: Arc::new(Mutex::new(Inner { state, path })),
            notify: Arc::new(Notify::new()),
            #[cfg(test)]
            wait_page_hook: Arc::new(Mutex::new(None)),
        }
    }

    pub fn send(&self, input: SendInput) -> std::result::Result<SendResult, MailboxError> {
        self.send_inner(input)
    }

    /// Append a message without injecting it into a model turn. The notify is
    /// only a mailbox-reader wakeup; report readers use a non-session alias.
    pub fn deliver_quiet(&self, input: SendInput) -> std::result::Result<SendResult, MailboxError> {
        self.send_inner(input)
    }

    fn send_inner(&self, input: SendInput) -> std::result::Result<SendResult, MailboxError> {
        validate(&input)?;
        let mut inner = self
            .inner
            .lock()
            .map_err(|_| MailboxError::Storage(anyhow::anyhow!("mailbox state lock poisoned")))?;
        if let Some(message) = inner.state.messages.iter().find(|m| m.id == input.id).cloned() {
            let existing = inner
                .state
                .deliveries
                .iter()
                .find(|d| d.message_id == input.id)
                .cloned()
                .ok_or_else(|| {
                    MailboxError::Storage(anyhow::anyhow!(
                        "mailbox delivery missing for {}",
                        input.id
                    ))
                })?;
            if message.sender != input.sender
                || message.recipient != input.recipient
                || message.body != input.body
                || message.metadata != input.metadata
            {
                return Err(MailboxError::IdConflict(input.id));
            }
            return Ok(SendResult { message, receipt: existing, outcome: SendOutcome::Duplicate });
        }
        let message = MailMessage {
            id: input.id,
            seq: inner.state.next_seq,
            sender: input.sender,
            recipient: input.recipient,
            body: input.body,
            created_at: crate::store::now_ms(),
            metadata: input.metadata,
        };
        let next_seq =
            inner.state.next_seq.checked_add(1).ok_or_else(|| {
                MailboxError::Storage(anyhow::anyhow!("mailbox sequence exhausted"))
            })?;
        let receipt = DeliveryReceipt {
            message_id: message.id.clone(),
            recipient: message.recipient.clone(),
            state: DeliveryState::Queued,
            updated_at: message.created_at,
        };
        let mut candidate = inner.state.clone();
        candidate.next_seq = next_seq;
        candidate.messages.push(message.clone());
        candidate.deliveries.push(receipt.clone());
        persist_state(inner.path.as_ref(), &candidate)?;
        inner.state = candidate;
        drop(inner);
        self.notify.notify_waiters();
        Ok(SendResult { message, receipt, outcome: SendOutcome::Created })
    }

    pub fn page(
        &self,
        recipient: &str,
        after: u64,
        limit: usize,
    ) -> std::result::Result<MailboxPage, MailboxError> {
        if recipient.trim().is_empty() {
            return Err(MailboxError::MissingRecipient);
        }
        let limit = limit.clamp(1, MAX_PAGE_SIZE);
        let inner = self
            .inner
            .lock()
            .map_err(|_| MailboxError::Storage(anyhow::anyhow!("mailbox state lock poisoned")))?;
        let rows: Vec<_> = inner
            .state
            .messages
            .iter()
            .filter(|m| m.recipient == recipient && m.seq > after)
            .filter_map(|m| {
                inner
                    .state
                    .deliveries
                    .iter()
                    .find(|d| d.message_id == m.id)
                    .cloned()
                    .map(|delivery| MailboxRow { message: m.clone(), delivery })
            })
            .take(limit)
            .collect();
        let next_cursor = rows.last().and_then(|last| {
            inner
                .state
                .messages
                .iter()
                .any(|m| m.recipient == recipient && m.seq > last.message.seq)
                .then_some(last.message.seq)
        });
        Ok(MailboxPage { cursor: after, rows, next_cursor })
    }

    pub fn acknowledge(
        &self,
        recipient: &str,
        message_id: &str,
    ) -> std::result::Result<DeliveryReceipt, MailboxError> {
        let mut inner = self
            .inner
            .lock()
            .map_err(|_| MailboxError::Storage(anyhow::anyhow!("mailbox state lock poisoned")))?;
        let message = inner
            .state
            .messages
            .iter()
            .find(|m| m.id == message_id)
            .ok_or_else(|| MailboxError::NotFound(message_id.into()))?;
        if message.recipient != recipient {
            return Err(MailboxError::NotRecipient(message_id.into()));
        }
        let mut candidate = inner.state.clone();
        let delivery =
            candidate.deliveries.iter_mut().find(|d| d.message_id == message_id).ok_or_else(
                || {
                    MailboxError::Storage(anyhow::anyhow!(
                        "mailbox delivery missing for {}",
                        message_id
                    ))
                },
            )?;
        delivery.state = DeliveryState::Acknowledged;
        delivery.updated_at = crate::store::now_ms();
        let receipt = delivery.clone();
        persist_state(inner.path.as_ref(), &candidate)?;
        inner.state = candidate;
        drop(inner);
        self.notify.notify_waiters();
        Ok(receipt)
    }

    pub async fn wait(
        &self,
        recipient: &str,
        after: u64,
        limit: usize,
        timeout_ms: u64,
    ) -> std::result::Result<MailboxPage, MailboxError> {
        let timeout = std::time::Duration::from_millis(timeout_ms.min(30_000));
        let deadline = tokio::time::Instant::now() + timeout;
        loop {
            // Register before reading the page. A send that commits after the
            // read but before the await is then retained by Notify rather than
            // becoming a lost wakeup.
            let notified = self.notify.notified();
            let page = self.page(recipient, after, limit)?;
            #[cfg(test)]
            self.run_wait_page_hook();
            if !page.rows.is_empty() || timeout.is_zero() {
                return Ok(page);
            }
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remaining.is_zero() || tokio::time::timeout(remaining, notified).await.is_err() {
                return self.page(recipient, after, limit);
            }
        }
    }

    pub fn flush(&self) -> Result<()> {
        let inner =
            self.inner.lock().map_err(|_| anyhow::anyhow!("mailbox state lock poisoned"))?;
        persist(&inner).map_err(|e| anyhow::anyhow!(e))
    }

    #[cfg(test)]
    fn set_wait_page_hook<F>(&self, hook: F)
    where
        F: FnOnce() + Send + 'static,
    {
        *self.wait_page_hook.lock().unwrap_or_else(std::sync::PoisonError::into_inner) =
            Some(Box::new(hook));
    }

    #[cfg(test)]
    fn run_wait_page_hook(&self) {
        let hook =
            self.wait_page_hook.lock().unwrap_or_else(std::sync::PoisonError::into_inner).take();
        if let Some(hook) = hook {
            hook();
        }
    }
}

fn validate_state(state: &PersistedState) -> Result<()> {
    let mut ids = std::collections::BTreeSet::new();
    let mut seqs = std::collections::BTreeSet::new();
    let mut delivery_ids = std::collections::BTreeSet::new();
    anyhow::ensure!(state.next_seq > 0, "mailbox next sequence must be positive");
    for message in &state.messages {
        anyhow::ensure!(
            ids.insert(message.id.clone()),
            "mailbox has duplicate message id {}",
            message.id
        );
        anyhow::ensure!(seqs.insert(message.seq), "mailbox has duplicate sequence {}", message.seq);
        anyhow::ensure!(
            message.seq < state.next_seq,
            "mailbox next sequence is behind message {}",
            message.id
        );
    }
    for delivery in &state.deliveries {
        anyhow::ensure!(
            delivery_ids.insert(delivery.message_id.clone()),
            "mailbox has duplicate delivery {}",
            delivery.message_id
        );
        let message =
            state.messages.iter().find(|message| message.id == delivery.message_id).ok_or_else(
                || anyhow::anyhow!("mailbox has orphan delivery {}", delivery.message_id),
            )?;
        anyhow::ensure!(
            message.recipient == delivery.recipient,
            "mailbox delivery recipient mismatch for {}",
            delivery.message_id
        );
    }
    for message in &state.messages {
        anyhow::ensure!(
            delivery_ids.contains(&message.id),
            "mailbox has missing delivery {}",
            message.id
        );
    }
    Ok(())
}

fn validate(input: &SendInput) -> std::result::Result<(), MailboxError> {
    if input.id.trim().is_empty() {
        return Err(MailboxError::MissingId);
    }
    if input.sender.trim().is_empty() {
        return Err(MailboxError::MissingSender);
    }
    if input.recipient.trim().is_empty() {
        return Err(MailboxError::MissingRecipient);
    }
    if input.body.len() > MAX_BODY_BYTES {
        return Err(MailboxError::BodyTooLarge);
    }
    let metadata_bytes = serde_json::to_vec(&input.metadata)
        .map_err(|e| MailboxError::Storage(anyhow::Error::new(e)))?;
    if metadata_bytes.len() > MAX_METADATA_BYTES {
        return Err(MailboxError::MetadataTooLarge);
    }
    Ok(())
}

fn persist(inner: &Inner) -> std::result::Result<(), MailboxError> {
    persist_state(inner.path.as_ref(), &inner.state)
}

fn persist_state(
    path: Option<&PathBuf>,
    state: &PersistedState,
) -> std::result::Result<(), MailboxError> {
    let Some(path) = path else {
        return Ok(());
    };
    let bytes = serde_json::to_vec_pretty(state)
        .map_err(|e| MailboxError::Storage(anyhow::Error::new(e)))?;
    let tmp = path.with_extension("json.tmp");
    write_private(&tmp, &bytes).map_err(|e| MailboxError::Storage(anyhow::Error::new(e)))?;
    std::fs::rename(&tmp, path).map_err(|e| MailboxError::Storage(anyhow::Error::new(e)))?;
    if let Some(parent) = path.parent() {
        #[cfg(unix)]
        std::fs::File::open(parent)
            .and_then(|file| file.sync_all())
            .map_err(|e| MailboxError::Storage(anyhow::Error::new(e)))?;
    }
    Ok(())
}

/// Write a temporary mailbox state owner-only, then let `persist_state`
/// durably rename it into place.
#[cfg(unix)]
fn write_private(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?;
    if file.metadata()?.permissions().mode() & 0o077 != 0 {
        file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
    }
    file.write_all(bytes)?;
    file.sync_all()
}

#[cfg(windows)]
fn write_private(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;

    match std::fs::remove_file(path) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    let mut file = crate::owner_only::create_new(path)?;
    file.write_all(bytes)?;
    file.sync_all()
}

#[cfg(test)]
mod tests {
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
        let task =
            tokio::spawn(async move { waiter.wait("reports:leo", 0, 10, 1_000).await.unwrap() });
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
        let task =
            tokio::spawn(async move { notifier.wait("recipient-b", 0, 1, 50).await.unwrap() });
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
}
