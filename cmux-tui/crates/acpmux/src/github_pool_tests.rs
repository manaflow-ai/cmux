use super::*;

const NOW: u64 = 1_800_000_000_000;

fn reading(remaining: u64) -> Reading {
    Reading { limit: 5000, remaining, reset_ms: NOW + HOUR_MS, read_ms: NOW }
}

#[test]
fn a_caller_over_its_cap_is_refused_only_while_the_pool_is_low() {
    let mut b = Budget::default();
    b.set_pool_reading(Pool::Core, reading(4000));
    // 170 a minute pace: spread the reads over the hour.
    for i in 0..CALLER_READS_PER_HOUR as u64 + 10 {
        let mut fresh = reading(4000);
        fresh.read_ms = NOW + i * 5000;
        b.set_pool_reading(Pool::Core, fresh);
        assert!(
            b.admit_read("lane/a", Pool::Core, true, NOW + i * 5000).is_ok(),
            "pool high: no cap"
        );
    }
    let t = NOW + 3_100_000;
    // Over the reserve but under the floor (15% of the limit with the hour still ahead).
    b.set_pool_reading(
        Pool::Core,
        Reading { limit: 5000, remaining: 600, reset_ms: t + HOUR_MS, read_ms: t },
    );
    let e = b.admit_read("lane/a", Pool::Core, true, t).unwrap_err();
    assert_eq!(e.code, -32044);
    let data = e.data.unwrap();
    assert_eq!(data["reason"], "github.budget.caller");
    assert_eq!(data["caller"], "lane/a");
    assert!(data["retryAfterMs"].as_u64().unwrap() > 0);
    assert!(b.admit_read("lane/b", Pool::Core, true, t).is_ok(), "another caller still reads");
}

#[test]
fn the_hard_reserve_refuses_every_read() {
    let mut b = Budget::default();
    b.set_pool_reading(Pool::Core, reading(HARD_RESERVE));
    let e = b.admit_read("lane/a", Pool::Core, true, NOW).unwrap_err();
    assert_eq!(e.data.unwrap()["reason"], "github.budget.pool");
    // An App token's read draws from another pool.
    assert!(b.admit_read("lane/a", Pool::Core, false, NOW).is_ok());
}

#[test]
fn reads_are_paced_across_callers() {
    let mut b = Budget::default();
    b.set_pool_reading(Pool::Core, reading(5000));
    for i in 0..PACE_PER_MINUTE {
        assert!(b.admit_read(&format!("lane/{i}"), Pool::Core, true, NOW).is_ok());
    }
    let e = b.admit_read("lane/x", Pool::Core, true, NOW + 1).unwrap_err();
    assert_eq!(e.data.unwrap()["reason"], "github.budget.pace");
    assert!(b.admit_read("lane/x", Pool::Core, true, NOW + MINUTE_MS).is_ok());
}

#[test]
fn no_reading_holds_every_caller_to_its_cap() {
    let mut b = Budget::default();
    for i in 0..CALLER_READS_PER_HOUR as u64 {
        assert!(b.admit_read("lane/a", Pool::Core, true, NOW + i * 1000).is_ok());
    }
    let e = b.admit_read("lane/a", Pool::Core, true, NOW + 700_000).unwrap_err();
    assert_eq!(e.data.unwrap()["reason"], "github.budget.caller");
}

#[test]
fn the_floor_shrinks_toward_the_reset() {
    let r = reading(1000);
    assert_eq!(r.floor(NOW), 750);
    assert_eq!(r.floor(NOW + HOUR_MS - 60_000), 100, "never under 2% of the limit");
}

#[test]
fn rate_limit_answer_parses() {
    let body = br#"{"resources":{"core":{"limit":5000,"remaining":4321,"reset":1800003600},"graphql":{"limit":5000,"remaining":120,"reset":1800001800}}}"#;
    let r = parse_reading(body, NOW).unwrap();
    assert_eq!((r.core.limit, r.core.remaining, r.core.reset_ms), (5000, 4321, 1_800_003_600_000));
    let g = r.graphql.unwrap();
    assert_eq!((g.remaining, g.reset_ms), (120, 1_800_001_800_000));
    let core_only = br#"{"resources":{"core":{"limit":5000,"remaining":1,"reset":1800003600}}}"#;
    assert!(parse_reading(core_only, NOW).unwrap().graphql.is_none());
    assert!(parse_reading(b"{}", NOW).is_none());
}

#[test]
fn each_read_is_judged_against_the_pool_it_spends() {
    let mut b = Budget::default();
    b.set_readings(Readings { core: reading(4000), graphql: Some(reading(HARD_RESERVE - 1)) });
    // GraphQL spent: a `--json` view is refused, naming the pool; a REST read still runs.
    let e = b.admit_read("lane/a", Pool::Graphql, true, NOW).unwrap_err();
    let data = e.data.unwrap();
    assert_eq!(data["reason"], "github.budget.pool");
    assert_eq!(data["pool"], "graphql");
    assert!(e.message.contains("graphql pool"), "{}", e.message);
    assert!(b.admit_read("lane/a", Pool::Core, true, NOW).is_ok());
    // Only the pool a read spends is counted down.
    assert_eq!(b.reading(Pool::Core).unwrap().remaining, 3999);
    assert_eq!(b.reading(Pool::Graphql).unwrap().remaining, HARD_RESERVE - 1);
}

#[test]
fn the_actions_counter_is_held_to_core_until_its_own_reading() {
    let mut b = Budget::default();
    b.set_readings(Readings { core: reading(HARD_RESERVE), graphql: Some(reading(5000)) });
    let e = b.admit_read("lane/a", Pool::Actions, true, NOW).unwrap_err();
    assert_eq!(e.data.unwrap()["pool"], "core", "no Actions reading yet: core's");
    b.set_pool_reading(Pool::Actions, reading(3000));
    assert!(b.admit_read("lane/a", Pool::Actions, true, NOW).is_ok());
    assert_eq!(b.reading(Pool::Actions).unwrap().remaining, 2999);
    assert_eq!(b.reading(Pool::Core).unwrap().remaining, HARD_RESERVE);
}

#[test]
fn a_stale_graphql_reading_holds_callers_to_their_cap_not_core() {
    let mut b = Budget::default();
    let mut old = reading(5000);
    old.read_ms = NOW - READING_TTL_MS - 1;
    b.set_readings(Readings { core: reading(5000), graphql: Some(old) });
    for i in 0..CALLER_READS_PER_HOUR as u64 {
        assert!(b.admit_read("lane/a", Pool::Graphql, true, NOW + i * 400).is_ok());
    }
    let e = b.admit_read("lane/a", Pool::Graphql, true, NOW + 300_000).unwrap_err();
    assert_eq!(e.data.unwrap()["reason"], "github.budget.caller");
}

#[test]
fn gh_commands_map_to_the_pool_they_spend() {
    let cases: &[(&[&str], Pool)] = &[
        (&["pr", "view", "1", "--json=number,title", "--repo=o/r"], Pool::Graphql),
        (&["repo", "view", "o/r", "--json=url"], Pool::Graphql),
        (&["pr", "list", "--json", "number"], Pool::Graphql),
        (&["api", "graphql", "-f", "query=x"], Pool::Graphql),
        (&["api", "/graphql"], Pool::Graphql),
        (&["api", "repos/o/r/actions/runs/1/jobs"], Pool::Actions),
        (&["api", "-X", "GET", "repos/o/r/actions/runs?per_page=5"], Pool::Actions),
        (&["run", "view", "1", "--log-failed"], Pool::Actions),
        (&["workflow", "list"], Pool::Actions),
        (&["api", "repos/o/r/pulls/1"], Pool::Core),
        (&["api", "repos/o/actions-tools/pulls"], Pool::Core),
        (&["pr", "diff", "1"], Pool::Core),
    ];
    for (args, pool) in cases {
        assert_eq!(pool_of(args), *pool, "{args:?}");
    }
}
