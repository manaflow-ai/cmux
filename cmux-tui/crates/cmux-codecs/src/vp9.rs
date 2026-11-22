//! VP9 through libvpx (built from source by build.rs): real-time deadline, CBR
//! with frame drop, infinite GOP, error resilience, screen-content tuning. The
//! settings follow WebRTC's libvpx VP9 screen-share configuration
//! (`LibvpxVp9Encoder`: speed 7-8 for screen, aq_mode 3 off for screen, tune
//! content screen, row-mt, no lag) so the bench measures VP9 the way a
//! browser would send it.

#![allow(non_upper_case_globals, non_camel_case_types, non_snake_case, dead_code, clippy::all)]

mod sys {
    include!(concat!(env!("OUT_DIR"), "/vpx_bindings.rs"));
}

use std::mem::MaybeUninit;
use std::os::raw::{c_int, c_uint, c_ulong};

use cmux_encode::{Codec, EncCfg, I420, Res, VideoDecoder, VideoEncoder};

fn check(rc: sys::vpx_codec_err_t, what: &str) -> Res<()> {
    if rc == sys::vpx_codec_err_t_VPX_CODEC_OK {
        Ok(())
    } else {
        Err(format!("libvpx {what} failed: {rc}").into())
    }
}

/// libvpx's VP9 encoder version string.
pub fn version() -> String {
    // SAFETY: returns a static NUL-terminated string.
    let s = unsafe { std::ffi::CStr::from_ptr(sys::vpx_codec_version_str()) };
    s.to_string_lossy().into_owned()
}

pub struct Vp9Encoder {
    ctx: Box<sys::vpx_codec_ctx_t>,
    cfg: Box<sys::vpx_codec_enc_cfg_t>,
    img: Box<sys::vpx_image_t>,
    kbps: u32,
    /// The first capture time (libvpx counts from it) and the last pts given to libvpx.
    origin: Option<i64>,
    last_pts: i64,
    /// One frame at the configured rate, in the microsecond timebase.
    frame_us: i64,
    name: String,
    width: usize,
    height: usize,
}

// SAFETY: the libvpx context is used from one thread at a time (owned by the media loop).
unsafe impl Send for Vp9Encoder {}

impl Vp9Encoder {
    pub fn new(cfg: &EncCfg) -> Res<Self> {
        let speed = if cfg.screen_content { 8 } else { 7 };
        let threads = cfg.threads.max(1);
        // SAFETY: plain libvpx calls on structs we own; the default config call fills `c`.
        unsafe {
            let iface = sys::vpx_codec_vp9_cx();
            let mut c = Box::new(MaybeUninit::<sys::vpx_codec_enc_cfg_t>::zeroed().assume_init());
            check(sys::vpx_codec_enc_config_default(iface, &mut *c, 0), "config default")?;
            c.g_w = cfg.width;
            c.g_h = cfg.height;
            c.g_timebase.num = 1;
            c.g_timebase.den = 1_000_000;
            c.g_threads = c_uint::from(threads);
            c.g_lag_in_frames = 0;
            c.g_error_resilient = 1;
            c.g_pass = sys::vpx_enc_pass_VPX_RC_ONE_PASS;
            c.rc_end_usage = sys::vpx_rc_mode_VPX_CBR;
            c.rc_target_bitrate = cfg.kbps.max(100);
            c.rc_min_quantizer = 2;
            c.rc_max_quantizer = 52;
            c.rc_undershoot_pct = 50;
            c.rc_overshoot_pct = 50;
            c.rc_buf_initial_sz = 500;
            c.rc_buf_optimal_sz = 600;
            c.rc_buf_sz = 1000;
            // WebRTC drops frames at 30% buffer; the bench can turn it off to spend
            // quality instead of frames (`CMUX_VP9_DROPFRAME_THRESH=0`).
            c.rc_dropframe_thresh = std::env::var("CMUX_VP9_DROPFRAME_THRESH")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(30);
            c.rc_resize_allowed = 0;
            c.kf_mode = sys::vpx_kf_mode_VPX_KF_DISABLED;
            c.kf_max_dist = u32::MAX >> 1;
            let mut ctx = Box::new(MaybeUninit::<sys::vpx_codec_ctx_t>::zeroed().assume_init());
            check(
                sys::vpx_codec_enc_init_ver(
                    &mut *ctx,
                    iface,
                    &*c,
                    0,
                    sys::VPX_ENCODER_ABI_VERSION as c_int,
                ),
                "encoder init",
            )?;
            let ctx_ptr: *mut sys::vpx_codec_ctx_t = &mut *ctx;
            let ctl = |id: u32, v: c_int| -> Res<()> {
                check(sys::vpx_codec_control_(ctx_ptr, id as c_int, v), "control")
            };
            ctl(sys::vp8e_enc_control_id_VP8E_SET_CPUUSED, speed)?;
            ctl(sys::vp8e_enc_control_id_VP9E_SET_ROW_MT, 1)?;
            ctl(sys::vp8e_enc_control_id_VP9E_SET_TILE_COLUMNS, if threads > 1 { 2 } else { 0 })?;
            ctl(sys::vp8e_enc_control_id_VP9E_SET_AQ_MODE, if cfg.screen_content { 0 } else { 3 })?;
            ctl(sys::vp8e_enc_control_id_VP8E_SET_STATIC_THRESHOLD, 1)?;
            ctl(sys::vp8e_enc_control_id_VP9E_SET_NOISE_SENSITIVITY, 0)?;
            ctl(sys::vp8e_enc_control_id_VP9E_SET_FRAME_PARALLEL_DECODING, 0)?;
            ctl(sys::vp8e_enc_control_id_VP8E_SET_MAX_INTRA_BITRATE_PCT, 900)?;
            if cfg.screen_content {
                ctl(
                    sys::vp8e_enc_control_id_VP9E_SET_TUNE_CONTENT,
                    sys::vp9e_tune_content_VP9E_CONTENT_SCREEN as c_int,
                )?;
            }
            let mut img = Box::new(MaybeUninit::<sys::vpx_image_t>::zeroed().assume_init());
            let w = cfg.width as usize;
            let h = cfg.height as usize;
            // Planes are pointed at the caller's picture on each encode (no copy).
            sys::vpx_img_wrap(
                &mut *img,
                sys::vpx_img_fmt_VPX_IMG_FMT_I420,
                cfg.width,
                cfg.height,
                1,
                std::ptr::NonNull::<u8>::dangling().as_ptr(),
            );
            let name = format!(
                "libvpx {} vp9 {} rt cpu-used={speed} cbr gop=inf er=1 threads={threads}",
                version(),
                if cfg.screen_content { "screen" } else { "camera" }
            );
            Ok(Self {
                ctx,
                cfg: c,
                img,
                kbps: cfg.kbps.max(100),
                origin: None,
                last_pts: -1,
                frame_us: 1_000_000 / i64::from(cfg.fps.max(1)),
                name,
                width: w,
                height: h,
            })
        }
    }
}

impl VideoEncoder for Vp9Encoder {
    fn encode(&mut self, pic: &I420, force_idr: bool, pts: i64, out: &mut Vec<u8>) -> Res<bool> {
        out.clear();
        if pic.width != self.width || pic.y.len() != self.width * self.height {
            return Err("vp9: picture size differs from the encoder's".into());
        }
        let img = &mut *self.img;
        img.planes[0] = pic.y.as_ptr().cast_mut();
        img.planes[1] = pic.u.as_ptr().cast_mut();
        img.planes[2] = pic.v.as_ptr().cast_mut();
        img.stride[0] = self.width as c_int;
        img.stride[1] = (self.width / 2) as c_int;
        img.stride[2] = (self.width / 2) as c_int;
        // libvpx refuses (INVALID_PARAM) a pts or duration that overflows its
        // internal timebase, which a wall-clock capture time in microseconds does:
        // count from the first capture instead. Timestamps must increase, and a
        // frame's duration (rate control's frame interval) is the gap since the
        // last one, one frame at the configured rate for the first, at most 1 s.
        let origin = *self.origin.get_or_insert(pts);
        let pts = pts.saturating_sub(origin).max(self.last_pts + 1);
        let duration = if self.last_pts < 0 {
            self.frame_us
        } else {
            (pts - self.last_pts).clamp(1, 1_000_000)
        } as c_ulong;
        self.last_pts = pts;
        let flags = if force_idr { sys::VPX_EFLAG_FORCE_KF as i64 } else { 0 };
        let mut key = false;
        // SAFETY: the image's planes point into `pic`, alive for the call; packets are read
        // before the next libvpx call on this context.
        unsafe {
            check(
                sys::vpx_codec_encode(
                    &mut *self.ctx,
                    &*self.img,
                    pts,
                    duration,
                    flags as sys::vpx_enc_frame_flags_t,
                    sys::VPX_DL_REALTIME as _,
                ),
                "encode",
            )?;
            let mut iter: sys::vpx_codec_iter_t = std::ptr::null();
            loop {
                let pkt = sys::vpx_codec_get_cx_data(&mut *self.ctx, &mut iter);
                if pkt.is_null() {
                    break;
                }
                if (*pkt).kind != sys::vpx_codec_cx_pkt_kind_VPX_CODEC_CX_FRAME_PKT {
                    continue;
                }
                let f = (*pkt).data.frame;
                out.extend_from_slice(std::slice::from_raw_parts(f.buf as *const u8, f.sz));
                key |= f.flags & sys::VPX_FRAME_IS_KEY != 0;
            }
        }
        Ok(key)
    }

    fn set_bitrate(&mut self, kbps: u32) {
        let kbps = kbps.max(100);
        if kbps.abs_diff(self.kbps) * 20 < self.kbps {
            return;
        }
        self.cfg.rc_target_bitrate = kbps;
        // SAFETY: a live encoder and a config it was created with.
        if unsafe { sys::vpx_codec_enc_config_set(&mut *self.ctx, &*self.cfg) }
            == sys::vpx_codec_err_t_VPX_CODEC_OK
        {
            self.kbps = kbps;
        }
    }

    fn kbps(&self) -> u32 {
        self.kbps
    }

    fn name(&self) -> String {
        self.name.clone()
    }

    fn codec(&self) -> Codec {
        Codec::Vp9
    }
}

impl Drop for Vp9Encoder {
    fn drop(&mut self) {
        // SAFETY: destroy a live context exactly once.
        unsafe { sys::vpx_codec_destroy(&mut *self.ctx) };
    }
}

pub struct Vp9Decoder {
    ctx: Box<sys::vpx_codec_ctx_t>,
}

impl Vp9Decoder {
    pub fn new(threads: u32) -> Res<Self> {
        // SAFETY: plain libvpx init on structs we own.
        unsafe {
            let mut ctx = Box::new(MaybeUninit::<sys::vpx_codec_ctx_t>::zeroed().assume_init());
            let cfg = sys::vpx_codec_dec_cfg_t { threads: threads.max(1), w: 0, h: 0 };
            check(
                sys::vpx_codec_dec_init_ver(
                    &mut *ctx,
                    sys::vpx_codec_vp9_dx(),
                    &cfg,
                    0,
                    sys::VPX_DECODER_ABI_VERSION as c_int,
                ),
                "decoder init",
            )?;
            Ok(Self { ctx })
        }
    }
}

impl VideoDecoder for Vp9Decoder {
    fn decode(&mut self, au: &[u8], out: &mut I420) -> Res<bool> {
        let mut got = false;
        // SAFETY: libvpx reads `au` during the call; the image it returns is valid until the
        // next decode call, and is copied out before then.
        unsafe {
            check(
                sys::vpx_codec_decode(
                    &mut *self.ctx,
                    au.as_ptr(),
                    au.len() as c_uint,
                    std::ptr::null_mut(),
                    0,
                ),
                "decode",
            )?;
            let mut iter: sys::vpx_codec_iter_t = std::ptr::null();
            loop {
                let img = sys::vpx_codec_get_frame(&mut *self.ctx, &mut iter);
                if img.is_null() {
                    break;
                }
                let img = &*img;
                crate::copy_planes(
                    out,
                    img.d_w as usize,
                    img.d_h as usize,
                    [img.planes[0], img.planes[1], img.planes[2]],
                    [img.stride[0] as usize, img.stride[1] as usize, img.stride[2] as usize],
                );
                got = true;
            }
        }
        Ok(got)
    }

    fn codec(&self) -> Codec {
        Codec::Vp9
    }

    fn name(&self) -> String {
        format!("libvpx {} vp9", version())
    }
}

impl Drop for Vp9Decoder {
    fn drop(&mut self) {
        // SAFETY: destroy a live context exactly once.
        unsafe { sys::vpx_codec_destroy(&mut *self.ctx) };
    }
}
