//! One writer publishes authenticated keys, policy and issuer time together.
//! Readers retain the verifier and its replay history for the owner lifetime.
use std::sync::{Arc, Weak};
use std::time::{Duration, Instant};

use super::streams::{reconcile_streams, wake_streams};
use super::{
    MAX_REPLAY, MAX_SAFE_INTEGER, NativePolicy, NativeTokenVerifier, ReceiverTime, State,
    valid_keys,
};
use crate::elapsed::{Deadline, Elapsed};
use crate::keyset::Keyset;
use crate::token::TokenRefused;

pub(super) struct ReceiverState {
    identity: Arc<()>,
    serial: u64,
    anchor: Option<ReceiverTime>,
    anchor_elapsed: Option<Duration>,
    retired: bool,
    elapsed: Option<Elapsed>,
}

impl ReceiverState {
    pub(super) fn ready(&self) -> bool {
        !self.retired && self.anchor.is_some()
    }
    pub(super) fn sample(&self, now: Instant) -> Option<ReceiverTime> {
        if self.retired {
            return None;
        }
        let anchor = self.anchor?;
        let active = now.checked_duration_since(anchor.monotonic)?;
        let elapsed = match &self.elapsed {
            Some(source) => active.max(source.elapsed()?.checked_sub(self.anchor_elapsed?)?),
            None => active,
        };
        advance_by(anchor, now, elapsed)
    }

    pub(super) fn budget(&self, policy: &NativePolicy) -> Option<Option<Deadline>> {
        let Some(source) = &self.elapsed else { return Some(None) };
        let anchor = self.anchor?;
        let base = self.anchor_elapsed?;
        let issuer = base.checked_add(Duration::from_millis(
            policy.expires_at_ms.checked_sub(anchor.unix_ms)?,
        ))?;
        let request_expires = policy.request_started.checked_add(Duration::from_millis(
            policy.expires_at_ms.checked_sub(policy.checked_at_ms)?,
        ))?;
        let request =
            base.checked_add(request_expires.checked_duration_since(anchor.monotonic)?)?;
        Some(Some(source.deadline_at(issuer.min(request))?))
    }
    fn current(&self, refresh: &Refresh) -> bool {
        !self.retired
            && self.serial < u64::MAX
            && self.serial == refresh.serial
            && Arc::ptr_eq(&self.identity, &refresh.owner)
    }
    fn next(&mut self) -> Option<u64> {
        if self.retired {
            return None;
        }
        self.serial = self.serial.saturating_add(1);
        (self.serial < u64::MAX).then_some(self.serial)
    }
}

fn advance(time: ReceiverTime, now: Instant) -> Option<ReceiverTime> {
    advance_by(time, now, now.checked_duration_since(time.monotonic)?)
}

fn advance_by(time: ReceiverTime, now: Instant, elapsed: Duration) -> Option<ReceiverTime> {
    let elapsed = u64::try_from(elapsed.as_millis()).ok()?;
    let unix_ms = time.unix_ms.checked_add(elapsed)?;
    (unix_ms <= MAX_SAFE_INTEGER).then_some(ReceiverTime { unix_ms, monotonic: now })
}

pub(super) fn invalidate_state(state: &mut State) {
    state.policy = None;
    if let Some(receiver) = state.receiver.as_mut() {
        receiver.next();
    }
}

/// An unforgeable local read attempt, bound to one writer and intent order.
/// Dropping the current attempt closes authority; dropping a superseded one
/// cannot cancel a newer snapshot. This is never serialized as a credential.
pub struct Refresh {
    verifier: Weak<NativeTokenVerifier>,
    owner: Arc<()>,
    serial: u64,
    started: Instant,
    elapsed: Option<Elapsed>,
    done: bool,
}
impl Refresh {
    pub fn started(&self) -> Instant {
        self.started
    }

    pub fn elapsed_source(&self) -> Option<Elapsed> {
        self.elapsed.clone()
    }

    pub fn elapsed(&self, now: Instant) -> Option<Duration> {
        let active = now.checked_duration_since(self.started)?;
        Some(match &self.elapsed {
            Some(elapsed) => active.max(elapsed.elapsed()?),
            None => active,
        })
    }
}
impl Drop for Refresh {
    fn drop(&mut self) {
        if !self.done
            && let Some(verifier) = self.verifier.upgrade()
        {
            cancel(&verifier, self);
        }
    }
}

fn cancel(verifier: &NativeTokenVerifier, refresh: &Refresh) -> bool {
    let Ok(mut state) = verifier.state.lock() else { return false };
    if !state.receiver.as_ref().is_some_and(|r| r.current(refresh)) {
        return false;
    }
    invalidate_state(&mut state);
    let wake = reconcile_streams(&mut state, None);
    drop(state);
    wake_streams(wake);
    true
}

/// A single authority writer. Its initial public keyset comes from the original
/// enrollment; it grants nothing until an authenticated fresh snapshot installs.
/// The monotonic source never supplies wall time. Owner drop closes all readers.
pub struct Owner {
    verifier: Arc<NativeTokenVerifier>,
}

impl Owner {
    pub fn new(keys: Keyset) -> Result<Self, TokenRefused> {
        Self::with_elapsed_clock(
            keys,
            || Some(Instant::now()),
            Elapsed::system().ok_or(TokenRefused::Invalid)?,
        )
    }

    pub fn with_clock(
        keys: Keyset,
        clock: impl Fn() -> Option<Instant> + Send + Sync + 'static,
    ) -> Result<Self, TokenRefused> {
        Self::with_mode(keys, None, clock, None)
    }

    /// Inject active and suspend-inclusive clocks independently. Both remain
    /// local to this owner and its unforgeable prepared reads.
    pub fn with_elapsed_clock(
        keys: Keyset,
        clock: impl Fn() -> Option<Instant> + Send + Sync + 'static,
        elapsed: Elapsed,
    ) -> Result<Self, TokenRefused> {
        Self::with_mode(keys, None, clock, Some(elapsed))
    }

    pub fn for_receiver(keys: Keyset, generation: String) -> Result<Self, TokenRefused> {
        Self::with_mode(
            keys,
            Some(generation),
            || Some(Instant::now()),
            Some(Elapsed::system().ok_or(TokenRefused::Invalid)?),
        )
    }

    fn with_mode(
        keys: Keyset,
        generation: Option<String>,
        clock: impl Fn() -> Option<Instant> + Send + Sync + 'static,
        elapsed: Option<Elapsed>,
    ) -> Result<Self, TokenRefused> {
        let clock = move || Some(ReceiverTime { unix_ms: 0, monotonic: clock()? });
        let verifier = match generation {
            Some(generation) => {
                NativeTokenVerifier::new_for_receiver(keys, generation, clock, MAX_REPLAY)
            }
            None => NativeTokenVerifier::new(keys, clock, MAX_REPLAY),
        }?;
        verifier.state.lock().map_err(|_| TokenRefused::Invalid)?.receiver = Some(ReceiverState {
            identity: Arc::new(()),
            serial: 0,
            anchor: None,
            anchor_elapsed: None,
            retired: false,
            elapsed,
        });
        Ok(Self { verifier: Arc::new(verifier) })
    }

    pub fn verifier(&self) -> Arc<NativeTokenVerifier> {
        self.verifier.clone()
    }

    pub fn begin(&self) -> Result<Refresh, TokenRefused> {
        let mut state = self.verifier.state.lock().map_err(|_| TokenRefused::Invalid)?;
        let now = (self.verifier.clock)().map(|t| t.monotonic);
        let receiver = state.receiver.as_mut().ok_or(TokenRefused::Invalid)?;
        let serial = receiver.next();
        if let (Some(serial), Some(started)) = (serial, now) {
            let elapsed = match &receiver.elapsed {
                Some(elapsed) => match elapsed.restart() {
                    Some(elapsed) => Some(elapsed),
                    None => {
                        drop(state);
                        self.invalidate();
                        return Err(TokenRefused::Invalid);
                    }
                },
                None => None,
            };
            return Ok(Refresh {
                verifier: Arc::downgrade(&self.verifier),
                owner: receiver.identity.clone(),
                serial,
                started,
                elapsed,
                done: false,
            });
        }
        invalidate_state(&mut state);
        let wake = reconcile_streams(&mut state, None);
        drop(state);
        wake_streams(wake);
        Err(TokenRefused::Invalid)
    }

    /// The caller authenticates and pins the source before supplying a snapshot.
    /// Publish its entire state under the verifier lock; an updated clock must
    /// never be visible with the previous policy or signing keys.
    pub fn install(
        &self,
        mut refresh: Refresh,
        keys: Keyset,
        policy: NativePolicy,
        time: ReceiverTime,
    ) -> Result<(), TokenRefused> {
        let mut state = self.verifier.state.lock().map_err(|_| TokenRefused::Invalid)?;
        if !state.receiver.as_ref().is_some_and(|r| r.current(&refresh)) {
            drop(state);
            return Err(TokenRefused::Invalid);
        }
        refresh.done = true;
        let candidate = (|| {
            if !valid_keys(&keys)
                || policy.request_started > refresh.started
                || time.monotonic < refresh.started
                || time.unix_ms > MAX_SAFE_INTEGER
                || time.unix_ms
                    < policy.checked_at_ms.checked_add(
                        u64::try_from(time.monotonic.duration_since(refresh.started).as_millis())
                            .ok()?,
                    )?
                || state.last_policy_check.is_some_and(|last| policy.checked_at_ms <= last)
            {
                return None;
            }
            let now = (self.verifier.clock)()?.monotonic;
            let incoming = advance(time, now)?;
            let receiver = state.receiver.as_ref()?;
            let anchor_elapsed = match &receiver.elapsed {
                Some(source) => Some(source.elapsed()?),
                None => None,
            };
            let debit = u64::try_from(refresh.elapsed(now)?.as_millis()).ok()?;
            if incoming.unix_ms < policy.checked_at_ms.checked_add(debit)? {
                return None;
            }
            let old = match receiver.anchor {
                Some(_) => receiver.sample(now)?.unix_ms,
                None => 0,
            };
            // Calibrated upper bounds may tighten between reads. Keep time
            // monotonic so tightening can never revive an expired/spent token.
            let now = ReceiverTime {
                unix_ms: incoming.unix_ms.max(old).max(state.clock_high_water),
                monotonic: now,
            };
            policy.valid(now).then_some((now, anchor_elapsed))
        })();
        let Some((now, anchor_elapsed)) = candidate else {
            invalidate_state(&mut state);
            let wake = reconcile_streams(&mut state, None);
            drop(state);
            wake_streams(wake);
            return Err(TokenRefused::Invalid);
        };
        state.keys = keys;
        state.last_policy_check = Some(policy.checked_at_ms);
        state.policy = Some(policy);
        state.clock_high_water = now.unix_ms;
        if let Some(receiver) = state.receiver.as_mut() {
            receiver.anchor = Some(now);
            receiver.anchor_elapsed = anchor_elapsed;
        }
        let wake = reconcile_streams(&mut state, Some(now));
        drop(state);
        wake_streams(wake);
        Ok(())
    }

    pub fn fail(&self, mut refresh: Refresh) -> bool {
        let applied = cancel(&self.verifier, &refresh);
        refresh.done = true;
        applied
    }

    /// A current authenticated read ended this receiving generation. Neither
    /// another read nor a retained verifier may reopen this process afterward.
    /// Superseded or foreign read intents cannot retire this owner.
    pub fn retire(&self, mut refresh: Refresh) -> bool {
        let Ok(mut state) = self.verifier.state.lock() else { return false };
        if !state.receiver.as_ref().is_some_and(|receiver| receiver.current(&refresh)) {
            drop(state);
            return false;
        }
        refresh.done = true;
        if let Some(receiver) = state.receiver.as_mut() {
            receiver.retired = true;
        }
        invalidate_state(&mut state);
        let wake = reconcile_streams(&mut state, None);
        drop(state);
        wake_streams(wake);
        true
    }

    /// A retired source needs a new process and private generation pin.
    pub fn is_retired(&self) -> bool {
        self.verifier.state.lock().map_or(true, |state| {
            state.receiver.as_ref().is_none_or(|receiver| {
                receiver.retired
                    || receiver.elapsed.as_ref().is_some_and(|source| source.elapsed().is_none())
            })
        })
    }

    pub fn invalidate(&self) {
        self.verifier.clear_authority();
    }
}

impl Drop for Owner {
    fn drop(&mut self) {
        self.invalidate();
    }
}
