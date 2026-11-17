//! The pure parts of cutting a recording by the camera path: output aspects
//! and sizes, the YUV4MPEG2 stream header the cutter reads frames through,
//! fitting a signal trace to the video's pixels, and cropping a plane.

use std::str::FromStr;

use crate::{Event, Rect, Signal};

/// A vertical cut's shape.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Aspect {
    /// 9:16, a phone's full screen.
    Tall,
    /// 4:5, a feed post.
    Portrait,
    /// 1:1.
    Square,
}

impl Aspect {
    /// Width over height.
    pub fn ratio(self) -> f64 {
        match self {
            Aspect::Tall => 9.0 / 16.0,
            Aspect::Portrait => 4.0 / 5.0,
            Aspect::Square => 1.0,
        }
    }

    /// The output size for `width` pixels wide (even, for H.264).
    pub fn output_size(self, width: u32) -> (u32, u32) {
        let w = (width & !1).max(2);
        let h = (f64::from(w) / self.ratio() / 2.0).round() as u32 * 2;
        (w, h.max(2))
    }
}

impl FromStr for Aspect {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, String> {
        match s {
            "9:16" => Ok(Aspect::Tall),
            "4:5" => Ok(Aspect::Portrait),
            "1:1" => Ok(Aspect::Square),
            _ => Err(format!("unknown aspect {s}: use 9:16, 4:5 or 1:1")),
        }
    }
}

/// A YUV4MPEG2 stream's header line (without its newline).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Y4mHeader {
    pub w: usize,
    pub h: usize,
    pub fps_num: u64,
    pub fps_den: u64,
    /// The `C` tag, "420jpeg" when absent.
    pub chroma: String,
}

impl Y4mHeader {
    pub fn parse(line: &str) -> Result<Self, String> {
        let mut tokens = line.trim_end().split(' ');
        if tokens.next() != Some("YUV4MPEG2") {
            return Err(format!("not a YUV4MPEG2 header: {line}"));
        }
        let (mut w, mut h, mut fps, mut chroma) = (None, None, (30, 1), "420jpeg".to_string());
        for token in tokens {
            let (tag, value) = token.split_at(token.len().min(1));
            match tag {
                "W" => w = value.parse().ok(),
                "H" => h = value.parse().ok(),
                "F" => {
                    let (n, d) = value.split_once(':').ok_or(format!("bad rate {value}"))?;
                    fps = (
                        n.parse().map_err(|_| format!("bad rate {value}"))?,
                        d.parse().map_err(|_| format!("bad rate {value}"))?,
                    );
                }
                "C" => chroma = value.to_string(),
                _ => {}
            }
        }
        match (w, h) {
            (Some(w), Some(h)) if w > 0 && h > 0 && fps.0 > 0 && fps.1 > 0 => {
                Ok(Self { w, h, fps_num: fps.0, fps_den: fps.1, chroma })
            }
            _ => Err(format!("YUV4MPEG2 header without a size or rate: {line}")),
        }
    }

    /// Bytes of one frame's planes (after its FRAME line).
    pub fn frame_bytes(&self) -> Result<usize, String> {
        let luma = self.w * self.h;
        let (cw, ch) = (self.w.div_ceil(2), self.h.div_ceil(2));
        if self.chroma.starts_with("444") {
            Ok(luma * 3)
        } else if self.chroma.starts_with("422") {
            Ok(luma + 2 * cw * self.h)
        } else if self.chroma.starts_with("420") {
            Ok(luma + 2 * cw * ch)
        } else if self.chroma == "mono" {
            Ok(luma)
        } else {
            Err(format!("unsupported chroma {}", self.chroma))
        }
    }

    /// The time of frame `index`, in microseconds from the first.
    pub fn frame_time_us(&self, index: u64) -> u64 {
        (u128::from(index) * 1_000_000 * u128::from(self.fps_den) / u128::from(self.fps_num)) as u64
    }
}

/// A trace fitted to a `video_w` x `video_h` recording: a trace that says
/// its screen size (a [`Signal::Source`] event) is scaled from it to the
/// video's pixels, and its source events are dropped (the video's size is
/// the camera's source).
pub fn fit_trace(events: &[Event], video_w: f64, video_h: f64) -> Vec<Event> {
    let mut scale = (1.0, 1.0);
    let mut out = Vec::with_capacity(events.len());
    for event in events {
        let (sx, sy) = scale;
        let signal = match event.signal {
            Signal::Source { w, h } => {
                if w > 0.0 && h > 0.0 {
                    scale = (video_w / w, video_h / h);
                }
                continue;
            }
            Signal::Pointer { x, y } => Signal::Pointer { x: x * sx, y: y * sy },
            Signal::Caret { x, y, w, h } => {
                Signal::Caret { x: x * sx, y: y * sy, w: w * sx, h: h * sy }
            }
            Signal::Window { id, x, y, w, h } => {
                Signal::Window { id, x: x * sx, y: y * sy, w: w * sx, h: h * sy }
            }
            Signal::Damage { x, y, w, h } => {
                Signal::Damage { x: x * sx, y: y * sy, w: w * sx, h: h * sy }
            }
            Signal::Cut => Signal::Cut,
        };
        out.push(Event { t_us: event.t_us, signal });
    }
    out
}

/// For each output index, the two source indices and the second's weight
/// (bilinear, sampling at pixel centres).
fn taps(start: f64, len: f64, out: usize, src: usize) -> Vec<(usize, usize, f32)> {
    let last = src.saturating_sub(1) as f64;
    (0..out)
        .map(|i| {
            let s = (start + (i as f64 + 0.5) * len / out as f64 - 0.5).clamp(0.0, last);
            let a = s.floor() as usize;
            let b = (a + 1).min(src.saturating_sub(1));
            (a, b, (s - a as f64) as f32)
        })
        .collect()
}

/// Samples `rect` of a `sw` x `sh` plane into `out` (`ow` x `oh`),
/// bilinear.
pub fn crop_plane(
    src: &[u8],
    sw: usize,
    sh: usize,
    rect: Rect,
    out: &mut [u8],
    ow: usize,
    oh: usize,
) {
    if sw == 0 || sh == 0 || src.len() < sw * sh || out.len() < ow * oh {
        return;
    }
    let xs = taps(rect.x, rect.w, ow, sw);
    let ys = taps(rect.y, rect.h, oh, sh);
    for (oy, &(ya, yb, fy)) in ys.iter().enumerate() {
        let (ra, rb) = (&src[ya * sw..ya * sw + sw], &src[yb * sw..yb * sw + sw]);
        let row = &mut out[oy * ow..oy * ow + ow];
        for (o, &(xa, xb, fx)) in row.iter_mut().zip(&xs) {
            let top = f32::from(ra[xa]) + (f32::from(ra[xb]) - f32::from(ra[xa])) * fx;
            let bottom = f32::from(rb[xa]) + (f32::from(rb[xb]) - f32::from(rb[xa])) * fx;
            *o = (top + (bottom - top) * fy).round().clamp(0.0, 255.0) as u8;
        }
    }
}
