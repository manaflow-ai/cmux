//! Renewal before a grant expires (with a backoff after a failure), the catch-up of a machine
//! taken back after a relaunch, and the ends of a holder: shutdown (erase) and detach (a quit or
//! an update, which leaves delivered access in place).

use std::collections::HashSet;
use std::future::Future;
use std::sync::Arc;
use std::time::Duration;

use crate::broker::{Broker, RENEWAL_RETRY_CAP};
use crate::broker_files::grant_in;
use crate::cx::{Cx, Ended, Job};
use crate::error::{BrokerError, Error};
use crate::local_access::MINIMUM_LIFETIME;
use crate::target::TargetRef;
use crate::types::{Grant, now, wait as timer};

/// The wait for one quit erase; the erase itself goes on.
const QUIT_BUDGET: Duration = Duration::from_secs(3);

/// Whether a failed renewal tries again later: the local holder or a delivery failed, including
/// the holder's `codex_auth_unavailable` (not authenticated), which is also what an offline
/// refresh answers. Never an account or team change, or a cancel.
pub fn retries_later(error: &Error) -> bool {
    matches!(
        error,
        Error::Broker(
            BrokerError::BrokerUnavailable
                | BrokerError::RemoteDeliveryFailed
                | BrokerError::ExpiredAccess
                | BrokerError::InvalidReply
                | BrokerError::NotAuthenticated
        )
    )
}

impl Broker {
    /// The wait before renewal try `failures` (1 or more): the base, doubled per failure, capped.
    pub fn renewal_retry_delay(&self, failures: u32) -> Duration {
        let doublings = failures.saturating_sub(1).min(10);
        self.renewal_retry_base.saturating_mul(1 << doublings).min(RENEWAL_RETRY_CAP)
    }

    /// Renews `grant` before it expires. After `failures` renewals that failed in a row, the
    /// next try comes after a backoff instead.
    pub(crate) fn schedule_refresh(self: &Arc<Self>, grant: &Grant, failures: u32) {
        let mut state = self.st();
        // A foreground refresh can race a renewal fan-out: keep the active renewal so its
        // delivery is not cancelled; it schedules itself again after its fan-out.
        if state.refresh_task.is_some() || state.targets.is_empty() || state.stopped {
            return;
        }
        state.refresh_cycle = state.refresh_cycle.saturating_add(1);
        let cycle = state.refresh_cycle;
        let lead = if state.cached_is_local && state.cached.as_ref() == Some(grant) {
            MINIMUM_LIFETIME + 60.0
        } else {
            120.0
        };
        let wait = if failures == 0 {
            timer((grant.expires_at - now() - lead).max(1.0))
        } else {
            self.renewal_retry_delay(failures)
        };
        state.next_renewal_at = Some(now() + wait.as_secs() as f64);
        let weak = Arc::downgrade(self);
        let grant = grant.clone();
        state.refresh_task = Some(Job::spawn(move |cx| async move {
            // wakeup-allow: one renewal wakeup before the grant expires, or one backoff after a failure.
            let result: Result<(), Error> = async {
                cx.sleep(wait).await?;
                let Some(this) = weak.upgrade() else { return Ok(()) };
                if !this.in_scope() {
                    return Err(BrokerError::ScopeChanged.into());
                }
                let refreshed = this.retry_renewal(&cx, || this.refresh_access(false)).await?;
                let mut undelivered = None;
                for target in this.target_list() {
                    let delivered = this
                        .retry_renewal(&cx, || this.deliver(&cx, &refreshed, &target, None))
                        .await;
                    match delivered {
                        Err(error) if error.is(BrokerError::ScopeChanged) => return Err(error),
                        Err(error) if retries_later(&error) => undelivered = Some(error),
                        _ => {}
                    }
                }
                // A machine its API failed to reach keeps its old access, which expires before
                // the refreshed grant's renewal: it takes the backoff instead (cmux#33387).
                if let Some(error) = undelivered {
                    return Err(error);
                }
                this.reschedule_refresh(&cx, &refreshed, cycle);
                Ok(())
            }
            .await;
            if let Err(error) = result
                && let Some(this) = weak.upgrade()
            {
                // A transient failure (the Mac woke before its network did) tries again later.
                this.renewal_failed(&cx, &error, &grant, cycle, failures);
            }
        }));
    }

    async fn retry_renewal<T, F, Fut>(&self, cx: &Cx, mut work: F) -> Result<T, Error>
    where
        F: FnMut() -> Fut,
        Fut: Future<Output = Result<T, Error>>,
    {
        for attempt in 0..=3u32 {
            match work().await {
                Ok(value) => return Ok(value),
                Err(error) => {
                    let quick = matches!(
                        error,
                        Error::Broker(
                            BrokerError::BrokerUnavailable
                                | BrokerError::RemoteDeliveryFailed
                                | BrokerError::ExpiredAccess
                        )
                    );
                    if cx.is_cancelled() || attempt >= 3 || !quick {
                        return Err(error);
                    }
                    self.ensure_scope(cx)?;
                    // wakeup-allow: at most three recovery attempts for an active renewal, then stop.
                    cx.sleep(Duration::from_secs(1 << attempt)).await?;
                }
            }
        }
        Err(BrokerError::BrokerUnavailable.into())
    }

    /// A renewal that failed ends, and after a transient failure the next one is scheduled after
    /// a backoff. Stops: shut down, no machine left, a newer renewal, a scope change, a sign-out
    /// or a cancel.
    fn renewal_failed(
        self: &Arc<Self>,
        cx: &Cx,
        error: &Error,
        grant: &Grant,
        cycle: u64,
        failures: u32,
    ) {
        let next = {
            let mut state = self.st();
            if cycle != state.refresh_cycle {
                return;
            }
            state.refresh_task = None;
            if cx.is_cancelled() || !retries_later(error) {
                return;
            }
            state.cached.clone().unwrap_or_else(|| grant.clone())
        };
        self.schedule_refresh(&next, failures.saturating_add(1));
    }

    fn reschedule_refresh(self: &Arc<Self>, cx: &Cx, grant: &Grant, cycle: u64) {
        let next = {
            let mut state = self.st();
            if cycle != state.refresh_cycle {
                return;
            }
            // This runs on the renewal task itself; clear its handle before the next one.
            state.refresh_task = None;
            if cx.is_cancelled() || state.targets.is_empty() {
                return;
            }
            state.cached.clone().unwrap_or_else(|| grant.clone())
        };
        self.schedule_refresh(&next, 0);
    }

    /// One catch-up delivery for a machine taken back after a relaunch: the cached grant while it
    /// is current, else a fresh one.
    pub(crate) async fn catch_up(
        self: &Arc<Self>,
        cx: &Cx,
        target: &TargetRef,
        generation: u64,
    ) -> Result<(), Error> {
        let cached = if self.cached_still_allowed().await { self.current_cache() } else { None };
        let grant = match cached {
            Some(grant) => grant,
            None => self.refresh_access(true).await?,
        };
        self.deliver(cx, &grant, target, Some(generation)).await
    }

    /// Whether a failed catch-up tries again: what a renewal retries, and a machine paused for now.
    pub fn catch_up_retries(error: &Error) -> bool {
        retries_later(error) || error.is(BrokerError::TargetOffline)
    }

    /// Tries a failed catch-up again, after the renewal backoff, until the access the machine
    /// holds runs out at `expiry` (cmux#34010). Stops: a delivery lands, `expiry` passes, the
    /// machine's access already outlasts `expiry`, an error a renewal would not retry, or the
    /// machine is no longer this run's at `generation`, the scope changed, or the holder stopped.
    /// A revoke, a delete, shutdown, detach and an emptied machine list cancel it.
    pub(crate) fn retry_catch_up(
        self: &Arc<Self>,
        target: &TargetRef,
        generation: u64,
        expiry: f64,
    ) {
        let id = target.machine_id().to_owned();
        self.cancel_catch_up(&id);
        let weak = Arc::downgrade(self);
        let target = target.clone();
        let mut state = self.st();
        let token = state.token();
        let task_id = id.clone();
        let job = Job::spawn(move |cx| async move {
            let mut failures = 0u32;
            while !cx.is_cancelled() {
                failures = failures.saturating_add(1);
                let Some(delay) =
                    weak.upgrade().and_then(|this| this.catch_up_delay(failures, expiry))
                else {
                    break;
                };
                // wakeup-allow: bounded catch-up retries, backed off, ending at the access expiry.
                if cx.sleep(delay).await.is_err() {
                    break;
                }
                let Some(this) = weak.upgrade() else { break };
                if !this.catch_up_wanted(&task_id, generation, expiry) {
                    break;
                }
                match this.catch_up(&cx, &target, generation).await {
                    Ok(()) => break,
                    Err(error) if !Self::catch_up_retries(&error) => break,
                    Err(_) => {}
                }
            }
            if let Some(this) = weak.upgrade() {
                let mut state = this.st();
                if state.catch_ups.get(&task_id).is_some_and(|(t, _)| *t == token) {
                    state.catch_ups.remove(&task_id);
                }
            }
        });
        state.catch_ups.insert(id, (token, job));
    }

    /// The wait before catch-up try `failures`, never past `expiry`; none once it has passed.
    fn catch_up_delay(&self, failures: u32, expiry: f64) -> Option<Duration> {
        let remaining = expiry - now();
        (remaining > 0.0).then(|| self.renewal_retry_delay(failures).min(timer(remaining)))
    }

    fn catch_up_wanted(&self, id: &str, generation: u64, expiry: f64) -> bool {
        let wanted = {
            let state = self.st();
            !state.stopped
                && state.targets.contains_key(id)
                && !state.pending_revocations.contains(id)
                && state.generation(id) == generation
                && now() < expiry
                && grant_in(state.installed.get(id).map_or(&[][..], Vec::as_slice)).expires_at
                    <= expiry
        };
        wanted && self.in_scope()
    }

    pub(crate) fn cancel_catch_up(&self, id: &str) {
        if let Some((_, job)) = self.st().catch_ups.remove(id) {
            job.cancel();
        }
    }

    pub(crate) fn cancel_catch_ups(&self) {
        let jobs: Vec<(u64, Job)> = self.st().catch_ups.drain().map(|(_, entry)| entry).collect();
        for (_, job) in jobs {
            job.cancel();
        }
    }

    /// The machines a failed catch-up still tries again for.
    pub fn catch_up_machine_ids(&self) -> HashSet<String> {
        self.st().catch_ups.keys().cloned().collect()
    }

    /// The catch-up retry for `id`: its cancel and its end (tests).
    pub fn catch_up_task(&self, id: &str) -> Option<(Cx, Ended)> {
        self.st().catch_ups.get(id).map(|(_, job)| (job.cx.clone(), job.ended()))
    }

    /// Stops the local process and renewal, then erases the registered machines' files.
    /// Returns the machines whose erase failed; the local credentials stay for reuse.
    pub async fn shutdown(self: &Arc<Self>) -> HashSet<String> {
        let (ending, pending, session) = {
            let mut state = self.st();
            state.stopped = true;
            if let Some(job) = &state.refresh_task {
                job.cancel();
            }
            if let Some((_, _, cx)) = &state.refresh_in_flight {
                cx.cancel();
            }
            let mut ending = state.targets.clone();
            ending.extend(state.revocation_targets.clone());
            (
                ending.into_values().collect::<Vec<_>>(),
                state.pending_revocations.clone(),
                state.session.clone(),
            )
        };
        self.cancel_catch_ups();
        if let Some(session) = session {
            self.invalidate(&session).await;
        }
        let failed = self.revoke_within_quit_budget(ending, pending).await;
        self.st().cached = None;
        failed
    }

    /// Quit and update: stops renewal and the local process like `shutdown`, but leaves the
    /// access delivered to each machine in place until the provider expires it, so a Cloud Codex
    /// run keeps working after cmux quits or updates (#33482). Only revocations asked for before
    /// the quit still run, within the quit budget. Returns the machines whose revocation failed.
    pub async fn detach(self: &Arc<Self>) -> HashSet<String> {
        let (asked, pending, session) = {
            let mut state = self.st();
            // Snapshot first: a renewal the cancel below cuts short is not an ask to erase.
            let asked: Vec<TargetRef> = state.revocation_targets.values().cloned().collect();
            let pending = state.pending_revocations.clone();
            state.stopped = true;
            state.detached = true;
            if let Some(job) = state.refresh_task.take() {
                job.cancel();
            }
            if let Some((_, _, cx)) = &state.refresh_in_flight {
                cx.cancel();
            }
            (asked, pending, state.session.clone())
        };
        self.cancel_catch_ups();
        if let Some(session) = session {
            self.invalidate(&session).await;
        }
        let failed = self.revoke_within_quit_budget(asked, pending).await;
        self.st().cached = None;
        failed
    }

    /// Erases each machine in parallel; each wait is bounded, not the erase itself (a cancel
    /// could release its lock before the server finishes erasing).
    async fn revoke_within_quit_budget(
        self: &Arc<Self>,
        targets: Vec<TargetRef>,
        initial: HashSet<String>,
    ) -> HashSet<String> {
        let waits = targets.into_iter().map(|target| {
            let this = self.clone();
            let id = target.machine_id().to_owned();
            let erase =
                tokio::spawn(async move { this.revoke(&Cx::never(), &target, false).await });
            async move {
                let succeeded =
                    matches!(tokio::time::timeout(QUIT_BUDGET, erase).await, Ok(Ok(Ok(()))));
                (id, succeeded)
            }
        });
        let mut failed = initial;
        for (id, succeeded) in futures_util::future::join_all(waits).await {
            if succeeded {
                failed.remove(&id);
            } else {
                failed.insert(id);
            }
        }
        failed
    }
}
