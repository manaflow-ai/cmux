//! Daylight saving in the local zone. This test binary sets `TZ` before the
//! first time call, so it does not depend on the machine's zone.

use cmux_automations::{Trigger, Zone};

fn pacific() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    // SAFETY: set once, before any thread of this binary reads the zone.
    ONCE.call_once(|| unsafe { std::env::set_var("TZ", "America/Los_Angeles") });
}

#[test]
fn daily_nine_am_stays_nine_am_across_the_fall_back() {
    pacific();
    // US DST ends Sunday 2026-11-01 02:00 local.
    let sat_9 = Zone::Local.timestamp(2026, 10, 31, 9, 0);
    let t = Trigger::Cron { expr: "0 9 * * *".into(), tz: "local".into() };
    let sun_9 = t.next_after(sat_9).unwrap().unwrap();
    assert_eq!(sun_9 - sat_9, 25 * 3_600, "the day with the repeated hour is 25 hours long");
    let c = Zone::Local.civil(sun_9);
    assert_eq!((c.day, c.hour, c.minute), (1, 9, 0));
}

#[test]
fn a_time_in_the_spring_forward_gap_fires_once_that_day() {
    pacific();
    // US DST starts Sunday 2027-03-14 02:00 local: 02:30 does not exist.
    let sat = Zone::Local.timestamp(2027, 3, 13, 12, 0);
    let t = Trigger::Cron { expr: "30 2 * * *".into(), tz: "local".into() };
    let first = t.next_after(sat).unwrap().unwrap();
    let c = Zone::Local.civil(first);
    assert_eq!((c.month, c.day), (3, 14), "the gap day still gets its run");
    let second = t.next_after(first).unwrap().unwrap();
    let c2 = Zone::Local.civil(second);
    assert_eq!((c2.day, c2.hour, c2.minute), (15, 2, 30));
}
