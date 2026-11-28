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
#[path = "cursor_tests.rs"]
mod tests;
