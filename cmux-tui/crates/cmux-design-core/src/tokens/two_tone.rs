//! `appearance.twoTone`: the chrome (sidebar, tab bar) takes tone A, the content panes (terminal,
//! agent pane, New Tab page, Home) take tone B. Ports `CmuxNextDesign/TwoTone.swift` (`enum TwoTone`:
//! its constants, the pairing table, `paintsContent`, `tones(background:foreground:accent:dark:)` and
//! `color(for:tokens:)`).
//!
//! The colour math is `cmux_theme_tokens`' port of `ThemeRGB`: `oklch` (`ThemeRGB.oklch`),
//! `from_oklch` (`ThemeRGB(oklchLightness:chroma:hue:)`) and `fit_contrast`
//! (`ThemeRGB.fitted(contrast:lighter:)`), the same formulas as Swift's `AppColor`.
//!
//! Ops: `tokens.two_tone_values`, `tokens.two_tone_constants`, `tokens.two_tone_variants`,
//! `tokens.two_tone_paints_content`, `tokens.two_tone_tones`, `tokens.two_tone_color`.

use crate::ops::{OpError, OpResult, parse, reply};
use crate::tokens::color::{Color, Rgb};
use cmux_theme_tokens::{Oklch, fit_contrast, from_oklch, oklch};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// Text on a tone (WCAG 2 AA, `TwoTone.textMinimum`).
pub const TEXT_MINIMUM: f64 = 4.5;
/// The accent on a tone (WCAG 2 non-text, `TwoTone.markMinimum`).
pub const MARK_MINIMUM: f64 = 3.0;
/// `auto`: tone A's OKLCH lightness step from the background.
pub const AUTO_LIGHTNESS_STEP: f64 = 0.045;
/// `auto`, dark: tone A's least OKLCH lightness.
pub const AUTO_DARK_FLOOR: f64 = 0.18;
/// `auto`: the share tone A turns from the background toward the accent in OKLab's a/b plane.
pub const AUTO_ACCENT_SHARE: f64 = 0.12;
/// `auto`: an accent with less OKLCH chroma is neutral and adds no tint.
pub const AUTO_HUED_CHROMA: f64 = 0.04;
/// `auto`: tone A's most chroma, unless the background has more of its own.
pub const AUTO_MAX_CHROMA: f64 = 0.02;
/// `auto`: a tone nearer the background than this steps the other way.
pub const AUTO_LEAST_STEP: f64 = 0.02;

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

/// What a two-tone paints (Swift `TwoTone.Tones`).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Tones {
    /// Tone A: the sidebar and the tab bar.
    pub chrome: Rgb,
    /// Tone B: the content panes; None keeps the theme's own (`auto`).
    pub content: Option<Rgb>,
    /// The accent, standing out on both tones.
    pub accent: Rgb,
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
        let v = |chrome, content, accent| Variant { chrome, content, accent };
        let (dark, light) = match self {
            TwoTone::Off | TwoTone::Auto => return None,
            TwoTone::InkSakura => {
                (v(0x1E1A24, 0x131118, 0xF4A6C0), v(0xF5E3EA, 0xFCF8F6, 0xC24D7C))
            }
            TwoTone::CharcoalRose => {
                (v(0x161616, 0x202020, 0xEE5396), v(0xEDEDED, 0xFAFAFA, 0xD02670))
            }
            TwoTone::InkMagenta => {
                (v(0x082451, 0x0D1526, 0xD32D6B), v(0xD9E2F0, 0xF7F9FC, 0xB0245A))
            }
            TwoTone::CreamForest => {
                (v(0x1B2E24, 0x151A16, 0xE3D6B0), v(0xEFE8D6, 0xFBF8F0, 0x2E6B4E))
            }
            TwoTone::NavySand => (v(0x14213D, 0x11151D, 0xDDBE91), v(0xECE1CE, 0xFAF7F1, 0x1F3B6E)),
            TwoTone::BoneOxblood => {
                (v(0x2B1518, 0x171313, 0xE8DDCB), v(0xE8E0D2, 0xF9F6F0, 0x7D2433))
            }
            TwoTone::SlateMatcha => {
                (v(0x1F2622, 0x151917, 0xA9C98A), v(0xE4ECDB, 0xFAFBF7, 0x4D6B2C))
            }
            TwoTone::PlumAmber => {
                (v(0x261B30, 0x17131C, 0xF0B45C), v(0xEEE4F3, 0xFCFAFD, 0x985A10))
            }
        };
        Some(Variants { dark, light })
    }

    /// Whether this value paints the content panes (a pairing; `auto` keeps the theme's).
    pub fn paints_content(self) -> bool {
        self.variants().is_some()
    }

    /// The tones this value gives a theme; None for `off` (Swift `tones(background:foreground:accent:dark:)`).
    #[allow(clippy::manual_clamp)] // Swift max/min, NaN-faithful.
    pub fn tones(self, background: Rgb, foreground: Rgb, accent: Rgb, dark: bool) -> Option<Tones> {
        let readable = |tone: Rgb| fit_contrast(tone, &[(foreground, TEXT_MINIMUM)], Some(!dark));
        let mark = |color: Rgb, chrome: Rgb, content: Rgb| {
            fit_contrast(color, &[(chrome, MARK_MINIMUM), (content, MARK_MINIMUM)], Some(dark))
        };
        match self {
            TwoTone::Off => None,
            TwoTone::Auto => {
                let ground = oklch(background);
                let tint = oklch(accent);
                let neutral = (1.0 - ground.c / AUTO_MAX_CHROMA).max(0.0);
                let share =
                    if tint.c >= AUTO_HUED_CHROMA { AUTO_ACCENT_SHARE * neutral } else { 0.0 };
                let plane = |chroma: f64, hue: f64| {
                    let radians = hue * (std::f64::consts::PI / 180.0);
                    (chroma * radians.cos(), chroma * radians.sin())
                };
                let (ga, gb) = plane(ground.c, ground.h);
                let (aa, ab) = plane(tint.c, tint.h);
                let a = ga + (aa - ga) * share;
                let b = gb + (ab - gb) * share;
                let chroma = a.hypot(b).min(ground.c.max(AUTO_MAX_CHROMA));
                let mut hue = b.atan2(a) * (180.0 / std::f64::consts::PI);
                hue %= 360.0;
                if hue < 0.0 {
                    hue += 360.0;
                }
                let at = |lightness: f64| {
                    readable(from_oklch(Oklch {
                        l: lightness.max(0.0).min(1.0),
                        c: chroma,
                        h: hue,
                    }))
                };
                let toward = if dark {
                    (ground.l + AUTO_LIGHTNESS_STEP).max(AUTO_DARK_FLOOR)
                } else {
                    ground.l - AUTO_LIGHTNESS_STEP
                };
                let away = if dark {
                    ground.l - AUTO_LIGHTNESS_STEP
                } else {
                    ground.l + AUTO_LIGHTNESS_STEP
                };
                let apart = |tone: Rgb| (oklch(tone).l - ground.l).abs();
                let mut chrome = at(toward);
                if apart(chrome) < AUTO_LEAST_STEP {
                    let other = at(away);
                    if apart(other) > apart(chrome) {
                        chrome = other;
                    }
                }
                Some(Tones { chrome, content: None, accent: mark(accent, chrome, background) })
            }
            _ => {
                let variants = self.variants()?;
                let variant = if dark { variants.dark } else { variants.light };
                let chrome = readable(Rgb::hex(variant.chrome));
                let content = readable(Rgb::hex(variant.content));
                Some(Tones {
                    chrome,
                    content: Some(content),
                    accent: mark(Rgb::hex(variant.accent), chrome, content),
                })
            }
        }
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
