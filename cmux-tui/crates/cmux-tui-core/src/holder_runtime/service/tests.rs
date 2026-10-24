//! Tests of the holder service: the ownership decision.

use super::*;

const A: [u8; 16] = [1; 16];
const B: [u8; 16] = [2; 16];
const C: [u8; 16] = [3; 16];

fn by_chan(mut claims: Vec<(u32, Claim)>) -> Vec<(u32, Claim)> {
    claims.sort_by_key(|(chan, _)| *chan);
    claims
}

/// Holder-core review: on a reconnect, a terminal the holder still runs
/// that no live terminal claims (a spawn whose SPAWNED the dropped link
/// lost, a terminal whose last CLOSE found no link) is ended, not left
/// running unseen, with its ring, for ever.
#[test]
fn a_reconnect_ends_what_the_holder_runs_that_nobody_claims() {
    let claims = ownership(&[(1, A), (2, B)], &[(1, A)], &[], false);
    assert_eq!(by_chan(claims), [(1, Claim::Resume), (2, Claim::Close)]);
}

/// Holder-core review: a startup-pass entry stays claimed across a
/// reconnect. The same holder keeps it (with its new listing); a new
/// holder, after the one that listed it died, gets its custody master
/// handed over, so the later re-attach does not ATTACH a channel only
/// the dead holder knew.
#[test]
fn a_reconnect_keeps_the_startup_pass_entries_and_hands_a_dead_holders_over() {
    let same = ownership(&[(3, C)], &[], &[(3, C)], false);
    assert_eq!(by_chan(same), [(3, Claim::Refresh)]);
    let new = ownership(&[], &[(1, A)], &[(3, C)], false);
    assert_eq!(by_chan(new), [(1, Claim::Adopt), (3, Claim::HandOver)]);
}

/// Holder-core review: only the startup pass keeps what nobody claims
/// yet (for it to re-attach); any other link ends it.
#[test]
fn only_the_startup_pass_keeps_what_nobody_claims() {
    let startup = ownership(&[(1, A), (2, B)], &[], &[], true);
    assert_eq!(by_chan(startup), [(1, Claim::Reserve), (2, Claim::Reserve)]);
    let other = ownership(&[(1, A), (2, B)], &[], &[], false);
    assert_eq!(by_chan(other), [(1, Claim::Close), (2, Claim::Close)]);
}

/// A live terminal resumes on the same holder and is adopted by a new
/// one; neither is ended.
#[test]
fn live_terminals_resume_on_the_same_holder_and_are_adopted_by_a_new_one() {
    let claims = ownership(&[(1, A)], &[(1, A), (2, B)], &[], false);
    assert_eq!(by_chan(claims), [(1, Claim::Resume), (2, Claim::Adopt)]);
}
