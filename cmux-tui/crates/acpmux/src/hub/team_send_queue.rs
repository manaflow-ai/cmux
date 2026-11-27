//! Durable FIFO admission and replay for team messages. Pending content and the receipt alias
//! are changed in one atomic file replacement; ownership is recorded before an item is retired.

use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use crate::mesh::{MeshHub, OutMessage, Receipt};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct QueuedTeamSend {
    pub(crate) id: String,
    pub(crate) message: OutMessage,
    pub(crate) address: String,
    #[serde(default)]
    pub(crate) caller: Option<String>,
    pub(crate) receipt: Receipt,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CompletedTeamSend {
    id: String,
    idempotency_key: String,
    address: String,
    caller: Option<String>,
    receipt: Receipt,
    completed_at: u64,
}

#[derive(Clone, Default, Serialize, Deserialize)]
struct QueueFile {
    pending: VecDeque<QueuedTeamSend>,
    completed: VecDeque<CompletedTeamSend>,
}

impl QueueFile {
    fn prune_completed(&mut self) {
        let cutoff = crate::store::now_ms().saturating_sub(7 * 24 * 60 * 60 * 1000);
        self.completed.retain(|entry| entry.completed_at >= cutoff);
    }
}

#[derive(Default)]
struct State {
    path: Option<PathBuf>,
    file: QueueFile,
    load_error: Option<String>,
}

#[derive(Clone, Default)]
pub(crate) struct TeamSendQueue {
    state: Arc<Mutex<State>>,
    flushing: Arc<tokio::sync::Mutex<()>>,
    retry: Arc<crate::mesh_gate::Gate>,
}

impl TeamSendQueue {
    /// A malformed or unreadable file is preserved; new sends fail rather than erase it.
    pub(crate) fn open(&self, path: &Path) {
        let loaded = match std::fs::read(path) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(QueueFile::default()),
            Err(e) => Err(e.to_string()),
            Ok(bytes) => serde_json::from_slice::<QueueFile>(&bytes)
                .or_else(|_| {
                    // The initial queue stored only its pending array.
                    serde_json::from_slice::<VecDeque<QueuedTeamSend>>(&bytes)
                        .map(|pending| QueueFile { pending, ..Default::default() })
                })
                .map_err(|e| e.to_string()),
        };
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        state.path = Some(path.to_owned());
        match loaded {
            Ok(file) => {
                state.file = file;
                state.file.prune_completed();
                state.load_error = None;
            }
            Err(error) => {
                state.file = QueueFile::default();
                state.load_error = Some(error);
            }
        }
    }

    /// Clone boot never replays a copied queue, even if setting it aside fails.
    pub(crate) fn open_at_start(&self, path: &Path, cloned: bool) {
        if cloned {
            let aside = path.with_extension("json.clone-boot");
            if let Err(error) = crate::home_fs::rename(path, &aside)
                && error.kind() != std::io::ErrorKind::NotFound
            {
                let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
                state.path = Some(path.to_owned());
                state.load_error = Some(format!("copied queue could not be set aside: {error}"));
                return;
            }
        }
        self.open(path);
    }

    /// All sends, including online ones, enter this durable FIFO before any network attempt.
    pub(crate) async fn enqueue(
        &self,
        message: OutMessage,
        address: String,
        caller: Option<String>,
    ) -> anyhow::Result<Receipt> {
        let queue = self.clone();
        tokio::task::spawn_blocking(move || queue.enqueue_blocking(message, address, caller))
            .await?
    }

    fn enqueue_blocking(
        &self,
        message: OutMessage,
        address: String,
        caller: Option<String>,
    ) -> anyhow::Result<Receipt> {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(error) = &state.load_error {
            anyhow::bail!("team send queue could not be read: {error}");
        }
        state.file.prune_completed();
        if let Some(entry) = state.file.pending.iter().find(|entry| {
            entry.message.idempotency_key == message.idempotency_key
                && entry.caller == caller
                && entry.address == address
        }) {
            return Ok(entry.receipt.clone());
        }
        if let Some(entry) = state.file.completed.iter().find(|entry| {
            entry.idempotency_key == message.idempotency_key
                && entry.caller == caller
                && entry.address == address
        }) {
            return Ok(entry.receipt.clone());
        }
        let id = format!("teamq:{}", uuid::Uuid::now_v7());
        let receipt: Receipt = serde_json::from_value(serde_json::json!({
            "messageId": id, "state": "queued", "to": message.to,
            "createdAt": crate::store::now_ms(), "detail": "queued for the mesh hub"
        }))?;
        state.file.pending.push_back(QueuedTeamSend {
            id,
            message,
            address,
            caller,
            receipt: receipt.clone(),
        });
        if let Err(error) = persist(&state) {
            state.file.pending.pop_back();
            return Err(error);
        }
        Ok(receipt)
    }

    /// Both the original queued id and the eventual hub id resolve to the durable sender.
    pub(crate) async fn lookup(&self, id: &str) -> Option<(Receipt, String, Option<String>)> {
        let (queue, id) = (self.clone(), id.to_owned());
        tokio::task::spawn_blocking(move || queue.lookup_blocking(&id)).await.ok().flatten()
    }

    fn lookup_blocking(&self, id: &str) -> Option<(Receipt, String, Option<String>)> {
        let id = id.strip_prefix("mesh:").unwrap_or(id);
        let state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        state
            .file
            .pending
            .iter()
            .find(|e| e.id == id)
            .map(|e| (e.receipt.clone(), e.address.clone(), e.caller.clone()))
            .or_else(|| {
                state
                    .file
                    .completed
                    .iter()
                    .find(|e| e.id == id || e.receipt.message_id == id)
                    .map(|e| (e.receipt.clone(), e.address.clone(), e.caller.clone()))
            })
    }

    #[cfg(test)]
    pub(crate) fn pending(&self) -> Vec<QueuedTeamSend> {
        self.state.lock().unwrap_or_else(|e| e.into_inner()).file.pending.iter().cloned().collect()
    }

    /// A concurrent flush exits immediately; heartbeats cannot accumulate waiting workers.
    /// The callback persists sender ownership before the pending item is atomically retired.
    /// It runs on the blocking pool along with the queue write.
    pub(crate) async fn flush<F, A, Fut>(&self, mesh: &dyn MeshHub, record: F, enabled: A)
    where
        F: Fn(&QueuedTeamSend, &Receipt) -> bool + Send + Sync + 'static,
        A: Fn() -> Fut,
        Fut: std::future::Future<Output = bool>,
    {
        let Ok(_serial) = self.flushing.try_lock() else { return };
        let record = Arc::new(record);
        loop {
            // Admission may be syncing the durable file; never wait for its state lock on an
            // async worker, including status reads and the next replayed item.
            let queue = self.clone();
            let Ok(item) = tokio::task::spawn_blocking(move || {
                queue.state.lock().unwrap_or_else(|e| e.into_inner()).file.pending.front().cloned()
            })
            .await
            else {
                return;
            };
            let Some(item) = item else { return };
            if !enabled().await || !self.retry.may_try() {
                return;
            }
            let receipt = match mesh.send(&item.message).await {
                Ok(receipt) => receipt,
                Err(error) if error.refused => {
                    let mut receipt = item.receipt.clone();
                    receipt.state = "refused".into();
                    receipt.detail = Some(error.to_string());
                    receipt
                }
                Err(error) => {
                    self.retry.failed(error.retry_after);
                    return;
                }
            };
            self.retry.answered();
            let (queue, record) = (self.clone(), record.clone());
            let settled = tokio::task::spawn_blocking(move || {
                if !record(&item, &receipt) {
                    return Ok(false);
                }
                let mut state = queue.state.lock().unwrap_or_else(|e| e.into_inner());
                if state.file.pending.front().is_none_or(|front| front.id != item.id) {
                    return Ok(true);
                }
                let previous = state.file.clone();
                state.file.pending.pop_front();
                state.file.completed.push_back(CompletedTeamSend {
                    id: item.id,
                    idempotency_key: item.message.idempotency_key,
                    address: item.address,
                    caller: item.caller,
                    receipt,
                    completed_at: crate::store::now_ms(),
                });
                // Same seven-day receipt window as the outbox's team origin records.
                state.file.prune_completed();
                if let Err(error) = persist(&state) {
                    state.file = previous;
                    return Err(error);
                }
                Ok(true)
            })
            .await;
            match settled {
                Ok(Ok(true)) => {}
                other => {
                    tracing::warn!("team send queue could not retire delivery: {other:?}");
                    return;
                }
            }
        }
    }
}

fn persist(state: &State) -> anyhow::Result<()> {
    let Some(path) = state.path.as_deref() else { return Ok(()) };
    crate::config::write_atomic(path, &serde_json::to_vec(&state.file)?).map_err(Into::into)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mesh::{Ack, Heartbeat, HeartbeatReply, HubError, InMessage};
    use futures::future::BoxFuture;
    use std::collections::VecDeque;
    use std::sync::Mutex;
    use std::time::Duration;

    #[derive(Default)]
    struct FakeMesh {
        bodies: Mutex<Vec<String>>,
        outcomes: Mutex<VecDeque<Result<Receipt, HubError>>>,
        pause_first: std::sync::atomic::AtomicBool,
        began: tokio::sync::Notify,
        release: tokio::sync::Notify,
    }

    impl MeshHub for FakeMesh {
        fn inbox(&self, _: Duration, _: usize) -> BoxFuture<'_, Result<Vec<InMessage>, HubError>> {
            Box::pin(async { Ok(Vec::new()) })
        }

        fn ack<'a>(&'a self, _: &'a str, _: &'a Ack) -> BoxFuture<'a, Result<(), HubError>> {
            Box::pin(async { Ok(()) })
        }

        fn heartbeat<'a>(
            &'a self,
            _: &'a Heartbeat,
        ) -> BoxFuture<'a, Result<HeartbeatReply, HubError>> {
            Box::pin(async { Err(HubError::unavailable("unused in queue test")) })
        }

        fn send<'a>(&'a self, message: &'a OutMessage) -> BoxFuture<'a, Result<Receipt, HubError>> {
            self.bodies.lock().unwrap().push(message.body.clone());
            let outcome = self
                .outcomes
                .lock()
                .unwrap()
                .pop_front()
                .unwrap_or_else(|| Ok(receipt("hub-message", "delivered")));
            let pause = self.pause_first.swap(false, std::sync::atomic::Ordering::SeqCst);
            Box::pin(async move {
                if pause {
                    self.began.notify_one();
                    self.release.notified().await;
                }
                outcome
            })
        }

        fn receipt<'a>(&'a self, id: &'a str) -> BoxFuture<'a, Result<Receipt, HubError>> {
            Box::pin(async move { Ok(receipt(id, "delivered")) })
        }
    }

    fn message(body: &str, key: &str) -> OutMessage {
        OutMessage {
            to: crate::mesh::Target {
                team_address: Some("@member/agent".into()),
                ..Default::default()
            },
            from: crate::mesh::Sender::default(),
            kind: crate::mesh::Kind::Prompt,
            op: None,
            body: body.into(),
            mode: crate::mesh::Mode::TurnEnd,
            idempotency_key: key.into(),
        }
    }

    fn receipt(id: &str, state: &str) -> Receipt {
        serde_json::from_value(serde_json::json!({"messageId": id, "state": state})).unwrap()
    }

    #[tokio::test]
    async fn queue_persists_and_flushes_in_fifo_order() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("team-send-queue.json");
        let queue = TeamSendQueue::default();
        queue.open(&path);
        queue.enqueue(message("first", "one"), "@member/agent".into(), None).await.unwrap();
        queue.enqueue(message("second", "two"), "@member/agent".into(), None).await.unwrap();

        let reopened = TeamSendQueue::default();
        reopened.open(&path);
        assert_eq!(
            reopened.pending().iter().map(|item| item.message.body.as_str()).collect::<Vec<_>>(),
            ["first", "second"]
        );

        let mesh = FakeMesh::default();
        reopened.flush(&mesh, |_, _| true, || async { true }).await;
        assert_eq!(mesh.bodies.lock().unwrap().as_slice(), ["first", "second"]);
        assert!(reopened.pending().is_empty());
        let after_restart = TeamSendQueue::default();
        after_restart.open(&path);
        assert!(after_restart.pending().is_empty());
    }

    #[tokio::test(start_paused = true)]
    async fn transient_failure_keeps_head_and_stops_fifo_flush() {
        let queue = TeamSendQueue::default();
        queue.enqueue(message("first", "one"), "@member/agent".into(), None).await.unwrap();
        queue.enqueue(message("second", "two"), "@member/agent".into(), None).await.unwrap();
        let mesh = FakeMesh::default();
        mesh.outcomes.lock().unwrap().push_back(Err(HubError::unavailable("offline")));

        queue.flush(&mesh, |_, _| true, || async { true }).await;
        assert_eq!(
            queue.pending().iter().map(|item| item.message.body.as_str()).collect::<Vec<_>>(),
            ["first", "second"]
        );
        for _ in 0..20 {
            queue.flush(&mesh, |_, _| true, || async { true }).await;
        }
        assert_eq!(mesh.bodies.lock().unwrap().len(), 1, "offline bursts share one probe");
        tokio::time::advance(crate::mesh_gate::FIRST_WINDOW).await;
        queue.flush(&mesh, |_, _| true, || async { true }).await;
        assert_eq!(mesh.bodies.lock().unwrap().as_slice(), ["first", "first", "second"]);
        assert!(queue.pending().is_empty());
    }

    #[tokio::test]
    async fn refused_message_is_settled_and_removed() {
        let queue = TeamSendQueue::default();
        queue.enqueue(message("bad", "one"), "@member/agent".into(), None).await.unwrap();
        let mesh = FakeMesh::default();
        mesh.outcomes.lock().unwrap().push_back(Err(HubError::refused("unknown recipient")));

        queue
            .flush(
                &mesh,
                |_, receipt| {
                    assert_eq!(receipt.state, "refused");
                    true
                },
                || async { true },
            )
            .await;
        assert!(queue.pending().is_empty());
    }

    #[tokio::test]
    async fn reconnect_serializes_new_admission_and_overlapping_flushes() {
        let queue = TeamSendQueue::default();
        queue.enqueue(message("first", "one"), "@member/agent".into(), None).await.unwrap();
        let mesh = Arc::new(FakeMesh::default());
        mesh.pause_first.store(true, std::sync::atomic::Ordering::SeqCst);
        let (q, m) = (queue.clone(), mesh.clone());
        let task =
            tokio::spawn(async move { q.flush(m.as_ref(), |_, _| true, || async { true }).await });
        tokio::time::timeout(Duration::from_secs(5), mesh.began.notified()).await.unwrap();
        queue.enqueue(message("second", "two"), "@member/agent".into(), None).await.unwrap();
        tokio::time::timeout(
            Duration::from_secs(1),
            queue.flush(mesh.as_ref(), |_, _| true, || async { true }),
        )
        .await
        .unwrap();
        assert_eq!(mesh.bodies.lock().unwrap().as_slice(), ["first"]);
        mesh.release.notify_one();
        tokio::time::timeout(Duration::from_secs(5), task).await.unwrap().unwrap();
        assert_eq!(mesh.bodies.lock().unwrap().as_slice(), ["first", "second"]);
        assert!(queue.pending().is_empty());
    }

    #[tokio::test]
    async fn ownership_and_atomic_write_failures_leave_head_replayable() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("queue.json");
        let queue = TeamSendQueue::default();
        queue.open(&path);
        let id = queue
            .enqueue(message("first", "one"), "@member/agent".into(), Some("sender".into()))
            .await
            .unwrap()
            .message_id;
        let mesh = FakeMesh::default();
        queue.flush(&mesh, |_, _| false, || async { true }).await;
        assert_eq!(queue.pending().len(), 1);
        queue.state.lock().unwrap().path = Some(dir.path().join("missing").join("queue.json"));
        // A path occupied by a directory makes replacement fail even as root.
        let bad_path = dir.path().join("directory");
        std::fs::create_dir(&bad_path).unwrap();
        queue.state.lock().unwrap().path = Some(bad_path);
        queue.flush(&mesh, |_, _| true, || async { true }).await;
        assert_eq!(queue.pending().len(), 1);
        assert_eq!(queue.lookup(&id).await.unwrap().0.state, "queued");
        let restarted = TeamSendQueue::default();
        restarted.open(&path);
        assert_eq!(restarted.pending().len(), 1);
        restarted.flush(&mesh, |_, _| true, || async { true }).await;
        let delivered = TeamSendQueue::default();
        delivered.open(&path);
        assert!(delivered.pending().is_empty());
        let (receipt, _, caller) = delivered.lookup(&id).await.unwrap();
        assert_eq!(receipt.message_id, "hub-message");
        assert_eq!(caller.as_deref(), Some("sender"));
    }

    #[tokio::test]
    async fn corrupt_and_copied_queues_never_overwrite_or_replay_source_messages() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("queue.json");
        std::fs::write(&path, b"not json").unwrap();
        let queue = TeamSendQueue::default();
        queue.open(&path);
        assert!(queue.enqueue(message("new", "one"), "@member/agent".into(), None).await.is_err());
        assert_eq!(std::fs::read(&path).unwrap(), b"not json");
        let source = dir.path().join("source.json");
        let queue = TeamSendQueue::default();
        queue.open(&source);
        queue.enqueue(message("source", "two"), "@member/agent".into(), None).await.unwrap();
        let copied = TeamSendQueue::default();
        copied.open_at_start(&source, true);
        assert!(copied.pending().is_empty());
        assert!(source.with_extension("json.clone-boot").is_file());
        // A failed rename also keeps the copied message out of replay, and refuses new sends.
        let failed_path = dir.path().join("failed.json");
        std::fs::copy(source.with_extension("json.clone-boot"), &failed_path).unwrap();
        std::fs::create_dir(failed_path.with_extension("json.clone-boot")).unwrap();
        let failed = TeamSendQueue::default();
        failed.open_at_start(&failed_path, true);
        assert!(failed.pending().is_empty());
        assert!(
            failed.enqueue(message("new", "three"), "@member/agent".into(), None).await.is_err()
        );
    }
}
