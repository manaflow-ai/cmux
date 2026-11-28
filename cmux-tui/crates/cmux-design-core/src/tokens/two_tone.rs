//! `appearance.twoTone`: the chrome (sidebar, tab bar) takes tone A, the content panes (terminal,
//! agent pane, New Tab page, Home) take tone B. Ports `CmuxNextDesign/TwoTone.swift` (`enum TwoTone`:
//! its constants, the pairing table, `paintsContent`, `tones(background:foreground:accent:dark:)` and
//! `color(for:tokens:)`).
//!
//! The rules themselves (the constants, the pairing table, the `auto` OKLCH math and the
//! readable/mark fits) are `cmux_config::theme_file::two_tone`'s, the source Swift's fixture test
//! already checks against; this module adds only what cmux-config lacks: Swift's enum and raw
//! values, `paintsContent`, `color(for:)` and the op shapes.
//!
//! Ops: `tokens.two_tone_values`, `tokens.two_tone_constants`, `tokens.two_tone_variants`,
//! `tokens.two_tone_paints_content`, `tokens.two_tone_tones`, `tokens.two_tone_color`.

use crate::ops::{OpError, OpResult, parse, reply};
use crate::tokens::color::{Color, Rgb};
use cmux_config::theme_file::two_tone as rules;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// The constants and `Tones`, cmux-config's (Swift `TwoTone`'s statics and `TwoTone.Tones`).
pub use rules::{
    AUTO_ACCENT_SHARE, AUTO_DARK_FLOOR, AUTO_HUED_CHROMA, AUTO_LEAST_STEP, AUTO_LIGHTNESS_STEP,
    AUTO_MAX_CHROMA, MARK_MINIMUM, TEXT_MINIMUM, Tones,
};

/// `appearance.twoTone`'s values (Swift `TwoTone`), raw values as Swift's.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TwoTone {
    /// Nothing changes (the default).
    Off,
    /// Tone A from the theme.
    Auto,
    /// Ink & Sakura.
    InkSakura,
    /// Charcoal & Rose.
    CharcoalRose,
    /// Ink Blue & Magenta.
    InkMagenta,
    /// Cream & Forest.
    CreamForest,
    /// Navy & Sand.
    NavySand,
    /// Bone & Oxblood.
    BoneOxblood,
    /// Slate & Matcha.
    SlateMatcha,
    /// Plum & Amber.
    PlumAmber,
}

/// One variant of a pairing, as `0xRRGGBB` (Swift `TwoTone.Variant`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Variant {
    /// Tone A.
    pub chrome: u32,
    /// Tone B.
    pub content: u32,
    /// The accent.
    pub accent: u32,
}

/// A pairing's dark and light variants.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Variants {
    /// The dark theme's variant.
    pub dark: Variant,
    /// The light theme's variant.
    pub light: Variant,
}

/// The surfaces a two-tone may paint (Swift `SurfaceKind`, raw values as Swift's).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SurfaceKind {
    /// The sidebar.
    Sidebar,
    /// The tab bar.
    TabBar,
    /// The terminal.
    Terminal,
    /// The agent pane.
    AgentPane,
    /// Settings.
    Settings,
    /// The New Tab page.
    NewTabPage,
    /// Home.
    Home,
    /// The browser's chrome.
    BrowserChrome,
    /// The docks.
    Docks,
    /// Internal pages.
    InternalPage,
    /// The split divider line.
    SplitDivider,
    /// The diff page.
    Diff,
    /// The Markdown page.
    Markdown,
    /// The code editor page.
    Editor,
}

impl TwoTone {
    /// Every value, in Swift's `allCases` order.
    pub const ALL: [TwoTone; 10] = [
        TwoTone::Off,
        TwoTone::Auto,
        TwoTone::InkSakura,
        TwoTone::CharcoalRose,
        TwoTone::InkMagenta,
        TwoTone::CreamForest,
        TwoTone::NavySand,
        TwoTone::BoneOxblood,
        TwoTone::SlateMatcha,
        TwoTone::PlumAmber,
    ];

    /// The raw value (Swift `rawValue`).
    pub fn raw_value(self) -> &'static str {
        match self {
            TwoTone::Off => "off",
            TwoTone::Auto => "auto",
            TwoTone::InkSakura => "inkSakura",
            TwoTone::CharcoalRose => "charcoalRose",
            TwoTone::InkMagenta => "inkMagenta",
            TwoTone::CreamForest => "creamForest",
            TwoTone::NavySand => "navySand",
            TwoTone::BoneOxblood => "boneOxblood",
            TwoTone::SlateMatcha => "slateMatcha",
            TwoTone::PlumAmber => "plumAmber",
        }
    }

    /// The value a raw value names (Swift `TwoTone(rawValue:)`).
    pub fn from_raw(raw: &str) -> Option<TwoTone> {
        Self::ALL.into_iter().find(|v| v.raw_value() == raw)
    }

    /// The pairing's dark and light variants; None for `off` and `auto`.
    pub fn variants(self) -> Option<Variants> {
        let pairing = rules::pairing(self.raw_value())?;
        let v =
            |x: rules::Variant| Variant { chrome: x.chrome, content: x.content, accent: x.accent };
        Some(Variants { dark: v(pairing.dark), light: v(pairing.light) })
    }

    /// Whether this value paints the content panes (a pairing; `auto` keeps the theme's).
    pub fn paints_content(self) -> bool {
        self.variants().is_some()
    }

    /// The tones this value gives a theme; None for `off` (Swift `tones(background:foreground:accent:dark:)`).
    pub fn tones(self, background: Rgb, foreground: Rgb, accent: Rgb, dark: bool) -> Option<Tones> {
        rules::resolve(self.raw_value(), rules::Theme { background, foreground, accent, dark })
    }

    /// The tone `kind` takes under this value, or None when it keeps its own (Swift
    /// `color(for:tokens:)`, with the tokens' `surfaceBackground`, `textPrimary`, `accent` and
    /// `isDark` as inputs; each colour is made opaque first, as Swift's `withAlpha(1)`).
    pub fn color_for(
        self,
        kind: SurfaceKind,
        surface_background: Rgb,
        text_primary: Rgb,
        accent: Rgb,
        is_dark: bool,
    ) -> Option<Rgb> {
        if self == TwoTone::Off {
            return None;
        }
        let chrome = match kind {
            SurfaceKind::Sidebar | SurfaceKind::TabBar => true,
            SurfaceKind::Terminal
            | SurfaceKind::AgentPane
            | SurfaceKind::NewTabPage
            | SurfaceKind::Home => false,
            _ => return None,
        };
        if !chrome && !self.paints_content() {
            return None;
        }
        let tones = self.tones(
            surface_background.with_alpha(1.0),
            text_primary.with_alpha(1.0),
            accent.with_alpha(1.0),
            is_dark,
        )?;
        if chrome { Some(tones.chrome) } else { tones.content }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ValueRequest {
    value: TwoTone,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TonesRequest {
    value: TwoTone,
    background: Color,
    foreground: Color,
    accent: Color,
    dark: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct TonesReply {
    chrome: Color,
    content: Option<Color>,
    accent: Color,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ColorRequest {
    value: TwoTone,
    kind: SurfaceKind,
    surface_background: Color,
    text_primary: Color,
    accent: Color,
    is_dark: bool,
}

/// Runs the `tokens.two_tone_*` ops.
pub fn call(name: &str, request: &Value) -> OpResult {
    match name {
        "two_tone_values" => reply(&TwoTone::ALL.iter().map(|v| v.raw_value()).collect::<Vec<_>>()),
        "two_tone_constants" => Ok(json!({
            "textMinimum": TEXT_MINIMUM,
            "markMinimum": MARK_MINIMUM,
            "autoLightnessStep": AUTO_LIGHTNESS_STEP,
            "autoDarkFloor": AUTO_DARK_FLOOR,
            "autoAccentShare": AUTO_ACCENT_SHARE,
            "autoHuedChroma": AUTO_HUED_CHROMA,
            "autoMaxChroma": AUTO_MAX_CHROMA,
            "autoLeastStep": AUTO_LEAST_STEP,
        })),
        "two_tone_variants" => {
            let r: ValueRequest = parse(request)?;
            reply(&r.value.variants())
        }
        "two_tone_paints_content" => {
            let r: ValueRequest = parse(request)?;
            reply(&r.value.paints_content())
        }
        "two_tone_tones" => {
            let r: TonesRequest = parse(request)?;
            let tones =
                r.value.tones(r.background.into(), r.foreground.into(), r.accent.into(), r.dark);
            reply(&tones.map(|t| TonesReply {
                chrome: t.chrome.into(),
                content: t.content.map(Into::into),
                accent: t.accent.into(),
            }))
        }
        "two_tone_color" => {
            let r: ColorRequest = parse(request)?;
            let color = r.value.color_for(
                r.kind,
                r.surface_background.into(),
                r.text_primary.into(),
                r.accent.into(),
                r.is_dark,
            );
            reply(&color.map(Color::from))
        }
        _ => Err(OpError::Unknown),
    }
}
