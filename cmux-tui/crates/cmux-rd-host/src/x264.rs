//! x264 through the C shim in csrc/x264_shim.c (feature `x264`): zerolatency, infinite GOP,
//! IDR on request, ABR with a one-frame VBV whose target follows congestion control.

use crate::encoder::H264Encoder;
use crate::Res;
use cmux_encode::I420;
use std::ffi::{c_char, c_int, CStr, CString};

#[repr(C)]
struct Raw {
    _private: [u8; 0],
}

extern "C" {
    fn rd_x264_build() -> *const c_char;
    #[allow(clippy::too_many_arguments)]
    fn rd_x264_open(
        w: c_int,
        h: c_int,
        fps: c_int,
        qp: c_int,
        kbps: c_int,
        threads: c_int,
        preset: *const c_char,
        profile: *const c_char,
    ) -> *mut Raw;
    #[allow(clippy::too_many_arguments)]
    fn rd_x264_encode(
        r: *mut Raw,
        y: *mut u8,
        u: *mut u8,
        v: *mut u8,
        ys: c_int,
        cs: c_int,
        idr: c_int,
        pts: i64,
        out: *mut *const u8,
        is_idr: *mut c_int,
    ) -> c_int;
    fn rd_x264_set_bitrate(r: *mut Raw, kbps: c_int, fps: c_int) -> c_int;
    fn rd_x264_close(r: *mut Raw);
}

pub struct X264 {
    raw: *mut Raw,
    fps: u32,
    kbps: u32,
    pub name: String,
}

// SAFETY: one encoder instance used by one thread at a time.
unsafe impl Send for X264 {}

impl X264 {
    pub fn new(
        width: u32,
        height: u32,
        fps: u32,
        kbps: u32,
        threads: u16,
        preset: &str,
        profile: &str,
    ) -> Res<Self> {
        let preset_c = CString::new(preset)?;
        let profile_c = CString::new(profile)?;
        // SAFETY: valid C strings and plain integers; NULL on failure.
        let raw = unsafe {
            rd_x264_open(
                width as c_int,
                height as c_int,
                fps as c_int,
                -1,
                kbps as c_int,
                c_int::from(threads.max(1)),
                preset_c.as_ptr(),
                profile_c.as_ptr(),
            )
        };
        if raw.is_null() {
            return Err("x264 open failed".into());
        }
        // SAFETY: static NUL-terminated string from the shim.
        let build = unsafe { CStr::from_ptr(rd_x264_build()) }.to_string_lossy().into_owned();
        let name = format!("{build} preset={preset} tune=zerolatency profile={profile} abr vbv=1frame gop=inf bframes=0");
        Ok(Self { raw, fps, kbps, name })
    }

    /// Retargets the bitrate when it moved more than 5 %.
    pub fn set_bitrate(&mut self, kbps: u32) {
        let kbps = kbps.max(100);
        if kbps.abs_diff(self.kbps) * 20 < self.kbps {
            return;
        }
        // SAFETY: our own encoder, between frames.
        if unsafe { rd_x264_set_bitrate(self.raw, kbps as c_int, self.fps as c_int) } >= 0 {
            self.kbps = kbps;
        }
    }

    pub fn kbps(&self) -> u32 {
        self.kbps
    }

    /// Encodes one picture into `out`; returns true for an IDR.
    pub fn encode(
        &mut self,
        pic: &I420,
        force_idr: bool,
        pts: i64,
        out: &mut Vec<u8>,
    ) -> Res<bool> {
        out.clear();
        let mut ptr: *const u8 = std::ptr::null();
        let mut idr: c_int = 0;
        let cw = (pic.width / 2) as c_int;
        // SAFETY: x264 only reads the planes; `ptr` stays valid until the next encode call.
        let n = unsafe {
            rd_x264_encode(
                self.raw,
                pic.y.as_ptr().cast_mut(),
                pic.u.as_ptr().cast_mut(),
                pic.v.as_ptr().cast_mut(),
                pic.width as c_int,
                cw,
                c_int::from(force_idr),
                pts,
                &mut ptr,
                &mut idr,
            )
        };
        if n < 0 {
            return Err("x264 encode failed".into());
        }
        if n > 0 && !ptr.is_null() {
            // SAFETY: the shim returns `n` contiguous bytes at `ptr`.
            out.extend_from_slice(unsafe { std::slice::from_raw_parts(ptr, n as usize) });
        }
        Ok(idr != 0)
    }
}

impl H264Encoder for X264 {
    fn encode(&mut self, pic: &I420, force_idr: bool, pts: i64, out: &mut Vec<u8>) -> Res<bool> {
        X264::encode(self, pic, force_idr, pts, out)
    }

    fn set_bitrate(&mut self, kbps: u32) {
        X264::set_bitrate(self, kbps);
    }

    fn kbps(&self) -> u32 {
        X264::kbps(self)
    }

    fn name(&self) -> String {
        self.name.clone()
    }
}

impl Drop for X264 {
    fn drop(&mut self) {
        // SAFETY: closing our own encoder once.
        unsafe { rd_x264_close(self.raw) };
    }
}
