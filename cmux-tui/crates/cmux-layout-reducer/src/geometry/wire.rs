//! The JSON operations over cmux-layout-reducer-ffi's `cmux_layout_reducer_json` channel (ops
//! `layout_geometry_*`), one per Swift entry point the app calls. Requests and replies are camelCase;
//! a rect is `{x, y, w, h}`, a missing optional field takes the Swift default, and a `None` reply
//! (Swift `nil` or `CGRect.null`) is JSON `null`.

use super::column_strip::{self, EqualizeColumn};
use super::divider_band::DividerBand;
use super::dock_strip::{self, Docks, FrameOrientation};
use super::drop_preview;
use super::drop_zones::{
    self, Bars, CLASSIC_PANE_PADDING, DropGeometry, DropStyle, DropTarget, PaneDropZone,
};
use super::edge_motion::{
    self, AnimatedFrame, Edges, HandleKind, Influence, MouseArea, MovedEdges, PressScreen,
    ScrollFacts, ShownPixels, Spring,
};
use super::floating_corners::FloatingPaneCorners;
use super::pane_chrome::{self, ChromeStyle};
use super::row_stack::{self, Row, RowStack};
use super::screen::{self, FloatingPane, ScreenGeometry, ScreenLayout, ScreenStyle};
use super::shown_range::ShownResizeRange;
use super::split_layout::{self, DividerGeometry, PointerRatio, PushResize, SplitNode, SplitStyle};
use super::strip_math::{self, StripStart, UniformEdge};
use super::width_ledger::{self, LedgerColumn, LedgerRecord};
use super::window_frame::{self, MOVED_WINDOW_GAP, WindowDock};
use super::{DockEdge, Point, Rect, Size, SplitAxis};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet, HashMap};

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

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SplitLayoutRequest {
    node: SplitNode,
    rect: Rect,
    #[serde(default)]
    style: SplitStyle,
    scale: Option<f64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FirstExtentRequest {
    ratio: f64,
    available: f64,
    minimum_a: f64,
    minimum_b: f64,
    scale: Option<f64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SplitRatioRequest {
    pointer: f64,
    container: Rect,
    axis: SplitAxis,
    #[serde(default)]
    style: SplitStyle,
    #[serde(flatten)]
    options: PointerRatio,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct EvenRatiosRequest {
    root: SplitNode,
    axis: SplitAxis,
    /// Set: the ratios once this pane splits (`changes(splitting:)`); unset: `changes(equalizing:)`.
    pane: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PushResizeRequest {
    split: String,
    column: String,
    #[serde(default)]
    docked: bool,
    trees: Vec<SplitNode>,
    column_width: f64,
    dividers: Vec<DividerGeometry>,
    viewport: f64,
    gap: f64,
    divider_thickness: f64,
    /// The drag deltas to answer `targets(delta:)` for.
    #[serde(default)]
    deltas: Vec<f64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct EdgeThickness {
    line_thickness: f64,
    hit_thickness: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RowStackRequest {
    column: String,
    rows: Vec<Row>,
    #[serde(default)]
    minimum_heights: Vec<f64>,
    frame: Rect,
    gap: f64,
    #[serde(default)]
    fits: bool,
    scale: Option<f64>,
    /// Set: the reply carries the row edges too.
    edges: Option<EdgeThickness>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RowPixelRequest {
    column_height: f64,
    gap: f64,
    permille: Option<f64>,
    height: Option<f64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RowResizeRequest {
    rows: Vec<Row>,
    stack: RowStack,
    upper: String,
    pointer_y: f64,
    #[serde(default)]
    minimums: HashMap<String, f64>,
    #[serde(default)]
    fits: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StripRequest {
    strip: StripStart,
    /// Set: `trading(column, to: width)`; unset: `uniform(width)`.
    column: Option<String>,
    width: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct UniformEdgeRequest {
    edge: UniformEdge,
    place: f64,
    /// Widths to report `edge`, `presented` and `addsTravel` at.
    #[serde(default)]
    probes: Vec<f64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct KeepAliveRequest {
    displayed: BTreeMap<String, Rect>,
    viewport: Rect,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StripFramesRequest {
    widths: Vec<f64>,
    viewport: Size,
    gap: f64,
    scale: Option<f64>,
    #[serde(default)]
    minimum_widths: Vec<f64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StripOffsetsRequest {
    frames: Vec<Rect>,
    content_width: f64,
    viewport_width: f64,
    gap: f64,
    /// The offset to clamp and find the leading column at.
    #[serde(default)]
    offset: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ScrollbarThumbRequest {
    track: Rect,
    offset: f64,
    content_width: f64,
    viewport_width: f64,
    minimum_thumb_width: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ScrollbarOffsetRequest {
    thumb_min_x: f64,
    thumb_width: f64,
    track: Rect,
    max_offset: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ScrollbarPageRequest {
    click_x: f64,
    thumb: Rect,
    offset: f64,
    viewport_width: f64,
    snaps: Vec<f64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct EqualizeRequest {
    columns: Vec<EqualizeColumn>,
    #[serde(default)]
    visible: BTreeSet<String>,
    viewport_width: f64,
    gap: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ScrollAreaRequest {
    window: Rect,
    /// Set: `navigationRect(rect)` with this content width.
    content_width: Option<f64>,
    rect: Option<Rect>,
    /// Set: `cells(of:)` and `overflow(of:in:style:scale:)` of this tree.
    root: Option<SplitNode>,
    #[serde(default)]
    style: SplitStyle,
    #[serde(default)]
    scroll_areas_enabled: bool,
    scale: Option<f64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WindowPlaceRequest {
    docks: Vec<WindowDock>,
    #[serde(default)]
    orientation: FrameOrientation,
    gap: f64,
    rect: Rect,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MovedWindowRequest {
    source: Rect,
    screen: Rect,
    gap: Option<f64>,
    /// Set: `frame(beside:on:avoiding:)`.
    occupied: Option<Vec<Rect>>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LedgerNoteRequest {
    record: Option<LedgerRecord>,
    before: Vec<LedgerColumn>,
    after: Vec<LedgerColumn>,
    viewport_width: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LedgerTakeRequest {
    record: Option<LedgerRecord>,
    current: Vec<LedgerColumn>,
    viewport_width: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ScreenRequest {
    layout: ScreenLayout,
    viewport: Size,
    #[serde(default)]
    style: ScreenStyle,
    scale: Option<f64>,
    /// `shiftingRows`: per row column, its vertical scroll offset.
    #[serde(default)]
    row_offsets: BTreeMap<String, f64>,
    /// `shiftingAreas`: per scroll area, its horizontal scroll offset.
    #[serde(default)]
    area_offsets: BTreeMap<String, f64>,
    /// `placingFloating`: the floating panes, back to front.
    #[serde(default)]
    floating: Vec<FloatingPane>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SplitRoomRequest {
    pane: String,
    axis: SplitAxis,
    layout: ScreenLayout,
    viewport: Size,
    #[serde(default)]
    style: ScreenStyle,
    removing: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CanvasRequest {
    frames: BTreeMap<String, Rect>,
    visible: Rect,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CornersRequest {
    /// Set: `init(uniform:)`; else the card's size and its edges' distances in from the window's.
    uniform: Option<f64>,
    #[serde(default)]
    size: Size,
    #[serde(default)]
    left: f64,
    #[serde(default)]
    top: f64,
    #[serde(default)]
    right: f64,
    #[serde(default)]
    bottom: f64,
    #[serde(default)]
    window_radius: f64,
    #[serde(default)]
    floor: f64,
    /// `contentRadius(inset:)`'s inset.
    #[serde(default)]
    inset: f64,
}

fn yes() -> bool {
    true
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DropPreviewRequest {
    pane: String,
    zone: PaneDropZone,
    layout: ScreenLayout,
    removing: Option<String>,
    #[serde(default)]
    even_sizing: bool,
    #[serde(default = "yes")]
    equalizes_close: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
enum ShownKind {
    Ratio,
    Width,
    Trade,
    DockWidth,
    RowHeights,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ShownRangeRequest {
    /// The screen; its geometry is `compute` of it at `viewport`, with `floating` placed.
    layout: ScreenLayout,
    viewport: Size,
    #[serde(default)]
    style: ScreenStyle,
    scale: Option<f64>,
    strip_offset: Option<f64>,
    #[serde(default)]
    floating: Vec<FloatingPane>,
    kind: ShownKind,
    /// `ratio`: the split.
    split: Option<String>,
    /// `width`, `dockWidth`, `rowHeights`, and the left one of a `trade`.
    column: Option<String>,
    /// `trade`: the right column.
    right: Option<String>,
    /// `rowHeights`: the pane the press is on.
    pane: Option<String>,
    #[serde(default)]
    delta: f64,
}

/// A screen as the edge ops lay it out: `compute` at `viewport` and `scale`, `floating` placed.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct EdgeScreen {
    layout: ScreenLayout,
    viewport: Size,
    #[serde(default)]
    style: ScreenStyle,
    #[serde(default)]
    floating: Vec<FloatingPane>,
}

impl EdgeScreen {
    fn geometry(&self, scale: f64) -> ScreenGeometry {
        ScreenGeometry::compute(&self.layout, self.viewport, &self.style, scale)
            .placing_floating(&self.floating, scale)
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct EdgePlaceRequest {
    frame: AnimatedFrame,
    target: Rect,
    #[serde(default)]
    keeps_shown: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct EdgeSeedRequest {
    frame: AnimatedFrame,
    before: Option<Rect>,
    after: Rect,
    rate: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct EdgePressRequest {
    #[serde(flatten)]
    screen: EdgeScreen,
    scale: Option<f64>,
    /// The screen view's bounds (a docked column's viewport).
    bounds: Size,
    kind: HandleKind,
    /// The handle's frame springs.
    handle: AnimatedFrame,
    /// How the screen draws the line's axis.
    shown: ShownPixels,
    /// The view offset that places the line moves.
    #[serde(default)]
    moves: bool,
    /// Extents from the anchor to answer `valueAt` for.
    #[serde(default)]
    extents: Vec<f64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct EdgeInfluenceRequest {
    kind: HandleKind,
    axis: SplitAxis,
    /// The caught layout and the probe's (both laid out at `scale`, 0 off the pixel grid as the
    /// press lays them).
    caught: EdgeScreen,
    probe: EdgeScreen,
    #[serde(default)]
    scale: f64,
    #[serde(default)]
    frames: BTreeMap<String, AnimatedFrame>,
    targets: Option<BTreeMap<String, Rect>>,
    #[serde(default)]
    speed_change: f64,
    #[serde(default)]
    place_change: f64,
    #[serde(default)]
    clamp_leftover: f64,
    minimum: Size,
    spring: Spring,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct EdgeLowestRequest {
    edges: Edges,
    spring: Spring,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CatchersRequest {
    areas: Vec<MouseArea>,
    pages: Vec<Rect>,
    active: bool,
    visible: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ScrollRouteRequest {
    dx: f64,
    dy: f64,
    /// A discrete wheel notch (no phase); else an undecided gesture's event.
    #[serde(default)]
    notch: bool,
    #[serde(default)]
    ended: bool,
    #[serde(default)]
    facts: ScrollFacts,
}

fn bounds_value(bounds: Option<crate::shown_resize::Bounds>) -> Value {
    bounds.map_or(Value::Null, |bounds| json!({"lower": bounds.lower, "upper": bounds.upper}))
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
        "split_layout" => {
            let r: SplitLayoutRequest = parse(request)?;
            let layout = split_layout::layout(&r.node, r.rect, &r.style, r.scale.unwrap_or(2.));
            Ok(json!({
                "panes": layout.panes,
                "dividers": layout.dividers,
                "minimumSize": split_layout::minimum_size(&r.node, &r.style),
            }))
        }
        "split_first_extent" => {
            let r: FirstExtentRequest = parse(request)?;
            to_value(split_layout::first_extent(
                r.ratio,
                r.available,
                r.minimum_a,
                r.minimum_b,
                r.scale.unwrap_or(2.),
            ))
        }
        "split_ratio" => {
            let r: SplitRatioRequest = parse(request)?;
            to_value(split_layout::ratio_for_pointer(
                r.pointer,
                r.container,
                r.axis,
                &r.style,
                &r.options,
            ))
        }
        "even_ratios" => {
            let r: EvenRatiosRequest = parse(request)?;
            to_value(match r.pane {
                Some(pane) => split_layout::even_ratios_splitting(&pane, r.axis, &r.root),
                None => split_layout::even_ratios_equalizing(&r.root, r.axis),
            })
        }
        "push_resize" => {
            let r: PushResizeRequest = parse(request)?;
            let push = PushResize::new(
                &r.split,
                &r.column,
                r.docked,
                &r.trees,
                r.column_width,
                &r.dividers,
                r.viewport,
                r.gap,
                r.divider_thickness,
            );
            let targets: Vec<_> = match &push {
                Some(push) => r.deltas.iter().map(|&delta| push.targets(delta)).collect(),
                None => vec![],
            };
            Ok(json!({ "push": push, "targets": targets }))
        }
        "row_stack" => {
            let r: RowStackRequest = parse(request)?;
            let scale = r.scale.unwrap_or(2.);
            let stack = RowStack::compute(
                &r.column,
                &r.rows,
                &r.minimum_heights,
                r.frame,
                r.gap,
                r.fits,
                scale,
            );
            let edges =
                r.edges.map(|edges| stack.edges(edges.line_thickness, edges.hit_thickness, scale));
            Ok(json!({
                "scrolls": stack.scrolls(),
                "maxOffset": stack.max_offset(),
                "edges": edges,
                "stack": stack,
            }))
        }
        "row_pixel" => {
            let r: RowPixelRequest = parse(request)?;
            Ok(json!({
                "pixelHeight": r.permille.map(|p| row_stack::pixel_height(p, r.column_height, r.gap)),
                "permille": r.height.map(|h| row_stack::permille(h, r.column_height, r.gap)),
            }))
        }
        "row_resize" => {
            let r: RowResizeRequest = parse(request)?;
            to_value(row_stack::resize_heights(
                &r.rows,
                &r.stack,
                &r.upper,
                r.pointer_y,
                &r.minimums,
                r.fits,
            ))
        }
        "strip_start" => {
            let r: StripRequest = parse(request)?;
            to_value(match r.column {
                Some(column) => r.strip.trading(&column, r.width),
                None => r.strip.uniform(r.width),
            })
        }
        "uniform_edge" => {
            let r: UniformEdgeRequest = parse(request)?;
            let edge = r.edge;
            if edge.index >= edge.widths.len() {
                return Err(format!("index {} past {} widths", edge.index, edge.widths.len()));
            }
            let probes: Vec<_> = r
                .probes
                .iter()
                .map(|&width| {
                    json!({
                        "edge": edge.edge(width),
                        "presented": edge.presented(width),
                        "addsTravel": edge.adds_travel(width),
                    })
                })
                .collect();
            Ok(json!({ "target": edge.target(r.place), "probes": probes }))
        }
        "keep_alive" => {
            let r: KeepAliveRequest = parse(request)?;
            to_value(strip_math::keep_alive(&r.displayed, r.viewport))
        }
        "strip_frames" => {
            let r: StripFramesRequest = parse(request)?;
            let (frames, content_width) = column_strip::frames(
                &r.widths,
                r.viewport,
                r.gap,
                r.scale.unwrap_or(2.),
                &r.minimum_widths,
            );
            Ok(json!({ "frames": frames, "contentWidth": content_width }))
        }
        "strip_offsets" => {
            let r: StripOffsetsRequest = parse(request)?;
            Ok(json!({
                "maxOffset": column_strip::max_offset(r.content_width, r.viewport_width),
                "clamped": column_strip::clamp(r.offset, r.content_width, r.viewport_width),
                "snaps": column_strip::snap_offsets(&r.frames, r.content_width, r.viewport_width, r.gap),
                "leading": column_strip::leading_column_index(&r.frames, r.offset, r.gap),
            }))
        }
        "scrollbar_thumb" => {
            let r: ScrollbarThumbRequest = parse(request)?;
            to_value(column_strip::scrollbar_thumb(
                r.track,
                r.offset,
                r.content_width,
                r.viewport_width,
                r.minimum_thumb_width,
            ))
        }
        "scrollbar_offset" => {
            let r: ScrollbarOffsetRequest = parse(request)?;
            to_value(column_strip::scrollbar_offset(
                r.thumb_min_x,
                r.thumb_width,
                r.track,
                r.max_offset,
            ))
        }
        "scrollbar_page" => {
            let r: ScrollbarPageRequest = parse(request)?;
            to_value(column_strip::scrollbar_page_target(
                r.click_x,
                r.thumb,
                r.offset,
                r.viewport_width,
                &r.snaps,
            ))
        }
        "equalize_columns" => {
            let r: EqualizeRequest = parse(request)?;
            to_value(column_strip::equalize(&r.columns, &r.visible, r.viewport_width, r.gap))
        }
        "scroll_area" => {
            let r: ScrollAreaRequest = parse(request)?;
            let navigation = match (r.content_width, r.rect) {
                (Some(content), Some(rect)) => {
                    Some(column_strip::scroll_area_navigation_rect(r.window, content, rect))
                }
                _ => None,
            };
            let (cells, overflow) = match &r.root {
                Some(root) => (
                    Some(column_strip::scroll_area_cells(root)),
                    column_strip::scroll_area_overflow(
                        root,
                        r.window,
                        &r.style,
                        r.scroll_areas_enabled,
                        r.scale.unwrap_or(2.),
                    )
                    .map(|(id, content)| json!({ "id": id, "content": content })),
                ),
                None => (None, None),
            };
            Ok(json!({ "navigationRect": navigation, "cells": cells, "overflow": overflow }))
        }
        "window_place" => {
            let r: WindowPlaceRequest = parse(request)?;
            to_value(window_frame::place(&r.docks, r.orientation, r.gap, r.rect))
        }
        "moved_window" => {
            let r: MovedWindowRequest = parse(request)?;
            let gap = r.gap.unwrap_or(MOVED_WINDOW_GAP);
            to_value(match r.occupied {
                Some(occupied) => {
                    window_frame::moved_window_frame_avoiding(r.source, r.screen, &occupied, gap)
                }
                None => window_frame::moved_window_frame(r.source, r.screen, gap),
            })
        }
        "width_ledger_note" => {
            let r: LedgerNoteRequest = parse(request)?;
            to_value(width_ledger::note_change(r.record, &r.before, &r.after, r.viewport_width))
        }
        "width_ledger_take" => {
            let r: LedgerTakeRequest = parse(request)?;
            to_value(width_ledger::take(r.record.as_ref(), &r.current, r.viewport_width))
        }
        "screen_compute" => {
            let r: ScreenRequest = parse(request)?;
            let scale = r.scale.unwrap_or(2.);
            let geometry = ScreenGeometry::compute(&r.layout, r.viewport, &r.style, scale)
                .shifting_rows(&r.row_offsets)
                .shifting_areas(&r.area_offsets)
                .placing_floating(&r.floating, scale);
            let navigation: BTreeMap<&String, Rect> = geometry
                .panes
                .keys()
                .filter_map(|pane| geometry.navigation_rect(pane).map(|rect| (pane, rect)))
                .collect();
            let docks: BTreeMap<&String, &str> = geometry
                .panes
                .keys()
                .filter_map(|pane| {
                    geometry.dock_frame(pane).map(|dock| (pane, dock.column.as_str()))
                })
                .collect();
            let mut value = to_value(&geometry)?;
            value["maxOffset"] = json!(geometry.max_offset());
            value["navigationRects"] = to_value(navigation)?;
            value["dockOfPane"] = to_value(docks)?;
            Ok(value)
        }
        "screen_canvas" => {
            let r: CanvasRequest = parse(request)?;
            to_value(ScreenGeometry::canvas(&r.frames, r.visible))
        }
        "split_room" => {
            let r: SplitRoomRequest = parse(request)?;
            to_value(screen::split_placement(
                &r.pane,
                r.axis,
                &r.layout,
                r.viewport,
                &r.style,
                r.removing.as_deref(),
            ))
        }
        "floating_corners" => {
            let r: CornersRequest = parse(request)?;
            let corners = match r.uniform {
                Some(radius) => FloatingPaneCorners::uniform(radius),
                None => FloatingPaneCorners::new(
                    r.size,
                    r.left,
                    r.top,
                    r.right,
                    r.bottom,
                    r.window_radius,
                    r.floor,
                ),
            };
            let mut value = to_value(corners)?;
            value["largest"] = json!(corners.largest());
            value["contentRadius"] = json!(corners.content_radius(r.inset));
            Ok(value)
        }
        "drop_preview" => {
            let r: DropPreviewRequest = parse(request)?;
            to_value(drop_preview::drop_preview(
                &r.pane,
                r.zone,
                &r.layout,
                r.removing.as_deref(),
                r.even_sizing,
                r.equalizes_close,
            ))
        }
        "shown_range" => {
            let r: ShownRangeRequest = parse(request)?;
            let scale = r.scale.unwrap_or(2.);
            let geometry = ScreenGeometry::compute(&r.layout, r.viewport, &r.style, scale)
                .placing_floating(&r.floating, scale);
            let range = ShownResizeRange {
                geometry: &geometry,
                style: &r.style,
                scale,
                strip_offset: r.strip_offset,
            };
            let columns: &[screen::Column] = match &r.layout {
                ScreenLayout::Columns(columns) => columns,
                ScreenLayout::Splits(_) => &[],
            };
            let column = |id: &Option<String>| {
                id.as_ref().and_then(|id| columns.iter().find(|column| &column.id == id))
            };
            Ok(match r.kind {
                ShownKind::Ratio => bounds_value(r.split.and_then(|split| range.ratio(&split))),
                ShownKind::Width => bounds_value(column(&r.column).and_then(|c| range.width(c))),
                ShownKind::DockWidth => {
                    bounds_value(column(&r.column).and_then(|c| range.dock_width(c)))
                }
                ShownKind::Trade => match (column(&r.column), column(&r.right)) {
                    (Some(left), Some(right)) => range
                        .trade(left, right, r.delta, &r.layout)
                        .map_or(Value::Null, |(left, right)| json!({"left": left, "right": right})),
                    _ => Value::Null,
                },
                ShownKind::RowHeights => match (column(&r.column), r.pane) {
                    (Some(c), Some(pane)) => {
                        range.row_heights(&pane, c, r.delta).map_or(Value::Null, |heights| {
                            Value::Array(
                                heights
                                    .into_iter()
                                    .map(|(row, height)| json!({"row": row, "height": height}))
                                    .collect(),
                            )
                        })
                    }
                    _ => Value::Null,
                },
            })
        }
        "edge_place" => {
            let mut r: EdgePlaceRequest = parse(request)?;
            edge_motion::place(&mut r.frame, r.target, r.keeps_shown);
            to_value(r.frame)
        }
        "edge_seed" => {
            let mut r: EdgeSeedRequest = parse(request)?;
            let moved = MovedEdges::new(r.before, r.after);
            edge_motion::seed(&mut r.frame, moved, r.rate);
            Ok(json!({"moved": to_value(moved)?, "frame": to_value(r.frame)?}))
        }
        "edge_press" => {
            let r: EdgePressRequest = parse(request)?;
            let scale = r.scale.unwrap_or(2.);
            let geometry = r.screen.geometry(scale);
            let screen = PressScreen {
                geometry: &geometry,
                layout: &r.screen.layout,
                style: &r.screen.style,
                bounds: r.bounds,
            };
            let caught = edge_motion::press(&r.kind, &screen, &r.handle, |_| (r.shown, r.moves));
            let Some(caught) = caught else {
                return Ok(Value::Null);
            };
            let values = r
                .extents
                .iter()
                .map(|extent| to_value(caught.value_at(*extent, &r.screen.style)))
                .collect::<Result<Vec<_>, _>>()?;
            Ok(json!({
                "value": to_value(&caught.value)?,
                "base": caught.base,
                "axis": to_value(caught.axis)?,
                "speedChange": caught.speed_change,
                "placeChange": caught.place_change,
                "held": caught.held,
                "catches": caught.catches,
                "restLine": edge_motion::rest_line(&r.kind, caught.axis, &geometry),
                "valuesAt": values,
            }))
        }
        "edge_influence" => {
            let r: EdgeInfluenceRequest = parse(request)?;
            let caught = r.caught.geometry(r.scale);
            let probe = r.probe.geometry(r.scale);
            let influence = Influence::new(&r.kind, &caught, &probe, r.axis);
            let mut applied = r.frames.clone();
            if let Some(influence) = &influence {
                for (pane, frame) in &mut applied {
                    let (from, to) =
                        (caught.panes.get(pane).copied(), probe.panes.get(pane).copied());
                    influence.apply(r.speed_change, r.place_change, frame, from, to);
                }
            }
            let negative = edge_motion::may_show_negative_size(
                &r.frames,
                r.targets.as_ref(),
                influence.as_ref(),
                r.speed_change,
                r.clamp_leftover,
                r.minimum,
                r.spring,
            );
            Ok(json!({
                "lineMove": influence.as_ref().map(|i| i.line_move),
                "frames": to_value(applied)?,
                "mayShowNegativeSize": negative,
            }))
        }
        "edge_lowest" => {
            let r: EdgeLowestRequest = parse(request)?;
            Ok(json!(edge_motion::lowest(&r.edges, r.spring)))
        }
        "divider_catchers" => {
            let r: CatchersRequest = parse(request)?;
            let wanted = edge_motion::wanted_catchers(&r.areas, &r.pages, r.active, r.visible);
            Ok(json!(wanted.iter().map(|area| area.id.as_str()).collect::<Vec<_>>()))
        }
        "scroll_route" => {
            let r: ScrollRouteRequest = parse(request)?;
            if r.notch {
                to_value(edge_motion::notch_route(r.dx, r.dy, r.facts))
            } else {
                to_value(edge_motion::undecided_lock(r.dx, r.dy, r.ended, r.facts))
            }
        }
        _ => Err(format!("unknown operation {operation}")),
    }
}
