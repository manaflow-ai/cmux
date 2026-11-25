use super::*;

fn picture(width: usize, height: usize, counter: u32, phase: u32) -> (Vec<u8>, Vec<u8>) {
    // Strides wider than the picture, as an IOSurface's are.
    let (y_stride, uv_stride) = (width + 64, width + 64);
    let mut y = vec![0xAA; y_stride * height];
    let mut uv = vec![0xAA; uv_stride * height / 2];
    paint(&mut Nv12 { y: &mut y, y_stride, uv: &mut uv, uv_stride, width, height }, counter, phase);
    (y, uv)
}

#[test]
fn the_marker_reads_back_with_the_bench_decoder() {
    for counter in [0u32, 1, 2, 0x1234, 0xffff, 0x1_0005] {
        let (y, _) = picture(1280, 720, counter, 0);
        let read = crate::marker::decode_luma_at(&y, 1280 + 64, true, (0, 0));
        assert_eq!(read, Some((counter & 0xffff) as u16), "counter {counter:#x}");
    }
}

#[test]
fn the_bars_move_and_the_marker_does_not() {
    let (a, _) = picture(1280, 720, 7, phase(0));
    let (b, _) = picture(1280, 720, 7, phase(1));
    let stride = 1280 + 64;
    // The marker rows are the same; the bars below the band moved.
    assert_eq!(a[..CELL as usize * stride], b[..CELL as usize * stride]);
    let row = 200 * stride;
    assert_ne!(a[row..row + 1280], b[row..row + 1280]);
    // Every pixel was written (no 0xAA left inside the picture).
    for r in 0..720 {
        assert!(a[r * stride..r * stride + 1280].iter().all(|&v| v != 0xAA), "row {r}");
    }
}

#[test]
fn key_button_and_scroll_presses_bump_and_releases_do_not() {
    assert!(bumps(&InputEvent::Key { usage: 4, down: true }));
    assert!(!bumps(&InputEvent::Key { usage: 4, down: false }));
    assert!(bumps(&InputEvent::Button { button: 0, down: true }));
    assert!(!bumps(&InputEvent::Button { button: 0, down: false }));
    assert!(bumps(&InputEvent::Scroll { dx: 0, dy: -100, precise: false }));
    assert!(!bumps(&InputEvent::Pointer { x: 3, y: 4 }));
    assert!(!bumps(&InputEvent::Text("a".into())));
}

#[test]
fn source_words_and_sizes_parse() {
    assert_eq!(parse(None, None, None), Ok(None));
    assert_eq!(parse(Some("screen"), None, None), Ok(None));
    assert!(parse(Some("screen"), Some("1280x720"), None).is_err());
    assert!(parse(Some("screen"), None, Some("text")).is_err());
    assert_eq!(
        parse(Some("synthetic"), None, None),
        Ok(Some(Synthetic { motion: Motion::Moving, scene: Scene::Bars, size: DEFAULT_SIZE }))
    );
    assert_eq!(
        parse(Some("synthetic-tick"), Some("1280x720"), Some("text")),
        Ok(Some(Synthetic { motion: Motion::Tick, scene: Scene::Text, size: (1280, 720) }))
    );
    assert_eq!(
        parse(Some("synthetic-still"), None, Some("noise")).map(|s| s.map(|s| (s.motion, s.scene))),
        Ok(Some((Motion::Still, Scene::Noise)))
    );
    for bad in ["1280", "1281x720", "320x240", "axb", "9000x720"] {
        assert!(parse(Some("synthetic"), Some(bad), None).is_err(), "{bad}");
    }
    assert!(parse(Some("camera"), None, None).is_err());
    assert!(parse(Some("synthetic"), None, Some("video")).is_err());
    assert_eq!(
        parse(Some("synthetic"), None, Some("churn")).map(|s| s.map(|s| s.scene)),
        Ok(Some(Scene::Churn))
    );
}

fn scene_picture(painter: &Painter, w: usize, h: usize, counter: u32, ph: u32) -> Vec<u8> {
    let stride = w + 64;
    // Painted over two different fills: every pixel inside the picture, luma and chroma,
    // must come out the same (any byte left unwritten shows its fill).
    let [(ya, uva), (yb, uvb)] = [0x00u8, 0xffu8].map(|fill| {
        let (mut y, mut uv) = (vec![fill; stride * h], vec![fill; stride * h / 2]);
        painter.paint(
            &mut Nv12 {
                y: &mut y,
                y_stride: stride,
                uv: &mut uv,
                uv_stride: stride,
                width: w,
                height: h,
            },
            counter,
            ph,
        );
        (y, uv)
    });
    for r in 0..h {
        assert_eq!(ya[r * stride..r * stride + w], yb[r * stride..r * stride + w], "y row {r}");
    }
    for r in 0..h / 2 {
        assert_eq!(uva[r * stride..r * stride + w], uvb[r * stride..r * stride + w], "uv row {r}");
    }
    ya
}

#[test]
fn every_scene_carries_the_marker_and_moves_under_it() {
    let (w, h, stride) = (1280, 720, 1280 + 64);
    for scene in [Scene::Bars, Scene::Text, Scene::Noise, Scene::Churn] {
        let painter = Painter::new(scene, w, h);
        let a = scene_picture(&painter, w, h, 0x2a5, phase(0));
        let b = scene_picture(&painter, w, h, 0x2a5, phase(1));
        assert_eq!(crate::marker::decode_luma_at(&a, stride, true, (0, 0)), Some(0x2a5));
        assert_eq!(a[..BAND_ROWS * stride], b[..BAND_ROWS * stride], "{scene:?} band");
        assert_ne!(a[BAND_ROWS * stride..], b[BAND_ROWS * stride..], "{scene:?} moved");
    }
}

#[test]
fn text_scrolls_up_four_rows_a_frame_and_noise_slides_eight_columns() {
    let (w, h, stride) = (1280, 720, 1280 + 64);
    let text = Painter::new(Scene::Text, w, h);
    let (a, b) = (scene_picture(&text, w, h, 0, phase(0)), scene_picture(&text, w, h, 0, phase(1)));
    for r in [BAND_ROWS, 300, h - 5] {
        assert_eq!(b[r * stride..r * stride + w], a[(r + 4) * stride..(r + 4) * stride + w]);
    }
    let noise = Painter::new(Scene::Noise, w, h);
    let (a, b) =
        (scene_picture(&noise, w, h, 0, phase(0)), scene_picture(&noise, w, h, 0, phase(1)));
    let r = 400 * stride;
    assert_eq!(b[r..r + w - 8], a[r + 8..r + w]);
}

#[test]
fn text_and_noise_are_dense_and_bars_are_not() {
    // Luma steps along a row: what makes a scene costly to encode.
    let (w, h, stride) = (1920, 1080, 1920 + 64);
    let steps = |scene| {
        let y = scene_picture(&Painter::new(scene, w, h), w, h, 0, 0);
        (BAND_ROWS..h)
            .map(|r| y[r * stride..r * stride + w].windows(2).filter(|p| p[0] != p[1]).count())
            .sum::<usize>()
    };
    let (bars, text, noise) = (steps(Scene::Bars), steps(Scene::Text), steps(Scene::Noise));
    assert!(bars < (h - BAND_ROWS) * 50, "bars {bars}");
    // Measured at 1920x1080: bars 39 624, text 118 324.
    assert!(text > bars * 2, "text {text} vs bars {bars}");
    assert!(noise > bars * 20, "noise {noise} vs bars {bars}");
}

#[test]
fn max_width_fits_keeping_the_aspect_and_the_marker() {
    assert_eq!(fit((1920, 1080), None), (1920, 1080));
    assert_eq!(fit((1920, 1080), Some(2560)), (1920, 1080));
    assert_eq!(fit((1920, 1080), Some(1280)), (1280, 720));
    assert_eq!(fit((1920, 1080), Some(100)), (640, 360));
}

#[test]
fn the_ticker_keeps_its_schedule_and_never_bursts_after_a_stall() {
    let interval = Duration::from_micros(16_667);
    let t0 = Instant::now();
    // A late wake keeps the schedule: the next deadline is one interval after the last.
    let late = t0 + Duration::from_millis(3);
    assert_eq!(next_tick(t0, interval, late), t0 + interval);
    // A stall past the next deadline starts over from now, with no catch-up frames.
    let stalled = t0 + Duration::from_millis(100);
    assert_eq!(next_tick(t0, interval, stalled), stalled + interval);
    // Sixty steps on time land sixty intervals out.
    let mut d = t0;
    for _ in 0..60 {
        d = next_tick(d, interval, d);
    }
    assert_eq!(d, t0 + interval * 60);
    // sleep_until returns at or after its deadline, and at once for a past one.
    let target = Instant::now() + Duration::from_millis(5);
    sleep_until(target);
    assert!(Instant::now() >= target);
    let before = Instant::now();
    sleep_until(before - Duration::from_millis(1));
    assert!(before.elapsed() < Duration::from_millis(50));
}
