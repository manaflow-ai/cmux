//! One writer publishes authenticated keys, policy and issuer time together.
//! Readers retain the verifier and its replay history for the owner lifetime.
use std::sync::{Arc, Weak};
use std::time::Instant;

use super::streams::{reconcile_streams, wake_streams};
use super::{
    MAX_REPLAY, MAX_SAFE_INTEGER, NativePolicy, NativeTokenVerifier, ReceiverTime, State,
    valid_keys,
};
use crate::keyset::Keyset;
use crate::token::TokenRefused;

pub(super) struct ReceiverState {
    identity: Arc<()>,
    serial: u64,
    anchor: Option<ReceiverTime>,
}

impl ReceiverState {
    pub(super) fn ready(&self) -> bool {
        self.anchor.is_some()
    }
    pub(super) fn sample(&self, now: Instant) -> Option<ReceiverTime> {
        advance(self.anchor?, now)
    }
    fn current(&self, refresh: &Refresh) -> bool {
        self.serial < u64::MAX
            && self.serial == refresh.serial
            && Arc::ptr_eq(&self.identity, &refresh.owner)
    }
    fn next(&mut self) -> Option<u64> {
        self.serial = self.serial.saturating_add(1);
        (self.serial < u64::MAX).then_some(self.serial)
    }
}

fn advance(time: ReceiverTime, now: Instant) -> Option<ReceiverTime> {
    let elapsed = u64::try_from(now.checked_duration_since(time.monotonic)?.as_millis()).ok()?;
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
    done: bool,
}
impl Refresh {
    pub fn started(&self) -> Instant {
        self.started
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
        Self::with_clock(keys, || Some(Instant::now()))
    }

    pub fn with_clock(
        keys: Keyset,
        clock: impl Fn() -> Option<Instant> + Send + Sync + 'static,
    ) -> Result<Self, TokenRefused> {
        Self::with_mode(keys, None, clock)
    }

    pub fn for_receiver(keys: Keyset, generation: String) -> Result<Self, TokenRefused> {
        Self::with_mode(keys, Some(generation), || Some(Instant::now()))
    }

    fn with_mode(
        keys: Keyset,
        generation: Option<String>,
        clock: impl Fn() -> Option<Instant> + Send + Sync + 'static,
    ) -> Result<Self, TokenRefused> {
        let clock = move || Some(ReceiverTime { unix_ms: 0, monotonic: clock()? });
        let verifier = match generation {
            Some(generation) => {
                NativeTokenVerifier::new_for_receiver(keys, generation, clock, MAX_REPLAY)
            }
            None => NativeTokenVerifier::new(keys, clock, MAX_REPLAY),
        }?;
        verifier.state.lock().map_err(|_| TokenRefused::Invalid)?.receiver =
            Some(ReceiverState { identity: Arc::new(()), serial: 0, anchor: None });
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
            return Ok(Refresh {
                verifier: Arc::downgrade(&self.verifier),
                owner: receiver.identity.clone(),
                serial,
                started,
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
            let old = match state.receiver.as_ref()?.anchor {
                Some(anchor) => advance(anchor, now)?.unix_ms,
                None => 0,
            };
            // Calibrated upper bounds may tighten between reads. Keep time
            // monotonic so tightening can never revive an expired/spent token.
            let now = ReceiverTime {
                unix_ms: incoming.unix_ms.max(old).max(state.clock_high_water),
                monotonic: now,
            };
            policy.valid(now).then_some(now)
        })();
        let Some(now) = candidate else {
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

    pub fn invalidate(&self) {
        self.verifier.clear_authority();
    }
}

impl Drop for Owner {
    fn drop(&mut self) {
        self.invalidate();
    }
}
