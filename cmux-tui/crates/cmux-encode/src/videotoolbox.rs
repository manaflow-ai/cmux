//! VideoToolbox H.264 encoder for macOS hosts (the hardware media engine), behind the
//! same `H264Encoder` trait as x264 and openh264. Low-latency rate control, real time,
//! no frame reordering, infinite GOP with IDR on request; output converted from the
//! length-prefixed (AVCC) form to Annex-B with SPS/PPS before every IDR.

use crate::frame_guard::{FrameGuard, keyframe_max_bytes, next_keyframe_floor};
use crate::{H264Encoder, I420, Res};

mod surface;
use std::ffi::c_void;
use std::os::raw::{c_int, c_long};
use std::ptr::{null, null_mut};
use std::sync::Mutex;
pub use surface::{ColorTag, SurfaceEncoder, SurfaceFormat, SurfaceFrame, SurfaceRect};

type CFTypeRef = *const c_void;
type CFStringRef = *const c_void;
type CFDictionaryRef = *const c_void;
type CFAllocatorRef = *const c_void;
type CFNumberRef = *const c_void;
type CFBooleanRef = *const c_void;
type CFArrayRef = *const c_void;
type OSStatus = i32;
type VTCompressionSessionRef = *mut c_void;
type CVPixelBufferRef = *mut c_void;
type CMSampleBufferRef = *mut c_void;
type CMBlockBufferRef = *mut c_void;
type CMFormatDescriptionRef = *mut c_void;

#[repr(C)]
#[derive(Clone, Copy)]
struct CMTime {
    value: i64,
    timescale: i32,
    flags: u32,
    epoch: i64,
}

const K_CM_TIME_FLAGS_VALID: u32 = 1;
const INVALID_TIME: CMTime = CMTime { value: 0, timescale: 0, flags: 0, epoch: 0 };
const CODEC_H264: u32 = u32::from_be_bytes(*b"avc1");
const PIXEL_420V: u32 = u32::from_be_bytes(*b"420v");
const CF_NUMBER_SINT32: c_long = 3;
const CF_NUMBER_FLOAT64: c_long = 6;

#[repr(C)]
struct CFDictionaryKeyCallBacks {
    _p: [u8; 0],
}
#[repr(C)]
struct CFDictionaryValueCallBacks {
    _p: [u8; 0],
}
#[repr(C)]
struct CFArrayCallBacks {
    _p: [u8; 0],
}

type OutputCallback = extern "C" fn(*mut c_void, *mut c_void, OSStatus, u32, CMSampleBufferRef);

crate::framework! {
    mod cf_sys = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation" {
        static kCFBooleanTrue: CFBooleanRef;
        static kCFBooleanFalse: CFBooleanRef;
        ref kCFTypeDictionaryKeyCallBacks: CFDictionaryKeyCallBacks;
        ref kCFTypeDictionaryValueCallBacks: CFDictionaryValueCallBacks;
        ref kCFTypeArrayCallBacks: CFArrayCallBacks;
        fn CFArrayCreate(a: CFAllocatorRef, values: *const CFTypeRef, n: c_long, cb: *const CFArrayCallBacks) -> CFArrayRef;
        fn CFDictionaryCreate(a: CFAllocatorRef, keys: *const CFTypeRef, values: *const CFTypeRef, n: c_long, kcb: *const CFDictionaryKeyCallBacks, vcb: *const CFDictionaryValueCallBacks) -> CFDictionaryRef;
        fn CFNumberCreate(a: CFAllocatorRef, t: c_long, v: *const c_void) -> CFNumberRef;
        fn CFArrayGetCount(a: CFArrayRef) -> c_long;
        fn CFArrayGetValueAtIndex(a: CFArrayRef, i: c_long) -> CFTypeRef;
        fn CFDictionaryContainsKey(d: CFDictionaryRef, k: CFTypeRef) -> u8;
        fn CFRelease(v: CFTypeRef);
    }
}
use cf_sys::*;

crate::framework! {
    mod cv_sys = "/System/Library/Frameworks/CoreVideo.framework/CoreVideo" {
        static kCVPixelBufferIOSurfacePropertiesKey: CFStringRef;
        static kCVImageBufferColorPrimaries_ITU_R_709_2: CFStringRef;
        static kCVImageBufferColorPrimaries_P3_D65: CFStringRef;
        static kCVImageBufferTransferFunction_ITU_R_709_2: CFStringRef;
        static kCVImageBufferYCbCrMatrix_ITU_R_709_2: CFStringRef;
        fn CVPixelBufferCreate(a: CFAllocatorRef, w: usize, h: usize, fmt: u32, attrs: CFDictionaryRef, out: *mut CVPixelBufferRef) -> i32;
        fn CVPixelBufferLockBaseAddress(pb: CVPixelBufferRef, flags: u64) -> i32;
        fn CVPixelBufferUnlockBaseAddress(pb: CVPixelBufferRef, flags: u64) -> i32;
        fn CVPixelBufferGetBaseAddressOfPlane(pb: CVPixelBufferRef, plane: usize) -> *mut u8;
        fn CVPixelBufferGetBytesPerRowOfPlane(pb: CVPixelBufferRef, plane: usize) -> usize;
        fn CVPixelBufferCreateWithIOSurface(a: CFAllocatorRef, surface: *mut c_void, attrs: CFDictionaryRef, out: *mut CVPixelBufferRef) -> i32;
    }
}
use cv_sys::*;

crate::framework! {
    mod iosurface_sys = "/System/Library/Frameworks/IOSurface.framework/IOSurface" {
        fn IOSurfaceGetWidth(surface: *mut c_void) -> usize;
        fn IOSurfaceGetHeight(surface: *mut c_void) -> usize;
        fn IOSurfaceGetPixelFormat(surface: *mut c_void) -> u32;
    }
}
use iosurface_sys::*;

crate::framework! {
    mod cm_sys = "/System/Library/Frameworks/CoreMedia.framework/CoreMedia" {
        static kCMSampleAttachmentKey_NotSync: CFStringRef;
        fn CMSampleBufferGetDataBuffer(sb: CMSampleBufferRef) -> CMBlockBufferRef;
        fn CMSampleBufferGetFormatDescription(sb: CMSampleBufferRef) -> CMFormatDescriptionRef;
        fn CMSampleBufferGetSampleAttachmentsArray(sb: CMSampleBufferRef, create: u8) -> CFArrayRef;
        fn CMBlockBufferGetDataLength(b: CMBlockBufferRef) -> usize;
        fn CMBlockBufferCopyDataBytes(b: CMBlockBufferRef, off: usize, len: usize, dst: *mut c_void) -> OSStatus;
        fn CMVideoFormatDescriptionGetH264ParameterSetAtIndex(d: CMFormatDescriptionRef, i: usize, ptr: *mut *const u8, size: *mut usize, count: *mut usize, nal_header_len: *mut c_int) -> OSStatus;
    }
}
use cm_sys::*;

crate::framework! {
    mod vt_sys = "/System/Library/Frameworks/VideoToolbox.framework/VideoToolbox" {
        static kVTVideoEncoderSpecification_EnableLowLatencyRateControl: CFStringRef;
        static kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: CFStringRef;
        static kVTCompressionPropertyKey_RealTime: CFStringRef;
        static kVTCompressionPropertyKey_AllowFrameReordering: CFStringRef;
        static kVTCompressionPropertyKey_MaxKeyFrameInterval: CFStringRef;
        static kVTCompressionPropertyKey_ExpectedFrameRate: CFStringRef;
        static kVTCompressionPropertyKey_AverageBitRate: CFStringRef;
        static kVTCompressionPropertyKey_DataRateLimits: CFStringRef;
        static kVTCompressionPropertyKey_ProfileLevel: CFStringRef;
        static kVTProfileLevel_H264_High_AutoLevel: CFStringRef;
        static kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel: CFStringRef;
        static kVTEncodeFrameOptionKey_ForceKeyFrame: CFStringRef;
        static kVTCompressionPropertyKey_ColorPrimaries: CFStringRef;
        static kVTCompressionPropertyKey_TransferFunction: CFStringRef;
        static kVTCompressionPropertyKey_YCbCrMatrix: CFStringRef;
        fn VTCompressionSessionCreate(a: CFAllocatorRef, w: i32, h: i32, codec: u32, spec: CFDictionaryRef, src_attrs: CFDictionaryRef, data_alloc: CFAllocatorRef, cb: OutputCallback, refcon: *mut c_void, out: *mut VTCompressionSessionRef) -> OSStatus;
        fn VTSessionSetProperty(s: *mut c_void, key: CFStringRef, value: CFTypeRef) -> OSStatus;
        fn VTCompressionSessionEncodeFrame(s: VTCompressionSessionRef, pb: CVPixelBufferRef, pts: CMTime, duration: CMTime, props: CFDictionaryRef, frame_refcon: *mut c_void, info: *mut u32) -> OSStatus;
        fn VTCompressionSessionCompleteFrames(s: VTCompressionSessionRef, until: CMTime) -> OSStatus;
        fn VTCompressionSessionInvalidate(s: VTCompressionSessionRef);
    }
}
use vt_sys::*;

// Speed keys bound apart from `vt_sys`: one missing on an older macOS (PrioritizeEncodingSpeed-
// OverQuality is macOS 12+) must not fail `frameworks()`; the session is then built without it.
crate::framework! {
    mod vt_speed_sys = "/System/Library/Frameworks/VideoToolbox.framework/VideoToolbox" {
        static kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality: CFStringRef;
        static kVTCompressionPropertyKey_MaxFrameDelayCount: CFStringRef;
    }
}

// Ultra's QP floor, bound apart for the same reason (MinAllowedFrameQP is a newer key): without
// it an ultra session keeps its frame budget and has no floor.
crate::framework! {
    mod vt_qp_sys = "/System/Library/Frameworks/VideoToolbox.framework/VideoToolbox" {
        static kVTCompressionPropertyKey_MinAllowedFrameQP: CFStringRef;
    }
}

// Ultra holds frame rate first (fleet sweep, 2026-11-16: at a 120 fps cap past 100 Mbps the
// encoder grew frames, 164 to 236 KB, instead of fps, and an uncapped target made 0.8-3.7 MB
// frames that took 13-45 ms to encode). So each frame gets about target/fps (DataRateLimits over
// one frame interval), never more than a per-pixel ceiling, and no QP ceiling fights that
// budget; extra rate buys fps first and then quality.
//
// That budget needs the regular hardware encoder. Under EnableLowLatencyRateControl
// VideoToolbox picks its realtime encoder, which refuses DataRateLimits (-12900): on an M4 Pro
// it dropped 112-116 of 120 scrolled-text frames at 1080p60 instead of shrinking them, and its
// slice QP never went below 16. The regular encoder (an ultra session) takes DataRateLimits,
// goes down to QP 11-15 on text, and encoded in 4.6 ms a frame against 5.6.

/// Ultra's QP floor: none (0). A floor only costs text (QP 18 held scrolled 1080p text to 43 dB
/// luma PSNR with errors up to 50 levels, where the encoder's own choice gave 62 dB and 2), and
/// the frame budget, not a floor, is what bounds the rate. `CMUX_RD_VT_ULTRA_MIN_QP` sets one
/// for the sweep.
pub const ULTRA_MIN_QP: i32 = NO_MIN_QP;
/// No floor.
const NO_MIN_QP: i32 = 0;
/// The most bits per pixel one ultra frame may take, whatever the target: about 0.78 MB at
/// 1080p, so a rate the link can carry never turns into frames too large to encode at the
/// frame rate.
const ULTRA_MAX_BITS_PER_PIXEL: u64 = 3;
/// Ultra's refinement frame may take this many frame budgets (within the per-pixel ceiling):
/// the screen is still, so the next frame interval has room for it.
const ULTRA_REFINE_BUDGETS: u64 = 4;
/// Ultra's QP floor for a keyframe: a 1080p IDR of dense text is 4.6 MB at the encoder's own
/// QP and still 1.8 MB at QP 22, and the encoder lets an IDR overrun DataRateLimits, so the
/// keyframe alone gets QP 30 or more; the frames after it bring the detail back.
pub const ULTRA_IDR_MIN_QP: i32 = 30;

/// Ultra's QP floor: `CMUX_RD_VT_ULTRA_MIN_QP` when it is a QP in 1-51, else [`ULTRA_MIN_QP`]
/// (none).
fn ultra_min_qp(env: Option<&str>) -> i32 {
    env.and_then(|v| v.trim().parse::<i32>().ok())
        .filter(|qp| (1..=51).contains(qp))
        .unwrap_or(ULTRA_MIN_QP)
}

/// Whether a profile runs the frame-size guard: on unless its env var says `off` (a sweep).
fn guard_enabled(env: Option<&str>) -> bool {
    env.map(str::trim) != Some("off")
}

/// Loads the frameworks the encoder binds at run time (crate::dynlib); an error says which
/// framework or symbol is missing.
// Each module's `available` also arrives through its glob import; the path names which one.
#[allow(unused_qualifications)]
fn frameworks() -> Res<()> {
    cf_sys::available()?;
    cv_sys::available()?;
    iosurface_sys::available()?;
    cm_sys::available()?;
    vt_sys::available()?;
    Ok(())
}

/// What the output callback produced for the last frame.
#[derive(Default)]
struct Output {
    annexb: Vec<u8>,
    keyframe: bool,
    status: OSStatus,
    /// The callback ran for the current frame.
    produced: bool,
}

pub struct VideoToolbox {
    session: VTCompressionSessionRef,
    /// The size the session encodes (a surface of another size recreates it).
    session_size: (usize, usize),
    /// The I420 path's pixel buffer, at `width` x `height`.
    pixel_buffer: CVPixelBufferRef,
    out: Box<Mutex<Output>>,
    width: usize,
    height: usize,
    fps: u32,
    baseline: bool,
    kbps: u32,
    /// The color tag the session carries (surface path); `None` until set.
    color: Option<ColorTag>,
    name: String,
    /// The ultra profile: frame rate first ([`VideoToolbox::set_ultra`]).
    ultra: bool,
    /// Ultra's QP floor ([`ULTRA_MIN_QP`] or its override).
    ultra_min_qp: i32,
    /// The next frame is ultra's refinement of a still screen ([`ULTRA_REFINE_BUDGETS`]).
    refine_next: bool,
    /// The frame-size guard, both profiles: each frame's QP floor from its damage and budget.
    guard: FrameGuard,
    /// Pixels of damage in the next frame (the whole picture until the caller says).
    changed_next: Option<u64>,
    /// Ultra runs the frame-size guard (`CMUX_RD_VT_ULTRA_GUARD=off` turns it off for a sweep).
    ultra_guard_on: bool,
    /// Standard runs the frame-size guard (`CMUX_RD_VT_STANDARD_GUARD=off` turns it off for a
    /// sweep).
    standard_guard_on: bool,
    /// Ultra's keyframe floor: [`ULTRA_IDR_MIN_QP`], raised after a keyframe over
    /// [`keyframe_max_bytes`] ([`next_keyframe_floor`]).
    idr_floor: i32,
    /// The MinAllowedFrameQP last set on the session.
    applied_min_qp: i32,
    /// The session was created with low-latency rate control (standard); an ultra session is
    /// not ([`create_session`]).
    session_low_latency: bool,
}

// SAFETY: the session and buffer are used from one thread at a time (the media loop).
unsafe impl Send for VideoToolbox {}

fn number_i32(v: i32) -> CFNumberRef {
    // SAFETY: a local value read by CFNumberCreate.
    unsafe { CFNumberCreate(null(), CF_NUMBER_SINT32, (&v as *const i32).cast()) }
}

fn number_f64(v: f64) -> CFNumberRef {
    // SAFETY: as above.
    unsafe { CFNumberCreate(null(), CF_NUMBER_FLOAT64, (&v as *const f64).cast()) }
}

/// The per-frame byte budget at `kbps` and `fps`: (bytes, seconds) for DataRateLimits, one
/// frame interval's share of the rate. A frame within it leaves a paced sender in one frame
/// interval, so the send stage holds at most one frame at any rate (the encoder spends a
/// higher QP on a large change instead of a frame that queues for hundreds of ms).
fn frame_budget(kbps: u32, fps: u32) -> (i32, f64) {
    let fps = fps.max(1);
    let bytes = u64::from(kbps.min(2_000_000)) * 1000 / 8 / u64::from(fps);
    (i32::try_from(bytes.max(1)).unwrap_or(i32::MAX), 1.0 / f64::from(fps))
}

/// Ultra's per-frame budget at `kbps` and `fps` for a `pixels` picture: one frame interval's
/// share of the rate ([`frame_budget`]) times `budgets`, at most [`ULTRA_MAX_BITS_PER_PIXEL`].
fn ultra_frame_budget(kbps: u32, fps: u32, pixels: usize, budgets: u64) -> (i32, f64) {
    let (bytes, seconds) = frame_budget(kbps, fps);
    let ceiling = (pixels as u64).saturating_mul(ULTRA_MAX_BITS_PER_PIXEL) / 8;
    let bytes = (u64::try_from(bytes).unwrap_or(0).saturating_mul(budgets)).min(ceiling.max(1));
    (i32::try_from(bytes.max(1)).unwrap_or(i32::MAX), seconds)
}

/// The encoder's name: profile, rate control (low-latency for standard, the regular encoder's
/// frame budget for ultra) and the fixed settings.
fn session_name(baseline: bool, ultra: bool) -> String {
    format!(
        "videotoolbox h264 {} {} realtime no-reordering gop=inf{}",
        if baseline { "constrained-baseline" } else { "high" },
        if ultra { "frame-budget-rc" } else { "low-latency-rc" },
        if ultra { " ultra" } else { "" },
    )
}

/// Whether a new target replaces the session's rate. A cut applies at once (the link has
/// less room now); a rise under 5% is skipped, since every change makes the encoder
/// re-plan its rate control.
fn bitrate_change_applies(current: u32, next: u32) -> bool {
    next < current || u64::from(next - current) * 20 >= u64::from(current)
}

fn dict(pairs: &[(CFStringRef, CFTypeRef)]) -> CFDictionaryRef {
    let keys: Vec<CFTypeRef> = pairs.iter().map(|p| p.0).collect();
    let values: Vec<CFTypeRef> = pairs.iter().map(|p| p.1).collect();
    // SAFETY: equal-length key/value arrays of CF objects with the standard callbacks.
    unsafe {
        CFDictionaryCreate(
            null(),
            keys.as_ptr(),
            values.as_ptr(),
            pairs.len() as c_long,
            kCFTypeDictionaryKeyCallBacks(),
            kCFTypeDictionaryValueCallBacks(),
        )
    }
}

extern "C" fn on_output(
    refcon: *mut c_void,
    _frame: *mut c_void,
    status: OSStatus,
    _flags: u32,
    sb: CMSampleBufferRef,
) {
    // SAFETY: refcon is the Box<Mutex<Output>> owned by the encoder, alive for the session.
    let out = unsafe { &*(refcon as *const Mutex<Output>) };
    let Ok(mut out) = out.lock() else { return };
    out.produced = true;
    out.status = status;
    out.annexb.clear();
    if status != 0 || sb.is_null() {
        return;
    }
    // SAFETY: CoreMedia getters on a valid sample buffer for the duration of the callback.
    unsafe {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, 0);
        let not_sync = !attachments.is_null()
            && CFArrayGetCount(attachments) > 0
            && CFDictionaryContainsKey(
                CFArrayGetValueAtIndex(attachments, 0),
                kCMSampleAttachmentKey_NotSync(),
            ) != 0;
        out.keyframe = !not_sync;
        if out.keyframe {
            let desc = CMSampleBufferGetFormatDescription(sb);
            let mut count = 0usize;
            let mut header = 0 as c_int;
            let mut i = 0usize;
            loop {
                let mut ptr: *const u8 = null();
                let mut size = 0usize;
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    desc,
                    i,
                    &mut ptr,
                    &mut size,
                    &mut count,
                    &mut header,
                ) != 0
                {
                    break;
                }
                out.annexb.extend_from_slice(&[0, 0, 0, 1]);
                out.annexb.extend_from_slice(std::slice::from_raw_parts(ptr, size));
                i += 1;
                if i >= count {
                    break;
                }
            }
        }
        let block = CMSampleBufferGetDataBuffer(sb);
        let len = CMBlockBufferGetDataLength(block);
        let mut avcc = vec![0u8; len];
        if CMBlockBufferCopyDataBytes(block, 0, len, avcc.as_mut_ptr().cast()) != 0 {
            out.status = -1;
            return;
        }
        // Length-prefixed (4 bytes, big-endian) NAL units to Annex-B start codes.
        let mut at = 0usize;
        while at + 4 <= avcc.len() {
            let n =
                u32::from_be_bytes([avcc[at], avcc[at + 1], avcc[at + 2], avcc[at + 3]]) as usize;
            at += 4;
            if at + n > avcc.len() {
                break;
            }
            out.annexb.extend_from_slice(&[0, 0, 0, 1]);
            out.annexb.extend_from_slice(&avcc[at..at + n]);
            at += n;
        }
    }
}

/// A hardware H.264 session at `width` x `height` whose output callback writes into `out`
/// (which must outlive the session). `low_latency`: VideoToolbox's low-latency rate control
/// (standard); off, the regular hardware encoder, which honors DataRateLimits (ultra).
fn create_session(
    width: usize,
    height: usize,
    fps: u32,
    baseline: bool,
    low_latency: bool,
    out: &Mutex<Output>,
) -> Res<VTCompressionSessionRef> {
    let mut session: VTCompressionSessionRef = null_mut();
    // SAFETY: CF statics from the frameworks; the dictionary is released after use.
    let status = unsafe {
        let low_latency = if low_latency { kCFBooleanTrue() } else { kCFBooleanFalse() };
        let spec = dict(&[
            (kVTVideoEncoderSpecification_EnableLowLatencyRateControl(), low_latency),
            (
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder(),
                kCFBooleanTrue(),
            ),
        ]);
        let s = VTCompressionSessionCreate(
            null(),
            width as i32,
            height as i32,
            CODEC_H264,
            spec,
            null(),
            null(),
            on_output,
            (out as *const Mutex<Output>).cast_mut().cast(),
            &mut session,
        );
        CFRelease(spec);
        s
    };
    if status != 0 || session.is_null() {
        return Err(format!("VTCompressionSessionCreate failed: {status}").into());
    }
    // SAFETY: setting properties on our live session with CF values we release.
    unsafe {
        let set = |k: CFStringRef, v: CFTypeRef| VTSessionSetProperty(session, k, v);
        set(kVTCompressionPropertyKey_RealTime(), kCFBooleanTrue());
        set(kVTCompressionPropertyKey_AllowFrameReordering(), kCFBooleanFalse());
        let profile = if baseline {
            kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel()
        } else {
            kVTProfileLevel_H264_High_AutoLevel()
        };
        set(kVTCompressionPropertyKey_ProfileLevel(), profile);
        let gop = number_i32(i32::MAX);
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval(), gop);
        CFRelease(gop);
        let rate = number_f64(f64::from(fps.max(1)));
        set(kVTCompressionPropertyKey_ExpectedFrameRate(), rate);
        CFRelease(rate);
        // Lower latency per frame: speed over quality (as the app's SurfaceFrameEncoder sets),
        // and no frame held back inside the encoder. Optional: an OS without the keys, or an
        // encoder that refuses one, keeps the session as built above.
        if vt_speed_sys::available().is_ok() {
            set(
                vt_speed_sys::kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality(),
                kCFBooleanTrue(),
            );
            let no_delay = number_i32(0);
            set(vt_speed_sys::kVTCompressionPropertyKey_MaxFrameDelayCount(), no_delay);
            CFRelease(no_delay);
        }
    }
    Ok(session)
}

impl VideoToolbox {
    /// `baseline`: constrained baseline (for openh264-decoded checks); otherwise High.
    pub fn new(width: u32, height: u32, fps: u32, kbps: u32, baseline: bool) -> Res<Self> {
        frameworks()?;
        let out: Box<Mutex<Output>> = Box::default();
        let session = create_session(width as usize, height as usize, fps, baseline, true, &out)?;
        let mut pixel_buffer: CVPixelBufferRef = null_mut();
        // SAFETY: creating an IOSurface-backed 420v buffer; attrs released after use.
        let pb_status = unsafe {
            let empty = dict(&[]);
            let attrs = dict(&[(kCVPixelBufferIOSurfacePropertiesKey(), empty)]);
            let r = CVPixelBufferCreate(
                null(),
                width as usize,
                height as usize,
                PIXEL_420V,
                attrs,
                &mut pixel_buffer,
            );
            CFRelease(attrs);
            CFRelease(empty);
            r
        };
        if pb_status != 0 {
            // SAFETY: invalidating and releasing the session we created.
            unsafe {
                VTCompressionSessionInvalidate(session);
                CFRelease(session as CFTypeRef);
            }
            return Err(format!("CVPixelBufferCreate failed: {pb_status}").into());
        }
        let mut this = Self {
            session,
            session_size: (width as usize, height as usize),
            pixel_buffer,
            out,
            width: width as usize,
            height: height as usize,
            fps,
            baseline,
            kbps: kbps.max(100),
            color: None,
            name: session_name(baseline, false),
            ultra: false,
            ultra_min_qp: ultra_min_qp(std::env::var("CMUX_RD_VT_ULTRA_MIN_QP").ok().as_deref()),
            refine_next: false,
            guard: FrameGuard::default(),
            changed_next: None,
            idr_floor: ULTRA_IDR_MIN_QP,
            ultra_guard_on: guard_enabled(std::env::var("CMUX_RD_VT_ULTRA_GUARD").ok().as_deref()),
            standard_guard_on: guard_enabled(
                std::env::var("CMUX_RD_VT_STANDARD_GUARD").ok().as_deref(),
            ),
            applied_min_qp: NO_MIN_QP,
            session_low_latency: true,
        };
        this.apply_bitrate(this.kbps);
        Ok(this)
    }

    /// Makes the session encode `width` x `height` with the profile's rate control, recreating
    /// it on a change. Returns true when it was recreated (the next frame must be an IDR).
    fn ensure_session(&mut self, width: usize, height: usize) -> Res<bool> {
        let low_latency = !self.ultra;
        if self.session_size == (width, height) && self.session_low_latency == low_latency {
            return Ok(false);
        }
        let session =
            create_session(width, height, self.fps, self.baseline, low_latency, &self.out)?;
        // SAFETY: invalidating and releasing our previous session once.
        unsafe {
            VTCompressionSessionInvalidate(self.session);
            CFRelease(self.session as CFTypeRef);
        }
        self.session = session;
        self.session_size = (width, height);
        self.session_low_latency = low_latency;
        self.color = None;
        self.apply_bitrate(self.kbps);
        self.applied_min_qp = NO_MIN_QP;
        if self.ultra_min_qp != NO_MIN_QP && self.ultra {
            self.apply_min_qp(self.ultra_min_qp);
        }
        Ok(true)
    }

    /// Turns the ultra profile on or off from the next frame, which recreates the session (and
    /// so is an IDR): on, the regular hardware encoder, each frame one frame interval's share
    /// of the target within a per-pixel ceiling; off, today's low-latency session.
    pub fn set_ultra(&mut self, on: bool) {
        if self.ultra == on {
            return;
        }
        self.ultra = on;
        self.refine_next = false;
        self.guard = FrameGuard::default();
        self.idr_floor = ULTRA_IDR_MIN_QP;
        self.name = session_name(self.baseline, on);
    }

    /// Pixels of damage in the next frame, for the frame-size guard. Without it the guard
    /// takes the whole picture as changed.
    pub fn set_changed_pixels(&mut self, pixels: u64) {
        self.changed_next = Some(pixels);
    }

    /// Turns the frame-size guard on (the default) or off on both profiles, for a measurement.
    pub fn set_guard(&mut self, on: bool) {
        self.ultra_guard_on = on;
        self.standard_guard_on = on;
    }

    /// The frame-size guard: the floor it set for the last frame and its learned bytes per
    /// changed pixel at QP 0.
    pub fn guard(&self) -> &FrameGuard {
        &self.guard
    }

    /// Ultra only: the next frame refines a still screen with [`ULTRA_REFINE_BUDGETS`] frame
    /// budgets and no QP floor.
    pub fn set_refine(&mut self, on: bool) {
        self.refine_next = on && self.ultra;
    }

    /// The configured QP floor: ultra's [`ULTRA_MIN_QP`] or its override, none on standard.
    fn configured_min_qp(&self) -> i32 {
        if self.ultra { self.ultra_min_qp } else { NO_MIN_QP }
    }

    /// The configured QP floor, `None` when there is none (standard, and ultra by default).
    /// The frame-size guard's per-frame floor is apart ([`Self::guard`]).
    pub fn min_qp(&self) -> Option<i32> {
        (self.ultra && self.ultra_min_qp != NO_MIN_QP).then_some(self.ultra_min_qp)
    }

    /// Ultra's per-frame byte budget now (DataRateLimits bytes), `None` when standard.
    pub fn ultra_frame_bytes(&self) -> Option<usize> {
        self.ultra.then(|| {
            let pixels = self.session_size.0 * self.session_size.1;
            ultra_frame_budget(self.kbps, self.fps, pixels, 1).0 as usize
        })
    }

    /// Sets the session's QP floor. Optional like the speed keys: an OS without the key, or an
    /// encoder that refuses it, keeps the frame budget alone.
    fn apply_min_qp(&mut self, qp: i32) -> bool {
        if vt_qp_sys::available().is_err() {
            return false;
        }
        let value = number_i32(qp);
        // SAFETY: our live session; the number is released after the session retains it.
        let status = unsafe {
            let s = VTSessionSetProperty(
                self.session,
                vt_qp_sys::kVTCompressionPropertyKey_MinAllowedFrameQP(),
                value,
            );
            CFRelease(value);
            s
        };
        if status == 0 {
            self.applied_min_qp = qp;
        }
        status == 0
    }

    /// Tags the session's output with `color` (primaries, transfer, matrix).
    fn apply_color(&mut self, color: ColorTag) {
        if self.color == Some(color) {
            return;
        }
        // SAFETY: CF statics from the frameworks set on our live session.
        unsafe {
            let primaries = match color {
                ColorTag::Srgb => kCVImageBufferColorPrimaries_ITU_R_709_2(),
                ColorTag::DisplayP3 => kCVImageBufferColorPrimaries_P3_D65(),
            };
            VTSessionSetProperty(
                self.session,
                kVTCompressionPropertyKey_ColorPrimaries(),
                primaries,
            );
            VTSessionSetProperty(
                self.session,
                kVTCompressionPropertyKey_TransferFunction(),
                kCVImageBufferTransferFunction_ITU_R_709_2(),
            );
            VTSessionSetProperty(
                self.session,
                kVTCompressionPropertyKey_YCbCrMatrix(),
                kCVImageBufferYCbCrMatrix_ITU_R_709_2(),
            );
        }
        self.color = Some(color);
    }

    /// Sets the average rate and the per-frame byte budget (`frame_budget`): VideoToolbox's
    /// DataRateLimits over one frame interval, so one frame drains within one frame interval
    /// at the current rate. A budget the encoder refuses leaves only the average rate.
    /// Ultra: the same one frame interval's share, within the per-pixel ceiling
    /// ([`ultra_frame_budget`]).
    fn apply_bitrate(&mut self, kbps: u32) {
        self.apply_rate(kbps, 1);
    }

    /// [`Self::apply_bitrate`] with ultra's frame budget `budgets` times as large (the
    /// refinement frame).
    fn apply_rate(&mut self, kbps: u32, budgets: u64) {
        let bps = number_i32((kbps.min(2_000_000) * 1000) as i32);
        let pixels = self.session_size.0 * self.session_size.1;
        let (bytes, seconds) = if self.ultra {
            ultra_frame_budget(kbps, self.fps, pixels, budgets)
        } else {
            frame_budget(kbps, self.fps)
        };
        // SAFETY: our live session; every CF object is released after use (the array
        // retains its numbers, the session retains the array).
        unsafe {
            VTSessionSetProperty(self.session, kVTCompressionPropertyKey_AverageBitRate(), bps);
            CFRelease(bps);
            let bytes = number_i32(bytes);
            let seconds = number_f64(seconds);
            let pair = [bytes, seconds];
            let limits = CFArrayCreate(null(), pair.as_ptr(), 2, kCFTypeArrayCallBacks());
            if !limits.is_null() {
                VTSessionSetProperty(
                    self.session,
                    kVTCompressionPropertyKey_DataRateLimits(),
                    limits,
                );
                CFRelease(limits);
            }
            CFRelease(bytes);
            CFRelease(seconds);
        }
        self.kbps = kbps;
    }

    /// Copies I420 into the NV12 (420v) pixel buffer.
    fn fill(&mut self, pic: &I420) -> Res<()> {
        let (w, h) = (self.width.min(pic.width), self.height);
        let cw = pic.width / 2;
        // SAFETY: lock, write within each plane's rows and bytes-per-row, unlock.
        unsafe {
            if CVPixelBufferLockBaseAddress(self.pixel_buffer, 0) != 0 {
                return Err("CVPixelBufferLockBaseAddress failed".into());
            }
            let y = CVPixelBufferGetBaseAddressOfPlane(self.pixel_buffer, 0);
            let ys = CVPixelBufferGetBytesPerRowOfPlane(self.pixel_buffer, 0);
            for row in 0..h.min(pic.y.len() / pic.width.max(1)) {
                std::ptr::copy_nonoverlapping(
                    pic.y.as_ptr().add(row * pic.width),
                    y.add(row * ys),
                    w,
                );
            }
            let uv = CVPixelBufferGetBaseAddressOfPlane(self.pixel_buffer, 1);
            let uvs = CVPixelBufferGetBytesPerRowOfPlane(self.pixel_buffer, 1);
            for row in 0..(h / 2).min(pic.u.len() / cw.max(1)) {
                let dst = uv.add(row * uvs);
                for col in 0..(w / 2) {
                    *dst.add(2 * col) = pic.u[row * cw + col];
                    *dst.add(2 * col + 1) = pic.v[row * cw + col];
                }
            }
            CVPixelBufferUnlockBaseAddress(self.pixel_buffer, 0);
        }
        Ok(())
    }
}

impl H264Encoder for VideoToolbox {
    fn encode(&mut self, pic: &I420, force_idr: bool, pts: i64, out: &mut Vec<u8>) -> Res<bool> {
        // A surface of another size may have resized the session.
        let resized = self.ensure_session(self.width, self.height)?;
        self.fill(pic)?;
        let pb = self.pixel_buffer;
        self.encode_buffer(pb, force_idr || resized, pts, out)
    }

    fn set_bitrate(&mut self, kbps: u32) {
        let kbps = kbps.max(100);
        if bitrate_change_applies(self.kbps, kbps) {
            self.apply_bitrate(kbps);
        }
    }

    fn kbps(&self) -> u32 {
        self.kbps
    }

    fn name(&self) -> String {
        self.name.clone()
    }
}

impl VideoToolbox {
    /// Encodes one pixel buffer synchronously: the output callback has run
    /// when this returns.
    fn encode_buffer(
        &mut self,
        pixel_buffer: CVPixelBufferRef,
        force_idr: bool,
        pts: i64,
        out: &mut Vec<u8>,
    ) -> Res<bool> {
        if let Ok(mut o) = self.out.lock() {
            *o = Output::default();
        }
        // Ultra's keyframe: this frame alone with a high floor, then back. VideoToolbox does not
        // hold an IDR to DataRateLimits (the fleet sweep's 1080p keyframes ran 2.4 MB on text and
        // 3.6 MB on noise at a one-frame-interval budget), so the floor is what keeps it small;
        // the frames after it, and the still screen's refinement, bring the detail back.
        let idr = force_idr && self.ultra;
        // Ultra's refinement: this frame alone with a larger budget and no floor, then back.
        let refine = std::mem::take(&mut self.refine_next) && self.ultra && !idr;
        let pixels = self.session_size.0 * self.session_size.1;
        let changed = self.changed_next.take().unwrap_or(pixels as u64).min(pixels as u64);
        // Every other frame, on either profile: the floor the guard picks from its damage and
        // one frame's budget, never under a configured floor. A floor only ever makes a frame
        // smaller. It is never a QP ceiling, which made the low-latency encoder drop frames
        // instead of shrinking them. Standard's low-latency encoder refuses DataRateLimits, so
        // without the guard a change after a still screen spends the saved-up rate (257/199/148
        // KB against an 8.3 KB budget at 512x256, 2 Mbps, 30 fps on a fleet Mac).
        let guard_on = if self.ultra { self.ultra_guard_on } else { self.standard_guard_on };
        let guarded = guard_on && !force_idr && !refine;
        let floor = if idr {
            self.idr_floor.max(self.ultra_min_qp)
        } else if refine {
            self.apply_rate(self.kbps, ULTRA_REFINE_BUDGETS);
            NO_MIN_QP
        } else if guarded {
            let budget = if self.ultra {
                ultra_frame_budget(self.kbps, self.fps, pixels, 1).0
            } else {
                frame_budget(self.kbps, self.fps).0
            };
            self.guard.before(changed, budget as usize).max(self.configured_min_qp())
        } else {
            // Standard's keyframe, and any frame with the guard off: the configured floor (none
            // on standard, as before the guard).
            self.configured_min_qp()
        };
        if floor != self.applied_min_qp {
            self.apply_min_qp(floor);
        }
        let result = self.encode_buffer_at(pixel_buffer, force_idr, pts, out);
        if refine {
            self.apply_bitrate(self.kbps);
        }
        if guarded && result.is_ok() {
            self.guard.after(changed, out.len());
        }
        if idr && result.is_ok() && !out.is_empty() {
            let max = keyframe_max_bytes(pixels);
            self.idr_floor = next_keyframe_floor(self.idr_floor, out.len(), max, ULTRA_IDR_MIN_QP);
        }
        result
    }

    fn encode_buffer_at(
        &mut self,
        pixel_buffer: CVPixelBufferRef,
        force_idr: bool,
        pts: i64,
        out: &mut Vec<u8>,
    ) -> Res<bool> {
        // `pts` is the capture time in microseconds (the trait's contract).
        let time =
            CMTime { value: pts, timescale: 1_000_000, flags: K_CM_TIME_FLAGS_VALID, epoch: 0 };
        // SAFETY: encoding our pixel buffer on our session; CompleteFrames runs the output
        // callback before it returns, so the result is ready afterwards.
        let status = unsafe {
            let props = if force_idr {
                dict(&[(kVTEncodeFrameOptionKey_ForceKeyFrame(), kCFBooleanTrue())])
            } else {
                null()
            };
            let mut info = 0u32;
            let s = VTCompressionSessionEncodeFrame(
                self.session,
                pixel_buffer,
                time,
                INVALID_TIME,
                props,
                null_mut(),
                &mut info,
            );
            if !props.is_null() {
                CFRelease(props);
            }
            if s == 0 { VTCompressionSessionCompleteFrames(self.session, INVALID_TIME) } else { s }
        };
        if status != 0 {
            return Err(format!("VideoToolbox encode failed: {status}").into());
        }
        let result = self.out.lock().map_err(|_| "output lock poisoned")?;
        if !result.produced {
            // No callback for this frame (dropped): nothing to send.
            out.clear();
            return Ok(false);
        }
        if result.status != 0 {
            return Err(format!("VideoToolbox output status {}", result.status).into());
        }
        out.clear();
        out.extend_from_slice(&result.annexb);
        Ok(result.keyframe && !out.is_empty())
    }
}

impl Drop for VideoToolbox {
    fn drop(&mut self) {
        // SAFETY: invalidating and releasing our own session and buffer once.
        unsafe {
            VTCompressionSessionInvalidate(self.session);
            CFRelease(self.session as CFTypeRef);
            CFRelease(self.pixel_buffer as CFTypeRef);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_frame_budget_is_one_frame_intervals_share_of_the_rate() {
        assert_eq!(frame_budget(8_000, 60), (16_666, 1.0 / 60.0));
        assert_eq!(frame_budget(1_000, 30).0, 4_166);
        assert_eq!(frame_budget(100, 0), (12_500, 1.0), "fps 0 counts as 1");
        assert!(frame_budget(u32::MAX, 1).0 > 0, "clamped, never negative");
    }

    #[test]
    fn ultra_holds_frame_rate_first_within_a_per_pixel_ceiling() {
        const P1080: usize = 1920 * 1080;
        // 150 Mbps at 120 fps: one frame interval's share, as standard.
        assert_eq!(ultra_frame_budget(150_000, 120, P1080, 1), frame_budget(150_000, 120));
        assert_eq!(ultra_frame_budget(150_000, 120, P1080, 1).0, 156_250);
        // An uncapped target (the sweep's 770 Mbps) stops at 3 bits per pixel: under 1 MB.
        assert_eq!(ultra_frame_budget(770_000, 120, P1080, 1), (777_600, 1.0 / 120.0));
        assert_eq!(ultra_frame_budget(u32::MAX, 1, P1080, 1).0, 777_600);
        // The refinement gets four budgets, still within the ceiling.
        assert_eq!(ultra_frame_budget(150_000, 120, P1080, 4).0, 625_000);
        assert_eq!(ultra_frame_budget(400_000, 120, P1080, 4).0, 777_600);
        assert!(ultra_frame_budget(100, 120, 0, 1).0 > 0, "never zero");
    }

    #[test]
    fn the_frame_guard_is_on_unless_a_sweep_says_off() {
        assert!(guard_enabled(None));
        assert!(guard_enabled(Some("on")));
        assert!(guard_enabled(Some("")));
        assert!(!guard_enabled(Some("off")));
        assert!(!guard_enabled(Some(" off\n")));
    }

    #[test]
    fn ultras_qp_floor_defaults_and_overrides() {
        assert_eq!(ultra_min_qp(None), NO_MIN_QP, "no floor by default");
        assert_eq!(ultra_min_qp(Some("20")), 20);
        assert_eq!(ultra_min_qp(Some(" 22 ")), 22);
        assert_eq!(ultra_min_qp(Some("0")), NO_MIN_QP, "0 is out of range");
        assert_eq!(ultra_min_qp(Some("52")), NO_MIN_QP, "past H.264's range");
        assert_eq!(ultra_min_qp(Some("x")), NO_MIN_QP);
    }

    #[test]
    fn the_name_says_which_rate_control_runs() {
        assert_eq!(
            session_name(false, false),
            "videotoolbox h264 high low-latency-rc realtime no-reordering gop=inf"
        );
        assert_eq!(
            session_name(true, true),
            "videotoolbox h264 constrained-baseline frame-budget-rc realtime no-reordering gop=inf ultra"
        );
    }

    #[test]
    fn a_bitrate_cut_applies_at_once_and_a_small_rise_waits() {
        assert!(bitrate_change_applies(10_000, 9_900), "a 1% cut");
        assert!(bitrate_change_applies(10_000, 5_000));
        assert!(!bitrate_change_applies(10_000, 10_400), "a 4% rise");
        assert!(bitrate_change_applies(10_000, 10_500), "a 5% rise");
        assert!(!bitrate_change_applies(10_000, 10_000));
    }
}
