//! Parity tests for `tokens::omnibar_ink` (`OmnibarInk.swift`, `AddressBarSurface.swift`): the
//! portable cases of OmnibarInkEveryThemeTests, plus pins worked from the Swift formulas.

use cmux_design_core::ops::call;
use cmux_design_core::tokens::color::Rgb;
use cmux_design_core::tokens::omnibar_ink::*;
use serde_json::{Value, json};

fn close(a: f64, b: f64) -> bool {
    (a - b).abs() < 1e-9
}

fn assert_rgb(c: Rgb, r: f64, g: f64, b: f64, a: f64) {
    assert!(
        close(c.r, r) && close(c.g, g) && close(c.b, b) && close(c.a, a),
        "{c:?} != ({r}, {g}, {b}, {a})"
    );
}

fn grey(c: Rgb, v: f64) {
    assert_rgb(c, v, v, v, 1.0);
}

fn op(name: &str, request: Value) -> Value {
    call(&format!("tokens.{name}"), &request).unwrap()
}

fn hex_json(h: u32) -> Value {
    let c = Rgb::hex(h);
    json!({"r": c.r, "g": c.g, "b": c.b})
}

fn num(v: &Value) -> f64 {
    v.as_f64().unwrap()
}

// MARK: Swift tests

/// OmnibarInkEveryThemeTests.anInkTheGroundsCannotRead...: light grounds and a near-white text
/// get a dark ink that reads on every ground.
#[test]
fn an_ink_the_grounds_cannot_read_moves_to_a_pole() {
    let grounds = [Rgb::hex(0xF0F0F0), Rgb::hex(0xE4E4E4)];
    let ink =
        OmnibarInk::new(Rgb::hex(0xF2F2F2), Rgb::hex(0xA0A0A0), &grounds, MINIMUM_TEXT_CONTRAST);
    for c in [ink.primary, ink.secondary, ink.icon] {
        assert!(worst_contrast(c, &ink.grounds) >= MINIMUM_TEXT_CONTRAST);
        assert!(c.relative_luminance() < 0.2);
        // F2F2F2 mixed 60% toward black: 0.9490196.. * 0.4.
        grey(c, 0.37960784313725493);
    }
    assert!(close(worst_contrast(ink.primary, &ink.grounds), 4.885878078444627));
}

/// OmnibarInkEveryThemeTests.theInkIsTheThemesOwnWhereItReads, on a dark opaque flat bar.
#[test]
fn the_ink_is_the_themes_own_where_it_reads() {
    let surface = AddressBarSurface::new(Rgb::hex(0x1E1E1E), Rgb::hex(0xF2F2F2), true, 1.0);
    let ink = surface.ink(&Backing::Flat { coverage: 0.0 }, Rgb::hex(0x9A9A9A));
    assert_eq!(ink.primary, Rgb::hex(0xF2F2F2));
    assert!(worst_contrast(ink.icon, &ink.grounds) >= MINIMUM_TEXT_CONTRAST);
    // The icon keeps its 83%; the secondary falls back to the primary.
    assert_rgb(ink.icon, 0.9490196078431372, 0.9490196078431372, 0.9490196078431372, 0.83);
    assert_eq!(ink.secondary, ink.primary);
    assert!(ink.reads(ink.primary));
}

// MARK: Pins: OmnibarInk

#[test]
fn readable_rules() {
    assert_eq!(worst_contrast(Rgb::hex(0x123456), &[]), 21.0);
    assert_eq!(worst_contrast(Rgb::BLACK, &[Rgb::WHITE]), 21.0);
    // Preferred reads: kept as is.
    assert_eq!(readable(Rgb::WHITE, &[Rgb::BLACK], 4.5, None), Rgb::WHITE);
    // Fallback reads.
    assert_eq!(readable(Rgb::hex(0x333333), &[Rgb::BLACK], 4.5, Some(Rgb::WHITE)), Rgb::WHITE);
    // Mid grey on itself: black wins (white is worse), 95% of the way.
    grey(readable(Rgb::hex(0x777777), &[Rgb::hex(0x777777)], 4.5, None), 0.023333333333333373);
    // Nothing reaches 21: the pole.
    assert_eq!(readable(Rgb::hex(0x777777), &[Rgb::hex(0x777777)], 21.0, None), Rgb::BLACK);
    // Empty grounds read anything.
    assert_eq!(readable(Rgb::hex(0x777777), &[], 4.5, None), Rgb::hex(0x777777));
    // No grounds: black.
    let ink = OmnibarInk::new(Rgb::WHITE, Rgb::WHITE, &[], 4.5);
    assert_eq!(ink.grounds, vec![Rgb::BLACK]);
    // Grounds are made opaque.
    let ink = OmnibarInk::new(Rgb::WHITE, Rgb::WHITE, &[Rgb::new(0.0, 0.0, 0.0, 0.3)], 4.5);
    assert_eq!(ink.grounds, vec![Rgb::BLACK]);
}

#[test]
fn icon_on_plates() {
    let ink = OmnibarInk::new(Rgb::hex(0xF2F2F2), Rgb::hex(0xA0A0A0), &[Rgb::hex(0x1E1E1E)], 4.5);
    grey(ink.secondary, 0.6274509803921569);
    assert_eq!(ink.icon_on(&[], true, 4.5), ink.icon);
    assert_eq!(ink.icon_on(&[], false, 4.5), ink.icon);
    let plate = Rgb::new(1.0, 1.0, 1.0, 0.9);
    grey(ink.icon_on(&[plate], false, 4.5), 0.37707450980392154);
    assert_eq!(ink.icon_on(&[plate], true, 4.5), Rgb::BLACK);
}

// MARK: Pins: AddressBarSurface

#[test]
fn surface_steps_and_card() {
    assert_eq!(AddressBarSurface::step(BarState::Rest, true), 0.10);
    assert_eq!(AddressBarSurface::step(BarState::Rest, false), 0.07);
    assert_eq!(AddressBarSurface::step(BarState::Hover, true), 0.245);
    assert_eq!(AddressBarSurface::step(BarState::Hover, false), 0.12);
    assert_eq!(AddressBarSurface::card_step(true), 0.12);
    assert_eq!(AddressBarSurface::card_step(false), 0.0);
    assert_eq!(AddressBarSurface::row_selected_alpha(true), 0.105);
    assert_eq!(AddressBarSurface::row_selected_alpha(false), 0.05);
    let s = AddressBarSurface::new(Rgb::hex(0x1E1E1E), Rgb::hex(0xF2F2F2), true, 1.0);
    assert_eq!(s.readable_step(BarState::Rest), 0.10);
    assert_eq!(s.readable_step(BarState::Hover), 0.245);
    grey(s.card(), 0.21741176470588236);
    let row = s.row_selected();
    assert_rgb(row, 0.9490196078431372, 0.9490196078431372, 0.9490196078431372, 0.105);
    // Opacity is clamped, colours made opaque.
    let c = AddressBarSurface::new(Rgb::new(0.0, 0.0, 0.0, 0.2), Rgb::WHITE, true, 3.0);
    assert_eq!(c.window_opacity, 1.0);
    assert_eq!(c.background.a, 1.0);
}

#[test]
fn readable_step_eases_back() {
    // White text on a mid grey: each step drops 0.01 until the text still reads.
    for (bg, rest, hover) in [
        (0x6A6A6A, 0.08000000000000002, 0.07499999999999993),
        (0x707070, 0.040000000000000015, 0.04499999999999993),
        (0x737373, 0.02000000000000001, 0.024999999999999925),
    ] {
        let s = AddressBarSurface::new(Rgb::hex(bg), Rgb::WHITE, true, 1.0);
        assert!(close(s.readable_step(BarState::Rest), rest), "{bg:x}");
        assert!(close(s.readable_step(BarState::Hover), hover), "{bg:x}");
    }
    // Unreadable even bare: 0.
    let s = AddressBarSurface::new(Rgb::hex(0x777777), Rgb::WHITE, true, 1.0);
    assert_eq!(s.readable_step(BarState::Hover), 0.0);
}

#[test]
fn layered_fill() {
    let s = AddressBarSurface::new(Rgb::BLACK, Rgb::WHITE, true, 1.0);
    assert_rgb(s.layered(0.5, 0.5), 2.0 / 3.0, 2.0 / 3.0, 2.0 / 3.0, 0.75);
    assert_eq!(s.layered(0.0, 0.0), Rgb::new(0.0, 0.0, 0.0, 0.0));
    let d = AddressBarSurface::new(Rgb::hex(0x1E1E1E), Rgb::hex(0xF2F2F2), true, 1.0);
    assert_rgb(
        d.layered(0.1, 0.0),
        0.9490196078431375,
        0.9490196078431375,
        0.9490196078431375,
        0.1,
    );
    assert_rgb(
        d.fill(BarState::Rest, 0.0),
        0.9490196078431375,
        0.9490196078431375,
        0.9490196078431375,
        0.1,
    );
}

#[test]
fn coverage_rises_to_the_legibility_floor() {
    let s = AddressBarSurface::new(Rgb::WHITE, Rgb::hex(0x1A1A1A), false, 0.5);
    assert_eq!(s.readable_step(BarState::Rest), 0.07);
    assert_eq!(s.readable_step(BarState::Hover), 0.12);
    assert_eq!(s.resolved_coverage(0.0), 0.13);
    assert_eq!(s.resolved_coverage(f64::NAN), 0.13);
    assert_eq!(s.resolved_coverage(0.7), 0.7);
    assert_eq!(s.resolved_coverage(2.0), 1.0);
    // An opaque window takes the request as is (clamped).
    let o = AddressBarSurface::new(Rgb::WHITE, Rgb::hex(0x1A1A1A), false, 1.0);
    assert_eq!(o.resolved_coverage(0.0), 0.0);
    assert_eq!(o.resolved_coverage(-1.0), 0.0);
    assert_eq!(s.desktops(), vec![Rgb::BLACK, Rgb::WHITE]);
    assert_eq!(o.desktops(), vec![Rgb::BLACK]);
    let tg = s.toolbar_grounds();
    grey(tg[0], 0.5);
    grey(tg[1], 1.0);
    let grounds = s.ink_grounds(&Backing::Flat { coverage: 0.0 });
    assert_eq!(grounds.len(), 5);
    for (g, v) in grounds.iter().zip([
        1.0,
        0.5325872549019608,
        0.9371372549019608,
        0.5094352941176471,
        0.892235294117647,
    ]) {
        grey(*g, v);
    }
    let ink = s.ink(&Backing::Flat { coverage: 0.0 }, Rgb::hex(0x8A8A8A));
    assert_eq!(ink.primary, Rgb::hex(0x1A1A1A));
    assert_eq!(ink.secondary, Rgb::hex(0x1A1A1A));
    assert_eq!(ink.icon, Rgb::hex(0x1A1A1A));
}

#[test]
fn glass_and_clear_grounds() {
    let s = AddressBarSurface::new(Rgb::hex(0x202020), Rgb::hex(0xEEEEEE), true, 0.8);
    let hover = Rgb::new(1.0, 1.0, 1.0, 0.1);
    let red = Rgb::new(1.0, 0.0, 0.0, 0.2);
    assert_eq!(AddressBarSurface::glass_frost(true), (Rgb::BLACK, 0.30));
    assert_eq!(AddressBarSurface::glass_frost(false), (Rgb::WHITE, 0.35));
    let g = s.ink_grounds(&Backing::Glass { tints: vec![None, Some(red)], hover });
    let want = [
        (0.22243137254901962, 0.22243137254901962),
        (0.07027450980392158, 0.07027450980392158),
        (0.1632470588235294, 0.1632470588235294),
        (0.25621960784313724, 0.056219607843137266),
        (0.33059764705882355, 0.15059764705882353),
        (0.2102745098039215, 0.2102745098039215),
        (0.28924705882352936, 0.28924705882352936),
        (0.36821960784313723, 0.16821960784313722),
        (0.4313976470588235, 0.2513976470588235),
    ];
    assert_eq!(g.len(), want.len());
    for (c, (r, gb)) in g.iter().zip(want) {
        assert_rgb(*c, r, gb, gb, 1.0);
    }
    // No tints: one untinted glass per ground.
    let e = s.ink_grounds(&Backing::Glass { tints: vec![], hover });
    assert_eq!(e, vec![g[0], g[1], g[2], g[5], g[6]]);
    let c = s.ink_grounds(&Backing::Clear { hover });
    for (c, v) in c.iter().zip([
        0.22243137254901962,
        0.10039215686274511,
        0.300392156862745,
        0.1903529411764706,
        0.3703529411764705,
    ]) {
        grey(*c, v);
    }
}

#[test]
fn backing_pick() {
    let h = Rgb::hex(0x101010);
    assert_eq!(
        backing_for(true, true, vec![None], h, 0.4),
        Backing::Glass { tints: vec![None], hover: h }
    );
    assert_eq!(backing_for(false, true, vec![], h, 0.4), Backing::Clear { hover: h });
    assert_eq!(backing_for(false, false, vec![], h, 0.4), Backing::Flat { coverage: 0.4 });
}

// MARK: Ops

#[test]
fn ops() {
    let ink = op(
        "omnibar_ink_new",
        json!({"text": hex_json(0xF2F2F2), "secondaryText": hex_json(0xA0A0A0),
               "grounds": [hex_json(0xF0F0F0), hex_json(0xE4E4E4)]}),
    );
    assert!(close(num(&ink["primary"]["r"]), 0.37960784313725493));
    assert!(close(num(&ink["icon"]["g"]), 0.37960784313725493));
    assert_eq!(ink["grounds"].as_array().unwrap().len(), 2);

    let dark = op(
        "omnibar_ink_new",
        json!({"text": hex_json(0xF2F2F2), "secondaryText": hex_json(0xA0A0A0), "grounds": [hex_json(0x1E1E1E)]}),
    );
    let icon = op(
        "omnibar_ink_icon_on",
        json!({"ink": dark, "plates": [{"r": 1.0, "g": 1.0, "b": 1.0, "a": 0.9}], "bare": false}),
    );
    assert!(close(num(&icon["r"]), 0.37707450980392154));
    let bare = op(
        "omnibar_ink_icon_on",
        json!({"ink": dark, "plates": [{"r": 1.0, "g": 1.0, "b": 1.0, "a": 0.9}]}),
    );
    assert_eq!(bare, json!({"r": 0.0, "g": 0.0, "b": 0.0, "a": 1.0}));

    let w = op(
        "omnibar_ink_worst_contrast",
        json!({"ink": hex_json(0x000000), "grounds": [hex_json(0xFFFFFF)]}),
    );
    assert_eq!(w, json!(21.0));
    assert_eq!(
        op("omnibar_ink_worst_contrast", json!({"ink": hex_json(0x000000), "grounds": []})),
        json!(21.0)
    );
    assert_eq!(
        op(
            "omnibar_ink_reads",
            json!({"color": hex_json(0x777777), "grounds": [hex_json(0x777777)]})
        ),
        json!(false)
    );
    assert_eq!(
        op(
            "omnibar_ink_reads",
            json!({"color": hex_json(0xFFFFFF), "grounds": [hex_json(0x000000)]})
        ),
        json!(true)
    );

    let light = json!({"background": hex_json(0xFFFFFF), "text": hex_json(0x1A1A1A), "isDark": false, "windowOpacity": 0.5});
    let s = op("omnibar_ink_surface", json!({"surface": light}));
    assert_eq!(s["restStep"], json!(0.07));
    assert_eq!(s["hoverStep"], json!(0.12));
    assert_eq!(s["resolvedCoverage"], json!(0.13));
    assert_eq!(s["desktops"].as_array().unwrap().len(), 2);
    assert_eq!(s["toolbarGrounds"][0], json!({"r": 0.5, "g": 0.5, "b": 0.5, "a": 1.0}));
    assert_eq!(s["card"], json!({"r": 1.0, "g": 1.0, "b": 1.0, "a": 1.0}));
    assert!(close(num(&s["rowSelected"]["a"]), 0.05));

    let g = op(
        "omnibar_ink_grounds",
        json!({"surface": light, "backing": {"kind": "flat", "coverage": 0.0}}),
    );
    assert_eq!(g.as_array().unwrap().len(), 5);
    assert!(close(num(&g[1]["r"]), 0.5325872549019608));

    let glass = json!({"background": hex_json(0x202020), "text": hex_json(0xEEEEEE), "isDark": true, "windowOpacity": 0.8});
    let gg = op(
        "omnibar_ink_grounds",
        json!({"surface": glass, "backing": {"kind": "glass", "tints": [null, {"r": 1.0, "g": 0.0, "b": 0.0, "a": 0.2}],
               "hover": {"r": 1.0, "g": 1.0, "b": 1.0, "a": 0.1}}}),
    );
    assert_eq!(gg.as_array().unwrap().len(), 9);
    assert!(close(num(&gg[3]["r"]), 0.25621960784313724));
    let gc = op(
        "omnibar_ink_grounds",
        json!({"surface": glass, "backing": {"kind": "clear", "hover": {"r": 1.0, "g": 1.0, "b": 1.0, "a": 0.1}}}),
    );
    assert!(close(num(&gc[4]["r"]), 0.3703529411764705));

    let dark_surface = json!({"background": hex_json(0x1E1E1E), "text": hex_json(0xF2F2F2), "isDark": true, "windowOpacity": 1.0});
    let fs = op(
        "omnibar_ink_for_surface",
        json!({"surface": dark_surface, "backing": {"kind": "flat", "coverage": 0.0}, "secondaryText": hex_json(0x9A9A9A)}),
    );
    assert_eq!(
        fs["primary"],
        hex_json(0xF2F2F2)
            .as_object()
            .map(|o| {
                let mut o = o.clone();
                o.insert("a".into(), json!(1.0));
                Value::Object(o)
            })
            .unwrap()
    );
    assert!(close(num(&fs["icon"]["a"]), 0.83));

    let b = op(
        "omnibar_ink_backing",
        json!({"glass": true, "glassTints": [null], "hoverFill": hex_json(0x101010)}),
    );
    assert_eq!(b["kind"], json!("glass"));
    assert_eq!(b["tints"], json!([null]));
    let b =
        op("omnibar_ink_backing", json!({"transparent": true, "hoverFill": hex_json(0x101010)}));
    assert_eq!(b["kind"], json!("clear"));
    let b = op("omnibar_ink_backing", json!({"hoverFill": hex_json(0x101010), "coverage": 0.25}));
    assert_eq!(b, json!({"kind": "flat", "coverage": 0.25}));
    assert!(call("tokens.omnibar_ink_nope", &json!({})).is_err());
}
