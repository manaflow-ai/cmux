use super::*;

/// An opaque `w` by `h` picture painted by `paint(x, y) -> sRGB bytes`.
fn picture(w: usize, h: usize, paint: impl Fn(usize, usize) -> [u8; 3]) -> Vec<u8> {
    let mut out = Vec::with_capacity(w * h * 4);
    for y in 0..h {
        for x in 0..w {
            let [r, g, b] = paint(x, y);
            out.extend_from_slice(&[r, g, b, 255]);
        }
    }
    out
}

#[test]
fn rejects_bad_input() {
    assert!(light_field(&[], 0, 0, 0).is_none());
    assert!(light_field(&[0; 15], 2, 2, 8).is_none(), "buffer too short");
    assert!(light_field(&[0; 16], 2, 2, 4).is_none(), "row shorter than its pixels");
    assert!(light_field(&[0; 16], 2, 2, 8).is_none(), "fully transparent");
    let big = vec![255u8; 129 * 128 * 4];
    assert!(light_field(&big, 129, 128, 129 * 4).is_none(), "past the pixel cap");
}

#[test]
fn ambient_averages_in_linear_light() {
    // Half black, half white: the linear mean is Y 0.5, which sRGB encodes
    // as ~188, not the gamma-space mean 128.
    let px = picture(8, 8, |x, _| if x < 4 { [0, 0, 0] } else { [255, 255, 255] });
    let field = light_field(&px, 8, 8, 32).unwrap();
    assert!((field.ambient_luminance - 0.5).abs() < 1e-9);
    let encoded = (field.ambient[0] * 255.0).round();
    assert_eq!(encoded, 188.0, "the mean is encoded once, from linear");
}

#[test]
fn finds_the_bright_region_and_its_color() {
    // A dark navy sky with a warm sun at the upper right.
    let px = picture(64, 40, |x, y| {
        let d = ((x as f64 - 50.0).powi(2) + (y as f64 - 8.0).powi(2)).sqrt();
        if d < 5.0 { [255, 200, 120] } else { [12, 18, 40] }
    });
    let field = light_field(&px, 64, 40, 256).unwrap();
    assert!((field.key_x - 50.5 / 64.0).abs() < 0.04, "key_x {}", field.key_x);
    assert!((field.key_y - 8.5 / 40.0).abs() < 0.05, "key_y {}", field.key_y);
    assert!(field.key_strength > 0.8, "a sun on a night sky is strong: {}", field.key_strength);
    // The rim keeps the sun's warm hue: red over green over blue.
    assert!(field.rim[0] > field.rim[1] && field.rim[1] > field.rim[2], "rim {:?}", field.rim);
    let rim_y = luminance(field.rim.map(linear));
    assert!((rim_y - RIM_LUMINANCE).abs() < 0.01, "rim at its luminance: {rim_y}");
    assert!(field.dominant_count >= 2);
    assert!(field.dominant_weight[0] > 0.8, "the sky covers most of it");
}

/// The spread is the bright region's own extent: a small sun is narrow, a lit band
/// of sky across the top is wide (before, every picture's spread came out near 1).
#[test]
fn a_sun_spreads_less_than_a_lit_sky() {
    let sun = picture(64, 40, |x, y| {
        let d = ((x as f64 - 50.0).powi(2) + (y as f64 - 8.0).powi(2)).sqrt();
        if d < 3.0 { [255, 230, 190] } else { [12, 18, 40] }
    });
    let sky =
        picture(64, 40, |_, y| if y < 8 { [235 - 4 * y as u8, 225, 210] } else { [12, 18, 40] });
    let sun = light_field(&sun, 64, 40, 256).unwrap();
    let sky = light_field(&sky, 64, 40, 256).unwrap();
    assert!(sun.key_spread < 0.2, "a small sun is narrow: {}", sun.key_spread);
    assert!(
        sky.key_spread > 2.0 * sun.key_spread,
        "sky {} over sun {}",
        sky.key_spread,
        sun.key_spread
    );
}

#[test]
fn two_highlights_never_average_into_the_dark_between() {
    let px = picture(64, 32, |x, y| {
        let left = ((x as f64 - 8.0).powi(2) + (y as f64 - 16.0).powi(2)).sqrt() < 4.0;
        let right = ((x as f64 - 56.0).powi(2) + (y as f64 - 16.0).powi(2)).sqrt() < 3.0;
        if left || right { [250, 250, 250] } else { [20, 20, 20] }
    });
    let field = light_field(&px, 64, 32, 256).unwrap();
    let x = field.key_x * 64.0;
    assert!(!(16.0..48.0).contains(&x), "key light at a highlight, not between: {x}");
}

#[test]
fn an_even_picture_has_no_key_light() {
    let px = picture(32, 32, |_, _| [90, 120, 160]);
    let field = light_field(&px, 32, 32, 128).unwrap();
    assert!(field.key_strength < 0.01, "{}", field.key_strength);
    assert_eq!(field.dominant_count, 1);
    assert!((field.dominant_weight[0] - 1.0).abs() < 1e-9);
}

#[test]
fn same_picture_same_answer() {
    let px = picture(48, 27, |x, y| [(x * 5) as u8, (y * 9) as u8, ((x + y) * 3) as u8]);
    assert_eq!(light_field(&px, 48, 27, 192), light_field(&px, 48, 27, 192));
}

#[test]
fn premultiplied_alpha_is_unpremultiplied() {
    // A half-transparent mid red reads as mid red, not dark red.
    let px: Vec<u8> = (0..16).flat_map(|_| [64u8, 0, 0, 128]).collect();
    let field = light_field(&px, 4, 4, 16).unwrap();
    assert!((field.ambient[0] - 128.0 / 255.0).abs() < 0.01, "{:?}", field.ambient);
}

#[test]
fn bright_saturated_colors_stay_in_gamut_and_hue() {
    let blue = at_luminance([0.0, 0.0, 1.0], RIM_LUMINANCE);
    assert!(blue.iter().all(|v| (0.0..=1.0 + 1e-9).contains(v)), "{blue:?}");
    assert!((luminance(blue) - RIM_LUMINANCE).abs() < 1e-9);
    assert!(blue[2] > blue[0] && blue[2] > blue[1], "still blue: {blue:?}");
    assert_eq!(at_luminance([0.0; 3], 0.3), [0.3; 3]);
}

#[test]
fn light_point_follows_aspect_fill() {
    let field = LightField { key_x: 1.0, key_y: 0.5, ..even_field() };
    // A 2:1 picture on a square container is cropped at the sides: its
    // right edge lies half a width past the container's.
    let (x, y) = light_point(&field, 2.0, 100.0, 100.0);
    assert!((x - 150.0).abs() < 1e-9 && (y - 50.0).abs() < 1e-9, "({x}, {y})");
    // The same aspect as the container maps straight across.
    let (x, y) = light_point(&field, 1.0, 100.0, 100.0);
    assert!((x - 100.0).abs() < 1e-9 && (y - 50.0).abs() < 1e-9);
}

#[test]
fn the_rect_nearest_the_light_glows_most() {
    let field = LightField { key_strength: 1.0, key_spread: 0.2, ..even_field() };
    let near = light_rim(&field, 0.0, 0.0, 10.0, 10.0, 100.0, 100.0, 1000.0).unwrap();
    let far = light_rim(&field, 0.0, 0.0, 800.0, 500.0, 100.0, 100.0, 1000.0).unwrap();
    assert!(near.alpha > far.alpha && far.alpha > 0.0, "{} {}", near.alpha, far.alpha);
    assert!((near.center_x + 0.1).abs() < 1e-9, "light left of the rect in unit space");
    assert!(light_rim(&field, 0.0, 0.0, 0.0, 0.0, 0.0, 10.0, 100.0).is_none());
    assert!(light_rim(&field, f64::NAN, 0.0, 0.0, 0.0, 10.0, 10.0, 100.0).is_none());
}

#[test]
fn style_points_at_the_light_and_glows_more_on_dark_pictures() {
    let dark =
        LightField { key_strength: 0.8, key_spread: 0.4, ambient_luminance: 0.05, ..even_field() };
    let bright = LightField { ambient_luminance: 0.7, ..dark };
    // Light at the top right of a window at the origin.
    let style = light_style(&dark, 300.0, 0.0, 0.0, 0.0, 200.0, 200.0, 1000.0).unwrap();
    assert!(style.dx > 0.7 && style.dy < -0.3, "{style:?}");
    assert!(((style.dx * style.dx + style.dy * style.dy) - 1.0).abs() < 1e-9, "a unit direction");
    let lit = light_style(&bright, 300.0, 0.0, 0.0, 0.0, 200.0, 200.0, 1000.0).unwrap();
    assert!(style.bloom_alpha > lit.bloom_alpha && style.tint_share > lit.tint_share);
    let centered = light_style(&dark, 100.0, 100.0, 0.0, 0.0, 200.0, 200.0, 1000.0).unwrap();
    assert_eq!((centered.dx, centered.dy), (0.0, -1.0), "a light at the center lights from above");
}

fn even_field() -> LightField {
    LightField {
        ambient: [0.5; 3],
        ambient_luminance: 0.2,
        key: [1.0; 3],
        key_x: 0.5,
        key_y: 0.5,
        key_strength: 0.0,
        key_spread: 0.0,
        dominant: [[0.5; 3]; LIGHT_DOMINANT_COUNT],
        dominant_weight: [1.0, 0.0, 0.0, 0.0],
        dominant_count: 1,
        rim: [1.0; 3],
        bloom: [0.5; 3],
        tint: [0.5; 3],
    }
}
