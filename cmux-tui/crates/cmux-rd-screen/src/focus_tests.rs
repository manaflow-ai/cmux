use super::*;

// Ports FocusSignalsTests.swift. Skipped: focusIsAnExtraChannelNeverThePrimary
// (VNCPeerLink channel labels, Swift WebRTC wiring) and FocusSecureFieldTests
// (SystemFocusProbe's Accessibility roles, macOS I/O); both stay Swift.

fn p(x: f64, y: f64) -> Point {
    Point { x, y }
}
fn r(x: f64, y: f64, w: f64, h: f64) -> Rect {
    Rect::new(x, y, w, h)
}
fn sz(w: f64, h: f64) -> Size {
    Size { w, h }
}

/// A 16" MacBook Pro main display: 1728x1117 points, 3456x2234 pixels.
fn retina() -> FocusGeometry {
    FocusGeometry { display: r(0.0, 0.0, 1728.0, 1117.0), pixels: sz(3456.0, 2234.0) }
}
/// A 1x 1920x1080 display to the right, its top 100 points above the main one's.
fn second() -> FocusGeometry {
    FocusGeometry { display: r(1728.0, -100.0, 1920.0, 1080.0), pixels: sz(1920.0, 1080.0) }
}

#[test]
fn global_points_become_display_pixels_at_the_displays_scale() {
    assert_eq!(retina().point(p(10.0, 20.0)), Some(p(20.0, 40.0)));
    assert_eq!(retina().point(p(864.0, 558.5)), Some(p(1728.0, 1117.0)));
    assert_eq!(second().point(p(1728.0 + 960.0, -100.0 + 540.0)), Some(p(960.0, 540.0)));
    assert_eq!(
        second().point(p(1728.0, -100.0)),
        Some(p(0.0, 0.0)),
        "the second display's top left is its origin"
    );
}

#[test]
fn a_point_on_another_display_is_none() {
    assert_eq!(retina().point(p(1800.0, 10.0)), None, "on the second display");
    assert_eq!(second().point(p(100.0, 100.0)), None, "on the main display");
    assert_eq!(retina().point(p(-1.0, 10.0)), None);
}

#[test]
fn rects_are_clipped_to_the_display() {
    assert_eq!(retina().rect(r(100.0, 50.0, 200.0, 10.0)), Some(r(200.0, 100.0, 400.0, 20.0)));
    assert_eq!(
        retina().rect(r(1628.0, 1000.0, 400.0, 300.0)),
        Some(r(3256.0, 2000.0, 200.0, 234.0))
    );
    assert_eq!(second().rect(r(1628.0, -200.0, 200.0, 200.0)), Some(r(0.0, 0.0, 100.0, 100.0)));
    assert_eq!(retina().rect(r(2000.0, 10.0, 50.0, 50.0)), None, "wholly on another display");
}

#[test]
fn a_zero_width_caret_keeps_its_height() {
    assert_eq!(retina().rect(r(100.0, 100.0, 0.0, 16.0)), Some(r(200.0, 200.0, 0.0, 32.0)));
}

#[test]
fn app_kit_coordinates_flip_around_the_main_display() {
    let main = 1117.0;
    assert_eq!(FocusGeometry::flipped_point(p(10.0, 1117.0), main), p(10.0, 0.0));
    assert_eq!(
        FocusGeometry::flipped_rect(r(10.0, 1000.0, 50.0, 17.0), main),
        r(10.0, 100.0, 50.0, 17.0)
    );
    assert_eq!(FocusGeometry::flipped_point(p(1800.0, 1217.0), main), p(1800.0, -100.0));
    let caret = FocusGeometry::flipped_rect(r(1828.0, 1197.0, 0.0, 20.0), main);
    assert_eq!(
        second().rect(caret),
        Some(r(100.0, 0.0, 0.0, 20.0)),
        "a caret at the second display's top"
    );
    let lower = FocusGeometry::flipped_rect(r(1828.0, 1117.0, 0.0, 20.0), main);
    assert_eq!(second().rect(lower), Some(r(100.0, 80.0, 0.0, 20.0)));
}

#[test]
fn damage_in_the_captured_picture_scales_to_display_pixels() {
    let captured = sz(1728.0, 1117.0);
    assert_eq!(
        retina().captured(r(10.0, 20.0, 30.0, 40.0), captured),
        Some(r(20.0, 40.0, 60.0, 80.0))
    );
    assert_eq!(
        retina().captured(r(1700.0, 1100.0, 100.0, 100.0), captured),
        Some(r(3400.0, 2200.0, 56.0, 34.0)),
        "clipped to the display"
    );
    assert_eq!(retina().captured(r(10.0, 20.0, 30.0, 40.0), sz(0.0, 0.0)), None);
}

fn ev(t_us: u64, signal: FocusSignal) -> String {
    FocusEvent { t_us, signal }.json()
}

#[test]
fn events_encode_as_the_engines_json() {
    assert_eq!(
        ev(123, FocusSignal::Source { w: 3024.0, h: 1964.0 }),
        r#"{"t_us":123,"kind":"source","w":3024,"h":1964}"#
    );
    assert_eq!(
        ev(123, FocusSignal::Pointer { x: 10.0, y: 20.5 }),
        r#"{"t_us":123,"kind":"pointer","x":10,"y":20.5}"#
    );
    assert_eq!(
        ev(7, FocusSignal::Caret(r(1.0, 2.0, 0.0, 32.0))),
        r#"{"t_us":7,"kind":"caret","x":1,"y":2,"w":0,"h":32}"#
    );
    assert_eq!(
        ev(7, FocusSignal::Window { id: 42, rect: r(0.0, 50.0, 800.0, 600.0) }),
        r#"{"t_us":7,"kind":"window","id":42,"x":0,"y":50,"w":800,"h":600}"#
    );
    assert_eq!(
        ev(7, FocusSignal::Damage(r(1.25, 2.0, 3.0, 4.0))),
        r#"{"t_us":7,"kind":"damage","x":1.3,"y":2,"w":3,"h":4}"#
    );
    assert_eq!(ev(u64::MAX, FocusSignal::Cut), r#"{"t_us":18446744073709551615,"kind":"cut"}"#);
}

#[test]
fn the_json_parses_with_the_tag_and_time_at_the_top() {
    let text = ev(99, FocusSignal::Window { id: 7, rect: r(1.0, 2.0, 3.0, 4.0) });
    let value: serde_json::Value = serde_json::from_str(&text).unwrap();
    let object = value.as_object().unwrap();
    let mut keys: Vec<&str> = object.keys().map(String::as_str).collect();
    keys.sort_unstable();
    assert_eq!(keys, ["h", "id", "kind", "t_us", "w", "x", "y"]);
    assert_eq!(object["kind"], "window");
    assert_eq!(object["t_us"].as_u64(), Some(99));
}

#[test]
fn coordinates_never_encode_as_exponents_or_non_finite_numbers() {
    assert_eq!(
        ev(1, FocusSignal::Pointer { x: 0.000_01, y: 1e7 }),
        r#"{"t_us":1,"kind":"pointer","x":0,"y":10000000}"#
    );
    assert_eq!(
        ev(1, FocusSignal::Pointer { x: f64::NAN, y: 1.0 }),
        r#"{"t_us":1,"kind":"pointer","x":0,"y":1}"#
    );
}

#[test]
fn number_formatting_rule() {
    assert_eq!(FocusEvent::number(12.34), "12.3");
    assert_eq!(FocusEvent::number(-0.5), "-0.5");
    assert_eq!(FocusEvent::number(-0.04), "0");
    assert_eq!(FocusEvent::number(f64::INFINITY), "0");
    assert_eq!(FocusEvent::number(5e12), "1000000000");
    assert_eq!(FocusEvent::number(-5e12), "-1000000000");
    assert_eq!(FocusEvent::number(123_456_789.25), "123456789.3");
}

#[test]
fn nearby_damage_merges_and_the_largest_regions_go_first() {
    let mut damage = FocusDamage::new();
    damage.add(&[r(100.0, 100.0, 800.0, 30.0), r(100.0, 130.0, 800.0, 30.0)]);
    damage.add(&[r(3000.0, 0.0, 100.0, 40.0)]);
    damage.add(&[r(2000.0, 2000.0, 10.0, 20.0)]);
    damage.add(&[r(120.0, 165.0, 10.0, 20.0)]);
    let regions = damage.drain(2);
    assert_eq!(regions, [r(100.0, 100.0, 800.0, 85.0), r(3000.0, 0.0, 100.0, 40.0)]);
    assert!(damage.drain(2).is_empty(), "drained");
}

#[test]
fn a_storm_of_rects_stays_bounded() {
    let mut damage = FocusDamage::new();
    for i in 0..10_000 {
        damage.add(&[r(f64::from(i % 100) * 200.0, f64::from(i / 100) * 200.0, 10.0, 10.0)]);
    }
    assert!(damage.count() <= FocusDamage::MAXIMUM_REGIONS);
    assert_eq!(damage.drain(3).len(), 3);
}

// The producer. The Swift FakeProbe (no Accessibility grant: no caret) is a
// FocusSample; `Sent` is a closure over a message list and an open flag.

fn probe() -> FocusSample {
    FocusSample {
        geometry: Some(retina()),
        pointer: Some(p(100.0, 100.0)),
        window: Some(FocusWindow { id: 5, frame: r(0.0, 0.0, 800.0, 600.0), pid: 0 }),
        caret: None,
    }
}

#[derive(Default)]
struct Sent {
    messages: Vec<String>,
    closed: bool,
}

impl Sent {
    fn tick(&mut self, producer: &mut FocusProducer, sample: &FocusSample, now: u64) {
        producer.run_tick(sample, now, |m| {
            if self.closed {
                return false;
            }
            self.messages.push(m.to_string());
            true
        });
    }
    fn kinds(&self) -> Vec<String> {
        self.messages
            .iter()
            .filter_map(|m| {
                serde_json::from_str::<serde_json::Value>(m).ok()?["kind"]
                    .as_str()
                    .map(str::to_string)
            })
            .collect()
    }
    fn count(&self, kind: &str) -> usize {
        self.kinds().iter().filter(|k| *k == kind).count()
    }
    fn take(&mut self) -> Vec<String> {
        std::mem::take(&mut self.messages)
    }
}

const SECOND: u64 = FocusProducer::TICKS_PER_SECOND;

#[test]
fn without_accessibility_the_pointer_window_and_damage_still_go() {
    let sample = probe();
    let mut sent = Sent::default();
    let mut producer = FocusProducer::new();
    producer.damage(sample.geometry.as_ref(), &[r(10.0, 10.0, 20.0, 20.0)], sz(3456.0, 2234.0));
    for tick in 0..SECOND {
        sent.tick(&mut producer, &sample, tick * 33_000);
    }
    let kinds = sent.kinds();
    assert_eq!(kinds.first().map(String::as_str), Some("source"), "the size first");
    assert!(kinds.iter().any(|k| k == "pointer"));
    assert!(kinds.iter().any(|k| k == "window"));
    assert!(kinds.iter().any(|k| k == "damage"));
    assert!(!kinds.iter().any(|k| k == "caret"));
    assert!(sent.messages.iter().any(|m| m == r#"{"t_us":0,"kind":"pointer","x":200,"y":200}"#));
}

#[test]
fn a_caret_goes_on_change_and_every_event_in_display_pixels() {
    let mut sample = probe();
    sample.caret = Some(r(50.0, 60.0, 0.0, 16.0));
    let mut sent = Sent::default();
    let mut producer = FocusProducer::new();
    for tick in 0..4 {
        sent.tick(&mut producer, &sample, tick * 33_000);
    }
    let carets: Vec<String> =
        sent.take().into_iter().filter(|m| m.contains(r#""kind":"caret""#)).collect();
    assert_eq!(
        carets,
        [r#"{"t_us":0,"kind":"caret","x":100,"y":120,"w":0,"h":32}"#],
        "once while it stays"
    );
    sample.caret = Some(r(58.0, 60.0, 0.0, 16.0));
    for tick in 4..8 {
        sent.tick(&mut producer, &sample, tick * 33_000);
    }
    assert_eq!(sent.take().iter().filter(|m| m.contains(r#""kind":"caret""#)).count(), 1);
}

#[test]
fn a_still_pointer_is_not_resent_every_tick() {
    let sample = probe();
    let mut sent = Sent::default();
    let mut producer = FocusProducer::new();
    for tick in 0..10 {
        sent.tick(&mut producer, &sample, tick * 33_000);
    }
    assert_eq!(sent.count("pointer"), 1);
}

#[test]
fn a_new_window_id_is_sent_at_once_and_the_window_is_repeated_for_a_late_joiner() {
    let mut sample = probe();
    let mut sent = Sent::default();
    let mut producer = FocusProducer::new();
    for tick in 0..SECOND {
        sent.tick(&mut producer, &sample, tick * 33_000);
    }
    assert_eq!(sent.count("window"), 1);
    sent.take();
    for tick in SECOND..2 * SECOND {
        sent.tick(&mut producer, &sample, tick * 33_000);
    }
    assert_eq!(sent.count("window"), 1, "re-sent once a second");
    assert!(sent.kinds().iter().any(|k| k == "source"), "the size too");
    sent.take();
    sample.window = Some(FocusWindow { id: 6, frame: r(10.0, 10.0, 400.0, 300.0), pid: 0 });
    for tick in 2 * SECOND..2 * SECOND + FocusProducer::WINDOW_EVERY {
        sent.tick(&mut producer, &sample, tick * 33_000);
    }
    assert!(sent.take().iter().any(|m| m.contains(r#""kind":"window","id":6"#)));
}

#[test]
fn damage_is_coalesced_to_at_most_thirty_messages_a_second() {
    let sample = probe();
    let mut sent = Sent::default();
    let mut producer = FocusProducer::new();
    for tick in 0..SECOND {
        let rects: Vec<Rect> = (0..20)
            .map(|i| r(f64::from(i) * 170.0, (tick % 10) as f64 * 200.0, 8.0, 8.0))
            .collect();
        producer.damage(sample.geometry.as_ref(), &rects, sz(3456.0, 2234.0));
        sent.tick(&mut producer, &sample, tick * 33_000);
    }
    assert!(sent.count("damage") <= 30);
    assert!(sent.count("damage") > 0);
}

#[test]
fn a_closed_channel_resends_everything_once_it_opens() {
    let sample = probe();
    let mut sent = Sent { closed: true, ..Sent::default() };
    let mut producer = FocusProducer::new();
    for tick in 0..3 {
        sent.tick(&mut producer, &sample, tick * 33_000);
    }
    sent.closed = false;
    sent.tick(&mut producer, &sample, 3 * 33_000);
    let kinds = sent.kinds();
    assert_eq!(kinds.first().map(String::as_str), Some("source"));
    assert!(kinds.iter().any(|k| k == "pointer"));
    assert!(kinds.iter().any(|k| k == "window"));
}

#[test]
fn a_failed_send_commits_nothing() {
    let sample = probe();
    let mut producer = FocusProducer::new();
    let tick = producer.tick(&sample, 0).unwrap();
    assert!(!tick.messages.is_empty());
    producer.failed();
    let again = producer.tick(&sample, 33_000).unwrap();
    assert_eq!(again.messages.len(), tick.messages.len(), "tick 1 resyncs everything");
    assert!(again.messages[0].contains(r#""kind":"source""#));
    producer.commit(again);
    let quiet = producer.tick(&sample, 66_000).unwrap();
    assert!(quiet.messages.is_empty(), "nothing changed: {:?}", quiet.messages);
}

#[test]
fn no_geometry_means_nothing_is_sent() {
    let sample = FocusSample { geometry: None, ..probe() };
    let mut sent = Sent::default();
    let mut producer = FocusProducer::new();
    for tick in 0..40 {
        sent.tick(&mut producer, &sample, tick * 33_000);
    }
    assert!(sent.kinds().is_empty());
}
