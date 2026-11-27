//! Ported from CmuxScreenKitTests/ScreenStreamCursorTests.swift.
use super::*;

fn arrow(w: f64, h: f64) -> CursorGeometry {
    CursorGeometry {
        size: Size::new(w, h),
        hotspot: Point::new(5.0 / 28.0, 5.0 / 40.0),
        points: Size::new(28.0, 40.0),
    }
}

fn shape() -> CursorGeometry {
    arrow(28.0 / 1512.0, 40.0 / 982.0)
}

fn near(a: f64, b: f64) -> bool {
    (a - b).abs() < 1e-6
}

fn current(cache: &CursorCache) -> Option<&str> {
    cache.current().map(|(id, _)| id)
}

#[test]
fn the_telepointers_pick_the_shape_they_name() {
    let mut cache = CursorCache::new();
    assert!(!cache.select(None), "a Mac that sends no shapes: no change");
    assert!(cache.current().is_none());
    assert!(!cache.add("arrow", shape()).became_current, "not named yet");
    assert!(cache.select(Some("arrow")) && current(&cache) == Some("arrow"));
    assert!(!cache.select(Some("arrow")), "unchanged");
    assert!(!cache.select(Some("ibeam")) && current(&cache) == Some("arrow"));
    assert!(cache.add("ibeam", shape()).became_current && current(&cache) == Some("ibeam"));
    assert!(
        cache.select(Some("arrow")) && current(&cache) == Some("arrow"),
        "back to a shape it has"
    );
    cache.reset();
    assert!(cache.current().is_none() && !cache.select(Some("ibeam")), "a new stream starts over");
}

#[test]
fn the_same_shape_on_another_display_updates_its_placement_once() {
    let mut cache = CursorCache::new();
    cache.add("arrow", arrow(28.0 / 1512.0, 40.0 / 982.0));
    assert!(cache.select(Some("arrow")));
    assert!(cache.add("arrow", arrow(28.0 / 756.0, 40.0 / 491.0)).became_current);
    let (_, geometry) = cache.current().unwrap();
    let p = geometry.placement(Point::new(100.0, 100.0), Size::new(756.0, 491.0));
    assert!(near(p.rect.width, 28.0) && near(p.rect.height, 40.0));
    assert!(near(p.rect.x, 95.0) && near(p.rect.y, 95.0));
    assert!(near(p.pixels_per_point, 1.0));
    assert!(!cache.add("arrow", arrow(28.0 / 756.0, 40.0 / 491.0)).became_current);
    assert!(!cache.select(Some("arrow")), "a repeated telepointer does not notify again");
}

#[test]
fn the_cache_keeps_what_the_host_remembers() {
    let mut cache = CursorCache::new();
    cache.add("arrow", shape());
    let mut evicted = Vec::new();
    for index in 0..CursorCache::CAPACITY + 10 {
        evicted.extend(cache.add(&format!("s{index}"), shape()).evicted);
        if index % 8 == 0 {
            cache.select(Some("arrow"));
        }
    }
    assert_eq!(evicted.len(), 11);
    assert!(!evicted.contains(&"arrow".to_owned()));
    assert!(evicted.contains(&"s0".to_owned()));
    assert!(cache.select(Some("s20")) && current(&cache) == Some("s20"));
    assert!(
        cache.select(Some("arrow")) && current(&cache) == Some("arrow"),
        "named often: still here"
    );
    assert!(
        !cache.select(Some("s0")) && current(&cache) == Some("arrow"),
        "the oldest unnamed one left"
    );
}

#[test]
fn it_is_as_large_as_the_mac_shows_it() {
    let p = shape().placement(Point::new(1000.0, 500.0), Size::new(3024.0, 1964.0));
    assert!(near(p.rect.width, 56.0) && near(p.rect.height, 80.0));
    assert!(near(p.rect.x, 990.0) && near(p.rect.y, 490.0));
    assert!(near(p.pixels_per_point, 2.0));
    let half = shape().placement(Point::new(500.0, 250.0), Size::new(1512.0, 982.0));
    assert!(
        near(half.rect.width, 28.0) && near(half.rect.x, 495.0) && near(half.pixels_per_point, 1.0)
    );
    let pointless = CursorGeometry { points: Size::default(), ..shape() };
    assert_eq!(pointless.placement(Point::default(), Size::new(10.0, 10.0)).pixels_per_point, 1.0);
}
