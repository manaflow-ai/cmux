use super::*;

/// A `w`x`h` RGB PNG: left half red, right half blue.
fn halves(w: u32, h: u32) -> Vec<u8> {
    let mut data = Vec::with_capacity((w * h * 3) as usize);
    for _ in 0..h {
        for x in 0..w {
            data.extend(if x < w / 2 { [255, 0, 0] } else { [0, 0, 255] });
        }
    }
    let mut out = Vec::new();
    let mut e = png::Encoder::new(&mut out, w, h);
    e.set_color(png::ColorType::Rgb);
    e.set_depth(png::BitDepth::Eight);
    e.write_header().unwrap().write_image_data(&data).unwrap();
    out
}

fn pixels(png_bytes: &[u8]) -> (u32, u32, Vec<u8>) {
    let mut reader = png::Decoder::new(std::io::Cursor::new(png_bytes)).read_info().unwrap();
    let mut buf = vec![0; reader.output_buffer_size()];
    let info = reader.next_frame(&mut buf).unwrap();
    buf.truncate(info.buffer_size());
    (info.width, info.height, buf)
}

#[test]
fn each_harness_gets_its_models_edge() {
    assert_eq!(limits(Some("claude")).max_edge, 1568);
    assert_eq!(limits(Some("codex")).max_edge, 2048);
    assert_eq!(limits(Some("opencode")), limits(Some("claude")));
    assert_eq!(limits(None).max_bytes, crate::prompt_uploads::INLINE_IMAGE_BYTES);
}

#[test]
fn a_large_png_is_scaled_to_the_edge_keeping_its_shape_and_colours() {
    let (bytes, w, h) = downscale(std::io::Cursor::new(halves(4000, 3000)), 1568).unwrap();
    assert_eq!((w, h), (1568, 1176));
    let (pw, ph, px) = pixels(&bytes);
    assert_eq!((pw, ph), (w, h));
    // The left edge is red and the right edge blue, as in the original.
    assert_eq!(&px[..3], &[255, 0, 0]);
    let last = px.len() - 3;
    assert_eq!(&px[last..], &[0, 0, 255]);
}

/// A `n`x`n` grey PNG of 1 px black and white: a checkerboard, or alternating rows.
fn black_and_white(n: u32, checker: bool) -> Vec<u8> {
    let data: Vec<u8> = (0..n * n)
        .map(|i| {
            let (x, y) = (i % n, i / n);
            let on = if checker { (x + y) % 2 == 0 } else { y % 2 == 0 };
            if on { 255 } else { 0 }
        })
        .collect();
    let mut out = Vec::new();
    let mut e = png::Encoder::new(&mut out, n, n);
    e.set_color(png::ColorType::Grayscale);
    e.set_depth(png::BitDepth::Eight);
    e.write_header().unwrap().write_image_data(&data).unwrap();
    out
}

/// Fine black and white detail (text, thin lines in a screenshot) keeps its light: half
/// black, half white is 188, not the 127 an average of sRGB codes gives
/// ("What every coder should know about gamma").
#[test]
fn a_model_copy_averages_light_not_srgb_codes() {
    for checker in [true, false] {
        for edge in [256, 128] {
            let (bytes, w, h) =
                downscale(std::io::Cursor::new(black_and_white(512, checker)), edge).unwrap();
            assert_eq!((w, h), (edge, edge));
            let px = pixels(&bytes).2;
            let off: Vec<u8> =
                px.iter().copied().filter(|v| !(187..=188).contains(v)).take(4).collect();
            assert!(off.is_empty(), "checker {checker} edge {edge}: {off:?}");
        }
    }
}

#[test]
fn a_png_too_large_to_decode_quickly_gets_no_copy() {
    assert!(copyable(8000, 8000) && copyable(10_000, 10_000));
    assert!(!copyable(20_000, 10_000) && !copyable(100_000, 100_000));
    assert!(!copyable(0, 10) && !copyable(10, 0));
}

/// A 2x1 PNG of `color` from `data`, with `palette` and `trns` when given.
fn two_pixels(color: png::ColorType, data: &[u8], palette: Option<(&[u8], &[u8])>) -> Vec<u8> {
    let mut out = Vec::new();
    let mut e = png::Encoder::new(&mut out, 2, 1);
    e.set_color(color);
    e.set_depth(png::BitDepth::Eight);
    if let Some((plte, trns)) = palette {
        e.set_palette(plte.to_vec());
        e.set_trns(trns.to_vec());
    }
    e.write_header().unwrap().write_image_data(data).unwrap();
    out
}

#[test]
fn a_transparent_pixel_does_not_tint_the_opaque_one_it_is_averaged_with() {
    // Opaque red and fully transparent blue: red, half covered (not translucent purple).
    let rgba = two_pixels(png::ColorType::Rgba, &[255, 0, 0, 255, 0, 0, 255, 0], None);
    // White and transparent black, as grey with alpha.
    let grey = two_pixels(png::ColorType::GrayscaleAlpha, &[255, 255, 0, 0], None);
    // The same red and blue from a palette whose blue is transparent (tRNS).
    let plte: &[u8] = &[255, 0, 0, 0, 0, 255];
    let indexed = two_pixels(png::ColorType::Indexed, &[0, 1], Some((plte, &[255, 0])));
    for (png_bytes, want) in
        [(rgba, [255, 0, 0, 127]), (grey, [255, 255, 255, 127]), (indexed, [255, 0, 0, 127])]
    {
        let (bytes, w, h) = downscale(std::io::Cursor::new(png_bytes), 1).unwrap();
        assert_eq!((w, h), (1, 1));
        assert_eq!(pixels(&bytes).2, want);
    }
}

#[test]
fn a_copys_base64_is_left_out_of_the_log_in_any_shape() {
    let (bytes, _, _) = downscale(std::io::Cursor::new(halves(4000, 3000)), 1568).unwrap();
    let data = base64::engine::general_purpose::STANDARD.encode(&bytes);
    // Another PNG, a screenshot sent inline, is logged as it was.
    let other = base64::engine::general_purpose::STANDARD.encode(halves(64, 64));
    let mut acp = json!({"method": "session/prompt", "params": {"prompt": [
        {"type": "image", "mimeType": "image/png", "data": data},
        {"type": "image", "mimeType": "image/png", "data": other},
    ]}});
    let mut claude = json!({"type": "user", "message": {"content": [
        {"type": "image", "source": {"type": "base64", "data": data}},
    ]}});
    scrub_logged(&mut acp);
    scrub_logged(&mut claude);
    assert_eq!(acp["params"]["prompt"][0]["data"], OMITTED);
    assert_eq!(acp["params"]["prompt"][1]["data"], other);
    assert_eq!(claude["message"]["content"][0]["source"]["data"], OMITTED);
    assert!(!is_copy("iVBORw0KGgo") && !is_copy("not base64 at all, long enough to be read"));
}

#[test]
fn a_png_within_the_edge_is_never_scaled_up() {
    let (_, w, h) = downscale(std::io::Cursor::new(halves(640, 480)), 1568).unwrap();
    assert_eq!((w, h), (640, 480));
    assert!(downscale(std::io::Cursor::new(b"not a png".to_vec()), 1568).is_none());
}

/// A model-sized copy saved beside its upload (#41372 review F5): held past its home check
/// and the home replaced, the copy lands in the held home and the new one gets nothing.
#[cfg(unix)]
#[test]
fn a_model_copy_save_held_past_its_check() {
    use crate::lost_home_race_tests::{forced, isolated, nothing};
    isolated(
        module_path!(),
        "a_model_copy_save_held_past_its_check",
        |home| {
            let dir = home.join("uploads").join("chat-a").join(uuid::Uuid::now_v7().to_string());
            std::fs::create_dir_all(&dir).unwrap();
            let saved = dir.join(".model-1568.png");
            let kept = saved.strip_prefix(home).unwrap().to_string_lossy().into_owned();
            let target = saved.clone();
            forced(home, target, nothing, Some(&kept), move || save(&saved, b"png bytes"));
        },
        |_, _| {},
    );
}
