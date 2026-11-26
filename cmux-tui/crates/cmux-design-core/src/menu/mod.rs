//! Menu look and sizing: GlassMenu, MenuLook, MenuTextSize, NSMenu system rows and the themed
//! pop-up button.
//!
//! Ops: `menu.NAME` (see [`call`]). Every op takes and answers camelCase JSON.

pub mod color;
pub mod look;
pub mod material;
pub mod popup;
pub mod rows;
pub mod text_size;

use crate::ops::{OpError, OpResult, parse, reply};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// `MenuMetrics.highlightInset`: the hover fill's inset, and a menu panel's default padding.
pub const HIGHLIGHT_INSET: f64 = 5.0;

/// A `CGRect`.
#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LookRequest {
    #[serde(default)]
    look: look::MenuLook,
    #[serde(default = "default_surface_radius")]
    surface_radius: f64,
}

fn default_surface_radius() -> f64 {
    material::DEFAULT_CORNER_RADIUS
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ValueRequest {
    value: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ShadowRequest {
    shadow: look::Shadow,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FlushRequest {
    row: Rect,
    card: Rect,
    padding: f64,
    #[serde(default = "default_gap")]
    gap: f64,
}

fn default_gap() -> f64 {
    look::SIDE_GAP
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SubmenuRequest {
    #[serde(default)]
    look: look::MenuLook,
    row: Rect,
    card: Rect,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ItemsRequest {
    items: Vec<rows::MenuItem>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MatchRequest {
    characters: String,
    #[serde(default)]
    flags: rows::Modifiers,
    items: Vec<rows::MenuItem>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ShortcutRequest {
    #[serde(default)]
    key_equivalent: String,
    modifiers: Option<rows::Modifiers>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TypeSelectRequest {
    #[serde(default)]
    state: rows::TypeSelect,
    characters: String,
    time: f64,
    titles: Vec<Option<String>>,
    current: Option<usize>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SizingRequest {
    views: Vec<rows::RowView>,
    #[serde(default)]
    look: look::MenuLook,
    #[serde(default)]
    bounds_width: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TextSizeRequest {
    base: f64,
    scale: f64,
    current: Option<f64>,
    #[serde(default)]
    in_menu_bar: bool,
    #[serde(default)]
    was_sized: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TokensRequest {
    tokens: material::MaterialTokens,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GlassRequest {
    tokens: material::MaterialTokens,
    veil: f64,
    page: color::ThemeRgb,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SurfaceRequest {
    surface: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ColorRequest {
    color: color::ThemeRgb,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ChevronRequest {
    #[serde(default)]
    pulls_down: bool,
    font_size: Option<f64>,
    #[serde(default)]
    has_fill: bool,
    #[serde(default)]
    has_ink: bool,
    #[serde(default)]
    bordered: bool,
    bounds: Option<Rect>,
    #[serde(default)]
    image_width: f64,
    #[serde(default)]
    image_height: f64,
    #[serde(default)]
    space3: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SystemItemsRequest {
    #[serde(default)]
    context_menu_plug_ins: bool,
    writing_tools: Option<bool>,
}

/// Runs `menu.NAME`.
///
/// | op | request | reply |
/// |---|---|---|
/// | `webVariables` | `{look}` | `{"--menu-*": "..."}` |
/// | `applyLook` | `{look, surfaceRadius}` | `{cornerRadius, elevation, drawsLookView, padding, separatorInkShare}` |
/// | `cssNumber` | `{value}` | `"12"` |
/// | `shadowElevation` | `{shadow}` | `{offset, blur, alpha}` or `null` |
/// | `flushAnchor` | `{row, card, padding, gap?}` | rect |
/// | `submenuAnchor` | `{look, row, card}` | rect |
/// | `rows` | `{items}` | `[index or null]` |
/// | `matchKey` | `{characters, flags, items}` | `[index path]` or `null` |
/// | `shortcut` | `{keyEquivalent, modifiers?}` | `"⌘,"` or `null` |
/// | `typeSelect` | `{state, characters, time, titles, current}` | `{pick, state}` |
/// | `fittingSize` | `{views, look}` | `{width, height}` |
/// | `layout` | `{views, look, boundsWidth}` | `[rect]` |
/// | `textSize` | `{base, scale}` | number |
/// | `textSizeAction` | `{base, scale, current, inMenuBar, wasSized}` | `{action, pointSize?}` |
/// | `material` | `{}` | the material's constants |
/// | `veil` | `{tokens}` | number |
/// | `webClear` | `{tokens}` | `{value, css}` |
/// | `glass` | `{tokens, veil, page}` | colour |
/// | `menuCornerRadius` | `{surface}` | number |
/// | `css` | `{color}` | `"rgba(...)"` |
/// | `popUpChevron` | `{pullsDown, fontSize?, hasFill, hasInk, bordered, bounds?, imageWidth, imageHeight, space3}` | `{symbol, pointSize, themed, frame?}` |
/// | `allowsSystemItems` | `{contextMenuPlugIns, writingTools?}` | bool |
pub fn call(name: &str, request: &Value) -> OpResult {
    match name {
        "webVariables" => {
            let r: LookRequest = parse(request)?;
            reply(&r.look.web_variables())
        }
        "applyLook" => {
            let r: LookRequest = parse(request)?;
            reply(&look::apply_look(&r.look, r.surface_radius))
        }
        "cssNumber" => {
            let r: ValueRequest = parse(request)?;
            reply(&look::number(r.value))
        }
        "shadowElevation" => {
            let r: ShadowRequest = parse(request)?;
            reply(&r.shadow.elevation())
        }
        "flushAnchor" => {
            let r: FlushRequest = parse(request)?;
            reply(&look::flush_anchor(r.row, r.card, r.padding, r.gap))
        }
        "submenuAnchor" => {
            let r: SubmenuRequest = parse(request)?;
            reply(&look::submenu_anchor(&r.look, r.row, r.card))
        }
        "rows" => {
            let r: ItemsRequest = parse(request)?;
            reply(&rows::rows(&r.items))
        }
        "matchKey" => {
            let r: MatchRequest = parse(request)?;
            reply(&rows::item_matching(&r.characters, r.flags, &r.items))
        }
        "shortcut" => {
            let r: ShortcutRequest = parse(request)?;
            let mask =
                r.modifiers.unwrap_or(rows::Modifiers { command: true, ..Default::default() });
            reply(&rows::shortcut(&r.key_equivalent, mask))
        }
        "typeSelect" => {
            let mut r: TypeSelectRequest = parse(request)?;
            let pick = r.state.pick(&r.characters, r.time, &r.titles, r.current);
            Ok(json!({ "pick": pick, "state": r.state }))
        }
        "fittingSize" => {
            let r: SizingRequest = parse(request)?;
            let row_height = r.look.row_height.unwrap_or(material::ROW_HEIGHT);
            let (width, height) =
                rows::fitting_size(&r.views, r.look.resolved_padding(), row_height);
            Ok(json!({ "width": width, "height": height }))
        }
        "layout" => {
            let r: SizingRequest = parse(request)?;
            let row_height = r.look.row_height.unwrap_or(material::ROW_HEIGHT);
            reply(&rows::layout(&r.views, r.look.resolved_padding(), row_height, r.bounds_width))
        }
        "textSize" => {
            let r: TextSizeRequest = parse(request)?;
            reply(&text_size::size(r.base, r.scale))
        }
        "textSizeAction" => {
            let r: TextSizeRequest = parse(request)?;
            reply(&text_size::action(r.base, r.scale, r.current, r.in_menu_bar, r.was_sized))
        }
        "material" => reply(&material::constants()),
        "veil" => {
            let r: TokensRequest = parse(request)?;
            reply(&material::veil_for(&r.tokens))
        }
        "webClear" => {
            let r: TokensRequest = parse(request)?;
            Ok(
                json!({ "value": material::web_clear(&r.tokens), "css": material::web_clear_css(&r.tokens) }),
            )
        }
        "glass" => {
            let r: GlassRequest = parse(request)?;
            reply(&material::glass(&r.tokens, r.veil, r.page))
        }
        "menuCornerRadius" => {
            let r: SurfaceRequest = parse(request)?;
            reply(&material::menu_corner_radius(r.surface))
        }
        "css" => {
            let r: ColorRequest = parse(request)?;
            reply(&color::css(r.color))
        }
        "popUpChevron" => {
            let r: ChevronRequest = parse(request)?;
            let chevron =
                popup::chevron(r.pulls_down, r.font_size, r.has_fill, r.has_ink, r.bordered);
            let frame =
                r.bounds.map(|b| popup::chevron_frame(b, r.image_width, r.image_height, r.space3));
            Ok(json!({
                "symbol": chevron.symbol,
                "pointSize": chevron.point_size,
                "themed": chevron.themed,
                "frame": frame,
            }))
        }
        "allowsSystemItems" => {
            let r: SystemItemsRequest = parse(request)?;
            reply(&popup::allows_system_items(r.context_menu_plug_ins, r.writing_tools))
        }
        _ => Err(OpError::Unknown),
    }
}
