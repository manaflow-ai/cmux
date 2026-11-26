//! The density catalog and the scales that follow the density: a port of CmuxNextDesign's
//! DensityTokenCatalog.swift ([`catalog`]), Typography+PageDensity.swift and CardScale.swift
//! ([`page`]), on a local port of the `DensityTokens` / `DensityPreset` parts they read
//! ([`tokens`]).
//!
//! Live app values (Text Size, Interface Size, `Metrics.tabIconSize`, a derived fallback's
//! scoped value) are inputs.
//!
//! Ops: `tokens.density_*`.

pub mod catalog;
pub mod page;
pub mod tokens;

pub use catalog::{Entry, Fallback, Field, Group, Unit};
pub use tokens::{DensityPreset, DensityTokens};

use crate::ops::{OpError, OpResult, parse, reply};
use crate::tokens::metrics;
use serde::{Deserialize, Serialize};
use serde_json::Value;

fn one() -> f64 {
    1.0
}

fn entry_for(key: &str) -> Result<&'static Entry, OpError> {
    catalog::entry(key).ok_or_else(|| OpError::Invalid(format!("no density entry {key}")))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct KeyRequest {
    key: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GroupRequest {
    group: Group,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct EntryDensityRequest {
    key: String,
    density: DensityTokens,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ValueRequest {
    key: String,
    density: DensityTokens,
    #[serde(default)]
    fallback: Option<f64>,
    #[serde(default = "one")]
    interface_scale: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SettingRequest {
    key: String,
    value: f64,
    density: DensityTokens,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct EntryBaseRequest {
    key: String,
    density: DensityTokens,
    base: DensityTokens,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DensityBaseRequest {
    density: DensityTokens,
    base: DensityTokens,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DensityRequest {
    density: DensityTokens,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PresetRequest {
    preset: DensityPreset,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PresetReply {
    raw_value: &'static str,
    name: &'static str,
    scale_factor: f64,
    omnibar_scale_factor: f64,
    tokens: &'static DensityTokens,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ResolveRequest {
    density: DensityTokens,
    compact: f64,
    comfortable: f64,
    #[serde(default)]
    token: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SpaceRequest {
    density: DensityTokens,
    value: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FontTokenRequest {
    density: DensityTokens,
    key: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct InfoReply {
    family: tokens::Family,
    is_built_in: bool,
    uniform_scale: Option<f64>,
    uses_default_row_fill: bool,
    level_body_size: f64,
    body_size: f64,
    sidebar_title_size: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ScaleRequest {
    density: DensityTokens,
    #[serde(default)]
    font_override: Option<f64>,
    #[serde(default = "one")]
    interface_scale: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PageDensityScaleRequest {
    density: DensityTokens,
    #[serde(default = "one")]
    interface_scale: f64,
    #[serde(default)]
    row_override: Option<f64>,
    #[serde(default)]
    space1_base: Option<f64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TabIconRequest {
    tab_icon_size: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ChatUserScaleRequest {
    #[serde(default)]
    font_override: Option<f64>,
    #[serde(default = "one")]
    interface_scale: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CardMetricsRequest {
    density: DensityTokens,
    #[serde(default = "one")]
    interface_scale: f64,
    button_corner_radius: f64,
    #[serde(default)]
    space_bases: Option<[f64; 6]>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct CardSizesReply {
    factor: f64,
    #[serde(flatten)]
    sizes: page::CardSizes,
}

/// Runs the `tokens.density_*` ops.
pub fn call(name: &str, request: &Value) -> OpResult {
    match name {
        "density_entries" => reply(&catalog::ALL),
        "density_entry" => {
            let r: KeyRequest = parse(request)?;
            reply(&catalog::entry(&r.key))
        }
        "density_group_title" => {
            let r: GroupRequest = parse(request)?;
            reply(&r.group.title())
        }
        "density_unlisted_keys" => reply(&catalog::UNLISTED_KEYS),
        "density_explicit_value" => {
            let r: EntryDensityRequest = parse(request)?;
            reply(&catalog::explicit_value(entry_for(&r.key)?, &r.density))
        }
        "density_value" => {
            let r: ValueRequest = parse(request)?;
            reply(&catalog::value(entry_for(&r.key)?, &r.density, r.fallback, r.interface_scale))
        }
        "density_setting" => {
            let r: SettingRequest = parse(request)?;
            reply(&catalog::setting(entry_for(&r.key)?, r.value, &r.density))
        }
        "density_resetting" => {
            let r: EntryBaseRequest = parse(request)?;
            reply(&catalog::resetting(entry_for(&r.key)?, &r.density, &r.base))
        }
        "density_resetting_all" => {
            let r: DensityBaseRequest = parse(request)?;
            reply(&catalog::resetting_all(&r.density, &r.base))
        }
        "density_differs" => {
            let r: EntryBaseRequest = parse(request)?;
            reply(&catalog::differs(entry_for(&r.key)?, &r.density, &r.base))
        }
        "density_base" => {
            let r: DensityRequest = parse(request)?;
            reply(catalog::base(&r.density))
        }
        "density_preset" => {
            let r: PresetRequest = parse(request)?;
            let p = r.preset;
            reply(&PresetReply {
                raw_value: p.raw(),
                name: p.name(),
                scale_factor: p.scale_factor(),
                omnibar_scale_factor: p.omnibar_scale_factor(),
                tokens: p.tokens(),
            })
        }
        "density_resolve" => {
            let r: ResolveRequest = parse(request)?;
            reply(&r.density.resolve(r.compact, r.comfortable, r.token.as_deref()))
        }
        "density_text_size" => {
            let r: ResolveRequest = parse(request)?;
            reply(&r.density.text_size(r.compact, r.comfortable))
        }
        "density_space" => {
            let r: SpaceRequest = parse(request)?;
            reply(&r.density.space(r.value))
        }
        "density_font_token" => {
            let r: FontTokenRequest = parse(request)?;
            reply(&r.density.font_token(&r.key))
        }
        "density_info" => {
            let r: DensityRequest = parse(request)?;
            let d = &r.density;
            reply(&InfoReply {
                family: d.family(),
                is_built_in: d.is_built_in(),
                uniform_scale: d.uniform_scale(),
                uses_default_row_fill: d.uses_default_row_fill(),
                level_body_size: d.level_body_size(),
                body_size: d.body_size(),
                sidebar_title_size: tokens::sidebar_title_size(d),
            })
        }
        "density_user_scale" => {
            let r: ScaleRequest = parse(request)?;
            reply(&tokens::user_scale(&r.density, r.font_override, r.interface_scale))
        }
        "density_page_density_scale" => {
            let r: PageDensityScaleRequest = parse(request)?;
            let space1 = r.space1_base.unwrap_or(metrics::SPACE_BASES[0]);
            let row =
                metrics::density_row_height(&r.density, r.interface_scale, r.row_override, space1);
            let default_row = metrics::default_density_row_height(space1);
            reply(&page::page_density_scale(&r.density, r.interface_scale, row, default_row))
        }
        "density_page_row_text_scale" => {
            let r: ScaleRequest = parse(request)?;
            let user = tokens::user_scale(&r.density, r.font_override, r.interface_scale);
            reply(&page::page_row_text_scale(&r.density, user))
        }
        "density_page_row_icon_scale" => {
            let r: TabIconRequest = parse(request)?;
            reply(&page::page_row_icon_scale(r.tab_icon_size))
        }
        "density_page_density_text_scale" => {
            let r: ScaleRequest = parse(request)?;
            reply(&page::page_density_text_scale(&r.density, r.font_override, r.interface_scale))
        }
        "density_page_chat_text_scale" => {
            let r: ScaleRequest = parse(request)?;
            reply(&page::page_chat_text_scale(&r.density, r.font_override, r.interface_scale))
        }
        "density_chat_user_scale" => {
            let r: ChatUserScaleRequest = parse(request)?;
            reply(&page::chat_user_scale(r.font_override, r.interface_scale))
        }
        "density_home_chat_density_scale" => {
            let r: DensityRequest = parse(request)?;
            reply(&page::home_chat_density_scale(&r.density))
        }
        "density_card_sizes" => {
            let r: ScaleRequest = parse(request)?;
            let user = tokens::user_scale(&r.density, r.font_override, r.interface_scale);
            let factor = page::card_text_factor(&r.density, user);
            reply(&CardSizesReply { factor, sizes: page::card_sizes(factor) })
        }
        "density_card_metrics" => {
            let r: CardMetricsRequest = parse(request)?;
            let bases = r.space_bases.unwrap_or(metrics::SPACE_BASES);
            let spaces = bases.map(|b| metrics::space(&r.density, r.interface_scale, b));
            reply(&page::card_metrics(spaces, r.button_corner_radius))
        }
        _ => Err(OpError::Unknown),
    }
}
