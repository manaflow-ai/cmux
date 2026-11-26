//! Parity tests for `tokens::two_tone`: Swift's `TwoToneTests` (the cmux-config fixture, off paints
//! nothing, inkSakura's surfaces), with the fixture's cases inlined from cmux-config's
//! `two_tone::fixture` (the generator Swift reads at test time), plus pins.

use cmux_design_core::ops::{OpError, call};
use cmux_design_core::tokens::color::Rgb;
use cmux_design_core::tokens::two_tone::*;
use serde_json::json;

/// cmux-config's `FIXTURE_THEMES` x every value: theme, value, background, foreground, accent,
/// dark, then the expected chrome, content and accent.
#[rustfmt::skip]
const CASES: &[(&str, TwoTone, u32, u32, u32, bool, u32, Option<u32>, u32)] = &[
    ("ghostty-dark", TwoTone::Auto, 0x282C34, 0xFFFFFF, 0xC678DD, true, 0x343741, None, 0xC678DD),
    ("ghostty-dark", TwoTone::InkSakura, 0x282C34, 0xFFFFFF, 0xC678DD, true, 0x1E1A24, Some(0x131118), 0xF4A6C0),
    ("ghostty-dark", TwoTone::CharcoalRose, 0x282C34, 0xFFFFFF, 0xC678DD, true, 0x161616, Some(0x202020), 0xEE5396),
    ("ghostty-dark", TwoTone::InkMagenta, 0x282C34, 0xFFFFFF, 0xC678DD, true, 0x082451, Some(0x0D1526), 0xD32D6B),
    ("ghostty-dark", TwoTone::CreamForest, 0x282C34, 0xFFFFFF, 0xC678DD, true, 0x1B2E24, Some(0x151A16), 0xE3D6B0),
    ("ghostty-dark", TwoTone::NavySand, 0x282C34, 0xFFFFFF, 0xC678DD, true, 0x14213D, Some(0x11151D), 0xDDBE91),
    ("ghostty-dark", TwoTone::BoneOxblood, 0x282C34, 0xFFFFFF, 0xC678DD, true, 0x2B1518, Some(0x171313), 0xE8DDCB),
    ("ghostty-dark", TwoTone::SlateMatcha, 0x282C34, 0xFFFFFF, 0xC678DD, true, 0x1F2622, Some(0x151917), 0xA9C98A),
    ("ghostty-dark", TwoTone::PlumAmber, 0x282C34, 0xFFFFFF, 0xC678DD, true, 0x261B30, Some(0x17131C), 0xF0B45C),
    ("tokyo-night", TwoTone::Auto, 0x1A1B26, 0xC0CAF5, 0x7AA2F7, true, 0x252631, None, 0x7AA2F7),
    ("tokyo-night", TwoTone::InkSakura, 0x1A1B26, 0xC0CAF5, 0x7AA2F7, true, 0x1E1A24, Some(0x131118), 0xF4A6C0),
    ("tokyo-night", TwoTone::CharcoalRose, 0x1A1B26, 0xC0CAF5, 0x7AA2F7, true, 0x161616, Some(0x202020), 0xEE5396),
    ("tokyo-night", TwoTone::InkMagenta, 0x1A1B26, 0xC0CAF5, 0x7AA2F7, true, 0x082451, Some(0x0D1526), 0xD32D6B),
    ("tokyo-night", TwoTone::CreamForest, 0x1A1B26, 0xC0CAF5, 0x7AA2F7, true, 0x1B2E24, Some(0x151A16), 0xE3D6B0),
    ("tokyo-night", TwoTone::NavySand, 0x1A1B26, 0xC0CAF5, 0x7AA2F7, true, 0x14213D, Some(0x11151D), 0xDDBE91),
    ("tokyo-night", TwoTone::BoneOxblood, 0x1A1B26, 0xC0CAF5, 0x7AA2F7, true, 0x2B1518, Some(0x171313), 0xE8DDCB),
    ("tokyo-night", TwoTone::SlateMatcha, 0x1A1B26, 0xC0CAF5, 0x7AA2F7, true, 0x1F2622, Some(0x151917), 0xA9C98A),
    ("tokyo-night", TwoTone::PlumAmber, 0x1A1B26, 0xC0CAF5, 0x7AA2F7, true, 0x261B30, Some(0x17131C), 0xF0B45C),
    ("black-neutral", TwoTone::Auto, 0x000000, 0xEEEEEE, 0x9A9A9A, true, 0x121212, None, 0x9A9A9A),
    ("black-neutral", TwoTone::InkSakura, 0x000000, 0xEEEEEE, 0x9A9A9A, true, 0x1E1A24, Some(0x131118), 0xF4A6C0),
    ("black-neutral", TwoTone::CharcoalRose, 0x000000, 0xEEEEEE, 0x9A9A9A, true, 0x161616, Some(0x202020), 0xEE5396),
    ("black-neutral", TwoTone::InkMagenta, 0x000000, 0xEEEEEE, 0x9A9A9A, true, 0x082451, Some(0x0D1526), 0xD32D6B),
    ("black-neutral", TwoTone::CreamForest, 0x000000, 0xEEEEEE, 0x9A9A9A, true, 0x1B2E24, Some(0x151A16), 0xE3D6B0),
    ("black-neutral", TwoTone::NavySand, 0x000000, 0xEEEEEE, 0x9A9A9A, true, 0x14213D, Some(0x11151D), 0xDDBE91),
    ("black-neutral", TwoTone::BoneOxblood, 0x000000, 0xEEEEEE, 0x9A9A9A, true, 0x2B1518, Some(0x171313), 0xE8DDCB),
    ("black-neutral", TwoTone::SlateMatcha, 0x000000, 0xEEEEEE, 0x9A9A9A, true, 0x1F2622, Some(0x151917), 0xA9C98A),
    ("black-neutral", TwoTone::PlumAmber, 0x000000, 0xEEEEEE, 0x9A9A9A, true, 0x261B30, Some(0x17131C), 0xF0B45C),
    ("rose-pine", TwoTone::Auto, 0x191724, 0xE0DEF4, 0xEBBCBA, true, 0x23222F, None, 0xEBBCBA),
    ("rose-pine", TwoTone::InkSakura, 0x191724, 0xE0DEF4, 0xEBBCBA, true, 0x1E1A24, Some(0x131118), 0xF4A6C0),
    ("rose-pine", TwoTone::CharcoalRose, 0x191724, 0xE0DEF4, 0xEBBCBA, true, 0x161616, Some(0x202020), 0xEE5396),
    ("rose-pine", TwoTone::InkMagenta, 0x191724, 0xE0DEF4, 0xEBBCBA, true, 0x082451, Some(0x0D1526), 0xD32D6B),
    ("rose-pine", TwoTone::CreamForest, 0x191724, 0xE0DEF4, 0xEBBCBA, true, 0x1B2E24, Some(0x151A16), 0xE3D6B0),
    ("rose-pine", TwoTone::NavySand, 0x191724, 0xE0DEF4, 0xEBBCBA, true, 0x14213D, Some(0x11151D), 0xDDBE91),
    ("rose-pine", TwoTone::BoneOxblood, 0x191724, 0xE0DEF4, 0xEBBCBA, true, 0x2B1518, Some(0x171313), 0xE8DDCB),
    ("rose-pine", TwoTone::SlateMatcha, 0x191724, 0xE0DEF4, 0xEBBCBA, true, 0x1F2622, Some(0x151917), 0xA9C98A),
    ("rose-pine", TwoTone::PlumAmber, 0x191724, 0xE0DEF4, 0xEBBCBA, true, 0x261B30, Some(0x17131C), 0xF0B45C),
    ("solarized-light", TwoTone::Auto, 0xFDF6E3, 0x586E75, 0x268BD2, false, 0xF2EBD7, None, 0x268BD2),
    ("solarized-light", TwoTone::InkSakura, 0xFDF6E3, 0x586E75, 0x268BD2, false, 0xF9E6ED, Some(0xFCF8F6), 0xC24D7C),
    ("solarized-light", TwoTone::CharcoalRose, 0xFDF6E3, 0x586E75, 0x268BD2, false, 0xEDEDED, Some(0xFAFAFA), 0xD02670),
    ("solarized-light", TwoTone::InkMagenta, 0xFDF6E3, 0x586E75, 0x268BD2, false, 0xE2ECFA, Some(0xF7F9FC), 0xB0245A),
    ("solarized-light", TwoTone::CreamForest, 0xFDF6E3, 0x586E75, 0x268BD2, false, 0xF2EBD8, Some(0xFBF8F0), 0x2E6B4E),
    ("solarized-light", TwoTone::NavySand, 0xFDF6E3, 0x586E75, 0x268BD2, false, 0xF5EAD6, Some(0xFAF7F1), 0x1F3B6E),
    ("solarized-light", TwoTone::BoneOxblood, 0xFDF6E3, 0x586E75, 0x268BD2, false, 0xF2EADB, Some(0xF9F6F0), 0x7D2433),
    ("solarized-light", TwoTone::SlateMatcha, 0xFDF6E3, 0x586E75, 0x268BD2, false, 0xE5EEDC, Some(0xFAFBF7), 0x4D6B2C),
    ("solarized-light", TwoTone::PlumAmber, 0xFDF6E3, 0x586E75, 0x268BD2, false, 0xF2E8F7, Some(0xFCFAFD), 0x985A10),
    ("github-light", TwoTone::Auto, 0xFFFFFF, 0x1F2328, 0x0969DA, false, 0xE8F1FE, None, 0x0969DA),
    ("github-light", TwoTone::InkSakura, 0xFFFFFF, 0x1F2328, 0x0969DA, false, 0xF5E3EA, Some(0xFCF8F6), 0xC24D7C),
    ("github-light", TwoTone::CharcoalRose, 0xFFFFFF, 0x1F2328, 0x0969DA, false, 0xEDEDED, Some(0xFAFAFA), 0xD02670),
    ("github-light", TwoTone::InkMagenta, 0xFFFFFF, 0x1F2328, 0x0969DA, false, 0xD9E2F0, Some(0xF7F9FC), 0xB0245A),
    ("github-light", TwoTone::CreamForest, 0xFFFFFF, 0x1F2328, 0x0969DA, false, 0xEFE8D6, Some(0xFBF8F0), 0x2E6B4E),
    ("github-light", TwoTone::NavySand, 0xFFFFFF, 0x1F2328, 0x0969DA, false, 0xECE1CE, Some(0xFAF7F1), 0x1F3B6E),
    ("github-light", TwoTone::BoneOxblood, 0xFFFFFF, 0x1F2328, 0x0969DA, false, 0xE8E0D2, Some(0xF9F6F0), 0x7D2433),
    ("github-light", TwoTone::SlateMatcha, 0xFFFFFF, 0x1F2328, 0x0969DA, false, 0xE4ECDB, Some(0xFAFBF7), 0x4D6B2C),
    ("github-light", TwoTone::PlumAmber, 0xFFFFFF, 0x1F2328, 0x0969DA, false, 0xEEE4F3, Some(0xFCFAFD), 0x985A10),
    ("paper-neutral", TwoTone::Auto, 0xF5F5F5, 0x222222, 0x777777, false, 0xE6E6E6, None, 0x777777),
    ("paper-neutral", TwoTone::InkSakura, 0xF5F5F5, 0x222222, 0x777777, false, 0xF5E3EA, Some(0xFCF8F6), 0xC24D7C),
    ("paper-neutral", TwoTone::CharcoalRose, 0xF5F5F5, 0x222222, 0x777777, false, 0xEDEDED, Some(0xFAFAFA), 0xD02670),
    ("paper-neutral", TwoTone::InkMagenta, 0xF5F5F5, 0x222222, 0x777777, false, 0xD9E2F0, Some(0xF7F9FC), 0xB0245A),
    ("paper-neutral", TwoTone::CreamForest, 0xF5F5F5, 0x222222, 0x777777, false, 0xEFE8D6, Some(0xFBF8F0), 0x2E6B4E),
    ("paper-neutral", TwoTone::NavySand, 0xF5F5F5, 0x222222, 0x777777, false, 0xECE1CE, Some(0xFAF7F1), 0x1F3B6E),
    ("paper-neutral", TwoTone::BoneOxblood, 0xF5F5F5, 0x222222, 0x777777, false, 0xE8E0D2, Some(0xF9F6F0), 0x7D2433),
    ("paper-neutral", TwoTone::SlateMatcha, 0xF5F5F5, 0x222222, 0x777777, false, 0xE4ECDB, Some(0xFAFBF7), 0x4D6B2C),
    ("paper-neutral", TwoTone::PlumAmber, 0xF5F5F5, 0x222222, 0x777777, false, 0xEEE4F3, Some(0xFCFAFD), 0x985A10),
    ("catppuccin-latte", TwoTone::Auto, 0xEFF1F5, 0x4C4F69, 0x8839EF, false, 0xE2E0EF, None, 0x8839EF),
    ("catppuccin-latte", TwoTone::InkSakura, 0xEFF1F5, 0x4C4F69, 0x8839EF, false, 0xF5E3EA, Some(0xFCF8F6), 0xC24D7C),
    ("catppuccin-latte", TwoTone::CharcoalRose, 0xEFF1F5, 0x4C4F69, 0x8839EF, false, 0xEDEDED, Some(0xFAFAFA), 0xD02670),
    ("catppuccin-latte", TwoTone::InkMagenta, 0xEFF1F5, 0x4C4F69, 0x8839EF, false, 0xD9E2F0, Some(0xF7F9FC), 0xB0245A),
    ("catppuccin-latte", TwoTone::CreamForest, 0xEFF1F5, 0x4C4F69, 0x8839EF, false, 0xEFE8D6, Some(0xFBF8F0), 0x2E6B4E),
    ("catppuccin-latte", TwoTone::NavySand, 0xEFF1F5, 0x4C4F69, 0x8839EF, false, 0xECE1CE, Some(0xFAF7F1), 0x1F3B6E),
    ("catppuccin-latte", TwoTone::BoneOxblood, 0xEFF1F5, 0x4C4F69, 0x8839EF, false, 0xE8E0D2, Some(0xF9F6F0), 0x7D2433),
    ("catppuccin-latte", TwoTone::SlateMatcha, 0xEFF1F5, 0x4C4F69, 0x8839EF, false, 0xE4ECDB, Some(0xFAFBF7), 0x4D6B2C),
    ("catppuccin-latte", TwoTone::PlumAmber, 0xEFF1F5, 0x4C4F69, 0x8839EF, false, 0xEEE4F3, Some(0xFCFAFD), 0x985A10),
];

/// cmux-config's pairing table: value, title, variants.
#[rustfmt::skip]
const PAIRINGS: &[(TwoTone, &str, Variants)] = &[
    (TwoTone::InkSakura, "Ink & Sakura", Variants { dark: Variant { chrome: 0x1E1A24, content: 0x131118, accent: 0xF4A6C0 }, light: Variant { chrome: 0xF5E3EA, content: 0xFCF8F6, accent: 0xC24D7C } }),
    (TwoTone::CharcoalRose, "Charcoal & Rose", Variants { dark: Variant { chrome: 0x161616, content: 0x202020, accent: 0xEE5396 }, light: Variant { chrome: 0xEDEDED, content: 0xFAFAFA, accent: 0xD02670 } }),
    (TwoTone::InkMagenta, "Ink Blue & Magenta", Variants { dark: Variant { chrome: 0x082451, content: 0x0D1526, accent: 0xD32D6B }, light: Variant { chrome: 0xD9E2F0, content: 0xF7F9FC, accent: 0xB0245A } }),
    (TwoTone::CreamForest, "Cream & Forest", Variants { dark: Variant { chrome: 0x1B2E24, content: 0x151A16, accent: 0xE3D6B0 }, light: Variant { chrome: 0xEFE8D6, content: 0xFBF8F0, accent: 0x2E6B4E } }),
    (TwoTone::NavySand, "Navy & Sand", Variants { dark: Variant { chrome: 0x14213D, content: 0x11151D, accent: 0xDDBE91 }, light: Variant { chrome: 0xECE1CE, content: 0xFAF7F1, accent: 0x1F3B6E } }),
    (TwoTone::BoneOxblood, "Bone & Oxblood", Variants { dark: Variant { chrome: 0x2B1518, content: 0x171313, accent: 0xE8DDCB }, light: Variant { chrome: 0xE8E0D2, content: 0xF9F6F0, accent: 0x7D2433 } }),
    (TwoTone::SlateMatcha, "Slate & Matcha", Variants { dark: Variant { chrome: 0x1F2622, content: 0x151917, accent: 0xA9C98A }, light: Variant { chrome: 0xE4ECDB, content: 0xFAFBF7, accent: 0x4D6B2C } }),
    (TwoTone::PlumAmber, "Plum & Amber", Variants { dark: Variant { chrome: 0x261B30, content: 0x17131C, accent: 0xF0B45C }, light: Variant { chrome: 0xEEE4F3, content: 0xFCFAFD, accent: 0x985A10 } }),
];

const VALUES: &[&str] = &[
    "off",
    "auto",
    "inkSakura",
    "charcoalRose",
    "inkMagenta",
    "creamForest",
    "navySand",
    "boneOxblood",
    "slateMatcha",
    "plumAmber",
];

const KINDS: [SurfaceKind; 14] = [
    SurfaceKind::Sidebar,
    SurfaceKind::TabBar,
    SurfaceKind::Terminal,
    SurfaceKind::AgentPane,
    SurfaceKind::Settings,
    SurfaceKind::NewTabPage,
    SurfaceKind::Home,
    SurfaceKind::BrowserChrome,
    SurfaceKind::Docks,
    SurfaceKind::InternalPage,
    SurfaceKind::SplitDivider,
    SurfaceKind::Diff,
    SurfaceKind::Markdown,
    SurfaceKind::Editor,
];

/// Swift `TwoToneTests.near`: every channel within 1.5/255.
fn near(a: Rgb, b: Rgb) -> bool {
    let t = 1.5 / 255.0;
    (a.r - b.r).abs() <= t && (a.g - b.g).abs() <= t && (a.b - b.b).abs() <= t
}

fn op(name: &str, request: serde_json::Value) -> serde_json::Value {
    call(&format!("tokens.{name}"), &request).unwrap_or_else(|e| panic!("{name}: {e:?}"))
}

fn color(hex: u32) -> serde_json::Value {
    let c = Rgb::hex(hex);
    json!({"r": c.r, "g": c.g, "b": c.b})
}

fn from_json(v: &serde_json::Value) -> Rgb {
    let f = |k: &str| v[k].as_f64().unwrap();
    Rgb::new(f("r"), f("g"), f("b"), 1.0)
}

/// Swift `theValuesAreRusts`.
#[test]
fn the_values_are_rusts() {
    let raws: Vec<_> = TwoTone::ALL.iter().map(|v| v.raw_value()).collect();
    assert_eq!(raws, VALUES);
    for v in TwoTone::ALL {
        assert_eq!(TwoTone::from_raw(v.raw_value()), Some(v));
    }
    assert_eq!(TwoTone::from_raw("ink-sakura"), None);
    assert_eq!(op("two_tone_values", json!({})), json!(VALUES));
}

/// Swift `thePairingTableIsRusts`.
#[test]
fn the_pairing_table_is_rusts() {
    assert_eq!(PAIRINGS.len(), 8);
    for (value, title, variants) in PAIRINGS {
        assert_eq!(value.variants(), Some(*variants), "{title}");
        assert!(value.paints_content(), "{title}");
    }
    assert_eq!(TwoTone::Off.variants(), None);
    assert_eq!(TwoTone::Auto.variants(), None);
    assert!(!TwoTone::Off.paints_content());
    assert!(!TwoTone::Auto.paints_content());
    let r = op("two_tone_variants", json!({"value": "charcoalRose"}));
    assert_eq!(r["dark"], json!({"chrome": 0x161616, "content": 0x202020, "accent": 0xEE5396}));
    assert_eq!(op("two_tone_variants", json!({"value": "auto"})), json!(null));
    assert_eq!(op("two_tone_paints_content", json!({"value": "plumAmber"})), json!(true));
}

/// Swift `everyCaseResolvesAsRustDoes`.
#[test]
fn every_case_resolves_as_rust_does() {
    assert_eq!(CASES.len(), 72);
    for &(theme, value, bg, fg, accent, dark, chrome, content, tone_accent) in CASES {
        let label = format!("{theme} {}", value.raw_value());
        let tones = value.tones(Rgb::hex(bg), Rgb::hex(fg), Rgb::hex(accent), dark);
        if value == TwoTone::Off {
            assert_eq!(tones, None, "{label}");
            continue;
        }
        let tones = tones.unwrap_or_else(|| panic!("{label}"));
        assert!(
            near(tones.chrome, Rgb::hex(chrome)),
            "{label} chrome {:06X}",
            tones.chrome.to_hex()
        );
        assert!(
            near(tones.accent, Rgb::hex(tone_accent)),
            "{label} accent {:06X}",
            tones.accent.to_hex()
        );
        match content {
            None => assert_eq!(tones.content, None, "{label}"),
            Some(c) => assert!(near(tones.content.unwrap(), Rgb::hex(c)), "{label} content"),
        }
    }
}

/// Every fixture case also runs through the op, the way PR B's Swift will call it.
#[test]
fn every_case_through_the_op() {
    for &(theme, value, bg, fg, accent, dark, chrome, content, tone_accent) in CASES {
        let r = op(
            "two_tone_tones",
            json!({"value": value, "background": color(bg), "foreground": color(fg), "accent": color(accent), "dark": dark}),
        );
        if value == TwoTone::Off {
            assert_eq!(r, json!(null));
            continue;
        }
        assert!(near(from_json(&r["chrome"]), Rgb::hex(chrome)), "{theme}");
        assert!(near(from_json(&r["accent"]), Rgb::hex(tone_accent)), "{theme}");
        assert_eq!(r["content"].is_null(), content.is_none(), "{theme}");
    }
}

/// cmux-config's charcoalRose pin: a dark theme takes the dark variant exactly.
#[test]
fn charcoal_rose_pin() {
    let t = TwoTone::CharcoalRose
        .tones(Rgb::hex(0x161616), Rgb::hex(0xF2F4F8), Rgb::hex(0xEE5396), true)
        .unwrap();
    assert_eq!(t.chrome.to_hex(), 0x161616);
    assert_eq!(t.content.map(Rgb::to_hex), Some(0x202020));
    assert_eq!(t.accent.to_hex(), 0xEE5396);
    let light =
        TwoTone::CharcoalRose.tones(Rgb::WHITE, Rgb::BLACK, Rgb::hex(0xD02670), false).unwrap();
    assert_eq!(light.chrome.to_hex(), 0xEDEDED);
    assert_eq!(light.content.map(Rgb::to_hex), Some(0xFAFAFA));
}

/// The rules the tones keep: the accent marks both tones, and auto's chrome steps off the
/// background.
#[test]
fn accents_stand_out_on_both_tones() {
    for &(theme, value, bg, fg, accent, dark, ..) in CASES {
        let Some(t) = value.tones(Rgb::hex(bg), Rgb::hex(fg), Rgb::hex(accent), dark) else {
            continue;
        };
        let content = t.content.unwrap_or(Rgb::hex(bg));
        // The 1.5/255 rounding the fixture allows can cost a hair of ratio.
        assert!(t.accent.contrast(t.chrome) >= MARK_MINIMUM - 0.05, "{theme} {value:?} on chrome");
        assert!(t.accent.contrast(content) >= MARK_MINIMUM - 0.05, "{theme} {value:?} on content");
        if value == TwoTone::Auto {
            assert_ne!(t.chrome.to_hex(), bg, "{theme}");
        }
    }
}

#[test]
fn tones_are_deterministic() {
    for &(_, value, bg, fg, accent, dark, ..) in CASES {
        let a = value.tones(Rgb::hex(bg), Rgb::hex(fg), Rgb::hex(accent), dark);
        let b = value.tones(Rgb::hex(bg), Rgb::hex(fg), Rgb::hex(accent), dark);
        assert_eq!(a, b);
    }
}

/// Swift `offPaintsNothing` (the `color(for:)` half; `SurfaceBackgrounds` is view-side).
#[test]
fn off_paints_nothing() {
    for kind in KINDS {
        assert_eq!(
            TwoTone::Off.color_for(kind, Rgb::hex(0x282C34), Rgb::WHITE, Rgb::hex(0xC678DD), true),
            None
        );
    }
}

/// Swift `surfacesTakeTheirTonesAndAnExplicitColorWins` (the `color(for:)` half).
#[test]
fn surfaces_take_their_tones() {
    let (bg, fg, accent) = (Rgb::hex(0x282C34), Rgb::WHITE, Rgb::hex(0xC678DD));
    let at = |v: TwoTone, k| v.color_for(k, bg, fg, accent, true);
    let sidebar = at(TwoTone::InkSakura, SurfaceKind::Sidebar).unwrap();
    let tab_bar = at(TwoTone::InkSakura, SurfaceKind::TabBar).unwrap();
    let terminal = at(TwoTone::InkSakura, SurfaceKind::Terminal).unwrap();
    assert_eq!(sidebar, tab_bar);
    assert_ne!(sidebar, terminal);
    assert_eq!(sidebar.to_hex(), 0x1E1A24);
    assert_eq!(terminal.to_hex(), 0x131118);
    for k in [SurfaceKind::AgentPane, SurfaceKind::NewTabPage, SurfaceKind::Home] {
        assert_eq!(at(TwoTone::InkSakura, k), Some(terminal), "{k:?}");
    }
    for k in [
        SurfaceKind::Settings,
        SurfaceKind::BrowserChrome,
        SurfaceKind::Docks,
        SurfaceKind::InternalPage,
        SurfaceKind::SplitDivider,
        SurfaceKind::Diff,
        SurfaceKind::Markdown,
        SurfaceKind::Editor,
    ] {
        assert_eq!(at(TwoTone::InkSakura, k), None, "{k:?}");
    }
    assert_eq!(at(TwoTone::Auto, SurfaceKind::Terminal), None);
    assert!(at(TwoTone::Auto, SurfaceKind::Sidebar).is_some());
    // Each colour is made opaque first.
    assert_eq!(
        TwoTone::Auto.color_for(SurfaceKind::Sidebar, bg.with_alpha(0.4), fg, accent, true),
        at(TwoTone::Auto, SurfaceKind::Sidebar)
    );
    let r = op(
        "two_tone_color",
        json!({"value": "inkSakura", "kind": "tabBar", "surfaceBackground": color(0x282C34), "textPrimary": color(0xFFFFFF), "accent": color(0xC678DD), "isDark": true}),
    );
    assert_eq!(from_json(&r).to_hex(), 0x1E1A24);
    let r = op(
        "two_tone_color",
        json!({"value": "auto", "kind": "terminal", "surfaceBackground": color(0x282C34), "textPrimary": color(0xFFFFFF), "accent": color(0xC678DD), "isDark": true}),
    );
    assert_eq!(r, json!(null));
}

#[test]
fn constants_match_swift() {
    let r = op("two_tone_constants", json!({}));
    assert_eq!(r["textMinimum"], 4.5);
    assert_eq!(r["markMinimum"], 3.0);
    assert_eq!(r["autoLightnessStep"], 0.045);
    assert_eq!(r["autoDarkFloor"], 0.18);
    assert_eq!(r["autoAccentShare"], 0.12);
    assert_eq!(r["autoHuedChroma"], 0.04);
    assert_eq!(r["autoMaxChroma"], 0.02);
    assert_eq!(r["autoLeastStep"], 0.02);
}

#[test]
fn bad_requests_and_unknown_ops() {
    assert!(matches!(
        call("tokens.two_tone_variants", &json!({"value": "nope"})),
        Err(OpError::Invalid(_))
    ));
    assert!(matches!(
        cmux_design_core::tokens::two_tone::call("two_tone_nope", &json!({})),
        Err(OpError::Unknown)
    ));
}
