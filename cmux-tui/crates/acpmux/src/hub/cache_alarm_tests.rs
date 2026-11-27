use super::*;
use serde_json::json;

fn turn(read: u64, write: u64, at_ms: u64, declared: bool) -> Turn {
    Turn { read, write, input: 100, at_ms, declared }
}

#[test]
fn a_collapse_right_after_a_warm_turn_is_churn() {
    let warm = turn(90_000, 1_000, 0, false);
    let cold = turn(0, 95_000, 60_000, false);
    assert_eq!(judge(Some(&warm), &cold), Verdict::Collapse(95_100));
}

#[test]
fn a_boundary_explains_a_collapse() {
    let warm = turn(90_000, 1_000, 0, false);
    assert_eq!(judge(Some(&warm), &turn(0, 95_000, 60_000, true)), Verdict::Declared);
    // The cache lapsed on its own past five minutes.
    assert_eq!(judge(Some(&warm), &turn(0, 95_000, 6 * 60_000, false)), Verdict::Declared);
}

#[test]
fn no_baseline_a_small_context_or_a_cold_start_is_quiet() {
    let cold = turn(0, 95_000, 1, false);
    assert_eq!(judge(None, &cold), Verdict::Quiet);
    let warm = turn(90_000, 1_000, 0, false);
    assert_eq!(judge(Some(&warm), &turn(0, 5_000, 1, false)), Verdict::Quiet);
    assert_eq!(judge(Some(&cold), &turn(0, 95_000, 2, false)), Verdict::Quiet);
    assert_eq!(judge(Some(&warm), &turn(80_000, 2_000, 2, false)), Verdict::Quiet);
}

fn result(read: u64, write: u64) -> Value {
    json!({"cacheReadTokens": read, "cacheWriteTokens": write, "inputTokens": 100, "turnCount": 5})
}

#[test]
fn observe_counts_on_the_turn_result_and_off_does_nothing() {
    let id = "cache-alarm-observe";
    let mut a = result(90_000, 1_000);
    observe(id, &mut a, 0, true);
    assert_eq!(a["harnessMagic"][FEATURE]["observed"], 1);
    let mut b = result(0, 95_000);
    observe(id, &mut b, 30_000, true);
    assert_eq!(b["harnessMagic"][FEATURE]["collapses"], 1);
    assert_eq!(b["harnessMagic"][FEATURE]["unreadTokens"], 95_100);
    let mut off = result(0, 95_000);
    observe(id, &mut off, 40_000, false);
    assert!(off.get("harnessMagic").is_none());
    let mut none = json!({"status": "completed"});
    observe(id, &mut none, 50_000, true);
    assert!(none.get("harnessMagic").is_none());
    forget(id);
}

#[test]
fn a_surgery_run_declares_the_boundary() {
    let id = "cache-alarm-surgery";
    let mut a = result(90_000, 1_000);
    observe(id, &mut a, 0, true);
    let mut b = result(0, 95_000);
    b["harnessMagic.surgery.runs"] = json!(1);
    observe(id, &mut b, 10_000, true);
    assert_eq!(b["harnessMagic"][FEATURE]["declared"], 1);
    assert!(b["harnessMagic"][FEATURE].get("collapses").is_none());
    forget(id);
}

#[test]
fn off_drops_the_harness_per_call_counts_too() {
    let mut msg = result(0, 95_000);
    msg["harnessMagic"] = json!({"cacheAlarm": {"callChurn": 1}, "dedupe": {"readsStubbed": 2}});
    observe("cache-alarm-off", &mut msg, 0, false);
    assert!(msg["harnessMagic"].get(FEATURE).is_none(), "{msg}");
    assert_eq!(msg["harnessMagic"]["dedupe"]["readsStubbed"], 2);
    let mut only = result(0, 95_000);
    only["harnessMagic"] = json!({"cacheAlarm": {"callChurn": 1}});
    observe("cache-alarm-off", &mut only, 0, false);
    assert!(only.get("harnessMagic").is_none(), "{only}");
}

#[test]
fn on_keeps_the_per_call_counts_beside_the_turn_ones() {
    let id = "cache-alarm-on-call";
    let mut msg = result(90_000, 1_000);
    msg["harnessMagic"] = json!({"cacheAlarm": {"callChurn": 1}});
    observe(id, &mut msg, 0, true);
    assert_eq!(msg["harnessMagic"][FEATURE]["callChurn"], 1);
    assert_eq!(msg["harnessMagic"][FEATURE]["observed"], 1);
    forget(id);
}
