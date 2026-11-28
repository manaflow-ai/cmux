use super::*;

fn fields(v: Value) -> Map<String, Value> {
    v.as_object().cloned().unwrap()
}

#[test]
fn a_harness_cost_is_the_model_cost_and_adds_to_the_session() {
    let (out, total) = cost_fields(&fields(json!({"costUsd": 0.25})), 4000, None, Some(1.0));
    assert_eq!(out["modelCostUsd"], json!(0.25));
    assert_eq!(out["modelCostSource"], json!("harness"));
    assert_eq!(out["taskCostUsd"], json!(0.25));
    assert_eq!(out["sessionCostUsd"], json!(1.25));
    assert!(out.get("computeCostUsd").is_none(), "no compute off Cloud");
    assert_eq!(total, Some(1.25));
}

#[test]
fn tokens_with_no_harness_cost_are_priced_at_the_table() {
    let usage = json!({"model": "claude-opus-4-5", "inputTokens": 1_000_000, "outputTokens": 0});
    let (out, total) = cost_fields(&fields(usage), 0, None, None);
    assert_eq!(out["modelCostSource"], json!("table"));
    let cost = out["modelCostUsd"].as_f64().unwrap();
    assert!(cost > 0.0, "{out:?}");
    assert_eq!(total, Some(cost));
}

#[test]
fn a_model_the_table_lacks_is_unpriced_not_zero() {
    let usage = json!({"model": "no-such-model-x", "inputTokens": 10});
    let (out, total) = cost_fields(&fields(usage), 1000, None, Some(2.0));
    assert!(out.is_empty(), "{out:?}");
    assert_eq!(total, Some(2.0));
}

#[test]
fn a_cloud_turn_adds_its_compute_at_the_machine_rate() {
    // 4 vCPU and 16 GiB: (4 x 0.04032 + 16 x 0.0129) / 3600 USD a second.
    let rate = compute_usd_per_second(4.0, 16.0);
    let (out, total) = cost_fields(&fields(json!({"costUsd": 0.1})), 60_000, Some(rate), None);
    assert_eq!(out["computeSeconds"], json!(60.0));
    let compute = out["computeCostUsd"].as_f64().unwrap();
    assert!((compute - 60.0 * rate).abs() < 1e-6, "{compute}");
    assert!((out["taskCostUsd"].as_f64().unwrap() - (0.1 + compute)).abs() < 1e-6);
    assert!((total.unwrap() - (0.1 + 60.0 * rate)).abs() < 1e-9);
}

#[test]
fn meminfo_total_is_read_in_kib() {
    assert_eq!(memory_kib("MemTotal:       16384000 kB\nMemFree: 1 kB\n"), Some(16_384_000));
    assert_eq!(memory_kib("MemFree: 1 kB\n"), None);
}
