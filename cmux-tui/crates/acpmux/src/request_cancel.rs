//! A client's `$/cancel_request` (JSON-RPC / LSP / ACP `CancelRequestNotification`), as the work
//! it cancelled sees it.
//!
//! The connection that took the request (`server/in_flight.rs`) answers it with
//! [`cancelled_error`] at once, frees its slot, and drops the future that serves it inside
//! [`until_cancelled`]'s scope. What that future was waiting on reads [`requested`] while it is
//! dropped and tells its own backend: an agent's request (`agent.rs`) and a peer's forwarded one
//! (`peer.rs`) send `$/cancel_request` on, forget their pending entry, and keep the id, so the
//! answer that still comes is dropped on purpose and logged under [`LOG_TARGET`] instead of
//! being lost or handed to a waiter that is gone.
//!
//! A future dropped for any other reason (a turn handed to the next daemon, a timeout) sees no
//! request here and keeps what it did before.

use crate::rpc::RpcError;
use serde_json::{Value, json};
use std::future::Future;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use tokio::sync::oneshot;

/// JSON-RPC's RequestCancelled (LSP): the answer to a request its client cancelled.
pub const REQUEST_CANCELLED: i64 = -32800;

/// The `initialize` feature of a daemon that honors `$/cancel_request`: the request is answered
/// with [`REQUEST_CANCELLED`] and the cancel goes on to the agent or peer. A peer link sends the
/// cancel on only to a peer that lists it (an older one ignores it anyway). The old
/// `cancelRequest` feature only said the notification is accepted.
pub const FEATURE: &str = "cancelRequestV2";

/// The tracing target of the cancel path's lines (the dropped late answers).
pub const LOG_TARGET: &str = "acpmux::cancel";

/// How many cancelled ids an agent or peer keeps to recognize a late answer by.
pub const REMEMBERED: usize = 1024;

tokio::task_local! {
    static CANCELLED: Arc<AtomicBool>;
}

/// The error a cancelled request is answered with.
pub fn cancelled_error() -> RpcError {
    RpcError::new(REQUEST_CANCELLED, "request cancelled")
        .with_data(json!({"reason": "request.cancelled"}))
}

/// The request id a `$/cancel_request` names: ACP's `requestId`, or LSP's `id`.
pub fn named_id(params: &Value) -> Option<&Value> {
    params.get("requestId").or_else(|| params.get("id")).filter(|v| v.is_string() || v.is_number())
}

/// Whether the request this task serves was cancelled by its client. True only while the
/// future [`until_cancelled`] ran is dropped after a cancel.
pub fn requested() -> bool {
    CANCELLED.try_with(|c| c.load(Ordering::SeqCst)).unwrap_or(false)
}

/// `fut`, unless `cancel` fires first: then None, and `fut` is dropped with [`requested`] true.
/// A `cancel` whose sender is dropped never fires.
pub async fn until_cancelled<F: Future>(
    cancel: oneshot::Receiver<()>,
    fut: F,
) -> Option<F::Output> {
    let flag = Arc::new(AtomicBool::new(false));
    let scoped = CANCELLED.scope(flag.clone(), fut);
    tokio::pin!(scoped);
    let out = tokio::select! {
        biased;
        out = &mut scoped => Some(out),
        Ok(()) = cancel => None,
    };
    if out.is_none() {
        flag.store(true, Ordering::SeqCst);
    }
    // `scoped` is dropped as this returns, inside its scope (tokio's `TaskLocalFuture` drops its
    // future with the value set), so what it waited on reads `requested`.
    out
}

/// Ids of cancelled requests, oldest first, with the method each was: what a late answer is
/// recognized by. Bounded at [`REMEMBERED`].
#[derive(Default)]
pub struct Cancelled {
    ids: std::collections::VecDeque<(String, String)>,
    /// Late answers dropped so far.
    pub dropped: u64,
}

impl Cancelled {
    pub fn remember(&mut self, key: String, method: String) {
        if self.ids.len() >= REMEMBERED {
            self.ids.pop_front();
        }
        self.ids.push_back((key, method));
    }

    /// An answer for `key` came with nobody waiting: true when it was a cancelled request's,
    /// which is then dropped and logged (once).
    pub fn take_late(&mut self, key: &str, from: &str) -> bool {
        let Some(at) = self.ids.iter().position(|(k, _)| k == key) else { return false };
        let (_, method) = self.ids.remove(at).unwrap_or_default();
        self.dropped += 1;
        tracing::debug!(
            target: LOG_TARGET,
            id = %key,
            method = %method,
            from,
            "dropped the late answer to a cancelled request"
        );
        true
    }

    pub fn len(&self) -> usize {
        self.ids.len()
    }

    pub fn is_empty(&self) -> bool {
        self.ids.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn a_cancelled_future_is_dropped_inside_its_scope() {
        struct Probe(Arc<AtomicBool>);
        impl Drop for Probe {
            fn drop(&mut self) {
                self.0.store(requested(), Ordering::SeqCst);
            }
        }
        let seen = Arc::new(AtomicBool::new(false));
        let probe = Probe(seen.clone());
        let (tx, rx) = oneshot::channel();
        let fut = async move {
            let _probe = probe;
            std::future::pending::<()>().await
        };
        tx.send(()).unwrap();
        assert!(until_cancelled(rx, fut).await.is_none());
        assert!(seen.load(Ordering::SeqCst), "the drop saw the cancel");
        assert!(!requested(), "outside the scope no cancel is seen");
    }

    #[tokio::test]
    async fn a_finished_future_and_a_dropped_sender_are_no_cancel() {
        let (tx, rx) = oneshot::channel::<()>();
        drop(tx);
        assert_eq!(until_cancelled(rx, async { 7 }).await, Some(7));
    }

    #[test]
    fn a_late_answer_is_dropped_once_and_only_for_a_cancelled_id() {
        let mut c = Cancelled::default();
        c.remember("3".into(), "session/set_mode".into());
        assert!(!c.take_late("4", "agent"));
        assert!(c.take_late("3", "agent"));
        assert!(!c.take_late("3", "agent"));
        assert_eq!(c.dropped, 1);
        assert!(c.is_empty());
    }

    /// What this process's log lines say while `f` runs, at `acpmux::cancel=debug`.
    fn logged(f: impl FnOnce()) -> String {
        #[derive(Clone, Default)]
        struct Lines(Arc<std::sync::Mutex<Vec<u8>>>);
        impl std::io::Write for Lines {
            fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
                self.0.lock().unwrap().extend_from_slice(buf);
                Ok(buf.len())
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }
        let lines = Lines::default();
        let writer = lines.clone();
        let subscriber = tracing_subscriber::fmt()
            .with_env_filter(tracing_subscriber::EnvFilter::new("acpmux::cancel=debug"))
            .with_ansi(false)
            .with_writer(move || writer.clone())
            .finish();
        tracing::subscriber::with_default(subscriber, f);
        String::from_utf8_lossy(&lines.0.lock().unwrap()).into_owned()
    }

    /// Review F2 of #41285: past the bound, the oldest cancelled id goes with a log line naming
    /// it, and its late answer is logged as an unknown id, never dropped in silence.
    #[test]
    fn a_late_answer_past_the_cap_is_logged_never_silent() {
        let log = logged(|| {
            let mut c = Cancelled::default();
            for n in 0..=REMEMBERED {
                c.remember(n.to_string(), "session/set_mode".into());
            }
            assert!(!c.take_late("0", "peer"), "its id went past the bound");
            assert!(c.take_late("1", "peer"), "a newer one is still known");
        });
        let lines: Vec<&str> = log.lines().collect();
        assert!(
            lines.iter().any(|l| l.contains("evicted") && l.contains("id=0 ")),
            "the eviction names the id: {log}"
        );
        assert!(
            lines
                .iter()
                .any(|l| l.contains("unknown id, possibly evicted cancel") && l.contains("id=0 ")),
            "its late answer is logged: {log}"
        );
    }
}
