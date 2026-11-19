use super::*;

/// A `n`x`n` RGB image of black and white: a 1 px checkerboard, or alternating rows.
pub(crate) fn pattern(n: u32, checker: bool) -> Vec<u8> {
    let mut out = Vec::with_capacity((n * n * 3) as usize);
    for y in 0..n {
        for x in 0..n {
            let on = if checker { (x + y) % 2 == 0 } else { y % 2 == 0 };
            out.extend([if on { 255 } else { 0 }; 3]);
        }
    }
    out
}

#[test]
fn every_srgb_code_survives_the_round_trip() {
    for code in 0..=255u8 {
        assert_eq!(to_srgb(to_linear(code)), code, "code {code}");
    }
    assert_eq!((to_linear(0), to_linear(255)), (0, 65535));
    assert_eq!((to_srgb(0), to_srgb(65535)), (0, 255));
}

/// The detector for the class: averaging sRGB code values gives 127 or 128 here, half
/// the light gives 188 ("What every coder should know about gamma").
#[test]
fn black_and_white_detail_averages_to_half_the_light_not_half_the_code() {
    for checker in [true, false] {
        for factor in [2u32, 4, 8] {
            let n = 96;
            let out = downscale(&pattern(n, checker), 3, n, n, n / factor, n / factor);
            assert_eq!(out.len(), ((n / factor) * (n / factor) * 3) as usize);
            for v in out {
                assert!((187..=188).contains(&v), "checker {checker} {factor}x gave {v}");
            }
        }
    }
}

#[test]
fn flat_colours_and_hard_edges_stay_exact() {
    // Every code, flat, comes back as itself.
    for code in 0..=255u8 {
        let px = [code, 255 - code, code / 2];
        let src: Vec<u8> = px.iter().copied().cycle().take(8 * 8 * 3).collect();
        let out = downscale(&src, 3, 8, 8, 3, 3);
        assert!(out.chunks_exact(3).all(|p| p == px), "{px:?} -> {out:?}");
    }
    // Left half red, right half blue: the edges keep their colour.
    let (w, h) = (40, 30);
    let src: Vec<u8> =
        (0..w * h).flat_map(|i| if i % w < w / 2 { [255, 0, 0] } else { [0, 0, 255] }).collect();
    let out = downscale(&src, 3, w, h, 15, 11);
    assert_eq!(&out[..3], &[255, 0, 0]);
    assert_eq!(&out[out.len() - 3..], &[0, 0, 255]);
}

#[test]
fn a_transparent_pixel_does_not_tint_the_opaque_one_it_is_averaged_with() {
    let out = downscale(&[255, 0, 0, 255, 0, 0, 255, 0], 4, 2, 1, 1, 1);
    assert_eq!(out, [255, 0, 0, 127]);
    // All transparent: transparent black.
    assert_eq!(downscale(&[9, 9, 9, 0, 9, 9, 9, 0], 4, 2, 1, 1, 1), [0, 0, 0, 0]);
}

#[test]
fn a_fractional_ratio_weighs_each_input_pixel_by_the_area_it_covers() {
    // Three columns, black, white, black, into two: each output pixel is two thirds
    // black and one third white, in light.
    let src = [0, 0, 0, 255, 255, 255, 0, 0, 0];
    let want = to_srgb(65535 / 3);
    assert_eq!(downscale(&src, 3, 3, 1, 2, 1), [want, want, want, want, want, want]);
}

#[test]
fn sizes_fit_the_edge_and_never_grow() {
    assert_eq!(fit(4000, 3000, 1568), (1568, 1176));
    assert_eq!(fit(640, 480, 1568), (640, 480));
    assert_eq!(fit(10_000, 1, 100), (100, 1));
    let scaler = Downscaler::new(10, 10, 20, 0, false);
    assert_eq!(scaler.output_size(), (10, 1));
}
