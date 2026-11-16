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
// Only the macOS host streams it; elsewhere `--source synthetic` is refused and the generator
// runs in tests.
#![cfg_attr(not(target_os = "macos"), allow(dead_code))]

use crate::args::Opts;
use crate::marker::{cells, CELL, CELLS};
use cmux_rd_proto::InputEvent;
use std::sync::OnceLock;

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

/// The synthetic source of a host process.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Synthetic {
    pub motion: Motion,
    pub size: (u32, u32),
}

static SELECTED: OnceLock<Synthetic> = OnceLock::new();

/// The synthetic source `--source` picked for this process, if any.
pub fn selected() -> Option<Synthetic> {
    SELECTED.get().copied()
}

/// Reads `--source` (and `--synthetic-size`) for `host` and `serve`. `screen` (the default)
/// captures the display; the synthetic words need a macOS host, which encodes the generated
/// surfaces with VideoToolbox.
pub fn configure(opts: &Opts) -> Result<(), String> {
    let Some(source) = parse(opts.get("source"), opts.get("synthetic-size"))? else {
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
        "cmux-rd: measurement only: --source {} streams a generated {}x{} picture, and viewer input bumps its marker instead of reaching this Mac",
        name(source.motion),
        source.size.0,
        source.size.1
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

/// `--source` and `--synthetic-size` as a synthetic source; None for the display.
pub fn parse(source: Option<&str>, size: Option<&str>) -> Result<Option<Synthetic>, String> {
    let motion = match source.map(str::trim) {
        None | Some("screen") => {
            return match size {
                Some(_) => Err("--synthetic-size needs --source synthetic".into()),
                None => Ok(None),
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
    Ok(Some(Synthetic { motion, size }))
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

/// Paints one picture: the marker showing `counter` at (0,0), a quiet band to the bars, and
/// bars shifted by `phase` pixels below it. Every pixel is written, so a reused surface
/// carries nothing from the last frame.
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
        assert_eq!(parse(None, None), Ok(None));
        assert_eq!(parse(Some("screen"), None), Ok(None));
        assert!(parse(Some("screen"), Some("1280x720")).is_err());
        assert_eq!(
            parse(Some("synthetic"), None),
            Ok(Some(Synthetic { motion: Motion::Moving, size: DEFAULT_SIZE }))
        );
        assert_eq!(
            parse(Some("synthetic-tick"), Some("1280x720")),
            Ok(Some(Synthetic { motion: Motion::Tick, size: (1280, 720) }))
        );
        assert_eq!(
            parse(Some("synthetic-still"), None).map(|s| s.map(|s| s.motion)),
            Ok(Some(Motion::Still))
        );
        for bad in ["1280", "1281x720", "320x240", "axb", "9000x720"] {
            assert!(parse(Some("synthetic"), Some(bad)).is_err(), "{bad}");
        }
        assert!(parse(Some("camera"), None).is_err());
    }

    #[test]
    fn max_width_fits_keeping_the_aspect_and_the_marker() {
        assert_eq!(fit((1920, 1080), None), (1920, 1080));
        assert_eq!(fit((1920, 1080), Some(2560)), (1920, 1080));
        assert_eq!(fit((1920, 1080), Some(1280)), (1280, 720));
        assert_eq!(fit((1920, 1080), Some(100)), (640, 360));
    }
}
