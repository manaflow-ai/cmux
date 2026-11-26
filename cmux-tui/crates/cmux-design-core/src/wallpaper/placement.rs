//! Where a background picture lies in its window (Swift `BackdropPlacement`, the
//! `appearance.backgroundPlacement` entry), and the adjust overlay's gestures
//! (Swift `BackdropAdjustOverlay`). The same math as cmux-config's `backdrop_placement`, which
//! owns the setting; its fixture `backdrop-placement-cases.json` pins both.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// How the picture is scaled before the anchor and zoom apply.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Mode {
    Fill,
    Fit,
    Center,
    Stretch,
}

impl Mode {
    /// The setting's word.
    pub fn name(self) -> &'static str {
        match self {
            Self::Fill => "fill",
            Self::Fit => "fit",
            Self::Center => "center",
            Self::Stretch => "stretch",
        }
    }

    fn parse(text: &str) -> Option<Self> {
        [Self::Fill, Self::Fit, Self::Center, Self::Stretch].into_iter().find(|m| m.name() == text)
    }
}

/// The smallest and largest zoom.
pub const ZOOM_RANGE: (f64, f64) = (1.0, 4.0);

/// One picture's placement: a mode, an anchor (0...1 from the top-left) and a zoom (1...4).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Placement {
    pub mode: Mode,
    pub x: f64,
    pub y: f64,
    pub zoom: f64,
}

impl Default for Placement {
    /// `centeredFill`: the picture fills the view, centered.
    fn default() -> Self {
        Self { mode: Mode::Fill, x: 0.5, y: 0.5, zoom: 1.0 }
    }
}

/// A width and height in points.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Size {
    pub width: f64,
    pub height: f64,
}

/// A rect in points.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Rect {
    pub fn max_x(&self) -> f64 {
        self.x + self.width
    }
    pub fn max_y(&self) -> f64 {
        self.y + self.height
    }
    pub fn mid_x(&self) -> f64 {
        self.x + self.width / 2.0
    }
    pub fn mid_y(&self) -> f64 {
        self.y + self.height / 2.0
    }
}

impl Placement {
    /// Swift's init: the anchor and zoom clamped to their ranges, NaN the default.
    pub fn new(mode: Mode, x: f64, y: f64, zoom: f64) -> Self {
        let unit = |v: f64| if v.is_nan() { 0.5 } else { v.clamp(0.0, 1.0) };
        let zoom = if zoom.is_nan() { 1.0 } else { zoom.clamp(ZOOM_RANGE.0, ZOOM_RANGE.1) };
        Self { mode, x: unit(x), y: unit(y), zoom }
    }

    /// Reads `"mode [x y [zoom]]"`; out-of-range values are refused, not clamped.
    pub fn parse(text: &str) -> Option<Self> {
        let parts: Vec<&str> = text.split_whitespace().collect();
        let mode = Mode::parse(parts.first()?)?;
        let number = |part: &str| {
            part.chars()
                .all(|c| c.is_ascii_digit() || "+-.eE".contains(c))
                .then(|| part.parse::<f64>().ok())
                .flatten()
                .filter(|v| v.is_finite())
        };
        let unit = |part: &str| number(part).filter(|v| (0.0..=1.0).contains(v));
        match parts.len() {
            1 => Some(Self::new(mode, 0.5, 0.5, 1.0)),
            3 => Some(Self::new(mode, unit(parts[1])?, unit(parts[2])?, 1.0)),
            4 => {
                let zoom =
                    number(parts[3]).filter(|z| (ZOOM_RANGE.0..=ZOOM_RANGE.1).contains(z))?;
                Some(Self::new(mode, unit(parts[1])?, unit(parts[2])?, zoom))
            }
            _ => None,
        }
    }

    /// The shortest text that reads back the same.
    pub fn text(&self) -> String {
        let number = |v: f64| {
            let text = format!("{v:.3}");
            let text = text.trim_end_matches('0').trim_end_matches('.');
            if text == "-0" { "0".to_string() } else { text.to_string() }
        };
        let mut out = self.mode.name().to_string();
        if self.x != 0.5 || self.y != 0.5 || self.zoom != 1.0 {
            out.push_str(&format!(" {} {}", number(self.x), number(self.y)));
        }
        if self.zoom != 1.0 {
            out.push_str(&format!(" {}", number(self.zoom)));
        }
        out
    }

    /// Where the whole picture is drawn in a `view`-sized view (top-left origin); nil without area.
    pub fn rect(&self, image: Size, view: Size) -> Option<Rect> {
        let positive = |v: f64| v.is_finite() && v > 0.0;
        if !(positive(image.width)
            && positive(image.height)
            && positive(view.width)
            && positive(view.height))
        {
            return None;
        }
        let (width, height) = match self.mode {
            Mode::Fill | Mode::Fit => {
                let sx = view.width / image.width;
                let sy = view.height / image.height;
                let scale = if self.mode == Mode::Fill { sx.max(sy) } else { sx.min(sy) };
                (image.width * scale, image.height * scale)
            }
            Mode::Center => (image.width, image.height),
            Mode::Stretch => (view.width, view.height),
        };
        let (width, height) = (width * self.zoom, height * self.zoom);
        Some(Rect {
            x: (view.width - width) * self.x,
            y: (view.height - height) * self.y,
            width,
            height,
        })
    }

    /// The part of [`Self::rect`] inside the view, and the unit rect of the picture drawn there.
    pub fn visible(&self, image: Size, view: Size) -> Option<Visible> {
        let drawn = self.rect(image, view)?;
        let left = drawn.x.max(0.0);
        let top = drawn.y.max(0.0);
        let right = drawn.max_x().min(view.width);
        let bottom = drawn.max_y().min(view.height);
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

    /// [`Self::visible`] for a bottom-left layer in `bounds`: the frame and `contentsRect`.
    pub fn layer_frame(&self, image: Size, bounds: Rect) -> Option<Visible> {
        let view = Size { width: bounds.width, height: bounds.height };
        let shown = self.visible(image, view)?;
        Some(Visible {
            frame: Rect {
                x: bounds.x + shown.frame.x,
                y: bounds.max_y() - shown.frame.max_y(),
                width: shown.frame.width,
                height: shown.frame.height,
            },
            contents: Rect {
                x: shown.contents.x,
                y: 1.0 - shown.contents.max_y(),
                width: shown.contents.width,
                height: shown.contents.height,
            },
        })
    }

    /// [`Self::rect`] in a bottom-left `bounds`.
    pub fn drawn_frame(&self, image: Size, bounds: Rect) -> Option<Rect> {
        let drawn = self.rect(image, Size { width: bounds.width, height: bounds.height })?;
        Some(Rect {
            x: bounds.x + drawn.x,
            y: bounds.max_y() - drawn.max_y(),
            width: drawn.width,
            height: drawn.height,
        })
    }

    /// The placement after a drag of `dx`, `dy` points (right and down): the picture follows the
    /// pointer until an edge would show.
    pub fn dragged(&self, image: Size, view: Size, dx: f64, dy: f64) -> Self {
        let Some(drawn) = self.rect(image, view) else { return *self };
        let step = |anchor: f64, delta: f64, room: f64| {
            if room.abs() < 1e-9 { anchor } else { (anchor + delta / room).clamp(0.0, 1.0) }
        };
        Self::new(
            self.mode,
            step(self.x, dx, view.width - drawn.width),
            step(self.y, dy, view.height - drawn.height),
            self.zoom,
        )
    }

    /// The zoom times `factor`, clamped.
    pub fn zoomed(&self, factor: f64) -> Self {
        Self::new(self.mode, self.x, self.y, self.zoom * factor)
    }
}

/// What a layer shows: `frame` in the view, `contents` the unit rect of the picture.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Visible {
    pub frame: Rect,
    pub contents: Rect,
}

/// The setting's map, read: blank ids and texts that don't read are dropped.
pub fn map(raw: &BTreeMap<String, String>) -> BTreeMap<String, Placement> {
    raw.iter()
        .filter(|(id, _)| !id.trim().is_empty())
        .filter_map(|(id, text)| Placement::parse(text).map(|p| (id.clone(), p)))
        .collect()
}

/// The entry a shown picture id keys its placement by: a dynamic macOS picture's moment keys its
/// file; modes, shuffles, pairs and nothing have none.
pub fn key(picture_id: &str) -> Option<&str> {
    let id = picture_id.trim();
    if id.is_empty()
        || ["none", "daily", "appearance", "schedule"].contains(&id)
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

/// The adjust overlay's drag from `from` to `to` (AppKit points: y grows up).
pub fn overlay_dragged(
    placement: &Placement,
    image: Size,
    view: Size,
    from: (f64, f64),
    to: (f64, f64),
) -> Placement {
    placement.dragged(image, view, to.0 - from.0, from.1 - to.1)
}

/// The zoom factor of one scroll step: up zooms in; a trackpad's fine deltas scale less.
pub fn scroll_zoom(delta_y: f64, precise: bool) -> f64 {
    (delta_y * if precise { 0.005 } else { 0.05 }).exp()
}

/// A button on the adjust overlay's bar.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Choice {
    Fill,
    Fit,
    Center,
    Reset,
    Done,
}

/// What a bar button does to `placement`; nil for Done.
pub fn choose(choice: Choice, placement: &Placement) -> Option<Placement> {
    match choice {
        Choice::Fill => Some(Placement::new(Mode::Fill, placement.x, placement.y, 1.0)),
        Choice::Fit => Some(Placement::new(Mode::Fit, placement.x, placement.y, 1.0)),
        Choice::Center => Some(Placement::new(Mode::Center, 0.5, 0.5, 1.0)),
        Choice::Reset => Some(Placement::default()),
        Choice::Done => None,
    }
}
