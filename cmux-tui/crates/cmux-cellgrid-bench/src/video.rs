//! The video path: the host's pane pixels through cmux-encode's OpenH264 (the
//! encoder cmux.rd's Linux host uses, screen-content real-time, frame skip on),
//! decoded with OpenH264 and compared against the source pixels.

use std::time::Instant;

use cmux_encode::openh264::{OpenH264, OpenH264Api};
use cmux_encode::{EncCfg, H264Encoder, I420, bgrx_rect_to_i420};
use openh264::decoder::Decoder;
use openh264::formats::YUVSource;

use crate::color::{de2000, lab};
use crate::raster::Surface;

pub struct Video {
    pub kbps: u32,
    /// Encode an unchanged frame this often while idle (WebRTC's ScreenStream
    /// refreshes every 500 ms); 0 encodes only on damage, as cmux.rd does.
    pub refresh_ms: u64,
    enc: OpenH264,
    dec: Decoder,
    pic: I420,
    out: Vec<u8>,
    w: usize,
    h: usize,
    pub decoded: Vec<u8>,
    pub frames: u64,
    pub last_encode_ns: u64,
}

pub struct Encoded {
    pub bytes: usize,
    pub encode_ns: u64,
    pub decode_ns: u64,
}

impl Video {
    pub fn new(w: usize, h: usize, fps: u32, kbps: u32, refresh_ms: u64) -> Result<Self, String> {
        let cfg = EncCfg {
            width: w as u32,
            height: h as u32,
            fps,
            kbps,
            threads: 4,
            screen_content: true,
        };
        let enc = OpenH264::new(&cfg, OpenH264Api::from_source()).map_err(|e| e.to_string())?;
        Ok(Video {
            kbps,
            refresh_ms,
            enc,
            dec: Decoder::new().map_err(|e| e.to_string())?,
            pic: I420::new(w, h),
            out: Vec::new(),
            w,
            h,
            decoded: vec![0; w * h * 4],
            frames: 0,
            last_encode_ns: 0,
        })
    }

    pub fn name(&self) -> String {
        if self.refresh_ms > 0 {
            format!("h264-{}k-refresh{}ms", self.kbps, self.refresh_ms)
        } else {
            format!("h264-{}k", self.kbps)
        }
    }

    /// Encodes `src` (BGRX), decodes the result into `self.decoded`. `decode_ns`
    /// includes the CPU conversion back to BGRX, which a real viewer does on the GPU.
    pub fn frame(&mut self, src: &[u8], pts_ms: i64) -> Result<Encoded, String> {
        let t0 = Instant::now();
        bgrx_rect_to_i420(src, &mut self.pic, 0, 0, self.w, self.h, 4);
        self.out.clear();
        let idr = self.frames == 0;
        self.enc.encode(&self.pic, idr, pts_ms, &mut self.out).map_err(|e| e.to_string())?;
        let encode_ns = t0.elapsed().as_nanos() as u64;
        self.frames += 1;
        let bytes = self.out.len();
        let t1 = Instant::now();
        if bytes > 0 {
            let decoded = self.dec.decode(&self.out).map_err(|e| e.to_string())?;
            if let Some(yuv) = decoded {
                let (ys, us, vs) = yuv.strides();
                i420_to_bgrx(
                    yuv.y(),
                    yuv.u(),
                    yuv.v(),
                    (ys, us, vs),
                    self.w,
                    self.h,
                    &mut self.decoded,
                );
            }
        }
        Ok(Encoded { bytes, encode_ns, decode_ns: t1.elapsed().as_nanos() as u64 })
    }
}

/// BT.601 video range back to BGRX: the inverse of cmux-encode's `bgrx_rect_to_i420`.
pub fn i420_to_bgrx(
    y: &[u8],
    u: &[u8],
    v: &[u8],
    strides: (usize, usize, usize),
    w: usize,
    h: usize,
    out: &mut [u8],
) {
    for row in 0..h {
        for col in 0..w {
            let c = i32::from(y[row * strides.0 + col]) - 16;
            let d = i32::from(u[(row / 2) * strides.1 + col / 2]) - 128;
            let e = i32::from(v[(row / 2) * strides.2 + col / 2]) - 128;
            let clamp = |x: i32| ((x + 128) >> 8).clamp(0, 255) as u8;
            let i = (row * w + col) * 4;
            out[i + 2] = clamp(298 * c + 409 * e);
            out[i + 1] = clamp(298 * c - 100 * d - 208 * e);
            out[i] = clamp(298 * c + 516 * d);
        }
    }
}

/// The I420 round trip with no codec: the floor 4:2:0 alone sets on colour.
pub fn chroma_floor(src: &[u8], w: usize, h: usize) -> Vec<u8> {
    let mut pic = I420::new(w, h);
    bgrx_rect_to_i420(src, &mut pic, 0, 0, w, h, 4);
    let mut out = vec![0; w * h * 4];
    i420_to_bgrx(&pic.y, &pic.u, &pic.v, (w, w / 2, w / 2), w, h, &mut out);
    out
}

/// How a received picture differs from the host's.
#[derive(Default, Clone, Debug)]
pub struct Quality {
    pub samples: u64,
    pub pixels: u64,
    pub exact_pixels: u64,
    pub text_cells: u64,
    pub exact_text_cells: u64,
    pub near_text_cells: u64,
    pub sq_err: f64,
    pub de: Vec<f32>,
}

impl Quality {
    /// Compares `got` with `want` (both BGRX). A text cell holds any glyph pixel;
    /// it is exact when every pixel matches and near when none is off by more
    /// than 8 in a channel. Colour error is CIEDE2000 on fully covered glyph
    /// pixels (the text colour itself), every 3rd one.
    pub fn add(&mut self, want: &Surface, got: &[u8], w: usize, h: usize, cw: usize, ch: usize) {
        self.samples += 1;
        let (cols, rows) = (w / cw, h / ch);
        for r in 0..rows {
            for c in 0..cols {
                let (mut text, mut exact, mut near) = (false, true, true);
                for y in r * ch..(r + 1) * ch {
                    for x in c * cw..(c + 1) * cw {
                        let p = y * w + x;
                        text |= want.mask[p] != 0;
                        for k in 0..3 {
                            let d =
                                (i32::from(want.bgrx[p * 4 + k]) - i32::from(got[p * 4 + k])).abs();
                            exact &= d == 0;
                            near &= d <= 8;
                        }
                    }
                }
                if text {
                    self.text_cells += 1;
                    self.exact_text_cells += u64::from(exact);
                    self.near_text_cells += u64::from(near);
                }
            }
        }
        for p in 0..w * h {
            let (a, b) = (&want.bgrx[p * 4..p * 4 + 3], &got[p * 4..p * 4 + 3]);
            self.pixels += 1;
            self.exact_pixels += u64::from(a == b);
            for k in 0..3 {
                let d = f64::from(a[k]) - f64::from(b[k]);
                self.sq_err += d * d;
            }
            if want.mask[p] == 1 && p % 3 == 0 {
                self.de.push(de2000(lab(a[2], a[1], a[0]), lab(b[2], b[1], b[0])) as f32);
            }
        }
    }

    pub fn json(&mut self) -> serde_json::Value {
        self.de.sort_by(f32::total_cmp);
        let pct = |n: u64, d: u64| {
            if d == 0 {
                serde_json::Value::Null
            } else {
                serde_json::json!(100.0 * n as f64 / d as f64)
            }
        };
        let mse = self.sq_err / (3.0 * self.pixels.max(1) as f64);
        let psnr = if mse == 0.0 {
            serde_json::json!("inf")
        } else {
            serde_json::json!(10.0 * (255.0f64 * 255.0 / mse).log10())
        };
        let q = |f: f64| self.de.get(((self.de.len() as f64 - 1.0) * f).round() as usize).copied();
        serde_json::json!({
            "samples": self.samples,
            "exact_pixels_pct": pct(self.exact_pixels, self.pixels),
            "exact_text_cells_pct": pct(self.exact_text_cells, self.text_cells),
            "near_text_cells_pct": pct(self.near_text_cells, self.text_cells),
            "psnr_db": psnr,
            "text_de2000_mean": if self.de.is_empty() { None } else { Some(self.de.iter().map(|&x| f64::from(x)).sum::<f64>() / self.de.len() as f64) },
            "text_de2000_p50": q(0.5),
            "text_de2000_p95": q(0.95),
            "text_de2000_over_jnd_pct": pct(self.de.iter().filter(|&&x| x > 2.3).count() as u64, self.de.len() as u64),
        })
    }
}
