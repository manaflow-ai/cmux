use super::*;

fn theme(background: u32, foreground: u32, accent: u32, dark: bool) -> Theme {
    Theme {
        background: Rgb::hex(background),
        foreground: Rgb::hex(foreground),
        accent: Rgb::hex(accent),
        dark,
    }
}

fn themes() -> Vec<Theme> {
    FIXTURE_THEMES.iter().map(|&(_, b, f, a, d)| theme(b, f, a, d)).collect()
}

#[test]
fn off_and_unknown_values_paint_nothing() {
    let t = theme(0x282C34, 0xFFFFFF, 0xC678DD, true);
    assert_eq!(resolve(OFF, t), None);
    assert_eq!(resolve("neon", t), None);
    assert_eq!(resolve("", t), None);
}

#[test]
fn values_are_off_auto_then_unique_pairings() {
    let values = values();
    assert_eq!(&values[..2], &[OFF, AUTO]);
    assert_eq!(values.len(), 2 + PAIRINGS.len());
    let unique: std::collections::BTreeSet<_> = values.iter().collect();
    assert_eq!(unique.len(), values.len());
    for p in PAIRINGS {
        assert!(p.id.chars().all(|c| c.is_ascii_alphanumeric()), "{}", p.id);
        assert!(!p.title.is_empty());
    }
}

#[test]
fn every_value_keeps_text_readable_and_the_accent_visible_on_both_tones() {
    for t in themes() {
        for value in values().into_iter().filter(|v| *v != OFF) {
            let tones = resolve(value, t).unwrap();
            let content = tones.content.unwrap_or(t.background);
            assert!(
                t.foreground.contrast(tones.chrome) >= TEXT_MINIMUM,
                "{value} chrome {} under {}",
                hex(tones.chrome),
                hex(t.foreground)
            );
            assert!(
                tones.content.is_none() || t.foreground.contrast(content) >= TEXT_MINIMUM,
                "{value} content {}",
                hex(content)
            );
            assert!(
                tones.accent.contrast(tones.chrome) >= MARK_MINIMUM,
                "{value} accent on chrome"
            );
            assert!(tones.accent.contrast(content) >= MARK_MINIMUM, "{value} accent on content");
        }
    }
}

#[test]
fn the_two_tones_are_apart_but_in_one_family() {
    for t in themes() {
        for value in values().into_iter().filter(|v| *v != OFF) {
            let tones = resolve(value, t).unwrap();
            let content = tones.content.unwrap_or(t.background);
            let (a, b) = (oklch(tones.chrome), oklch(content));
            let apart = (a.l - b.l).abs();
            // Seen apart (an OKLCH lightness step or a hue), never a jarring jump.
            assert!(
                apart >= 0.02 || (a.c - b.c).abs() >= 0.02,
                "{value}: tones too close: {apart}"
            );
            assert!(apart <= 0.2, "{value}: tones too far apart: {apart}");
        }
    }
}

#[test]
fn a_dark_theme_gets_dark_tones_and_a_light_theme_light_ones() {
    for t in themes() {
        for p in PAIRINGS {
            let tones = resolve(p.id, t).unwrap();
            for tone in [tones.chrome, tones.content.unwrap()] {
                assert_eq!(tone.relative_luminance() < 0.18, t.dark, "{} {}", p.id, hex(tone));
            }
        }
    }
}

#[test]
fn auto_follows_the_theme() {
    // Dark: a step lighter, toward the accent's hue.
    let dark = theme(0x1A1B26, 0xC0CAF5, 0x7AA2F7, true);
    let tones = resolve(AUTO, dark).unwrap();
    assert_eq!(tones.content, None);
    let (chrome, ground, accent) =
        (oklch(tones.chrome), oklch(dark.background), oklch(dark.accent));
    assert!(chrome.l > ground.l);
    let distance = |a: f64, b: f64| {
        let d = (a - b).rem_euclid(360.0);
        d.min(360.0 - d)
    };
    assert!(
        distance(chrome.h, accent.h) <= distance(ground.h, accent.h) + 1.0,
        "{} vs {}",
        chrome.h,
        accent.h
    );
    assert!(chrome.c <= AUTO_MAX_CHROMA.max(ground.c) + 0.005);
    // Light: a step darker.
    let light = theme(0xFFFFFF, 0x1F2328, 0x0969DA, false);
    let tones = resolve(AUTO, light).unwrap();
    assert!(oklch(tones.chrome).l < oklch(light.background).l);
    // A neutral accent adds no hue: a neutral ground stays neutral.
    let neutral = theme(0x000000, 0xEEEEEE, 0x9A9A9A, true);
    assert!(oklch(resolve(AUTO, neutral).unwrap().chrome).c < 0.005);
    // Two themes give two tones.
    assert_ne!(resolve(AUTO, dark).unwrap().chrome, resolve(AUTO, neutral).unwrap().chrome);
}

#[test]
fn a_pairing_keeps_its_colors_where_they_already_read() {
    let t = theme(0x161616, 0xF2F4F8, 0xEE5396, true);
    let tones = resolve("charcoalRose", t).unwrap();
    assert_eq!(hex(tones.chrome), "#161616");
    assert_eq!(tones.content.map(hex).as_deref(), Some("#202020"));
    assert_eq!(hex(tones.accent), "#EE5396");
}

#[test]
fn resolving_is_deterministic() {
    for t in themes() {
        for value in values() {
            assert_eq!(resolve(value, t), resolve(value, t));
        }
    }
    assert_eq!(fixture(), fixture());
}

/// Writes the fixture the Swift mirror's test reads (`TwoToneTests`) to the
/// path in `CMUX_TWO_TONE_FIXTURE`; that test runs this one. Without the
/// variable it only checks the fixture serializes. The fixture is never
/// committed: generated files are made where they are used.
#[test]
fn writes_the_swift_fixture() {
    let fresh = format!("{}\n", serde_json::to_string_pretty(&fixture()).unwrap());
    if let Some(path) = std::env::var_os("CMUX_TWO_TONE_FIXTURE") {
        std::fs::write(&path, &fresh).unwrap();
    }
    assert!(fresh.contains("\"cases\""));
}

/// The settings source lists exactly these values.
#[test]
fn the_settings_source_lists_every_value() {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../schemas/settings/source/appearance.json");
    let source: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    let row = source["lists"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|list| list["rows"].as_array().unwrap())
        .find(|row| row["key"] == SETTING_KEY)
        .expect("appearance.json has the row");
    let listed: Vec<&str> =
        row["choices"].as_array().unwrap().iter().map(|c| c["value"].as_str().unwrap()).collect();
    assert_eq!(listed, values());
    assert_eq!(row["default"], OFF);
    for (choice, pairing) in row["choices"].as_array().unwrap()[2..].iter().zip(PAIRINGS) {
        assert_eq!(choice["title"]["text"], pairing.title);
    }
}
