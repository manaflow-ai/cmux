//! A race that starts at the route that won last time: [`race_remembered`] orders the
//! candidates by a [`LastGood`] memory, races them with the stagger taken from the remembered
//! connect time, and records the winner (or forgets the peer when every attempt failed). The
//! one way every dial uses the memory, so cmux-remote's TCP dial and the phone's signaling
//! dial behave and measure the same.

use std::future::Future;
use std::hash::Hash;
use std::io;
use std::net::SocketAddr;

use crate::{LastGood, Losers, RacePolicy, Won, race_keeping_losers};

/// `addresses` IPv6 first, the two families alternating, the order within a family kept
/// (RFC 8305). Dials race over this, not the resolver's order: musl sorts every A record first
/// on a host whose only IPv6 address is ULA and reads no `/etc/gai.conf`, so attempt 0 would
/// always be IPv4 and IPv6 never used where it is the faster path. An IPv6 attempt that stalls
/// is joined by IPv4 after the race's stagger; one with no route fails at once.
#[must_use]
pub fn v6_first(addresses: &[SocketAddr]) -> Vec<SocketAddr> {
    let (mut v6, mut v4): (Vec<_>, Vec<_>) =
        addresses.iter().copied().partition(SocketAddr::is_ipv6);
    v6.reverse();
    v4.reverse();
    let mut out = Vec::with_capacity(addresses.len());
    while !v6.is_empty() || !v4.is_empty() {
        out.extend(v6.pop());
        out.extend(v4.pop());
    }
    out
}

/// [`race`] over `candidates` with `memory`'s winner for `key` first and the stagger set from
/// its connect time ([`RacePolicy::with_lead`]). The winner is recorded for `key`; a race whose
/// every attempt failed forgets `key`. Returns the winning target beside the [`Won`] (whose
/// `target_index` indexes the reordered list, not `candidates`).
///
/// # Errors
/// The race's error: the last attempt's.
pub async fn race_remembered<K, A, T, F, Fut>(
    memory: &LastGood<K, A>,
    key: K,
    candidates: &[A],
    policy: RacePolicy,
    connect: F,
) -> io::Result<(A, Won<T>)>
where
    K: Eq + Hash,
    A: Clone + PartialEq,
    F: FnMut(A) -> Fut,
    Fut: Future<Output = io::Result<T>>,
{
    race_remembered_keeping_losers(memory, key, candidates, policy, connect)
        .await
        .map(|(winner, won, _)| (winner, won))
}

/// [`race_remembered`], with the attempts still in flight handed back as [`Losers`]
/// ([`crate::race_keeping_losers`]): the feed for a [`crate::Standby`] pool.
///
/// # Errors
/// The race's error: the last attempt's.
pub async fn race_remembered_keeping_losers<K, A, T, F, Fut>(
    memory: &LastGood<K, A>,
    key: K,
    candidates: &[A],
    policy: RacePolicy,
    connect: F,
) -> io::Result<(A, Won<T>, Losers<A, Fut>)>
where
    K: Eq + Hash,
    A: Clone + PartialEq,
    F: FnMut(A) -> Fut,
    Fut: Future<Output = io::Result<T>>,
{
    let (ordered, lead) = memory.order(&key, candidates);
    match race_keeping_losers(&ordered, policy.with_lead(lead), connect).await {
        Ok((won, losers)) => {
            let Some(winner) = ordered.get(won.target_index).cloned() else {
                return Err(io::Error::other("race won on a target it was not given"));
            };
            memory.record(key, winner.clone(), won.connect);
            Ok((winner, won, losers))
        }
        Err(error) => {
            memory.forget(&key);
            Err(error)
        }
    }
}

#[cfg(test)]
#[path = "remembered_tests.rs"]
mod tests;
