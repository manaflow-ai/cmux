//! Where a background picture lies in its window or pane
//! (`appearance.backgroundPlacement`, one entry per picture id).
//!
//! A placement is a scaling mode, an anchor and a zoom:
//!
//! - `fill` covers the view (today's look, Core Animation's
//!   `resizeAspectFill`), `fit` shows the whole picture, `center` draws it at
//!   its own size, `stretch` covers the view ignoring the aspect ratio.
//! - `x`, `y` (0...1, from the top-left) say which part of the picture shows
//!   where the picture is larger than the view, and where it sits where it is
//!   smaller, like CSS `object-position`: the picture's origin is
//!   `(view - drawn) * anchor` on each axis. 0.5 centers it. Because the anchor
//!   stays in 0...1, a filled picture never shows an empty edge at any anchor.
//! - `zoom` (1...4) scales the drawn picture around that anchor.
//!
//! Unset is `fill 0.5 0.5 1`, the centered fill every window draws today.
//!
//! The setting stores each placement as text: the mode, then the anchor and
//! the zoom when they are not the default (`"fit"`, `"fill 0.3 0.7"`,
//! `"fill 0.3 0.7 2"`). The app draws with a mirror of this math
//! (Swift `BackdropPlacement`, web `backgroundPlacement.ts`); this module and
//! its tests are the spec, and `tests/fixtures/backdrop-placement-cases.json`
//! is the shared table all three check.

use serde_json::Value;

/// How the picture is scaled before the anchor and zoom apply.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PlacementMode {
    /// Cover the view, keeping the aspect ratio (cropping the overflow).
    Fill,
    /// Show the whole picture, keeping the aspect ratio (bars where it is narrower).
    Fit,
    /// The picture at its own size.
    Center,
    /// Cover the view exactly, ignoring the aspect ratio.
    Stretch,
}

impl PlacementMode {
    /// The setting's word for the mode.
    pub fn name(self) -> &'static str {
        match self {
            Self::Fill => "fill",
            Self::Fit => "fit",
            Self::Center => "center",
            Self::Stretch => "stretch",
        }
    }

    /// The mode a setting word names.
    pub fn parse(text: &str) -> Option<Self> {
        match text {
            "fill" => Some(Self::Fill),
            "fit" => Some(Self::Fit),
            "center" => Some(Self::Center),
            "stretch" => Some(Self::Stretch),
            _ => None,
        }
    }
}

/// The smallest and largest zoom.
pub const ZOOM_RANGE: (f64, f64) = (1.0, 4.0);

/// One picture's placement.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Placement {
    pub mode: PlacementMode,
    /// The horizontal anchor, 0 (left) to 1 (right).
    pub x: f64,
    /// The vertical anchor, 0 (top) to 1 (bottom).
    pub y: f64,
    /// 1 to 4.
    pub zoom: f64,
}

impl Default for Placement {
    /// Today's look: the picture fills the view, centered.
    fn default() -> Self {
        Self { mode: PlacementMode::Fill, x: 0.5, y: 0.5, zoom: 1.0 }
    }
}

impl Placement {
    /// A placement with its anchor and zoom clamped to their ranges (NaN is the default).
    pub fn clamped(mode: PlacementMode, x: f64, y: f64, zoom: f64) -> Self {
        let unit = |v: f64| if v.is_nan() { 0.5 } else { v.clamp(0.0, 1.0) };
        let zoom = if zoom.is_nan() { 1.0 } else { zoom.clamp(ZOOM_RANGE.0, ZOOM_RANGE.1) };
        Self { mode, x: unit(x), y: unit(y), zoom }
    }

    /// The setting's text for one placement (`"fill"`, `"fit 0.25 0.5"`,
    /// `"fill 0.3 0.7 2"`), the shortest that reads back the same.
    pub fn to_text(&self) -> String {
        let number = |v: f64| {
            let text = format!("{v:.3}");
            let text = text.trim_end_matches('0').trim_end_matches('.');
            if text == "-0" { "0".to_string() } else { text.to_string() }
        };
        let centered = self.x == 0.5 && self.y == 0.5;
        let mut out = self.mode.name().to_string();
        if !centered || self.zoom != 1.0 {
            out.push_str(&format!(" {} {}", number(self.x), number(self.y)));
        }
        if self.zoom != 1.0 {
            out.push_str(&format!(" {}", number(self.zoom)));
        }
        out
    }

    /// Reads one placement's text: a mode, optionally followed by both anchors
    /// and then a zoom, separated by spaces. Values out of range are refused,
    /// not clamped, so a typo never moves a picture silently.
    pub fn parse(text: &str) -> Option<Self> {
        let parts: Vec<&str> = text.split_whitespace().collect();
        let (mode, rest) = parts.split_first()?;
        let mode = PlacementMode::parse(mode)?;
        let number = |part: &str| part.parse::<f64>().ok().filter(|v| v.is_finite());
        let unit = |part: &str| number(part).filter(|v| (0.0..=1.0).contains(v));
        let (x, y, zoom) = match rest {
            [] => (0.5, 0.5, 1.0),
            [x, y] => (unit(x)?, unit(y)?, 1.0),
            [x, y, zoom] => (
                unit(x)?,
                unit(y)?,
                number(zoom).filter(|z| (ZOOM_RANGE.0..=ZOOM_RANGE.1).contains(z))?,
            ),
            _ => return None,
        };
        Some(Self { mode, x, y, zoom })
    }
}

/// A width and height in points.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Size {
    pub width: f64,
    pub height: f64,
}

/// A rect in points, origin at the view's top-left, y growing down.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

/// Where the whole picture is drawn in a `view`-sized view, in the view's
/// points (top-left origin); it may run past the view's edges, which clip it.
/// Nil when the picture or the view has no area.
pub fn placement_rect(image: Size, view: Size, placement: &Placement) -> Option<Rect> {
    let positive = |v: f64| v.is_finite() && v > 0.0;
    if !(positive(image.width)
        && positive(image.height)
        && positive(view.width)
        && positive(view.height))
    {
        return None;
    }
    let p = Placement::clamped(placement.mode, placement.x, placement.y, placement.zoom);
    let (width, height) = match p.mode {
        PlacementMode::Fill | PlacementMode::Fit => {
            let sx = view.width / image.width;
            let sy = view.height / image.height;
            let scale = if p.mode == PlacementMode::Fill { sx.max(sy) } else { sx.min(sy) };
            (image.width * scale, image.height * scale)
        }
        PlacementMode::Center => (image.width, image.height),
        PlacementMode::Stretch => (view.width, view.height),
    };
    let (width, height) = (width * p.zoom, height * p.zoom);
    Some(Rect { x: (view.width - width) * p.x, y: (view.height - height) * p.y, width, height })
}

/// What a layer shows for a placement: `frame`, the part of the view the
/// picture covers (top-left origin), and `contents`, the part of the picture
/// drawn there in unit coordinates (top-left origin), Core Animation's
/// `contentsRect` before the flip to a bottom-left layer.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Visible {
    pub frame: Rect,
    pub contents: Rect,
}

/// The visible part of [`placement_rect`]: nil when it has no area or misses the view.
pub fn visible(image: Size, view: Size, placement: &Placement) -> Option<Visible> {
    let drawn = placement_rect(image, view, placement)?;
    let left = drawn.x.max(0.0);
    let top = drawn.y.max(0.0);
    let right = (drawn.x + drawn.width).min(view.width);
    let bottom = (drawn.y + drawn.height).min(view.height);
    if right <= left || bottom <= top {
        return None;
    }
    let frame = Rect { x: left, y: top, width: right - left, height: bottom - top };
    let contents = Rect {
        x: (left - drawn.x) / drawn.width,
        y: (top - drawn.y) / drawn.height,
        width: frame.width / drawn.width,
        height: frame.height / drawn.height,
    };
    Some(Visible { frame, contents })
}

/// The anchor after the picture is dragged by `dx`, `dy` points (right and
/// down positive): the picture follows the pointer until an edge would show,
/// then stops. An axis where the drawn picture is exactly the view's size
/// does not move.
pub fn dragged(image: Size, view: Size, placement: &Placement, dx: f64, dy: f64) -> Placement {
    let Some(drawn) = placement_rect(image, view, placement) else { return *placement };
    let step = |anchor: f64, delta: f64, room: f64| {
        if room.abs() < 1e-9 { anchor } else { (anchor + delta / room).clamp(0.0, 1.0) }
    };
    Placement::clamped(
        placement.mode,
        step(placement.x, dx, view.width - drawn.width),
        step(placement.y, dy, view.height - drawn.height),
        placement.zoom,
    )
}

/// The id `appearance.backgroundPlacement` keys a shown picture by, so the
/// app (which knows the picture it draws) and Settings (which knows the
/// stored choice) read and write the same entry:
///
/// - a dynamic macOS wallpaper pinned to a moment of its day
///   (`system:PATH|frame:N|light` or `|dark`) is its file, `system:PATH`, so
///   a placement stays as the frames change and adds no key per frame;
/// - a Light and Dark pair (`appearance:A|B`) is not one picture: each side
///   keys itself (callers resolve the pair to the side shown first);
/// - a mode, a shuffle, `none` or an empty id has no picture: `None`.
///
/// Any other id is its own key.
pub fn placement_key(picture_id: &str) -> Option<&str> {
    let id = picture_id.trim();
    let no_picture = ["none", "daily", "appearance", "schedule"];
    if id.is_empty()
        || no_picture.contains(&id)
        || id.starts_with("folder:")
        || id.starts_with("appearance:")
    {
        return None;
    }
    if let Some(path) = id.strip_prefix("system:")
        && let Some((file, moment)) = path.rsplit_once("|frame:")
    {
        let frame = moment.strip_suffix("|light").or_else(|| moment.strip_suffix("|dark"));
        if frame.is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit())) {
            return id.get(.."system:".len() + file.len());
        }
    }
    Some(id)
}

/// Whether `value` is a valid `appearance.backgroundPlacement`: an object of
/// non-empty picture ids to placement texts ([`Placement::parse`]).
pub fn is_placement_map(value: &Value) -> bool {
    value.as_object().is_some_and(|members| {
        members.iter().all(|(id, value)| {
            !id.trim().is_empty() && value.as_str().and_then(Placement::parse).is_some()
        })
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const WIDE: Size = Size { width: 2000.0, height: 1000.0 };
    const SQUARE: Size = Size { width: 400.0, height: 400.0 };

    fn place(text: &str) -> Placement {
        Placement::parse(text).unwrap_or_else(|| panic!("{text} parses"))
    }

    fn close(a: Rect, b: Rect) {
        let eq = |x: f64, y: f64| (x - y).abs() < 1e-6;
        assert!(
            eq(a.x, b.x) && eq(a.y, b.y) && eq(a.width, b.width) && eq(a.height, b.height),
            "{a:?} != {b:?}"
        );
    }

    #[test]
    fn unset_is_the_centered_fill_of_today() {
        let rect = placement_rect(WIDE, SQUARE, &Placement::default()).unwrap();
        // resizeAspectFill: scale 0.4, 800x400 centered on the 400x400 view.
        close(rect, Rect { x: -200.0, y: 0.0, width: 800.0, height: 400.0 });
        // A tall view crops the sides of a wide picture, centered.
        close(
            placement_rect(WIDE, Size { width: 300.0, height: 600.0 }, &Placement::default())
                .unwrap(),
            Rect { x: -450.0, y: 0.0, width: 1200.0, height: 600.0 },
        );
    }

    #[test]
    fn fit_shows_the_whole_picture() {
        let rect = placement_rect(WIDE, SQUARE, &place("fit")).unwrap();
        close(rect, Rect { x: 0.0, y: 100.0, width: 400.0, height: 200.0 });
        // Anchored to the top.
        close(
            placement_rect(WIDE, SQUARE, &place("fit 0.5 0")).unwrap(),
            Rect { x: 0.0, y: 0.0, width: 400.0, height: 200.0 },
        );
    }

    #[test]
    fn center_and_stretch() {
        let small = Size { width: 100.0, height: 50.0 };
        close(
            placement_rect(small, SQUARE, &place("center")).unwrap(),
            Rect { x: 150.0, y: 175.0, width: 100.0, height: 50.0 },
        );
        close(
            placement_rect(WIDE, SQUARE, &place("stretch")).unwrap(),
            Rect { x: 0.0, y: 0.0, width: 400.0, height: 400.0 },
        );
    }

    #[test]
    fn a_filled_picture_never_shows_an_empty_edge() {
        for x in [0.0, 0.1, 0.5, 0.9, 1.0] {
            for y in [0.0, 0.5, 1.0] {
                for zoom in [1.0, 1.7, 4.0] {
                    let p = Placement::clamped(PlacementMode::Fill, x, y, zoom);
                    let r = placement_rect(WIDE, SQUARE, &p).unwrap();
                    assert!(r.x <= 1e-9 && r.y <= 1e-9, "{p:?} {r:?}");
                    assert!(
                        r.x + r.width >= SQUARE.width - 1e-9
                            && r.y + r.height >= SQUARE.height - 1e-9,
                        "{p:?} {r:?}"
                    );
                }
            }
        }
        // Anchors past the range clamp, so the picture still covers.
        let p = Placement::clamped(PlacementMode::Fill, -3.0, 9.0, 1.0);
        assert_eq!((p.x, p.y), (0.0, 1.0));
    }

    #[test]
    fn the_anchor_picks_the_part_that_shows() {
        close(
            placement_rect(WIDE, SQUARE, &place("fill 0 0.5")).unwrap(),
            Rect { x: 0.0, y: 0.0, width: 800.0, height: 400.0 },
        );
        close(
            placement_rect(WIDE, SQUARE, &place("fill 1 0.5")).unwrap(),
            Rect { x: -400.0, y: 0.0, width: 800.0, height: 400.0 },
        );
    }

    #[test]
    fn zoom_scales_around_the_anchor() {
        // 2x: 1600x800, centered.
        close(
            placement_rect(WIDE, SQUARE, &place("fill 0.5 0.5 2")).unwrap(),
            Rect { x: -600.0, y: -200.0, width: 1600.0, height: 800.0 },
        );
        // The zoom is clamped to 1...4.
        let p = Placement::clamped(PlacementMode::Fill, 0.5, 0.5, 10.0);
        assert_eq!(p.zoom, 4.0);
        // A zoomed fit can run past the view.
        let r = placement_rect(WIDE, SQUARE, &place("fit 0.5 0.5 3")).unwrap();
        close(r, Rect { x: -400.0, y: -100.0, width: 1200.0, height: 600.0 });
    }

    #[test]
    fn visible_is_the_cropped_part() {
        let v = visible(WIDE, SQUARE, &Placement::default()).unwrap();
        close(v.frame, Rect { x: 0.0, y: 0.0, width: 400.0, height: 400.0 });
        close(v.contents, Rect { x: 0.25, y: 0.0, width: 0.5, height: 1.0 });
        let fit = visible(WIDE, SQUARE, &place("fit")).unwrap();
        close(fit.frame, Rect { x: 0.0, y: 100.0, width: 400.0, height: 200.0 });
        close(fit.contents, Rect { x: 0.0, y: 0.0, width: 1.0, height: 1.0 });
    }

    #[test]
    fn dragging_moves_the_picture_with_the_pointer_until_an_edge() {
        // Fill: 800 wide in 400, room -400. Dragging right 100 shows more of the left.
        let p = dragged(WIDE, SQUARE, &Placement::default(), 100.0, 50.0);
        assert!((p.x - 0.25).abs() < 1e-9, "{p:?}");
        // No vertical room: y stays.
        assert_eq!(p.y, 0.5);
        let r = placement_rect(WIDE, SQUARE, &p).unwrap();
        assert!((r.x - -100.0).abs() < 1e-9, "the picture moved 100 points right: {r:?}");
        // Far past the edge, it stops there.
        let p = dragged(WIDE, SQUARE, &Placement::default(), 10_000.0, 0.0);
        assert_eq!(p.x, 0.0);
    }

    #[test]
    fn no_area_has_no_rect() {
        assert!(
            placement_rect(Size { width: 0.0, height: 1.0 }, SQUARE, &Placement::default())
                .is_none()
        );
        assert!(
            placement_rect(WIDE, Size { width: 10.0, height: 0.0 }, &Placement::default())
                .is_none()
        );
        assert!(
            placement_rect(WIDE, Size { width: f64::NAN, height: 1.0 }, &Placement::default())
                .is_none()
        );
    }

    #[test]
    fn text_round_trips() {
        for text in [
            "fill",
            "fit",
            "center",
            "stretch",
            "fill 0.3 0.7",
            "fill 0.3 0.7 2",
            "fit 0 1",
            "fill 0.5 0.5 1.25",
        ] {
            assert_eq!(place(text).to_text(), text);
        }
        assert_eq!(place("fill 0.5 0.5 1").to_text(), "fill");
        assert_eq!(
            Placement::clamped(PlacementMode::Fill, 1.0 / 3.0, 0.5, 1.0).to_text(),
            "fill 0.333 0.5"
        );
        assert_eq!(place("  fit   0.25  0.75 ").to_text(), "fit 0.25 0.75");
    }

    #[test]
    fn bad_text_is_refused() {
        for text in [
            "",
            "cover",
            "Fill",
            "fill 0.5",
            "fill 2 0.5",
            "fill 0.5 -0.1",
            "fill 0.5 0.5 0.5",
            "fill 0.5 0.5 5",
            "fill 0.5 0.5 1 1",
            "fill a b",
            "fill NaN 0.5",
            "fill inf 0.5",
        ] {
            assert!(Placement::parse(text).is_none(), "{text:?} is refused");
        }
    }

    #[test]
    fn the_map_holds_one_placement_per_picture() {
        use serde_json::json;
        assert!(is_placement_map(&json!({})));
        assert!(is_placement_map(
            &json!({ "munch-scream": "fit", "file:/Users/me/a.png": "fill 0.2 0.8 1.5" })
        ));
        for bad in [
            json!("fit"),
            json!([]),
            json!({ "a": "cover" }),
            json!({ "a": 1 }),
            json!({ "": "fit" }),
            json!({ " ": "fit" }),
        ] {
            assert!(!is_placement_map(&bad), "{bad} is refused");
        }
    }
}
