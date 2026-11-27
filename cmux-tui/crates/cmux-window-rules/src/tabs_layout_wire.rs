//! The JSON requests and replies of the `tab_layout_*` ops the app sends over
//! `cmux_layout_reducer_json`. The vertical ops send the list's inputs and lay it out again.

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::vertical::{self, List};
use super::{
    FadedEdges, Item, LayoutResult, Metrics, ScrollMapping, Slot, Style, TabState, Visibility,
    closing_mode_width, faded_edges, insert_placeholder, insertion_index, layout, offset_revealing,
    resized,
};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LayoutRequest {
    items: Vec<Item>,
    available_width: f64,
    #[serde(default)]
    style: Style,
    metrics: Metrics,
    closing_mode_width: Option<f64>,
    full_width_tab: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ResizedRequest {
    result: LayoutResult,
    available_width: f64,
    #[serde(default)]
    style: Style,
    metrics: Metrics,
    closing_mode_width: Option<f64>,
}

#[derive(Deserialize)]
struct ClosingRequest {
    closing: String,
    result: LayoutResult,
    current: Option<f64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PlaceholderRequest {
    items: Vec<Item>,
    placeholder: Item,
    tab_index: usize,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct InsertionRequest {
    dragged_min_x: f64,
    group_start: f64,
    other_widths: Vec<f64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RevealRequest {
    slot: Slot,
    current: f64,
    content_width: f64,
    viewport_width: f64,
    #[serde(default)]
    margin: f64,
    #[serde(default)]
    fixed_leading: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct EdgesRequest {
    offset: f64,
    content_width: f64,
    viewport_width: f64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct EdgesReply {
    clamped: f64,
    max_offset: f64,
    #[serde(flatten)]
    edges: FadedEdges,
}

#[derive(Deserialize)]
struct MappingPoint {
    x: f64,
    #[serde(default)]
    pinned: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MappingRequest {
    result: LayoutResult,
    viewport_width: f64,
    #[serde(default)]
    minimum_scrollable: f64,
    #[serde(default)]
    offset: f64,
    #[serde(default)]
    points: Vec<MappingPoint>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ResolveRequest {
    width: f64,
    #[serde(default)]
    tab: TabState,
    #[serde(default)]
    style: Style,
    metrics: Metrics,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct OriginRequest {
    visibility: Visibility,
    pill_width: f64,
    metrics: Metrics,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PathRequest {
    widths: Vec<f64>,
    start: Visibility,
    #[serde(default)]
    tab: TabState,
    #[serde(default)]
    style: Style,
    metrics: Metrics,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct VerticalRequest {
    #[serde(default)]
    tabs: Vec<vertical::Tab>,
    #[serde(default)]
    groups: Vec<vertical::Group>,
    #[serde(default)]
    shows_new_tab: bool,
    #[serde(default)]
    icons_only: bool,
    width: f64,
    #[serde(default)]
    metrics: vertical::Metrics,
    #[serde(default)]
    x: f64,
    #[serde(default)]
    y: f64,
    #[serde(default)]
    dragging_pinned: bool,
    id: Option<String>,
}

impl VerticalRequest {
    fn list(&self) -> List<'_> {
        List {
            tabs: &self.tabs,
            groups: &self.groups,
            icons_only: self.icons_only,
            width: self.width,
            metrics: self.metrics,
        }
    }
}

fn parse<T: DeserializeOwned>(request: &[u8]) -> Option<T> {
    serde_json::from_slice(request).ok()
}

/// Whether `operation` is one of these ops.
pub fn handles(operation: &str) -> bool {
    operation.starts_with("tab_layout_")
}

/// The reply to `operation` with `request`, or `None` for an unknown op or a request that does
/// not parse.
pub fn respond(operation: &str, request: &[u8]) -> Option<Value> {
    let reply = match operation {
        "tab_layout_layout" => {
            let r: LayoutRequest = parse(request)?;
            let result = layout(
                &r.items,
                r.available_width,
                r.style,
                &r.metrics,
                r.closing_mode_width,
                r.full_width_tab.as_deref(),
            );
            serde_json::to_value(result)
        }
        "tab_layout_resized" => {
            let r: ResizedRequest = parse(request)?;
            serde_json::to_value(resized(
                &r.result,
                r.available_width,
                r.style,
                &r.metrics,
                r.closing_mode_width,
            ))
        }
        "tab_layout_closing_mode_width" => {
            let r: ClosingRequest = parse(request)?;
            Ok(json!({ "width": closing_mode_width(&r.closing, &r.result, r.current) }))
        }
        "tab_layout_insert_placeholder" => {
            let mut r: PlaceholderRequest = parse(request)?;
            insert_placeholder(&mut r.items, r.placeholder, r.tab_index);
            Ok(json!({ "items": r.items }))
        }
        "tab_layout_insertion_index" => {
            let r: InsertionRequest = parse(request)?;
            Ok(json!({ "index": insertion_index(r.dragged_min_x, r.group_start, &r.other_widths) }))
        }
        "tab_layout_scroll_reveal" => {
            let r: RevealRequest = parse(request)?;
            let offset = offset_revealing(
                &r.slot,
                r.current,
                r.content_width,
                r.viewport_width,
                r.margin,
                r.fixed_leading,
            );
            Ok(json!({ "offset": offset }))
        }
        "tab_layout_faded_edges" => {
            let r: EdgesRequest = parse(request)?;
            serde_json::to_value(EdgesReply {
                clamped: super::clamp_offset(r.offset, r.content_width, r.viewport_width),
                max_offset: super::max_offset(r.content_width, r.viewport_width),
                edges: faded_edges(r.offset, r.content_width, r.viewport_width),
            })
        }
        "tab_layout_scroll_mapping" => {
            let r: MappingRequest = parse(request)?;
            let mapping =
                ScrollMapping::new(&r.result, r.viewport_width, r.minimum_scrollable, r.offset);
            let points: Vec<Value> = r
                .points
                .iter()
                .map(|point| {
                    json!({
                        "viewX": mapping.view_x(point.x, point.pinned),
                        "contentX": mapping.content_x(point.x, point.pinned),
                        "showsUnpinned": mapping.shows_unpinned(point.x),
                    })
                })
                .collect();
            Ok(json!({ "band": mapping.band, "offset": mapping.offset, "points": points }))
        }
        "tab_layout_chrome_resolve" => {
            let r: ResolveRequest = parse(request)?;
            serde_json::to_value(Visibility::resolve(r.width, r.tab, r.style, &r.metrics))
        }
        "tab_layout_close_origin" => {
            let r: OriginRequest = parse(request)?;
            Ok(json!({ "x": r.visibility.close_button_origin_x(r.pill_width, &r.metrics) }))
        }
        "tab_layout_chrome_path" => {
            let r: PathRequest = parse(request)?;
            let forms = Visibility::path(&r.widths, r.start, r.tab, r.style, &r.metrics);
            Ok(json!({ "forms": forms }))
        }
        "tab_layout_vertical" => {
            let r: VerticalRequest = parse(request)?;
            serde_json::to_value(r.list().layout(r.shows_new_tab))
        }
        "tab_layout_vertical_row_at" => {
            let r: VerticalRequest = parse(request)?;
            let list = r.list();
            let layout = list.layout(r.shows_new_tab);
            Ok(json!({ "row": list.row_at(&layout, r.x, r.y) }))
        }
        "tab_layout_vertical_frame" => {
            let r: VerticalRequest = parse(request)?;
            let list = r.list();
            let layout = list.layout(r.shows_new_tab);
            Ok(json!({ "frame": list.frame_of(&layout, r.id.as_deref()?) }))
        }
        "tab_layout_vertical_slot" => {
            let r: VerticalRequest = parse(request)?;
            let list = r.list();
            let layout = list.layout(r.shows_new_tab);
            serde_json::to_value(list.slot_at(&layout, r.x, r.y, r.dragging_pinned))
        }
        _ => return None,
    };
    reply.ok()
}
