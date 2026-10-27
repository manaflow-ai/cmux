use std::time::{Duration, Instant};

use serde_json::json;

use super::*;

fn args(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

#[test]
fn only_a_sandboxed_run_routes_here_so_code_mode_scripts_keep_working() {
    assert!(split(&args(&["run", "script.ts"])).is_none());
    assert!(split(&args(&["run", "script.ts", "--", "--sandboxed"])).is_none());
    assert!(split(&args(&["workspace", "list"])).is_none());
    assert!(split(&args(&["run", "--sandboxed", "hi"])).is_some());
    assert!(split(&args(&["run", "hi", "--sandboxed"])).is_some());
}

#[test]
fn each_wait_fits_before_the_deadline_and_none_starts_after_it() {
    let now = Instant::now();
    // Plenty left: the server waits its full 10 s inside a 30 s socket budget.
    assert_eq!(
        wait_slice(now, now + Duration::from_secs(60), Duration::ZERO),
        Some((Duration::from_millis(10_000), Duration::from_secs(30)))
    );
    // 1.5 s left: server wait, socket budget and the call's margin all end by the deadline.
    let (server, budget) =
        wait_slice(now, now + Duration::from_millis(1_500), Duration::ZERO).unwrap();
    assert_eq!(budget, Duration::from_millis(500));
    // With a second or less left, the call's margin alone would pass the deadline: no call.
    assert_eq!(wait_slice(now, now + Duration::from_secs(1), Duration::ZERO), None);
    assert!(server <= budget);
    assert_eq!(wait_slice(now, now, Duration::ZERO), None);
    assert_eq!(wait_slice(now + Duration::from_secs(1), now, Duration::ZERO), None);
    // `--socket`'s probe comes off the slice: with 6 s left, a 5 s probe and the 1 s margin, no call starts.
    assert_eq!(wait_slice(now, now + Duration::from_secs(6), Duration::from_secs(5)), None);
    let (_, budget) =
        wait_slice(now, now + Duration::from_secs(8), Duration::from_secs(5)).unwrap();
    assert!(budget <= Duration::from_secs(2));
}

#[test]
fn a_receipt_counts_only_when_it_is_this_runs_finished_sandbox_receipt() {
    let full = json!({ "receipt": {
        "schema": "cmux.run.receipt/v1", "runId": "run-1", "environment": "sandboxed",
        "status": "succeeded", "cleanup": "destroyed",
    } });
    assert_eq!(run_receipt(&full, "run-1"), Some(&full["receipt"]));
    for snapshot in [
        json!({}),
        json!({ "receipt": null }),
        json!({ "receipt": "x" }),
        json!({ "receipt": {} }),
        json!({ "receipt": { "schema": "cmux.run.receipt/v1", "runId": "run-1", "environment": "sandboxed", "status": "running", "cleanup": "pending" } }),
        json!({ "receipt": { "schema": "cmux.run.receipt/v1", "runId": "run-2", "environment": "sandboxed", "status": "succeeded", "cleanup": "destroyed" } }),
        json!({ "receipt": { "runId": "run-1", "environment": "sandboxed", "status": "succeeded", "cleanup": "destroyed" } }),
        // A skeleton without the sandboxed environment or a cleanup state is no receipt.
        json!({ "receipt": { "schema": "cmux.run.receipt/v1", "runId": "run-1", "status": "succeeded" } }),
        json!({ "receipt": { "schema": "cmux.run.receipt/v1", "runId": "run-1", "environment": "sandboxed", "status": "succeeded" } }),
    ] {
        assert_eq!(run_receipt(&snapshot, "run-1"), None, "{snapshot}");
    }
}
