//! Damage and cuts from a recording's frames (no signal trace), and the
//! pure parts of the cutter: aspects, the YUV4MPEG2 header, fitting a
//! trace to the video, cropping a plane.

use cmux_follow_cam::damage::{DamageConfig, FrameDiff, thumbnail};
use cmux_follow_cam::video::{Aspect, Y4mHeader, crop_plane, fit_trace};
use cmux_follow_cam::{Camera, Config, Event, Rect, STEP_US, Signal, read_trace};

/// Thumbnails 320x180 of a 2560x1440 screen: 8 screen pixels a pixel.
const W: usize = 320;
const H: usize = 180;
const SCALE: (f64, f64) = (8.0, 8.0);

fn blank() -> Vec<u8> {
    vec![30; W * H]
}

/// `frame` with a bright box at (x, y), w x h thumbnail pixels.
fn with_box(frame: &[u8], x: usize, y: usize, w: usize, h: usize) -> Vec<u8> {
    let mut out = frame.to_vec();
    for row in y..y + h {
        for col in x..x + w {
            out[row * W + col] = 220;
        }
    }
    out
}

fn damage_rects(signals: &[Signal]) -> Vec<Rect> {
    signals
        .iter()
        .filter_map(|s| match *s {
            Signal::Damage { x, y, w, h } => Some(Rect::new(x, y, w, h)),
            _ => None,
        })
        .collect()
}

fn contains(outer: &Rect, inner: &Rect) -> bool {
    outer.x <= inner.x
        && outer.y <= inner.y
        && outer.x + outer.w >= inner.x + inner.w
        && outer.y + outer.h >= inner.y + inner.h
}

#[test]
fn the_first_frame_and_a_still_frame_say_nothing() {
    let mut diff = FrameDiff::new(DamageConfig::default(), W, H);
    assert!(diff.push(&blank(), SCALE).is_empty());
    assert!(diff.push(&blank(), SCALE).is_empty());
}

#[test]
fn compression_noise_is_not_damage() {
    let mut diff = FrameDiff::new(DamageConfig::default(), W, H);
    diff.push(&blank(), SCALE);
    let noisy: Vec<u8> = (0..W * H).map(|i| 30 + (i % 7) as u8).collect();
    assert!(diff.push(&noisy, SCALE).is_empty());
}

#[test]
fn a_typed_character_is_damage_where_it_was_typed_in_screen_pixels() {
    let mut diff = FrameDiff::new(DamageConfig::default(), W, H);
    let first = blank();
    diff.push(&first, SCALE);
    // A character 3x5 thumbnail pixels at (201, 52): 24x40 on the screen.
    let signals = diff.push(&with_box(&first, 201, 52, 3, 5), SCALE);
    let rects = damage_rects(&signals);
    assert_eq!(rects.len(), 1, "{signals:?}");
    let typed = Rect::new(201.0 * 8.0, 52.0 * 8.0, 24.0, 40.0);
    assert!(contains(&rects[0], &typed), "{:?} does not cover {typed:?}", rects[0]);
    // The grain is a block: the rect is at most a couple of blocks around it.
    assert!(rects[0].w <= 2.0 * 8.0 * 8.0 && rects[0].h <= 2.0 * 8.0 * 8.0, "{:?}", rects[0]);
    assert!(!signals.contains(&Signal::Cut));
}

#[test]
fn two_far_apart_changes_are_two_rects() {
    let mut diff = FrameDiff::new(DamageConfig::default(), W, H);
    let first = blank();
    diff.push(&first, SCALE);
    let next = with_box(&with_box(&first, 10, 10, 4, 4), 290, 150, 4, 4);
    let rects = damage_rects(&diff.push(&next, SCALE));
    assert_eq!(rects.len(), 2, "{rects:?}");
}

#[test]
fn a_line_of_typing_is_one_rect_not_one_per_block() {
    let mut diff = FrameDiff::new(DamageConfig::default(), W, H);
    let first = blank();
    diff.push(&first, SCALE);
    let rects = damage_rects(&diff.push(&with_box(&first, 20, 100, 120, 5), SCALE));
    assert_eq!(rects.len(), 1, "{rects:?}");
}

#[test]
fn a_scene_change_is_a_cut_and_no_damage() {
    let mut diff = FrameDiff::new(DamageConfig::default(), W, H);
    diff.push(&blank(), SCALE);
    let other: Vec<u8> = (0..W * H).map(|i| if (i / W) % 2 == 0 { 200 } else { 120 }).collect();
    let signals = diff.push(&other, SCALE);
    assert_eq!(signals, vec![Signal::Cut]);
    // The frame after the cut compares with the new scene.
    assert!(diff.push(&other, SCALE).is_empty());
}

#[test]
fn a_thumbnail_averages_the_area_each_pixel_covers() {
    // 8x4 luma: left half 0, right half 200.
    let luma: Vec<u8> = (0..32).map(|i| if i % 8 < 4 { 0 } else { 200 }).collect();
    let (small, h) = thumbnail(&luma, 8, 4, 2);
    assert_eq!(h, 1);
    assert_eq!(small, vec![0, 200]);
    let (half, h) = thumbnail(&luma, 8, 4, 4);
    assert_eq!(h, 2);
    assert_eq!(half, vec![0, 0, 200, 200, 0, 0, 200, 200]);
}

/// Typing on a line at the right of the screen, seen only through the
/// frames: the camera ends up framing the typing.
#[test]
fn a_recording_without_a_trace_gets_a_camera_that_follows_the_typing() {
    let mut diff = FrameDiff::new(DamageConfig::default(), W, H);
    let config = Config::default();
    let mut camera = Camera::new(config, 2560.0, 1440.0);
    let mut frame = blank();
    let fps = 30;
    let mut last = camera.advance(0);
    for i in 0..(fps * 3) {
        let t = i as u64 * 1_000_000 / fps as u64;
        // A character every other frame, from x = 250 rightward on y = 120.
        if i % 2 == 0 && i > 0 {
            let col = 250 + (i as usize / 2) % 60;
            frame = with_box(&frame, col.min(W - 2), 120, 1, 4);
        }
        for signal in diff.push(&frame, SCALE) {
            camera.push(Event { t_us: t, signal });
        }
        last = camera.advance(t);
    }
    let typing_x = 250.0 * 8.0;
    assert!(
        last.x <= typing_x && typing_x <= last.x + last.w,
        "crop {last:?} does not frame the typing at x {typing_x}"
    );
    assert!(last.x > 0.0, "the camera never moved: {last:?}");
    let _ = STEP_US;
}

#[test]
fn aspects_parse_and_size_even_outputs() {
    assert_eq!("9:16".parse::<Aspect>(), Ok(Aspect::Tall));
    assert_eq!("4:5".parse::<Aspect>(), Ok(Aspect::Portrait));
    assert_eq!("1:1".parse::<Aspect>(), Ok(Aspect::Square));
    assert!("16:9".parse::<Aspect>().is_err());
    assert!((Aspect::Tall.ratio() - 9.0 / 16.0).abs() < 1e-9);
    assert_eq!(Aspect::Tall.output_size(1080), (1080, 1920));
    assert_eq!(Aspect::Portrait.output_size(1080), (1080, 1350));
    assert_eq!(Aspect::Square.output_size(1080), (1080, 1080));
    assert_eq!(Aspect::Tall.output_size(721), (720, 1280));
}

#[test]
fn a_y4m_header_gives_size_rate_and_frame_bytes() {
    let header = Y4mHeader::parse("YUV4MPEG2 W1920 H1080 F30000:1001 Ip A1:1 C444").unwrap();
    assert_eq!((header.w, header.h, header.fps_num, header.fps_den), (1920, 1080, 30000, 1001));
    assert_eq!(header.frame_bytes(), Ok(1920 * 1080 * 3));
    let default = Y4mHeader::parse("YUV4MPEG2 W4 H2 F30:1").unwrap();
    assert_eq!(default.chroma, "420jpeg");
    assert_eq!(default.frame_bytes(), Ok(8 + 2 + 2));
    assert!(Y4mHeader::parse("RIFF").is_err());
    assert!(Y4mHeader::parse("YUV4MPEG2 W4 F30:1").is_err());
}

#[test]
fn a_trace_from_a_retina_screen_is_scaled_to_the_video() {
    let trace = read_trace(
        "{\"t_us\":0,\"kind\":\"source\",\"w\":1440,\"h\":900}\n\
         {\"t_us\":10,\"kind\":\"caret\",\"x\":100,\"y\":50,\"w\":2,\"h\":20}\n\
         {\"t_us\":20,\"kind\":\"cut\"}\n",
    )
    .unwrap();
    let fitted = fit_trace(&trace, 2880.0, 1800.0);
    assert_eq!(
        fitted,
        vec![
            Event { t_us: 10, signal: Signal::Caret { x: 200.0, y: 100.0, w: 4.0, h: 40.0 } },
            Event { t_us: 20, signal: Signal::Cut },
        ]
    );
    // A trace with no source is in the video's pixels already.
    let plain = read_trace("{\"t_us\":5,\"kind\":\"pointer\",\"x\":7,\"y\":9}").unwrap();
    assert_eq!(fit_trace(&plain, 2880.0, 1800.0), plain);
}

#[test]
fn crop_plane_takes_the_rect_and_scales_it() {
    // 4x2 plane, columns 0 10 20 30.
    let src = [0, 10, 20, 30, 0, 10, 20, 30];
    let mut out = [0u8; 2];
    crop_plane(&src, 4, 2, Rect::new(2.0, 0.0, 2.0, 2.0), &mut out, 2, 1);
    // Bilinear at pixel centres: the crop's columns are 20 and 30, and a 2x
    // shrink in y averages the same values.
    assert!(out[0] >= 20 && out[0] <= 25 && out[1] >= 25 && out[1] <= 30, "{out:?}");
    let mut same = [0u8; 8];
    crop_plane(&src, 4, 2, Rect::new(0.0, 0.0, 4.0, 2.0), &mut same, 4, 2);
    assert_eq!(same, src);
}
