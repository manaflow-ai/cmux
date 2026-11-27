//! Encoding captured IOSurfaces with no CPU copy (remote-tab-r2.md B2): the
//! remote browser host on a Mac hands Viz's IOSurface (BGRA, or NV12) to the
//! hardware encoder through CVPixelBufferCreateWithIOSurface. The call is
//! synchronous, so the caller releases its capture lease when it returns.

use std::ffi::c_void;
use std::ptr::{null, null_mut};

use super::{
    CFRelease, CFTypeRef, CVPixelBufferCreateWithIOSurface, CVPixelBufferPoolRef, CVPixelBufferRef,
    IOSurfaceGetHeight, IOSurfaceGetPixelFormat, IOSurfaceGetWidth, PIXEL_420V,
    VTPixelTransferSessionRef, VideoToolbox, cv_pool_sys, dict,
    kCVPixelBufferIOSurfacePropertiesKey, number_i32, vt_transfer_sys,
};
use crate::Res;

const PIXEL_BGRA: u32 = u32::from_be_bytes(*b"BGRA");
/// NV12 full range also counts as NV12.
const PIXEL_420F: u32 = u32::from_be_bytes(*b"420f");

/// The pixel layout of a captured surface.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SurfaceFormat {
    Bgra,
    Nv12,
}

/// The color space the surface's pixels are in. The session tags its output
/// with sRGB transfer (H.264 13; both spaces use the sRGB curve), the BT.709 YCbCr
/// matrix and these primaries (sRGB: BT.709; Display P3: P3 D65), so the viewer's
/// decoder presents it correctly.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ColorTag {
    Srgb,
    DisplayP3,
}

/// A rectangle in surface pixels (a damage hint; VideoToolbox has no damage
/// input, so it is unused today).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct SurfaceRect {
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
}

/// One captured IOSurface to encode. Built only through the unsafe
/// [`SurfaceFrame::new`], whose contract keeps the surface alive.
#[derive(Debug, Clone, Copy)]
pub struct SurfaceFrame {
    io_surface: *mut c_void,
    pub format: SurfaceFormat,
    pub width: u32,
    pub height: u32,
    pub color: ColorTag,
}

impl SurfaceFrame {
    /// # Safety
    /// `io_surface` is a live IOSurfaceRef that stays alive until `encode_surface` returns.
    pub unsafe fn new(
        io_surface: *mut c_void,
        format: SurfaceFormat,
        width: u32,
        height: u32,
        color: ColorTag,
    ) -> Self {
        Self { io_surface, format, width, height, color }
    }
}

/// Encodes captured IOSurfaces with no CPU copy (remote-tab-r2.md B2).
pub trait SurfaceEncoder: Send {
    fn encode_surface(
        &mut self,
        frame: &SurfaceFrame,
        damage: SurfaceRect,
        force_idr: bool,
        pts_us: i64,
        out: &mut Vec<u8>,
    ) -> Res<bool>;
    fn set_bitrate(&mut self, kbps: u32);
    fn kbps(&self) -> u32;
    fn set_acknowledged_ltr_tokens(&mut self, _tokens: &[u64]) {}
    fn set_force_ltr_refresh(&mut self, _refresh: bool) {}
    fn ltr_token(&self) -> Option<u64> {
        None
    }
}

impl SurfaceEncoder for VideoToolbox {
    fn set_acknowledged_ltr_tokens(&mut self, tokens: &[u64]) {
        self.acknowledged_ltr_tokens.clear();
        self.acknowledged_ltr_tokens.extend_from_slice(tokens);
    }

    fn set_force_ltr_refresh(&mut self, refresh: bool) {
        self.force_ltr_refresh = refresh;
    }

    fn ltr_token(&self) -> Option<u64> {
        self.ltr_token
    }
    /// Wraps the surface (no copy) and encodes it. A frame whose format or
    /// size does not match its surface is refused; a new size recreates the
    /// session and the frame becomes an IDR. Returns true for an IDR.
    fn encode_surface(
        &mut self,
        frame: &SurfaceFrame,
        _damage: SurfaceRect,
        force_idr: bool,
        pts_us: i64,
        out: &mut Vec<u8>,
    ) -> Res<bool> {
        out.clear();
        self.idr_cause = None;
        if frame.io_surface.is_null() {
            return Err("encode_surface: NULL IOSurface".into());
        }
        // SAFETY: a live IOSurfaceRef by SurfaceFrame::new's contract.
        let (width, height, pixel) = unsafe {
            (
                IOSurfaceGetWidth(frame.io_surface),
                IOSurfaceGetHeight(frame.io_surface),
                IOSurfaceGetPixelFormat(frame.io_surface),
            )
        };
        let format_ok = match frame.format {
            SurfaceFormat::Bgra => pixel == PIXEL_BGRA,
            SurfaceFormat::Nv12 => pixel == PIXEL_420V || pixel == PIXEL_420F,
        };
        if !format_ok {
            return Err(format!(
                "encode_surface: surface pixel format {pixel:#x} is not {:?}",
                frame.format
            )
            .into());
        }
        if (width, height) != (frame.width as usize, frame.height as usize) {
            return Err(format!(
                "encode_surface: surface is {width}x{height}, frame says {}x{}",
                frame.width, frame.height
            )
            .into());
        }
        // The resolution ladder's picture, when it is smaller than the surface: the session
        // encodes that size from a GPU-scaled copy. Equal (or larger): the surface as it is.
        let scaled_to =
            self.picture.filter(|&(w, h)| (w, h) != (width, height) && w <= width && h <= height);
        let (enc_width, enc_height) = scaled_to.unwrap_or((width, height));
        let resized = self.ensure_session(enc_width, enc_height)?;
        self.apply_color(frame.color);
        let mut pixel_buffer: CVPixelBufferRef = null_mut();
        // SAFETY: wraps the live surface in a new pixel buffer (no copy); released below.
        let status = unsafe {
            CVPixelBufferCreateWithIOSurface(
                std::ptr::null(),
                frame.io_surface,
                std::ptr::null(),
                &mut pixel_buffer,
            )
        };
        if status != 0 || pixel_buffer.is_null() {
            return Err(format!("CVPixelBufferCreateWithIOSurface failed: {status}").into());
        }
        self.idr_cause = (resized && !force_idr).then_some("resize");
        let source = match scaled_to {
            None => Ok(pixel_buffer),
            Some((w, h)) => self.scale(pixel_buffer, w, h),
        };
        let result = source.and_then(|buffer| {
            let r = self.encode_buffer(buffer, force_idr || resized, pts_us, out);
            if buffer != pixel_buffer {
                // SAFETY: releasing the scaled buffer `scale` returned (back to its pool);
                // the encode has completed.
                unsafe { CFRelease(buffer as CFTypeRef) };
            }
            r
        });
        // SAFETY: releasing the wrapper we created; the encode has completed.
        unsafe { CFRelease(pixel_buffer as CFTypeRef) };
        result
    }

    fn set_bitrate(&mut self, kbps: u32) {
        crate::H264Encoder::set_bitrate(self, kbps);
    }

    fn kbps(&self) -> u32 {
        crate::H264Encoder::kbps(self)
    }
}

impl VideoToolbox {
    /// A `width` x `height` copy of `source` scaled on the GPU, in a pooled buffer the caller
    /// releases. The scaler is made at the first scaled frame and kept.
    fn scale(
        &mut self,
        source: CVPixelBufferRef,
        width: usize,
        height: usize,
    ) -> Res<CVPixelBufferRef> {
        if self.scaler.is_none() {
            self.scaler = Some(Scaler::new()?);
        }
        let scaler = self.scaler.as_mut().ok_or("no pixel transfer session")?;
        scaler.scale(source, width, height)
    }
}

/// Scales captured surfaces down to the resolution ladder's picture (design D5) with a
/// VTPixelTransferSession: on the GPU, no CPU copy, into IOSurface-backed NV12 (420v)
/// buffers from a pool of the picture's size (a new size makes a new pool).
pub(super) struct Scaler {
    transfer: VTPixelTransferSessionRef,
    /// The pool of the last picture size; NULL before the first scaled frame.
    pool: CVPixelBufferPoolRef,
    pool_size: (usize, usize),
}

impl Scaler {
    fn new() -> Res<Self> {
        vt_transfer_sys::available()?;
        cv_pool_sys::available()?;
        let mut transfer: VTPixelTransferSessionRef = null_mut();
        // SAFETY: creates a transfer session into our local; released in Drop.
        let status =
            unsafe { vt_transfer_sys::VTPixelTransferSessionCreate(null(), &mut transfer) };
        if status != 0 || transfer.is_null() {
            return Err(format!("VTPixelTransferSessionCreate failed: {status}").into());
        }
        Ok(Self { transfer, pool: null_mut(), pool_size: (0, 0) })
    }

    /// Makes the pool hand out `width` x `height` buffers, replacing it on a size change.
    fn ensure_pool(&mut self, width: usize, height: usize) -> Res<()> {
        if !self.pool.is_null() && self.pool_size == (width, height) {
            return Ok(());
        }
        let mut pool: CVPixelBufferPoolRef = null_mut();
        // SAFETY: CF statics and numbers in dictionaries released after use (the pool
        // copies its attributes); the new pool lands in our local.
        let status = unsafe {
            let format = number_i32(PIXEL_420V as i32);
            let w = number_i32(i32::try_from(width).unwrap_or(i32::MAX));
            let h = number_i32(i32::try_from(height).unwrap_or(i32::MAX));
            let empty = dict(&[]);
            let attrs = dict(&[
                (cv_pool_sys::kCVPixelBufferPixelFormatTypeKey(), format),
                (cv_pool_sys::kCVPixelBufferWidthKey(), w),
                (cv_pool_sys::kCVPixelBufferHeightKey(), h),
                (kCVPixelBufferIOSurfacePropertiesKey(), empty),
            ]);
            let s = cv_pool_sys::CVPixelBufferPoolCreate(null(), null(), attrs, &mut pool);
            CFRelease(attrs);
            CFRelease(empty);
            CFRelease(h);
            CFRelease(w);
            CFRelease(format);
            s
        };
        if status != 0 || pool.is_null() {
            return Err(format!("CVPixelBufferPoolCreate {width}x{height} failed: {status}").into());
        }
        if !self.pool.is_null() {
            // SAFETY: releasing our previous pool once; buffers still out keep their own
            // reference to it.
            unsafe { CFRelease(self.pool as CFTypeRef) };
        }
        self.pool = pool;
        self.pool_size = (width, height);
        Ok(())
    }

    /// `source` scaled into a new pooled buffer, which the caller releases.
    fn scale(
        &mut self,
        source: CVPixelBufferRef,
        width: usize,
        height: usize,
    ) -> Res<CVPixelBufferRef> {
        self.ensure_pool(width, height)?;
        let mut target: CVPixelBufferRef = null_mut();
        // SAFETY: a buffer from our live pool into our local.
        let status = unsafe {
            cv_pool_sys::CVPixelBufferPoolCreatePixelBuffer(null(), self.pool, &mut target)
        };
        if status != 0 || target.is_null() {
            return Err(format!("CVPixelBufferPoolCreatePixelBuffer failed: {status}").into());
        }
        // SAFETY: both buffers are live; the transfer has completed when it returns.
        let status = unsafe {
            vt_transfer_sys::VTPixelTransferSessionTransferImage(self.transfer, source, target)
        };
        if status != 0 {
            // SAFETY: releasing the buffer we took from the pool, unused.
            unsafe { CFRelease(target as CFTypeRef) };
            return Err(format!("VTPixelTransferSessionTransferImage failed: {status}").into());
        }
        Ok(target)
    }
}

impl Drop for Scaler {
    fn drop(&mut self) {
        // SAFETY: invalidating and releasing our own transfer session and pool once.
        unsafe {
            vt_transfer_sys::VTPixelTransferSessionInvalidate(self.transfer);
            CFRelease(self.transfer as CFTypeRef);
            if !self.pool.is_null() {
                CFRelease(self.pool as CFTypeRef);
            }
        }
    }
}

#[cfg(test)]
#[path = "surface_tests.rs"]
mod tests;
