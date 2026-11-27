//! Updates fence new waiting sends before shutdown, and defer if accepted sends cannot finish.
//! Durable inbox submissions remain admissible while the next daemon is being prepared.
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::sync::Notify;

use crate::no_panic::LockExt;
use crate::rpc::RpcError;

// timeout: an unfinished turn defers the update; it never authorizes cutting that turn.
pub(crate) const WITHIN: Duration = Duration::from_secs(30);

#[derive(Default)]
struct State {
    active: usize,
    drainers: usize,
    committed: bool,
}

#[derive(Default)]
pub(crate) struct Admission {
    state: Mutex<State>,
    changed: Notify,
}

pub(crate) struct SendPermit(Arc<Admission>);

impl Drop for SendPermit {
    fn drop(&mut self) {
        self.0.state.lock_or_recover().active -= 1;
        self.0.changed.notify_waiters();
    }
}

pub(crate) struct Drain(Arc<Admission>);

impl Drain {
    pub(crate) fn commit(self) {
        self.0.state.lock_or_recover().committed = true;
    }
}

impl Drop for Drain {
    fn drop(&mut self) {
        self.0.state.lock_or_recover().drainers -= 1;
        self.0.changed.notify_waiters();
    }
}

impl Admission {
    pub(crate) fn admit(self: &Arc<Self>) -> Result<SendPermit, RpcError> {
        let mut state = self.state.lock_or_recover();
        if state.drainers > 0 || state.committed {
            return Err(super::shutdown_drain::restarting_error());
        }
        state.active += 1;
        Ok(SendPermit(self.clone()))
    }

    async fn drain(self: &Arc<Self>, within: Duration) -> Result<Drain, RpcError> {
        self.state.lock_or_recover().drainers += 1;
        let guard = Drain(self.clone());
        let ready = async {
            loop {
                let changed = self.changed.notified();
                tokio::pin!(changed);
                changed.as_mut().enable();
                if self.state.lock_or_recover().active == 0 {
                    return;
                }
                changed.await;
            }
        };
        if tokio::time::timeout(within, ready).await.is_err() {
            return Err(deferred());
        }
        Ok(guard)
    }
}

pub(crate) fn deferred() -> RpcError {
    RpcError::new(
        -32000,
        "daemon update deferred: accepted sends are still finishing; the daemon is still serving",
    )
    .with_data(serde_json::json!({"reason": "update.deferred", "retryable": true}))
}

/// Before handing listeners away or asking a supervisor to stop. The guard reopens admission
/// on every failure/cancellation; commit it only once shutdown has actually been requested.
pub(crate) async fn prepare(hub: &crate::hub::Hub) -> Result<Drain, RpcError> {
    let until = tokio::time::Instant::now() + WITHIN;
    let guard = hub.update_admission.drain(WITHIN).await?;
    if !super::shutdown_drain::flush_before_update(hub, until).await {
        return Err(deferred());
    }
    Ok(guard)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test(start_paused = true)]
    async fn update_drain_defers_without_losing_accepted_sends() {
        let gate = Arc::new(Admission::default());
        let accepted: Vec<_> = (0..20).map(|_| gate.admit().unwrap()).collect();
        for _ in 0..5 {
            let drain = gate.drain(Duration::from_secs(1));
            tokio::pin!(drain);
            tokio::select! {
                biased;
                _ = &mut drain => panic!("active sends must defer the update"),
                () = tokio::task::yield_now() => {}
            }
            assert!(gate.admit().is_err());
            assert!(drain.await.is_err());
            assert_eq!(gate.state.lock_or_recover().active, 20);
            assert!(gate.admit().is_ok(), "a deferred update reopens admission");
        }
        drop(accepted);
        gate.drain(Duration::from_secs(1)).await.unwrap().commit();
        assert!(gate.admit().is_err());
    }

    #[tokio::test]
    async fn update_drain_finishes_only_after_last_send_and_reopens_on_cancel() {
        let gate = Arc::new(Admission::default());
        let send = gate.admit().unwrap();
        let drain = gate.drain(Duration::from_secs(1));
        tokio::pin!(drain);
        tokio::select! {
            biased;
            _ = &mut drain => panic!("send still owns its response"),
            () = tokio::task::yield_now() => {}
        }
        assert!(gate.admit().is_err());
        drop(send);
        let guard = drain.await.unwrap();
        assert!(gate.admit().is_err());
        drop(guard);
        assert!(gate.admit().is_ok());
    }
}
