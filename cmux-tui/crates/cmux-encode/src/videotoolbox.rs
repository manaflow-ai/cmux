//! VideoToolbox H.264 encoder for macOS hosts (the hardware media engine), behind the
//! same `H264Encoder` trait as x264 and openh264. Low-latency rate control, real time,
//! no frame reordering, infinite GOP with IDR on request; output converted from the
//! length-prefixed (AVCC) form to Annex-B with SPS/PPS before every IDR.

use crate::{H264Encoder, I420, Res};

mod surface;
pub use surface::{ColorTag, SurfaceEncoder, SurfaceFormat, SurfaceFrame, SurfaceRect};
use std::ffi::c_void;
use std::os::raw::{c_int, c_long};
use std::ptr::{null, null_mut};
use std::sync::Mutex;

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

type OutputCallback = extern "C" fn(*mut c_void, *mut c_void, OSStatus, u32, CMSampleBufferRef);

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    static kCFBooleanTrue: CFBooleanRef;
    static kCFBooleanFalse: CFBooleanRef;
    static kCFTypeDictionaryKeyCallBacks: CFDictionaryKeyCallBacks;
    static kCFTypeDictionaryValueCallBacks: CFDictionaryValueCallBacks;
    fn CFDictionaryCreate(
        a: CFAllocatorRef,
        keys: *const CFTypeRef,
        values: *const CFTypeRef,
        n: c_long,
        kcb: *const CFDictionaryKeyCallBacks,
        vcb: *const CFDictionaryValueCallBacks,
    ) -> CFDictionaryRef;
    fn CFNumberCreate(a: CFAllocatorRef, t: c_long, v: *const c_void) -> CFNumberRef;
    fn CFArrayGetCount(a: CFArrayRef) -> c_long;
    fn CFArrayGetValueAtIndex(a: CFArrayRef, i: c_long) -> CFTypeRef;
    fn CFDictionaryContainsKey(d: CFDictionaryRef, k: CFTypeRef) -> u8;
    fn CFRelease(v: CFTypeRef);
}

#[link(name = "CoreVideo", kind = "framework")]
unsafe extern "C" {
    static kCVPixelBufferIOSurfacePropertiesKey: CFStringRef;
    fn CVPixelBufferCreate(
        a: CFAllocatorRef,
        w: usize,
        h: usize,
        fmt: u32,
        attrs: CFDictionaryRef,
        out: *mut CVPixelBufferRef,
    ) -> i32;
    fn CVPixelBufferLockBaseAddress(pb: CVPixelBufferRef, flags: u64) -> i32;
    fn CVPixelBufferUnlockBaseAddress(pb: CVPixelBufferRef, flags: u64) -> i32;
    fn CVPixelBufferGetBaseAddressOfPlane(pb: CVPixelBufferRef, plane: usize) -> *mut u8;
    fn CVPixelBufferGetBytesPerRowOfPlane(pb: CVPixelBufferRef, plane: usize) -> usize;
}

#[link(name = "CoreMedia", kind = "framework")]
unsafe extern "C" {
    static kCMSampleAttachmentKey_NotSync: CFStringRef;
    fn CMSampleBufferGetDataBuffer(sb: CMSampleBufferRef) -> CMBlockBufferRef;
    fn CMSampleBufferGetFormatDescription(sb: CMSampleBufferRef) -> CMFormatDescriptionRef;
    fn CMSampleBufferGetSampleAttachmentsArray(sb: CMSampleBufferRef, create: u8) -> CFArrayRef;
    fn CMBlockBufferGetDataLength(b: CMBlockBufferRef) -> usize;
    fn CMBlockBufferCopyDataBytes(
        b: CMBlockBufferRef,
        off: usize,
        len: usize,
        dst: *mut c_void,
    ) -> OSStatus;
    fn CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
        d: CMFormatDescriptionRef,
        i: usize,
        ptr: *mut *const u8,
        size: *mut usize,
        count: *mut usize,
        nal_header_len: *mut c_int,
    ) -> OSStatus;
}

#[link(name = "VideoToolbox", kind = "framework")]
unsafe extern "C" {
    static kVTVideoEncoderSpecification_EnableLowLatencyRateControl: CFStringRef;
    static kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: CFStringRef;
    static kVTCompressionPropertyKey_RealTime: CFStringRef;
    static kVTCompressionPropertyKey_AllowFrameReordering: CFStringRef;
    static kVTCompressionPropertyKey_MaxKeyFrameInterval: CFStringRef;
    static kVTCompressionPropertyKey_ExpectedFrameRate: CFStringRef;
    static kVTCompressionPropertyKey_AverageBitRate: CFStringRef;
    static kVTCompressionPropertyKey_ProfileLevel: CFStringRef;
    static kVTProfileLevel_H264_High_AutoLevel: CFStringRef;
    static kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel: CFStringRef;
    static kVTEncodeFrameOptionKey_ForceKeyFrame: CFStringRef;
    fn VTCompressionSessionCreate(
        a: CFAllocatorRef,
        w: i32,
        h: i32,
        codec: u32,
        spec: CFDictionaryRef,
        src_attrs: CFDictionaryRef,
        data_alloc: CFAllocatorRef,
        cb: OutputCallback,
        refcon: *mut c_void,
        out: *mut VTCompressionSessionRef,
    ) -> OSStatus;
    fn VTSessionSetProperty(s: *mut c_void, key: CFStringRef, value: CFTypeRef) -> OSStatus;
    fn VTCompressionSessionEncodeFrame(
        s: VTCompressionSessionRef,
        pb: CVPixelBufferRef,
        pts: CMTime,
        duration: CMTime,
        props: CFDictionaryRef,
        frame_refcon: *mut c_void,
        info: *mut u32,
    ) -> OSStatus;
    fn VTCompressionSessionCompleteFrames(s: VTCompressionSessionRef, until: CMTime) -> OSStatus;
    fn VTCompressionSessionInvalidate(s: VTCompressionSessionRef);
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
    pixel_buffer: CVPixelBufferRef,
    out: Box<Mutex<Output>>,
    width: usize,
    height: usize,
    kbps: u32,
    name: String,
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
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks,
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
                kCMSampleAttachmentKey_NotSync,
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

impl VideoToolbox {
    /// `baseline`: constrained baseline (for openh264-decoded checks); otherwise High.
    pub fn new(width: u32, height: u32, fps: u32, kbps: u32, baseline: bool) -> Res<Self> {
        let out: Box<Mutex<Output>> = Box::default();
        let mut session: VTCompressionSessionRef = null_mut();
        // SAFETY: CF statics from the frameworks; the dictionary is released after use.
        let status = unsafe {
            let spec = dict(&[
                (kVTVideoEncoderSpecification_EnableLowLatencyRateControl, kCFBooleanTrue),
                (
                    kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder,
                    kCFBooleanTrue,
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
                (&*out as *const Mutex<Output>).cast_mut().cast(),
                &mut session,
            );
            CFRelease(spec);
            s
        };
        if status != 0 || session.is_null() {
            return Err(format!("VTCompressionSessionCreate failed: {status}").into());
        }
        let mut pixel_buffer: CVPixelBufferRef = null_mut();
        // SAFETY: creating an IOSurface-backed 420v buffer; attrs released after use.
        let pb_status = unsafe {
            let empty = dict(&[]);
            let attrs = dict(&[(kCVPixelBufferIOSurfacePropertiesKey, empty)]);
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
        let this = Self {
            session,
            pixel_buffer,
            out,
            width: width as usize,
            height: height as usize,
            kbps: kbps.max(100),
            name: format!(
                "videotoolbox h264 {} low-latency-rc realtime no-reordering gop=inf",
                if baseline { "constrained-baseline" } else { "high" }
            ),
        };
        // SAFETY: setting properties on our live session with CF values we release.
        unsafe {
            let set = |k: CFStringRef, v: CFTypeRef| VTSessionSetProperty(session, k, v);
            set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
            set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
            let profile = if baseline {
                kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel
            } else {
                kVTProfileLevel_H264_High_AutoLevel
            };
            set(kVTCompressionPropertyKey_ProfileLevel, profile);
            let gop = number_i32(i32::MAX);
            set(kVTCompressionPropertyKey_MaxKeyFrameInterval, gop);
            CFRelease(gop);
            let rate = number_f64(f64::from(fps.max(1)));
            set(kVTCompressionPropertyKey_ExpectedFrameRate, rate);
            CFRelease(rate);
        }
        let mut this = this;
        this.apply_bitrate(this.kbps);
        Ok(this)
    }

    fn apply_bitrate(&mut self, kbps: u32) {
        let bps = number_i32((kbps.min(2_000_000) * 1000) as i32);
        // SAFETY: our live session; the number is released after use.
        unsafe {
            VTSessionSetProperty(self.session, kVTCompressionPropertyKey_AverageBitRate, bps);
            CFRelease(bps);
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
        self.fill(pic)?;
        if let Ok(mut o) = self.out.lock() {
            *o = Output::default();
        }
        // `pts` is the capture time in microseconds (the trait's contract).
        let time =
            CMTime { value: pts, timescale: 1_000_000, flags: K_CM_TIME_FLAGS_VALID, epoch: 0 };
        // SAFETY: encoding our pixel buffer on our session; CompleteFrames runs the output
        // callback before it returns, so the result is ready afterwards.
        let status = unsafe {
            let props = if force_idr {
                dict(&[(kVTEncodeFrameOptionKey_ForceKeyFrame, kCFBooleanTrue)])
            } else {
                null()
            };
            let mut info = 0u32;
            let s = VTCompressionSessionEncodeFrame(
                self.session,
                self.pixel_buffer,
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

    fn set_bitrate(&mut self, kbps: u32) {
        let kbps = kbps.max(100);
        if kbps.abs_diff(self.kbps) * 20 >= self.kbps {
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
