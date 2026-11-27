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

/// Which H.264 encoder a row uses: OpenH264 (what Linux and Windows hosts send) or an
/// OS encoder: VideoToolbox (what macOS hosts send; macOS only) or Media Foundation's
/// hardware or software MFT (Windows only).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum H264Impl {
    #[default]
    OpenH264,
    VideoToolbox,
    MediaFoundation,
    MediaFoundationSoftware,
}

impl H264Impl {
    pub const ALL: [H264Impl; 4] = [
        H264Impl::OpenH264,
        H264Impl::VideoToolbox,
        H264Impl::MediaFoundation,
        H264Impl::MediaFoundationSoftware,
    ];

    /// The bench's name for an H.264 encoder: `h264`, `h264-vt`, `h264-mf` or `h264-mf-sw`.
    pub fn label(self) -> &'static str {
        match self {
            H264Impl::OpenH264 => "h264",
            H264Impl::VideoToolbox => "h264-vt",
            H264Impl::MediaFoundation => "h264-mf",
            H264Impl::MediaFoundationSoftware => "h264-mf-sw",
        }
    }

    pub fn parse(label: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|i| i.label() == label)
    }
}

/// The H.264 encoder `imp`, `None` when this platform has none (VideoToolbox off macOS,
/// Media Foundation off Windows). `h264-mf` is a hardware MFT only: no fallback, so its
/// rows are the hardware encoder's or an error.
///
/// Measurement knobs, read here only (never by a host): `CMUX_OPENH264_TUNING` holds
/// [`cmux_encode::openh264::OpenH264Options::parse`]'s list and `CMUX_MF_TUNING`
/// [`cmux_encode::mediafoundation::MfTuning::parse`]'s; unset is the shipped settings (on
/// Linux the Linux host's, [`cmux_encode::openh264::OpenH264Options::linux_host`]).
pub fn open_h264(imp: H264Impl, cfg: &EncCfg) -> Res<Option<Box<dyn VideoEncoder>>> {
    use cmux_encode::openh264::OpenH264Options;
    let tuning = |name: &str| std::env::var(name).unwrap_or_default();
    Ok(match imp {
        H264Impl::OpenH264 => {
            let shipped = if cfg!(target_os = "linux") {
                OpenH264Options::linux_host()
            } else {
                OpenH264Options::default()
            };
            let opts = OpenH264Options::parse_over(shipped, &tuning("CMUX_OPENH264_TUNING"))?;
            Some(Box::new(OpenH264::with_options(cfg, OpenH264Api::from_source(), &opts)?))
        }
        // Constrained baseline like OpenH264's, so both send the same profile.
        #[cfg(target_os = "macos")]
        H264Impl::VideoToolbox => Some(Box::new(cmux_encode::videotoolbox::VideoToolbox::new(
            cfg.width, cfg.height, cfg.fps, cfg.kbps, true,
        )?)),
        #[cfg(windows)]
        H264Impl::MediaFoundation | H264Impl::MediaFoundationSoftware => {
            use cmux_encode::mediafoundation::{MediaFoundation, MfTuning, MftKind};
            let kind = if imp == H264Impl::MediaFoundation {
                MftKind::Hardware
            } else {
                MftKind::Software
            };
            let t = MfTuning::parse(&tuning("CMUX_MF_TUNING"))?;
            Some(Box::new(MediaFoundation::with_tuning(cfg, kind, &t)?))
        }
        #[allow(unreachable_patterns)]
        _ => None,
    })
}

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

/// OpenH264's decoder (from source; the bench's and the Linux viewer's), and the conversion the
/// stream's last SPS asks for.
pub struct H264Decoder(openh264::decoder::Decoder, cmux_encode::color::Yuv);

impl H264Decoder {
    pub fn new() -> Res<Self> {
        Ok(Self(openh264::decoder::Decoder::new()?, cmux_encode::color::UNTAGGED.yuv()))
    }
}

impl VideoDecoder for H264Decoder {
    fn decode(&mut self, au: &[u8], out: &mut I420) -> Res<bool> {
        use openh264::formats::YUVSource;
        if let Some(vui) = cmux_encode::color::sps_vui(au) {
            self.1 = vui.yuv();
        }
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

    fn color(&self) -> cmux_encode::color::Yuv {
        self.1
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
