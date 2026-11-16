//! Fleet-only measurements for an "ultra" screen-sharing profile (Leo, 2026-11-16: "why are you
//! being so skimpy with bandwidth?"): what the Mac hardware encoder does when bandwidth is not
//! the limit. Not a gate: it asserts nothing and prints one table, also written to
//! `.build/artifacts/vt-ultra.txt` at the repository root (fetch it with `--artifact`).
//!
//!   Q1  4:4:4: which profiles and pixel formats VideoToolbox accepts for H.264 and HEVC, what
//!       chroma format the stream's SPS carries, and whether the decoder gives the chroma back.
//!   Q2  text quality against a QP ceiling (18, 20, 22): bytes per frame and luma error of a
//!       scrolled glyph page (the content of encode.rs's frame-budget test), decoded back.
//!   Q3  Mbps and encode ms per frame at 4K60 and 4K120 under full-screen motion (the moving
//!       bars of cmux-rd-host's `--source synthetic`, and the scrolled text), no per-frame cap.
//!   Q4  the merged encoder (videotoolbox.rs, per-frame DataRateLimits, no QP ceiling): frames
//!       VideoToolbox drops under scrolled text at 400 and 2000 kbps.
//!
//! Run on a fleet Mac only:
//!   cmux-ci run --class isolated --script scripts/ci/cmux-tui-rust-check.sh --ref SHA --os macos \
//!     --arg test --arg vt_ultra_measurements --arg cmux-encode:vt_ultra \
//!     --artifact .build/artifacts/vt-ultra.txt
#![cfg(target_os = "macos")]
#![allow(non_upper_case_globals, clippy::all)]

use std::ffi::{CString, c_char, c_void};
use std::io::Write;
use std::ptr::{null, null_mut};
use std::sync::Mutex;
use std::time::Instant;

type Ref = *const c_void;
type MRef = *mut c_void;

#[repr(C)]
#[derive(Clone, Copy)]
struct CMTime {
    value: i64,
    timescale: i32,
    flags: u32,
    epoch: i64,
}
const INVALID: CMTime = CMTime { value: 0, timescale: 0, flags: 0, epoch: 0 };
fn micros(t: i64) -> CMTime {
    CMTime { value: t, timescale: 1_000_000, flags: 1, epoch: 0 }
}

const UTF8: u32 = 0x0800_0100;
const SINT32: isize = 3;
const FLOAT64: isize = 6;

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    static kCFBooleanTrue: Ref;
    static kCFBooleanFalse: Ref;
    static kCFTypeDictionaryKeyCallBacks: u8;
    static kCFTypeDictionaryValueCallBacks: u8;
    static kCFTypeArrayCallBacks: u8;
    fn CFDictionaryCreate(
        a: Ref,
        k: *const Ref,
        v: *const Ref,
        n: isize,
        kcb: Ref,
        vcb: Ref,
    ) -> Ref;
    fn CFDictionaryGetValue(d: Ref, k: Ref) -> Ref;
    fn CFArrayCreate(a: Ref, v: *const Ref, n: isize, cb: Ref) -> Ref;
    fn CFArrayGetCount(a: Ref) -> isize;
    fn CFArrayGetValueAtIndex(a: Ref, i: isize) -> Ref;
    fn CFNumberCreate(a: Ref, t: isize, v: *const c_void) -> Ref;
    fn CFRelease(v: Ref);
    fn CFRetain(v: Ref) -> Ref;
    fn CFCopyDescription(v: Ref) -> Ref;
    fn CFStringGetCString(s: Ref, buf: *mut c_char, len: isize, enc: u32) -> u8;
    fn CFStringCreateWithCString(a: Ref, s: *const c_char, enc: u32) -> Ref;
    fn CFGetTypeID(v: Ref) -> usize;
    fn CFStringGetTypeID() -> usize;
    fn CFDictionaryContainsKey(d: Ref, k: Ref) -> u8;
}

#[link(name = "CoreVideo", kind = "framework")]
unsafe extern "C" {
    static kCVPixelBufferIOSurfacePropertiesKey: Ref;
    static kCVPixelBufferPixelFormatTypeKey: Ref;
    fn CVPixelBufferCreate(a: Ref, w: usize, h: usize, fmt: u32, attrs: Ref, out: *mut MRef)
    -> i32;
    fn CVPixelBufferLockBaseAddress(pb: Ref, flags: u64) -> i32;
    fn CVPixelBufferUnlockBaseAddress(pb: Ref, flags: u64) -> i32;
    fn CVPixelBufferGetBaseAddressOfPlane(pb: Ref, plane: usize) -> *mut u8;
    fn CVPixelBufferGetBytesPerRowOfPlane(pb: Ref, plane: usize) -> usize;
    fn CVPixelBufferGetWidthOfPlane(pb: Ref, plane: usize) -> usize;
    fn CVPixelBufferGetHeightOfPlane(pb: Ref, plane: usize) -> usize;
    fn CVPixelBufferGetPixelFormatType(pb: Ref) -> u32;
}

#[link(name = "CoreMedia", kind = "framework")]
unsafe extern "C" {
    static kCMSampleAttachmentKey_NotSync: Ref;
    fn CMSampleBufferGetDataBuffer(sb: Ref) -> Ref;
    fn CMSampleBufferGetFormatDescription(sb: Ref) -> Ref;
    fn CMSampleBufferGetSampleAttachmentsArray(sb: Ref, create: u8) -> Ref;
    fn CMBlockBufferGetDataLength(b: Ref) -> usize;
    fn CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
        d: Ref,
        i: usize,
        p: *mut *const u8,
        size: *mut usize,
        count: *mut usize,
        nal: *mut i32,
    ) -> i32;
    fn CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
        d: Ref,
        i: usize,
        p: *mut *const u8,
        size: *mut usize,
        count: *mut usize,
        nal: *mut i32,
    ) -> i32;
}

type EncCallback = extern "C" fn(MRef, MRef, i32, u32, Ref);
type DecCallback = extern "C" fn(MRef, MRef, i32, u32, Ref, CMTime, CMTime);

#[repr(C)]
struct DecRecord {
    cb: DecCallback,
    refcon: MRef,
}

#[link(name = "VideoToolbox", kind = "framework")]
unsafe extern "C" {
    fn VTCompressionSessionCreate(
        a: Ref,
        w: i32,
        h: i32,
        codec: u32,
        spec: Ref,
        src: Ref,
        da: Ref,
        cb: EncCallback,
        refcon: MRef,
        out: *mut MRef,
    ) -> i32;
    fn VTSessionSetProperty(s: MRef, key: Ref, value: Ref) -> i32;
    fn VTSessionCopyProperty(s: MRef, key: Ref, a: Ref, out: *mut Ref) -> i32;
    fn VTCompressionSessionEncodeFrame(
        s: MRef,
        pb: Ref,
        pts: CMTime,
        dur: CMTime,
        props: Ref,
        frame: MRef,
        info: *mut u32,
    ) -> i32;
    fn VTCompressionSessionCompleteFrames(s: MRef, until: CMTime) -> i32;
    fn VTCompressionSessionInvalidate(s: MRef);
    fn VTCopyVideoEncoderList(options: Ref, out: *mut Ref) -> i32;
    fn VTCopySupportedPropertyDictionaryForEncoder(
        w: i32,
        h: i32,
        codec: u32,
        spec: Ref,
        id: *mut Ref,
        props: *mut Ref,
    ) -> i32;
    fn VTIsHardwareDecodeSupported(codec: u32) -> u8;
    fn VTDecompressionSessionCreate(
        a: Ref,
        fmt: Ref,
        spec: Ref,
        dest: Ref,
        cb: *const DecRecord,
        out: *mut MRef,
    ) -> i32;
    fn VTDecompressionSessionDecodeFrame(
        s: MRef,
        sb: Ref,
        flags: u32,
        frame: MRef,
        info: *mut u32,
    ) -> i32;
    fn VTDecompressionSessionWaitForAsynchronousFrames(s: MRef) -> i32;
    fn VTDecompressionSessionInvalidate(s: MRef);
}

unsafe extern "C" {
    fn dlsym(handle: MRef, name: *const c_char) -> MRef;
}

const H264: u32 = u32::from_be_bytes(*b"avc1");
const HEVC: u32 = u32::from_be_bytes(*b"hvc1");
const F420V: u32 = u32::from_be_bytes(*b"420v");
const F444V: u32 = u32::from_be_bytes(*b"444v");
const X444: u32 = u32::from_be_bytes(*b"x444");

fn fourcc(v: u32) -> String {
    String::from_utf8_lossy(&v.to_be_bytes()).into_owned()
}

/// A CF constant by name (null when this macOS does not export it).
fn k(name: &str) -> Ref {
    let c = CString::new(name).unwrap();
    // SAFETY: dlsym with RTLD_DEFAULT; the symbol is a CFStringRef variable.
    unsafe {
        let p = dlsym(-2isize as MRef, c.as_ptr());
        if p.is_null() { null() } else { *(p as *const Ref) }
    }
}
fn yes() -> Ref {
    unsafe { kCFBooleanTrue }
}
fn no() -> Ref {
    unsafe { kCFBooleanFalse }
}
fn n32(v: i32) -> Ref {
    unsafe { CFNumberCreate(null(), SINT32, (&v as *const i32).cast()) }
}
fn nf(v: f64) -> Ref {
    unsafe { CFNumberCreate(null(), FLOAT64, (&v as *const f64).cast()) }
}
fn dict(pairs: &[(Ref, Ref)]) -> Ref {
    let pairs: Vec<_> = pairs.iter().filter(|p| !p.0.is_null()).collect();
    let keys: Vec<Ref> = pairs.iter().map(|p| p.0).collect();
    let values: Vec<Ref> = pairs.iter().map(|p| p.1).collect();
    unsafe {
        CFDictionaryCreate(
            null(),
            keys.as_ptr(),
            values.as_ptr(),
            keys.len() as isize,
            (&raw const kCFTypeDictionaryKeyCallBacks).cast(),
            (&raw const kCFTypeDictionaryValueCallBacks).cast(),
        )
    }
}
fn cfstr(s: &str) -> Ref {
    let c = CString::new(s).unwrap();
    unsafe { CFStringCreateWithCString(null(), c.as_ptr(), UTF8) }
}
fn string(s: Ref) -> String {
    if s.is_null() {
        return "null".into();
    }
    let mut buf = vec![0 as c_char; 65536];
    unsafe {
        let owned =
            if CFGetTypeID(s) == CFStringGetTypeID() { CFRetain(s) } else { CFCopyDescription(s) };
        let ok = CFStringGetCString(owned, buf.as_mut_ptr(), buf.len() as isize, UTF8);
        CFRelease(owned);
        if ok == 0 {
            return "?".into();
        }
        std::ffi::CStr::from_ptr(buf.as_ptr())
            .to_string_lossy()
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ")
    }
}

struct Log(std::fs::File);
impl Log {
    fn open() -> Self {
        let root =
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../.build/artifacts");
        let _ = std::fs::create_dir_all(&root);
        Log(std::fs::File::create(root.join("vt-ultra.txt")).expect("artifact file"))
    }
    fn line(&mut self, s: impl AsRef<str>) {
        eprintln!("{}", s.as_ref());
        let _ = writeln!(self.0, "{}", s.as_ref());
        let _ = self.0.flush();
    }
}

// ---------------------------------------------------------------------------------------
// Content: a source gives full-resolution luma, Cb and Cr rows for one frame.

trait Source {
    fn prepare(&mut self, frame: usize);
    fn luma(&self, y: usize) -> &[u8];
    fn cb(&self, y: usize) -> &[u8];
    fn cr(&self, y: usize) -> &[u8];
    fn chroma_static(&self) -> bool;
}

/// encode.rs's glyph cells (dark strokes on a light page), scrolled `step` rows a frame.
/// `colored`: each cell's strokes get a hue, so chroma has one-pixel detail (the 4:4:4 probe).
struct TextPage {
    w: usize,
    y: Vec<u8>,
    cb: Vec<u8>,
    cr: Vec<u8>,
    neutral: Vec<u8>,
    colored: bool,
    scroll: usize,
    step: usize,
}

fn glyph(x: usize, y: usize) -> (bool, u64) {
    let (cell, row) = ((x / 8) as u64, (y / 16) as u64);
    let mut h = cell.wrapping_mul(0x9e37_79b9_7f4a_7c15) ^ row.wrapping_mul(0xc2b2_ae3d_27d4_eb4f);
    h ^= h >> 29;
    let (gx, gy) = (x % 8, y % 16);
    let stroke = gy >= 3 && gy < 13 && gx >= 1 && gx < 7 && (h >> (gx + 8 * (gy % 4))) & 1 == 1;
    (stroke, h)
}

impl TextPage {
    fn new(w: usize, h: usize, frames: usize, step: usize, colored: bool) -> Self {
        let rows = h + frames * step + 2;
        let mut y = vec![0u8; w * rows];
        let (mut cb, mut cr) =
            if colored { (vec![128u8; w * rows], vec![128u8; w * rows]) } else { (vec![], vec![]) };
        for r in 0..rows {
            for x in 0..w {
                let (stroke, hash) = glyph(x, r);
                y[r * w + x] = if stroke { 40 } else { 230 };
                if colored && stroke {
                    cb[r * w + x] = 40 + ((hash >> 40) % 176) as u8;
                    cr[r * w + x] = 40 + ((hash >> 48) % 176) as u8;
                }
            }
        }
        TextPage { w, y, cb, cr, neutral: vec![128; w], colored, scroll: 0, step }
    }
}

impl Source for TextPage {
    fn prepare(&mut self, frame: usize) {
        self.scroll = frame * self.step;
    }
    fn luma(&self, y: usize) -> &[u8] {
        let r = y + self.scroll;
        &self.y[r * self.w..(r + 1) * self.w]
    }
    fn cb(&self, y: usize) -> &[u8] {
        if !self.colored {
            return &self.neutral;
        }
        let r = y + self.scroll;
        &self.cb[r * self.w..(r + 1) * self.w]
    }
    fn cr(&self, y: usize) -> &[u8] {
        if !self.colored {
            return &self.neutral;
        }
        let r = y + self.scroll;
        &self.cr[r * self.w..(r + 1) * self.w]
    }
    fn chroma_static(&self) -> bool {
        !self.colored
    }
}

/// cmux-rd-host's `--source synthetic` picture (PR #44441, src/synthetic.rs `paint`): the
/// marker row (counter 0), a quiet band, and 48 px bars moving 8 px a frame over the whole
/// picture below it, with hues on every other bar.
struct Bars {
    w: usize,
    band: Vec<u8>,
    marker: Vec<u8>,
    templates: [Vec<u8>; 2],
    cb: Vec<u8>,
    cr: Vec<u8>,
    neutral: Vec<u8>,
}
const CELL: usize = 32;
const BAND_ROWS: usize = 2 * CELL;
const BAR: usize = 48;

impl Bars {
    fn new(w: usize) -> Self {
        let mut marker = vec![96u8; w];
        let guard = [true, false, true, false];
        for i in 0..20 {
            let white = if i < 16 { false } else { guard[i - 16] };
            marker[i * CELL..(i + 1) * CELL].fill(if white { 235 } else { 16 });
        }
        Bars {
            w,
            band: vec![96; w],
            marker,
            templates: [vec![0; w], vec![0; w]],
            cb: vec![128; w],
            cr: vec![128; w],
            neutral: vec![128; w],
        }
    }
}

impl Source for Bars {
    fn prepare(&mut self, frame: usize) {
        let shift = frame * 8;
        for (t, lift) in [0u8, 12].into_iter().enumerate() {
            for x in 0..self.w {
                let k = (x + shift) / BAR;
                self.templates[t][x] =
                    if k % 2 == 0 { 40 + lift } else { (60 + (k / 2 * 37) % 150) as u8 + lift };
            }
        }
        for x in 0..self.w {
            let k = ((x & !1) + shift) / BAR;
            let (b, r) = if k % 2 == 0 {
                (128, 128)
            } else {
                ((64 + (k * 53) % 128) as u8, (64 + (k * 91) % 128) as u8)
            };
            self.cb[x] = b;
            self.cr[x] = r;
        }
    }
    fn luma(&self, y: usize) -> &[u8] {
        if y < CELL {
            &self.marker
        } else if y < BAND_ROWS {
            &self.band
        } else {
            &self.templates[(y / 64) % 2]
        }
    }
    fn cb(&self, y: usize) -> &[u8] {
        if y < BAND_ROWS { &self.neutral } else { &self.cb }
    }
    fn cr(&self, y: usize) -> &[u8] {
        if y < BAND_ROWS { &self.neutral } else { &self.cr }
    }
    fn chroma_static(&self) -> bool {
        false
    }
}

fn pixel_buffer(w: usize, h: usize, fmt: u32) -> Result<MRef, String> {
    let mut pb: MRef = null_mut();
    let s = unsafe {
        let empty = dict(&[]);
        let attrs = dict(&[(kCVPixelBufferIOSurfacePropertiesKey, empty)]);
        let s = CVPixelBufferCreate(null(), w, h, fmt, attrs, &mut pb);
        CFRelease(attrs);
        CFRelease(empty);
        s
    };
    if s != 0 || pb.is_null() {
        Err(format!("CVPixelBufferCreate {} = {s}", fourcc(fmt)))
    } else {
        Ok(pb)
    }
}

/// Writes one frame of `src` into a biplanar 420v, 444v or x444 buffer.
fn write(pb: MRef, src: &dyn Source, h: usize, chroma: bool) {
    unsafe {
        CVPixelBufferLockBaseAddress(pb, 0);
        let fmt = CVPixelBufferGetPixelFormatType(pb);
        let wide = fmt == X444;
        let sub = fmt == F420V;
        let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
        for y in 0..h {
            let row = src.luma(y);
            let dst = base.add(y * stride);
            if wide {
                for (x, v) in row.iter().enumerate() {
                    let v = u16::from(*v) << 8;
                    *dst.add(2 * x) = v as u8;
                    *dst.add(2 * x + 1) = (v >> 8) as u8;
                }
            } else {
                std::ptr::copy_nonoverlapping(row.as_ptr(), dst, row.len());
            }
        }
        if chroma {
            let base = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
            let (cw, ch) =
                (CVPixelBufferGetWidthOfPlane(pb, 1), CVPixelBufferGetHeightOfPlane(pb, 1));
            let step = if sub { 2 } else { 1 };
            for cy in 0..ch {
                let (cb, cr) = (src.cb(cy * step), src.cr(cy * step));
                let dst = base.add(cy * stride);
                for cx in 0..cw {
                    let (b, r) = (cb[cx * step], cr[cx * step]);
                    if wide {
                        *dst.add(4 * cx) = 0;
                        *dst.add(4 * cx + 1) = b;
                        *dst.add(4 * cx + 2) = 0;
                        *dst.add(4 * cx + 3) = r;
                    } else {
                        *dst.add(2 * cx) = b;
                        *dst.add(2 * cx + 1) = r;
                    }
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, 0);
    }
}

#[derive(Default, Clone, Copy)]
struct Err3 {
    y_psnr: f64,
    y_max: u32,
    /// Share of luma pixels off by more than 24 (of 0-255): a visibly wrong glyph pixel.
    y_bad: f64,
    cb_psnr: f64,
    cr_psnr: f64,
}

fn psnr(sse: f64, n: f64) -> f64 {
    if sse == 0.0 { 99.0 } else { 10.0 * (255.0f64 * 255.0 / (sse / n)).log10() }
}

/// Compares a decoded buffer with the source buffer (same format, 8-bit or the top 8 bits).
fn compare(src: MRef, dec: Ref) -> Result<Err3, String> {
    unsafe {
        let (fs, fd) = (CVPixelBufferGetPixelFormatType(src), CVPixelBufferGetPixelFormatType(dec));
        if fs != fd {
            return Err(format!("decoder gave {} for {}", fourcc(fd), fourcc(fs)));
        }
        let bps = if fs == X444 { 2 } else { 1 };
        CVPixelBufferLockBaseAddress(src, 1);
        CVPixelBufferLockBaseAddress(dec, 1);
        let mut e = Err3::default();
        // Luma.
        let (w, h) = (CVPixelBufferGetWidthOfPlane(src, 0), CVPixelBufferGetHeightOfPlane(src, 0));
        let (a, sa) = (
            CVPixelBufferGetBaseAddressOfPlane(src, 0),
            CVPixelBufferGetBytesPerRowOfPlane(src, 0),
        );
        let (b, sb) = (
            CVPixelBufferGetBaseAddressOfPlane(dec as MRef, 0),
            CVPixelBufferGetBytesPerRowOfPlane(dec, 0),
        );
        let (mut sse, mut max, mut bad) = (0f64, 0u32, 0usize);
        for y in 0..h {
            let ra = std::slice::from_raw_parts(a.add(y * sa), w * bps);
            let rb = std::slice::from_raw_parts(b.add(y * sb), w * bps);
            for x in 0..w {
                let d = (i32::from(ra[x * bps + bps - 1]) - i32::from(rb[x * bps + bps - 1]))
                    .unsigned_abs();
                sse += f64::from(d * d);
                max = max.max(d);
                bad += usize::from(d > 24);
            }
        }
        e.y_psnr = psnr(sse, (w * h) as f64);
        e.y_max = max;
        e.y_bad = bad as f64 / (w * h) as f64;
        // Chroma (interleaved CbCr).
        let (cw, ch) =
            (CVPixelBufferGetWidthOfPlane(src, 1), CVPixelBufferGetHeightOfPlane(src, 1));
        let (a, sa) = (
            CVPixelBufferGetBaseAddressOfPlane(src, 1),
            CVPixelBufferGetBytesPerRowOfPlane(src, 1),
        );
        let (b, sb) = (
            CVPixelBufferGetBaseAddressOfPlane(dec as MRef, 1),
            CVPixelBufferGetBytesPerRowOfPlane(dec, 1),
        );
        let (mut s0, mut s1) = (0f64, 0f64);
        for y in 0..ch {
            let ra = std::slice::from_raw_parts(a.add(y * sa), cw * 2 * bps);
            let rb = std::slice::from_raw_parts(b.add(y * sb), cw * 2 * bps);
            for x in 0..cw {
                let i = 2 * x * bps + bps - 1;
                let d0 = f64::from(ra[i]) - f64::from(rb[i]);
                let d1 = f64::from(ra[i + bps]) - f64::from(rb[i + bps]);
                s0 += d0 * d0;
                s1 += d1 * d1;
            }
        }
        e.cb_psnr = psnr(s0, (cw * ch) as f64);
        e.cr_psnr = psnr(s1, (cw * ch) as f64);
        CVPixelBufferUnlockBaseAddress(dec as MRef, 1);
        CVPixelBufferUnlockBaseAddress(src, 1);
        Ok(e)
    }
}

// ---------------------------------------------------------------------------------------
// The SPS's profile and chroma format (the stream's own word, not the API's).

struct Bits<'a> {
    b: Vec<u8>,
    at: usize,
    _p: std::marker::PhantomData<&'a ()>,
}
impl Bits<'_> {
    fn new(nal: &[u8]) -> Self {
        // Drop emulation-prevention bytes (00 00 03).
        let mut b = Vec::with_capacity(nal.len());
        let mut zeros = 0;
        for &v in nal {
            if zeros >= 2 && v == 3 {
                zeros = 0;
                continue;
            }
            zeros = if v == 0 { zeros + 1 } else { 0 };
            b.push(v);
        }
        Bits { b, at: 0, _p: std::marker::PhantomData }
    }
    fn u(&mut self, n: usize) -> u64 {
        let mut v = 0;
        for _ in 0..n {
            let byte = self.b.get(self.at / 8).copied().unwrap_or(0);
            v = (v << 1) | u64::from((byte >> (7 - self.at % 8)) & 1);
            self.at += 1;
        }
        v
    }
    fn ue(&mut self) -> u64 {
        let mut zeros = 0;
        while self.u(1) == 0 && zeros < 32 {
            zeros += 1;
        }
        (1u64 << zeros) - 1 + self.u(zeros)
    }
}

fn sps_info(desc: Ref, codec: u32) -> String {
    let mut i = 0usize;
    loop {
        let (mut p, mut size, mut count, mut nal) = (null::<u8>(), 0usize, 0usize, 0i32);
        let s = unsafe {
            if codec == H264 {
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    desc, i, &mut p, &mut size, &mut count, &mut nal,
                )
            } else {
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    desc, i, &mut p, &mut size, &mut count, &mut nal,
                )
            }
        };
        if s != 0 || p.is_null() {
            return format!("no SPS ({s})");
        }
        let bytes = unsafe { std::slice::from_raw_parts(p, size) };
        if codec == H264 && bytes[0] & 0x1f == 7 {
            let mut r = Bits::new(&bytes[1..]);
            let profile = r.u(8);
            r.u(16);
            r.ue();
            let (mut chroma, mut depth) = (1, 8);
            if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(&profile) {
                chroma = r.ue();
                if chroma == 3 {
                    r.u(1);
                }
                depth = 8 + r.ue();
            }
            return format!(
                "sps profile_idc={profile} chroma_format_idc={chroma} bit_depth={depth}"
            );
        }
        if codec == HEVC && (bytes[0] >> 1) & 0x3f == 33 {
            let mut r = Bits::new(&bytes[2..]);
            r.u(4);
            let sub = r.u(3) as usize;
            r.u(1);
            r.u(2);
            r.u(1);
            let profile = r.u(5);
            r.u(32);
            r.u(48);
            r.u(8);
            let mut flags = vec![];
            for _ in 0..sub {
                flags.push((r.u(1), r.u(1)));
            }
            if sub > 0 {
                for _ in sub..8 {
                    r.u(2);
                }
            }
            for (p, l) in flags {
                if p == 1 {
                    r.u(88);
                }
                if l == 1 {
                    r.u(8);
                }
            }
            r.ue();
            let chroma = r.ue();
            if chroma == 3 {
                r.u(1);
            }
            r.ue();
            r.ue();
            if r.u(1) == 1 {
                for _ in 0..4 {
                    r.ue();
                }
            }
            let depth = 8 + r.ue();
            return format!(
                "sps general_profile_idc={profile} chroma_format_idc={chroma} bit_depth={depth}"
            );
        }
        i += 1;
        if i >= count.max(1) {
            return "no SPS in the parameter sets".into();
        }
    }
}

// ---------------------------------------------------------------------------------------
// Encoder and decoder sessions.

struct Sample {
    sb: Ref,
    status: i32,
    flags: u32,
}

extern "C" fn on_encoded(refcon: MRef, _f: MRef, status: i32, flags: u32, sb: Ref) {
    let out = unsafe { &*(refcon as *const Mutex<Vec<Sample>>) };
    if !sb.is_null() {
        unsafe { CFRetain(sb) };
    }
    out.lock().unwrap().push(Sample { sb, status, flags });
}

#[derive(Clone)]
struct Cfg {
    codec: u32,
    w: usize,
    h: usize,
    fps: u32,
    fmt: u32,
    profile: Ref,
    profile_name: String,
    avg_kbps: Option<u32>,
    limits: Option<(i32, f64)>,
    min_qp: Option<i32>,
    max_qp: Option<i32>,
    low_latency: bool,
}

impl Cfg {
    fn new(codec: u32, w: usize, h: usize, fps: u32) -> Self {
        Cfg {
            codec,
            w,
            h,
            fps,
            fmt: F420V,
            profile: null(),
            profile_name: "default".into(),
            avg_kbps: Some(1_000_000),
            limits: None,
            min_qp: None,
            max_qp: None,
            low_latency: true,
        }
    }
}

struct Enc {
    s: MRef,
    out: Box<Mutex<Vec<Sample>>>,
    pb: MRef,
    notes: Vec<String>,
}

impl Enc {
    fn new(cfg: &Cfg) -> Result<Enc, String> {
        let out: Box<Mutex<Vec<Sample>>> = Box::default();
        let mut s: MRef = null_mut();
        let ll = k("kVTVideoEncoderSpecification_EnableLowLatencyRateControl");
        let hw = k("kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder");
        let spec =
            if cfg.low_latency { dict(&[(ll, yes()), (hw, yes())]) } else { dict(&[(hw, yes())]) };
        let st = unsafe {
            let st = VTCompressionSessionCreate(
                null(),
                cfg.w as i32,
                cfg.h as i32,
                cfg.codec,
                spec,
                null(),
                null(),
                on_encoded,
                (&*out as *const Mutex<Vec<Sample>>).cast_mut().cast(),
                &mut s,
            );
            CFRelease(spec);
            st
        };
        let mut notes = vec![];
        if (st != 0 || s.is_null()) && cfg.low_latency {
            // The low-latency rate control refused this codec or size: say so, and measure
            // the session without it.
            notes.push(format!("low-latency-rc refused {st}, built without it"));
            let spec = dict(&[(hw, yes())]);
            let st2 = unsafe {
                let st = VTCompressionSessionCreate(
                    null(),
                    cfg.w as i32,
                    cfg.h as i32,
                    cfg.codec,
                    spec,
                    null(),
                    null(),
                    on_encoded,
                    (&*out as *const Mutex<Vec<Sample>>).cast_mut().cast(),
                    &mut s,
                );
                CFRelease(spec);
                st
            };
            if st2 != 0 || s.is_null() {
                return Err(format!(
                    "VTCompressionSessionCreate {st} (low latency), {st2} (without)"
                ));
            }
        } else if st != 0 || s.is_null() {
            return Err(format!("VTCompressionSessionCreate {st}"));
        }
        let pb = match pixel_buffer(cfg.w, cfg.h, cfg.fmt) {
            Ok(pb) => pb,
            Err(e) => {
                unsafe {
                    VTCompressionSessionInvalidate(s);
                    CFRelease(s);
                }
                return Err(e);
            }
        };
        let mut e = Enc { s, out, pb, notes };
        e.set("RealTime", yes());
        e.set("AllowFrameReordering", no());
        if !cfg.profile.is_null() {
            e.set("ProfileLevel", cfg.profile);
        }
        e.set_owned("MaxKeyFrameInterval", n32(i32::MAX));
        e.set_owned("ExpectedFrameRate", nf(f64::from(cfg.fps)));
        e.set("PrioritizeEncodingSpeedOverQuality", yes());
        e.set_owned("MaxFrameDelayCount", n32(0));
        if let Some(kbps) = cfg.avg_kbps {
            e.set_owned(
                "AverageBitRate",
                n32((u64::from(kbps) * 1000).min(i32::MAX as u64) as i32),
            );
        }
        if let Some((bytes, secs)) = cfg.limits {
            let pair = [n32(bytes), nf(secs)];
            let arr = unsafe {
                CFArrayCreate(null(), pair.as_ptr(), 2, (&raw const kCFTypeArrayCallBacks).cast())
            };
            e.set_owned("DataRateLimits", arr);
            unsafe {
                CFRelease(pair[0]);
                CFRelease(pair[1]);
            }
        }
        if let Some(q) = cfg.min_qp {
            e.set_owned("MinAllowedFrameQP", n32(q));
        }
        if let Some(q) = cfg.max_qp {
            e.set_owned("MaxAllowedFrameQP", n32(q));
        }
        Ok(e)
    }

    fn set(&mut self, short: &str, v: Ref) -> i32 {
        let key = k(&format!("kVTCompressionPropertyKey_{short}"));
        if key.is_null() {
            self.notes.push(format!("{short}:no-symbol"));
            return -1;
        }
        let st = unsafe { VTSessionSetProperty(self.s, key, v) };
        if st != 0 {
            self.notes.push(format!("{short}:{st}"));
        }
        st
    }
    fn set_owned(&mut self, short: &str, v: Ref) -> i32 {
        let st = self.set(short, v);
        unsafe { CFRelease(v) };
        st
    }
    fn get(&self, short: &str) -> String {
        let key = k(&format!("kVTCompressionPropertyKey_{short}"));
        if key.is_null() {
            return "no-symbol".into();
        }
        let mut v: Ref = null();
        let st = unsafe { VTSessionCopyProperty(self.s, key, null(), &mut v) };
        if st != 0 {
            return format!("err {st}");
        }
        let s = string(v);
        if !v.is_null() {
            unsafe { CFRelease(v) };
        }
        s
    }

    /// Encodes the buffer synchronously; returns the samples and the encode wall time in ms.
    fn encode(&mut self, pts: i64, idr: bool) -> Result<(Vec<Sample>, f64), String> {
        let props =
            if idr { dict(&[(k("kVTEncodeFrameOptionKey_ForceKeyFrame"), yes())]) } else { null() };
        let t = Instant::now();
        let st = unsafe {
            let mut info = 0u32;
            let s = VTCompressionSessionEncodeFrame(
                self.s,
                self.pb,
                micros(pts),
                INVALID,
                props,
                null_mut(),
                &mut info,
            );
            if s == 0 { VTCompressionSessionCompleteFrames(self.s, INVALID) } else { s }
        };
        let ms = t.elapsed().as_secs_f64() * 1000.0;
        if !props.is_null() {
            unsafe { CFRelease(props) };
        }
        if st != 0 {
            return Err(format!("encode {st}"));
        }
        Ok((std::mem::take(&mut *self.out.lock().unwrap()), ms))
    }
}

impl Drop for Enc {
    fn drop(&mut self) {
        unsafe {
            VTCompressionSessionInvalidate(self.s);
            CFRelease(self.s);
            CFRelease(self.pb);
            for s in self.out.lock().unwrap().drain(..) {
                if !s.sb.is_null() {
                    CFRelease(s.sb);
                }
            }
        }
    }
}

fn sample_bytes(sb: Ref) -> usize {
    unsafe { CMBlockBufferGetDataLength(CMSampleBufferGetDataBuffer(sb)) }
}
fn sample_key(sb: Ref) -> bool {
    unsafe {
        let a = CMSampleBufferGetSampleAttachmentsArray(sb, 0);
        !(a.is_null() == false
            && CFArrayGetCount(a) > 0
            && CFDictionaryContainsKey(
                CFArrayGetValueAtIndex(a, 0),
                kCMSampleAttachmentKey_NotSync,
            ) != 0)
    }
}

struct DecOut {
    status: i32,
    img: Ref,
}
extern "C" fn on_decoded(
    refcon: MRef,
    _f: MRef,
    status: i32,
    _flags: u32,
    img: Ref,
    _p: CMTime,
    _d: CMTime,
) {
    let out = unsafe { &*(refcon as *const Mutex<DecOut>) };
    let mut o = out.lock().unwrap();
    o.status = status;
    if !img.is_null() {
        unsafe { CFRetain(img) };
    }
    o.img = img;
}

struct Dec {
    s: MRef,
    out: Box<Mutex<DecOut>>,
}
impl Dec {
    fn new(desc: Ref, fmt: u32) -> Result<Dec, String> {
        let out = Box::new(Mutex::new(DecOut { status: 0, img: null() }));
        let rec =
            DecRecord { cb: on_decoded, refcon: (&*out as *const Mutex<DecOut>).cast_mut().cast() };
        let mut s: MRef = null_mut();
        let st = unsafe {
            let f = n32(fmt as i32);
            let empty = dict(&[]);
            let dest = dict(&[
                (kCVPixelBufferPixelFormatTypeKey, f),
                (kCVPixelBufferIOSurfacePropertiesKey, empty),
            ]);
            let st = VTDecompressionSessionCreate(null(), desc, null(), dest, &rec, &mut s);
            CFRelease(dest);
            CFRelease(empty);
            CFRelease(f);
            st
        };
        if st != 0 || s.is_null() {
            Err(format!("VTDecompressionSessionCreate {st}"))
        } else {
            Ok(Dec { s, out })
        }
    }
    fn decode(&mut self, sb: Ref) -> Result<Ref, String> {
        let st = unsafe {
            let mut info = 0u32;
            let s = VTDecompressionSessionDecodeFrame(self.s, sb, 0, null_mut(), &mut info);
            VTDecompressionSessionWaitForAsynchronousFrames(self.s);
            s
        };
        let mut o = self.out.lock().unwrap();
        let img = std::mem::replace(&mut o.img, null());
        if st != 0 || o.status != 0 || img.is_null() {
            if !img.is_null() {
                unsafe { CFRelease(img) };
            }
            return Err(format!("decode {st}/{}", o.status));
        }
        Ok(img)
    }
}
impl Drop for Dec {
    fn drop(&mut self) {
        unsafe {
            VTDecompressionSessionInvalidate(self.s);
            CFRelease(self.s);
        }
    }
}

// ---------------------------------------------------------------------------------------
// One run: `still` frames of frame 0 (the first an IDR), then `moving` frames of motion.

#[derive(Default)]
struct Run {
    notes: Vec<String>,
    idr_bytes: usize,
    bytes: Vec<usize>,
    ms: Vec<f64>,
    drops: usize,
    errs: Vec<Err3>,
    decode_note: String,
    sps: String,
    profile_readback: String,
    qp_readback: String,
}

fn run(
    cfg: &Cfg,
    src: &mut dyn Source,
    still: usize,
    moving: usize,
    decode: bool,
) -> Result<Run, String> {
    let mut enc = Enc::new(cfg)?;
    let mut r = Run { notes: std::mem::take(&mut enc.notes), ..Default::default() };
    r.profile_readback = enc.get("ProfileLevel");
    r.qp_readback =
        format!("min={} max={}", enc.get("MinAllowedFrameQP"), enc.get("MaxAllowedFrameQP"));
    let mut dec: Option<Dec> = None;
    let interval = 1_000_000 / i64::from(cfg.fps);
    let mut written_chroma = false;
    for f in 0..still + moving {
        let frame = if f < still { 0 } else { f - still + 1 };
        src.prepare(frame);
        let chroma = !(src.chroma_static() && written_chroma);
        if f == 0 || f >= still {
            write(enc.pb, src, cfg.h, chroma);
            written_chroma = true;
        }
        let (samples, ms) = enc.encode(f as i64 * interval, f == 0)?;
        if f >= still {
            r.ms.push(ms);
        }
        if samples.is_empty() || samples.iter().all(|s| s.sb.is_null() || s.flags & 2 != 0) {
            if f >= still {
                r.drops += 1;
            }
        }
        for s in samples {
            if s.sb.is_null() || s.status != 0 {
                continue;
            }
            let bytes = sample_bytes(s.sb);
            if f == 0 {
                r.idr_bytes = bytes;
                r.sps = sps_info(unsafe { CMSampleBufferGetFormatDescription(s.sb) }, cfg.codec);
                let _ = sample_key(s.sb);
            } else if f >= still {
                r.bytes.push(bytes);
            }
            // Every frame is decoded (the still phase's P frames are references too); only
            // the IDR (a format check) and the motion frames are compared.
            if decode {
                if dec.is_none() && r.decode_note.is_empty() {
                    match Dec::new(unsafe { CMSampleBufferGetFormatDescription(s.sb) }, cfg.fmt) {
                        Ok(d) => dec = Some(d),
                        Err(e) => r.decode_note = e,
                    }
                }
                if let Some(d) = dec.as_mut() {
                    match d.decode(s.sb) {
                        Ok(img) => {
                            if f >= still || f == 0 {
                                match compare(enc.pb, img) {
                                    Ok(e) if f >= still => r.errs.push(e),
                                    Ok(_) => {}
                                    Err(e) => r.decode_note = e,
                                }
                            }
                            unsafe { CFRelease(img) };
                        }
                        Err(e) => r.decode_note = e,
                    }
                }
            }
            unsafe { CFRelease(s.sb) };
        }
    }
    Ok(r)
}

fn mean(v: &[f64]) -> f64 {
    if v.is_empty() { 0.0 } else { v.iter().sum::<f64>() / v.len() as f64 }
}
fn pct(v: &[f64], p: f64) -> f64 {
    if v.is_empty() {
        return 0.0;
    }
    let mut s = v.to_vec();
    s.sort_by(|a, b| a.partial_cmp(b).unwrap());
    s[((s.len() - 1) as f64 * p).round() as usize]
}
fn name(codec: u32) -> &'static str {
    if codec == H264 { "h264" } else { "hevc" }
}

// ---------------------------------------------------------------------------------------

fn header(log: &mut Log) {
    let sh = |c: &str, a: &[&str]| {
        std::process::Command::new(c)
            .args(a)
            .output()
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .unwrap_or_default()
    };
    log.line(format!(
        "# host chip={} model={} macOS={} build={}",
        sh("sysctl", &["-n", "machdep.cpu.brand_string"]),
        sh("sysctl", &["-n", "hw.model"]),
        sh("sw_vers", &["-productVersion"]),
        sh("sw_vers", &["-buildVersion"])
    ));
}

fn q1(log: &mut Log) {
    log.line("## Q1 4:4:4: what VideoToolbox accepts and what the stream says");
    unsafe {
        log.line(format!(
            "Q1 VTIsHardwareDecodeSupported h264={} hevc={}",
            VTIsHardwareDecodeSupported(H264),
            VTIsHardwareDecodeSupported(HEVC)
        ));
        let mut list: Ref = null();
        if VTCopyVideoEncoderList(null(), &mut list) == 0 && !list.is_null() {
            let ct = k("kVTVideoEncoderList_CodecType");
            for i in 0..CFArrayGetCount(list) {
                let e = CFArrayGetValueAtIndex(list, i);
                let c = string(CFDictionaryGetValue(e, ct));
                if c.contains("1635148593") || c.contains("1752589105") {
                    log.line(format!("Q1 encoder {}", string(e)));
                }
            }
            CFRelease(list);
        }
    }
    let hw = k("kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder");
    let ll = k("kVTVideoEncoderSpecification_EnableLowLatencyRateControl");
    let mut profiles: Vec<(u32, Vec<(String, Ref)>)> = vec![];
    for codec in [H264, HEVC] {
        let mut found = vec![];
        for low_latency in [true, false] {
            let spec =
                if low_latency { dict(&[(hw, yes()), (ll, yes())]) } else { dict(&[(hw, yes())]) };
            let (mut id, mut props): (Ref, Ref) = (null(), null());
            let st = unsafe {
                VTCopySupportedPropertyDictionaryForEncoder(
                    1920, 1080, codec, spec, &mut id, &mut props,
                )
            };
            unsafe { CFRelease(spec) };
            if st != 0 || props.is_null() {
                log.line(format!(
                    "Q1 {} ll={low_latency} supported-properties: err {st}",
                    name(codec)
                ));
                continue;
            }
            let has = |short: &str| unsafe {
                let key = k(&format!("kVTCompressionPropertyKey_{short}"));
                !key.is_null() && CFDictionaryContainsKey(props, key) != 0
            };
            log.line(format!(
                "Q1 {} ll={low_latency} encoder={} MaxAllowedFrameQP={} MinAllowedFrameQP={} DataRateLimits={} ConstantBitRate={}",
                name(codec),
                string(id),
                has("MaxAllowedFrameQP"),
                has("MinAllowedFrameQP"),
                has("DataRateLimits"),
                has("ConstantBitRate")
            ));
            unsafe {
                let pl = CFDictionaryGetValue(props, k("kVTCompressionPropertyKey_ProfileLevel"));
                let values = if pl.is_null() {
                    null()
                } else {
                    CFDictionaryGetValue(pl, k("kVTPropertySupportedValueListKey"))
                };
                if !values.is_null() {
                    let mut names = vec![];
                    for i in 0..CFArrayGetCount(values) {
                        let v = CFArrayGetValueAtIndex(values, i);
                        let s = string(v);
                        if low_latency && (s.contains("AutoLevel") || s.ends_with("_Auto")) {
                            CFRetain(v);
                            found.push((s.clone(), v));
                        }
                        names.push(s);
                    }
                    log.line(format!(
                        "Q1 {} ll={low_latency} ProfileLevel values: {}",
                        name(codec),
                        names.join(" ")
                    ));
                }
                CFRelease(props);
                if !id.is_null() {
                    CFRelease(id);
                }
            }
        }
        profiles.push((codec, found));
    }
    // Every AutoLevel profile the encoder lists, plus no profile, for each input format.
    for (codec, list) in &profiles {
        let mut candidates: Vec<(String, Ref)> = vec![("default".into(), null())];
        candidates.extend(list.iter().cloned());
        for fmt in [F420V, F444V, X444] {
            for (pname, p) in &candidates {
                let mut cfg = Cfg::new(*codec, 1920, 1080, 60);
                cfg.fmt = fmt;
                cfg.profile = *p;
                cfg.profile_name = pname.clone();
                cfg.max_qp = Some(18);
                let mut src = TextPage::new(1920, 1080, 6, 24, true);
                match run(&cfg, &mut src, 2, 6, true) {
                    Ok(r) => {
                        let e = r.errs.last().copied().unwrap_or_default();
                        log.line(format!(
                            "Q1 {} in={} profile={} readback={} {} idr={}B enc_ms={:.2} decode={} y_psnr={:.1} cb_psnr={:.1} cr_psnr={:.1} notes=[{}]",
                            name(*codec),
                            fourcc(fmt),
                            pname,
                            r.profile_readback,
                            r.sps,
                            r.idr_bytes,
                            mean(&r.ms),
                            if r.decode_note.is_empty() { "ok".into() } else { r.decode_note.clone() },
                            e.y_psnr,
                            e.cb_psnr,
                            e.cr_psnr,
                            r.notes.join(",")
                        ));
                    }
                    Err(e) => log.line(format!(
                        "Q1 {} in={} profile={pname} error={e}",
                        name(*codec),
                        fourcc(fmt)
                    )),
                }
            }
        }
    }
}

fn q2(log: &mut Log) {
    log.line("## Q2 scrolled text (24 rows a frame) vs QP: avg 1 Gbps, no DataRateLimits; bytes over the scroll frames; luma error decoded back");
    for (w, h, moving) in [(1920usize, 1080usize, 60usize), (3840, 2160, 30)] {
        let mut src = TextPage::new(w, h, moving + 1, 24, false);
        for codec in [H264, HEVC] {
            for low_latency in [true, false] {
                if !low_latency && w > 1920 {
                    continue;
                }
                for (mode, pin) in [("max", false), ("min=max", true)] {
                    for qp in [18, 20, 22] {
                        let mut cfg = Cfg::new(codec, w, h, 60);
                        cfg.max_qp = Some(qp);
                        cfg.min_qp = pin.then_some(qp);
                        cfg.low_latency = low_latency;
                        match run(&cfg, &mut src, 10, moving, true) {
                            Ok(r) => {
                                let b: Vec<f64> = r.bytes.iter().map(|&b| b as f64).collect();
                                let yp: Vec<f64> = r.errs.iter().map(|e| e.y_psnr).collect();
                                let ymax = r.errs.iter().map(|e| e.y_max).max().unwrap_or(0);
                                let bad: Vec<f64> =
                                    r.errs.iter().map(|e| e.y_bad * 100.0).collect();
                                log.line(format!(
                                    "Q2 {}x{} {} ll={} qp {}={} | idr={}B scroll mean={:.0}B p95={:.0}B max={:.0}B (={:.1} Mbps@60 {:.1} Mbps@120) | y_psnr mean={:.2} min={:.2} max_abs_err={} bad>24 mean={:.3}% max={:.3}% | drops={} enc_ms mean={:.2} | readback {} {} notes=[{}] {}",
                                    w, h, name(codec), low_latency, mode, qp,
                                    r.idr_bytes, mean(&b), pct(&b, 0.95), pct(&b, 1.0),
                                    mean(&b) * 8.0 * 60.0 / 1e6, mean(&b) * 8.0 * 120.0 / 1e6,
                                    mean(&yp), pct(&yp, 0.0), ymax, mean(&bad), pct(&bad, 1.0),
                                    r.drops, mean(&r.ms), r.qp_readback, r.sps, r.notes.join(","), r.decode_note
                                ));
                            }
                            Err(e) => log.line(format!(
                                "Q2 {w}x{h} {} ll={low_latency} qp {mode}={qp} error={e}",
                                name(codec)
                            )),
                        }
                    }
                }
            }
        }
    }
}

fn q3(log: &mut Log) {
    log.line("## Q3 4K full-screen motion, avg 1 Gbps, no DataRateLimits, back-to-back synchronous encodes (EncodeFrame+CompleteFrames)");
    let (w, h, moving) = (3840usize, 2160usize, 240usize);
    let mut text = TextPage::new(w, h, moving + 1, 24, false);
    let mut bars = Bars::new(w);
    for content in ["bars", "text"] {
        for codec in [H264, HEVC] {
            for fps in [60u32, 120] {
                for qp in [Some(18), Some(20), Some(22), None] {
                    let mut cfg = Cfg::new(codec, w, h, fps);
                    cfg.max_qp = qp;
                    let src: &mut dyn Source =
                        if content == "bars" { &mut bars } else { &mut text };
                    let t = Instant::now();
                    match run(&cfg, src, 5, moving, false) {
                        Ok(r) => {
                            let b: Vec<f64> = r.bytes.iter().map(|&b| b as f64).collect();
                            log.line(format!(
                                "Q3 {content} 4K{fps} {} maxqp={} | {:.1} Mbps (mean {:.0}B p95 {:.0}B max {:.0}B, idr {}B) | enc_ms mean={:.2} p50={:.2} p95={:.2} max={:.2} (budget {:.2}) | drops={}/{} | wall {:.1}s notes=[{}]",
                                name(codec),
                                qp.map_or("none".into(), |q| q.to_string()),
                                mean(&b) * 8.0 * f64::from(fps) / 1e6,
                                mean(&b), pct(&b, 0.95), pct(&b, 1.0), r.idr_bytes,
                                mean(&r.ms), pct(&r.ms, 0.5), pct(&r.ms, 0.95), pct(&r.ms, 1.0),
                                1000.0 / f64::from(fps),
                                r.drops, moving,
                                t.elapsed().as_secs_f64(), r.notes.join(",")
                            ));
                        }
                        Err(e) => {
                            log.line(format!("Q3 {content} 4K{fps} {} error={e}", name(codec)))
                        }
                    }
                }
            }
        }
    }
}

/// The merged encoder (videotoolbox.rs on feat-cmux-next): H.264 High, low-latency rate
/// control, AverageBitRate plus one frame interval's DataRateLimits, no QP ceiling.
fn q4(log: &mut Log) {
    use cmux_encode::H264Encoder;
    use cmux_encode::I420;
    use cmux_encode::videotoolbox::VideoToolbox;
    log.line("## Q4 merged VideoToolbox (DataRateLimits per frame, no QP ceiling): scrolled text 24 rows a frame after 30 still frames");
    for (w, h, fps) in [(512usize, 256usize, 30u32), (1920, 1080, 60), (3840, 2160, 60)] {
        let moving = 120usize;
        let page = TextPage::new(w, h, moving + 1, 24, false);
        for kbps in [400u32, 2000] {
            let mut enc = match VideoToolbox::new(w as u32, h as u32, fps, kbps, false) {
                Ok(e) => e,
                Err(e) => {
                    log.line(format!("Q4 {w}x{h}@{fps} {kbps}kbps error={e}"));
                    continue;
                }
            };
            let mut pic = I420::new(w, h);
            let mut au = Vec::new();
            let interval = 1_000_000 / i64::from(fps);
            let (mut still_drops, mut drops, mut sizes, mut ms, mut first_drop) =
                (0, 0, vec![], vec![], None);
            let mut src = page.clone_view();
            for f in 0..30 + moving {
                let frame = if f < 30 { 0 } else { f - 29 };
                src.prepare(frame);
                for y in 0..h {
                    pic.y[y * w..(y + 1) * w].copy_from_slice(src.luma(y));
                }
                let t = Instant::now();
                let r = enc.encode(&pic, f == 0, f as i64 * interval, &mut au);
                let took = t.elapsed().as_secs_f64() * 1000.0;
                if let Err(e) = r {
                    log.line(format!("Q4 {w}x{h}@{fps} {kbps}kbps frame {f} error={e}"));
                    break;
                }
                if f < 30 {
                    still_drops += usize::from(au.is_empty() && f > 0);
                    continue;
                }
                ms.push(took);
                if au.is_empty() {
                    drops += 1;
                    first_drop.get_or_insert(f - 29);
                } else {
                    sizes.push(au.len() as f64);
                }
            }
            let budget = u64::from(kbps) * 1000 / 8 / u64::from(fps);
            let over = sizes.iter().filter(|&&s| s > budget as f64 * 1.5).count();
            log.line(format!(
                "Q4 {w}x{h}@{fps} {kbps}kbps | scroll drops={drops}/{moving} (first at scroll frame {:?}) still-phase empty={still_drops}/29 | sent mean={:.0}B max={:.0}B budget={budget}B over1.5x={over} | enc_ms mean={:.2}",
                first_drop, mean(&sizes), pct(&sizes, 1.0), mean(&ms)
            ));
        }
    }
}

impl TextPage {
    /// The page again (Q4 keeps one page per size across both rates).
    fn clone_view(&self) -> TextPage {
        TextPage {
            w: self.w,
            y: self.y.clone(),
            cb: self.cb.clone(),
            cr: self.cr.clone(),
            neutral: self.neutral.clone(),
            colored: self.colored,
            scroll: 0,
            step: self.step,
        }
    }
}

#[test]
fn vt_ultra_measurements() {
    let mut log = Log::open();
    header(&mut log);
    let only = std::env::var("VT_ULTRA_ONLY").unwrap_or_default();
    let want = |q: &str| only.is_empty() || only.split(',').any(|x| x == q);
    let t = Instant::now();
    if want("q4") {
        q4(&mut log);
    }
    if want("q1") {
        q1(&mut log);
    }
    if want("q2") {
        q2(&mut log);
    }
    if want("q3") {
        q3(&mut log);
    }
    log.line(format!("# done in {:.0}s", t.elapsed().as_secs_f64()));
    let _ = cfstr;
}
