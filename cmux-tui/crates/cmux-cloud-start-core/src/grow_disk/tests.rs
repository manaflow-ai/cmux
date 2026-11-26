use super::*;

const GIB: i64 = 1 << 30;

fn sizes(floor: i64, needed: i64) -> Sizes {
    Sizes { floor: Some(floor), needed: Some(needed), max_disk: 256 * GIB as u64 }
}

#[test]
fn disk_rounds_up_to_steps_and_caps() {
    assert_eq!(disk_mb(-5, u64::MAX), 0);
    assert_eq!(disk_mb(0, u64::MAX), 0);
    assert_eq!(disk_mb(1, u64::MAX), 4096);
    assert_eq!(disk_mb(4 * GIB, u64::MAX), 4096);
    assert_eq!(disk_mb(4 * GIB + 1, u64::MAX), 8192);
    assert_eq!(disk_mb(300 * GIB, 256 * GIB as u64), 256 * 1024);
}

#[test]
fn unknown_sizes_do_not_grow() {
    assert_eq!(start(&Sizes { max_disk: 1, ..Sizes::default() }), Next::NotGrown);
    assert_eq!(start(&Sizes { floor: Some(1), max_disk: 1, ..Sizes::default() }), Next::NotGrown);
}

#[test]
fn past_every_plan() {
    assert_eq!(start(&sizes(257 * GIB, 300 * GIB)), Next::PastPlan { size: "xxl".into() });
}

#[test]
fn grows_to_needed() {
    assert_eq!(start(&sizes(20 * GIB, 30 * GIB)), Next::Resize { disk_mb: 32 * 1024 });
    assert_eq!(after(&sizes(20 * GIB, 30 * GIB), &Answer::Done, false), Next::Grown);
}

#[test]
fn locked_retries_at_the_plan_disk() {
    let s = sizes(100 * GIB, 150 * GIB);
    let locked = Answer::Locked { plan_max: Some("lg".into()), largest: Some(128 * GIB as u64) };
    assert_eq!(after(&s, &locked, false), Next::Resize { disk_mb: 128 * 1024 });
    assert_eq!(after(&s, &Answer::Done, true), Next::Grown);
    assert_eq!(after(&s, &locked, true), Next::PastPlan { size: "lg".into() });
    assert_eq!(after(&s, &Answer::Failed, true), Next::NotGrown);
}

#[test]
fn locked_floor_past_plan() {
    let locked = Answer::Locked { plan_max: Some("lg".into()), largest: Some(128 * GIB as u64) };
    assert_eq!(
        after(&sizes(130 * GIB, 195 * GIB), &locked, false),
        Next::PastPlan { size: "lg".into() }
    );
}

#[test]
fn locked_without_plan_or_other_errors() {
    let s = sizes(20 * GIB, 30 * GIB);
    assert_eq!(after(&s, &Answer::Locked { plan_max: None, largest: None }, false), Next::NotGrown);
    assert_eq!(
        after(&s, &Answer::Locked { plan_max: Some("lg".into()), largest: None }, false),
        Next::NotGrown
    );
    assert_eq!(after(&s, &Answer::Failed, false), Next::NotGrown);
}
