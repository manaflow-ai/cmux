use super::*;

fn canvases() -> [u32; 7] {
    [0x101418, 0x000000, 0x1e1e2e, 0xfafafa, 0xffffff, 0xf4ecd8, 0x808080]
}

fn accents() -> [u32; 5] {
    [0x7aa2f7, 0xff0000, 0x00ff00, 0x222222, 0xeeeeee]
}

#[test]
fn every_key_is_set() {
    let t = theme_from_two_colors(Rgb::hex(0x101418), Rgb::hex(0x7aa2f7), None);
    let s = &t.scheme;
    assert!(s.cursor.is_some() && s.cursor_text.is_some());
    assert!(s.selection_background.is_some() && s.selection_foreground.is_some());
    assert_eq!(s.accent, Some(t.accent));
    assert_eq!(s.background.to_hex(), 0x101418);
    let text = s.export(crate::SchemeFormat::Ghostty);
    for key in [
        "background",
        "foreground",
        "cursor-color",
        "cursor-text",
        "selection-background",
        "selection-foreground",
        "cmux-accent",
    ] {
        assert!(text.contains(key), "{key} missing:\n{text}");
    }
    assert_eq!(text.matches("palette = ").count(), 16, "{text}");
}

#[test]
fn appearance_follows_the_canvas() {
    let dark = theme_from_two_colors(Rgb::hex(0x101418), Rgb::hex(0x7aa2f7), None);
    let light = theme_from_two_colors(Rgb::hex(0xfafafa), Rgb::hex(0x7aa2f7), None);
    assert_eq!(dark.appearance, Appearance::Dark);
    assert_eq!(light.appearance, Appearance::Light);
}

#[test]
fn contrast_holds_on_every_canvas_and_accent() {
    let spec = spec();
    let (text, mark) = (spec.minimum_text_contrast, spec.minimum_mark_contrast);
    for canvas in canvases() {
        for accent in accents() {
            for asked in [None, Some(Appearance::Dark), Some(Appearance::Light)] {
                let t = theme_from_two_colors(Rgb::hex(canvas), Rgb::hex(accent), asked);
                let s = &t.scheme;
                let ctx = format!("canvas {canvas:06x} accent {accent:06x} {asked:?}");
                assert!(s.foreground.contrast(s.background) >= text, "foreground {ctx}");
                for (i, c) in s.palette.iter().enumerate() {
                    let floor = if matches!(i, 0) {
                        1.0
                    } else if i == 7 {
                        text
                    } else {
                        mark
                    };
                    assert!(c.contrast(s.background) >= floor, "ansi {i} {ctx}");
                }
                assert!(t.accent.contrast(s.background) >= mark, "accent {ctx}");
                let (sb, sf) = (s.selection_background.unwrap(), s.selection_foreground.unwrap());
                assert!(sf.contrast(sb) >= text, "selection {ctx}");
                assert!(s.cursor_text.unwrap().contrast(t.accent) >= text, "cursor text {ctx}");
            }
        }
    }
}

#[test]
fn same_colors_same_theme() {
    let a = theme_from_two_colors(Rgb::hex(0x1e1e2e), Rgb::hex(0xcba6f7), None);
    let b = theme_from_two_colors(Rgb::hex(0x1e1e2e), Rgb::hex(0xcba6f7), None);
    assert_eq!(a, b);
}
