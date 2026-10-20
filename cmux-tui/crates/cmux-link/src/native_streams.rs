//! Current-policy reconciliation of leases captured during JWT verification.
use std::task::Waker;
use std::time::{Duration, Instant};

use super::{NativePolicy, ReceiverTime, State};

pub(super) fn stream_deadline(policy: &NativePolicy, now: ReceiverTime) -> Option<Instant> {
    Some(
        policy
            .request_started
            .checked_add(Duration::from_millis(
                policy.expires_at_ms.checked_sub(policy.checked_at_ms)?,
            ))?
            .min(now.monotonic.checked_add(Duration::from_millis(
                policy.expires_at_ms.checked_sub(now.unix_ms)?,
            ))?),
    )
}

pub(super) fn reconcile_streams(state: &mut State, now: Option<ReceiverTime>) -> Vec<Waker> {
    let policy =
        now.and_then(|now| state.policy.as_ref().filter(|p| p.valid(now)).map(|p| (p, now)));
    let mut wake = Vec::new();
    state.streams.retain(|stream| {
        let Some(previous) = stream.lease.deadline() else { return false };
        let next = policy.and_then(|(p, now)| {
            if now.monotonic >= previous
                || p.issuer != stream.issuer
                || p.host != stream.host
                || p.epoch != stream.epoch
                || p.team != stream.team
                || p.authority_version != stream.authority_version
                || state.keys.keys.get(&stream.kid) != Some(&stream.signing_key)
                || !p.peers.iter().any(|peer| {
                    peer.install == stream.peer.install
                        && peer.binding == stream.peer.binding
                        && peer.services.contains(&stream.service)
                })
            {
                return None;
            }
            stream_deadline(p, now)
        });
        wake.extend(stream.lease.set(next));
        next.is_some()
    });
    wake
}

pub(super) fn wake_streams(wake: Vec<Waker>) {
    for waker in wake {
        waker.wake();
    }
}
