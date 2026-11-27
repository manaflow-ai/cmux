//! `appearance.twoTone`: a toggle any theme or plain settings can switch on,
//! under any chrome style. The chrome (the sidebar and the tab bar) takes
//! tone A, the content panes (terminal, agent pane, New Tab page, Home) take
//! tone B, and the accent sits on both. Leo, 2026-11-19: "the two-tone ...
//! that's just one of the toggles you can have ... what would actually look
//! good and not eyesore-ish".
//!
//! - `off` (the default): nothing changes.
//! - `auto`: tone A from the theme itself: its background, a step lighter in
//!   dark and darker in light, turned toward the accent's hue with a little of
//!   its chroma; the content keeps the theme's background and the accent is
//!   the theme's, fitted to both.
//! - A pairing ([`PAIRINGS`]): a curated chrome, content and accent, with a
//!   light and a dark variant; the theme's light or dark picks one.
//!
//! Every tone keeps the theme's text readable on it (4.5:1, [`TEXT_MINIMUM`])
//! and the accent stands out on both tones (3:1, [`MARK_MINIMUM`]), moving
//! only OKLCH lightness so a hue never shifts. An explicit
//! `appearance.surfaces.<surface>.color` still wins over a tone (the app's
//! `SurfaceBackgrounds`). The Swift mirror (`TwoTone`, CmuxNextDesign) is
//! checked against [`fixture`]: its test runs this crate's tests to write the
//! fixture where it reads it, never into git.

use cmux_theme_tokens::{Oklch, Rgb, fit_contrast, from_oklch, oklch};
use serde_json::{Value, json};

/// The setting.
pub const SETTING_KEY: &str = "appearance.twoTone";
/// The default: no second tone.
pub const OFF: &str = "off";
/// Tone A derived from the theme.
pub const AUTO: &str = "auto";
/// Text on a tone (WCAG 2 AA, `AppTheme.textMinimum`).
pub const TEXT_MINIMUM: f64 = 4.5;
/// The accent on a tone (WCAG 2 non-text contrast).
pub const MARK_MINIMUM: f64 = 3.0;
/// `auto`: how far tone A's OKLCH lightness steps from the background.
pub const AUTO_LIGHTNESS_STEP: f64 = 0.045;
/// `auto`, dark: tone A's least OKLCH lightness, so a black background still
/// gets a tone apart from it (lightness near 0 is all one black).
pub const AUTO_DARK_FLOOR: f64 = 0.18;
/// `auto`: tone A turns this share of the way from the background toward the
/// accent in OKLab's a/b plane (a tint of the theme, never the accent's hue
/// at the background's chroma, which turns a purple ground brown).
pub const AUTO_ACCENT_SHARE: f64 = 0.12;
/// `auto`: an accent with less OKLCH chroma than this is neutral and adds no
/// tint.
pub const AUTO_HUED_CHROMA: f64 = 0.04;
/// `auto`: tone A's most chroma, unless the background has more of its own.
pub const AUTO_MAX_CHROMA: f64 = 0.02;
/// `auto`: a tone less than this OKLCH lightness from the background, where
/// the text pushed it back, steps the other way instead.
pub const AUTO_LEAST_STEP: f64 = 0.02;

/// One variant of a pairing, as `0xRRGGBB`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Variant {
    /// Tone A: the sidebar and the tab bar.
    pub chrome: u32,
    /// Tone B: the terminal, the agent pane, the New Tab page and Home.
    pub content: u32,
    pub accent: u32,
}

/// A curated two-tone pairing.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Pairing {
    /// The setting's value.
    pub id: &'static str,
    /// Its title in Settings and the command palette.
    pub title: &'static str,
    pub dark: Variant,
    pub light: Variant,
}

const fn variant(chrome: u32, content: u32, accent: u32) -> Variant {
    Variant { chrome, content, accent }
}

/// The pairings, in the order Settings lists them. Each is a muted ground
/// and one clear accent: a dark variant whose chrome and content sit a few
/// lightness steps apart in the same family, and a light one on paper tones.
pub const PAIRINGS: [Pairing; 8] = [
    Pairing {
        id: "inkSakura",
        title: "Ink & Sakura",
        dark: variant(0x1E1A24, 0x131118, 0xF4A6C0),
        light: variant(0xF5E3EA, 0xFCF8F6, 0xC24D7C),
    },
    Pairing {
        id: "charcoalRose",
        title: "Charcoal & Rose",
        dark: variant(0x161616, 0x202020, 0xEE5396),
        light: variant(0xEDEDED, 0xFAFAFA, 0xD02670),
    },
    Pairing {
        id: "inkMagenta",
        title: "Ink Blue & Magenta",
        dark: variant(0x082451, 0x0D1526, 0xD32D6B),
        light: variant(0xD9E2F0, 0xF7F9FC, 0xB0245A),
    },
    Pairing {
        id: "creamForest",
        title: "Cream & Forest",
        dark: variant(0x1B2E24, 0x151A16, 0xE3D6B0),
        light: variant(0xEFE8D6, 0xFBF8F0, 0x2E6B4E),
    },
    Pairing {
        id: "navySand",
        title: "Navy & Sand",
        dark: variant(0x14213D, 0x11151D, 0xDDBE91),
        light: variant(0xECE1CE, 0xFAF7F1, 0x1F3B6E),
    },
    Pairing {
        id: "boneOxblood",
        title: "Bone & Oxblood",
        dark: variant(0x2B1518, 0x171313, 0xE8DDCB),
        light: variant(0xE8E0D2, 0xF9F6F0, 0x7D2433),
    },
    Pairing {
        id: "slateMatcha",
        title: "Slate & Matcha",
        dark: variant(0x1F2622, 0x151917, 0xA9C98A),
        light: variant(0xE4ECDB, 0xFAFBF7, 0x4D6B2C),
    },
    Pairing {
        id: "plumAmber",
        title: "Plum & Amber",
        dark: variant(0x261B30, 0x17131C, 0xF0B45C),
        light: variant(0xEEE4F3, 0xFCFAFD, 0x985A10),
    },
];

/// Every value of the setting, in the schema's order: `off`, `auto`, then
/// the pairings.
pub fn values() -> Vec<&'static str> {
    [OFF, AUTO].into_iter().chain(PAIRINGS.iter().map(|p| p.id)).collect()
}

/// The pairing `id` names.
pub fn pairing(id: &str) -> Option<&'static Pairing> {
    PAIRINGS.iter().find(|p| p.id == id)
}

/// The theme colors a two-tone derives from (one scope's tokens).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Theme {
    pub background: Rgb,
    /// The primary text color, which must stay readable on both tones.
    pub foreground: Rgb,
    pub accent: Rgb,
    /// Whether the theme is dark: it picks a pairing's variant.
    pub dark: bool,
}

/// What a two-tone paints.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Tones {
    /// Tone A: the sidebar and the tab bar.
    pub chrome: Rgb,
    /// Tone B: the content panes; None keeps the theme's own (`auto`).
    pub content: Option<Rgb>,
    /// The accent, standing out on both tones.
    pub accent: Rgb,
}

/// The tones `value` gives `theme`; None for `off` and for an unknown value.
pub fn resolve(value: &str, theme: Theme) -> Option<Tones> {
    if value == AUTO {
        return Some(auto(theme));
    }
    let pairing = pairing(value)?;
    let variant = if theme.dark { pairing.dark } else { pairing.light };
    let chrome = readable(Rgb::hex(variant.chrome), theme);
    let content = readable(Rgb::hex(variant.content), theme);
    Some(Tones {
        chrome,
        content: Some(content),
        accent: mark(Rgb::hex(variant.accent), chrome, content, theme),
    })
}

/// `auto`: tone A one lightness step from the background (lighter in dark,
/// darker in light), tinted a little toward the accent.
fn auto(theme: Theme) -> Tones {
    let ground = oklch(theme.background);
    let accent = oklch(theme.accent);
    // A ground with a tint of its own (Solarized's cream) keeps it: the accent tints only a neutral one.
    let neutral = (1.0 - ground.c / AUTO_MAX_CHROMA).max(0.0);
    let share = if accent.c >= AUTO_HUED_CHROMA { AUTO_ACCENT_SHARE * neutral } else { 0.0 };
    let plane = |v: Oklch| {
        let radians = v.h.to_radians();
        (v.c * radians.cos(), v.c * radians.sin())
    };
    let ((ga, gb), (aa, ab)) = (plane(ground), plane(accent));
    let (a, b) = (ga + (aa - ga) * share, gb + (ab - gb) * share);
    let c = a.hypot(b).min(ground.c.max(AUTO_MAX_CHROMA));
    let h = b.atan2(a).to_degrees().rem_euclid(360.0);
    let at = |l: f64| readable(from_oklch(Oklch { l: l.clamp(0.0, 1.0), c, h }), theme);
    let (toward, away) = if theme.dark {
        ((ground.l + AUTO_LIGHTNESS_STEP).max(AUTO_DARK_FLOOR), ground.l - AUTO_LIGHTNESS_STEP)
    } else {
        (ground.l - AUTO_LIGHTNESS_STEP, ground.l + AUTO_LIGHTNESS_STEP)
    };
    let apart = |tone: Rgb| (oklch(tone).l - ground.l).abs();
    let mut chrome = at(toward);
    if apart(chrome) < AUTO_LEAST_STEP {
        let other = at(away);
        if apart(other) > apart(chrome) {
            chrome = other;
        }
    }
    Tones { chrome, content: None, accent: mark(theme.accent, chrome, theme.background, theme) }
}

/// `tone` with the theme's text readable on it: darker under light text,
/// lighter under dark.
fn readable(tone: Rgb, theme: Theme) -> Rgb {
    fit_contrast(tone, &[(theme.foreground, TEXT_MINIMUM)], Some(!theme.dark))
}

/// `accent` standing out on both tones: lighter on dark tones, darker on light.
fn mark(accent: Rgb, chrome: Rgb, content: Rgb, theme: Theme) -> Rgb {
    fit_contrast(accent, &[(chrome, MARK_MINIMUM), (content, MARK_MINIMUM)], Some(theme.dark))
}

fn hex(color: Rgb) -> String {
    format!("#{:06X}", color.to_hex())
}

/// The sample themes [`fixture`] resolves: dark and light, neutral and hued
/// accents, and the extremes (pure black and white).
pub const FIXTURE_THEMES: [(&str, u32, u32, u32, bool); 8] = [
    ("ghostty-dark", 0x282C34, 0xFFFFFF, 0xC678DD, true),
    ("tokyo-night", 0x1A1B26, 0xC0CAF5, 0x7AA2F7, true),
    ("black-neutral", 0x000000, 0xEEEEEE, 0x9A9A9A, true),
    ("rose-pine", 0x191724, 0xE0DEF4, 0xEBBCBA, true),
    ("solarized-light", 0xFDF6E3, 0x586E75, 0x268BD2, false),
    ("github-light", 0xFFFFFF, 0x1F2328, 0x0969DA, false),
    ("paper-neutral", 0xF5F5F5, 0x222222, 0x777777, false),
    ("catppuccin-latte", 0xEFF1F5, 0x4C4F69, 0x8839EF, false),
];

/// The pairing table and every value resolved for [`FIXTURE_THEMES`], as
/// JSON: the Swift mirror's test (`TwoToneTests`) has
/// `tests::writes_the_swift_fixture` write it and must give the same colors.
pub fn fixture() -> Value {
    let pairings: Vec<Value> = PAIRINGS
        .iter()
        .map(|p| {
            let side = |v: Variant| {
                json!({"chrome": hex(Rgb::hex(v.chrome)), "content": hex(Rgb::hex(v.content)), "accent": hex(Rgb::hex(v.accent))})
            };
            json!({"id": p.id, "title": p.title, "dark": side(p.dark), "light": side(p.light)})
        })
        .collect();
    let cases: Vec<Value> = FIXTURE_THEMES
        .iter()
        .flat_map(|&(name, background, foreground, accent, dark)| {
            let theme = Theme {
                background: Rgb::hex(background),
                foreground: Rgb::hex(foreground),
                accent: Rgb::hex(accent),
                dark,
            };
            values().into_iter().filter_map(move |value| {
                let tones = resolve(value, theme)?;
                Some(json!({
                    "theme": name,
                    "background": hex(theme.background),
                    "foreground": hex(theme.foreground),
                    "accent": hex(theme.accent),
                    "dark": dark,
                    "value": value,
                    "chrome": hex(tones.chrome),
                    "content": tones.content.map(hex),
                    "toneAccent": hex(tones.accent),
                }))
            })
        })
        .collect();
    json!({
        "$comment": "cmux-config theme_file::two_tone::fixture, written for TwoToneTests at test time and never committed. The Swift mirror (TwoTone, CmuxNextDesign) must resolve the same colors.",
        "values": values(),
        "pairings": pairings,
        "cases": cases,
    })
}

#[cfg(test)]
#[path = "two_tone_tests.rs"]
mod tests;
