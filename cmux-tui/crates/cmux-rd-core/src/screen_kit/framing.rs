//! Follow mode's framing: a crop (a fraction of the display) to the scroll
//! view's zoom and offset, and back.

use super::{Point, Rect, Size};

/// Where the view's scroll view must be to show a crop of a display: the
/// zoom that fits the whole crop in the view, and the content offset that
/// centres it there. A crop taller than the view's shape shows letterboxed.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CameraFraming {
    pub zoom_scale: f64,
    pub content_offset: Point,
}

impl CameraFraming {
    /// `crop` is a fraction of `display` (its rect in the scroll view's
    /// unzoomed content); `view` is the scroll view's bounds.
    pub fn new(crop: Rect, display: Rect, view: Size) -> Self {
        let width = (crop.width * display.width).max(1.0);
        let height = (crop.height * display.height).max(1.0);
        let zoom = (view.width / width).min(view.height / height);
        let content_offset = Point::new(
            (display.x + crop.x * display.width) * zoom - (view.width - width * zoom) / 2.0,
            (display.y + crop.y * display.height) * zoom - (view.height - height * zoom) / 2.0,
        );
        Self { zoom_scale: zoom, content_offset }
    }

    /// The part of `display` the view shows at this zoom and offset (a
    /// fraction of it, cut to the display): what the person framed by hand.
    pub fn visible(&self, display: Rect, view: Size) -> Rect {
        if !(display.width > 0.0 && display.height > 0.0 && self.zoom_scale > 0.0) {
            return Rect::ZERO;
        }
        let zoom = self.zoom_scale;
        let shown = Rect::new(
            self.content_offset.x / zoom,
            self.content_offset.y / zoom,
            view.width / zoom,
            view.height / zoom,
        );
        let Some(cut) = shown.intersection(&display) else { return Rect::ZERO };
        Rect::new(
            (cut.x - display.x) / display.width,
            (cut.y - display.y) / display.height,
            cut.width / display.width,
            cut.height / display.height,
        )
    }
}

#[cfg(test)]
#[path = "framing_tests.rs"]
mod tests;
