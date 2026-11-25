//! The plan's "N of M kept running, X of Y hours" numbers, from `cloud.plan.get` answers.

use serde_json::json;

use super::*;

fn plan(active: i64, max_active: i64, hours_used: Value, minutes: Value) -> Value {
    json!({
        "plan_id": "next_plus",
        "upgrade_plan": "next_pro",
        "limits": {
            "max_active": max_active, "max_saved": 20, "memory_options_mb": [8192],
            "locked_memory_options_mb": [], "vm_hours_included": null,
        },
        "usage": { "active": active, "saved": 3, "vm_hours_used": hours_used, "period_end": 1_798_761_600_000_i64 },
        "included_machine_minutes": minutes,
    })
}

#[test]
fn reads_running_and_hours_from_the_plan() {
    let allowance = read(&plan(3, 8, json!(120.5), json!(90_000)));
    assert_eq!(allowance.running_now, Some(3));
    assert_eq!(allowance.running_limit, Some(8));
    assert_eq!(allowance.hours_used, Some(120.5));
    // 90,000 vCPU-minutes / 60 / 4 vCPUs = 375 standard-machine hours.
    assert_eq!(allowance.hours_included, Some(375.0));
    assert_eq!(allowance.hours_left, Some(254.5));
    assert_eq!(allowance.period_end_ms, Some(1_798_761_600_000));
    assert_eq!(allowance.binds, Binds::Neither);
}

#[test]
fn the_three_plans_hours_divide_by_the_standard_machine() {
    for (minutes, hours) in [(90_000, 375.0), (225_000, 937.5), (900_000, 3_750.0)] {
        assert_eq!(read(&plan(0, 8, json!(0), json!(minutes))).hours_included, Some(hours));
    }
}

#[test]
fn reads_the_plan_wrapped_as_a_read_answer() {
    let inner = plan(1, 8, json!(2), json!(90_000));
    assert_eq!(read(&json!({ "value": inner.clone() })), read(&inner));
    assert_eq!(read(&json!({ "plan": inner.clone() })), read(&inner));
    assert_eq!(read(&json!({ "value": { "plan": inner.clone() } })), read(&inner));
}

#[test]
fn used_up_hours_bind_before_free_slots() {
    let allowance = read(&plan(1, 8, json!(400), json!(90_000)));
    assert_eq!(allowance.hours_left, Some(0.0));
    assert_eq!(allowance.binds, Binds::Hours);
}

#[test]
fn full_slots_bind_while_hours_remain() {
    assert_eq!(read(&plan(8, 8, json!(10), json!(90_000))).binds, Binds::Running);
    // Over the cap (a downgrade mid-month) is full too.
    assert_eq!(read(&plan(9, 8, json!(10), json!(90_000))).binds, Binds::Running);
}

#[test]
fn a_plan_with_no_hour_total_reads_slots_only() {
    // Monthly plans answer included_machine_minutes null and vm_hours_included null today.
    let allowance = read(&plan(2, 32, json!(40), Value::Null));
    assert_eq!(allowance.hours_included, None);
    assert_eq!(allowance.hours_left, None);
    assert_eq!(allowance.hours_used, Some(40.0));
    assert_eq!(allowance.binds, Binds::Neither);
}

#[test]
fn the_classic_hour_limit_is_the_fallback() {
    let mut answer = plan(0, 5, json!(10), Value::Null);
    answer["limits"]["vm_hours_included"] = json!(100);
    assert_eq!(read(&answer).hours_included, Some(100.0));
    assert_eq!(read(&answer).hours_left, Some(90.0));
}

#[test]
fn an_unknown_meter_leaves_hours_left_unknown() {
    let allowance = read(&plan(2, 8, Value::Null, json!(90_000)));
    assert_eq!(allowance.hours_used, None);
    assert_eq!(allowance.hours_included, Some(375.0));
    assert_eq!(allowance.hours_left, None);
    assert_eq!(allowance.binds, Binds::Neither);
}

#[test]
fn bad_fields_drop_themselves() {
    let answer = json!({
        "limits": { "max_active": "8", "vm_hours_included": -1 },
        "usage": { "active": -2, "vm_hours_used": "x", "period_end": 0 },
        "included_machine_minutes": -5,
    });
    assert_eq!(read(&answer), Allowance::default());
    assert_eq!(read(&json!(null)), Allowance::default());
    assert_eq!(read(&json!({ "value": 3 })), Allowance::default());
    assert_eq!(Allowance::default().binds, Binds::Unknown);
}

#[test]
fn encodes_camel_case_for_the_app() {
    let value = to_value(&read(&plan(3, 8, json!(120.5), json!(90_000))));
    assert_eq!(
        value,
        json!({
            "runningNow": 3, "runningLimit": 8, "hoursUsed": 120.5, "hoursIncluded": 375.0,
            "hoursLeft": 254.5, "periodEndMs": 1_798_761_600_000_i64, "binds": "neither",
        })
    );
}
