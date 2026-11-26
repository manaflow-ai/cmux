//! The Mac's cursor on a screen stream: where its image lands at any zoom,
//! and the viewer's cache of the shapes the host sent. The images stay in
//! the app; this keeps their ids and geometry.

use std::collections::{HashMap, VecDeque};

use super::{Point, Rect, Size};

/// A shape's geometry: sizes as fractions of the streamed display, so it
/// lands at the Mac's size at any zoom.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CursorGeometry {
    /// Width and height as fractions of the streamed display.
    pub size: Size,
    /// The hotspot as a fraction of `size`.
    pub hotspot: Point,
    /// The cursor's size in the Mac's points (its shadow is in points).
    pub points: Size,
}

/// Where and how large to draw a cursor.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CursorPlacement {
    /// The image's rectangle, its top left at the hotspot's offset from the pointer.
    pub rect: Rect,
    /// Frame pixels per Mac point (for the shadow).
    pub pixels_per_point: f64,
}

impl CursorGeometry {
    /// Where to draw it on a picture `frame` pixels in size, with the pointer at `pointer`.
    pub fn placement(&self, pointer: Point, frame: Size) -> CursorPlacement {
        let width = self.size.width * frame.width;
        let height = self.size.height * frame.height;
        let rect = Rect::new(
            pointer.x - self.hotspot.x * width,
            pointer.y - self.hotspot.y * height,
            width,
            height,
        );
        let pixels_per_point =
            if self.points.width > 0.0 { width / self.points.width } else { 1.0 };
        CursorPlacement { rect, pixels_per_point }
    }
}

/// What adding a shape did.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct CursorAdd {
    /// It is now the current shape: the view redraws.
    pub became_current: bool,
    /// A shape that left the cache: the app drops its image.
    pub evicted: Option<String>,
}

/// The shapes a viewer has (more than the host remembers sending, so every
/// shape the host names without sending again is here) and the one the
/// telepointers name. A telepointer that names a shape not here yet keeps
/// the last one until it arrives: the cursor never flashes to another shape.
#[derive(Clone, Debug, Default)]
pub struct CursorCache {
    shapes: HashMap<String, CursorGeometry>,
    /// Least recently named or added first.
    order: VecDeque<String>,
    /// The shape the latest telepointers named.
    wanted: Option<String>,
    current: Option<(String, CursorGeometry)>,
}

impl CursorCache {
    pub const CAPACITY: usize = 128;

    pub fn new() -> Self {
        Self::default()
    }

    /// The shape to draw: its id and geometry.
    pub fn current(&self) -> Option<(&str, &CursorGeometry)> {
        self.current.as_ref().map(|(id, geometry)| (id.as_str(), geometry))
    }

    pub fn contains(&self, id: &str) -> bool {
        self.shapes.contains_key(id)
    }

    fn is_current(&self, id: &str, geometry: &CursorGeometry) -> bool {
        self.current.as_ref().is_some_and(|(current, shape)| current == id && shape == geometry)
    }

    /// Adds a shape from the host.
    pub fn add(&mut self, id: &str, geometry: CursorGeometry) -> CursorAdd {
        let mut result = CursorAdd::default();
        if self.shapes.insert(id.to_owned(), geometry).is_none() {
            self.order.push_back(id.to_owned());
            if self.order.len() > Self::CAPACITY
                && let Some(gone) = self.order.pop_front()
            {
                self.shapes.remove(&gone);
                result.evicted = Some(gone);
            }
        }
        if self.wanted.as_deref() == Some(id) && !self.is_current(id, &geometry) {
            self.current = Some((id.to_owned(), geometry));
            result.became_current = true;
        }
        result
    }

    /// The telepointers named `id` (`None`: a host that sends no shapes, no
    /// change); true when the current shape changed.
    pub fn select(&mut self, id: Option<&str>) -> bool {
        let Some(id) = id else { return false };
        self.wanted = Some(id.to_owned());
        // Named again: newest, as the host's own memory has it.
        if let Some(index) = self.order.iter().position(|named| named == id)
            && index != self.order.len() - 1
            && let Some(named) = self.order.remove(index)
        {
            self.order.push_back(named);
        }
        let Some(&shape) = self.shapes.get(id) else { return false };
        if self.is_current(id, &shape) {
            return false;
        }
        self.current = Some((id.to_owned(), shape));
        true
    }

    /// A new stream: its host's shapes start over.
    pub fn reset(&mut self) {
        *self = Self::default();
    }
}

#[cfg(test)]
mod tests {
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
        assert!(
            cache.current().is_none() && !cache.select(Some("ibeam")),
            "a new stream starts over"
        );
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
            near(half.rect.width, 28.0)
                && near(half.rect.x, 495.0)
                && near(half.pixels_per_point, 1.0)
        );
        let pointless = CursorGeometry { points: Size::default(), ..shape() };
        assert_eq!(
            pointless.placement(Point::default(), Size::new(10.0, 10.0)).pixels_per_point,
            1.0
        );
    }
}
