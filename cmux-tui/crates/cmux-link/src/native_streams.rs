//! Current-policy reconciliation of leases captured during JWT verification.
use std::task::Waker;
use std::time::{Duration, Instant};

use super::{NativePeer, NativePolicy, ReceiverTime, State};
use crate::dial::Service;
use crate::elapsed::Deadline;
use crate::stream_lease::LeaseControl;
use std::collections::BTreeMap;

/// Captured under the verifier lock. Full authority prevents a replacement
/// grant from adopting a stream in the admission-to-handoff race.
pub(super) struct StreamAuthority {
    pub(super) issuer: String,
    pub(super) host: String,
    pub(super) epoch: u64,
    pub(super) team: String,
    pub(super) authority_version: String,
    pub(super) peer: NativePeer,
    pub(super) proof: StreamProof,
    pub(super) lease: LeaseControl,
}

pub(super) enum StreamProof {
    Token { service: Service, kid: String, signing_key: [u8; 32] },
    // Before a hello names its kid/service, pin all public keys and services.
    // Keyset version metadata alone does not change signing authority.
    Handshake { keys: BTreeMap<String, [u8; 32]> },
}

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

pub(super) fn elapsed_deadline(state: &State, policy: &NativePolicy) -> Option<Option<Deadline>> {
    match &state.receiver {
        Some(receiver) => receiver.budget(policy),
        None => Some(None),
    }
}

pub(super) fn reconcile_streams(state: &mut State, now: Option<ReceiverTime>) -> Vec<Waker> {
    let policy =
        now.and_then(|now| state.policy.as_ref().filter(|p| p.valid(now)).map(|p| (p, now)));
    let elapsed = policy.and_then(|(p, _)| elapsed_deadline(state, p));
    let mut wake = Vec::new();
    state.streams.retain(|stream| {
        let Some(previous) = stream.lease.deadline() else {
            wake.extend(stream.lease.set(None, None));
            return false;
        };
        let next = policy.and_then(|(p, now)| {
            if now.monotonic >= previous
                || p.issuer != stream.issuer
                || p.host != stream.host
                || p.epoch != stream.epoch
                || p.team != stream.team
                || p.authority_version != stream.authority_version
                || !p.peers.iter().any(|peer| {
                    peer.install == stream.peer.install
                        && peer.binding == stream.peer.binding
                        && match &stream.proof {
                            StreamProof::Token { service, kid, signing_key } => {
                                peer.services.contains(service)
                                    && state.keys.keys.get(kid) == Some(signing_key)
                            }
                            StreamProof::Handshake { keys } => {
                                &state.keys.keys == keys
                                    && peer.services.len() == stream.peer.services.len()
                                    && peer
                                        .services
                                        .iter()
                                        .all(|s| stream.peer.services.contains(s))
                            }
                        }
                })
            {
                return None;
            }
            let next = stream_deadline(p, now)?;
            // A partial hello never acquires an indefinitely renewed slot.
            // Token admission replaces it with a separately verified lease.
            Some(if matches!(stream.proof, StreamProof::Handshake { .. }) {
                next.min(previous)
            } else {
                next
            })
        });
        let budget = if matches!(stream.proof, StreamProof::Handshake { .. }) {
            match (stream.lease.elapsed_deadline(), elapsed.clone()) {
                (Some(previous), Some(Some(next))) => previous.bounded_by(next).map(Some),
                (None, Some(None)) => Some(None),
                _ => None,
            }
        } else {
            elapsed.clone()
        };
        let next = next.filter(|_| budget.is_some());
        wake.extend(stream.lease.set(next, next.and(budget).flatten()));
        next.is_some()
    });
    wake
}

pub(super) fn wake_streams(wake: Vec<Waker>) {
    for waker in wake {
        waker.wake();
    }
}
