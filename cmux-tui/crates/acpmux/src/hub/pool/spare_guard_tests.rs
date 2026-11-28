//! The loop seen live: seven remembered harnesses, spares of ~250 MB, the 1 GB default cap. Each
//! person request restarted the spares the cap had just ended.

use super::super::policy::{Origin, Pool, PoolKey, Role};
use super::*;

const MB: u64 = 1024 * 1024;

fn key(harness: &str) -> PoolKey {
    PoolKey {
        origin: Origin::Local,
        cwd: "/a".into(),
        harness: harness.to_owned(),
        preset: None,
        args: Vec::new(),
        system_prompt_sha256: None,
        auth: String::new(),
        account: None,
        machine: None,
        prompt_suggestions: None,
        tool_servers: String::new(),
        settings_file: Default::default(),
        model: None,
        effort: None,
    }
}

/// One presence pass as `spare_on_person_request` and `pool_after_ready` run it, at `at`
/// seconds: every harness without a spare that the guard admits starts, becomes ready, and the
/// cap ends the oldest entries, whose spares are held. Returns the starts.
fn presence_pass(
    pool: &mut Pool<(String, u64)>,
    guard: &mut SpareGuard,
    harnesses: &[&str],
    at: u64,
    cap: u64,
) -> usize {
    let now = Duration::from_secs(at);
    let mut starts = 0;
    for h in harnesses {
        if pool.has_spare(h) || guard.admit(h, Start::Auto, now) != Verdict::Start {
            continue;
        }
        let k = key(h);
        let generation = pool.want(Role::Spare, k.clone(), now).start.expect("a start");
        assert!(pool.complete(&k, generation, ((*h).to_owned(), 250 * MB), now).is_none());
        starts += 1;
        for ((harness, _), spare) in pool.enforce_cap(cap, |p| p.1) {
            if spare {
                guard.evicted_by_cap(&harness);
            }
        }
    }
    starts
}

#[test]
fn spares_over_the_rss_cap_settle_instead_of_restarting_on_every_request() {
    let harnesses =
        ["opencode", "claude-sr", "chief", "claude-sr2", "antigravity", "codex", "claude"];
    let mut pool = Pool::new(Duration::from_secs(3600));
    pool.set_spare_idle(Duration::from_secs(3600));
    let mut guard = SpareGuard::default();
    // The first pass starts each once; four fit, the cap ends the oldest three.
    assert_eq!(presence_pass(&mut pool, &mut guard, &harnesses, 0, 1024 * MB), 7);
    let kept = harnesses.iter().filter(|h| pool.has_spare(h)).count();
    assert_eq!(kept, 4);
    // Two hours of person requests, one a second: nothing starts again.
    let later: usize =
        (1..7200).map(|t| presence_pass(&mut pool, &mut guard, &harnesses, t, 1024 * MB)).sum();
    assert_eq!(later, 0, "a spare the cap ended is never restarted on its own");
    // The person uses one of them: its spare starts once, as a session's refill would.
    assert_eq!(guard.admit("opencode", Start::Used, Duration::from_secs(7200)), Verdict::Start);
    assert_eq!(guard.admit("opencode", Start::Auto, Duration::from_secs(7200)), Verdict::Start);
}

#[test]
fn the_daemons_own_spare_starts_are_rate_limited_per_harness_and_trip_once() {
    let mut guard = SpareGuard::default();
    let at = Duration::from_secs;
    for t in 0..u64::try_from(MAX_STARTS).unwrap() {
        assert_eq!(guard.admit("claude", Start::Auto, at(t)), Verdict::Start);
    }
    assert_eq!(guard.admit("claude", Start::Auto, at(10)), Verdict::Tripped { first: true });
    assert_eq!(guard.admit("claude", Start::Auto, at(11)), Verdict::Tripped { first: false });
    assert_eq!(guard.admit("codex", Start::Auto, at(11)), Verdict::Start, "per harness");
    assert_eq!(guard.admit("claude", Start::Used, at(12)), Verdict::Start, "a chat refills");
    assert_eq!(guard.admit("claude", Start::Auto, WINDOW + at(1)), Verdict::Start);
}
