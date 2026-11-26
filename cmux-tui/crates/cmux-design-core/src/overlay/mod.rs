//! Overlay surfaces: the floating glass (`FloatingGlassStyle`, `SurfaceRole`, `GlassLevel`,
//! `OverlayGlassVariant`, `HoverSurfaceLook`, `TransientMaterial`), the floating pane's look,
//! the native popup's columns, keys and press gesture, the find pill's veil and the quit flow.
//!
//! Ops: `overlay.NAME` (see [`call`]). Every op takes and answers camelCase JSON.

pub mod find;
pub mod glass;
pub mod pane;
pub mod popup;
pub mod quit;

use crate::menu::color::ThemeRgb;
use crate::ops::{OpError, OpResult, parse, reply};
use glass::{
    Elevation, FloatingGlassStyle, GlassLevel, HoverSurfaceLook, OverlayGlassVariant, SurfaceRole,
};
use pane::{FloatingPaneCornerMode, FloatingPaneLook, FloatingPaneMaterial};
use popup::{KeyColumn, Point, Rect, RowKind, RowLists};
use serde::Deserialize;
use serde_json::{Value, json};

/// A style named by preset (`"toast"`, `"findPill"`, ...) or given whole.
#[derive(Deserialize)]
#[serde(untagged)]
enum StyleArg {
    Named(String),
    Whole(FloatingGlassStyle),
}

impl StyleArg {
    fn resolve(self) -> Result<FloatingGlassStyle, OpError> {
        match self {
            StyleArg::Named(name) => FloatingGlassStyle::named(&name)
                .ok_or_else(|| OpError::Invalid(format!("no glass style {name:?}"))),
            StyleArg::Whole(style) => Ok(style),
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StyleRequest {
    style: StyleArg,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LookRequest {
    style: StyleArg,
    is_dark: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct VeilRequest {
    style: StyleArg,
    is_dark: bool,
    glass_tint: ThemeRgb,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CornerRequest {
    outer: f64,
    padding: f64,
    depth: i64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LevelRequest {
    level: GlassLevel,
    #[serde(default)]
    alpha: Option<f64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RoleRequest {
    role: SurfaceRole,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct VariantRequest {
    #[serde(default)]
    variant: Option<OverlayGlassVariant>,
    #[serde(default)]
    veil_takes_theme_tint: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct HoverRequest {
    #[serde(default)]
    look: Option<HoverSurfaceLook>,
    #[serde(default)]
    base_shadow: Option<Elevation>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RowHeightRequest {
    kind: RowKind,
    #[serde(default)]
    has_caption: bool,
    #[serde(default)]
    slider_height: Option<f64>,
    standard_row_height: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ColumnKeyRequest {
    columns: Vec<KeyColumn>,
    #[serde(default)]
    search_accessory: Option<String>,
    #[serde(default)]
    selected: Option<String>,
    #[serde(default)]
    key: u16,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PressRequest {
    #[serde(default)]
    moved: bool,
    start: Point,
    point: Point,
    held_for: f64,
    #[serde(default)]
    row_picked: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ConfineRequest {
    bounds: Rect,
    #[serde(default)]
    previous: Option<Rect>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PointerRequest {
    frame: Rect,
    menu_width: f64,
    menu_height: f64,
    viewport: Rect,
    #[serde(default)]
    rtl: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ArrowRequest {
    key_code: u16,
    #[serde(default)]
    flags: Vec<String>,
    #[serde(default)]
    has_marked_text: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StepsRequest {
    #[serde(default)]
    text: String,
    #[serde(default)]
    no_matches: bool,
    #[serde(default)]
    can_step: Option<bool>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DeadlineRequest {
    participant: f64,
    #[serde(default)]
    cap: Option<f64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct UnsavedRequest {
    participants: Vec<quit::Participant>,
}

fn role_json(role: SurfaceRole) -> Value {
    json!({
        "role": role,
        "glassLevel": role.glass_level(),
        "cornerDepth": role.corner_depth(),
        "castsShadow": role.casts_shadow(),
        "neutralStyle": role.neutral_style(),
    })
}

fn hover_json(look: HoverSurfaceLook, base: Elevation) -> Value {
    json!({
        "look": look,
        "title": look.title(),
        "isSolid": look.is_solid(),
        "material": look.material(),
        "edgeWidth": look.edge_width(),
        "shadow": look.shadow(base),
    })
}

/// Runs the op `overlay.NAME`.
pub fn call(name: &str, request: &Value) -> OpResult {
    match name {
        "transientMaterial" => reply(&glass::TRANSIENT),
        "glassStyle" => {
            let r: StyleRequest = parse(request)?;
            reply(&r.style.resolve()?)
        }
        "glassLook" => {
            let r: LookRequest = parse(request)?;
            reply(&r.style.resolve()?.look(r.is_dark))
        }
        "veil" => {
            let r: VeilRequest = parse(request)?;
            reply(&r.style.resolve()?.veil_rgb(r.is_dark, r.glass_tint))
        }
        "cornerRadius" => {
            let r: CornerRequest = parse(request)?;
            reply(&glass::corner_radius(r.outer, r.padding, r.depth))
        }
        "glassLevel" => {
            let r: LevelRequest = parse(request)?;
            let strength = r.level.tint_strength();
            reply(&json!({
                "tintStrength": strength,
                "alpha": r.alpha.map(|a| glass::scaled_alpha(a, strength)),
            }))
        }
        "surfaceRole" => {
            let r: RoleRequest = parse(request)?;
            reply(&role_json(r.role))
        }
        "surfaceRoles" => reply(&json!({
            "nearOpaque": glass::NEAR_OPAQUE,
            "roles": SurfaceRole::ALL.iter().map(|&r| role_json(r)).collect::<Vec<_>>(),
        })),
        "glassVariant" => {
            let r: VariantRequest = parse(request)?;
            let v = r.variant.unwrap_or(OverlayGlassVariant::PICKED);
            reply(&json!({
                "variant": v,
                "number": v.number(),
                "tintsGlass": v.tints_glass(r.veil_takes_theme_tint),
                "drawsRim": v.draws_rim(),
                "prefersFrost": v.prefers_frost(),
            }))
        }
        "hoverSurfaceLook" => {
            let r: HoverRequest = parse(request)?;
            let look = r.look.unwrap_or(HoverSurfaceLook::DEFAULT);
            reply(&hover_json(look, r.base_shadow.unwrap_or(glass::ELEVATION_2)))
        }
        "hoverSurfaceLooks" => reply(&json!({
            "default": HoverSurfaceLook::DEFAULT,
            "solid": HoverSurfaceLook::SOLID,
            "all": HoverSurfaceLook::ALL,
        })),
        "paneMaterials" => reply(
            &FloatingPaneMaterial::ALL
                .iter()
                .map(|m| json!({"material": m, "title": m.title(), "system": m.system()}))
                .collect::<Vec<_>>(),
        ),
        "paneCornerModes" => reply(
            &FloatingPaneCornerMode::ALL
                .iter()
                .map(|m| json!({"mode": m, "title": m.title()}))
                .collect::<Vec<_>>(),
        ),
        "paneTunables" => reply(&json!({"keys": pane::ALL_KEYS, "numbers": pane::NUMBER_KNOBS})),
        "paneLook" => {
            let raw: FloatingPaneLook = parse(request)?;
            let look = FloatingPaneLook::from_knobs(&raw);
            let see_through = look.is_see_through();
            let mut value =
                serde_json::to_value(&look).map_err(|e| OpError::Invalid(e.to_string()))?;
            value["isSeeThrough"] = json!(see_through);
            Ok(value)
        }
        "rowHeight" => {
            let r: RowHeightRequest = parse(request)?;
            reply(&popup::row_height(r.kind, r.has_caption, r.slider_height, r.standard_row_height))
        }
        "columnsLayout" => {
            let r: popup::ColumnsInput = parse(request)?;
            reply(&popup::layout_columns(&r))
        }
        "columnKey" => {
            let r: ColumnKeyRequest = parse(request)?;
            reply(&popup::column_key(
                &r.columns,
                r.search_accessory.as_deref(),
                r.selected.as_deref(),
                r.key,
            ))
        }
        "firstListColumnRow" => {
            let r: ColumnKeyRequest = parse(request)?;
            reply(&popup::first_list_column_row(&r.columns, r.search_accessory.as_deref()))
        }
        "allRows" => {
            let r: RowLists = parse(request)?;
            reply(&json!({"rows": r.all_rows(), "hasColumns": r.has_columns()}))
        }
        "pressRelease" => {
            let r: PressRequest = parse(request)?;
            let moved = popup::press_moved(r.moved, r.start, r.point);
            reply(&json!({
                "moved": moved,
                "mayPick": popup::press_may_pick(moved, r.held_for),
                "outcome": popup::press_released(moved, r.held_for, r.row_picked),
            }))
        }
        "confinementRect" => {
            let r: ConfineRequest = parse(request)?;
            reply(&popup::confinement_rect(r.bounds, r.previous))
        }
        "pointerMenu" => {
            let r: PointerRequest = parse(request)?;
            reply(&popup::pointer_menu(r.frame, r.menu_width, r.menu_height, r.viewport, r.rtl))
        }
        "findForwardsArrow" => {
            let r: ArrowRequest = parse(request)?;
            reply(&find::should_forward_arrow(r.key_code, &r.flags, r.has_marked_text))
        }
        "findStepsEnabled" => {
            let r: StepsRequest = parse(request)?;
            reply(&find::steps_enabled(&r.text, r.no_matches, r.can_step))
        }
        "quitDeadline" => {
            let r: DeadlineRequest = parse(request)?;
            reply(&quit::flush_deadline(r.participant, r.cap))
        }
        "quitUnsaved" => {
            let r: UnsavedRequest = parse(request)?;
            reply(&quit::unsaved(&r.participants))
        }
        _ => Err(OpError::Unknown),
    }
}
