//! AV1: rav1e encodes, rav1d (the Rust port of dav1d) decodes; both pure Rust.
//!
//! rav1e settings: speed 10 (its fastest preset), low latency (no frame
//! reordering), no scene-change keyframes, infinite GOP, bitrate rate control,
//! `Tune::Psnr`. rav1e has no AV1 screen-content tools (palette, intra block
//! copy), no runtime bitrate change and a frame of lookahead; the adapter
//! reports the capture time of each packet it returns ([`VideoEncoder::output_pts`])
//! so the bench charges that delay to AV1.

use std::collections::VecDeque;
use std::ffi::c_int;
use std::mem::MaybeUninit;
use std::ptr::NonNull;

use cmux_encode::{Codec, EncCfg, I420, Res, VideoDecoder, VideoEncoder};
use rav1e::prelude::*;

const SPEED: u8 = 10;

/// A target change of this many percent or more restarts rav1e at the new one.
const RESTART_PCT: u32 = 30;

pub struct Av1Encoder {
    ctx: Context<u8>,
    cfg: EncCfg,
    width: usize,
    kbps: u32,
    /// The congestion controller's newest target, applied at the next frame.
    want_kbps: Option<u32>,
    /// Capture times of frames sent and not yet returned, oldest first.
    pending_pts: VecDeque<i64>,
    last_pts: Option<i64>,
    /// A keyframe was asked for and has not come out of the lookahead yet.
    key_pending: bool,
    /// Restarts for a new target (each one starts with a keyframe).
    pub restarts: u32,
    name: String,
}

fn context(cfg: &EncCfg, kbps: u32) -> Res<Context<u8>> {
    let mut enc = EncoderConfig::with_speed_preset(SPEED);
    enc.width = cfg.width as usize;
    enc.height = cfg.height as usize;
    enc.time_base = Rational::new(1, u64::from(cfg.fps.max(1)));
    enc.low_latency = true;
    enc.error_resilient = false;
    enc.min_key_frame_interval = 0;
    // rav1e caps the interval at i32::MAX / 3 frames (about two years at 30 fps).
    enc.max_key_frame_interval = i32::MAX as u64 / 3;
    enc.bitrate = (kbps.max(100) * 1000) as i32;
    enc.tune = Tune::Psnr;
    enc.speed_settings.rdo_lookahead_frames = 1;
    enc.speed_settings.scene_detection_mode = SceneDetectionSpeed::None;
    enc.chroma_sampling = ChromaSampling::Cs420;
    enc.bit_depth = 8;
    // Tiles let rav1e's threads split one frame.
    enc.tiles = usize::from(cfg.threads.max(1));
    Ok(Config::new()
        .with_encoder_config(enc)
        .with_threads(usize::from(cfg.threads.max(1)))
        .new_context::<u8>()
        .map_err(|e| format!("rav1e config: {e}"))?)
}

impl Av1Encoder {
    pub fn new(cfg: &EncCfg) -> Res<Self> {
        let kbps = cfg.kbps.max(100);
        let name = format!(
            "rav1e {} av1 speed={SPEED} low-latency rc=bitrate (restart on a {RESTART_PCT}% target change) gop=inf threads={}",
            rav1e::version::short(),
            cfg.threads.max(1)
        );
        Ok(Self {
            ctx: context(cfg, kbps)?,
            cfg: *cfg,
            width: cfg.width as usize,
            kbps,
            want_kbps: None,
            pending_pts: VecDeque::new(),
            last_pts: None,
            key_pending: false,
            restarts: 0,
            name,
        })
    }
}

impl VideoEncoder for Av1Encoder {
    fn encode(&mut self, pic: &I420, force_idr: bool, pts: i64, out: &mut Vec<u8>) -> Res<bool> {
        out.clear();
        self.last_pts = None;
        // rav1e has no runtime target change: a large one restarts it, dropping the frame
        // in its lookahead, and the new context starts with a keyframe.
        if let Some(kbps) = self.want_kbps.take() {
            self.ctx = context(&self.cfg, kbps)?;
            self.kbps = kbps;
            self.pending_pts.clear();
            self.key_pending = true;
            self.restarts += 1;
        }
        // A keyframe already on its way through the lookahead answers this request too.
        let force_idr = force_idr && !self.key_pending;
        self.key_pending |= force_idr;
        let mut frame = self.ctx.new_frame();
        let (w, cw) = (self.width, self.width / 2);
        frame.planes[0].copy_from_raw_u8(&pic.y, w, 1);
        frame.planes[1].copy_from_raw_u8(&pic.u, cw, 1);
        frame.planes[2].copy_from_raw_u8(&pic.v, cw, 1);
        let params = FrameParameters {
            frame_type_override: if force_idr {
                FrameTypeOverride::Key
            } else {
                FrameTypeOverride::No
            },
            ..FrameParameters::default()
        };
        self.ctx.send_frame((frame, params)).map_err(|e| format!("rav1e send_frame: {e:?}"))?;
        self.pending_pts.push_back(pts);
        let mut key = false;
        loop {
            match self.ctx.receive_packet() {
                Ok(packet) => {
                    out.extend_from_slice(&packet.data);
                    if packet.frame_type == FrameType::KEY {
                        key = true;
                        self.key_pending = false;
                    }
                    self.last_pts = self.pending_pts.pop_front();
                }
                Err(EncoderStatus::Encoded) => continue,
                Err(EncoderStatus::NeedMoreData) => break,
                Err(e) => return Err(format!("rav1e receive_packet: {e:?}").into()),
            }
        }
        Ok(key)
    }

    fn set_bitrate(&mut self, kbps: u32) {
        let kbps = kbps.max(100);
        if kbps.abs_diff(self.kbps) * 100 >= self.kbps * RESTART_PCT {
            self.want_kbps = Some(kbps);
        }
    }

    fn kbps(&self) -> u32 {
        self.kbps
    }

    fn name(&self) -> String {
        self.name.clone()
    }

    fn codec(&self) -> Codec {
        Codec::Av1
    }

    fn output_pts(&self) -> Option<i64> {
        self.last_pts
    }
}

mod d {
    pub use rav1d::include::dav1d::data::Dav1dData;
    pub use rav1d::include::dav1d::dav1d::{Dav1dContext, Dav1dSettings};
    pub use rav1d::include::dav1d::picture::Dav1dPicture;
    pub use rav1d::src::lib::{
        dav1d_close, dav1d_data_create, dav1d_data_unref, dav1d_default_settings,
        dav1d_get_picture, dav1d_open, dav1d_picture_unref, dav1d_send_data,
    };
}

pub struct Av1Decoder {
    ctx: Option<d::Dav1dContext>,
}

// SAFETY: the decoder context is used from one thread at a time.
unsafe impl Send for Av1Decoder {}

/// rav1d returns `-errno`, with the platform's EAGAIN (11 on Linux, 35 on macOS).
const EAGAIN: c_int = -libc::EAGAIN;

impl Av1Decoder {
    pub fn new(threads: u32) -> Res<Self> {
        // SAFETY: default settings fill the struct; open writes the context or fails.
        unsafe {
            let mut s = MaybeUninit::<d::Dav1dSettings>::zeroed();
            d::dav1d_default_settings(NonNull::new(s.as_mut_ptr()).ok_or("settings")?);
            let mut s = s.assume_init();
            s.n_threads = threads.max(1) as c_int;
            // One frame in, one frame out: no frame threading delay.
            s.max_frame_delay = 1;
            let mut ctx: Option<d::Dav1dContext> = None;
            let rc = d::dav1d_open(NonNull::new(&mut ctx), NonNull::new(&mut s));
            if rc.0 != 0 || ctx.is_none() {
                return Err(format!("rav1d open failed: {}", rc.0).into());
            }
            Ok(Self { ctx })
        }
    }
}

impl VideoDecoder for Av1Decoder {
    fn decode(&mut self, au: &[u8], out: &mut I420) -> Res<bool> {
        let mut got = false;
        // SAFETY: rav1d's C API on a live context; the data buffer it allocates is filled
        // before it is sent, and every picture it returns is copied out and unreferenced.
        unsafe {
            let mut data: d::Dav1dData = std::mem::zeroed();
            let buf = d::dav1d_data_create(NonNull::new(&mut data), au.len());
            if buf.is_null() {
                return Err("rav1d data_create failed".into());
            }
            std::ptr::copy_nonoverlapping(au.as_ptr(), buf, au.len());
            let mut result = Ok(());
            while data.sz > 0 {
                let rc = d::dav1d_send_data(self.ctx, NonNull::new(&mut data));
                if rc.0 != 0 && rc.0 != EAGAIN {
                    result = Err(format!("rav1d send_data failed: {}", rc.0));
                    break;
                }
                match self.drain(out) {
                    Ok(g) => got |= g,
                    Err(e) => {
                        result = Err(e.to_string());
                        break;
                    }
                }
            }
            // Every path releases the buffer once, the error paths too.
            d::dav1d_data_unref(NonNull::new(&mut data));
            result?;
            got |= self.drain(out)?;
        }
        Ok(got)
    }

    fn codec(&self) -> Codec {
        Codec::Av1
    }

    fn name(&self) -> String {
        "rav1d 1.1 av1".into()
    }
}

impl Av1Decoder {
    /// Takes every picture rav1d has ready; the newest lands in `out`.
    unsafe fn drain(&mut self, out: &mut I420) -> Res<bool> {
        let mut got = false;
        loop {
            let mut pic = d::Dav1dPicture::default();
            // SAFETY: a live context and a picture struct we own.
            let rc = unsafe { d::dav1d_get_picture(self.ctx, NonNull::new(&mut pic)) };
            if rc.0 == EAGAIN {
                return Ok(got);
            }
            if rc.0 != 0 {
                return Err(format!("rav1d get_picture failed: {}", rc.0).into());
            }
            let w = pic.p.w as usize;
            let h = pic.p.h as usize;
            let planes = [
                pic.data[0].map_or(std::ptr::null(), |p| p.as_ptr() as *const u8),
                pic.data[1].map_or(std::ptr::null(), |p| p.as_ptr() as *const u8),
                pic.data[2].map_or(std::ptr::null(), |p| p.as_ptr() as *const u8),
            ];
            let strides = [pic.stride[0] as usize, pic.stride[1] as usize, pic.stride[1] as usize];
            if planes.iter().all(|p| !p.is_null()) {
                // SAFETY: rav1d's planes cover stride times rows for an 8-bit 4:2:0 picture.
                unsafe { crate::copy_planes(out, w, h, planes, strides) };
                got = true;
            }
            // SAFETY: release the picture rav1d handed out, exactly once.
            unsafe { d::dav1d_picture_unref(NonNull::new(&mut pic)) };
        }
    }
}

impl Drop for Av1Decoder {
    fn drop(&mut self) {
        // SAFETY: close a live context exactly once.
        unsafe { d::dav1d_close(NonNull::new(&mut self.ctx)) };
    }
}
