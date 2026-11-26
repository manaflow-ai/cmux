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
mod tests {
    //! Ported from CmuxScreenKitTests/ScreenCameraFramingTests.swift.
    use super::*;

    const DISPLAY: Rect = Rect::new(0.0, 0.0, 1920.0, 1080.0);
    const VIEW: Size = Size::new(393.0, 852.0);

    fn near(a: f64, b: f64, eps: f64) -> bool {
        (a - b).abs() < eps
    }

    #[test]
    fn a_portrait_crop_fills_the_view() {
        let height = 360.0 / 1080.0;
        let width = 360.0 * 393.0 / 852.0 / 1920.0;
        let f = CameraFraming::new(Rect::new(0.5, 0.5, width, height), DISPLAY, VIEW);
        assert!(near(f.zoom_scale, 852.0 / 360.0, 1e-9));
        assert!(near(f.content_offset.x, 960.0 * f.zoom_scale, 1e-6));
        assert!(near(f.content_offset.y, 540.0 * f.zoom_scale, 1e-6));
    }

    #[test]
    fn a_wide_full_height_crop_is_letterboxed() {
        let f = CameraFraming::new(Rect::new(0.25, 0.0, 0.5, 1.0), DISPLAY, VIEW);
        let scale = 393.0 / 960.0;
        assert!(near(f.zoom_scale, scale, 1e-9));
        assert!(near(f.content_offset.x, 480.0 * scale, 1e-6));
        let shown_height = 1080.0 * scale;
        assert!(
            near(f.content_offset.y, -(852.0 - shown_height) / 2.0, 1e-6),
            "centred vertically"
        );
    }

    #[test]
    fn a_second_display_offsets_the_content() {
        let second = Rect::new(1920.0, 0.0, 1920.0, 1080.0);
        let f = CameraFraming::new(Rect::new(0.0, 0.0, 0.5, 1.0), second, VIEW);
        assert!(near(f.content_offset.x, 1920.0 * 393.0 / 960.0, 1e-6));
    }

    #[test]
    fn visible_is_the_inverse() {
        let crop = Rect::new(0.4, 0.2, 360.0 * 393.0 / 852.0 / 1920.0, 360.0 / 1080.0);
        let back = CameraFraming::new(crop, DISPLAY, VIEW).visible(DISPLAY, VIEW);
        assert!(near(back.x, crop.x, 1e-9) && near(back.y, crop.y, 1e-9));
        assert!(near(back.width, crop.width, 1e-9) && near(back.height, crop.height, 1e-9));
        let shown = CameraFraming::new(Rect::new(0.25, 0.0, 0.5, 1.0), DISPLAY, VIEW)
            .visible(DISPLAY, VIEW);
        assert!(near(shown.height, 1.0, 1e-9), "the black bars are not part of the display");
        assert!(near(shown.x, 0.25, 1e-9) && near(shown.width, 0.5, 1e-9));
    }

    #[test]
    fn nothing_shown_is_zero() {
        let none = CameraFraming { zoom_scale: 0.0, content_offset: Point::default() };
        assert_eq!(none.visible(DISPLAY, VIEW), Rect::ZERO);
        let away = CameraFraming { zoom_scale: 1.0, content_offset: Point::new(5000.0, 0.0) };
        assert_eq!(away.visible(DISPLAY, VIEW), Rect::ZERO);
    }
}
