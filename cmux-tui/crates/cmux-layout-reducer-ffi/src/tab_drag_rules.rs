//! The tab drag's rules over the JSON channel: what the drag previews and
//! commits at the pointer (`tab_drag_rule_*`, `cmux_layout_reducer::tab_drag_rules`),
//! the small move rules the app's daemon IO follows (`tab_moves_*`), and the
//! drop overlay's rects (`drop_overlay_*`, `cmux_layout_reducer::drop_overlay_geometry`).
//! A mouse move sends one proposal kind and the drag's source counts, never a
//! list that grows with the window; every reply is a few fields.

use crate::ERR_INVALID;
use cmux_layout_reducer::drop_overlay_geometry::{
    self as overlay, Point as OverlayPoint, Rect, RectEdge, Zone,
};
use cmux_layout_reducer::tab_drag_rules::{
    self as rules, Context, DropKind, Edge, Point, SplitDirection,
};
use serde::Deserialize;
use serde_json::{Value, json};

pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(b"tab_drag_rule_")
        || operation.starts_with(b"tab_moves_")
        || operation.starts_with(b"drop_overlay_")
}

#[derive(Deserialize)]
struct KindRequest {
    kind: DropKind,
    context: Context,
}

#[derive(Deserialize)]
struct WinnerRequest {
    kinds: Vec<Option<DropKind>>,
    context: Context,
}

#[derive(Deserialize)]
struct ResolveRequest {
    #[serde(default)]
    kind: Option<DropKind>,
    #[serde(default)]
    refused_reason: Option<String>,
    inside_window: bool,
    #[serde(default)]
    point: Point,
    context: Context,
}

#[derive(Deserialize)]
struct ContextRequest {
    context: Context,
    #[serde(default)]
    pane: Option<String>,
}

#[derive(Deserialize)]
struct EdgeRequest {
    edge: Edge,
}

#[derive(Deserialize)]
struct DockWidthRequest {
    edge: String,
    #[serde(default)]
    width: Option<f64>,
    #[serde(default)]
    beside: Option<f64>,
    #[serde(default)]
    asked_beside: bool,
}

#[derive(Deserialize)]
struct AnchorRequest {
    #[serde(default)]
    column_panes: Vec<String>,
    #[serde(default)]
    screen_panes: Vec<String>,
    #[serde(default)]
    avoiding: Option<String>,
}

#[derive(Deserialize)]
struct SplitPreviewRequest {
    region: Rect,
    zone: Zone,
    gap: f64,
}

#[derive(Deserialize)]
struct InsertionLineRequest {
    region: Rect,
    zone: Zone,
    width: f64,
    length: f64,
}

#[derive(Deserialize)]
struct ZoneRequest {
    zone: Zone,
}

#[derive(Deserialize)]
struct BandRequest {
    rect: Rect,
    edge: RectEdge,
    depth: f64,
}

#[derive(Deserialize)]
struct InsetCardRequest {
    target: Rect,
    fraction: f64,
    max_width: f64,
    height: f64,
}

#[derive(Deserialize)]
struct TabPillRequest {
    target: Rect,
    width: f64,
    height: f64,
    inset: f64,
}

#[derive(Deserialize)]
struct MorphStartRequest {
    pointer: OverlayPoint,
    width: f64,
}

fn parse<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

fn value<T: serde::Serialize>(reply: &T) -> Result<Value, i32> {
    serde_json::to_value(reply).map_err(|_| ERR_INVALID)
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let reply = match operation {
        b"tab_drag_rule_verdict" => {
            let KindRequest { kind, context } = parse(request)?;
            value(&rules::verdict(&kind, &context))?
        }
        b"tab_drag_rule_blocks" => {
            let KindRequest { kind, context } = parse(request)?;
            json!({ "blocks": rules::blocks(&kind, &context) })
        }
        b"tab_drag_rule_winner" => {
            let WinnerRequest { kinds, context } = parse(request)?;
            json!({ "index": rules::winner(&kinds, &context) })
        }
        b"tab_drag_rule_outcome" => {
            let ResolveRequest { kind, inside_window, point, context, .. } = parse(request)?;
            value(&rules::outcome(kind.as_ref(), inside_window, point, &context))?
        }
        b"tab_drag_rule_resolve" => {
            let ResolveRequest { kind, refused_reason, inside_window, point, context } =
                parse(request)?;
            value(&rules::resolve(
                kind.as_ref(),
                refused_reason.as_deref(),
                inside_window,
                point,
                &context,
            ))?
        }
        b"tab_drag_rule_context" => {
            let ContextRequest { context, pane } = parse(request)?;
            json!({
                "empties_source_pane": context.empties_source_pane(),
                "empties_source_workspace": context.empties_source_workspace(),
                "splits_behind": pane.is_some_and(|pane| context.splits_behind(&pane)),
            })
        }
        b"tab_moves_split_behind" => {
            let EdgeRequest { edge } = parse(request)?;
            let (edge, swaps_back) = rules::split_behind(edge);
            json!({ "edge": edge, "swaps_back": swaps_back })
        }
        b"tab_moves_fallback_split" => {
            let EdgeRequest { edge } = parse(request)?;
            let (direction, swaps_back): (SplitDirection, bool) = rules::fallback_split(edge);
            json!({ "direction": direction, "swaps_back": swaps_back })
        }
        b"tab_moves_dock_width" => {
            let DockWidthRequest { edge, width, beside, asked_beside } = parse(request)?;
            match rules::dock_width(&edge, width, beside, asked_beside) {
                Some(width) => json!({ "width": width }),
                None => json!({ "needs_beside": true }),
            }
        }
        b"tab_moves_column_anchor" => {
            let AnchorRequest { column_panes, screen_panes, avoiding } = parse(request)?;
            json!({ "pane": rules::column_anchor(&column_panes, &screen_panes, avoiding.as_deref()) })
        }
        b"drop_overlay_split_preview" => {
            let SplitPreviewRequest { region, zone, gap } = parse(request)?;
            let (incoming, existing) = overlay::split_preview(region, zone, gap);
            json!({ "incoming": incoming, "existing": existing })
        }
        b"drop_overlay_insertion_line" => {
            let InsertionLineRequest { region, zone, width, length } = parse(request)?;
            json!({ "rect": overlay::insertion_line(region, zone, width, length) })
        }
        b"drop_overlay_glow_edges" => {
            let ZoneRequest { zone } = parse(request)?;
            json!({ "edges": overlay::glow_edges(zone) })
        }
        b"drop_overlay_band" => {
            let BandRequest { rect, edge, depth } = parse(request)?;
            json!({ "rect": overlay::band(rect, edge, depth) })
        }
        b"drop_overlay_inset_card" => {
            let InsetCardRequest { target, fraction, max_width, height } = parse(request)?;
            json!({ "rect": overlay::inset_card(target, fraction, max_width, height) })
        }
        b"drop_overlay_tab_pill" => {
            let TabPillRequest { target, width, height, inset } = parse(request)?;
            json!({ "rect": overlay::tab_pill(target, width, height, inset) })
        }
        b"drop_overlay_morph_start" => {
            let MorphStartRequest { pointer, width } = parse(request)?;
            json!({ "rect": overlay::morph_start(pointer, width) })
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&reply).map_err(|_| ERR_INVALID)
}
