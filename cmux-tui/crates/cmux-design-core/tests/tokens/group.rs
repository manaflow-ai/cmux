//! Parity tests for `tokens::group`: the Swift suites GroupGradientTests,
//! GroupPictorialPaletteTests, NewProfileColorTests, GroupPaletteTests and
//! GroupBackgroundEveryThemeTests ported value for value, plus pins worked by hand from the
//! Swift formulas and one JSON op per function.

use cmux_design_core::ops::{OpError, call};
use cmux_design_core::tokens::color::{Color, Rgb};
use cmux_design_core::tokens::group::{
    ChipInks, ColorRole, GLASS_OPACITY, GlassPaintInput, GroupBackground, GroupColor,
    GroupGradient, GroupPalette, GroupTheme, GroupTint, MINIMUM_MARK_CONTRAST,
    MINIMUM_TEXT_CONTRAST, MINIMUM_VISIBLE_CONTRAST, NEUTRAL_OPACITY, OkLabPoint, PALETTE_ORDER,
    SidebarGroupBackgroundStyle, SidebarGroupGlass, Strength, Wallpaper, automatic,
    automatic_after, chip, chip_draws_glass, chip_glass_paint, glass_fill, glass_paint, glass_rgb,
    glyph_ink, grayscale_rgb, header_rgb, hsb_rgb, hue_saturation, marble, over, palette_rgb,
    perceptual_distance, pictorial_rgb, swatch_rgb, theme_rgb, visible, wallpaper_rgb,
};
use cmux_theme_tokens::{
    GHOSTTY_DEFAULT_PALETTE, Oklch, ThemeInput, ThemeTokens, from_oklch, oklch, readable,
};
use serde_json::{Value, json};

const EPS: f64 = 1e-9;

fn close(a: Rgb, b: Rgb) -> bool {
    (a.r - b.r).abs() < EPS
        && (a.g - b.g).abs() < EPS
        && (a.b - b.b).abs() < EPS
        && (a.a - b.a).abs() < EPS
}

fn op(name: &str, request: Value) -> Value {
    call(&format!("tokens.{name}"), &request).unwrap_or_else(|e| panic!("{name}: {e:?}"))
}

fn rgb_of(v: &Value) -> Rgb {
    let c: Color = serde_json::from_value(v.clone()).expect("a color");
    c.into()
}

fn theme_json(t: &GroupTheme) -> Value {
    serde_json::to_value(t).expect("theme json")
}

/// A theme from `background`, `foreground` and an 8-entry palette, as Swift's
/// `ThemeInput(background:foreground:palette:)` gives `tokens.ansi` exactly those 8.
fn theme8(background: u32, foreground: u32, palette8: [u32; 8], opacity: f64) -> GroupTheme {
    let mut palette = GHOSTTY_DEFAULT_PALETTE;
    for (i, hex) in palette8.iter().enumerate() {
        palette[i] = Rgb::hex(*hex);
    }
    let input = ThemeInput {
        background: Rgb::hex(background),
        foreground: Rgb::hex(foreground),
        palette,
        background_opacity: opacity,
        ..ThemeInput::default()
    };
    let mut theme = GroupTheme::from(&ThemeTokens::derive(&input));
    theme.ansi.truncate(8);
    theme
}

/// GroupPaletteTests.tokens(dark:) (Catppuccin Mocha / Latte).
fn palette_theme(dark: bool) -> GroupTheme {
    if dark {
        theme8(
            0x1E1E2E,
            0xCDD6F4,
            [0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xBAC2DE],
            1.0,
        )
    } else {
        theme8(
            0xEFF1F5,
            0x4C4F69,
            [0x5C5F77, 0xD20F39, 0x40A02B, 0xDF8E1D, 0x1E66F5, 0xEA76CB, 0x179299, 0xACB0BE],
            1.0,
        )
    }
}

/// The app's default theme (Swift `ThemeScope.app.tokens` with no config: Ghostty's default).
fn app_theme() -> GroupTheme {
    GroupTheme::from(&ThemeTokens::derive(&ThemeInput::default()))
}

fn hue_degrees(c: Rgb) -> f64 {
    hue_saturation(c.r, c.g, c.b).0 * 360.0
}

fn hue_distance(a: f64, b: f64) -> f64 {
    let d = (a - b).abs() % 360.0;
    d.min(360.0 - d)
}

// MARK: GroupPalette, GroupGradient, SidebarGroupBackgroundStyle, SidebarGroupGlass

#[test]
fn palette_traits() {
    use GroupPalette::*;
    assert!(!Glass.colors_new_groups());
    for p in GroupPalette::ALL {
        assert_eq!(p.colors_new_groups(), p != Glass, "{p:?}");
        assert_eq!(p.follows_wallpaper(), p == Wallpaper || p == Pictorial, "{p:?}");
        assert_eq!(p.drawn(), if p == Glass { Vibrant } else { p });
    }
    let r = op("group_palette_traits", json!({"palette": "glass"}));
    assert_eq!(r, json!({"colorsNewGroups": false, "followsWallpaper": false, "drawn": "vibrant"}));
    let r = op("group_palette_traits", json!({"palette": "pictorial"}));
    assert_eq!(r["followsWallpaper"], json!(true));
}

#[test]
fn gradient_stops_and_wire_names() {
    let s = GroupGradient::Sunset.stops();
    assert_eq!((s[0].lightness, s[0].chroma, s[0].hue), (0.70, 0.19, 350.0));
    assert_eq!((s[2].lightness, s[2].chroma, s[2].hue), (0.84, 0.16, 85.0));
    assert_eq!(GroupGradient::TwoTone.stops().len(), 2);
    assert_eq!(GroupGradient::default(), GroupGradient::Sunset);
    let r = op("group_gradient_stops", json!({"gradient": "twoTone"}));
    assert_eq!(
        r,
        json!([{"lightness":0.70,"chroma":0.18,"hue":300.0},{"lightness":0.76,"chroma":0.17,"hue":50.0}])
    );
}

// GroupGradientTests.theEndsAreTheStops
#[test]
fn the_ends_are_the_stops() {
    for g in GroupGradient::ALL {
        let stops = g.stops();
        for (place, stop) in [(0.0, stops[0]), (1.0, stops[stops.len() - 1])] {
            let lch = oklch(g.rgb_at(place));
            assert!((lch.l - stop.lightness).abs() < 0.01, "{g:?} at {place}: {}", lch.l);
            let dh = (lch.h - stop.hue).abs();
            assert!(!(3.0..=357.0).contains(&dh), "{g:?} at {place}: hue {}", lch.h);
        }
    }
}

// GroupGradientTests.everyStepKeepsItsChroma
#[test]
fn every_step_keeps_its_chroma() {
    for g in GroupGradient::ALL {
        let weakest = g.stops().iter().map(|s| s.chroma).fold(f64::INFINITY, f64::min);
        for step in 0..=40 {
            let chroma = oklch(g.rgb_at(step as f64 / 40.0)).c;
            assert!(chroma >= 0.75 * weakest, "{g:?} step {step}: {chroma}");
        }
    }
}

// GroupGradientTests.twoToneMixesThroughPinkNotGrey
#[test]
fn two_tone_mixes_through_pink_not_grey() {
    let g = GroupGradient::TwoTone;
    let middle = g.rgb_at(0.5);
    let (a, b) = (g.rgb_at(0.0), g.rgb_at(1.0));
    let srgb = Rgb::new((a.r + b.r) / 2.0, (a.g + b.g) / 2.0, (a.b + b.b) / 2.0, 1.0);
    assert!(oklch(middle).c > 1.5 * oklch(srgb).c);
    let hue = oklch(middle).h;
    assert!(!(20.0..=330.0).contains(&hue), "hue {hue}");
}

// GroupGradientTests.placesSpreadOverTheWholeGradient
#[test]
fn places_spread_over_the_whole_gradient() {
    assert_eq!(GroupGradient::place(0, 1), 0.0);
    let places: Vec<f64> = (0..5).map(|i| GroupGradient::place(i, 5)).collect();
    assert_eq!(places, vec![0.0, 0.25, 0.5, 0.75, 1.0]);
    assert_eq!(op("group_gradient_place", json!({"index": 3, "count": 5})), json!(0.75));
    assert_eq!(op("group_gradient_place", json!({"index": 3, "count": 0})), json!(0.0));
}

#[test]
fn gradient_rgb_pins() {
    // One stop past either end clamps; place 0 is the first stop through from_oklch.
    let sunset = GroupGradient::Sunset;
    assert_eq!(sunset.rgb_at(0.0), from_oklch(Oklch { l: 0.70, c: 0.19, h: 350.0 }));
    assert_eq!(sunset.rgb_at(-3.0), sunset.rgb_at(0.0));
    assert_eq!(sunset.rgb_at(1.0), from_oklch(Oklch { l: 0.84, c: 0.16, h: 85.0 }));
    assert_eq!(sunset.rgb_at(9.0), sunset.rgb_at(1.0));
    // 0.25 of sunset: scaled 0.5, index 0, t 0.5; turn = (40 - 350 + 540) % 360 - 180 = 50;
    // hue (350 + 25 + 360) % 360 = 15.
    let want = from_oklch(Oklch {
        l: 0.70 + (0.72 - 0.70) * 0.5,
        c: 0.19 + (0.18 - 0.19) * 0.5,
        h: (350.0 + 50.0 * 0.5 + 360.0) % 360.0,
    });
    assert_eq!(sunset.rgb_at(0.25), want);
    // 1.0 of aurora uses the last segment at t = 1 (index capped at count - 2).
    let lagoon_end = GroupGradient::Lagoon.rgb_at(1.0);
    let turn = (165.0f64 - 205.0 + 540.0) % 360.0 - 180.0;
    assert_eq!(turn, -40.0);
    assert_eq!(
        lagoon_end,
        from_oklch(Oklch {
            l: 0.76 + (0.80 - 0.76) * 1.0,
            c: 0.13 + (0.15 - 0.13) * 1.0,
            h: (205.0 + turn + 360.0) % 360.0,
        })
    );
    let r = op("group_gradient_rgb", json!({"gradient": "sunset", "place": 0.25}));
    assert_eq!(rgb_of(&r), want);
}

#[test]
fn background_style_traits() {
    use SidebarGroupBackgroundStyle::*;
    // GroupBackgroundEveryThemeTests.automaticFollowsTheAppsGroupLook
    assert!(Auto.draws_glass(true));
    assert!(!Auto.draws_glass(false));
    assert!(Glass.draws_glass(false));
    assert!(!Solid.draws_glass(true));
    for s in SidebarGroupBackgroundStyle::ALL {
        assert_eq!(s.draws_background(), matches!(s, Auto | Glass | Solid), "{s:?}");
        assert_eq!(s.draws_members_mark(), !matches!(s, Sections | Folder), "{s:?}");
        assert_eq!(s.indents_members(), matches!(s, Folder | Tree), "{s:?}");
        assert_eq!(s.leads_with_folder(), matches!(s, Folder | Tree), "{s:?}");
        assert_eq!(s.draws_card(), s == Card, "{s:?}");
        assert_eq!(s.draws_on_tab_strip(), !matches!(s, Folder | Chip | Tree | Card), "{s:?}");
    }
    let r = op("group_background_style_traits", json!({"style": "card", "appLooksGlassy": true}));
    assert_eq!(
        r,
        json!({"drawsGlass": false, "drawsBackground": false, "drawsMembersMark": true,
               "indentsMembers": false, "leadsWithFolder": false, "drawsCard": true,
               "drawsOnTabStrip": false})
    );
}

#[test]
fn sidebar_group_glass() {
    use SidebarGroupGlass::*;
    assert_eq!(SidebarGroupGlass::DEFAULT, Vivid);
    assert_eq!((Glass.tint(true), Glass.tint(false)), (0.30, 0.22));
    assert_eq!((Vivid.tint(true), Vivid.tint(false)), (0.44, 0.34));
    assert_eq!((Frost.tint(true), Frost.tint(false)), (0.16, 0.12));
    assert_eq!((Solid.tint(true), Solid.tint(false)), (1.0, 1.0));
    let titles: Vec<&str> = SidebarGroupGlass::ALL.iter().map(|g| g.title()).collect();
    assert_eq!(titles, ["Tinted glass", "Vivid glass", "Frosted glass", "Solid bar"]);
    let r = op("group_glass_tint", json!({"glass": "frost", "dark": true}));
    assert_eq!(r, json!({"tint": 0.16, "title": "Frosted glass"}));
}

// MARK: GroupColor

#[test]
fn color_rgb_pins() {
    assert_eq!(GroupColor::Red.rgb(ColorRole::Swatch, true), Rgb::hex(0xFD7273));
    assert_eq!(GroupColor::Red.rgb(ColorRole::Swatch, false), Rgb::hex(0xE36364));
    // Dark fill: the swatch 55% toward 1C1C1E; light fill: 70% toward white.
    let s = Rgb::hex(0xFD7273);
    let want = Rgb::new(
        s.r + (28.0 / 255.0 - s.r) * 0.55,
        s.g + (28.0 / 255.0 - s.g) * 0.55,
        s.b + (30.0 / 255.0 - s.b) * 0.55,
        1.0,
    );
    assert!(close(GroupColor::Red.rgb(ColorRole::Fill, true), want));
    let l = Rgb::hex(0x4693F1);
    let want =
        Rgb::new(l.r + (1.0 - l.r) * 0.7, l.g + (1.0 - l.g) * 0.7, l.b + (1.0 - l.b) * 0.7, 1.0);
    assert!(close(GroupColor::Blue.rgb(ColorRole::Fill, false), want));
    let theme = palette_theme(true);
    assert_eq!(swatch_rgb(GroupColor::Pink, &theme), Rgb::hex(0xF46CBF));
    assert_eq!(header_rgb(GroupColor::Pink, &theme), GroupColor::Pink.rgb(ColorRole::Fill, true));
    let r = op("group_color_rgb", json!({"color": "purple", "role": "swatch", "dark": false}));
    assert_eq!(rgb_of(&r), Rgb::hex(0x9F79E6));
    assert_eq!(GroupColor::from_raw("teal"), None);
    assert_eq!(GroupColor::from_raw("grey"), Some(GroupColor::Grey));
}

// GroupPaletteTests.glassColorsNoNewGroupAndDrawsVibrant
#[test]
fn glass_draws_vibrant() {
    let theme = palette_theme(true);
    for c in GroupColor::ALL {
        let g = palette_rgb(c, GroupPalette::Glass, &theme, None, GroupGradient::Sunset);
        assert_eq!(g, palette_rgb(c, GroupPalette::Vibrant, &theme, None, GroupGradient::Sunset));
        // Vibrant returns the swatch with no readable step.
        assert_eq!(g, swatch_rgb(c, &theme));
    }
}

// GroupPaletteTests.newGroupsTakeTheLeastUsedColorInAnOrderThatKeepsNeighborsApart
#[test]
fn automatic_runs_in_palette_order() {
    let mut existing: Vec<GroupTint> = Vec::new();
    for _ in 0..PALETTE_ORDER.len() {
        existing.push(GroupTint::Palette(automatic(&existing)));
    }
    let want: Vec<GroupTint> = PALETTE_ORDER.iter().map(|c| GroupTint::Palette(*c)).collect();
    assert_eq!(existing, want);
    assert!(
        !PALETTE_ORDER.contains(&GroupColor::Blue) && !PALETTE_ORDER.contains(&GroupColor::Grey)
    );
    let custom = GroupTint::Custom(Rgb::hex(0x336699).into());
    assert_eq!(
        automatic(&[GroupTint::Palette(GroupColor::Purple), custom, GroupTint::None]),
        GroupColor::Orange
    );
    let mut full = want;
    full.push(GroupTint::Palette(GroupColor::Purple));
    assert_eq!(automatic(&full), GroupColor::Orange);
    let theme = palette_theme(true);
    for pair in PALETTE_ORDER.windows(2) {
        let d = hue_distance(
            hue_degrees(swatch_rgb(pair[0], &theme)),
            hue_degrees(swatch_rgb(pair[1], &theme)),
        );
        assert!(d >= 60.0, "{:?} then {:?}: {d}", pair[0], pair[1]);
    }
    let r = op(
        "group_automatic",
        json!({"existing": [{"palette": "purple"}, {"custom": {"r": 0.2, "g": 0.4, "b": 0.6}}, "none"]}),
    );
    assert_eq!(r, json!("orange"));
    assert_eq!(
        op("group_palette_order", json!({})),
        json!(["purple", "orange", "cyan", "red", "green", "pink", "yellow"])
    );
}

// GroupPaletteTests.vibrantIsBrightAndSaturated
#[test]
fn vibrant_is_bright_and_saturated() {
    for dark in [true, false] {
        let theme = palette_theme(dark);
        for c in GroupColor::ALL.into_iter().filter(|c| *c != GroupColor::Grey) {
            let s = swatch_rgb(c, &theme);
            let (_, saturation) = hue_saturation(s.r, s.g, s.b);
            let brightness = s.r.max(s.g).max(s.b);
            assert!(saturation >= 0.45, "{c:?}: {saturation}");
            assert!(brightness >= if dark { 0.75 } else { 0.65 }, "{c:?}: {brightness}");
        }
    }
}

// GroupPaletteTests.grayscaleHasNoHueAndEachNeighborDiffersInLightness
#[test]
fn grayscale_has_no_hue_and_neighbors_differ() {
    for dark in [true, false] {
        let theme = palette_theme(dark);
        let greys: Vec<Rgb> = PALETTE_ORDER
            .iter()
            .map(|c| palette_rgb(*c, GroupPalette::Grayscale, &theme, None, GroupGradient::Sunset))
            .collect();
        for g in &greys {
            let spread = g.r.max(g.g).max(g.b) - g.r.min(g.g).min(g.b);
            assert!(spread <= 0.08, "{g:?}");
        }
        for pair in greys.windows(2) {
            assert!(pair[0].contrast(pair[1]) >= 1.25, "{pair:?}");
        }
    }
    assert_eq!(grayscale_rgb(GroupColor::Purple, true), Rgb::hex(0xE6E4E0));
    assert_eq!(grayscale_rgb(GroupColor::Blue, false), Rgb::hex(0x627273));
    let r = op("group_grayscale_rgb", json!({"color": "pink", "dark": true}));
    assert_eq!(rgb_of(&r), Rgb::hex(0x857A82));
}

// GroupPaletteTests.theThemePaletteIsTheThemesTerminalColors
#[test]
fn theme_palette_is_the_terminal_colors() {
    let theme = palette_theme(true);
    for c in PALETTE_ORDER {
        let want = theme_rgb(c, &theme).expect("8 colors");
        assert_eq!(palette_rgb(c, GroupPalette::Theme, &theme, None, GroupGradient::Sunset), want);
    }
    // Pins by the formula: red is p[1]; with 8 colors pink is p[5] 35% toward p[1]; orange is
    // p[1] halfway to p[3]; each readable as a mark over the sidebar.
    let sidebar = theme.sidebar();
    let p = |i: usize| Rgb::from(theme.ansi[i]);
    assert_eq!(theme_rgb(GroupColor::Red, &theme), Some(readable(p(1), sidebar, 3.0)));
    assert_eq!(
        theme_rgb(GroupColor::Pink, &theme),
        Some(readable(p(5).mixed(p(1), 0.35), sidebar, 3.0))
    );
    assert_eq!(
        theme_rgb(GroupColor::Orange, &theme),
        Some(readable(p(1).mixed(p(3), 0.5), sidebar, 3.0))
    );
    assert_eq!(theme_rgb(GroupColor::Grey, &theme), None);
    // 16 colors: pink is bright magenta, p[13].
    let full = app_theme();
    assert_eq!(full.ansi.len(), 16);
    assert_eq!(
        theme_rgb(GroupColor::Pink, &full),
        Some(readable(Rgb::from(full.ansi[13]), full.sidebar(), 3.0))
    );
    // Under 8: none, so the palette falls back to the swatch.
    let mut short = theme.clone();
    short.ansi.truncate(7);
    assert_eq!(theme_rgb(GroupColor::Red, &short), None);
    assert_eq!(
        palette_rgb(GroupColor::Red, GroupPalette::Theme, &short, None, GroupGradient::Sunset),
        readable(Rgb::hex(0xFD7273), short.sidebar(), MINIMUM_MARK_CONTRAST)
    );
    let r = op("group_theme_rgb", json!({"color": "red", "theme": theme_json(&theme)}));
    assert_eq!(rgb_of(&r), readable(p(1), sidebar, 3.0));
    let r = op("group_theme_rgb", json!({"color": "grey", "theme": theme_json(&theme)}));
    assert_eq!(r, Value::Null);
}

// GroupPaletteTests.theWallpaperPaletteFollowsThePicturesHue
#[test]
fn wallpaper_palette_follows_the_picture() {
    let theme = palette_theme(true);
    let orange = Wallpaper::new(0.71, 0.39, 0.24);
    let teal = Wallpaper::new(0.1, 0.5, 0.55);
    let pal = |w: Option<&Wallpaper>, c: GroupColor, p: GroupPalette| {
        palette_rgb(c, p, &theme, w, GroupGradient::Sunset)
    };
    let from_orange = hue_degrees(pal(Some(&orange), GroupColor::Orange, GroupPalette::Wallpaper));
    let from_teal = hue_degrees(pal(Some(&teal), GroupColor::Orange, GroupPalette::Wallpaper));
    assert!(hue_distance(from_orange, hue_degrees(Rgb::new(0.71, 0.39, 0.24, 1.0))) <= 20.0);
    assert!(hue_distance(from_orange, from_teal) >= 90.0);
    let grey = Wallpaper::new(0.5, 0.5, 0.5);
    assert_eq!(
        pal(Some(&grey), GroupColor::Red, GroupPalette::Wallpaper),
        pal(None, GroupColor::Red, GroupPalette::Grayscale)
    );
    assert_eq!(
        pal(None, GroupColor::Red, GroupPalette::Wallpaper),
        pal(None, GroupColor::Red, GroupPalette::Vibrant)
    );
}

#[test]
fn wallpaper_rgb_pins() {
    // HSB of (0.71, 0.39, 0.24): max red, delta 0.47.
    let (h, s) = hue_saturation(0.71, 0.39, 0.24);
    assert!((h - (0.39 - 0.24) / 0.47 / 6.0).abs() < EPS);
    assert!((s - 0.47 / 0.71).abs() < EPS);
    // Pure red picture, orange, dark: hue (0 - 10 + 360) % 360 / 360, saturation 0.5,
    // brightness 0.95; sector 5 gives (v, p, q).
    let got = wallpaper_rgb(GroupColor::Orange, &Wallpaper::new(1.0, 0.0, 0.0), true);
    let f = 350.0 / 60.0 - 5.0;
    let want = Rgb::new(0.95, 0.95 * (1.0 - 0.5), 0.95 * (1.0 - 0.5 * f), 1.0);
    assert!(close(got, want), "{got:?}");
    // Green picture (hue 1/3), cyan light: hue (120 + 160) / 360, s 0.62, v 0.78; sector 4 → (t, p, v).
    let got = wallpaper_rgb(GroupColor::Cyan, &Wallpaper::new(0.0, 1.0, 0.0), false);
    let f = 280.0 / 60.0 - 4.0;
    let want = Rgb::new(0.78 * (1.0 - 0.62 * (1.0 - f)), 0.78 * (1.0 - 0.62), 0.78, 1.0);
    assert!(close(got, want), "{got:?}");
    // Grey: saturation 0.08 at the picture's hue.
    let got = wallpaper_rgb(GroupColor::Grey, &Wallpaper::new(0.0, 0.0, 1.0), true);
    assert!(close(got, hsb_rgb(240.0 / 360.0, 0.08, 0.95)));
    // Saturation under 0.08 is grey: grayscale.
    let w = Wallpaper::new(0.5, 0.5, 0.52);
    assert_eq!(wallpaper_rgb(GroupColor::Red, &w, true), grayscale_rgb(GroupColor::Red, true));
    // Out-of-range input is clamped as Swift's WallpaperTint init does.
    let wild = Wallpaper { red: 4.0, green: -1.0, blue: 0.0, bands: vec![] };
    assert_eq!(
        wallpaper_rgb(GroupColor::Orange, &wild, true),
        wallpaper_rgb(GroupColor::Orange, &Wallpaper::new(1.0, 0.0, 0.0), true)
    );
    let r = op(
        "group_wallpaper_rgb",
        json!({"color": "orange", "wallpaper": {"red": 1.0, "green": 0.0, "blue": 0.0}, "dark": true}),
    );
    let f = 350.0 / 60.0 - 5.0;
    assert!(close(rgb_of(&r), Rgb::new(0.95, 0.475, 0.95 * (1.0 - 0.5 * f), 1.0)));
}

// GroupPaletteTests.eachPalettesMarbleHasItsOwnColors
#[test]
fn each_palettes_marble_has_its_own_colors() {
    let theme = palette_theme(true);
    let w = Wallpaper::new(0.2, 0.35, 0.6);
    let marbles: Vec<Vec<u32>> = [
        GroupPalette::Theme,
        GroupPalette::Wallpaper,
        GroupPalette::Grayscale,
        GroupPalette::Vibrant,
    ]
    .iter()
    .map(|p| {
        marble(*p, &theme, Some(&w), GroupGradient::Sunset).iter().map(|c| c.to_hex()).collect()
    })
    .collect();
    assert!(marbles.iter().all(|m| m.len() == 8));
    for i in 0..marbles.len() {
        for j in (i + 1)..marbles.len() {
            assert_ne!(marbles[i], marbles[j]);
        }
    }
    // Vibrant's marble is the order plus blue, as swatches.
    let vibrant = marble(GroupPalette::Vibrant, &theme, None, GroupGradient::Sunset);
    let want: Vec<Rgb> = PALETTE_ORDER
        .iter()
        .chain([GroupColor::Blue].iter())
        .map(|c| swatch_rgb(*c, &theme))
        .collect();
    assert_eq!(vibrant, want);
    let r = op("group_marble", json!({"palette": "vibrant", "theme": theme_json(&theme)}));
    let got: Vec<Rgb> = r.as_array().expect("array").iter().map(rgb_of).collect();
    assert_eq!(got, want);
}

// GroupGradientTests.tokensAndTheMarbleFollowTheGradient
#[test]
fn tokens_and_the_marble_follow_the_gradient() {
    let theme = app_theme();
    let first =
        palette_rgb(PALETTE_ORDER[0], GroupPalette::Gradient, &theme, None, GroupGradient::Aurora);
    let want = readable(GroupGradient::Aurora.rgb_at(0.0), theme.sidebar(), MINIMUM_MARK_CONTRAST);
    assert_eq!(first, want);
    let m = marble(GroupPalette::Gradient, &theme, None, GroupGradient::Sunset);
    assert_eq!(m.len(), 8);
    for i in 0..8 {
        for j in (i + 1)..8 {
            assert_ne!(m[i], m[j], "step {i} and {j}");
        }
    }
    // Grey sits last of nine on the gradient (order + blue + grey), blue eighth.
    let grey =
        palette_rgb(GroupColor::Grey, GroupPalette::Gradient, &theme, None, GroupGradient::Sunset);
    let want = readable(GroupGradient::Sunset.rgb_at(1.0), theme.sidebar(), MINIMUM_MARK_CONTRAST);
    assert_eq!(grey, want);
    let blue =
        palette_rgb(GroupColor::Blue, GroupPalette::Gradient, &theme, None, GroupGradient::Sunset);
    let want =
        readable(GroupGradient::Sunset.rgb_at(7.0 / 8.0), theme.sidebar(), MINIMUM_MARK_CONTRAST);
    assert_eq!(blue, want);
    let r = op(
        "group_palette_rgb",
        json!({"color": "purple", "palette": "gradient", "gradient": "aurora", "theme": theme_json(&theme)}),
    );
    assert_eq!(rgb_of(&r), first);
}

// GroupPictorialPaletteTests.aGroupTakesItsBandsHue
#[test]
fn a_group_takes_its_bands_hue() {
    let bands = [Wallpaper::new(0.5, 0.08, 0.06), Wallpaper::new(0.3, 0.3, 0.3)];
    let top = oklch(pictorial_rgb(&bands, 0.0));
    let band = oklch(Rgb::new(0.5, 0.08, 0.06, 1.0));
    assert!((top.h - band.h).abs() < 4.0, "{} vs {}", top.h, band.h);
    assert!((top.l - 0.72).abs() < 0.02, "{}", top.l);
    assert!(oklch(pictorial_rgb(&bands, 1.0)).c < 0.02);
    // Pins: the band's chroma times 1.4, held to 0.08...0.18, at lightness 0.72.
    let want = from_oklch(Oklch { l: 0.72, c: (band.c * 1.4).clamp(0.08, 0.18), h: band.h });
    assert_eq!(pictorial_rgb(&bands, 0.0), want);
    // floor(0.5 * 2) = 1: the second band; place clamps.
    assert_eq!(pictorial_rgb(&bands, 0.5), pictorial_rgb(&bands, 1.0));
    assert_eq!(pictorial_rgb(&bands, 7.0), pictorial_rgb(&bands, 1.0));
    assert_eq!(pictorial_rgb(&[], 0.3), Rgb::WHITE);
    let r = op(
        "group_pictorial_rgb",
        json!({"bands": [{"red": 0.5, "green": 0.08, "blue": 0.06}, {"red": 0.3, "green": 0.3, "blue": 0.3}], "place": 0.0}),
    );
    assert_eq!(rgb_of(&r), want);
}

// GroupPictorialPaletteTests.theMarbleAndALoneTokenFollowThePicture
#[test]
fn the_marble_and_a_lone_token_follow_the_picture() {
    let theme = app_theme();
    let mut w = Wallpaper::new(0.2, 0.35, 0.6);
    w.bands =
        (0..16).map(|i| Wallpaper::new(i as f64 / 15.0, 0.3, 1.0 - i as f64 / 15.0)).collect();
    let m = marble(GroupPalette::Pictorial, &theme, Some(&w), GroupGradient::Sunset);
    assert_eq!(m.len(), 8);
    // Step 3 of 8: place 3/7, band floor(3/7 * 16) = 6.
    let want = readable(pictorial_rgb(&w.bands, 3.0 / 7.0), theme.sidebar(), MINIMUM_MARK_CONTRAST);
    assert_eq!(m[3], want);
    assert_eq!(
        palette_rgb(
            GroupColor::Red,
            GroupPalette::Pictorial,
            &theme,
            Some(&w),
            GroupGradient::Sunset
        ),
        palette_rgb(
            GroupColor::Red,
            GroupPalette::Wallpaper,
            &theme,
            Some(&w),
            GroupGradient::Sunset
        )
    );
}

// MARK: NewProfileColorTests

fn made(count: usize, after: &[&str]) -> Vec<GroupColor> {
    let mut colors: Vec<String> = after.iter().map(|s| s.to_string()).collect();
    let mut out = Vec::new();
    for _ in 0..count {
        let next = automatic_after(&colors);
        out.push(next);
        colors.push(next.raw().to_string());
    }
    out
}

fn closest(colors: &[GroupColor]) -> f64 {
    let mut least = f64::INFINITY;
    for (i, a) in colors.iter().enumerate() {
        for b in &colors[i + 1..] {
            least = least.min(perceptual_distance(*a, *b));
        }
    }
    least
}

#[test]
fn profiles_made_in_a_row_stay_far_apart() {
    for (count, threshold) in [(2, 0.30), (3, 0.20), (4, 0.18), (5, 0.12)] {
        let colors = made(count, &[]);
        assert!(closest(&colors) >= threshold, "{colors:?}: {}", closest(&colors));
    }
}

#[test]
fn the_next_profile_is_far_from_a_recolored_one() {
    use GroupColor::*;
    for picked in [Orange, Red, Pink, Purple, Green, Cyan, Yellow] {
        let next = automatic_after(&[picked.raw().to_string()]);
        assert!(perceptual_distance(next, picked) >= 0.25, "after {picked:?}: {next:?}");
    }
}

#[test]
fn every_profile_gets_a_color_never_blue_or_grey() {
    let colors = made(15, &[]);
    assert!(colors.iter().all(|c| *c != GroupColor::Blue && *c != GroupColor::Grey));
    let mut first7 = colors[..7].to_vec();
    first7.sort_by_key(|c| c.raw());
    first7.dedup();
    assert_eq!(first7.len(), 7);
    for pair in colors.windows(2) {
        assert!(perceptual_distance(pair[0], pair[1]) >= 0.07, "{pair:?}");
    }
    assert_eq!(made(15, &[]), colors);
}

#[test]
fn unknown_and_missing_colors_count_for_none() {
    let none: Vec<String> = Vec::new();
    assert_eq!(automatic_after(&["".into(), "teal".into()]), automatic_after(&none));
    // Nothing used: no reference, so the first open color.
    assert_eq!(automatic_after(&none), GroupColor::Purple);
    let r = op("group_automatic_after", json!({"existing": ["", "teal"]}));
    assert_eq!(r, json!("purple"));
}

#[test]
fn perceptual_distance_pins() {
    // The OKLab distance of the dark swatches and of the light ones; the smaller wins.
    let p = |hex: u32| OkLabPoint::of(Rgb::hex(hex));
    let dark = p(0xFD7273).distance(p(0x62A7FD));
    let light = p(0xE36364).distance(p(0x4693F1));
    assert_eq!(perceptual_distance(GroupColor::Red, GroupColor::Blue), dark.min(light));
    assert_eq!(perceptual_distance(GroupColor::Cyan, GroupColor::Cyan), 0.0);
    // OKLab from OKLCH: (l, c cos h, c sin h).
    let lch = oklch(Rgb::hex(0xFD7273));
    let pt = p(0xFD7273);
    let rad = lch.h * std::f64::consts::PI / 180.0;
    assert_eq!((pt.lightness, pt.a, pt.b), (lch.l, lch.c * rad.cos(), lch.c * rad.sin()));
    let r = op("group_perceptual_distance", json!({"color": "red", "other": "blue"}));
    assert_eq!(r.as_f64(), Some(dark.min(light)));
    // A blue profile pushes the next color away from blue: of all seven open colors, the
    // farthest from blue.
    let next = automatic_after(&["blue".into()]);
    let mut best = PALETTE_ORDER[0];
    for c in PALETTE_ORDER {
        if perceptual_distance(c, GroupColor::Blue)
            > perceptual_distance(best, GroupColor::Blue) + 1e-9
        {
            best = c;
        }
    }
    assert_eq!(next, best);
}

// MARK: GroupBackground

#[test]
fn glass_fill_pins() {
    let g = Rgb::new(0.2, 0.2, 0.2, 1.0);
    // Needed (0.5 - 0.2) / 0.8 = 0.375 < 0.6: alpha 0.6, channel 0.2 + 0.3 / 0.6 = 0.7.
    let got = glass_fill(Rgb::new(0.5, 0.5, 0.5, 1.0), g, GLASS_OPACITY);
    assert!(close(got, Rgb::new(0.2 + 0.3 / 0.6, 0.2 + 0.3 / 0.6, 0.2 + 0.3 / 0.6, 0.6)));
    // Needed 0.7 / 0.8 = 0.875: alpha 0.875, channel 0.2 + 0.7 / 0.875 (= 1).
    let got = glass_fill(Rgb::new(0.9, 0.2, 0.2, 1.0), g, GLASS_OPACITY);
    assert!(close(got, Rgb::new(0.2 + 0.7 / 0.875, 0.2, 0.2, 0.875)));
    // Going down: (g - s) / g. Ground 0.8, shown 0.1: 0.875.
    let got = glass_fill(Rgb::new(0.1, 0.8, 0.8, 1.0), Rgb::new(0.8, 0.8, 0.8, 1.0), 0.3);
    assert!(close(got, Rgb::new(0.8 + (0.1 - 0.8) / 0.875, 0.8, 0.8, 0.875)));
    // A white ground going up needs 1.
    let got = glass_fill(Rgb::WHITE, Rgb::WHITE, 0.3);
    assert!(close(got, Rgb::new(1.0, 1.0, 1.0, 0.3)));
    let r = op(
        "group_glass_fill",
        json!({"color": {"r": 0.5, "g": 0.5, "b": 0.5}, "ground": {"r": 0.2, "g": 0.2, "b": 0.2}}),
    );
    assert!(close(rgb_of(&r), Rgb::new(0.7, 0.7, 0.7, 0.6)));
}

#[test]
fn visible_pins() {
    // Already 1.2:1 apart: the opaque color.
    let c = Rgb::new(0.9, 0.9, 0.9, 0.4);
    assert_eq!(visible(c, Rgb::BLACK), c.with_alpha(1.0));
    // Mid grey on itself: equal luminance, ground luminance 0.214 >= 0.18, so toward black.
    // 1.2:1 needs luminance <= 0.170, channel <= 0.449: 0.5 (1 - s) <= 0.449 at s = 0.12.
    let g = Rgb::new(0.5, 0.5, 0.5, 1.0);
    let got = visible(g, g);
    assert!(close(got, Rgb::new(0.44, 0.44, 0.44, 1.0)), "{got:?}");
    assert!(got.contrast(g) >= MINIMUM_VISIBLE_CONTRAST);
    let r = op(
        "group_visible",
        json!({"color": {"r": 0.5, "g": 0.5, "b": 0.5}, "ground": {"r": 0.5, "g": 0.5, "b": 0.5}}),
    );
    assert!(close(rgb_of(&r), Rgb::new(0.44, 0.44, 0.44, 1.0)));
}

#[test]
fn glyph_ink_and_chip() {
    let theme = palette_theme(true);
    // The theme's text over its own sidebar reads: the first candidate.
    let sidebar = theme.sidebar();
    let ink = glyph_ink(&theme, sidebar);
    assert_eq!(ink, theme.text().composited(sidebar.with_alpha(1.0)));
    // On mid grey nothing but black reaches 4.5:1 over every state; ink always reads.
    for base in [Rgb::new(0.5, 0.5, 0.5, 1.0), Rgb::hex(0xFD7273), Rgb::hex(0x14BBC2)] {
        let ink = glyph_ink(&theme, base);
        assert!(ink.contrast(base) >= MINIMUM_TEXT_CONTRAST - 0.01, "{base:?}");
        let (fill, ink) = chip(&theme, base, ChipInks::OnColor);
        assert!(ink == Rgb::hex(0x1F1F1F) || ink == Rgb::WHITE);
        assert!(ink.contrast(fill) >= MINIMUM_TEXT_CONTRAST - 0.01, "{base:?}");
    }
    // White bar, onColor: dark 1F1F1F wins the sort and reads, so the bar stays.
    let (fill, ink) = chip(&theme, Rgb::WHITE, ChipInks::OnColor);
    assert_eq!(ink, Rgb::hex(0x1F1F1F));
    assert_eq!(fill, Rgb::WHITE);
    let r = op(
        "group_chip",
        json!({"theme": theme_json(&theme), "color": {"r": 1.0, "g": 1.0, "b": 1.0}, "inks": "onColor"}),
    );
    assert_eq!(rgb_of(&r["ink"]), Rgb::hex(0x1F1F1F));
    let r =
        op("group_glyph_ink", json!({"theme": theme_json(&theme), "color": Color::from(sidebar)}));
    assert_eq!(rgb_of(&r), theme.text().composited(sidebar.with_alpha(1.0)));
}

#[test]
fn background_pins() {
    let theme = palette_theme(true);
    let ground = theme.sidebar().with_alpha(1.0);
    let text = theme.text().with_alpha(1.0);
    // Wash, no tint, solid: ground 8% toward the text, kept visible, glyph ink on it.
    let bg = GroupBackground::new(
        GroupTint::None,
        Strength::Wash,
        false,
        GroupPalette::Vibrant,
        None,
        &theme,
    );
    let shown = visible(ground.mixed(text, 0.08), ground);
    assert_eq!(bg.shown, shown);
    assert_eq!(bg.fill, shown);
    assert_eq!(bg.ink, glyph_ink(&theme, shown));
    assert_eq!(bg.rim, None);
    assert_eq!(bg.ground, ground);
    // Glass: fill composites back to shown, rim the text at 0.16 in dark.
    let glass = GroupBackground::new(
        GroupTint::None,
        Strength::Wash,
        true,
        GroupPalette::Vibrant,
        None,
        &theme,
    );
    assert_eq!(glass.fill, glass_fill(shown, ground, GLASS_OPACITY));
    assert_eq!(glass.rim, Some(text.with_alpha(0.16)));
    assert!(glass.is_glass());
    // Band, vibrant palette: the header fill, onColor inks.
    let band = GroupBackground::new(
        GroupTint::Palette(GroupColor::Green),
        Strength::Band,
        false,
        GroupPalette::Vibrant,
        None,
        &theme,
    );
    let (fill, ink) =
        chip(&theme, visible(header_rgb(GroupColor::Green, &theme), ground), ChipInks::OnColor);
    if fill.contrast(ground) >= MINIMUM_VISIBLE_CONTRAST {
        assert_eq!((band.shown, band.ink), (fill.with_alpha(1.0), ink));
    }
    // painted: no steps is the fill; steps composite over shown, kept visible.
    assert_eq!(band.painted(&[]), band.fill);
    let hover = theme.hover();
    assert_eq!(band.painted(&[hover]), visible(hover.composited(band.shown), ground));
    let r = op(
        "group_background",
        json!({"tint": "none", "strength": "wash", "glass": true, "palette": "vibrant",
               "theme": theme_json(&theme), "steps": [Color::from(hover)]}),
    );
    assert_eq!(rgb_of(&r["shown"]), shown);
    assert_eq!(r["isGlass"], json!(true));
    assert_eq!(rgb_of(&r["rim"]), text.with_alpha(0.16));
    assert_eq!(
        rgb_of(&r["painted"]),
        glass_fill(visible(hover.composited(glass.shown), ground), ground, GLASS_OPACITY)
    );
}

/// GroupBackgroundEveryThemeTests.everyGroupBackgroundIsVisibleInEveryBundledTheme, over the
/// themes this crate can build (the Swift suite reads 600+ bundled theme files).
#[test]
fn every_group_background_is_visible() {
    let themes = [
        (
            0x1E1E2E,
            0xCDD6F4,
            [0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xBAC2DE],
        ),
        (
            0xEFF1F5,
            0x4C4F69,
            [0x5C5F77, 0xD20F39, 0x40A02B, 0xDF8E1D, 0x1E66F5, 0xEA76CB, 0x179299, 0xACB0BE],
        ),
        (
            0x282C34,
            0xFFFFFF,
            [0x1D1F21, 0xCC6666, 0xB5BD68, 0xF0C674, 0x81A2BE, 0xB294BB, 0x8ABEB7, 0xC5C8C6],
        ),
        (
            0xFFFFFF,
            0x000000,
            [0x000000, 0xC91B00, 0x00C200, 0xC7C400, 0x0225C7, 0xCA30C7, 0x00C5C7, 0xC7C7C7],
        ),
        (
            0x000000,
            0xFFFFFF,
            [0x000000, 0xFF0000, 0x00FF00, 0xFFFF00, 0x0000FF, 0xFF00FF, 0x00FFFF, 0xFFFFFF],
        ),
        (
            0xFF0000,
            0xFFFF00,
            [0x000000, 0xFF0000, 0x00FF00, 0xFFFF00, 0x0000FF, 0xFF00FF, 0x00FFFF, 0xFFFFFF],
        ),
        (
            0x777777,
            0x888888,
            [0x000000, 0x7F7F7F, 0x808080, 0x818181, 0x828282, 0x838383, 0x848484, 0x858585],
        ),
    ];
    let wallpaper = Wallpaper::new(0.2, 0.35, 0.6);
    let minimum = MINIMUM_VISIBLE_CONTRAST - 0.005;
    let mut failures = Vec::new();
    for (bg, fg, pal) in themes {
        for opacity in [1.0, 0.7] {
            let theme = theme8(bg, fg, pal, opacity);
            let ground = theme.sidebar().with_alpha(1.0);
            let mut tints = vec![GroupTint::None];
            tints.extend(GroupColor::ALL.map(GroupTint::Palette));
            tints.push(GroupTint::Custom(Rgb::hex(0xD0312D).into()));
            tints.push(GroupTint::Custom(ground.into()));
            for tint in tints {
                for strength in [Strength::Band, Strength::Wash] {
                    for glass in [false, true] {
                        for palette in [
                            GroupPalette::Vibrant,
                            GroupPalette::Theme,
                            GroupPalette::Grayscale,
                            GroupPalette::Wallpaper,
                        ] {
                            let label = format!(
                                "{bg:06X} {opacity} {tint:?} {strength:?} {glass} {palette:?}"
                            );
                            let b = GroupBackground::new(
                                tint,
                                strength,
                                glass,
                                palette,
                                Some(&wallpaper),
                                &theme,
                            );
                            let rest = b.fill.composited(ground);
                            if rest.contrast(ground) < minimum {
                                failures.push(format!("{label}: rest"));
                            }
                            let hovered = b.painted(&[theme.hover()]).composited(ground);
                            if hovered.contrast(ground) < minimum {
                                failures.push(format!("{label}: hovered"));
                            }
                            if glass {
                                if b.fill.a >= 1.0 || b.rim.is_none() {
                                    failures.push(format!("{label}: glass"));
                                }
                                let d = (rest.r - b.shown.r)
                                    .abs()
                                    .max((rest.g - b.shown.g).abs())
                                    .max((rest.b - b.shown.b).abs());
                                if d >= 0.004 {
                                    failures.push(format!("{label}: glass shows {rest:?}"));
                                }
                            } else if b.fill.a < 1.0 {
                                failures.push(format!("{label}: solid is translucent"));
                            }
                            if strength == Strength::Band
                                && b.ink.contrast(b.shown) < MINIMUM_TEXT_CONTRAST - 0.01
                            {
                                failures.push(format!("{label}: ink"));
                            }
                        }
                    }
                }
            }
        }
    }
    assert!(
        failures.is_empty(),
        "{} failures: {:?}",
        failures.len(),
        &failures[..failures.len().min(20)]
    );
}

// MARK: Glass

#[test]
fn over_pins() {
    // a = 0.5 + 1 * 0.5 = 1; red (1 * 0.5 + 0) / 1, blue (0 + 1 * 0.5) / 1.
    let got = over(Rgb::new(1.0, 0.0, 0.0, 0.5), Rgb::new(0.0, 0.0, 1.0, 1.0));
    assert!(close(got, Rgb::new(0.5, 0.0, 0.5, 1.0)));
    // Two halves: a = 0.75; red 0.5 / 0.75, blue 0.25 / 0.75.
    let got = over(Rgb::new(1.0, 0.0, 0.0, 0.5), Rgb::new(0.0, 0.0, 1.0, 0.5));
    assert!(close(got, Rgb::new(0.5 / 0.75, 0.0, 0.25 / 0.75, 0.75)));
    // Both clear: top.
    let top = Rgb::new(0.3, 0.2, 0.1, 0.0);
    assert_eq!(over(top, Rgb::new(1.0, 1.0, 1.0, 0.0)), top);
    let r = op(
        "group_over",
        json!({"top": {"r": 1.0, "g": 0.0, "b": 0.0, "a": 0.5}, "bottom": {"r": 0.0, "g": 0.0, "b": 1.0}}),
    );
    assert!(close(rgb_of(&r), Rgb::new(0.5, 0.0, 0.5, 1.0)));
}

#[test]
fn glass_rgb_pins() {
    let theme = palette_theme(true);
    // No color: the theme text, opaque.
    let none =
        glass_rgb(GroupTint::None, GroupPalette::Vibrant, &theme, None, GroupGradient::Sunset, 1.3);
    assert_eq!(none, theme.text().with_alpha(1.0));
    // Custom (0.8, 0.2, 0.2) reads 3.2:1 on the dark sidebar, so it stays; grey
    // 0.299*0.8 + 0.587*0.2 + 0.114*0.2, each channel pushed 1.3x away from it.
    let custom = GroupTint::Custom(Color { r: 0.8, g: 0.2, b: 0.2, a: 1.0 });
    let got = glass_rgb(custom, GroupPalette::Vibrant, &theme, None, GroupGradient::Sunset, 1.3);
    let grey = 0.299 * 0.8 + 0.587 * 0.2 + 0.114 * 0.2;
    let push = |c: f64| grey + (c - grey) * 1.3;
    assert!(close(got, Rgb::new(push(0.8), push(0.2), push(0.2), 1.0)), "{got:?}");
    // A vibrant swatch, vividness 1: itself.
    let red = glass_rgb(
        GroupTint::Palette(GroupColor::Red),
        GroupPalette::Vibrant,
        &theme,
        None,
        GroupGradient::Sunset,
        1.0,
    );
    assert!(close(red, Rgb::hex(0xFD7273)));
    let r = op(
        "group_glass_rgb",
        json!({"tint": {"custom": {"r": 0.8, "g": 0.2, "b": 0.2}}, "palette": "vibrant", "theme": theme_json(&theme)}),
    );
    assert!(close(rgb_of(&r), Rgb::new(push(0.8), push(0.2), push(0.2), 1.0)));
}

fn paint_input<'a>(
    theme: &'a GroupTheme,
    tint: GroupTint,
    glass: SidebarGroupGlass,
    steps: &'a [Rgb],
) -> GlassPaintInput<'a> {
    GlassPaintInput {
        tint,
        palette: GroupPalette::Vibrant,
        glass,
        theme,
        ground: None,
        steps,
        opaque: false,
        veil: Rgb::new(1.0, 1.0, 1.0, 0.06),
        wallpaper: None,
        gradient: GroupGradient::Sunset,
    }
}

#[test]
fn glass_paint_rules() {
    let theme = palette_theme(true);
    let ground = theme.sidebar().with_alpha(1.0);
    let veil = Rgb::new(1.0, 1.0, 1.0, 0.06);
    // A colored pane: the vivid glass tint over the veil.
    let tint = GroupTint::Palette(GroupColor::Cyan);
    let p = glass_paint(&paint_input(&theme, tint, SidebarGroupGlass::Vivid, &[]));
    let pane = over(
        glass_rgb(tint, GroupPalette::Vibrant, &theme, None, GroupGradient::Sunset, 1.3)
            .with_alpha(0.44),
        veil,
    );
    let shown = pane.composited(ground).with_alpha(1.0);
    if shown.contrast(ground) >= MINIMUM_VISIBLE_CONTRAST {
        assert_eq!(p.fill, pane);
        assert_eq!(p.shown, shown);
    }
    assert!(p.shown.contrast(ground) >= MINIMUM_VISIBLE_CONTRAST);
    assert_eq!(p.ink, readable(theme.text().with_alpha(1.0), p.shown, MINIMUM_TEXT_CONTRAST));
    // Solid draws as vivid glass.
    assert_eq!(p, glass_paint(&paint_input(&theme, tint, SidebarGroupGlass::Solid, &[])));
    // No color: the neutral band's shown at 0.3 over the ground (no veil).
    let n = glass_paint(&paint_input(&theme, GroupTint::None, SidebarGroupGlass::Frost, &[]));
    let neutral = GroupBackground::new(
        GroupTint::None,
        Strength::Band,
        false,
        GroupPalette::Vibrant,
        None,
        &theme,
    );
    let pane = glass_fill(neutral.shown, ground, NEUTRAL_OPACITY);
    let shown = pane.composited(ground).with_alpha(1.0);
    if shown.contrast(ground) >= MINIMUM_VISIBLE_CONTRAST {
        assert_eq!(n.fill, pane);
    }
    // Opaque paints shown.
    let mut input = paint_input(&theme, tint, SidebarGroupGlass::Glass, &[]);
    input.opaque = true;
    let o = glass_paint(&input);
    assert_eq!(o.fill, o.shown);
    // JSON.
    let r = op(
        "group_glass_paint",
        json!({"tint": {"palette": "cyan"}, "palette": "vibrant", "glass": "vivid",
               "theme": theme_json(&theme), "veil": {"r": 1.0, "g": 1.0, "b": 1.0, "a": 0.06}}),
    );
    assert_eq!(rgb_of(&r["fill"]), p.fill);
    assert_eq!(rgb_of(&r["ink"]), p.ink);
}

#[test]
fn chip_glass() {
    use SidebarGroupBackgroundStyle as S;
    // A look the strip does not take falls back to auto: glass unless the bar is solid.
    assert!(chip_draws_glass(SidebarGroupGlass::Vivid, S::Folder));
    assert!(!chip_draws_glass(SidebarGroupGlass::Solid, S::Card));
    assert!(chip_draws_glass(SidebarGroupGlass::Solid, S::Glass));
    assert!(!chip_draws_glass(SidebarGroupGlass::Vivid, S::Solid));
    assert!(!chip_draws_glass(SidebarGroupGlass::Vivid, S::Sections));
    let theme = palette_theme(true);
    let chrome = Rgb::hex(0x181825);
    let tint = GroupTint::Palette(GroupColor::Red);
    let input = paint_input(&theme, tint, SidebarGroupGlass::Vivid, &[]);
    assert_eq!(chip_glass_paint(S::Solid, chrome, &input), None);
    let none = paint_input(&theme, GroupTint::None, SidebarGroupGlass::Vivid, &[]);
    assert_eq!(chip_glass_paint(S::Auto, chrome, &none), None);
    let got = chip_glass_paint(S::Auto, chrome, &input).expect("glass");
    let mut want = input.clone();
    want.ground = Some(chrome);
    assert_eq!(got, glass_paint(&want));
    assert_eq!(
        op("group_chip_glass_draws", json!({"glass": "solid", "background": "glass"})),
        json!(true)
    );
    let r = op(
        "group_chip_glass_paint",
        json!({"tint": {"palette": "red"}, "palette": "vibrant", "glass": "vivid", "theme": theme_json(&theme),
               "veil": {"r": 1.0, "g": 1.0, "b": 1.0, "a": 0.06}, "background": "solid", "chrome": Color::from(chrome)}),
    );
    assert_eq!(r, Value::Null);
    let r = op(
        "group_chip_glass_paint",
        json!({"tint": {"palette": "red"}, "palette": "vibrant", "glass": "vivid", "theme": theme_json(&theme),
               "veil": {"r": 1.0, "g": 1.0, "b": 1.0, "a": 0.06}, "background": "auto", "chrome": Color::from(chrome)}),
    );
    assert_eq!(rgb_of(&r["fill"]), got.fill);
}

#[test]
fn unknown_and_bad_requests() {
    assert_eq!(call("tokens.group_nope", &json!({})), Err(OpError::Unknown));
    assert_eq!(
        cmux_design_core::tokens::group::call("density_entry", &json!({})),
        Err(OpError::Unknown)
    );
    assert!(matches!(
        call("tokens.group_glass_tint", &json!({"glass": "clear"})),
        Err(OpError::Invalid(_))
    ));
}
