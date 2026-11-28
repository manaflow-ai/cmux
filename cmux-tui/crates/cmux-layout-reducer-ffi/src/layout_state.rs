//! `cmux_layout_reducer::layout_state` over the JSON channel (ops `layout_state_*`): the Mac app's
//! `LayoutModel` rules. A transition takes the model and answers it changed, with the intents the
//! class emits; `schemas/layout-state/vectors.json` has the answers the app's Swift rules gave.
//!
//! - `layout_state_new` `{screens, activeScreen?, focusedPane?}` -> `{model}`
//! - `layout_state_apply` `{model, screens}` -> `{model}` (`apply(screens:)`)
//! - `layout_state_settle` `{model, transaction}` -> `{model}`
//! - `layout_state_reject` `{model, transaction}` -> `{model, shown}`
//! - `layout_state_set_split_ratio` `{model, split, ratio, transaction, phase}` -> `{model, intents}`
//! - `layout_state_set_column_width` `{model, column, width, transaction, phase}` -> `{model, intents}`
//! - `layout_state_supersede` `{model, splits, columns}` -> `{model}` (the ended overrides they replace)
//! - `layout_state_cancel_gesture` `{model, transaction}` -> `{model, shown, intents}`
//! - `layout_state_focus` `{model, pane, notify, source}` -> `{model, intents, entered, revealOnCanvas}`
//! - `layout_state_dismiss_focus_ring` `{model}` -> `{model}`
//! - `layout_state_select_screen` `{model, screen}` -> `{model, intents}`
//! - `layout_state_send_ended` `{model, values, transaction, unsendable?}` -> `{model, done, intent}`:
//!   `done` is true or false when the change finished (nothing to send, or refused before it
//!   showed), null when `intent` goes to the app now; then `layout_state_end_sending` `{model}` ->
//!   `{model, sent}`. A change the app sends while it hears `intent` nests between the two.
//! - `layout_state_sizes` `{intent}` -> `{values, transaction}` (both null for another intent)
//! - `layout_state_floating_clamped` `{frame}` -> `{frame}`; `layout_state_floating_rect`
//!   `{frame, width, height, scale}` -> `{rect}`; `layout_state_floating_pane_rect` `{card}` ->
//!   `{rect}`; `layout_state_floating_card_rect` `{pane}` -> `{rect}`;
//!   `layout_state_floating_fractions` `{rect, width, height}` -> `{frame}`;
//!   `layout_state_floating_raise` `{pane, floating, source}` -> `{intent}`
//! - `layout_state_divider_tree` `{tree, split, pane}` -> `{plan, beside}`
//! - `layout_state_dividers` `{screens, split, pane}` -> `{plan, beside, hidden}`
//! - `layout_state_cache` `{model, frames, bounds?, divider}` -> `{node, live}` (cmux-layout-cache
//!   `PaneNode` and `LiveTree` JSON); `layout_state_cache_drift` `{cached, reconciled?}` -> `{mark}`
//! - `layout_state_screen` `{screen, pane, column}` -> `{panes, visualPanes, contains, floats,
//!   implicitColumn, columnContaining, inAgentChatDock, columnById}`
//! - `layout_state_layout` `{layout, other, split, heights, column, dock?}` -> `{visualPanes,
//!   sameStructure, treeWithSplit, settingRowHeights, settingDock}`
//!
//! A model is `layout_state::Model`'s JSON (a request's `paneCloses` is read, never answered); a
//! screen and a layout are `layout_state::Screen`'s and `screen_layout`'s; a rect is
//! `{x, y, width, height}`; a value to send is `{kind: "ratio", split, ratio}` or
//! `{kind: "width", column, width}`.

use crate::ERR_INVALID;
use cmux_layout_reducer::layout_state::{
    DragValue, EndedValues, FloatingPane, FocusSource, Intent, Model, Phase, Rect, RowHeight,
    Screen, SendStart, Unsendable, cache_drift, cache_live, cache_node, divider_beside,
    divider_hidden, divider_insert_plan, end_sending, floating_card_rect, floating_clamped,
    floating_fractions, floating_pane_rect, floating_raise, floating_rect, has_same_structure,
    screens_divider_beside, screens_divider_insert_plan, setting_dock, setting_row_heights,
    tree_with_split, visual_panes,
};
use cmux_layout_reducer::screen_layout::{Dock, Layout, Node};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};

pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(b"layout_state_")
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct NewRequest {
    screens: Vec<Screen>,
    #[serde(default)]
    active_screen: Option<String>,
    #[serde(default)]
    focused_pane: Option<String>,
}

#[derive(Deserialize)]
struct ModelRequest {
    model: Model,
    #[serde(default)]
    screens: Vec<Screen>,
    #[serde(default)]
    transaction: String,
}

#[derive(Deserialize)]
struct GestureRequest {
    model: Model,
    #[serde(default)]
    split: String,
    #[serde(default)]
    column: String,
    #[serde(default)]
    ratio: f64,
    #[serde(default)]
    width: f64,
    transaction: String,
    phase: Phase,
}

#[derive(Deserialize)]
struct SupersedeRequest {
    model: Model,
    #[serde(default)]
    splits: BTreeSet<String>,
    #[serde(default)]
    columns: BTreeSet<String>,
}

#[derive(Deserialize)]
struct FocusRequest {
    model: Model,
    pane: String,
    #[serde(default)]
    notify: bool,
    #[serde(default)]
    source: FocusSource,
}

#[derive(Deserialize)]
struct ScreenRequest {
    model: Model,
    screen: String,
}

#[derive(Deserialize)]
struct SendRequest {
    model: Model,
    values: Vec<DragValue>,
    transaction: String,
    #[serde(default)]
    unsendable: Option<Unsendable>,
}

#[derive(Deserialize)]
struct SizesRequest {
    intent: Intent,
}

#[derive(Deserialize)]
struct FloatingRequest {
    #[serde(default)]
    frame: Rect,
    #[serde(default)]
    rect: Rect,
    #[serde(default)]
    card: Rect,
    #[serde(default)]
    pane: Value,
    #[serde(default)]
    width: f64,
    #[serde(default)]
    height: f64,
    #[serde(default)]
    scale: f64,
}

#[derive(Deserialize)]
struct RaiseRequest {
    pane: String,
    #[serde(default)]
    floating: Vec<FloatingPane>,
    #[serde(default)]
    source: FocusSource,
}

#[derive(Deserialize)]
struct DividerTreeRequest {
    tree: Node,
    #[serde(default)]
    split: String,
    #[serde(default)]
    pane: String,
}

#[derive(Deserialize)]
struct DividersRequest {
    screens: Vec<Screen>,
    #[serde(default)]
    split: String,
    #[serde(default)]
    pane: String,
}

#[derive(Deserialize)]
struct CacheRequest {
    model: Model,
    #[serde(default)]
    frames: BTreeMap<String, Rect>,
    #[serde(default)]
    bounds: Option<Rect>,
    #[serde(default)]
    divider: f64,
}

#[derive(Deserialize)]
struct DriftRequest {
    cached: Value,
    #[serde(default)]
    reconciled: Option<(usize, usize)>,
}

#[derive(Deserialize)]
struct ScreenQueryRequest {
    screen: Screen,
    #[serde(default)]
    pane: String,
    #[serde(default)]
    column: String,
}

#[derive(Deserialize)]
struct LayoutRequest {
    layout: Layout,
    other: Layout,
    #[serde(default)]
    split: String,
    #[serde(default)]
    heights: Vec<RowHeight>,
    #[serde(default)]
    column: String,
    #[serde(default)]
    dock: Option<Dock>,
}

fn parse<T: DeserializeOwned>(request: &[u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

fn rect(value: &Value) -> Result<Rect, i32> {
    serde_json::from_value(value.clone()).map_err(|_| ERR_INVALID)
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let reply: Value = match operation {
        b"layout_state_new" => {
            let r: NewRequest = parse(request)?;
            json!({ "model": Model::new(r.screens, r.active_screen, r.focused_pane) })
        }
        b"layout_state_apply" => {
            let mut r: ModelRequest = parse(request)?;
            r.model.apply(r.screens);
            json!({ "model": r.model })
        }
        b"layout_state_settle" => {
            let mut r: ModelRequest = parse(request)?;
            r.model.settle(&r.transaction);
            json!({ "model": r.model })
        }
        b"layout_state_reject" => {
            let mut r: ModelRequest = parse(request)?;
            let shown = r.model.reject(&r.transaction);
            json!({ "model": r.model, "shown": shown })
        }
        b"layout_state_set_split_ratio" => {
            let mut r: GestureRequest = parse(request)?;
            let intents = r.model.set_split_ratio(&r.split, r.ratio, &r.transaction, r.phase);
            json!({ "model": r.model, "intents": intents })
        }
        b"layout_state_set_column_width" => {
            let mut r: GestureRequest = parse(request)?;
            let intents = r.model.set_column_width(&r.column, r.width, &r.transaction, r.phase);
            json!({ "model": r.model, "intents": intents })
        }
        b"layout_state_supersede" => {
            let mut r: SupersedeRequest = parse(request)?;
            r.model.supersede_sent_ratios(&r.splits);
            r.model.supersede_sent_widths(&r.columns);
            json!({ "model": r.model })
        }
        b"layout_state_cancel_gesture" => {
            let mut r: ModelRequest = parse(request)?;
            let (shown, intents) = r.model.cancel_gesture(&r.transaction);
            json!({ "model": r.model, "shown": shown, "intents": intents })
        }
        b"layout_state_focus" => {
            let mut r: FocusRequest = parse(request)?;
            let effects = r.model.focus(&r.pane, r.notify, r.source);
            json!({
                "model": r.model,
                "intents": effects.intents,
                "entered": effects.entered,
                "revealOnCanvas": effects.reveal_on_canvas,
            })
        }
        b"layout_state_dismiss_focus_ring" => {
            let mut r: ModelRequest = parse(request)?;
            r.model.dismiss_focus_ring();
            json!({ "model": r.model })
        }
        b"layout_state_select_screen" => {
            let mut r: ScreenRequest = parse(request)?;
            let intents = r.model.select_screen(&r.screen);
            json!({ "model": r.model, "intents": intents })
        }
        b"layout_state_send_ended" => {
            let mut r: SendRequest = parse(request)?;
            let change = EndedValues { values: r.values, transaction: r.transaction };
            let (done, intent) = match change.send(&mut r.model, r.unsendable.as_ref()) {
                SendStart::Done(sent) => (Some(sent), None),
                SendStart::Sending(intent) => (None, intent),
            };
            json!({ "model": r.model, "done": done, "intent": intent })
        }
        b"layout_state_end_sending" => {
            let mut r: ModelRequest = parse(request)?;
            let sent = end_sending(&mut r.model);
            json!({ "model": r.model, "sent": sent })
        }
        b"layout_state_sizes" => {
            let r: SizesRequest = parse(request)?;
            match r.intent.sizes() {
                Some((values, transaction)) => {
                    json!({ "values": values, "transaction": transaction })
                }
                None => json!({ "values": null, "transaction": null }),
            }
        }
        b"layout_state_floating_clamped" => {
            let r: FloatingRequest = parse(request)?;
            json!({ "frame": floating_clamped(r.frame) })
        }
        b"layout_state_floating_rect" => {
            let r: FloatingRequest = parse(request)?;
            json!({ "rect": floating_rect(r.frame, r.width, r.height, r.scale) })
        }
        b"layout_state_floating_pane_rect" => {
            let r: FloatingRequest = parse(request)?;
            json!({ "rect": floating_pane_rect(r.card) })
        }
        b"layout_state_floating_card_rect" => {
            let r: FloatingRequest = parse(request)?;
            json!({ "rect": floating_card_rect(rect(&r.pane)?) })
        }
        b"layout_state_floating_fractions" => {
            let r: FloatingRequest = parse(request)?;
            json!({ "frame": floating_fractions(r.rect, r.width, r.height) })
        }
        b"layout_state_floating_raise" => {
            let r: RaiseRequest = parse(request)?;
            json!({ "intent": floating_raise(&r.pane, &r.floating, r.source) })
        }
        b"layout_state_divider_tree" => {
            let r: DividerTreeRequest = parse(request)?;
            json!({
                "plan": divider_insert_plan(&r.tree, &r.split),
                "beside": divider_beside(&r.tree, &r.pane),
            })
        }
        b"layout_state_dividers" => {
            let r: DividersRequest = parse(request)?;
            json!({
                "plan": screens_divider_insert_plan(&r.screens, &r.split),
                "beside": screens_divider_beside(&r.screens, &r.pane),
                "hidden": divider_hidden(&r.screens, &r.split),
            })
        }
        b"layout_state_cache" => {
            let r: CacheRequest = parse(request)?;
            json!({
                "node": cache_node(&r.model, &r.frames),
                "live": cache_live(&r.model, r.bounds, r.divider),
            })
        }
        b"layout_state_cache_drift" => {
            let r: DriftRequest = parse(request)?;
            json!({ "mark": cache_drift(&r.cached, r.reconciled) })
        }
        b"layout_state_screen" => {
            let r: ScreenQueryRequest = parse(request)?;
            let screen = &r.screen;
            json!({
                "panes": screen.panes(),
                "visualPanes": screen.visual_panes(),
                "contains": screen.contains(&r.pane),
                "floats": screen.floats(&r.pane),
                "implicitColumn": screen.implicit_column_id(),
                "columnContaining": screen.column_containing(&r.pane),
                "inAgentChatDock": screen.in_agent_chat_dock(&r.pane),
                "columnById": screen.column_by_id(&r.column),
            })
        }
        b"layout_state_layout" => {
            let r: LayoutRequest = parse(request)?;
            json!({
                "visualPanes": visual_panes(&r.layout),
                "sameStructure": has_same_structure(&r.layout, &r.other),
                "treeWithSplit": tree_with_split(&r.layout, &r.split),
                "settingRowHeights": setting_row_heights(&r.layout, &r.heights, &r.column),
                "settingDock": setting_dock(&r.layout, r.dock.as_ref(), &r.column),
            })
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&reply).map_err(|_| ERR_INVALID)
}
