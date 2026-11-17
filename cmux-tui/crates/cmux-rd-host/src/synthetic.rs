//! `--source synthetic` (bench builds, macOS host): a generated picture instead of the display,
//! so transport, encoder and controller runs need no Screen Recording or Accessibility grant.
//! The picture is NV12 with the glass-to-glass marker (marker.rs: 20 cells of 32x32 px at the
//! top-left, the counter LSB first, then the guard 1,0,1,0) over moving bars. A viewer's key
//! press, click or scroll bumps the marker counter instead of reaching the system, so
//! `cmux-rd bench --input key` measures key-to-frame exactly as with the marker app. The
//! macOS half (`mac/synthetic.rs`) paints into IOSurfaces and feeds them to the same
//! VideoToolbox session and send path as captured frames.
//!
//!   synthetic        bars move every frame (at the frame rate cap); input bumps the counter
//!   synthetic-still  nothing moves; a frame goes out only when input bumps the counter
//!   synthetic-tick   bars move and the counter also counts every frame (the fps probe, as
//!                    the marker app's `--tick --motion`)
//!
//! `--synthetic-scene` picks what is under the marker. Flat bars compress to almost nothing, so
//! the encoder spends far below any target; the harder scenes make it spend:
//!
//!   bars   flat bars moving 8 px a frame (the default)
//!   text   dense pseudo-text, 8x16 glyph cells with tinted tokens, scrolling up 4 px a frame
//!   noise  the bars with per-pixel grain baked in, moving 8 px a frame
//!   churn  the same grain at a new random offset every frame: no motion search finds it, so
//!          every frame is new content (text and noise only translate, which an encoder
//!          predicts almost for free: on a fleet Mac both spent 2-3 Mbps under a 40 Mbps target)
// Only the macOS host streams it; elsewhere `--source synthetic` is refused and the generator
// runs in tests.
#![cfg_attr(not(target_os = "macos"), allow(dead_code))]

use crate::args::Opts;
use crate::marker::{cells, CELL, CELLS};
use cmux_rd_proto::InputEvent;
use std::sync::OnceLock;
use std::time::{Duration, Instant};

/// The default picture size (`--synthetic-size WxH` changes it; `--max-width` fits it).
pub const DEFAULT_SIZE: (u32, u32) = (1920, 1080);
/// Rows above the bars: the marker's row and a quiet band under it.
pub const BAND_ROWS: usize = 2 * CELL as usize;
/// The bars' width and how far they move each frame, in pixels.
const BAR: usize = 48;
const STEP: u32 = 8;
/// Video-range luma for a white and a black marker cell, the band, and neutral chroma.
const WHITE: u8 = 235;
const BLACK: u8 = 16;
const BAND: u8 = 96;
const NEUTRAL: u8 = 128;

/// How the synthetic picture moves and what bumps its counter.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Motion {
    Moving,
    Still,
    Tick,
}

/// What the picture shows under the marker.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Scene {
    Bars,
    Text,
    Noise,
    Churn,
}

/// The synthetic source of a host process.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Synthetic {
    pub motion: Motion,
    pub scene: Scene,
    pub size: (u32, u32),
}

static SELECTED: OnceLock<Synthetic> = OnceLock::new();

/// The synthetic source `--source` picked for this process, if any.
pub fn selected() -> Option<Synthetic> {
    SELECTED.get().copied()
}

/// Reads `--source` (and `--synthetic-size`, `--synthetic-scene`) for `host` and `serve`.
/// `screen` (the default) captures the display; the synthetic words need a macOS host, which
/// encodes the generated surfaces with VideoToolbox.
pub fn configure(opts: &Opts) -> Result<(), String> {
    let Some(source) =
        parse(opts.get("source"), opts.get("synthetic-size"), opts.get("synthetic-scene"))?
    else {
        return Ok(());
    };
    if !cfg!(target_os = "macos") {
        return Err(
            "--source synthetic needs a macOS host (it encodes IOSurfaces with VideoToolbox)"
                .into(),
        );
    }
    let _ = SELECTED.set(source);
    eprintln!(
        "cmux-rd: measurement only: --source {} streams a generated {}x{} {:?} picture, and viewer input bumps its marker instead of reaching this Mac",
        name(source.motion),
        source.size.0,
        source.size.1,
        source.scene
    );
    Ok(())
}

fn name(motion: Motion) -> &'static str {
    match motion {
        Motion::Moving => "synthetic",
        Motion::Still => "synthetic-still",
        Motion::Tick => "synthetic-tick",
    }
}

/// `--source`, `--synthetic-size` and `--synthetic-scene` as a synthetic source; None for the
/// display.
pub fn parse(
    source: Option<&str>,
    size: Option<&str>,
    scene: Option<&str>,
) -> Result<Option<Synthetic>, String> {
    let motion = match source.map(str::trim) {
        None | Some("screen") => {
            return match (size, scene) {
                (Some(_), _) => Err("--synthetic-size needs --source synthetic".into()),
                (_, Some(_)) => Err("--synthetic-scene needs --source synthetic".into()),
                (None, None) => Ok(None),
            }
        }
        Some("synthetic") => Motion::Moving,
        Some("synthetic-still") => Motion::Still,
        Some("synthetic-tick") => Motion::Tick,
        Some(other) => {
            return Err(format!(
                "--source {other}: use screen, synthetic, synthetic-still or synthetic-tick"
            ))
        }
    };
    let size = match size {
        None => DEFAULT_SIZE,
        Some(text) => {
            let bad = || {
                format!("--synthetic-size {text}: WIDTHxHEIGHT in pixels, even, at least 640x96")
            };
            let (w, h) = text.split_once('x').ok_or_else(bad)?;
            let (w, h) =
                (w.parse::<u32>().map_err(|_| bad())?, h.parse::<u32>().map_err(|_| bad())?);
            if w < MIN_SIZE.0
                || h < MIN_SIZE.1
                || !w.is_multiple_of(2)
                || !h.is_multiple_of(2)
                || w > 7680
                || h > 4320
            {
                return Err(bad());
            }
            (w, h)
        }
    };
    let scene = match scene.map(str::trim) {
        None | Some("bars") => Scene::Bars,
        Some("text") => Scene::Text,
        Some("noise") => Scene::Noise,
        Some("churn") => Scene::Churn,
        Some(other) => {
            return Err(format!("--synthetic-scene {other}: use bars, text, noise or churn"))
        }
    };
    Ok(Some(Synthetic { motion, scene, size }))
}

/// The marker row and a band of bars under it.
const MIN_SIZE: (u32, u32) = (CELLS as u32 * CELL, BAND_ROWS as u32 + CELL);

/// `size` fitted to `max_width` (the viewer's or `--max-width`), keeping its aspect; even, and
/// never narrower than the marker.
pub fn fit(size: (u32, u32), max_width: Option<u32>) -> (u32, u32) {
    let Some(limit) = max_width.filter(|&w| w < size.0) else { return size };
    let width = limit.max(MIN_SIZE.0) & !1;
    let height =
        ((u64::from(size.1) * u64::from(width) / u64::from(size.0)) as u32).max(MIN_SIZE.1) & !1;
    (width, height)
}

/// Whether a viewer event bumps the marker counter: a key press, a button press or a scroll,
/// as the marker app counts them. Releases, moves and text do not.
pub fn bumps(event: &InputEvent) -> bool {
    match event {
        InputEvent::Key { down, .. } | InputEvent::Button { down, .. } => *down,
        InputEvent::Scroll { .. } => true,
        _ => false,
    }
}

/// The longest single sleep of the ticker. macOS gives a process started over ssh about 50%
/// timer leeway, so one `sleep(16.7 ms)` returned after 25.0 ms on a fleet Mac and the 60 fps
/// ticker ran at 40; sleeps of at most 2 ms toward an absolute deadline held 60.0 fps there
/// (gap p95 17.0 ms).
const TICK_STEP: Duration = Duration::from_millis(2);

/// Sleeps until `deadline` in steps of at most [`TICK_STEP`].
pub fn sleep_until(deadline: Instant) {
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return;
        }
        std::thread::sleep(left.min(TICK_STEP));
    }
}

/// The ticker's next deadline: one interval after the last, so late wakes do not drift the
/// rate; but never in the past, so a stall is not followed by a burst of catch-up frames.
pub fn next_tick(last: Instant, interval: Duration, now: Instant) -> Instant {
    let next = last + interval;
    if next > now {
        next
    } else {
        now + interval
    }
}

/// How far the bars have moved after `frame` moving frames.
pub fn phase(frame: u64) -> u32 {
    (frame as u32).wrapping_mul(STEP)
}

/// One NV12 picture's planes: luma (`width` x `height`) and interleaved CbCr at half size.
pub struct Nv12<'a> {
    pub y: &'a mut [u8],
    pub y_stride: usize,
    pub uv: &'a mut [u8],
    pub uv_stride: usize,
    pub width: usize,
    pub height: usize,
}

/// Paints a scene: the marker at (0,0) over a quiet band, the scene under it. The text and
/// noise scenes are a texture made once for the picture size and copied each frame at an
/// offset, so painting costs one copy of the picture whatever the scene.
pub struct Painter {
    scene: Scene,
    texture: Option<Texture>,
}

impl Painter {
    pub fn new(scene: Scene, width: usize, height: usize) -> Self {
        let rows = height.saturating_sub(BAND_ROWS).max(2) & !1;
        let texture = match scene {
            Scene::Bars => None,
            Scene::Text => Some(Texture::text(width & !1, TEXT_ROWS)),
            Scene::Noise | Scene::Churn => Some(Texture::noise(NOISE_TILE, rows)),
        };
        Self { scene, texture }
    }

    /// Paints one picture: the marker showing `counter`, and the scene moved on by `phase`
    /// (frames x 8 px). Every pixel is written, so a reused surface carries nothing from the
    /// last frame.
    pub fn paint(&self, p: &mut Nv12<'_>, counter: u32, phase: u32) {
        let Some(texture) = &self.texture else { return paint(p, counter, phase) };
        band_and_marker(p, counter);
        match self.scene {
            // Scrolls up 4 px a frame (even, so chroma rows stay with their luma).
            Scene::Text => texture.copy_into(p, 0, phase as usize / 2),
            Scene::Bars | Scene::Noise => texture.copy_into(p, phase as usize, 0),
            // A new place in the grain every frame (even rows, so chroma stays with luma).
            Scene::Churn => {
                let jump = mix(u64::from(phase) ^ 0x6368_7572_6e00);
                let (dx, dy) = (
                    (jump % NOISE_TILE as u64) as usize,
                    ((jump >> 32) as usize % texture.rows) & !1,
                );
                texture.copy_into(p, dx, dy)
            }
        }
    }
}

/// Text texture rows: 128 lines of 16 px, so the scroll repeats after 512 frames.
const TEXT_ROWS: usize = 2048;
/// The noise texture's width: it repeats every 1024 px across, with bars of 64.
const NOISE_TILE: usize = 1024;

/// A scene's texture: NV12 planes that wrap in both directions.
struct Texture {
    y: Vec<u8>,
    uv: Vec<u8>,
    /// Luma columns and rows, both even; chroma is half of each, interleaved, so a chroma row
    /// is also `width` bytes.
    width: usize,
    rows: usize,
}

/// A pseudo-random 64-bit value for a key (splitmix64), so textures are the same every run.
fn mix(key: u64) -> u64 {
    let mut z = key.wrapping_add(0x9e37_79b9_7f4a_7c15);
    z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
    z ^ (z >> 31)
}

impl Texture {
    /// Code-like text: lines of 8x16 glyph cells with ragged indents and ends, glyphs of
    /// random strokes in a 5x9 box, each token tinted one of a few hues.
    fn text(width: usize, rows: usize) -> Self {
        const FG: u8 = 210;
        const BG: u8 = 22;
        let cols = width / 8;
        let mut y = vec![BG; width * rows];
        let mut uv = vec![NEUTRAL; width * rows / 2];
        let tints: [(u8, u8); 4] = [(NEUTRAL, NEUTRAL), (170, 100), (90, 170), (160, 160)];
        for line in 0..rows / 16 {
            let seed = mix(line as u64);
            let indent = (seed % 6) as usize * 2;
            let room = cols.saturating_sub(indent + 12).max(1);
            let end = (indent + 12 + (seed >> 8) as usize % room).min(cols);
            let mut tint = tints[0];
            for col in indent..end {
                let cell = mix(seed ^ ((col as u64) << 20));
                if cell.is_multiple_of(7) {
                    // A space; the next token takes a new tint.
                    tint = tints[(cell >> 8) as usize % tints.len()];
                    continue;
                }
                for gy in 0..9 {
                    let bits = mix(cell ^ (gy as u64 + 1));
                    for gx in 0..5 {
                        if (bits >> (gx * 7)) & 3 == 0 {
                            y[(line * 16 + 3 + gy) * width + col * 8 + 1 + gx] = FG;
                        }
                    }
                }
                for cy in 0..8 {
                    let at = (line * 8 + cy) * width + col * 8;
                    for pair in uv[at..at + 8].chunks_exact_mut(2) {
                        pair.copy_from_slice(&[tint.0, tint.1]);
                    }
                }
            }
        }
        Self { y, uv, width, rows }
    }

    /// Bars 64 px wide (two row templates) with per-pixel grain of up to +/-28.
    fn noise(width: usize, rows: usize) -> Self {
        let mut y = vec![0; width * rows];
        for row in 0..rows {
            let lift = if (row / 64).is_multiple_of(2) { 0 } else { 12 };
            for x in 0..width {
                let k = x / 64;
                let base = if k.is_multiple_of(2) { 40 } else { 60 + (k / 2 * 37) % 150 } + lift;
                let grain = (mix(((row as u64) << 32) | x as u64) % 57) as i32 - 28;
                y[row * width + x] = (base as i32 + grain).clamp(16, 235) as u8;
            }
        }
        let chroma: Vec<u8> = (0..width / 2)
            .flat_map(|cx| {
                let k = cx * 2 / 64;
                if k.is_multiple_of(2) {
                    [NEUTRAL, NEUTRAL]
                } else {
                    [(64 + (k * 53) % 128) as u8, (64 + (k * 91) % 128) as u8]
                }
            })
            .collect();
        let uv = chroma.repeat(rows / 2);
        Self { y, uv, width, rows }
    }

    /// Fills the picture under the band from the texture, `dx` columns across and `dy` rows
    /// down into it, wrapping.
    fn copy_into(&self, p: &mut Nv12<'_>, dx: usize, dy: usize) {
        let (width, height) = (p.width, p.height);
        for row in BAND_ROWS..height {
            let src = (row - BAND_ROWS + dy) % self.rows * self.width;
            let line = &mut p.y[row * p.y_stride..row * p.y_stride + width];
            copy_wrapped(line, &self.y[src..src + self.width], dx);
        }
        for row in BAND_ROWS / 2..height / 2 {
            let src = (row - BAND_ROWS / 2 + dy / 2) % (self.rows / 2) * self.width;
            let line = &mut p.uv[row * p.uv_stride..row * p.uv_stride + width];
            copy_wrapped(line, &self.uv[src..src + self.width], dx & !1);
        }
    }
}

/// Fills `dst` from `src` starting at `start`, wrapping to its beginning.
fn copy_wrapped(dst: &mut [u8], src: &[u8], start: usize) {
    let (mut at, mut out) = (start % src.len(), 0);
    while out < dst.len() {
        let n = (src.len() - at).min(dst.len() - out);
        dst[out..out + n].copy_from_slice(&src[at..at + n]);
        out += n;
        at = 0;
    }
}

/// The quiet band at the top with the marker showing `counter` over it, luma and chroma.
fn band_and_marker(p: &mut Nv12<'_>, counter: u32) {
    let width = p.width;
    for row in 0..BAND_ROWS.min(p.height) {
        p.y[row * p.y_stride..row * p.y_stride + width].fill(BAND);
    }
    let marker = cells(counter);
    for row in 0..CELL as usize {
        let line = &mut p.y[row * p.y_stride..row * p.y_stride + width];
        for (i, white) in marker.iter().enumerate() {
            let x = i * CELL as usize;
            line[x..x + CELL as usize].fill(if *white { WHITE } else { BLACK });
        }
    }
    for row in 0..(BAND_ROWS / 2).min(p.height / 2) {
        p.uv[row * p.uv_stride..row * p.uv_stride + width].fill(NEUTRAL);
    }
}

/// Paints one picture of the bars scene: the marker showing `counter` at (0,0), a quiet band
/// to the bars, and bars shifted by `phase` pixels below it. Every pixel is written, so a
/// reused surface carries nothing from the last frame.
pub fn paint(p: &mut Nv12<'_>, counter: u32, phase: u32) {
    let (width, height) = (p.width, p.height);
    debug_assert!(width >= MIN_SIZE.0 as usize && height >= MIN_SIZE.1 as usize);
    // Luma: the band, then the marker over it, then the bars (two row templates, so the
    // picture has horizontal edges as well as vertical ones).
    for row in 0..BAND_ROWS.min(height) {
        p.y[row * p.y_stride..row * p.y_stride + width].fill(BAND);
    }
    let marker = cells(counter);
    for row in 0..CELL as usize {
        let line = &mut p.y[row * p.y_stride..row * p.y_stride + width];
        for (i, white) in marker.iter().enumerate() {
            let x = i * CELL as usize;
            line[x..x + CELL as usize].fill(if *white { WHITE } else { BLACK });
        }
    }
    let shift = phase as usize;
    let bar_luma = |x: usize, lift: u8| -> u8 {
        let k = (x + shift) / BAR;
        if k.is_multiple_of(2) {
            40 + lift
        } else {
            (60 + (k / 2 * 37) % 150) as u8 + lift
        }
    };
    let templates: [Vec<u8>; 2] =
        [0u8, 12].map(|lift| (0..width).map(|x| bar_luma(x, lift)).collect());
    for row in BAND_ROWS..height {
        let template = &templates[(row / 64) % 2];
        p.y[row * p.y_stride..row * p.y_stride + width].copy_from_slice(template);
    }
    // Chroma: neutral under the band, hues for the bars.
    let half = width / 2;
    let chroma: Vec<u8> = (0..half)
        .flat_map(|cx| {
            let k = (cx * 2 + shift) / BAR;
            if k.is_multiple_of(2) {
                [NEUTRAL, NEUTRAL]
            } else {
                [(64 + (k * 53) % 128) as u8, (64 + (k * 91) % 128) as u8]
            }
        })
        .collect();
    for row in 0..height / 2 {
        let line = &mut p.uv[row * p.uv_stride..row * p.uv_stride + half * 2];
        if row < BAND_ROWS / 2 {
            line.fill(NEUTRAL);
        } else {
            line.copy_from_slice(&chroma);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn picture(width: usize, height: usize, counter: u32, phase: u32) -> (Vec<u8>, Vec<u8>) {
        // Strides wider than the picture, as an IOSurface's are.
        let (y_stride, uv_stride) = (width + 64, width + 64);
        let mut y = vec![0xAA; y_stride * height];
        let mut uv = vec![0xAA; uv_stride * height / 2];
        paint(
            &mut Nv12 { y: &mut y, y_stride, uv: &mut uv, uv_stride, width, height },
            counter,
            phase,
        );
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
            parse(Some("synthetic-still"), None, Some("noise"))
                .map(|s| s.map(|s| (s.motion, s.scene))),
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
            assert_eq!(
                uva[r * stride..r * stride + w],
                uvb[r * stride..r * stride + w],
                "uv row {r}"
            );
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
        let (a, b) =
            (scene_picture(&text, w, h, 0, phase(0)), scene_picture(&text, w, h, 0, phase(1)));
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
}
