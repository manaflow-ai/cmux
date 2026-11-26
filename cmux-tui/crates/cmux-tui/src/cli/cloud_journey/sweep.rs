//! The leaked-machine sweep, before `create machine`: the machines earlier journey runs meant to delete
//! and left behind (a job cancelled or timed out before its delete step). The TypeScript journey has
//! had this sweep (`staleJourneyMachines`, scripts/cmux-next/cloud-journey.ts); the Rust journey and
//! `cmux repro run --cloud` had none, so their leaks piled up until staging answered
//! `cloud.quota.vm_limit` ("this team has its limit of 300 machines ... 48 of them are test
//! leftovers", repro-capsule-journey run 45554668749).
//!
//! The rule is the TypeScript one. Ownership is the name, never age or state:
//! `cloud journey auto jr-<tag>` (with ` gateway` or ` cold`), `cloud start bench jr-<tag> …`, and
//! `repro capsule <id> jr-<tag>`, names only a run that deletes its machine gives. The tag is the
//! run's start in milliseconds, base 36. A machine is swept only when that start is more than
//! [`STALE_MS`] ago and it has had no activity for [`IDLE_MS`]. A `--keep` run's
//! `cloud journey jr-<tag>`, any other name, and a tag that does not read as a time are never picked.

use cmux_cloud_wire::{CloudMachine, CloudMachineStatus};

/// Well past the longest job that runs a journey (the TypeScript journey's `STALE_JOURNEY_MS`), so a
/// journey that is still running never loses its machine.
pub(super) const STALE_MS: i64 = 11 * 3_600_000;
/// And idle this long: a machine with activity since then is in use, whatever its age.
pub(super) const IDLE_MS: i64 = 60 * 60_000;
/// The most machines one run deletes; the next run takes the rest.
pub(super) const MAX_PER_RUN: usize = 25;
/// 2020-01-01T00:00:00Z: a real tag is a time after it.
const EPOCH_2020_MS: i64 = 1_577_836_800_000;

/// The start time a journey-owned name's tag reads as, when the name is one only a deleting run gives.
pub(super) fn owned_tag_ms(name: &str) -> Option<i64> {
    let tag = if let Some(rest) = name.strip_prefix("cloud journey auto jr-") {
        rest.strip_suffix(" gateway").or_else(|| rest.strip_suffix(" cold")).unwrap_or(rest)
    } else if let Some(rest) = name.strip_prefix("cloud start bench jr-") {
        let (tag, role) = rest.split_once(' ')?;
        let ok = role == "source"
            || ["spare ", "cold ", "snapshot "].iter().any(|p| {
                role.strip_prefix(p)
                    .is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
            });
        if !ok {
            return None;
        }
        tag
    } else if let Some(rest) = name.strip_prefix("repro capsule ") {
        let (id, tag) = rest.split_once(" jr-")?;
        if id.is_empty() || id.contains(char::is_whitespace) {
            return None;
        }
        tag
    } else {
        return None;
    };
    if tag.is_empty()
        || tag.len() > 16
        || !tag.bytes().all(|b| b.is_ascii_digit() || b.is_ascii_lowercase())
    {
        return None;
    }
    i64::from_str_radix(tag, 36).ok()
}

/// The machines the sweep may delete, oldest first, at most [`MAX_PER_RUN`].
pub(super) fn stale(machines: &[CloudMachine], now_ms: i64) -> Vec<&CloudMachine> {
    let mut out: Vec<(&CloudMachine, i64)> = machines
        .iter()
        .filter(|m| m.status != CloudMachineStatus::Deleting)
        .filter_map(|m| {
            let started = owned_tag_ms(m.name.as_deref()?)?;
            if started < EPOCH_2020_MS || started > now_ms || now_ms - started <= STALE_MS {
                return None;
            }
            if m.last_active_at.is_some_and(|at| now_ms - at <= IDLE_MS) {
                return None;
            }
            Some((m, started))
        })
        .collect();
    out.sort_by_key(|(_, started)| *started);
    out.into_iter().take(MAX_PER_RUN).map(|(m, _)| m).collect()
}
