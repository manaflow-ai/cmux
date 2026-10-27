//! Daemon status (host chips, the web URL), read again on the events that can change it:
//! `_acpmux/status_changed`, focus, a peer's session change, a lagged stream, a reconnect.
//! No poll. Asks made while a read is in flight fold into one more read (`Notify` keeps
//! one permit).

use super::AppMsg;
use serde_json::Value;
use std::future::Future;
use std::sync::Arc;
use tokio::sync::{Notify, mpsc, watch};

/// `C` is the daemon connection the reads go to (`Arc<Client>`; a tag in tests).
pub(super) struct StatusReads<C> {
    wanted: Arc<Notify>,
    client: watch::Sender<C>,
}

impl<C: Clone + Send + Sync + 'static> StatusReads<C> {
    /// Starts the reader: each ask runs `read` on the current connection and sends a
    /// successful answer as `AppMsg::Status`.
    pub(super) fn start<R, F>(client: C, read: R, tx: mpsc::UnboundedSender<AppMsg>) -> Self
    where
        R: Fn(C) -> F + Send + 'static,
        F: Future<Output = Option<Value>> + Send,
    {
        let wanted = Arc::new(Notify::new());
        let (client, mut current) = watch::channel(client);
        let asked = wanted.clone();
        // task-owner: the TUI; it ends when the TUI drops its sender or its messages.
        tokio::spawn(async move {
            loop {
                tokio::select! {
                    () = asked.notified() => {}
                    changed = current.changed() => {
                        if changed.is_err() { return; }
                        continue;
                    }
                }
                let c = current.borrow_and_update().clone();
                if let Some(v) = read(c).await
                    && tx.send(AppMsg::Status(v)).is_err()
                {
                    return;
                }
            }
        });
        Self { wanted, client }
    }

    /// Asks for one more read; asks made before it starts are one read.
    pub(super) fn read_again(&self) {
        self.wanted.notify_one();
    }

    /// The connection later reads go to (after a reconnect).
    pub(super) fn use_client(&self, client: C) {
        self.client.send_replace(client);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::time::Duration;
    use tokio::sync::Semaphore;
    use tokio::time::timeout;

    /// Reads that report their start (the connection tag) and wait for a release.
    fn held_reads() -> (
        StatusReads<u32>,
        mpsc::UnboundedReceiver<u32>,
        Arc<Semaphore>,
        mpsc::UnboundedReceiver<AppMsg>,
    ) {
        let (started_tx, started) = mpsc::unbounded_channel();
        let release = Arc::new(Semaphore::new(0));
        let held = release.clone();
        let (tx, msgs) = mpsc::unbounded_channel();
        let read = move |c: u32| {
            let (started_tx, held) = (started_tx.clone(), held.clone());
            async move {
                started_tx.send(c).ok()?;
                held.acquire().await.ok()?.forget();
                Some(json!({ "client": c }))
            }
        };
        (StatusReads::start(1, read, tx), started, release, msgs)
    }

    async fn no_read(started: &mut mpsc::UnboundedReceiver<u32>) -> bool {
        timeout(Duration::from_secs(10), started.recv()).await.is_err()
    }

    #[tokio::test(start_paused = true)]
    async fn asks_during_a_read_fold_into_exactly_one_more_read() {
        let (reads, mut started, release, mut msgs) = held_reads();
        assert!(no_read(&mut started).await, "a read with no ask");
        reads.read_again();
        assert_eq!(started.recv().await, Some(1));
        // Three asks while the first read is in flight.
        reads.read_again();
        reads.read_again();
        reads.read_again();
        release.add_permits(1);
        assert_eq!(started.recv().await, Some(1), "the asks during the read got no read");
        release.add_permits(1);
        assert!(no_read(&mut started).await, "the asks during one read were more than one read");
        let mut answers = 0;
        while let Ok(msg) = msgs.try_recv() {
            answers += usize::from(matches!(msg, AppMsg::Status(_)));
        }
        assert_eq!(answers, 2);
    }

    #[tokio::test(start_paused = true)]
    async fn a_new_connection_reads_nothing_until_asked_then_takes_the_next_read() {
        let (reads, mut started, release, _msgs) = held_reads();
        reads.use_client(2);
        assert!(no_read(&mut started).await, "a new connection read with no ask");
        reads.read_again();
        assert_eq!(started.recv().await, Some(2));
        release.add_permits(1);
    }
}
