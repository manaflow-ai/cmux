//! `cmux-layout-reducer`'s window docks, Dock Column plan and Home Chief panel over the JSON channel
//! (ops `dock_model_*`). The app sends the state and the calls, and draws what comes back.

use cmux_layout_reducer::chief_panel::{
    ChiefAction, ChiefPanel, ChiefPanelFrame, Rect, Size, StyleInput, resolve_style,
};
use cmux_layout_reducer::dock_model::{
    DockColumn, DockDefaults, DockEdge, DockMode, DocksAction, LayoutScreen, WindowDocks,
    dock_column_containing, set_column_dock, validate_dock,
};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};

use crate::ERR_INVALID;

/// Whether `operation` is one of this module's.
pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(b"dock_model_")
}

fn parse<T: DeserializeOwned>(request: &[u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

#[derive(Deserialize)]
struct DocksRequest {
    docks: WindowDocks,
    #[serde(default)]
    actions: Vec<DocksAction>,
}

#[derive(Deserialize)]
struct WidthRequest {
    current: f64,
}

#[derive(Deserialize)]
struct EdgeRequest {
    column: String,
    layout: cmux_layout_reducer::dock_model::ScreenLayout,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PlanRequest {
    screen: LayoutScreen,
    column: String,
    #[serde(default)]
    pane: Option<String>,
    #[serde(default)]
    edge: Option<DockEdge>,
    #[serde(default)]
    default_edge: Option<DockEdge>,
    mode: DockMode,
}

#[derive(Deserialize)]
struct ColumnRequest {
    screens: Vec<LayoutScreen>,
    pane: String,
}

#[derive(Deserialize)]
struct ValidateRequest {
    screens: Vec<LayoutScreen>,
    column: String,
    #[serde(default)]
    dock: Option<DockColumn>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PanelState {
    #[serde(default)]
    docked_edge: Option<DockEdge>,
    #[serde(default)]
    is_open: bool,
    #[serde(default)]
    floating_frame: ChiefPanelFrame,
    #[serde(default = "default_extent")]
    dock_extent_permille: i64,
}

fn default_extent() -> i64 {
    cmux_layout_reducer::dock_model::DEFAULT_EXTENT_PERMILLE
}

#[derive(Deserialize)]
struct ChiefRequest {
    panel: PanelState,
    #[serde(default)]
    actions: Vec<ChiefAction>,
}

#[derive(Deserialize)]
struct FrameRectRequest {
    frame: ChiefPanelFrame,
    size: Size,
    #[serde(default)]
    minimum: Option<Size>,
}

#[derive(Deserialize)]
struct FrameFittingRequest {
    rect: Rect,
    size: Size,
    #[serde(default)]
    minimum: Option<Size>,
}

/// Answers one `dock_model_*` op.
pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let reply: Value = match operation {
        b"dock_model_docks" => {
            let DocksRequest { mut docks, actions } = parse(request)?;
            let results: Vec<Value> = actions.iter().map(|action| docks.apply(action)).collect();
            json!({ "docks": docks, "results": results })
        }
        b"dock_model_width" => {
            let WidthRequest { current } = parse(request)?;
            json!({ "width": DockDefaults.width(current) })
        }
        b"dock_model_edge" => {
            let EdgeRequest { column, layout } = parse(request)?;
            json!({ "edge": DockDefaults.edge(&column, &layout) })
        }
        b"dock_model_plan" => {
            let PlanRequest { screen, column, pane, edge, default_edge, mode } = parse(request)?;
            let plan =
                DockDefaults.plan(&screen, &column, pane.as_deref(), edge, default_edge, mode);
            json!({ "plan": plan })
        }
        b"dock_model_column" => {
            let ColumnRequest { screens, pane } = parse(request)?;
            json!({ "column": dock_column_containing(&screens, &pane) })
        }
        b"dock_model_validate" => {
            let ValidateRequest { screens, column, dock } = parse(request)?;
            json!({ "refusal": validate_dock(&screens, dock.as_ref(), &column) })
        }
        b"dock_model_set_column" => {
            let ValidateRequest { screens, column, dock } = parse(request)?;
            match set_column_dock(&screens, &column, dock.as_ref()) {
                Ok(intent) => json!({ "refusal": null, "intent": intent }),
                Err(refusal) => json!({ "refusal": refusal, "intent": null }),
            }
        }
        b"dock_model_chief" => {
            let ChiefRequest { panel, actions } = parse(request)?;
            let mut panel = ChiefPanel::new(
                panel.docked_edge,
                panel.is_open,
                panel.floating_frame,
                panel.dock_extent_permille,
            );
            let results: Vec<Value> = actions.iter().map(|action| panel.apply(action)).collect();
            json!({ "panel": panel, "results": results })
        }
        b"dock_model_frame_rect" => {
            let FrameRectRequest { frame, size, minimum } = parse(request)?;
            let minimum = minimum.unwrap_or(ChiefPanelFrame::MINIMUM_SIZE);
            json!({ "rect": frame.rect(size, minimum) })
        }
        b"dock_model_frame_fitting" => {
            let FrameFittingRequest { rect, size, minimum } = parse(request)?;
            let minimum = minimum.unwrap_or(ChiefPanelFrame::MINIMUM_SIZE);
            json!({ "frame": ChiefPanelFrame::fitting(rect, size, minimum) })
        }
        b"dock_model_style" => {
            let input: StyleInput = parse(request)?;
            json!(resolve_style(&input))
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&reply).map_err(|_| ERR_INVALID)
}
