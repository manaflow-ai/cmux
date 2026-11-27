use super::*;

fn node(name: &str, rent: f64, cold: f64, rtt: f64, account: &str) -> Node {
    Node {
        name: name.into(),
        rent_usd_per_hour: Some(rent),
        warm: false,
        cold_start_s: Some(cold),
        rtt_ms: Some(rtt),
        account: Some(account.into()),
    }
}

fn close(a: f64, b: f64) -> bool {
    (a - b).abs() < 1e-9
}

#[test]
fn each_term_is_priced_as_the_rfd_writes_it() {
    let work = Work {
        expected_run_s: 7200.0,
        turns: 200,
        context_tokens: 150_000,
        cache_account: Some("a".into()),
    };
    let c = cost(&node("vm", 0.756, 90.0, 20.0, "b"), &work, &Prices::LANE);
    assert!(close(c.rent_usd, 1.512), "{c:?}");
    assert!(close(c.cold_start_s, 90.0));
    assert!(close(c.rtt_s, 4.0));
    // 150k tokens at $5/M, written at 1.25x instead of read at 0.1x.
    assert!(close(c.refill_usd, 0.8625), "{c:?}");
    assert!(close(c.total_usd(&Prices::LANE), 1.512 + 0.8625 + 94.0 * 0.004));
    assert!(c.unknown.is_empty());
}

#[test]
fn a_session_stays_on_the_account_that_holds_its_cache() {
    let work = Work { context_tokens: 400_000, cache_account: Some("a".into()), ..Work::default() };
    let same = cost(&node("x", 0.0, 0.0, 0.0, "a"), &work, &Prices::LANE);
    let moved = cost(&node("y", 0.0, 0.0, 0.0, "b"), &work, &Prices::LANE);
    assert_eq!(same.refill_usd, 0.0);
    assert!(moved.refill_usd > 2.0, "{moved:?}");
    // An unknown account is charged the move: a miss is the likely case, never a free one.
    let unknown = Node { account: None, ..node("z", 0.0, 0.0, 0.0, "") };
    assert!(close(cost(&unknown, &work, &Prices::LANE).refill_usd, moved.refill_usd));
}

#[test]
fn new_work_has_no_cache_to_miss() {
    let work = Work { context_tokens: 400_000, cache_account: None, ..Work::default() };
    assert_eq!(cost(&node("y", 0.0, 0.0, 0.0, "b"), &work, &Prices::LANE).refill_usd, 0.0);
}

#[test]
fn a_warm_node_skips_its_cold_start() {
    let work = Work::default();
    let warm = Node { warm: true, cold_start_s: None, ..node("w", 0.0, 0.0, 0.0, "a") };
    let c = cost(&warm, &work, &Prices::LANE);
    assert_eq!(c.cold_start_s, 0.0);
    assert!(!c.unknown.contains(&"cold_start"), "a warm node needs no cold-start reading");
}

#[test]
fn unread_terms_count_zero_and_are_named() {
    let bare = Node { name: "bare".into(), ..Node::default() };
    let c = cost(&bare, &Work::default(), &Prices::LANE);
    assert_eq!(c.unknown, vec!["rent", "cold_start", "rtt"]);
    assert_eq!(c.total_usd(&Prices::LANE), 0.0);
    let bad = Node { rent_usd_per_hour: Some(f64::NAN), rtt_ms: Some(-1.0), ..bare };
    assert_eq!(
        cost(&bad, &Work::default(), &Prices::LANE).unknown,
        vec!["rent", "cold_start", "rtt"]
    );
}

#[test]
fn rank_puts_the_cheapest_first_and_keeps_order_on_ties() {
    let work = Work { expected_run_s: 3600.0, turns: 100, ..Work::default() };
    let nodes = [
        node("dear", 1.512, 60.0, 10.0, "a"),
        node("tie-1", 0.268, 60.0, 10.0, "a"),
        node("tie-2", 0.268, 60.0, 10.0, "a"),
    ];
    let names: Vec<&str> =
        rank(&nodes, &work, &Prices::LANE).iter().map(|(n, _)| n.name.as_str()).collect();
    assert_eq!(names, ["tie-1", "tie-2", "dear"]);
}

#[test]
fn a_long_cold_start_loses_to_rent_on_a_short_task() {
    // A 10-minute task: a paid-for warm machine beats a cheap cold VM that must clone and build.
    let work = Work { expected_run_s: 600.0, turns: 20, ..Work::default() };
    let warm = Node { warm: true, ..node("warm", 0.0, 0.0, 40.0, "a") };
    let cold = node("cold", 0.067, 900.0, 15.0, "a");
    let nodes = [cold, warm];
    assert_eq!(rank(&nodes, &work, &Prices::LANE)[0].0.name, "warm");
}
