//! Parity tests for `cmux_design_core::wallpaper`: the values of the Swift suites the rules came
//! from (BackdropTimeOfDayTests, BackdropDynamicFramesTests, BackdropPlacementTests,
//! BackdropAgentGlowTests, ShaderWallpaperTests, WallpaperLightTests) and cmux-config's shared
//! placement fixture, plus the `wallpaper.*` ops' JSON shapes.

use cmux_design_core::ops::{OpError, call};
use cmux_design_core::wallpaper::art_fit::ArtFit;
use cmux_design_core::wallpaper::dynamic::{self, Frames, Motion, StoreChoice};
use cmux_design_core::wallpaper::glow::{self, Agent, Level};
use cmux_design_core::wallpaper::location::{self, Location};
use cmux_design_core::wallpaper::placement::{self, Choice, Mode, Placement, Rect, Size};
use cmux_design_core::wallpaper::sun::{sun_events, sun_position};
use cmux_design_core::wallpaper::time_of_day::{self, SunEvent, When};
use cmux_design_core::wallpaper::zone::{Transition, Zone};
use cmux_design_core::wallpaper::{light, live, shader, signals};
use serde_json::{Value, json};
use std::collections::BTreeMap;

const SAN_FRANCISCO: Location = Location { latitude: 37.7749, longitude: -122.4194 };
const TROMSO: Location = Location { latitude: 69.6496, longitude: 18.956 };

fn zone(offset: i32, transitions: &[(f64, i32)]) -> Zone {
    Zone {
        offset,
        transitions: transitions.iter().map(|&(at, offset)| Transition { at, offset }).collect(),
    }
}

/// America/Los_Angeles, 2025 to 2027.
fn los_angeles() -> Zone {
    zone(
        -28_800,
        &[
            (1_741_514_400.0, -25_200),
            (1_762_074_000.0, -28_800),
            (1_772_964_000.0, -25_200),
            (1_793_523_600.0, -28_800),
            (1_805_018_400.0, -25_200),
        ],
    )
}

/// Australia/Lord_Howe, 2026: +11 until April, +10:30, +11 from October.
fn lord_howe() -> Zone {
    zone(39_600, &[(1_775_314_800.0, 37_800), (1_791_041_400.0, 39_600)])
}

/// Europe/Oslo, 2026.
fn oslo() -> Zone {
    zone(3_600, &[(1_774_746_000.0, 7_200), (1_792_890_000.0, 3_600)])
}

fn tokyo() -> Zone {
    Zone::fixed(32_400)
}

fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// `calendar.date(from: DateComponents(...))` in `zone`.
fn local(zone: &Zone, y: i64, m: i64, d: i64, h: i64, mi: i64) -> f64 {
    zone.instant((days_from_civil(y, m, d) * 86_400 + h * 3_600 + mi * 60) as f64)
}

/// Minutes between `t` and the local clock time `h:mi` of its day.
fn minutes_off(t: f64, zone: &Zone, h: i64, mi: i64) -> f64 {
    let target = zone.start_of_day(t) + (h * 3_600 + mi * 60) as f64;
    (t - target).abs() / 60.0
}

fn schedule(pairs: &[(&str, &str)]) -> Vec<time_of_day::Entry> {
    let members: BTreeMap<String, String> =
        pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
    time_of_day::parse(&members, |_| true).expect("schedule reads")
}

// MARK: sun and time of day (BackdropTimeOfDayTests)

#[test]
fn sun_times_match_noaa_within_two_minutes() {
    let la = los_angeles();
    let june = sun_events(&SAN_FRANCISCO, local(&la, 2026, 6, 21, 12, 0), &la);
    assert!(minutes_off(june.sunrise.unwrap(), &la, 5, 48) <= 2.0);
    assert!(minutes_off(june.noon, &la, 13, 12) <= 2.0);
    assert!(minutes_off(june.sunset.unwrap(), &la, 20, 35) <= 2.0);
    let december = sun_events(&SAN_FRANCISCO, local(&la, 2026, 12, 21, 12, 0), &la);
    assert!(minutes_off(december.sunrise.unwrap(), &la, 7, 21) <= 2.0);
    assert!(minutes_off(december.noon, &la, 12, 8) <= 2.0);
    assert!(minutes_off(december.sunset.unwrap(), &la, 16, 54) <= 2.0);
    assert!(december.dawn.unwrap() < december.sunrise.unwrap());
    assert!(december.dusk.unwrap() > december.sunset.unwrap());
    let high = sun_position(&SAN_FRANCISCO, june.noon);
    assert!((high.altitude - 75.7).abs() < 0.5, "{high:?}");
    assert!((high.azimuth - 180.0).abs() < 1.0, "{high:?}");
}

#[test]
fn polar_days_skip_the_missing_events() {
    let oslo = oslo();
    let winter = sun_events(&TROMSO, local(&oslo, 2026, 12, 21, 12, 0), &oslo);
    assert!(winter.sunrise.is_none() && winter.sunset.is_none());
    assert!(winter.dawn.is_some() && winter.dusk.is_some());
    let summer = sun_events(&TROMSO, local(&oslo, 2026, 6, 21, 12, 0), &oslo);
    assert!(summer.sunrise.is_none() && summer.sunset.is_none() && summer.dusk.is_none());

    let entries = schedule(&[("07:00", "day"), ("sunset", "night")]);
    let evening = local(&oslo, 2026, 12, 21, 20, 0);
    let resolved = time_of_day::resolve(&entries, evening, Some(&TROMSO), &oslo);
    assert_eq!(resolved.value.as_deref(), Some("day"));
    let la = los_angeles();
    let pacific = local(&la, 2026, 12, 21, 20, 0);
    let resolved = time_of_day::resolve(&entries, pacific, Some(&SAN_FRANCISCO), &la);
    assert_eq!(resolved.value.as_deref(), Some("night"));
}

#[test]
fn schedule_keys_parse() {
    assert_eq!(time_of_day::when("07:00"), Some(When::Clock { minutes: 420 }));
    assert_eq!(time_of_day::when("9:05"), Some(When::Clock { minutes: 545 }));
    assert_eq!(
        time_of_day::when("sunset-30m"),
        Some(When::Sun { event: SunEvent::Sunset, offset: -1_800.0 })
    );
    assert_eq!(
        time_of_day::when("sunrise+1h"),
        Some(When::Sun { event: SunEvent::Sunrise, offset: 3_600.0 })
    );
    assert_eq!(time_of_day::when("dusk"), Some(When::Sun { event: SunEvent::Dusk, offset: 0.0 }));
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
        assert_eq!(time_of_day::when(bad), None, "{bad}");
    }
}

#[test]
fn schedule_resolves_in_local_time() {
    for zone in [los_angeles(), tokyo(), lord_howe()] {
        let entries = schedule(&[("07:00", "morning"), ("12:30", "noon"), ("19:00", "night")]);
        let at = |h, mi| local(&zone, 2026, 5, 10, h, mi);
        let early = time_of_day::resolve(&entries, at(5, 59), None, &zone);
        assert_eq!(early.value.as_deref(), Some("night"));
        assert_eq!(early.next, Some(at(7, 0)));
        let value = |t| time_of_day::resolve(&entries, t, None, &zone).value;
        assert_eq!(value(at(7, 0)).as_deref(), Some("morning"));
        assert_eq!(value(at(12, 29)).as_deref(), Some("morning"));
        let afternoon = time_of_day::resolve(&entries, at(12, 30), None, &zone);
        assert_eq!(afternoon.value.as_deref(), Some("noon"));
        assert_eq!(afternoon.next, Some(at(19, 0)));
        let mixed = schedule(&[("07:00", "day"), ("sunset", "night")]);
        let late = time_of_day::resolve(&mixed, at(23, 0), None, &zone);
        assert_eq!(late.value.as_deref(), Some("day"));
    }
}

#[test]
fn daylight_saving_gaps_and_repeats() {
    let la = los_angeles();
    let entries = schedule(&[("02:30", "late"), ("12:00", "day")]);
    let spring = time_of_day::resolve(&entries, local(&la, 2026, 3, 8, 1, 0), None, &la);
    assert_eq!(spring.value.as_deref(), Some("day"));
    assert_eq!(spring.next, Some(1_772_964_000.0));

    let fall_entries = schedule(&[("01:30", "late"), ("12:00", "day")]);
    let fall = time_of_day::resolve(&fall_entries, local(&la, 2026, 11, 1, 0, 30), None, &la);
    assert_eq!(fall.next, Some(1_793_521_800.0));
    let later = time_of_day::resolve(&fall_entries, 1_793_525_400.0 + 60.0, None, &la);
    assert_eq!(later.value.as_deref(), Some("late"));
    assert_eq!(later.next, Some(local(&la, 2026, 11, 1, 12, 0)));
}

#[test]
fn half_hour_daylight_saving_gap() {
    let howe = lord_howe();
    let entries = schedule(&[("02:15", "late"), ("12:00", "day")]);
    let next =
        time_of_day::resolve(&entries, local(&howe, 2026, 10, 4, 1, 0), None, &howe).next.unwrap();
    assert_eq!(howe.seconds_into_day(next), 2 * 3_600 + 30 * 60);
}

#[test]
fn locations_parse_and_come_from_the_time_zone() {
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
    let table = "# comment\nUS\t+340308-1181434\tAmerica/Los_Angeles\tPacific\nAU\t-3133+15905\tAustralia/Lord_Howe\tLord Howe Island\n";
    let zones = location::parse_zone_table(table);
    let angeles = zones["America/Los_Angeles"];
    assert!((angeles.latitude - 34.0522).abs() < 0.001);
    assert!((angeles.longitude + 118.2428).abs() < 0.001);
    let howe = zones["Australia/Lord_Howe"];
    assert!((howe.latitude + 31.55).abs() < 0.001);
    assert!((howe.longitude - 159.0833).abs() < 0.001);
    assert_eq!(Location::of("GMT+0900", 3_600 * 9, &zones).longitude, 135.0);
    assert_eq!(Location::of("America/Los_Angeles", -28_800, &zones), angeles);
}

// MARK: dynamic pictures (BackdropDynamicFramesTests)

fn at_june_21(h: i64, mi: i64) -> f64 {
    local(&los_angeles(), 2026, 6, 21, h, mi)
}

#[test]
fn solar_frames_follow_the_sun() {
    let plist = json!({
        "si": [
            {"i": 0, "a": -40.0, "z": 0.0}, {"i": 1, "a": 20.0, "z": 80.0},
            {"i": 2, "a": 75.0, "z": 180.0}, {"i": 3, "a": 20.0, "z": 280.0},
        ],
        "ap": {"l": 2, "d": 0},
    });
    let frames = dynamic::read(Some(&plist), None, None, 4).unwrap();
    assert!(frames.solar.len() == 4 && frames.light == 2 && frames.dark == 0);
    let la = los_angeles();
    let frame = |t| frames.frame(t, &SAN_FRANCISCO, &la);
    assert_eq!(frame(at_june_21(1, 0)), 0);
    assert_eq!(frame(at_june_21(8, 0)), 1);
    assert_eq!(frame(at_june_21(13, 10)), 2);
    assert_eq!(frame(at_june_21(18, 0)), 3);
    let change = frames.next_change(at_june_21(8, 0), &SAN_FRANCISCO, &la).unwrap();
    assert!(change > at_june_21(8, 0) && change < at_june_21(12, 0));
    assert_ne!(frame(change), 1);
    assert_eq!(frame(change - 1.0), 1);
}

#[test]
fn clock_frames_follow_the_local_day() {
    let plist = json!({
        "ti": [{"i": 0, "t": 0.25}, {"i": 1, "t": 0.5}, {"i": 2, "t": 0.75}],
        "ap": {"l": 1, "d": 2},
    });
    let frames = dynamic::read(None, Some(&plist), None, 3).unwrap();
    let la = los_angeles();
    let frame = |t| frames.frame(t, &SAN_FRANCISCO, &la);
    assert_eq!(frame(at_june_21(3, 0)), 2);
    assert_eq!(frame(at_june_21(6, 0)), 0);
    assert_eq!(frame(at_june_21(12, 30)), 1);
    assert_eq!(frame(at_june_21(20, 0)), 2);
    let change = frames.next_change(at_june_21(7, 0), &SAN_FRANCISCO, &la).unwrap();
    assert!((change - at_june_21(12, 0)).abs() <= 1.0);
}

#[test]
fn appearance_pairs_follow_the_suns_altitude() {
    let plist = json!({"l": 0, "d": 1});
    let frames = dynamic::read(None, None, Some(&plist), 2).unwrap();
    let la = los_angeles();
    assert_eq!(frames.frame(at_june_21(12, 0), &SAN_FRANCISCO, &la), 0);
    assert_eq!(frames.frame(at_june_21(23, 0), &SAN_FRANCISCO, &la), 1);
}

#[test]
fn reading_frames_keeps_the_first_extremes_and_drops_bad_indices() {
    // A still picture has no frames; out-of-range and fractional indices are dropped.
    assert_eq!(dynamic::read(Some(&json!({"si": []})), None, None, 1), None);
    let plist = json!({"si": [
        {"i": 0, "a": 30.0, "z": 0.0}, {"i": 1, "a": 30.0, "z": 90.0},
        {"i": 2, "a": -10.0, "z": 0.0}, {"i": 9, "a": 80.0, "z": 0.0}, {"i": 1.5, "a": 90.0, "z": 0.0},
    ]});
    let frames = dynamic::read(Some(&plist), None, None, 3).unwrap();
    assert_eq!(frames.solar.len(), 3);
    assert_eq!((frames.light, frames.dark), (0, 2));
    // Only the first plist present is read.
    let h24 = json!({"ti": [{"i": 1, "t": 0.5}]});
    let frames = dynamic::read(Some(&json!({"l": 1})), Some(&h24), None, 3).unwrap();
    assert!(frames.clock.is_empty() && frames.light == 1 && frames.dark == 1);
    // The appearance's frame: apr first, then the highest or lowest sun.
    let apr = json!({"l": 1, "d": 2});
    assert_eq!(dynamic::appearance_frame(Some(&apr), None, None, true, 3), 2);
    assert_eq!(dynamic::appearance_frame(None, Some(&plist), None, false, 3), 0);
    assert_eq!(dynamic::appearance_frame(None, Some(&plist), None, true, 3), 2);
    assert_eq!(dynamic::appearance_frame(None, None, None, true, 3), 0);
}

#[test]
fn the_desktop_store_names_the_display_choice_and_its_motion() {
    let root = json!({
        "AllSpacesAndDisplays": {"Desktop": {"Content": {"Choices": [{
            "Provider": "com.apple.wallpaper.choice.image",
            "Files": [{"relative": "file:///System/Library/Desktop%20Pictures/Sonoma.heic"}],
            "Configuration": {"$data": {"style": "dynamic"}},
        }]}}},
        "Displays": {"ABC-123": {"Desktop": {"Content": {"Choices": [{
            "Provider": "com.apple.wallpaper.choice.aerials",
            "Configuration": {"$data": {"assetID": "B2FC91ED-6891-4DEB-85A1-268B2B4160B6"}},
        }]}}}},
    });
    let all = dynamic::read_store(&root, None).unwrap();
    assert!(!all.is_aerial());
    assert_eq!(all.files(), ["file:///System/Library/Desktop%20Pictures/Sonoma.heic"]);
    assert_eq!(all.motion(), Some(Motion::Time));
    assert!(all.aerial_ids().is_empty());
    let own = dynamic::read_store(&root, Some("abc-123")).unwrap();
    assert!(own.is_aerial());
    assert_eq!(own.aerial_ids(), ["B2FC91ED-6891-4DEB-85A1-268B2B4160B6"]);
    // An unknown display falls back to every display's choice.
    assert_eq!(dynamic::read_store(&root, Some("other")), Some(all));
    assert_eq!(dynamic::read_store(&json!({}), None), None);
    let motion = |s: &str| StoreChoice { provider: None, strings: vec![s.into()] }.motion();
    assert_eq!(motion("Automatic"), Some(Motion::Appearance));
    assert_eq!(motion("dark"), Some(Motion::Dark));
    assert_eq!(motion("light"), Some(Motion::Light));
    assert_eq!(motion("Sonoma"), None);
}

#[test]
fn a_store_choice_moment_follows_its_motion() {
    let la = los_angeles();
    let frames = Frames {
        solar: Vec::new(),
        clock: vec![
            dynamic::ClockFrame { time: 0.25, index: 0 },
            dynamic::ClockFrame { time: 0.5, index: 1 },
        ],
        light: 0,
        dark: 2,
    };
    let t = at_june_21(7, 0);
    let moment = |m| dynamic::frame_of(Some(&frames), m, t, &SAN_FRANCISCO, &la);
    assert_eq!(moment(Some(Motion::Dark)), dynamic::Moment { index: Some(2), next: None });
    assert_eq!(moment(Some(Motion::Light)), dynamic::Moment { index: Some(0), next: None });
    assert_eq!(moment(Some(Motion::Appearance)), dynamic::Moment::default());
    let time = moment(None);
    assert_eq!(time.index, Some(0));
    assert!((time.next.unwrap() - at_june_21(12, 0)).abs() <= 1.0);
    let pair = Frames { light: 0, dark: 1, ..Frames::default() };
    let none = dynamic::frame_of(Some(&pair), None, t, &SAN_FRANCISCO, &la);
    assert_eq!(none, dynamic::Moment::default());
    assert_eq!(dynamic::moment_until(None, 100.0), 160.0);
    assert_eq!(dynamic::moment_until(Some(130.0), 100.0), 130.0);
}

// MARK: placement (cmux-config's fixture, BackdropPlacementTests)

const FIXTURE: &str =
    include_str!("../../cmux-config/tests/fixtures/backdrop-placement-cases.json");

fn size(value: &Value) -> Size {
    Size { width: value[0].as_f64().unwrap(), height: value[1].as_f64().unwrap() }
}

fn rect(value: &Value) -> Option<Rect> {
    let v = value.as_array()?;
    let n = |i: usize| v[i].as_f64().unwrap();
    Some(Rect { x: n(0), y: n(1), width: n(2), height: n(3) })
}

fn close(a: Option<Rect>, b: Option<Rect>) -> bool {
    match (a, b) {
        (None, None) => true,
        (Some(a), Some(b)) => [(a.x, b.x), (a.y, b.y), (a.width, b.width), (a.height, b.height)]
            .iter()
            .all(|(x, y)| (x - y).abs() < 1e-6),
        _ => false,
    }
}

#[test]
fn placement_fixture_cases() {
    let fixture: Value = serde_json::from_str(FIXTURE).unwrap();
    let cases = fixture["cases"].as_array().unwrap();
    assert_eq!(cases.len(), 103);
    for case in cases {
        let text = case["placement"].as_str().unwrap();
        let placement = Placement::parse(text).unwrap_or_else(|| panic!("{text} reads"));
        let (image, view) = (size(&case["image"]), size(&case["view"]));
        assert!(close(placement.rect(image, view), rect(&case["rect"])), "rect {case}");
        let visible = placement.visible(image, view);
        assert!(close(visible.map(|v| v.frame), rect(&case["frame"])), "frame {case}");
        assert!(close(visible.map(|v| v.contents), rect(&case["contents"])), "contents {case}");
        assert_eq!(Placement::parse(&placement.text()), Some(placement), "{text}");
    }
}

#[test]
fn placement_fixture_drags_and_keys() {
    let fixture: Value = serde_json::from_str(FIXTURE).unwrap();
    let drags = fixture["drags"].as_array().unwrap();
    assert_eq!(drags.len(), 9);
    for drag in drags {
        let placement = Placement::parse(drag["placement"].as_str().unwrap()).unwrap();
        let (dx, dy) = (drag["delta"][0].as_f64().unwrap(), drag["delta"][1].as_f64().unwrap());
        let after = placement.dragged(size(&drag["image"]), size(&drag["view"]), dx, dy);
        assert_eq!(after.text(), drag["after"].as_str().unwrap(), "{drag}");
    }
    let keys = fixture["keys"].as_array().unwrap();
    assert_eq!(keys.len(), 16);
    for key in keys {
        assert_eq!(placement::key(key["id"].as_str().unwrap()), key["key"].as_str(), "{key}");
    }
}

#[test]
fn placement_text_reads_and_clamps() {
    assert_eq!(Placement::parse("fill"), Some(Placement::default()));
    assert_eq!(Placement::parse("fit 0 1 2"), Some(Placement::new(Mode::Fit, 0.0, 1.0, 2.0)));
    for bad in [
        "",
        "tile",
        "fill 0.5",
        "fill 2 0",
        "fill 0 0 5",
        "fill 0x1 0",
        "fill nan 0",
        "fill 0 0 1 1",
    ] {
        assert_eq!(Placement::parse(bad), None, "{bad}");
    }
    assert_eq!(
        Placement::new(Mode::Fill, f64::NAN, 3.0, 9.0),
        Placement::new(Mode::Fill, 0.5, 1.0, 4.0)
    );
    assert_eq!(Placement::new(Mode::Center, 0.25, 0.125, 1.5).text(), "center 0.25 0.125 1.5");
    assert_eq!(Placement::new(Mode::Fill, 0.5, 0.5, 2.0).text(), "fill 0.5 0.5 2");
    assert_eq!(Placement::default().zoomed(10.0).zoom, 4.0);
    assert_eq!(Placement::default().zoomed(0.1).zoom, 1.0);
    let raw: BTreeMap<String, String> = [("a", "fit"), (" ", "fill"), ("b", "nope")]
        .iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect();
    let map = placement::map(&raw);
    assert_eq!(map.len(), 1);
    assert_eq!(map["a"].mode, Mode::Fit);
}

#[test]
fn placement_layer_frames_flip_to_bottom_left() {
    let placement = Placement::new(Mode::Fill, 0.0, 0.0, 1.0);
    let image = Size { width: 2_000.0, height: 1_000.0 };
    let bounds = Rect { x: 10.0, y: 20.0, width: 400.0, height: 400.0 };
    let layer = placement.layer_frame(image, bounds).unwrap();
    assert_eq!(layer.frame, Rect { x: 10.0, y: 20.0, width: 400.0, height: 400.0 });
    assert_eq!(layer.contents, Rect { x: 0.0, y: 0.0, width: 0.5, height: 1.0 });
    let drawn = placement.drawn_frame(image, bounds).unwrap();
    assert_eq!(drawn, Rect { x: 10.0, y: 20.0, width: 800.0, height: 400.0 });
    let zoomed = Placement::new(Mode::Fit, 0.5, 0.0, 2.0);
    let shown = zoomed.layer_frame(image, bounds).unwrap();
    // Fit: 400 x 200, zoomed 800 x 400 anchored at the top: the top half of the picture shows.
    assert_eq!(shown.frame, Rect { x: 10.0, y: 20.0, width: 400.0, height: 400.0 });
    assert_eq!(shown.contents, Rect { x: 0.25, y: 0.0, width: 0.5, height: 1.0 });
    assert_eq!(placement.layer_frame(image, Rect { width: 0.0, ..bounds }), None);
}

#[test]
fn the_adjust_overlay_drags_zooms_and_chooses() {
    let image = Size { width: 2_000.0, height: 1_000.0 };
    let view = Size { width: 400.0, height: 400.0 };
    let start = Placement::default();
    // AppKit's y grows up: a drag right by 100 moves the anchor left a quarter of the room.
    let dragged = placement::overlay_dragged(&start, image, view, (200.0, 200.0), (300.0, 150.0));
    assert_eq!(dragged.text(), "fill 0.25 0.5");
    assert_eq!(dragged, start.dragged(image, view, 100.0, 50.0));
    assert!((placement::scroll_zoom(1.0, false) - 0.05_f64.exp()).abs() < 1e-12);
    assert!((placement::scroll_zoom(-10.0, true) - (-0.05_f64).exp()).abs() < 1e-12);
    let moved = Placement::new(Mode::Center, 0.2, 0.8, 3.0);
    assert_eq!(
        placement::choose(Choice::Fill, &moved),
        Some(Placement::new(Mode::Fill, 0.2, 0.8, 1.0))
    );
    assert_eq!(
        placement::choose(Choice::Fit, &moved),
        Some(Placement::new(Mode::Fit, 0.2, 0.8, 1.0))
    );
    assert_eq!(
        placement::choose(Choice::Center, &moved),
        Some(Placement::new(Mode::Center, 0.5, 0.5, 1.0))
    );
    assert_eq!(placement::choose(Choice::Reset, &moved), Some(Placement::default()));
    assert_eq!(placement::choose(Choice::Done, &moved), None);
}

// MARK: desktop picture fit, glow, light, signals

#[test]
fn desktop_picture_options_pick_the_fit() {
    assert_eq!(ArtFit::from_options(None, None), ArtFit::Fill);
    assert_eq!(ArtFit::from_options(Some(3), None), ArtFit::Fill);
    assert_eq!(ArtFit::from_options(Some(3), Some(false)), ArtFit::Fit);
    assert_eq!(ArtFit::from_options(Some(0), None), ArtFit::Fit);
    assert_eq!(ArtFit::from_options(Some(1), None), ArtFit::Stretch);
    assert_eq!(ArtFit::from_options(Some(2), None), ArtFit::Center);
    assert!(ArtFit::Fit.shows_fill() && ArtFit::Center.shows_fill());
    assert!(!ArtFit::Fill.shows_fill() && !ArtFit::Stretch.shows_fill());
    let image = Size { width: 200.0, height: 100.0 };
    let bounds = Rect { x: 0.0, y: 0.0, width: 100.0, height: 100.0 };
    let r = |fit: ArtFit, ppp| fit.rect(image, bounds, ppp).unwrap();
    assert_eq!(r(ArtFit::Fill, 1.0), Rect { x: -50.0, y: 0.0, width: 200.0, height: 100.0 });
    assert_eq!(r(ArtFit::Fit, 1.0), Rect { x: 0.0, y: 25.0, width: 100.0, height: 50.0 });
    assert_eq!(r(ArtFit::Stretch, 1.0), bounds);
    assert_eq!(r(ArtFit::Center, 0.5), Rect { x: 0.0, y: 25.0, width: 100.0, height: 50.0 });
    assert_eq!(r(ArtFit::Center, f64::NAN), Rect { x: -50.0, y: 0.0, width: 200.0, height: 100.0 });
    assert_eq!(ArtFit::Fill.rect(Size { width: 0.0, height: 1.0 }, bounds, 1.0), None);
}

#[test]
fn agent_glow_ranks_levels_and_picks_one_machine() {
    let agent = |machine: &str, level| Agent { machine: machine.into(), level };
    let calm = glow::glow(&[]);
    assert_eq!((calm.level, calm.machine.as_deref(), calm.opacity), (Level::Calm, None, 0.0));
    assert_eq!(glow::glow(&[agent("my-vm", Level::Calm)]), calm);
    let waiting =
        glow::glow(&[agent("huge-blue", Level::Working), agent("my-vm", Level::NeedsYou)]);
    assert_eq!(waiting.level, Level::NeedsYou);
    assert_eq!(waiting.machine.as_deref(), Some("my-vm"));
    assert_eq!(waiting.opacity, 1.0);
    let working = glow::glow(&[agent("huge-blue", Level::Working)]);
    assert_eq!(working.machine.as_deref(), Some("huge-blue"));
    assert!(working.opacity > 0.0 && working.opacity < 1.0);
    let both = [agent("huge-blue", Level::NeedsYou), agent("my-vm", Level::NeedsYou)];
    let reversed = [both[1].clone(), both[0].clone()];
    assert_eq!(glow::glow(&both), glow::glow(&reversed));
}

#[test]
fn wallpaper_light_geometry_and_css() {
    let screen = Rect { x: 0.0, y: 0.0, width: 1_600.0, height: 1_000.0 };
    let window = Rect { x: 0.0, y: 500.0, width: 600.0, height: 500.0 };
    let geometry = light::geometry(window, screen).unwrap();
    assert_eq!(geometry.rect, Rect { x: 0.0, y: 0.0, width: 600.0, height: 500.0 });
    assert!((geometry.diagonal - (1_600.0_f64.powi(2) + 1_000.0_f64.powi(2)).sqrt()).abs() < 1e-9);
    assert_eq!(light::geometry(window, Rect { x: 0.0, y: 0.0, width: 0.0, height: 0.0 }), None);
    let rgb = |r, g, b| light::Rgb { red: r, green: g, blue: b };
    let css = light::css(&light::PageLight {
        rim: rgb(1.2, 0.5, -0.1),
        bloom: rgb(0.25, 0.5, 0.75),
        tint: rgb(0.0, 0.0, 0.0),
        dx: 0.8456,
        dy: -0.1,
        rim_alpha: 0.5,
        bloom_alpha: 0.125,
        tint_share: 0.0,
    });
    assert_eq!(css.len(), 8);
    assert_eq!(css["--wl-dx"], "0.846");
    assert_eq!(css["--wl-dy"], "-0.100");
    assert_eq!(css["--wl-rim"], "color(srgb 1.000 0.500 0.000)");
    assert_eq!(css["--wl-bloom"], "color(srgb 0.250 0.500 0.750)");
    assert_eq!(css["--wl-bloom-alpha"], "0.125");
}

#[test]
fn playback_signals_and_desktop_selection() {
    let start = signals::Playback::default();
    assert_eq!(signals::note(start, "windowWillClose"), (start, signals::Signal::Closing));
    assert_eq!(signals::note(start, "windowDidBecomeKey").1, signals::Signal::Raised);
    let (asleep, signal) = signals::note(start, "screensDidSleep");
    assert!(asleep.screens_asleep && signal == signals::Signal::Changed);
    assert!(!signals::note(asleep, "screensDidWake").0.screens_asleep);
    let (away, _) = signals::note(start, "sessionDidResignActive");
    assert!(away.session_inactive);
    assert!(!signals::note(away, "sessionDidBecomeActive").0.session_inactive);
    assert_eq!(
        signals::selection("/a.heic", Some(3), true),
        signals::Selection::Moment { path: "/a.heic".into(), frame: 3, dark: true }
    );
    assert_eq!(
        signals::selection("/a.heic", None, false),
        signals::Selection::System { path: "/a.heic".into() }
    );
}

// MARK: shaders (ShaderWallpaperTests) and live wallpapers

#[test]
fn every_shader_reads_back_from_its_id_and_poster() {
    let ids: Vec<String> = shader::all().into_iter().map(|s| s.id).collect();
    assert_eq!(
        ids,
        [
            "shader:currents",
            "shader:ripples",
            "shader:aurora",
            "shader:field",
            "shader:aero",
            "shader:sakura",
            "shader:sumi",
            "shader:koi",
            "shader:snowfall",
            "shader:lanterns",
            "shader:rain",
            "shader:matrix"
        ]
    );
    for s in shader::all() {
        assert_eq!(shader::from_id(&s.id).as_ref(), Some(&s));
        assert_eq!(s.fragment_name, format!("wp_{}", s.raw));
        for dark in [false, true] {
            let name = shader::poster_name(&s.raw, dark);
            assert_eq!(shader::poster(&name), Some((s.clone(), dark)), "{name}");
        }
    }
    assert_eq!(shader::from_id("shader:plasma"), None);
    assert_eq!(shader::poster_name("currents", true), "currents-dark-v2.png");
    assert_eq!(shader::poster("plasma-dark-v2.png"), None);
    assert_eq!(shader::named("aurora").unwrap().start_time, 63.0);
}

fn clock() -> shader::Clock {
    serde_json::from_value(json!({})).unwrap()
}

#[test]
fn the_shader_clock_eases_the_pointer_and_fades_its_energy() {
    let mut c = clock();
    let step = |pointer: [f64; 2]| shader::Step {
        elapsed: 1.0 / 60.0,
        pointer: Some(pointer),
        scale: [2.0, 2.0],
        pixel_size: [800.0, 600.0],
    };
    c.advance(&step([100.0, 100.0]));
    let start = c.clone();
    assert_eq!(start.pointer, [200.0, 200.0]);
    c.advance(&step([300.0, 100.0]));
    assert!(c.energy > start.energy, "a fast pointer adds energy");
    assert!(c.mouse[0] > start.mouse[0] && c.mouse[0] < 600.0);
    assert_eq!(c.pointer, [600.0, 200.0]);
    let moved = c.energy;
    for _ in 0..120 {
        c.advance(&step([300.0, 100.0]));
    }
    assert!(c.energy < moved * 0.2, "the energy fades while the pointer rests");
    assert!((c.mouse[0] - 600.0).abs() < 1.0);
    for _ in 0..600 {
        c.advance(&step([300.0, 100.0]));
    }
    assert!(!c.lively([2.0, 2.0]), "{c:?}");
    assert_eq!(c.frames_per_second([2.0, 2.0], shader::MAXIMUM_FPS), shader::CALM_FPS);
}

#[test]
fn a_resume_eases_the_clock_up_from_still() {
    let mut c = clock();
    c.resumed();
    let frame = 1.0 / 30.0;
    let step =
        shader::Step { elapsed: frame, pointer: None, scale: [1.0, 1.0], pixel_size: [0.0; 2] };
    c.advance(&step);
    let first = c.time;
    assert!(first > 0.0 && first < frame as f32 * 0.01);
    let mut steps = vec![first];
    let mut before = c.time;
    for _ in 0..100 {
        c.advance(&step);
        steps.push(c.time - before);
        before = c.time;
    }
    assert!(steps.windows(2).all(|w| w[1] >= w[0] - 1e-5));
    c.advance(&step);
    assert!((c.time - before - frame as f32).abs() < 1e-4);
}

#[test]
fn clicks_send_rings_and_the_oldest_is_replaced() {
    let mut c = clock();
    for i in 0..5 {
        c.time = i as f32;
        c.ring([80.0 + f64::from(i), 40.0], [2.0, 2.0]);
    }
    assert!(c.rings.iter().all(|r| r[3] == 1.0));
    assert_eq!(c.rings[0][0], 168.0);
    assert!(c.rings[0][2] > c.rings[3][2]);
    assert_eq!(c.next_ring, 1);
    assert_eq!(c.energy, 1.0);
    let mut calm = clock();
    calm.ring([10.0, 10.0], [1.0, 1.0]);
    calm.energy = 0.0;
    assert!(calm.lively([1.0, 1.0]), "a spreading ring keeps the full rate");
    calm.time = shader::RING_SECONDS;
    assert!(!calm.lively([1.0, 1.0]));
    assert_eq!(shader::ceiling(true), shader::WARM_FPS);
    assert_eq!(shader::WARM_FPS * 2.0, shader::MAXIMUM_FPS);
    assert!(shader::frame_due(1.0 / 60.0, 60.0));
    assert!(!shader::frame_due(0.01, 60.0));
}

#[test]
fn live_manifests_stills_and_digests() {
    assert_eq!(live::hold_reason_name(0), "");
    assert_eq!(live::hold_reason_name(5), "screens-asleep");
    assert_eq!(live::hold_reason_name(12), "idle");
    assert_eq!(live::hold_reason_name(200), "200");
    assert_eq!(live::digest(None), 0);
    assert_eq!(live::digest(Some(b"")), 0xcbf2_9ce4_8422_2325);
    assert_eq!(live::digest(Some(b"a")), 0xaf63_dc4c_8601_ec8c);
    assert_eq!(live::manifest(&json!({"id": ""})), None);
    let bare = live::manifest(&json!({"id": "tide"})).unwrap();
    assert_eq!(
        (bare.name.as_str(), bare.fps, bare.scale, bare.interactive),
        ("tide", 30, 1.0, true)
    );
    assert_eq!((bare.idle_after, bare.still_pointer), (20.0, [0.5, 0.5]));
    let full = live::manifest(&json!({
        "id": "tide", "name": "Tide", "description": "Waves", "fps": 24, "scale": 0.5,
        "interactive": false, "idle_after": 5,
        "params": [{"default": 0.25}, {}, {"default": 2}],
        "still": {"time": 3.5, "pointer": [0.25, 0.75]},
    }))
    .unwrap();
    assert_eq!(full.params, [0.25, 0.0, 2.0]);
    let still = live::still(&full, 200, 100);
    assert_eq!((still.time, still.pointer, still.still), (3.5, [50.0, 75.0], true));
    assert_eq!(live::still_key("tide", 255, "c"), "tide|ff|c");
}

// MARK: ops

fn op(name: &str, request: Value) -> Value {
    call(&format!("wallpaper.{name}"), &request).unwrap_or_else(|e| panic!("{name}: {e:?}"))
}

#[test]
fn ops_answer_in_camel_case_json() {
    assert_eq!(
        op("placementParse", json!({"text": "fit 0 1"})),
        json!({"mode": "fit", "x": 0.0, "y": 1.0, "zoom": 1.0})
    );
    assert_eq!(
        op(
            "placementText",
            json!({"placement": {"mode": "fill", "x": 0.25, "y": 0.5, "zoom": 1.0}})
        ),
        json!("fill 0.25 0.5")
    );
    assert_eq!(
        op(
            "placementRect",
            json!({"image": {"width": 2000, "height": 1000}, "view": {"width": 400, "height": 400}})
        ),
        json!({"x": -200.0, "y": 0.0, "width": 800.0, "height": 400.0})
    );
    assert_eq!(op("placementKey", json!({"pictureId": "daily"})), Value::Null);
    assert_eq!(
        op("timeOfDayWhen", json!({"text": "sunset-30m"})),
        json!({"kind": "sun", "event": "sunset", "offset": -1800.0})
    );
    assert_eq!(
        op("locationParse", json!({"text": "1,2"})),
        json!({"latitude": 1.0, "longitude": 2.0})
    );
    assert_eq!(
        op("locationOf", json!({"identifier": "X", "secondsFromGmt": 3600})),
        json!({"latitude": 0.0, "longitude": 15.0})
    );
    assert_eq!(
        op("artFit", json!({"imageScaling": 2})),
        json!({"fit": "center", "showsFill": true})
    );
    assert_eq!(op("shaderId", json!({"id": "shader:koi"}))["fragmentName"], json!("wp_koi"));
    assert_eq!(op("shaders", json!({})).as_array().unwrap().len(), 12);
    assert_eq!(op("holdReasonName", json!({"reason": 1})), json!("occluded"));
    assert_eq!(op("liveDigest", json!({"source": "a"})), json!("af63dc4c8601ec8c"));
    assert_eq!(op("liveManifest", json!({"id": "tide"}))["idleAfter"], json!(20.0));
    assert_eq!(
        op("agentGlow", json!({"agents": [{"machine": "m", "level": "needsYou"}]})),
        json!({"level": "needsYou", "machine": "m", "opacity": 1.0})
    );
    assert_eq!(
        op("playbackSignal", json!({"name": "screensDidSleep"})),
        json!({"state": {"screensAsleep": true, "sessionInactive": false}, "signal": "changed"})
    );
    assert_eq!(
        op("desktopShownSelection", json!({"path": "/a", "frame": 2, "dark": false})),
        json!({"kind": "moment", "path": "/a", "frame": 2, "dark": false})
    );
    assert_eq!(op("overlayChoose", json!({"choice": "done"})), Value::Null);
    assert_eq!(op("momentUntil", json!({"next": null, "t": 10.0})), json!(70.0));
    let sun = op(
        "sunEvents",
        json!({"location": {"latitude": 69.6496, "longitude": 18.956}, "t": 1_797_850_800.0, "zone": {"offset": 3600}}),
    );
    assert_eq!(sun["sunrise"], Value::Null);
    let resolved = op(
        "timeOfDayResolve",
        json!({"entries": [{"when": {"kind": "clock", "minutes": 0}, "value": "a"}], "t": 0.0}),
    );
    assert_eq!(resolved, json!({"value": "a", "next": 86400.0}));
    let ring = op("shaderRing", json!({"clock": {}, "point": [1, 2], "scale": [2, 2]}));
    assert_eq!(ring["rings"][0], json!([2.0, 4.0, 0.0, 1.0]));
    let fps = op("shaderFps", json!({"clock": {}, "warm": true}));
    assert_eq!(fps, json!({"lively": false, "fps": 30.0}));
    let store = op(
        "storeChoiceRead",
        json!({"root": {"AllSpacesAndDisplays": {"Desktop": {"Content": {"Choices": [{"Provider": "p", "x": "Dark"}]}}}}}),
    );
    assert_eq!(store["motion"], json!("dark"));
}

#[test]
fn ops_refuse_unknown_names_and_bad_requests() {
    assert!(matches!(call("wallpaper.nope", &json!({})), Err(OpError::Unknown)));
    assert!(matches!(call("wallpaper.placementRect", &json!({})), Err(OpError::Invalid(_))));
    assert!(matches!(call("wallpaper.sunPosition", &json!({"t": "x"})), Err(OpError::Invalid(_))));
}
