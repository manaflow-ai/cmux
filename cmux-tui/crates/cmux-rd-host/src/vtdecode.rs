//! The bench viewer's hardware decoder on macOS: VideoToolbox, the decoder the cmux-next
//! viewer pane uses, so a bench run measures what a person sees and decodes every profile the
//! host sends (the OpenH264 decoder handles constrained baseline only). Annex-B access units
//! in; NV12 (video range) pictures out, read through their luma plane.

use crate::Res;
use std::ffi::c_void;
use std::os::raw::c_long;
use std::ptr::{null, null_mut};
use std::sync::Mutex;

type CFTypeRef = *const c_void;
type CFStringRef = *const c_void;
type CFDictionaryRef = *const c_void;
type OSStatus = i32;
type CMFormatDescriptionRef = *mut c_void;
type CMBlockBufferRef = *mut c_void;
type CMSampleBufferRef = *mut c_void;
type CVPixelBufferRef = *mut c_void;
type VTDecompressionSessionRef = *mut c_void;

#[repr(C)]
#[derive(Clone, Copy)]
struct CMTime {
    value: i64,
    timescale: i32,
    flags: u32,
    epoch: i64,
}

type OutputCallback =
    extern "C" fn(*mut c_void, *mut c_void, OSStatus, u32, CVPixelBufferRef, CMTime, CMTime);

#[repr(C)]
struct CallbackRecord {
    callback: OutputCallback,
    refcon: *mut c_void,
}

#[repr(C)]
struct DictCallbacks {
    _p: [u8; 0],
}

const PIXEL_420V: u32 = u32::from_be_bytes(*b"420v");
const CF_NUMBER_SINT32: c_long = 3;
const BLOCK_ASSURE_MEMORY_NOW: u32 = 1;
const LOCK_READ_ONLY: u64 = 1;

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    static kCFTypeDictionaryKeyCallBacks: DictCallbacks;
    static kCFTypeDictionaryValueCallBacks: DictCallbacks;
    fn CFDictionaryCreate(
        a: *const c_void,
        keys: *const CFTypeRef,
        values: *const CFTypeRef,
        n: c_long,
        kcb: *const DictCallbacks,
        vcb: *const DictCallbacks,
    ) -> CFDictionaryRef;
    fn CFNumberCreate(a: *const c_void, t: c_long, v: *const c_void) -> CFTypeRef;
    fn CFRetain(v: CFTypeRef) -> CFTypeRef;
    fn CFRelease(v: CFTypeRef);
}

#[link(name = "CoreMedia", kind = "framework")]
unsafe extern "C" {
    fn CMVideoFormatDescriptionCreateFromH264ParameterSets(
        a: *const c_void,
        count: usize,
        pointers: *const *const u8,
        sizes: *const usize,
        nal_header_length: i32,
        out: *mut CMFormatDescriptionRef,
    ) -> OSStatus;
    fn CMBlockBufferCreateWithMemoryBlock(
        a: *const c_void,
        memory: *mut c_void,
        length: usize,
        block_allocator: *const c_void,
        source: *const c_void,
        offset: usize,
        data_length: usize,
        flags: u32,
        out: *mut CMBlockBufferRef,
    ) -> OSStatus;
    fn CMBlockBufferReplaceDataBytes(
        source: *const c_void,
        dest: CMBlockBufferRef,
        offset: usize,
        length: usize,
    ) -> OSStatus;
    fn CMSampleBufferCreateReady(
        a: *const c_void,
        data: CMBlockBufferRef,
        format: CMFormatDescriptionRef,
        samples: c_long,
        timings: c_long,
        timing: *const c_void,
        sizes_count: c_long,
        sizes: *const usize,
        out: *mut CMSampleBufferRef,
    ) -> OSStatus;
}

#[link(name = "VideoToolbox", kind = "framework")]
unsafe extern "C" {
    fn VTDecompressionSessionCreate(
        a: *const c_void,
        format: CMFormatDescriptionRef,
        spec: CFDictionaryRef,
        attrs: CFDictionaryRef,
        callback: *const CallbackRecord,
        out: *mut VTDecompressionSessionRef,
    ) -> OSStatus;
    fn VTDecompressionSessionDecodeFrame(
        s: VTDecompressionSessionRef,
        sample: CMSampleBufferRef,
        flags: u32,
        refcon: *mut c_void,
        info: *mut u32,
    ) -> OSStatus;
    fn VTDecompressionSessionWaitForAsynchronousFrames(s: VTDecompressionSessionRef) -> OSStatus;
    fn VTDecompressionSessionInvalidate(s: VTDecompressionSessionRef);
}

#[link(name = "CoreVideo", kind = "framework")]
unsafe extern "C" {
    static kCVPixelBufferPixelFormatTypeKey: CFStringRef;
    fn CVPixelBufferLockBaseAddress(b: CVPixelBufferRef, flags: u64) -> i32;
    fn CVPixelBufferUnlockBaseAddress(b: CVPixelBufferRef, flags: u64) -> i32;
    fn CVPixelBufferGetBaseAddressOfPlane(b: CVPixelBufferRef, plane: usize) -> *mut u8;
    fn CVPixelBufferGetBytesPerRowOfPlane(b: CVPixelBufferRef, plane: usize) -> usize;
    fn CVPixelBufferGetWidth(b: CVPixelBufferRef) -> usize;
    fn CVPixelBufferGetHeight(b: CVPixelBufferRef) -> usize;
}

/// The NAL units of an Annex-B access unit (start codes removed).
fn nal_units(au: &[u8]) -> Vec<&[u8]> {
    let mut starts = Vec::new();
    let mut i = 0;
    while i + 3 <= au.len() {
        if au[i] == 0 && au[i + 1] == 0 && au[i + 2] == 1 {
            starts.push(i + 3);
            i += 3;
        } else {
            i += 1;
        }
    }
    starts
        .iter()
        .enumerate()
        .map(|(n, &start)| {
            let mut end = starts.get(n + 1).map_or(au.len(), |&next| next - 3);
            // A four-byte start code leaves one zero at the end of the previous unit.
            while end > start && au[end - 1] == 0 && n + 1 < starts.len() {
                end -= 1;
            }
            &au[start..end]
        })
        .filter(|unit| !unit.is_empty())
        .collect()
}

/// One decoded picture (a retained NV12 pixel buffer).
pub struct Picture(CVPixelBufferRef);

impl Picture {
    pub fn size(&self) -> (usize, usize) {
        // SAFETY: a retained, live pixel buffer.
        unsafe { (CVPixelBufferGetWidth(self.0), CVPixelBufferGetHeight(self.0)) }
    }

    /// Calls `read` with the luma plane and its stride.
    pub fn with_luma<T>(&self, read: impl FnOnce(&[u8], usize) -> T) -> T {
        // SAFETY: the buffer is locked read-only while the plane slice is alive; the slice
        // covers exactly stride * height bytes of plane 0.
        unsafe {
            CVPixelBufferLockBaseAddress(self.0, LOCK_READ_ONLY);
            let base = CVPixelBufferGetBaseAddressOfPlane(self.0, 0);
            let stride = CVPixelBufferGetBytesPerRowOfPlane(self.0, 0);
            let rows = CVPixelBufferGetHeight(self.0);
            let plane = std::slice::from_raw_parts(base, stride * rows);
            let out = read(plane, stride);
            CVPixelBufferUnlockBaseAddress(self.0, LOCK_READ_ONLY);
            out
        }
    }

    /// RGB (8 bits per channel) for a snapshot: video-range BT.709 NV12 to full-range RGB.
    pub fn rgb(&self) -> (usize, usize, Vec<u8>) {
        let (w, h) = self.size();
        let mut rgb = vec![0u8; w * h * 3];
        // SAFETY: as in with_luma, for both planes.
        unsafe {
            CVPixelBufferLockBaseAddress(self.0, LOCK_READ_ONLY);
            let y = CVPixelBufferGetBaseAddressOfPlane(self.0, 0);
            let ys = CVPixelBufferGetBytesPerRowOfPlane(self.0, 0);
            let c = CVPixelBufferGetBaseAddressOfPlane(self.0, 1);
            let cs = CVPixelBufferGetBytesPerRowOfPlane(self.0, 1);
            for row in 0..h {
                for col in 0..w {
                    let luma = f32::from(*y.add(row * ys + col)) - 16.0;
                    let ci = (row / 2) * cs + (col / 2) * 2;
                    let cb = f32::from(*c.add(ci)) - 128.0;
                    let cr = f32::from(*c.add(ci + 1)) - 128.0;
                    let l = 1.164 * luma;
                    let px = &mut rgb[(row * w + col) * 3..][..3];
                    px[0] = (l + 1.793 * cr).clamp(0.0, 255.0) as u8;
                    px[1] = (l - 0.213 * cb - 0.533 * cr).clamp(0.0, 255.0) as u8;
                    px[2] = (l + 2.112 * cb).clamp(0.0, 255.0) as u8;
                }
            }
            CVPixelBufferUnlockBaseAddress(self.0, LOCK_READ_ONLY);
        }
        (w, h, rgb)
    }
}

impl Drop for Picture {
    fn drop(&mut self) {
        // SAFETY: releasing the reference this value holds.
        unsafe { CFRelease(self.0 as CFTypeRef) };
    }
}

/// Where the output callback leaves the picture of the frame being decoded.
type Slot = Mutex<Option<Picture>>;

extern "C" fn on_output(
    refcon: *mut c_void,
    _frame: *mut c_void,
    status: OSStatus,
    _flags: u32,
    image: CVPixelBufferRef,
    _pts: CMTime,
    _duration: CMTime,
) {
    if status != 0 || image.is_null() {
        return;
    }
    // SAFETY: `refcon` is the decoder's boxed slot, alive as long as the session; the image is
    // retained before it is kept.
    unsafe {
        let slot = &*(refcon as *const Slot);
        CFRetain(image as CFTypeRef);
        *slot.lock().unwrap_or_else(|p| p.into_inner()) = Some(Picture(image));
    }
}

pub struct VtDecoder {
    session: VTDecompressionSessionRef,
    format: CMFormatDescriptionRef,
    parameter_sets: Vec<Vec<u8>>,
    slot: Box<Slot>,
}

// SAFETY: the session and format are used from one thread at a time (the bench's loop).
unsafe impl Send for VtDecoder {}

impl VtDecoder {
    pub fn new() -> Self {
        Self {
            session: null_mut(),
            format: null_mut(),
            parameter_sets: Vec::new(),
            slot: Box::default(),
        }
    }

    fn close(&mut self) {
        // SAFETY: invalidating and releasing objects this decoder created, once.
        unsafe {
            if !self.session.is_null() {
                VTDecompressionSessionInvalidate(self.session);
                CFRelease(self.session as CFTypeRef);
                self.session = null_mut();
            }
            if !self.format.is_null() {
                CFRelease(self.format as CFTypeRef);
                self.format = null_mut();
            }
        }
    }

    /// A new SPS or PPS (re)creates the session.
    fn open(&mut self, sps: &[u8], pps: &[u8]) -> Res<()> {
        self.close();
        let pointers = [sps.as_ptr(), pps.as_ptr()];
        let sizes = [sps.len(), pps.len()];
        // SAFETY: two valid parameter sets; out-pointers are ours; the dictionaries are
        // released after the session copies them.
        unsafe {
            let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                null(),
                2,
                pointers.as_ptr(),
                sizes.as_ptr(),
                4,
                &mut self.format,
            );
            if status != 0 {
                return Err(format!("H.264 format description failed: {status}").into());
            }
            let format =
                CFNumberCreate(null(), CF_NUMBER_SINT32, (&PIXEL_420V as *const u32).cast());
            let keys = [kCVPixelBufferPixelFormatTypeKey];
            let values = [format];
            let attrs = CFDictionaryCreate(
                null(),
                keys.as_ptr(),
                values.as_ptr(),
                1,
                &kCFTypeDictionaryKeyCallBacks,
                &kCFTypeDictionaryValueCallBacks,
            );
            let record = CallbackRecord {
                callback: on_output,
                refcon: (&*self.slot as *const Slot).cast_mut().cast(),
            };
            let status = VTDecompressionSessionCreate(
                null(),
                self.format,
                null(),
                attrs,
                &record,
                &mut self.session,
            );
            CFRelease(attrs);
            CFRelease(format);
            if status != 0 {
                return Err(format!("VTDecompressionSessionCreate failed: {status}").into());
            }
        }
        self.parameter_sets = vec![sps.to_vec(), pps.to_vec()];
        Ok(())
    }

    /// Decodes one access unit; `None` when it gave no picture (no session yet, or skipped).
    pub fn decode(&mut self, au: &[u8]) -> Res<Option<Picture>> {
        let units = nal_units(au);
        let sps = units.iter().find(|u| u[0] & 0x1f == 7);
        let pps = units.iter().find(|u| u[0] & 0x1f == 8);
        if let (Some(sps), Some(pps)) = (sps, pps) {
            if self.parameter_sets != [sps.to_vec(), pps.to_vec()] {
                self.open(sps, pps)?;
            }
        }
        if self.session.is_null() {
            return Ok(None);
        }
        // Length-prefixed (AVCC) picture data: every unit but parameter sets and delimiters.
        let mut avcc = Vec::with_capacity(au.len() + 16);
        for unit in units.iter().filter(|u| !matches!(u[0] & 0x1f, 7..=9)) {
            avcc.extend_from_slice(&(unit.len() as u32).to_be_bytes());
            avcc.extend_from_slice(unit);
        }
        if avcc.is_empty() {
            return Ok(None);
        }
        // SAFETY: the block buffer is created with its own memory and filled from `avcc`; the
        // sample references the block and our format; both are released after a synchronous
        // decode, whose output callback ran before VTDecompressionSessionWaitForAsynchronousFrames
        // returns.
        unsafe {
            let mut block: CMBlockBufferRef = null_mut();
            let status = CMBlockBufferCreateWithMemoryBlock(
                null(),
                null_mut(),
                avcc.len(),
                null(),
                null(),
                0,
                avcc.len(),
                BLOCK_ASSURE_MEMORY_NOW,
                &mut block,
            );
            if status != 0 {
                return Err(format!("CMBlockBufferCreate failed: {status}").into());
            }
            CMBlockBufferReplaceDataBytes(avcc.as_ptr().cast(), block, 0, avcc.len());
            let mut sample: CMSampleBufferRef = null_mut();
            let size = avcc.len();
            let status = CMSampleBufferCreateReady(
                null(),
                block,
                self.format,
                1,
                0,
                null(),
                1,
                &size,
                &mut sample,
            );
            CFRelease(block as CFTypeRef);
            if status != 0 {
                return Err(format!("CMSampleBufferCreateReady failed: {status}").into());
            }
            let mut info = 0u32;
            let status =
                VTDecompressionSessionDecodeFrame(self.session, sample, 0, null_mut(), &mut info);
            VTDecompressionSessionWaitForAsynchronousFrames(self.session);
            CFRelease(sample as CFTypeRef);
            if status != 0 {
                return Err(format!("VTDecompressionSessionDecodeFrame failed: {status}").into());
            }
        }
        Ok(self.slot.lock().unwrap_or_else(|p| p.into_inner()).take())
    }
}

impl Drop for VtDecoder {
    fn drop(&mut self) {
        self.close();
    }
}
