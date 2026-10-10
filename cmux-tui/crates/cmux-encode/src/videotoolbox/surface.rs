//! Encoding captured IOSurfaces with no CPU copy (remote-tab-r2.md B2): the
//! remote browser host on a Mac hands Viz's IOSurface (BGRA, or NV12) to the
//! hardware encoder through CVPixelBufferCreateWithIOSurface. The call is
//! synchronous, so the caller releases its capture lease when it returns.

use std::ffi::c_void;
use std::ptr::null_mut;

use super::{
    CFRelease, CFTypeRef, CVPixelBufferCreateWithIOSurface, CVPixelBufferRef, IOSurfaceGetHeight,
    IOSurfaceGetPixelFormat, IOSurfaceGetWidth, PIXEL_420V, VideoToolbox,
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
/// with BT.709 transfer and YCbCr matrix and these primaries (sRGB: BT.709;
/// Display P3: P3 D65), so the viewer's decoder presents it correctly.
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
}

impl SurfaceEncoder for VideoToolbox {
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
        let resized = self.ensure_session(width, height)?;
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
        let result = self.encode_buffer(pixel_buffer, force_idr || resized, pts_us, out);
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
