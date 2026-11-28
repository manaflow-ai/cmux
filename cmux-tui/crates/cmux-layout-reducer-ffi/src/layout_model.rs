//! `cmux_layout_reducer::layout_model` over the JSON channel (ops `layout_model_*`): the layout
//! model's split tree helpers, even split sizing, Equalize Splits, new column widths, where a new
//! pane goes, main pane layout and the agent chat's placement picks. Each request is one JSON
//! object; `schemas/layout-model/vectors.json` has cases of each with the answer the app's Swift
//! rules gave.
//!
//! - `layout_model_tree` `{node, other, split, pane, axis, newSplit, newPane}` -> `{splits,
//!   sameShape, node: {axis, a, b}?, equalizedRatio?, replaced}` (`SplitNode.splits`,
//!   `hasSameShape(as: other)`, `node(for: split)`, `equalizedRatio(for: split)`, and
//!   `replacingLeaf(pane)` with a split `newSplit` of `pane` and a new leaf `newPane` at 0.5)
//! - `layout_model_even_split` `{root, pane, axis}` -> `{changes}` (`EvenSplitRatios.changes(splitting:)`)
//! - `layout_model_split_sizing` `{layout, pane, axis, removing?, even}` -> `{changes}`
//! - `layout_model_equalize` `{layout, zoomed, visiblePanes, viewportWidth?, gap, minimumWidths}`
//!   -> `{outcome: "nothingToEqualize" | "equalized", values: [{split, ratio} | {column, width}]}`
//! - `layout_model_equalize_split` `{layouts, split}` -> `{ratio}`
//! - `layout_model_equalize_columns` `{columns, visible, viewportWidth, gap, minimumWidths}` ->
//!   `{resizes}` (`ColumnEqualizer.resizes`)
//! - `layout_model_new_column_plan` `{mode, columns, anchor?, visible, fixedWidth, removing?}` -> `{width}`
//! - `layout_model_new_column_width` `{layout?, pane, visiblePanes, mode, fixedWidth, removing?}` -> `{width}`
//! - `layout_model_auto_split` `{layout, frames, recent}` -> `{split: {pane, axis}?}`
//! - `layout_model_pane_placement` `{layout, focused, recent, frames, placement, tiles}` ->
//!   `{plan: {tab: pane} | {split: {pane, axis}}}`
//! - `layout_model_main_pane` `{setting, override}` -> `{on}`
//! - `layout_model_main_pane_side` `{placement}` -> `{side}` (a placement is `"here"`,
//!   `{tab: pane}`, `"dockChat"` or `"besideDock"`)
//! - `layout_model_dock_pick` `{hasStrip, keep}` -> `{pick: "usual" | {beside: {closesPage}}}`
//! - `layout_model_chat_columns` `{screenId, layout, pane}` -> `{columns}`
//!
//! A layout, node or column is `cmux_layout_reducer::screen_layout`'s JSON; `frames` maps a pane
//! to `{x, y, width, height}`; `minimumWidths` maps a column to its minimum width in points.

use crate::ERR_INVALID;
use cmux_layout_reducer::layout_model::{
    ChatColumnPlacement, ColumnEqualizer, EqualizeOutcome, EqualizeScreen, Frame, MainPaneOverride,
    NewColumnWidthMode, NewPanePlacement, auto_split, chat_columns, dock_pick, equalize,
    equalize_split, even_split_changes, main_pane_is_on, main_pane_side, new_column_plan,
    new_column_width, pane_plan, split_sizing_changes,
};
use cmux_layout_reducer::screen_layout::{Axis, Column, Layout, Node};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};

pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(b"layout_model_")
}

fn parse<T: DeserializeOwned>(request: &[u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TreeRequest {
    node: Node,
    other: Node,
    split: String,
    pane: String,
    axis: Axis,
    new_split: String,
    new_pane: String,
}

#[derive(Deserialize)]
struct EvenSplitRequest {
    root: Node,
    pane: String,
    axis: Axis,
}

#[derive(Deserialize)]
struct SplitSizingRequest {
    layout: Layout,
    pane: String,
    axis: Axis,
    #[serde(default)]
    removing: Option<String>,
    #[serde(default)]
    even: bool,
}

#[derive(Deserialize)]
struct EqualizeSplitRequest {
    layouts: Vec<Layout>,
    split: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct EqualizeColumnsRequest {
    columns: Vec<Column>,
    #[serde(default)]
    visible: BTreeSet<String>,
    #[serde(default)]
    viewport_width: f64,
    #[serde(default)]
    gap: f64,
    #[serde(default)]
    minimum_widths: BTreeMap<String, f64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct NewColumnPlanRequest {
    mode: NewColumnWidthMode,
    columns: Vec<Column>,
    #[serde(default)]
    anchor: Option<String>,
    #[serde(default)]
    visible: Vec<String>,
    fixed_width: f64,
    #[serde(default)]
    removing: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct NewColumnWidthRequest {
    #[serde(default)]
    layout: Option<Layout>,
    pane: String,
    #[serde(default)]
    visible_panes: BTreeSet<String>,
    mode: NewColumnWidthMode,
    fixed_width: f64,
    #[serde(default)]
    removing: Option<String>,
}

#[derive(Deserialize)]
struct AutoSplitRequest {
    layout: Layout,
    #[serde(default)]
    frames: BTreeMap<String, Frame>,
    #[serde(default)]
    recent: Vec<String>,
}

#[derive(Deserialize)]
struct PanePlacementRequest {
    layout: Layout,
    focused: String,
    #[serde(default)]
    recent: Vec<String>,
    #[serde(default)]
    frames: BTreeMap<String, Frame>,
    placement: NewPanePlacement,
    #[serde(default)]
    tiles: bool,
}

#[derive(Deserialize)]
struct MainPaneRequest {
    setting: bool,
    #[serde(rename = "override")]
    override_: MainPaneOverride,
}

#[derive(Deserialize)]
struct MainPaneSideRequest {
    placement: ChatColumnPlacement,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DockPickRequest {
    has_strip: bool,
    keep: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ChatColumnsRequest {
    screen_id: String,
    layout: Layout,
    pane: String,
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let reply: Value = match operation {
        b"layout_model_tree" => {
            let r: TreeRequest = parse(request)?;
            let node =
                r.node.node_for(&r.split).map(|(axis, a, b)| json!({"axis": axis, "a": a, "b": b}));
            let new_leaf = Node::leaf(&r.new_pane);
            let replaced = r.node.replacing_leaf(&r.pane, &|leaf| {
                Node::split(&r.new_split, r.axis, 0.5, leaf.clone(), new_leaf.clone())
            });
            json!({
                "splits": r.node.splits(),
                "sameShape": r.node.has_same_shape(&r.other),
                "node": node,
                "equalizedRatio": r.node.equalized_ratio(&r.split),
                "replaced": replaced,
            })
        }
        b"layout_model_even_split" => {
            let r: EvenSplitRequest = parse(request)?;
            json!({"changes": even_split_changes(&r.pane, r.axis, &r.root)})
        }
        b"layout_model_split_sizing" => {
            let r: SplitSizingRequest = parse(request)?;
            json!({"changes": split_sizing_changes(&r.layout, &r.pane, r.axis, r.removing.as_deref(), r.even)})
        }
        b"layout_model_equalize" => {
            let r: EqualizeScreen = parse(request)?;
            match equalize(&r) {
                EqualizeOutcome::NothingToEqualize => {
                    json!({"outcome": "nothingToEqualize", "values": []})
                }
                EqualizeOutcome::Equalize(values) => {
                    json!({"outcome": "equalized", "values": values})
                }
            }
        }
        b"layout_model_equalize_split" => {
            let r: EqualizeSplitRequest = parse(request)?;
            json!({"ratio": equalize_split(&r.layouts, &r.split)})
        }
        b"layout_model_equalize_columns" => {
            let r: EqualizeColumnsRequest = parse(request)?;
            let equalizer = ColumnEqualizer {
                columns: &r.columns,
                visible: &r.visible,
                viewport_width: r.viewport_width,
                gap: r.gap,
                minimum_widths: &r.minimum_widths,
            };
            json!({"resizes": equalizer.resizes()})
        }
        b"layout_model_new_column_plan" => {
            let r: NewColumnPlanRequest = parse(request)?;
            json!({"width": new_column_plan(
                r.mode,
                &r.columns,
                r.anchor.as_deref(),
                &r.visible,
                r.fixed_width,
                r.removing.as_deref(),
            )})
        }
        b"layout_model_new_column_width" => {
            let r: NewColumnWidthRequest = parse(request)?;
            json!({"width": new_column_width(
                r.layout.as_ref(),
                &r.pane,
                &r.visible_panes,
                r.mode,
                r.fixed_width,
                r.removing.as_deref(),
            )})
        }
        b"layout_model_auto_split" => {
            let r: AutoSplitRequest = parse(request)?;
            json!({"split": auto_split(&r.layout, &r.frames, &r.recent)})
        }
        b"layout_model_pane_placement" => {
            let r: PanePlacementRequest = parse(request)?;
            json!({"plan": pane_plan(&r.layout, &r.focused, &r.recent, &r.frames, r.placement, r.tiles)})
        }
        b"layout_model_main_pane" => {
            let r: MainPaneRequest = parse(request)?;
            json!({"on": main_pane_is_on(r.setting, r.override_)})
        }
        b"layout_model_main_pane_side" => {
            let r: MainPaneSideRequest = parse(request)?;
            json!({"side": main_pane_side(&r.placement)})
        }
        b"layout_model_dock_pick" => {
            let r: DockPickRequest = parse(request)?;
            json!({"pick": dock_pick(r.has_strip, r.keep)})
        }
        b"layout_model_chat_columns" => {
            let r: ChatColumnsRequest = parse(request)?;
            json!({"columns": chat_columns(&r.screen_id, &r.layout, &r.pane)})
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&reply).map_err(|_| ERR_INVALID)
}
