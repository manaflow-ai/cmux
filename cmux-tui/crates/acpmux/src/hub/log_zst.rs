//! Part of `Hub`; see `hub/mod.rs`. Closed chats' logs compressed on their own
//! (`store/log_zst.rs`).
//!
//! A chat that closes for good (its status goes to closed: a person's close, an end; never a
//! daemon restart or a handover, which leave the status as it was) is queued, and so is every
//! closed chat at the daemon's start, oldest first: that pass finds the ones a crash or an older
//! build left plain, and costs one listing for a log already compressed. A retention rewrite
//! puts plain segments back, so a chat it rewrote is queued again (`retention.rs`).
//!
//! One worker (`log_zst_worker`) takes one chat at a time and compresses its segments on a
//! thread of its own at the lowest CPU and IO priority (`store::log_zst::in_background`). It
//! leaves a chat that is in use (`log_zst_ready`): not closed, an agent, a turn, a queue, a
//! move, an import, a cold archive, or its log not read yet. A pass stops between two segments
//! once the chat is used again or the daemon shuts down, and the store refuses the rename of a
//! segment a writer holds, so a reopened chat's appends always go to a plain segment
//! (`LocalStore::open_writer` starts the next one after a compressed last segment). The worker
//! ends with the hub's scope (its stop condition): it is cancelled at the shutdown, and a pass
//! under way stops at its next segment.
//!
//! `store.compressClosedLogs: false` in the config file turns it off.

use super::*;

/// How long after a close a chat's log waits before its pass: the records that follow a close
/// (the agent's `stopped`, a title) land first, in the segment they would have gone in.
const SETTLE: std::time::Duration = std::time::Duration::from_secs(60);

/// [`SETTLE`], or none in tests.
fn settle() -> std::time::Duration {
    if cfg!(test) { std::time::Duration::ZERO } else { SETTLE }
}

/// The chats waiting for a compression pass, in order, each once, with when each may go.
#[derive(Default)]
pub(crate) struct LogZst {
    queue: StdMutex<std::collections::VecDeque<(String, std::time::Instant)>>,
    wake: Arc<Notify>,
}

impl LogZst {
    fn push(&self, id: &str, at: std::time::Instant) {
        let mut queue = self.queue.lock().unwrap_or_else(|e| e.into_inner());
        match queue.iter_mut().find(|(queued, _)| queued == id) {
            Some(queued) => queued.1 = queued.1.max(at),
            None => queue.push_back((id.to_owned(), at)),
        }
        drop(queue);
        self.wake.notify_one();
    }

    fn pop(&self) -> Option<(String, std::time::Instant)> {
        self.queue.lock().unwrap_or_else(|e| e.into_inner()).pop_front()
    }
}

impl Hub {
    /// Queues chat `id` for a compression pass, [`SETTLE`] from now. Only queues; no lock but
    /// the queue's is taken.
    pub(super) fn log_zst_enqueue(&self, id: &str) {
        self.log_zst.push(id, std::time::Instant::now() + settle());
    }

    /// The daemon's one log compression worker ([module docs](self)), started once every chat's
    /// log is read (`daemon.rs`): every closed chat is queued first, oldest first. None when the
    /// config turns it off.
    pub fn log_zst_worker(self: &Arc<Self>) -> Option<tokio::task::JoinHandle<Option<()>>> {
        let on = self.config.try_read().map_or(true, |c| c.store.compress_closed_logs());
        if !on {
            return None;
        }
        let mut closed: Vec<_> =
            self.sessions().into_iter().filter(|s| s.status() == SessionStatus::Closed).collect();
        closed.sort_by_cached_key(|s| s.meta().updated_at);
        let now = std::time::Instant::now();
        for session in &closed {
            self.log_zst.push(&session.id, now);
        }
        let hub = Arc::downgrade(self);
        let wake = self.log_zst.wake.clone();
        Some(self.scope.spawn_until_cancelled("log-zst-worker", async move {
            loop {
                let next = {
                    let Some(hub) = hub.upgrade() else { return };
                    if hub.shutting_down() {
                        return;
                    }
                    hub.log_zst.pop()
                };
                let Some((id, at)) = next else {
                    wake.notified().await;
                    continue;
                };
                tokio::time::sleep_until(at.into()).await;
                let Some(hub) = hub.upgrade() else { return };
                if hub.shutting_down() {
                    return;
                }
                if let Err(e) =
                    tokio::task::spawn_blocking(move || hub.compress_closed_log(&id)).await
                {
                    tracing::warn!("log compression: {e}");
                }
            }
        }))
    }

    /// One pass over chat `id`'s log, when it is closed and unused; waits for it.
    pub(super) fn compress_closed_log(self: &Arc<Self>, id: &str) {
        let Some(session) = self.session_by_id(id) else { return };
        if !self.log_zst_ready(&session) {
            return;
        }
        let started = std::time::Instant::now();
        let hub = self.clone();
        let chat = id.to_owned();
        let pass = crate::store::log_zst::in_background(move || {
            let stop = || hub.shutting_down() || !hub.log_zst_ready(&session);
            hub.store.compress_log(&chat, &stop)
        });
        match pass {
            Ok(Ok(done)) if done.segments > 0 => tracing::info!(
                session = %id,
                "log compression: {} segments, {} bytes to {} in {} ms{}",
                done.segments,
                done.bytes_before,
                done.bytes_after,
                started.elapsed().as_millis(),
                if done.stopped { ", stopped" } else { "" }
            ),
            Ok(Ok(_)) => {}
            Ok(Err(e)) => tracing::warn!(session = %id, "log compression: {e:#}"),
            Err(e) => tracing::warn!(session = %id, "log compression: {e}"),
        }
    }

    /// Whether `session`'s log may be compressed now ([module docs](self)). Only locks that are
    /// never held across an append are taken, and `child` is only tried.
    pub(super) fn log_zst_ready(&self, session: &Session) -> bool {
        let meta = session.meta();
        meta.status == SessionStatus::Closed
            && meta.cold.is_none()
            && meta.watching.is_none()
            && session.status_writes.load(Ordering::SeqCst) == 0
            && session.child.try_lock().is_ok_and(|child| child.is_none())
            && self.session_log_loaded(session)
            && !session.purged.load(Ordering::SeqCst)
            && !session.replaced.load(Ordering::SeqCst)
            && !session.loading.load(Ordering::SeqCst)
            && session.turn().is_none()
            && session.queued() == 0
            && session.moving().is_none()
            && !self.importing.lock().unwrap_or_else(|e| e.into_inner()).contains(&session.id)
    }
}

#[cfg(test)]
#[path = "log_zst_tests.rs"]
mod tests;
