//! One current-view check and lifetime register for every paired stream.

use cmux_link::pairing::Pairings;
use cmux_link::stamp::LinkPeer;
use std::future::Future;
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt};

/// What an open paired stream watches: every new
/// pairing view, and the register of open paired streams that a reload
/// waits on before it removes a revoked WireGuard peer.
#[derive(Clone)]
pub(super) struct Revocations {
    pub(super) view: tokio::sync::watch::Receiver<std::sync::Arc<Pairings>>,
    pub(super) open: std::sync::Arc<OpenStreams>,
}

/// Open paired streams per WireGuard key.
#[derive(Default)]
pub(super) struct OpenStreams {
    keys: std::sync::Mutex<std::collections::HashMap<[u8; 32], usize>>,
    closed: tokio::sync::Notify,
}

impl OpenStreams {
    pub(super) fn enter(self: &std::sync::Arc<Self>, key: [u8; 32]) -> OpenStream {
        *self
            .keys
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .entry(key)
            .or_default() += 1;
        OpenStream { register: self.clone(), key }
    }

    fn any_open(&self, keys: &[[u8; 32]]) -> bool {
        let open = self.keys.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        keys.iter().any(|key| open.get(key).is_some_and(|count| *count > 0))
    }

    /// Returns once no paired stream of `keys` is open (event-driven: each
    /// stream's end wakes this).
    pub(super) async fn closed(&self, keys: &[[u8; 32]]) {
        loop {
            let notified = self.closed.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            if !self.any_open(keys) {
                return;
            }
            notified.await;
        }
    }
}

/// One open paired stream in [`OpenStreams`]; leaves it on drop.
pub(super) struct OpenStream {
    register: std::sync::Arc<OpenStreams>,
    key: [u8; 32],
}

impl Drop for OpenStream {
    fn drop(&mut self) {
        let mut open = self.register.keys.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(count) = open.get_mut(&self.key) {
            *count = count.saturating_sub(1);
            if *count == 0 {
                open.remove(&self.key);
            }
        }
        drop(open);
        self.register.closed.notify_waiters();
    }
}

/// Check the current view before polling work and after every update. A
/// subscription created after revocation has no changed() event to consume.
pub(super) async fn while_paired<F: Future>(
    revocations: Option<&mut Revocations>,
    key: [u8; 32],
    peer: &LinkPeer,
    work: F,
) -> Result<F::Output, ()> {
    let Some(revocations) = revocations else { return Ok(work.await) };
    let revoked = async {
        loop {
            let current = revocations
                .view
                .borrow_and_update()
                .by_key(&key)
                .is_some_and(|record| record.peer() == *peer);
            if !current || revocations.view.changed().await.is_err() {
                return;
            }
        }
    };
    tokio::select! {
        biased;
        () = revoked => Err(()),
        result = work => Ok(result),
    }
}

/// Send the close while reload still retains the WireGuard peer. Drain only
/// to acknowledge the far side's close; revoked bytes never reach a caller.
pub(super) async fn close_revoked<S: AsyncRead + AsyncWrite + Unpin>(stream: &mut S) {
    let _ = stream.shutdown().await;
    let _ = tokio::time::timeout(std::time::Duration::from_secs(2), async {
        let mut sink = [0u8; 1024];
        while matches!(tokio::io::AsyncReadExt::read(&mut *stream, &mut sink).await, Ok(n) if n > 0)
        {
        }
    })
    .await;
}
