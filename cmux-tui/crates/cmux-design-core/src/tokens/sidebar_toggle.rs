//! The sidebar toggle's drawn glyphs: ports `SidebarToggleGlyph.swift` (CmuxNextDesign): the
//! glyph names (`name(sidebarHidden:)`, `slideName(progress:)`), the name parse and image size of
//! `image(named:pointSize:)`, and `draw(hidden:progress:in:pointSize:)`'s geometry as a list of
//! [`Mark`]s (rounded rects, polylines and a clipped fill, all in a y-down canvas).
//!
//! Skipped: the `NSImage`/`NSBezierPath` drawing itself (stroking, filling, the clip and the
//! template flag); Swift keeps drawing the marks this module computes.
//!
//! Ops: `tokens.sidebar_toggle_name`, `tokens.sidebar_toggle_slide_name`,
//! `tokens.sidebar_toggle_parse`, `tokens.sidebar_toggle_image_size`, `tokens.sidebar_toggle_draw`,
//! `tokens.sidebar_toggle_image`, `tokens.sidebar_toggle_glyphs`.

pub use crate::tokens::plus_button::{Point, Rect};

use crate::ops::{OpError, OpResult, parse, reply};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// `SidebarToggleGlyph.prefix`.
pub const PREFIX: &str = "cmux.sidebarToggle.";
/// `SidebarToggleGlyph.slideSteps`.
pub const SLIDE_STEPS: i64 = 48;

/// `SidebarToggleGlyph`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Glyph {
    /// `panel`: the bar slides from the divider to the left edge.
    Panel,
    /// `railFilled`.
    RailFilled,
    /// `railOnly`.
    RailOnly,
    /// `chevronPanel`.
    ChevronPanel,
    /// `twoColumn`.
    TwoColumn,
    /// `listRail`.
    ListRail,
    /// `thickEdge`.
    ThickEdge,
}

impl Glyph {
    /// `allCases`, in Swift's order.
    pub const ALL: [Glyph; 7] = [
        Glyph::Panel,
        Glyph::RailFilled,
        Glyph::RailOnly,
        Glyph::ChevronPanel,
        Glyph::TwoColumn,
        Glyph::ListRail,
        Glyph::ThickEdge,
    ];

    /// `rawValue`.
    pub fn raw_value(self) -> &'static str {
        match self {
            Glyph::Panel => "panel",
            Glyph::RailFilled => "railFilled",
            Glyph::RailOnly => "railOnly",
            Glyph::ChevronPanel => "chevronPanel",
            Glyph::TwoColumn => "twoColumn",
            Glyph::ListRail => "listRail",
            Glyph::ThickEdge => "thickEdge",
        }
    }

    /// `init(rawValue:)`.
    pub fn from_raw(raw: &str) -> Option<Glyph> {
        Glyph::ALL.into_iter().find(|g| g.raw_value() == raw)
    }

    /// `name(sidebarHidden:)`.
    pub fn name(self, sidebar_hidden: bool) -> String {
        format!("{PREFIX}{}{}", self.raw_value(), if sidebar_hidden { ".hidden" } else { ".shown" })
    }
}

/// `slideName(progress:)`: the `panel` frame `progress` of the way from shown (0) to hidden (1).
pub fn slide_name(progress: f64) -> String {
    // NaN reads as shown (0), as `max(0.0)` would give.
    let clamped = if progress.is_nan() { 0.0 } else { progress.clamp(0.0, 1.0) };
    let step = (clamped * SLIDE_STEPS as f64).round() as i64;
    if step == 0 {
        return Glyph::Panel.name(false);
    }
    if step == SLIDE_STEPS {
        return Glyph::Panel.name(true);
    }
    format!("{PREFIX}{}.{step}", Glyph::Panel.raw_value())
}

/// What `image(named:)` reads from a name.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ParsedName {
    /// The glyph.
    pub glyph: Glyph,
    /// The sidebar-hidden form.
    pub hidden: bool,
    /// The slide progress (a step / 48; else 1 hidden, 0 otherwise).
    pub progress: f64,
}

/// `image(named:)`'s guard and parse: None for a name that is not one of these glyphs.
pub fn parse_name(name: &str) -> Option<ParsedName> {
    let rest = name.strip_prefix(PREFIX)?;
    let parts: Vec<&str> = rest.split('.').filter(|p| !p.is_empty()).collect();
    if parts.len() != 2 {
        return None;
    }
    let glyph = Glyph::from_raw(parts.first().copied()?)?;
    let state = parts.get(1).copied()?;
    let hidden = state == "hidden";
    let progress = match state.parse::<i64>() {
        Ok(step) => step as f64 / SLIDE_STEPS as f64,
        Err(_) => {
            if hidden {
                1.0
            } else {
                0.0
            }
        }
    };
    Some(ParsedName { glyph, hidden, progress })
}

/// The image's size at `point_size`: a regular SF Symbol panel glyph's box.
pub fn image_size(point_size: f64) -> (f64, f64) {
    ((point_size * 1.38).round(), (point_size * 1.1).round())
}

/// How a mark is painted.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Paint {
    /// Stroked at the glyph's line width, round caps and joins.
    Stroke,
    /// Filled.
    Fill,
}

/// One drawn mark, in black (the template's mask), y down.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum Mark {
    /// `NSBezierPath(roundedRect:xRadius:yRadius:)` with both radii `radius`.
    RoundedRect {
        /// The rectangle.
        rect: Rect,
        /// The corner radius.
        radius: f64,
        /// Stroke or fill.
        paint: Paint,
    },
    /// Stroked polylines (each a move then lines) at `alpha` black.
    Lines {
        /// The subpaths.
        subpaths: Vec<Vec<Point>>,
        /// The stroke's alpha.
        alpha: f64,
    },
    /// `rect` filled, clipped to the rounded rect `clip` with radius `clip_radius`.
    ClippedFill {
        /// The filled rectangle.
        rect: Rect,
        /// The clip.
        clip: Rect,
        /// The clip's radius.
        clip_radius: f64,
    },
}

/// The glyph's drawing: the stroke width and the marks in order.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Drawing {
    /// The stroke width (`line`).
    pub line_width: f64,
    /// The frame the outline draws (`outer`).
    pub outer: Rect,
    /// The outline's radius.
    pub radius: f64,
    /// The rail's width.
    pub rail_width: f64,
    /// The divider's x.
    pub divider_x: f64,
    /// The marks.
    pub marks: Vec<Mark>,
}

fn line(a: Point, b: Point) -> Mark {
    Mark::Lines { subpaths: vec![vec![a, b]], alpha: 1.0 }
}

/// `draw(hidden:progress:in:pointSize:)`'s geometry.
pub fn draw(glyph: Glyph, hidden: bool, progress: f64, canvas: Rect, point_size: f64) -> Drawing {
    let line_w = 1f64.max(point_size * 0.085);
    let inset = line_w / 2.0 + point_size * 0.03;
    let outer = canvas.inset_by(inset, inset);
    let radius = outer.height * 0.22;
    let rail_width = (outer.width * 0.34).round();
    let divider_x = outer.min_x() + rail_width;
    let outline = Mark::RoundedRect { rect: outer, radius, paint: Paint::Stroke };
    let divider = line(Point::new(divider_x, outer.min_y()), Point::new(divider_x, outer.max_y()));
    let paint = |stroked: bool| if stroked { Paint::Stroke } else { Paint::Fill };

    let marks = match glyph {
        Glyph::Panel => {
            let t = progress;
            let x = divider_x + (outer.min_x() + line_w * 2.5 - divider_x) * t;
            let bar_inset = outer.height * 0.27 * t;
            vec![
                outline,
                line(
                    Point::new(x, outer.min_y() + bar_inset),
                    Point::new(x, outer.max_y() - bar_inset),
                ),
            ]
        }
        Glyph::RailFilled => {
            if hidden {
                vec![outline, divider]
            } else {
                let rail = Rect::new(
                    outer.min_x() + line_w * 1.5,
                    outer.min_y() + line_w * 1.5,
                    rail_width - line_w * 2.0,
                    outer.height - line_w * 3.0,
                );
                vec![
                    outline,
                    Mark::RoundedRect { rect: rail, radius: radius * 0.55, paint: Paint::Fill },
                ]
            }
        }
        Glyph::RailOnly => {
            let width = (canvas.width * 0.3).round();
            let bar =
                Rect::new(canvas.min_x() + canvas.width * 0.18, outer.min_y(), width, outer.height);
            let x = bar.max_x() + line_w * 2.2;
            let y1 = outer.min_y() + outer.height * 0.3;
            let y2 = outer.min_y() + outer.height * 0.7;
            vec![
                Mark::RoundedRect { rect: bar, radius: width * 0.42, paint: paint(hidden) },
                Mark::Lines {
                    subpaths: vec![
                        vec![Point::new(x, y1), Point::new(outer.max_x() - line_w, y1)],
                        vec![Point::new(x, y2), Point::new(outer.max_x() - line_w * 3.0, y2)],
                    ],
                    alpha: 1.0,
                },
            ]
        }
        Glyph::ChevronPanel => {
            let content =
                Rect::new(divider_x, outer.min_y(), outer.max_x() - divider_x, outer.height);
            let half = outer.height * 0.2;
            let tip_x = content.mid_x() + if hidden { half / 2.0 } else { -half / 2.0 };
            let back_x = content.mid_x() + if hidden { -half / 2.0 } else { half / 2.0 };
            vec![
                outline,
                divider,
                Mark::Lines {
                    subpaths: vec![vec![
                        Point::new(back_x, content.mid_y() - half),
                        Point::new(tip_x, content.mid_y()),
                        Point::new(back_x, content.mid_y() + half),
                    ]],
                    alpha: 1.0,
                },
            ]
        }
        Glyph::TwoColumn => {
            let gap = line_w * 1.8;
            let left =
                Rect::new(outer.min_x(), outer.min_y(), rail_width - gap / 2.0, outer.height);
            let right = Rect::new(
                outer.min_x() + rail_width + gap / 2.0,
                outer.min_y(),
                outer.max_x() - outer.min_x() - rail_width - gap / 2.0,
                outer.height,
            );
            let small = radius * 0.8;
            vec![
                Mark::RoundedRect { rect: left, radius: small, paint: paint(hidden) },
                Mark::RoundedRect { rect: right, radius: small, paint: Paint::Stroke },
            ]
        }
        Glyph::ListRail => {
            let subpaths = [0.3, 0.5, 0.7]
                .iter()
                .map(|fraction| {
                    let y = outer.min_y() + outer.height * fraction;
                    vec![
                        Point::new(outer.min_x() + line_w * 2.2, y),
                        Point::new(divider_x - line_w * 2.2, y),
                    ]
                })
                .collect();
            vec![outline, divider, Mark::Lines { subpaths, alpha: if hidden { 0.4 } else { 1.0 } }]
        }
        Glyph::ThickEdge => {
            if hidden {
                let x = outer.min_x() + outer.width * 0.2;
                vec![outline, line(Point::new(x, outer.min_y()), Point::new(x, outer.max_y()))]
            } else {
                let bar = Rect::new(outer.min_x(), outer.min_y(), outer.width * 0.2, outer.height);
                vec![outline, Mark::ClippedFill { rect: bar, clip: outer, clip_radius: radius }]
            }
        }
    };
    Drawing { line_width: line_w, outer, radius, rail_width, divider_x, marks }
}

/// `image(named:pointSize:)` without the drawing: the parse, the image size and the marks drawn in
/// the image's own rect (origin zero). None for a name that is not one of these glyphs.
pub fn image(name: &str, point_size: f64) -> Option<(ParsedName, (f64, f64), Drawing)> {
    let parsed = parse_name(name)?;
    let size = image_size(point_size);
    let canvas = Rect::new(0.0, 0.0, size.0, size.1);
    let drawing = draw(parsed.glyph, parsed.hidden, parsed.progress, canvas, point_size);
    Some((parsed, size, drawing))
}

// MARK: JSON

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct NameRequest {
    glyph: Glyph,
    sidebar_hidden: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SlideRequest {
    progress: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ParseRequest {
    name: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SizeRequest {
    point_size: f64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SizeReply {
    width: f64,
    height: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DrawRequest {
    glyph: Glyph,
    #[serde(default)]
    hidden: bool,
    #[serde(default)]
    progress: f64,
    canvas: Rect,
    point_size: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ImageRequest {
    name: String,
    point_size: f64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ImageReply {
    parsed: ParsedName,
    size: SizeReply,
    drawing: Drawing,
}

/// Runs the `tokens.sidebar_toggle_*` ops.
pub fn call(name: &str, request: &Value) -> OpResult {
    match name {
        "sidebar_toggle_name" => {
            let r: NameRequest = parse(request)?;
            reply(&r.glyph.name(r.sidebar_hidden))
        }
        "sidebar_toggle_slide_name" => {
            let r: SlideRequest = parse(request)?;
            reply(&slide_name(r.progress))
        }
        // {name} -> {glyph, hidden, progress} | null
        "sidebar_toggle_parse" => {
            let r: ParseRequest = parse(request)?;
            reply(&parse_name(&r.name))
        }
        "sidebar_toggle_image_size" => {
            let r: SizeRequest = parse(request)?;
            let (width, height) = image_size(r.point_size);
            reply(&SizeReply { width, height })
        }
        "sidebar_toggle_draw" => {
            let r: DrawRequest = parse(request)?;
            reply(&draw(r.glyph, r.hidden, r.progress, r.canvas, r.point_size))
        }
        // {name, pointSize} -> {parsed, size, drawing} | null
        "sidebar_toggle_image" => {
            let r: ImageRequest = parse(request)?;
            let out = image(&r.name, r.point_size).map(|(parsed, (width, height), drawing)| {
                ImageReply { parsed, size: SizeReply { width, height }, drawing }
            });
            reply(&out)
        }
        // {} -> [rawValue, ...]
        "sidebar_toggle_glyphs" => {
            reply(&Glyph::ALL.iter().map(|g| g.raw_value()).collect::<Vec<_>>())
        }
        _ => Err(OpError::Unknown),
    }
}
