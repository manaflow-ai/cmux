//! Schedule math: cron, presets, intervals, one-shots, catch-up after sleep.
//! Times are UTC here, so the cases hold on any machine; daylight saving is
//! in `dst.rs`, which runs itself under a fixed `TZ`.

use cmux_automations::{CatchUp, CronExpr, Trigger, Zone, plan_fires};

/// 2026-10-30 09:00:00 UTC, a Friday.
const FRI_0900: i64 = 1_793_350_800;
const MIN: i64 = 60;
const HOUR: i64 = 3_600;
const DAY: i64 = 86_400;

fn cron(expr: &str) -> Trigger {
    Trigger::Cron { expr: expr.into(), tz: "UTC".into() }
}

#[test]
fn fri_0900_is_what_the_constant_says() {
    let c = Zone::Utc.civil(FRI_0900);
    assert_eq!((c.year, c.month, c.day, c.hour, c.minute, c.weekday), (2026, 10, 30, 9, 0, 5));
}

#[test]
fn cron_parses_lists_ranges_steps_and_names() {
    assert!(CronExpr::parse("*/15 9-17 * * mon-fri").is_ok());
    assert!(CronExpr::parse("0 9 1,15 jan,jul *").is_ok());
    assert!(CronExpr::parse("@daily").is_ok());
    assert!(CronExpr::parse("0 9 * * 7").is_ok(), "7 is Sunday too");
    for bad in [
        "",
        "* * * *",
        "* * * * * *",
        "60 * * * *",
        "* 24 * * *",
        "* * 0 * *",
        "* * * 13 *",
        "*/0 * * * *",
        "5-1 * * * *",
        "x * * * *",
    ] {
        assert!(CronExpr::parse(bad).is_err(), "{bad:?} must be refused");
    }
}

#[test]
fn cron_next_fire() {
    // 09:00 weekdays: from Friday 09:00 the next is Monday 09:00.
    assert_eq!(cron("0 9 * * 1-5").next_after(FRI_0900).unwrap(), Some(FRI_0900 + 3 * DAY));
    // Strictly after: one minute before 09:00 gives 09:00.
    assert_eq!(cron("0 9 * * *").next_after(FRI_0900 - MIN).unwrap(), Some(FRI_0900));
    // Every 15 minutes.
    assert_eq!(cron("*/15 * * * *").next_after(FRI_0900 + 1).unwrap(), Some(FRI_0900 + 15 * MIN));
    // Sunday written as 7.
    assert_eq!(
        cron("30 8 * * 7").next_after(FRI_0900).unwrap(),
        Some(FRI_0900 + 2 * DAY - 30 * MIN)
    );
    // Day of month and day of week both set: either matches (cron's OR rule).
    // Next 1st of the month is Sunday Nov 1; next Monday is Nov 2.
    assert_eq!(cron("0 9 1 * 1").next_after(FRI_0900).unwrap(), Some(FRI_0900 + 2 * DAY));
    // Feb 30 never happens.
    assert_eq!(cron("0 0 30 2 *").next_after(FRI_0900).unwrap(), None);
}

#[test]
fn presets_are_cron() {
    let t = Trigger::preset_daily(9, 0, Zone::Utc);
    assert_eq!(t.next_after(FRI_0900).unwrap(), Some(FRI_0900 + DAY));
    let t = Trigger::preset_weekdays(9, 0, Zone::Utc);
    assert_eq!(t.next_after(FRI_0900).unwrap(), Some(FRI_0900 + 3 * DAY));
    let t = Trigger::preset_weekly(1, 9, 0, Zone::Utc);
    assert_eq!(t.next_after(FRI_0900).unwrap(), Some(FRI_0900 + 3 * DAY));
    let t = Trigger::preset_hourly(Zone::Utc);
    assert_eq!(t.next_after(FRI_0900).unwrap(), Some(FRI_0900 + HOUR));
}

#[test]
fn every_is_anchored_to_creation() {
    let t = Trigger::Every { seconds: 30 * MIN as u64, anchor: FRI_0900 + 7 };
    assert_eq!(t.next_after(FRI_0900).unwrap(), Some(FRI_0900 + 7));
    assert_eq!(t.next_after(FRI_0900 + 7).unwrap(), Some(FRI_0900 + 7 + 30 * MIN));
    assert!(Trigger::Every { seconds: 59, anchor: 0 }.validate().is_err(), "floor is one minute");
}

#[test]
fn at_fires_once_and_manual_never() {
    let t = Trigger::At { at: FRI_0900 };
    assert_eq!(t.next_after(FRI_0900 - 1).unwrap(), Some(FRI_0900));
    assert_eq!(t.next_after(FRI_0900).unwrap(), None);
    assert_eq!(Trigger::Manual.next_after(0).unwrap(), None);
}

#[test]
fn named_zone_is_refused_locally_with_a_reason() {
    let t = Trigger::Cron { expr: "0 9 * * *".into(), tz: "America/Los_Angeles".into() };
    let err = t.validate().unwrap_err().to_string();
    assert!(err.contains("cmux Cloud"), "{err}");
}

#[test]
fn on_time_fire_runs() {
    let plan =
        plan_fires(&cron("0 9 * * *"), FRI_0900 - MIN, FRI_0900 + 5, CatchUp::default()).unwrap();
    assert_eq!(plan.run, vec![FRI_0900]);
    assert!(plan.skipped.is_empty());
    assert_eq!(plan.handled_through, FRI_0900 + 5);
}

#[test]
fn nothing_due_does_nothing() {
    let plan =
        plan_fires(&cron("0 9 * * *"), FRI_0900, FRI_0900 + HOUR, CatchUp::default()).unwrap();
    assert!(plan.run.is_empty() && plan.skipped.is_empty());
}

#[test]
fn latest_catches_up_once_and_records_the_rest() {
    // Asleep from Monday 08:00 to Friday 10:00: Mon..Fri 09:00 missed.
    let woke = FRI_0900 + HOUR;
    let plan = plan_fires(
        &cron("0 9 * * *"),
        FRI_0900 - 4 * DAY - HOUR,
        woke,
        CatchUp::Latest { window_seconds: DAY as u64 },
    )
    .unwrap();
    assert_eq!(plan.run, vec![FRI_0900], "one catch-up for the latest miss");
    let skipped: Vec<i64> = plan.skipped.iter().map(|(t, _)| *t).collect();
    assert_eq!(
        skipped,
        vec![FRI_0900 - 4 * DAY, FRI_0900 - 3 * DAY, FRI_0900 - 2 * DAY, FRI_0900 - DAY]
    );
    assert!(plan.skipped.iter().all(|(_, why)| why == "superseded"));
}

#[test]
fn latest_outside_the_window_is_stale() {
    let plan = plan_fires(
        &cron("0 9 * * *"),
        FRI_0900 - MIN,
        FRI_0900 + 2 * DAY - 2 * HOUR,
        CatchUp::Latest { window_seconds: 6 * HOUR as u64 },
    )
    .unwrap();
    assert!(plan.run.is_empty());
    let last = plan.skipped.last().unwrap();
    assert_eq!(last, &(FRI_0900 + DAY, "stale".to_string()));
}

#[test]
fn all_runs_each_missed_time_oldest_first_capped() {
    let plan = plan_fires(
        &cron("0 * * * *"),
        FRI_0900 - MIN,
        FRI_0900 + 4 * HOUR + 5,
        CatchUp::All { max: 3 },
    )
    .unwrap();
    assert_eq!(plan.run, vec![FRI_0900 + 2 * HOUR, FRI_0900 + 3 * HOUR, FRI_0900 + 4 * HOUR]);
    assert_eq!(
        plan.skipped,
        vec![(FRI_0900, "superseded".to_string()), (FRI_0900 + HOUR, "superseded".to_string())]
    );
}

#[test]
fn none_skips_every_late_time() {
    let plan =
        plan_fires(&cron("*/10 * * * *"), FRI_0900 - MIN, FRI_0900 + 25 * MIN, CatchUp::None)
            .unwrap();
    assert!(plan.run.is_empty());
    assert_eq!(plan.skipped.len(), 3);
    assert!(plan.skipped.iter().all(|(_, why)| why == "machine_asleep"));
}

#[test]
fn a_month_asleep_on_a_minute_schedule_stays_bounded() {
    let plan =
        plan_fires(&cron("* * * * *"), FRI_0900, FRI_0900 + 30 * DAY, CatchUp::default()).unwrap();
    assert_eq!(plan.run, vec![FRI_0900 + 30 * DAY]);
    assert!(plan.skipped.len() <= 50, "skips are capped, not 43,000 rows");
    assert!(plan.skipped_uncounted > 40_000);
}
