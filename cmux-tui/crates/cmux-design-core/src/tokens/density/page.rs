//! A port of Typography+PageDensity.swift (the scales app web pages and chats draw at) and
//! CardScale.swift (card and dialog text sizes and metrics). Fonts themselves stay in Swift;
//! these are their point sizes.

use super::tokens::{
    DensityPreset, DensityTokens, half, reference_tokens, sidebar_title_size, smax,
};
use crate::tokens::metrics::{button_container, scale};
use serde::{Deserialize, Serialize};

/// `TypeScale.Base`: the type ramp's steps.
pub mod type_scale {
    /// `caption`.
    pub const CAPTION: f64 = 11.0;
    /// `detail`.
    pub const DETAIL: f64 = 12.0;
    /// `body`.
    pub const BODY: f64 = 13.0;
    /// `field`.
    pub const FIELD: f64 = 14.0;
    /// `title`.
    pub const TITLE: f64 = 15.0;
    /// `heading`.
    pub const HEADING: f64 = 20.0;
}

/// `Typography.pageDensityScale`: the uniform scale (interface-scaled), else the row height
/// over Default's.
pub fn page_density_scale(
    tokens: &DensityTokens,
    interface_scale: f64,
    density_row_height: f64,
    default_density_row_height: f64,
) -> f64 {
    match tokens.uniform_scale() {
        Some(u) => scale(u, interface_scale),
        None => density_row_height / default_density_row_height,
    }
}

/// `Typography.pageRowTextScale`: the row title over Default's, times `userScale`.
pub fn page_row_text_scale(tokens: &DensityTokens, user_scale: f64) -> f64 {
    sidebar_title_size(tokens) / smax(1.0, sidebar_title_size(DensityPreset::Cozy.tokens()))
        * user_scale
}

/// `Typography.pageRowIconScale`: the live `Metrics.tabIconSize` over Default's token.
pub fn page_row_icon_scale(tab_icon_size: f64) -> f64 {
    tab_icon_size / smax(1.0, DensityPreset::Cozy.tokens().token("tabIconSize").unwrap_or(16.0))
}

/// `Typography.pageDensityTextScale`: the chrome body (Text Size, else the density's) over
/// Default's, times the interface scale.
pub fn page_density_text_scale(
    tokens: &DensityTokens,
    font_override: Option<f64>,
    interface_scale: f64,
) -> f64 {
    let body = font_override.unwrap_or_else(|| tokens.body_size());
    body / DensityPreset::Cozy.tokens().body_size() * interface_scale
}

/// `Typography.pageChatTextScale`: Text Size, else Default's body times `chatTextScale`, over
/// Default's body, times the interface scale.
pub fn page_chat_text_scale(
    tokens: &DensityTokens,
    font_override: Option<f64>,
    interface_scale: f64,
) -> f64 {
    let drawn = DensityPreset::Cozy.tokens().body_size();
    let density_body = tokens.token("chatTextScale").map(|s| drawn * s).unwrap_or(drawn);
    let body = font_override.unwrap_or(density_body);
    body / drawn * interface_scale
}

/// `Typography.chatUserScale`: Text Size over Default's body, times the interface scale.
pub fn chat_user_scale(font_override: Option<f64>, interface_scale: f64) -> f64 {
    let drawn = DensityPreset::Cozy.tokens().body_size();
    let body = font_override.unwrap_or(drawn);
    body / drawn * interface_scale
}

/// `Typography.homeChatDensityScale`: the `homeTextScale` token, else 1.
pub fn home_chat_density_scale(tokens: &DensityTokens) -> f64 {
    tokens.token("homeTextScale").unwrap_or(1.0)
}

/// `Typography.cardTextFactor`: the density's 12/13 text over the reference's, times `userScale`.
pub fn card_text_factor(tokens: &DensityTokens, user_scale: f64) -> f64 {
    let reference = reference_tokens().text_size(12.0, 13.0);
    tokens.text_size(12.0, 13.0) / smax(1.0, reference) * user_scale
}

/// `Typography.cardSize(_:)`: a type step times the factor, on the half-point grid.
pub fn card_size(step: f64, factor: f64) -> f64 {
    half(step * factor)
}

/// The card fonts' point sizes (`cardTitle` ... `dialogTitle`).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CardSizes {
    /// `cardTitle` (body step).
    pub title: f64,
    /// `cardMessage` (body step).
    pub message: f64,
    /// `cardBody` (detail step).
    pub body: f64,
    /// `cardBodyDigits` (detail step).
    pub body_digits: f64,
    /// `cardButton` (detail step).
    pub button: f64,
    /// `cardCaption` (caption step).
    pub caption: f64,
    /// `dialogTitle` (title step).
    pub dialog_title: f64,
}

/// The card fonts' sizes for `factor` ([`card_text_factor`]).
pub fn card_sizes(factor: f64) -> CardSizes {
    let detail = card_size(type_scale::DETAIL, factor);
    let body = card_size(type_scale::BODY, factor);
    CardSizes {
        title: body,
        message: body,
        body: detail,
        body_digits: detail,
        button: detail,
        caption: card_size(type_scale::CAPTION, factor),
        dialog_title: card_size(type_scale::TITLE, factor),
    }
}

/// The card metrics (`Metrics.cardPadding` ... `dialogPadding`).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CardMetrics {
    /// `cardPadding`: space4 + space1.
    pub card_padding: f64,
    /// `cardTextGap`: space1.
    pub card_text_gap: f64,
    /// `cardRowGap`: space3.
    pub card_row_gap: f64,
    /// `cardCornerRadius`: the button corner around `cardPadding`.
    pub card_corner_radius: f64,
    /// `dialogPadding`: space6.
    pub dialog_padding: f64,
}

/// The card metrics from the grid (`spaces` = space1...space6) and `buttonCornerRadius`.
pub fn card_metrics(spaces: [f64; 6], button_corner_radius: f64) -> CardMetrics {
    let card_padding = spaces[3] + spaces[0];
    CardMetrics {
        card_padding,
        card_text_gap: spaces[0],
        card_row_gap: spaces[2],
        card_corner_radius: button_container(button_corner_radius, card_padding).outer_radius(),
        dialog_padding: spaces[5],
    }
}
