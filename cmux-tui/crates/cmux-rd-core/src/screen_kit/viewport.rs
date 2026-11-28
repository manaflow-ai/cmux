//! The screen view's scroll math: fitting a display, centring it, keeping
//! it on screen, paging between displays, letterbox insets, scroll
//! quantizing, keeping the trackpad cursor in view, and the stream's
//! layout size and demand. The view owns its scroll view; these say where
//! it goes.

use super::{Point, Rect, Size};

/// The zoom at which `rect` fits `view` whole; 1 for an empty rect.
pub fn fit_scale(rect: Rect, view: Size) -> f64 {
    if !(rect.width > 0.0 && rect.height > 0.0) {
        return 1.0;
    }
    (view.width / rect.width).min(view.height / rect.height)
}

/// The content offset that centres `rect` in `view` at `scale`.
pub fn centered_offset(rect: Rect, scale: f64, view: Size) -> Point {
    Point::new(
        rect.x * scale - (view.width - rect.width * scale) / 2.0,
        rect.y * scale - (view.height - rect.height * scale) / 2.0,
    )
}

/// The deepest zoom for a display that fits at `fit`.
pub fn maximum_zoom(fit: f64) -> f64 {
    (fit * 6.0).max(2.0)
}

/// Two zoom scales are the same zoom (a view "at fit").
pub fn same_zoom(a: f64, b: f64) -> bool {
    (a - b).abs() < 0.001
}

fn offset_range(min_edge: f64, length: f64, view_length: f64, scale: f64) -> (f64, f64) {
    let low = min_edge * scale;
    let size = length * scale;
    if size <= view_length {
        let centered = low - (view_length - size) / 2.0;
        return (centered, centered);
    }
    (low, low + size - view_length)
}

/// The offset that keeps `focus` on screen at `scale` (centred on an axis
/// where it is smaller than the view); `allow_horizontal` leaves x free
/// (a swipe between displays).
pub fn clamped_offset(
    offset: Point,
    focus: Rect,
    scale: f64,
    view: Size,
    allow_horizontal: bool,
) -> Point {
    let (x_low, x_high) = offset_range(focus.x, focus.width, view.width, scale);
    let (y_low, y_high) = offset_range(focus.y, focus.height, view.height, scale);
    Point::new(
        if allow_horizontal { offset.x } else { offset.x.max(x_low).min(x_high) },
        offset.y.max(y_low).min(y_high),
    )
}

/// The display a swipe that ends at fit lands on: the next one for a fast
/// or long swipe left, the previous for one right, else where it was.
/// `moved` is the content's travel from the page's centred offset.
pub fn page_target(
    page: usize,
    count: usize,
    velocity_x: f64,
    moved: f64,
    view_width: f64,
) -> usize {
    let mut target = page;
    if velocity_x > 0.3 || moved > view_width * 0.25 {
        target = (page + 1).min(count.saturating_sub(1));
    }
    if velocity_x < -0.3 || moved < -view_width * 0.25 {
        target = page.saturating_sub(1);
    }
    target
}

/// The page a display list opens on: the display at the origin (the Mac's
/// main display), else the first.
pub fn initial_page(screens: &[Rect]) -> usize {
    screens.iter().position(|screen| screen.x == 0.0 && screen.y == 0.0).unwrap_or(0)
}

/// Scroll view content insets (top, left, bottom, right).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Insets {
    pub top: f64,
    pub left: f64,
    pub bottom: f64,
    pub right: f64,
}

/// Insets that let any display sit centred (`centres_any`: fitted mode or
/// several displays): a whole view on every side; otherwise letterboxing
/// for content smaller than the view.
pub fn content_insets(centres_any: bool, view: Size, content: Size) -> Insets {
    if centres_any {
        return Insets {
            top: view.height,
            left: view.width,
            bottom: view.height,
            right: view.width,
        };
    }
    let x = ((view.width - content.width) / 2.0).max(0.0);
    let y = ((view.height - content.height) / 2.0).max(0.0);
    Insets { top: y, left: x, bottom: y, right: x }
}

/// A finger's scroll travel, in view points, to whole pixels or wheel
/// clicks for the Mac; what is left over carries to the next stroke.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct ScrollQuantizer {
    pub remainder: Point,
}

/// View points per wheel click (a host without pixel scrolling).
pub const POINTS_PER_SCROLL_CLICK: f64 = 18.0;

impl ScrollQuantizer {
    /// A new stroke starts from nothing.
    pub fn reset(&mut self) {
        self.remainder = Point::default();
    }

    /// Adds `translation` and takes the whole units: framebuffer pixels at
    /// `pixels_per_point` when `pixels`, else clicks of
    /// [`POINTS_PER_SCROLL_CLICK`]. Truncates toward zero, as Swift's `Int(_:)`.
    pub fn scroll(
        &mut self,
        translation: Point,
        pixels: bool,
        pixels_per_point: f64,
    ) -> (i64, i64) {
        self.remainder.x += translation.x;
        self.remainder.y += translation.y;
        if pixels {
            let scale = pixels_per_point;
            let x = (self.remainder.x * scale) as i64;
            let y = (self.remainder.y * scale) as i64;
            self.remainder.x -= x as f64 / scale;
            self.remainder.y -= y as f64 / scale;
            return (x, y);
        }
        let x = (self.remainder.x / POINTS_PER_SCROLL_CLICK) as i64;
        let y = (self.remainder.y / POINTS_PER_SCROLL_CLICK) as i64;
        self.remainder.x -= x as f64 * POINTS_PER_SCROLL_CLICK;
        self.remainder.y -= y as f64 * POINTS_PER_SCROLL_CLICK;
        (x, y)
    }
}

/// Framebuffer pixels under one view point at `zoom`.
pub fn pixels_per_point(zoom: f64) -> f64 {
    1.0 / zoom.max(0.01)
}

/// A pointer position kept inside `rect` (its last pixel row and column).
pub fn clamp_to_rect(point: Point, rect: Rect) -> Point {
    Point::new(
        point.x.max(rect.x).min(rect.x.max(rect.max_x() - 1.0)),
        point.y.max(rect.y).min(rect.y.max(rect.max_y() - 1.0)),
    )
}

/// The offset that keeps the cursor (`cursor`, in zoomed content points)
/// clear of the view's edges by 12 % of its short side. Not yet clamped.
pub fn follow_cursor(offset: Point, cursor: Point, view: Size) -> Point {
    let margin = view.width.min(view.height) * 0.12;
    let follow = |position: f64, origin: f64, length: f64| {
        if position - origin < margin {
            position - margin
        } else if position - origin > length - margin {
            position - length + margin
        } else {
            origin
        }
    };
    Point::new(follow(cursor.x, offset.x, view.width), follow(cursor.y, offset.y, view.height))
}

/// An offset kept inside the scroll view's content and insets (free mode).
pub fn clamp_to_content(offset: Point, insets: Insets, content: Size, view: Size) -> Point {
    Point::new(
        offset
            .x
            .max(-insets.left)
            .min((-insets.left).max(content.width + insets.right - view.width)),
        offset
            .y
            .max(-insets.top)
            .min((-insets.top).max(content.height + insets.bottom - view.height)),
    )
}

/// The content size for a stream's video: the Mac display's own pixel size
/// when the video has its shape (scaled down to what the view shows), so a
/// resolution step keeps the zoom and pointer; the video's size otherwise.
pub fn stream_layout_size(video: Size, display: Option<Size>) -> Size {
    match display {
        Some(display)
            if display.width > 0.0
                && display.height > 0.0
                && video.height > 0.0
                && (display.width / display.height - video.width / video.height).abs() < 0.01 =>
        {
            display
        }
        _ => video,
    }
}

/// The viewer's demand: the long edge, in screen pixels, of the whole
/// streamed display at `zoom` on a `display_scale` screen, rounded up.
pub fn demand_long_edge(frame: Size, zoom: f64, display_scale: f64) -> i64 {
    (frame.width.max(frame.height) * zoom * display_scale).ceil() as i64
}

/// A framebuffer point as a fraction of the frame.
pub fn normalized(point: Point, frame: Size) -> Point {
    Point::new(point.x / frame.width.max(1.0), point.y / frame.height.max(1.0))
}

/// A framebuffer point kept on the frame's pixels.
pub fn clamp_to_frame(point: Point, frame: Size) -> Point {
    Point::new(
        point.x.max(0.0).min((frame.width - 1.0).max(0.0)),
        point.y.max(0.0).min((frame.height - 1.0).max(0.0)),
    )
}

#[cfg(test)]
#[path = "viewport_tests.rs"]
mod tests;
