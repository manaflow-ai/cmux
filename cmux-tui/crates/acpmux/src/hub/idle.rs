//! Part of `Hub`; see `hub/mod.rs`. A session harness nobody uses exits.
//!
//! Every new session used to keep its adapter alive until the daemon
//! stopped: after about 25 sessions, 36 adapters, 187 processes and 9.4 GB,
//! with switches slowing as they piled up. A session is idle when no client
//! is attached, no turn runs or waits, no permission is pending, no start
//! holds its spawn lock, and nothing was logged for `idle_child`. Its
//! harness is then stopped through `detach_child`: the record and the
//! agent session id stay, so the next prompt resumes it (`session/load`).
//!
//! One task per hub waits on the injected clock for the earliest deadline
//! and on a wake signal for a new child; it never polls, so idle costs no
//! CPU. Activity only moves deadlines later, so the task wakes at most once
//! per idle period per live child.

use super::*;

impl Hub {
    /// The hub clock's time, as stored in `Session::last_active`.
    pub(super) fn clock_now(&self) -> u64 {
        self.clock.lock().unwrap().now().as_nanos() as u64
    }

    /// Something happened in `session`: its idle period starts again.
    pub(super) fn touch(&self, session: &Session) {
        session.last_active.store(self.clock_now(), Ordering::Relaxed);
    }

    /// Unused right now. A turn or permission an adopted host's recovery
    /// rebuilt (`hosts.rs` `recover_work`) counts like a live one: it sets
    /// `session.turn` (and holds `turn_lock` until the answer), registers
    /// the permission as pending, and moves the status off ready.
    fn idle_eligible(&self, session: &Session) -> bool {
        !self.stopping.load(Ordering::SeqCst)
            && session.attached.load(Ordering::SeqCst) == 0
            && matches!(session.status(), SessionStatus::Ready | SessionStatus::Idle)
            && session.turn().is_none()
            && session.turn_lock.try_lock().is_ok()
            && session.queued() == 0
            && session.pending_permissions().is_empty()
            && session.spawn_lock.try_lock().is_ok()
    }

    /// The daemon is stopping (`_acpmux/shutdown`, SIGTERM, then
    /// `shutdown_all`): the idle reaper never stops a harness again.
    pub fn stop_idle_reaper(&self) {
        self.stopping.store(true, Ordering::SeqCst);
    }

    /// A child was published: make sure the reaper runs and sees it.
    pub(super) fn wake_idle_reaper(self: &Arc<Self>) {
        if !self.idle_reaper.swap(true, Ordering::SeqCst) {
            let weak = Arc::downgrade(self);
            let wake = self.idle_wake.clone();
            tokio::spawn(async move { Self::idle_reaper_loop(weak, wake).await });
        }
        self.idle_wake.notify_one();
    }

    async fn idle_reaper_loop(weak: std::sync::Weak<Self>, wake: Arc<Notify>) {
        loop {
            let (next, clock) = {
                let Some(hub) = weak.upgrade() else { return };
                let clock = hub.clock.lock().unwrap().clone();
                (hub.next_idle_deadline(), clock)
            };
            match next {
                Some(at) => {
                    tokio::select! {
                        _ = clock.sleep_until(at) => {}
                        _ = wake.notified() => {}
                    }
                }
                None => wake.notified().await,
            }
            let Some(hub) = weak.upgrade() else { return };
            hub.stop_idle_children().await;
        }
    }

    /// When the first live child's idle period ends, on the hub clock.
    fn next_idle_deadline(&self) -> Option<std::time::Duration> {
        let idle = (*self.idle_child.lock().unwrap())?;
        self.sessions()
            .iter()
            .filter(|s| s.child.try_lock().map(|c| c.is_some()).unwrap_or(true))
            .map(|s| std::time::Duration::from_nanos(s.last_active.load(Ordering::Relaxed)) + idle)
            .min()
    }

    async fn stop_idle_children(&self) {
        // Shutdown owns every child from its first step: hosted ones are
        // handed off or ended there, never terminated here meanwhile.
        let _pass = self.idle_pass.lock().await;
        if self.stopping.load(Ordering::SeqCst) {
            return;
        }
        let Some(idle) = *self.idle_child.lock().unwrap() else { return };
        let now = self.clock_now();
        let idle = idle.as_nanos() as u64;
        for session in self.sessions() {
            if session.last_active.load(Ordering::Relaxed).saturating_add(idle) > now {
                continue;
            }
            let has_child = session.child.try_lock().map(|c| c.is_some()).unwrap_or(true);
            if !has_child {
                continue;
            }
            if self.idle_eligible(&session) {
                tracing::info!(session = %session.id, "idle harness exits; the session resumes on its next prompt");
                self.detach_child(&session).await;
            } else {
                // In use at its deadline: a full idle period starts now.
                self.touch(&session);
            }
        }
    }
}
