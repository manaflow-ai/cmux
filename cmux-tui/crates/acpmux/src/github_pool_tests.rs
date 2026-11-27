use super::*;

const NOW: u64 = 1_800_000_000_000;

fn reading(remaining: u64) -> Reading {
    Reading { limit: 5000, remaining, reset_ms: NOW + HOUR_MS, read_ms: NOW }
}

#[test]
fn a_caller_over_its_cap_is_refused_only_while_the_pool_is_low() {
    let mut b = Budget::default();
    b.set_reading(reading(4000));
    // 170 a minute pace: spread the reads over the hour.
    for i in 0..CALLER_READS_PER_HOUR as u64 + 10 {
        let mut fresh = reading(4000);
        fresh.read_ms = NOW + i * 5000;
        b.set_reading(fresh);
        assert!(b.admit_read("lane/a", true, NOW + i * 5000).is_ok(), "pool high: no cap");
    }
    let t = NOW + 3_100_000;
    // Over the reserve but under the floor (15% of the limit with the hour still ahead).
    b.set_reading(Reading { limit: 5000, remaining: 600, reset_ms: t + HOUR_MS, read_ms: t });
    let e = b.admit_read("lane/a", true, t).unwrap_err();
    assert_eq!(e.code, -32044);
    let data = e.data.unwrap();
    assert_eq!(data["reason"], "github.budget.caller");
    assert_eq!(data["caller"], "lane/a");
    assert!(data["retryAfterMs"].as_u64().unwrap() > 0);
    assert!(b.admit_read("lane/b", true, t).is_ok(), "another caller still reads");
}

#[test]
fn the_hard_reserve_refuses_every_read() {
    let mut b = Budget::default();
    b.set_reading(reading(HARD_RESERVE));
    let e = b.admit_read("lane/a", true, NOW).unwrap_err();
    assert_eq!(e.data.unwrap()["reason"], "github.budget.pool");
    // An App token's read draws from another pool.
    assert!(b.admit_read("lane/a", false, NOW).is_ok());
}

#[test]
fn reads_are_paced_across_callers() {
    let mut b = Budget::default();
    b.set_reading(reading(5000));
    for i in 0..PACE_PER_MINUTE {
        assert!(b.admit_read(&format!("lane/{i}"), true, NOW).is_ok());
    }
    let e = b.admit_read("lane/x", true, NOW + 1).unwrap_err();
    assert_eq!(e.data.unwrap()["reason"], "github.budget.pace");
    assert!(b.admit_read("lane/x", true, NOW + MINUTE_MS).is_ok());
}

#[test]
fn no_reading_holds_every_caller_to_its_cap() {
    let mut b = Budget::default();
    for i in 0..CALLER_READS_PER_HOUR as u64 {
        assert!(b.admit_read("lane/a", true, NOW + i * 1000).is_ok());
    }
    let e = b.admit_read("lane/a", true, NOW + 700_000).unwrap_err();
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
    let body = br#"{"resources":{"core":{"limit":5000,"remaining":4321,"reset":1800003600}}}"#;
    let r = parse_reading(body, NOW).unwrap();
    assert_eq!((r.limit, r.remaining, r.reset_ms), (5000, 4321, 1_800_003_600_000));
    assert!(parse_reading(b"{}", NOW).is_none());
}
