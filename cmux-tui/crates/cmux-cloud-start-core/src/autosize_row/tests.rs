use serde_json::{Value, json};

use super::*;

/// A frame's data as cmux-platform `autoSizeEventData` sends it.
fn data(kind: &str, extra: Value) -> Value {
    let mut base = json!({
        "v": 1,
        "machine": "vm_a",
        "record": "rec_1",
        "team": "t1",
        "creator": "u1",
        "kind": kind,
        "reason": "memory",
        "reason_text": "it ran out of memory",
        "from": {"vcpu": 2, "mem_gib": 4, "disk_gib": 20, "hourly_usd": 0.148},
        "hourly_usd": 0.148,
        "line": "Machine grew to 4 vCPU / 8 GiB (it ran out of memory), now $0.296 an hour",
        "at": 1_795_600_000_000u64
    });
    for (key, value) in extra.as_object().unwrap() {
        base[key] = value.clone();
    }
    base
}

fn event(value: Value) -> Event {
    serde_json::from_value(value).unwrap()
}

fn grow() -> Event {
    event(data(
        "grow",
        json!({"to": {"vcpu": 4, "mem_gib": 8, "disk_gib": 20, "hourly_usd": 0.296}, "hourly_usd": 0.296}),
    ))
}

fn plan_hold(at: u64) -> Event {
    event(data(
        "hold",
        json!({
            "hold": "at_plan_limit",
            "upgrade": {"plan": "next_pro", "label": "Pro", "maxVcpu": 8, "maxMemGiB": 32, "maxDiskGiB": 128},
            "line": "This machine needs more than your plan allows (it ran out of memory); it stays at 2 vCPU / 4 GiB. Upgrade to Pro for 8 vCPU / 32 GiB.",
            "at": at
        }),
    ))
}

#[test]
fn a_grow_reads_its_new_shape_rate_and_reason() {
    let row = row(&grow(), None).unwrap();
    assert_eq!(row.kind, Kind::Grow);
    assert_eq!(row.cause, Cause::Memory);
    assert_eq!(row.hourly_usd, 0.296);
    assert_eq!(row.rate_change_usd, 0.148);
    assert_eq!(row.offer, None);
    assert_eq!(row.hold, None);
    assert_eq!(row.key, "rec_1:grow:1795600000000");
    assert_eq!(row.shape_now(), Shape { vcpu: 4.0, memory_gib: 8.0 });
    assert_eq!(row.why().map(|why| why.reason), Some(Reason::GrewForMemory));
}

#[test]
fn a_shrink_is_a_lower_rate_and_no_memory_reason() {
    let shrink = event(data(
        "shrink",
        json!({
            "reason": "idle", "reason_text": "it was idle",
            "from": {"vcpu": 4, "mem_gib": 8, "disk_gib": 20, "hourly_usd": 0.296},
            "to": {"vcpu": 2, "mem_gib": 4, "disk_gib": 20, "hourly_usd": 0.148},
            "machine": "vm_b"
        }),
    ));
    let row = row(&shrink, None).unwrap();
    assert_eq!(row.rate_change_usd, -0.148);
    assert_eq!(row.cause, Cause::Idle);
    assert_eq!(row.machine, "vm_b", "after a shrink the frame names the new machine");
    assert_eq!(row.shape_now(), Shape { vcpu: 2.0, memory_gib: 4.0 });
    assert_eq!(row.why(), None);
}

#[test]
fn a_hold_at_the_plan_limit_offers_the_plan_above_to_its_creator_only() {
    let held = plan_hold(5);
    let mine = row(&held, Some("u1")).unwrap();
    assert_eq!(mine.hold, Some(Hold::AtPlanLimit));
    assert_eq!(mine.rate_change_usd, 0.0);
    assert_eq!(mine.shape_now(), Shape { vcpu: 2.0, memory_gib: 4.0 });
    assert_eq!(
        mine.offer,
        Some(Offer::Upgrade {
            plan: "next_pro".into(),
            label: "Pro".into(),
            vcpu: 8.0,
            mem_gib: 32.0
        })
    );
    assert_eq!(row(&held, None).unwrap().offer, mine.offer);
    assert_eq!(row(&held, Some("u2")).unwrap().offer, None, "a shared view never offers it");
}

#[test]
fn a_hold_with_no_plan_above_or_another_code_offers_nothing() {
    let top = event(data("hold", json!({"hold": "at_plan_limit", "upgrade": null})));
    assert_eq!(row(&top, None).unwrap().offer, None);
    let busy = event(data("hold", json!({"hold": "resize_in_progress"})));
    let row = row(&busy, None).unwrap();
    assert_eq!(row.hold, Some(Hold::Other { name: "resize_in_progress".into() }));
    assert_eq!(row.offer, None);
    let json = serde_json::to_value(&row).unwrap();
    assert_eq!(json["hold"], json!({"code": "other", "name": "resize_in_progress"}));
}

#[test]
fn a_newer_wire_version_or_an_unknown_reason_is_handled() {
    assert_eq!(row(&event(data("grow", json!({"v": 2}))), None), None);
    let odd = event(data("grow", json!({"reason": "gpu"})));
    assert_eq!(row(&odd, None).unwrap().cause, Cause::Unknown);
    assert!(serde_json::from_value::<Event>(data("explode", json!({}))).is_err());
}

#[test]
fn a_resend_is_one_row_and_a_repeated_hold_counts_up() {
    let first = row(&grow(), None).unwrap();
    let rows = push(Vec::new(), first.clone());
    let rows = push(rows, first);
    assert_eq!(rows.len(), 1);

    let rows = push(rows, row(&plan_hold(10), None).unwrap());
    let rows = push(rows, row(&plan_hold(20), None).unwrap());
    let rows = push(rows, row(&plan_hold(30), None).unwrap());
    assert_eq!(rows.len(), 2);
    assert_eq!((rows[1].count, rows[1].at_ms, rows[1].last_at_ms), (3, 10, 30));

    // A grow in between starts a new row; the next hold is its own row again.
    let grew_again = event(data("grow", json!({"at": 40, "to": {"vcpu": 4, "mem_gib": 8}})));
    let rows = push(rows, row(&grew_again, None).unwrap());
    let rows = push(rows, row(&plan_hold(50), None).unwrap());
    assert_eq!(rows.iter().map(|row| row.count).collect::<Vec<_>>(), vec![1, 3, 1, 1]);
}

#[test]
fn only_the_newest_rows_stay() {
    let mut rows = Vec::new();
    for at in 1..=(MAX_ROWS as u64 + 5) {
        let kind = if at % 2 == 0 { "grow" } else { "shrink" };
        rows = push(rows, row(&event(data(kind, json!({"at": at}))), None).unwrap());
    }
    assert_eq!(rows.len(), MAX_ROWS);
    assert_eq!(rows[0].at_ms, 6);
}
