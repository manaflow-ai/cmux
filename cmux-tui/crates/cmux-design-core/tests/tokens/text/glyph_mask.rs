//! `GlyphMask.swift`.

use cmux_design_core::ops::call;
use cmux_design_core::tokens::text::glyph_mask::*;
use serde_json::json;

#[test]
fn constants() {
    assert_eq!(WEIGHT_CACHE_LIMIT, 512);
    assert_eq!((MEASURE_STRING, MEASURE_WIDTH, MEASURE_HEIGHT), ("Hlm", 96, 40));
    assert_eq!((WARM_STRING, WARM_WIDTH, WARM_HEIGHT), ("Hlm1", 64, 32));
    assert_eq!(REFERENCE_SCALE, 2.0);
    assert_eq!(REFERENCE_TEXT_POSITION, (2.0, 5.0));
    assert_eq!(WARM_WEIGHTS, ["regular", "medium", "semibold"]);
}

#[test]
fn components_clamp_and_default_black() {
    assert_eq!(components(None), [0.0; 3]);
    assert_eq!(components(Some(&[1.0, 0.5])), [0.0; 3]);
    assert_eq!(components(Some(&[1.5, -0.2, 0.25, 0.9])), [1.0, 0.0, 0.25]);
}

#[test]
fn weight_key_pins() {
    assert_eq!(weight_key([1.0, 1.0, 1.0], true), 0x01FF_FFFF);
    assert_eq!(weight_key([1.0, 1.0, 1.0], false), 0x00FF_FFFF);
    assert_eq!(weight_key([0.0, 0.0, 0.0], true), 0x0100_0000);
    // 0.5 * 255 = 127.5 rounds away from zero to 128 (0x80).
    assert_eq!(weight_key([0.5, 0.0, 0.0], false), 0x0080_0000);
    assert_ne!(weight_key([0.2, 0.3, 0.4], true), weight_key([0.2, 0.3, 0.4], false));
}

#[test]
fn weight_and_cache() {
    assert_eq!(weight(7, false), 14);
    assert_eq!(weight(7, true), 15);
    assert!(!weight_cache_evicts(511));
    assert!(weight_cache_evicts(512));
}

#[test]
fn pixels_and_placement() {
    assert_eq!(image_scale(0.5), 1.0);
    assert_eq!(image_scale(2.0), 2.0);
    assert_eq!(pixels(10.25, 3.0, 2.0), (21, 6));
    assert_eq!(image_pixels(0.0, 10.0, 2.0), None);
    assert_eq!(image_pixels(10.25, 3.0, 0.0), Some((11, 3)));
    assert!(renders_top_down(&[true]));
    assert!(!renders_top_down(&[true, true]));
    assert!(!renders_top_down(&[]));
    assert!(renders_top_down(&[false, true, true, true]));
    // 10.25 x 3.3 at 2x: 21 x 7 px, 10.5 x 3.5 pt; bottom-up y = 3.3 - 3.5.
    let p = place(10.25, 3.3, 2.0, false);
    assert_eq!((p.x, p.width, p.height, p.contents_scale), (0.0, 10.5, 3.5, 2.0));
    assert!((p.y - (3.3 - 3.5)).abs() < 1e-12);
    assert_eq!(place(10.25, 3.3, 2.0, true).y, 0.0);
}

#[test]
fn ops() {
    assert_eq!(
        call("tokens.text_glyph_weight_key", &json!({"ink": [1, 1, 1], "smoothsStems": true}))
            .unwrap(),
        json!({"components": [1.0, 1.0, 1.0], "key": 0x01FF_FFFF})
    );
    assert_eq!(
        call("tokens.text_glyph_weight", &json!({"measured": 3, "smoothsStems": true})).unwrap(),
        json!({"weight": 7})
    );
    assert_eq!(
        call("tokens.text_glyph_image_pixels", &json!({"width": 10.25, "height": 3, "scale": 2}))
            .unwrap(),
        json!({"pixels": [21, 6]})
    );
    assert_eq!(
        call("tokens.text_glyph_image_pixels", &json!({"width": 0, "height": 3, "scale": 2}))
            .unwrap(),
        json!({"pixels": null})
    );
    assert_eq!(
        call(
            "tokens.text_glyph_place",
            &json!({"width": 10, "height": 4, "scale": 2, "flippedChain": [true]})
        )
        .unwrap(),
        json!({"x": 0.0, "y": 0.0, "width": 10.0, "height": 4.0, "contentsScale": 2.0})
    );
    let c = call("tokens.text_glyph_constants", &json!({})).unwrap();
    assert_eq!(c["weightCacheLimit"], json!(512));
    assert_eq!(c["warmWeights"], json!(["regular", "medium", "semibold"]));
}
