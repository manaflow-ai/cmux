//! The pending update's health wait when the supervisor deferred the old
//! session host's replacement ([`super::resolve::resolve_with`]), and the
//! connection list's input idle time it decides by.

use serde_json::json;

use super::resolve::{self, DEFER_EXCUSE, GuardStep, Resolved};
use super::role::HEALTH_TIMEOUT;

/// A fake-clock flip for [`resolve::resolve_with`] (5 s per wait, the clock
/// at 0 at the flip's restart): the supervisor keeps the old-build session
/// host, marked, until `replaced_s` (`None`: it never replaces it, today's
/// adopt), and the new build serves `serves_after_s` after its replacement.
/// Returns the outcome, the second it came at, and the guard steps.
fn resolve_timeline(
    replaced_s: Option<u64>,
    marked: bool,
    serves_after_s: u64,
) -> (Resolved, u64, Vec<GuardStep>) {
    let now = std::cell::Cell::new(0_u64);
    let mut guard = Vec::new();
    let resolved = resolve::resolve_with(
        || replaced_s.is_some_and(|at| now.get() >= at + serves_after_s),
        || marked && replaced_s.is_none_or(|at| now.get() < at),
        || std::time::Duration::from_secs(now.get()),
        |d| {
            now.set(now.get() + d.as_secs());
            true
        },
        |step| guard.push(step),
    );
    (resolved, now.get(), guard)
}

#[test]
fn a_flip_whose_host_replacement_was_deferred_commits_once_the_new_host_serves() {
    // Before: the adopted old-build host is never replaced, so the new
    // build never serves and the health timeout rolls the flip back.
    let (before, before_s, _) = resolve_timeline(None, false, 15);
    assert_eq!((before, before_s), (Resolved::TimedOut, HEALTH_TIMEOUT.as_secs()));
    // After, a busy host: a person's session keeps the old host for 30 min
    // (past the 10 min health timeout); it is replaced when the session
    // ends, and the new build serves 15 s later. It commits, and the
    // previous build's guard (which knows no deferral) is off meanwhile.
    let (after, after_s, guard) = resolve_timeline(Some(1_800), true, 15);
    assert_eq!(after, Resolved::Healthy, "rolled back at {after_s} s");
    assert_eq!(after_s, 1_815);
    assert_eq!(guard, [GuardStep::Disarm, GuardStep::Rearm]);
    // After, an idle host: replaced at once, serving 15 s after the flip.
    let (idle, idle_s, guard) = resolve_timeline(Some(0), false, 15);
    assert_eq!((idle, idle_s), (Resolved::Healthy, 15));
    assert!(guard.is_empty(), "{guard:?}");
    eprintln!(
        "flip to healthy: before {before_s} s (rolled back); after {idle_s} s idle, {after_s} s deferred 30 min"
    );
}

#[test]
fn the_health_deadline_runs_from_the_replacement_and_the_deferral_is_bounded() {
    // Replaced after 30 min but never serving: rolled back a health
    // timeout after the replacement, not after the flip.
    let (out, at, _) = resolve_timeline(Some(1_800), true, u64::MAX / 2);
    assert_eq!((out, at), (Resolved::TimedOut, 1_800 + HEALTH_TIMEOUT.as_secs()));
    // A mark that never goes holds the deadline back only so long.
    let (out, at, _) = resolve_timeline(Some(u64::MAX / 4), true, 0);
    assert_eq!(out, Resolved::TimedOut);
    assert_eq!(at, DEFER_EXCUSE.as_secs() + HEALTH_TIMEOUT.as_secs());
}

#[test]
fn the_least_input_idle_time_of_the_attached_sessions_is_read_and_absent_from_an_old_host() {
    use super::carrier::attached_input_idle_in;
    let conn = |state: &str, generation: u64, idle: Option<u64>| {
        let mut c = json!({"device_id": "d", "session_id": "s", "generation": generation, "state": state,
            "resume_lease_remaining_ms": null, "lane_bindings": [], "physical_link_count": 1});
        if let Some(ms) = idle {
            c["input_idle_ms"] = json!(ms);
        }
        c
    };
    let list = |items: Vec<serde_json::Value>| serde_json::Value::Array(items).to_string();
    assert_eq!(attached_input_idle_in("[]"), Some((0, None)));
    let two = list(vec![
        conn("connected", 1, Some(700_000)),
        conn("reconnecting", 2, Some(650_000)),
        conn("closed", 3, Some(5)),
    ]);
    assert_eq!(attached_input_idle_in(&two), Some((2, Some(650_000))));
    // A session host from before the field: attached, idle unknown.
    let old = list(vec![conn("connected", 1, None), conn("connected", 2, Some(900_000))]);
    assert_eq!(attached_input_idle_in(&old), Some((2, None)));
    assert_eq!(attached_input_idle_in("not json"), None);
    assert_eq!(attached_input_idle_in(&list(vec![conn("weird", 1, Some(1))])), None);
}
