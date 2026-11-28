//! Ports of CmuxNextDesignTests/BackdropTimeOfDayTests.swift.

use super::*;

const SF: Location = Location { latitude: 37.7749, longitude: -122.4194 };
const TROMSO: Location = Location { latitude: 69.6496, longitude: 18.956 };

fn zone(name: &str) -> Zone {
    Zone::Named(name.parse().unwrap())
}

fn at(zone: Zone, y: i32, m: u32, d: u32, h: u32, min: u32) -> f64 {
    let wall = NaiveDate::from_ymd_opt(y, m, d).unwrap().and_hms_opt(h, min, 0).unwrap();
    zone.local_to_utc(wall.and_utc().timestamp() as f64)
}

fn minutes_off(t: Option<f64>, zone: Zone, h: u32, m: u32) -> f64 {
    let t = t.unwrap();
    let date = zone.date_at(t);
    let target = at(zone, date.year(), date.month(), date.day(), h, m);
    (t - target).abs() / 60.0
}

fn tod(entries: &[(&str, &str)]) -> TimeOfDay {
    TimeOfDay::parse(entries.iter().copied(), |_| true).unwrap()
}

#[test]
fn sun_times_match_noaa_within_two_minutes() {
    let z = zone("America/Los_Angeles");
    let june = SF.sun_events(z.start_of_day(NaiveDate::from_ymd_opt(2026, 6, 21).unwrap()));
    assert!(minutes_off(june.sunrise, z, 5, 48) <= 2.0);
    assert!(minutes_off(Some(june.noon), z, 13, 12) <= 2.0);
    assert!(minutes_off(june.sunset, z, 20, 35) <= 2.0);
    let dec = SF.sun_events(z.start_of_day(NaiveDate::from_ymd_opt(2026, 12, 21).unwrap()));
    assert!(minutes_off(dec.sunrise, z, 7, 21) <= 2.0);
    assert!(minutes_off(Some(dec.noon), z, 12, 8) <= 2.0);
    assert!(minutes_off(dec.sunset, z, 16, 54) <= 2.0);
    assert!(dec.dawn.unwrap() < dec.sunrise.unwrap());
    assert!(dec.dusk.unwrap() > dec.sunset.unwrap());
    let high = SF.sun_position(june.noon);
    assert!((high.altitude - 75.7).abs() < 0.5);
    assert!((high.azimuth - 180.0).abs() < 1.0);
}

#[test]
fn polar_days_skip_the_missing_events() {
    let z = zone("Europe/Oslo");
    let start = |m, d| z.start_of_day(NaiveDate::from_ymd_opt(2026, m, d).unwrap());
    let winter = TROMSO.sun_events(start(12, 21));
    assert!(winter.sunrise.is_none() && winter.sunset.is_none());
    assert!(winter.dawn.is_some() && winter.dusk.is_some());
    let summer = TROMSO.sun_events(start(6, 21));
    assert!(summer.sunrise.is_none() && summer.sunset.is_none() && summer.dusk.is_none());

    let schedule = tod(&[("07:00", "day"), ("sunset", "night")]);
    let evening = at(z, 2026, 12, 21, 20, 0);
    assert_eq!(schedule.resolve(evening, Some(TROMSO), z).0.as_deref(), Some("day"));
    let pacific = zone("America/Los_Angeles");
    let sf_evening = at(pacific, 2026, 12, 21, 20, 0);
    assert_eq!(schedule.resolve(sf_evening, Some(SF), pacific).0.as_deref(), Some("night"));
}

#[test]
fn schedule_keys_parse() {
    assert_eq!(When::parse("07:00"), Some(When::Clock { minutes: 420 }));
    assert_eq!(When::parse("9:05"), Some(When::Clock { minutes: 545 }));
    assert_eq!(
        When::parse("sunset-30m"),
        Some(When::Sun { event: SunEvent::Sunset, offset: -1_800.0 })
    );
    assert_eq!(
        When::parse("sunrise+1h"),
        Some(When::Sun { event: SunEvent::Sunrise, offset: 3_600.0 })
    );
    assert_eq!(When::parse("dusk"), Some(When::Sun { event: SunEvent::Dusk, offset: 0.0 }));
    for bad in [
        "24:00",
        "07:60",
        "7",
        "sunset-",
        "sunset+30s",
        "midnight",
        "Sunset",
        "sunrise+25h",
        "07:0",
        "٠٧:٠٠",
    ] {
        assert_eq!(When::parse(bad), None, "{bad}");
    }
}

#[test]
fn schedule_resolves_in_local_time() {
    for name in ["America/Los_Angeles", "Asia/Tokyo", "Australia/Lord_Howe"] {
        let z = zone(name);
        let schedule = tod(&[("07:00", "morning"), ("12:30", "noon"), ("19:00", "night")]);
        let (value, next) = schedule.resolve(at(z, 2026, 5, 10, 5, 59), None, z);
        assert_eq!(value.as_deref(), Some("night"), "{name}");
        assert_eq!(next, Some(at(z, 2026, 5, 10, 7, 0)), "{name}");
        let shown = |h, m| schedule.resolve(at(z, 2026, 5, 10, h, m), None, z);
        assert_eq!(shown(7, 0).0.as_deref(), Some("morning"));
        assert_eq!(shown(12, 29).0.as_deref(), Some("morning"));
        let afternoon = shown(12, 30);
        assert_eq!(afternoon.0.as_deref(), Some("noon"));
        assert_eq!(afternoon.1, Some(at(z, 2026, 5, 10, 19, 0)));
        let mixed = tod(&[("07:00", "day"), ("sunset", "night")]);
        assert_eq!(mixed.resolve(at(z, 2026, 5, 10, 23, 0), None, z).0.as_deref(), Some("day"));
    }
}

#[test]
fn daylight_saving_gaps_and_repeats() {
    let z = zone("America/Los_Angeles");
    let spring =
        tod(&[("02:30", "late"), ("12:00", "day")]).resolve(at(z, 2026, 3, 8, 1, 0), None, z);
    assert_eq!(spring.0.as_deref(), Some("day"));
    assert_eq!(spring.1, Some(1_772_964_000.0));

    let fall_schedule = tod(&[("01:30", "late"), ("12:00", "day")]);
    let fall = fall_schedule.resolve(at(z, 2026, 11, 1, 0, 30), None, z);
    assert_eq!(fall.1, Some(1_793_521_800.0));
    let later = fall_schedule.resolve(1_793_525_400.0 + 60.0, None, z);
    assert_eq!(later.0.as_deref(), Some("late"));
    assert_eq!(later.1, Some(at(z, 2026, 11, 1, 12, 0)));
}

#[test]
fn half_hour_daylight_saving_gap() {
    let z = zone("Australia/Lord_Howe");
    let schedule = tod(&[("02:15", "late"), ("12:00", "day")]);
    let next = schedule.resolve(at(z, 2026, 10, 4, 1, 0), None, z).1.unwrap();
    let wall = next + f64::from(z.offset_at(next));
    let minute_of_day = (wall.rem_euclid(86_400.0) / 60.0) as u32;
    assert_eq!(minute_of_day, 2 * 60 + 30);
}

#[test]
fn locations_parse() {
    assert_eq!(
        Location::parse("37.77,-122.42"),
        Some(Location { latitude: 37.77, longitude: -122.42 })
    );
    assert_eq!(
        Location::parse(" -33.87 , 151.21 "),
        Some(Location { latitude: -33.87, longitude: 151.21 })
    );
    for bad in ["", "37.77", "91,0", "0,181", "north,east", "1,2,3"] {
        assert_eq!(Location::parse(bad), None, "{bad}");
    }
}

#[test]
fn rotation_every_n_minutes() {
    let z = zone("Asia/Tokyo");
    let rotation = Rotation::parse("45").unwrap();
    assert_eq!(rotation, Rotation::Minutes(45));
    assert_eq!(Rotation::from_minutes(90.0), Some(Rotation::Minutes(90)));
    assert_eq!(Rotation::parse("0"), None);
    assert_eq!(Rotation::parse("1441"), None);
    assert_eq!(Rotation::parse("15m"), Some(Rotation::QuarterHour));
    assert_eq!(Rotation::parse("hourly").map(Rotation::raw).as_deref(), Some("hourly"));
    let start = at(z, 2026, 5, 10, 10, 10);
    assert_eq!(rotation.next_turn(start, z), at(z, 2026, 5, 10, 10, 30));
    let picks: std::collections::BTreeSet<_> =
        (0..4).map(|i| rotation.index(4, start + f64::from(i) * 2_700.0, z).unwrap()).collect();
    assert_eq!(picks.len(), 4);
    assert_eq!(rotation.index(0, start, z), None);
}

#[test]
fn daily_turns_at_local_midnight_and_strides_coprime() {
    let z = zone("America/Los_Angeles");
    let noon = at(z, 2026, 11, 1, 12, 0);
    assert_eq!(Rotation::Daily.next_turn(noon, z), at(z, 2026, 11, 2, 0, 0));
    assert_eq!(
        Rotation::Daily.period(at(z, 2026, 11, 2, 0, 0), z),
        Rotation::Daily.period(noon, z) + 1
    );
    assert_eq!(daily_stride(97), 89);
    assert_eq!(daily_stride(150), 97);
}
