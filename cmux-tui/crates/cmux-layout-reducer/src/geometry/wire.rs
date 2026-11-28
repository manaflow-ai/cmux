//! The JSON operations over cmux-layout-reducer-ffi's `cmux_layout_reducer_json` channel (ops
//! `layout_geometry_*`), one per Swift entry point the app calls. Requests and replies are camelCase;
//! a rect is `{x, y, w, h}`, a missing optional field takes the Swift default, and a `None` reply
//! (Swift `nil` or `CGRect.null`) is JSON `null`.

use super::divider_band::DividerBand;
use super::dock_strip::{self, Docks, FrameOrientation};
use super::drop_zones::{
    self, Bars, CLASSIC_PANE_PADDING, DropGeometry, DropStyle, DropTarget, PaneDropZone,
};
use super::pane_chrome::{self, ChromeStyle};
use super::{DockEdge, Point, Rect, Size, SplitAxis};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};

/// The prefix every operation here starts with.
pub const PREFIX: &str = "layout_geometry_";

/// Whether `operation` is one of these.
pub fn serves(operation: &str) -> bool {
    operation.starts_with(PREFIX)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ZoneRequest {
    point: Point,
    rect: Rect,
    #[serde(default)]
    header: f64,
    #[serde(default)]
    footer: f64,
    #[serde(default)]
    style: DropStyle,
    previous: Option<PaneDropZone>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TargetRequest {
    point: Point,
    screen: String,
    geometry: DropGeometry,
    #[serde(default)]
    bars: Bars,
    #[serde(default)]
    style: DropStyle,
    previous: Option<DropTarget>,
    /// Set: `point` is in view coordinates with the strip at this offset (`target(atView:)`).
    offset: Option<f64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DockTargetRequest {
    point: Point,
    screen: String,
    geometry: DropGeometry,
    #[serde(default)]
    style: DropStyle,
    #[serde(default)]
    top_inset: f64,
    #[serde(default)]
    bottom_inset: f64,
    previous: Option<DropTarget>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
enum RectKind {
    Region,
    Highlight,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RectRequest {
    kind: RectKind,
    target: DropTarget,
    geometry: DropGeometry,
    #[serde(default)]
    style: DropStyle,
    /// Set: the rect in view coordinates with the strip at this offset.
    offset: Option<f64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ClassicRequest {
    body: Rect,
    zone: PaneDropZone,
    padding: Option<f64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PartsRequest {
    /// Each column's dock edge in daemon order, `null` for a strip column.
    edges: Vec<Option<DockEdge>>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PlaceRequest {
    #[serde(default)]
    docks: Docks,
    viewport: Size,
    gap: f64,
    #[serde(default)]
    orientation: FrameOrientation,
    scale: Option<f64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BandRequest {
    axis: SplitAxis,
    center: f64,
    line_thickness: f64,
    hit_thickness: f64,
    cross_start: f64,
    cross_length: f64,
    scale: Option<f64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ChromeRequest {
    #[serde(default)]
    style: ChromeStyle,
    cell: Option<Rect>,
    /// `roundedRect(inPadded:...)`'s inputs; the padded rect defaults to the cell's content rect.
    padded: Option<Rect>,
    #[serde(default)]
    header: f64,
    #[serde(default)]
    footer: f64,
    #[serde(default)]
    leading: f64,
    scale: Option<f64>,
}

fn parse<T: DeserializeOwned>(request: Value) -> Result<T, String> {
    serde_json::from_value(request).map_err(|error| error.to_string())
}

fn to_value<T: serde::Serialize>(value: T) -> Result<Value, String> {
    serde_json::to_value(value).map_err(|error| error.to_string())
}

/// Answer `operation` for `request`.
pub fn call(operation: &str, request: Value) -> Result<Value, String> {
    match operation.strip_prefix(PREFIX).unwrap_or_default() {
        "drop_zone" => {
            let r: ZoneRequest = parse(request)?;
            to_value(drop_zones::zone(r.point, r.rect, r.header, r.footer, &r.style, r.previous))
        }
        "drop_target" => {
            let r: TargetRequest = parse(request)?;
            let previous = r.previous.as_ref();
            to_value(match r.offset {
                Some(offset) => drop_zones::target_in_view(
                    r.point,
                    offset,
                    &r.screen,
                    &r.geometry,
                    &r.bars,
                    &r.style,
                    previous,
                ),
                None => {
                    drop_zones::target(r.point, &r.screen, &r.geometry, &r.bars, &r.style, previous)
                }
            })
        }
        "dock_target" => {
            let r: DockTargetRequest = parse(request)?;
            to_value(drop_zones::dock_target(
                r.point,
                &r.screen,
                &r.geometry,
                &r.style,
                r.top_inset,
                r.bottom_inset,
                r.previous.as_ref(),
            ))
        }
        "drop_rect" => {
            let r: RectRequest = parse(request)?;
            to_value(match (r.kind, r.offset) {
                (RectKind::Region, None) => {
                    drop_zones::region_rect(&r.target, &r.geometry, &r.style)
                }
                (RectKind::Region, Some(offset)) => {
                    drop_zones::region_rect_in_view(&r.target, offset, &r.geometry, &r.style)
                }
                (RectKind::Highlight, None) => {
                    drop_zones::highlight_rect(&r.target, &r.geometry, &r.style)
                }
                (RectKind::Highlight, Some(offset)) => {
                    drop_zones::highlight_rect_in_view(&r.target, offset, &r.geometry, &r.style)
                }
            })
        }
        "classic_highlight" => {
            let r: ClassicRequest = parse(request)?;
            to_value(drop_zones::classic_pane_highlight(
                r.body,
                r.zone,
                r.padding.unwrap_or(CLASSIC_PANE_PADDING),
            ))
        }
        "dock_parts" => {
            let r: PartsRequest = parse(request)?;
            to_value(dock_strip::parts(&r.edges))
        }
        "dock_place" => {
            let r: PlaceRequest = parse(request)?;
            to_value(dock_strip::place(
                &r.docks,
                r.viewport,
                r.gap,
                r.orientation,
                r.scale.unwrap_or(2.),
            ))
        }
        "owns_corners" => {
            #[derive(Deserialize)]
            struct Corners {
                edge: DockEdge,
                #[serde(default)]
                orientation: FrameOrientation,
            }
            let r: Corners = parse(request)?;
            to_value(dock_strip::owns_corners(r.edge, r.orientation))
        }
        "divider_band" => {
            let r: BandRequest = parse(request)?;
            to_value(DividerBand::new(
                r.axis,
                r.center,
                r.line_thickness,
                r.hit_thickness,
                r.cross_start,
                r.cross_length,
                r.scale.unwrap_or(2.),
            ))
        }
        "pane_chrome" => {
            let r: ChromeRequest = parse(request)?;
            let content = r.cell.map(|cell| pane_chrome::content_rect(cell, r.style.pane_padding));
            let rounded = r
                .padded
                .or(content)
                .map(|padded| pane_chrome::rounded_rect(padded, r.header, r.footer, r.leading));
            Ok(json!({
                "stripGap": r.style.strip_gap(),
                "effectiveDividerHitThickness": r.style.effective_divider_hit_thickness(),
                "columnEdgeLineThickness": r.style.column_edge_line_thickness(),
                "columnEdgeHitThickness": r.style.column_edge_hit_thickness(),
                "contentRect": content,
                "roundedRect": rounded,
                "cornerRadius": rounded.map(|rect| pane_chrome::corner_radius(rect, r.style.pane_corner_radius)),
                "hairlineWidth": pane_chrome::hairline_width(r.scale.unwrap_or(2.)),
            }))
        }
        _ => Err(format!("unknown operation {operation}")),
    }
}
