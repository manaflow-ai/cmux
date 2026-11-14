//! Screen-share codecs behind cmux-encode's [`VideoEncoder`] and
//! [`VideoDecoder`], for measurement: OpenH264 (the encoder cmux.rd ships,
//! from source here, and its decoder), VP9 through libvpx and AV1 through
//! rav1e and rav1d. VP9 and AV1 are royalty-free (AOMedia and Google patent
//! licenses); no shipped binary links this crate until the codec table in its
//! pull request says one should replace H.264.

use cmux_encode::openh264::{OpenH264, OpenH264Api};
use cmux_encode::{Codec, EncCfg, I420, Res, VideoDecoder, VideoEncoder};

#[cfg(feature = "av1")]
pub mod av1;
#[cfg(feature = "vp9")]
pub mod vp9;

pub mod bench;

/// The encoder for `codec`, `None` when this build leaves it out.
pub fn open_encoder(codec: Codec, cfg: &EncCfg) -> Res<Option<Box<dyn VideoEncoder>>> {
    Ok(match codec {
        Codec::H264 => Some(Box::new(OpenH264::new(cfg, OpenH264Api::from_source())?)),
        #[cfg(feature = "vp9")]
        Codec::Vp9 => Some(Box::new(vp9::Vp9Encoder::new(cfg)?)),
        #[cfg(feature = "av1")]
        Codec::Av1 => Some(Box::new(av1::Av1Encoder::new(cfg)?)),
        #[allow(unreachable_patterns)]
        _ => None,
    })
}

/// The decoder for `codec`, `None` when this build leaves it out.
pub fn open_decoder(codec: Codec, threads: u32) -> Res<Option<Box<dyn VideoDecoder>>> {
    let _ = threads;
    Ok(match codec {
        Codec::H264 => Some(Box::new(H264Decoder::new()?)),
        #[cfg(feature = "vp9")]
        Codec::Vp9 => Some(Box::new(vp9::Vp9Decoder::new(threads)?)),
        #[cfg(feature = "av1")]
        Codec::Av1 => Some(Box::new(av1::Av1Decoder::new(threads)?)),
        #[allow(unreachable_patterns)]
        _ => None,
    })
}

/// OpenH264's decoder (from source; the bench's and the Linux viewer's).
pub struct H264Decoder(openh264::decoder::Decoder);

impl H264Decoder {
    pub fn new() -> Res<Self> {
        Ok(Self(openh264::decoder::Decoder::new()?))
    }
}

impl VideoDecoder for H264Decoder {
    fn decode(&mut self, au: &[u8], out: &mut I420) -> Res<bool> {
        use openh264::formats::YUVSource;
        let Some(yuv) = self.0.decode(au)? else { return Ok(false) };
        let (w, h) = yuv.dimensions();
        let (ys, us, vs) = yuv.strides();
        // SAFETY: OpenH264's planes cover their strides times their rows for this call.
        unsafe {
            copy_planes(
                out,
                w,
                h,
                [yuv.y().as_ptr(), yuv.u().as_ptr(), yuv.v().as_ptr()],
                [ys, us, vs],
            )
        };
        Ok(true)
    }

    fn codec(&self) -> Codec {
        Codec::H264
    }

    fn name(&self) -> String {
        "openh264 decoder (source)".into()
    }
}

/// Copies three 4:2:0 planes with strides into `out` (resized to `w` x `h`).
///
/// # Safety
/// Each plane pointer must cover its stride times its row count.
pub(crate) unsafe fn copy_planes(
    out: &mut I420,
    w: usize,
    h: usize,
    planes: [*const u8; 3],
    strides: [usize; 3],
) {
    if out.width != w || out.y.len() != w * h {
        *out = I420::new(w, h);
    }
    let (cw, ch) = (w / 2, h / 2);
    for (i, (dst, pw, ph)) in
        [(&mut out.y, w, h), (&mut out.u, cw, ch), (&mut out.v, cw, ch)].into_iter().enumerate()
    {
        for row in 0..ph {
            // SAFETY: the caller guarantees the plane covers `strides[i] * ph` bytes.
            let src = unsafe { std::slice::from_raw_parts(planes[i].add(row * strides[i]), pw) };
            dst[row * pw..(row + 1) * pw].copy_from_slice(src);
        }
    }
}

/// Luma PSNR of `got` against `want` in dB (99 when identical).
pub fn psnr_y(want: &I420, got: &I420) -> f64 {
    if want.y.len() != got.y.len() {
        return 0.0;
    }
    let se: u64 = want
        .y
        .iter()
        .zip(&got.y)
        .map(|(&a, &b)| {
            let d = i64::from(a) - i64::from(b);
            (d * d) as u64
        })
        .sum();
    if se == 0 {
        return 99.0;
    }
    let mse = se as f64 / want.y.len() as f64;
    10.0 * (255.0 * 255.0 / mse).log10()
}
