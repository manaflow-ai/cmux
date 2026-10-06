//! Placeholder (red commit): B2 surface encoding lands in the next commit.

use std::ffi::c_void;

use super::VideoToolbox;
use crate::Res;

/// The pixel layout of a captured surface.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SurfaceFormat {
    Bgra,
    Nv12,
}

/// The color space the surface's pixels are in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ColorTag {
    Srgb,
    DisplayP3,
}

/// A rectangle in surface pixels.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct SurfaceRect {
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
}

/// One captured IOSurface to encode.
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
    pub unsafe fn new(io_surface: *mut c_void, format: SurfaceFormat, width: u32, height: u32, color: ColorTag) -> Self {
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
    fn encode_surface(&mut self, _f: &SurfaceFrame, _d: SurfaceRect, _i: bool, _p: i64, out: &mut Vec<u8>) -> Res<bool> {
        out.clear();
        Ok(false)
    }
    fn set_bitrate(&mut self, kbps: u32) {
        crate::H264Encoder::set_bitrate(self, kbps);
    }
    fn kbps(&self) -> u32 {
        crate::H264Encoder::kbps(self)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::videotoolbox::{dict, CFRelease, CFTypeRef, CVPixelBufferRef, kCVPixelBufferIOSurfacePropertiesKey, PIXEL_420V};
    use std::ptr::{null, null_mut};

    const PIXEL_BGRA: u32 = u32::from_be_bytes(*b"BGRA");

    #[link(name = "CoreVideo", kind = "framework")]
    unsafe extern "C" {
        fn CVPixelBufferCreate(
            a: *const c_void,
            w: usize,
            h: usize,
            fmt: u32,
            attrs: *const c_void,
            out: *mut CVPixelBufferRef,
        ) -> i32;
        fn CVPixelBufferGetIOSurface(pb: CVPixelBufferRef) -> *mut c_void;
    }

    /// An IOSurface-backed pixel buffer; the surface lives as long as the buffer.
    struct TestSurface(CVPixelBufferRef);

    impl TestSurface {
        fn new(width: u32, height: u32, format: u32) -> Self {
            let mut pb: CVPixelBufferRef = null_mut();
            // SAFETY: creating an IOSurface-backed buffer; attrs released after use.
            let status = unsafe {
                let empty = dict(&[]);
                let attrs = dict(&[(kCVPixelBufferIOSurfacePropertiesKey, empty)]);
                let s = CVPixelBufferCreate(null(), width as usize, height as usize, format, attrs, &mut pb);
                CFRelease(attrs);
                CFRelease(empty);
                s
            };
            assert_eq!(status, 0, "CVPixelBufferCreate");
            Self(pb)
        }

        fn frame(&self, format: SurfaceFormat, width: u32, height: u32, color: ColorTag) -> SurfaceFrame {
            // SAFETY: the buffer (and so its surface) outlives every encode in the tests.
            unsafe { SurfaceFrame::new(CVPixelBufferGetIOSurface(self.0), format, width, height, color) }
        }
    }

    impl Drop for TestSurface {
        fn drop(&mut self) {
            // SAFETY: releasing the buffer we created.
            unsafe { CFRelease(self.0 as CFTypeRef) };
        }
    }

    fn encode_until_output(enc: &mut VideoToolbox, frame: &SurfaceFrame, force_idr: bool) -> (bool, Vec<u8>) {
        let mut out = Vec::new();
        let mut idr = false;
        for i in 0..4 {
            idr |= enc.encode_surface(frame, SurfaceRect::default(), force_idr && i == 0, i * 33_000, &mut out).expect("encode");
            if !out.is_empty() {
                break;
            }
        }
        (idr, out)
    }

    #[test]
    fn a_bgra_surface_encodes_an_idr_with_no_copy() {
        let mut enc = VideoToolbox::new(256, 128, 30, 2_000, false).expect("hardware encoder");
        let surface = TestSurface::new(256, 128, PIXEL_BGRA);
        let (idr, au) = encode_until_output(&mut enc, &surface.frame(SurfaceFormat::Bgra, 256, 128, ColorTag::Srgb), true);
        assert!(idr);
        assert!(au.starts_with(&[0, 0, 0, 1]));
    }

    #[test]
    fn an_nv12_surface_in_display_p3_encodes() {
        let mut enc = VideoToolbox::new(256, 128, 30, 2_000, false).expect("hardware encoder");
        let surface = TestSurface::new(256, 128, PIXEL_420V);
        let (idr, au) = encode_until_output(&mut enc, &surface.frame(SurfaceFormat::Nv12, 256, 128, ColorTag::DisplayP3), true);
        assert!(idr);
        assert!(!au.is_empty());
    }

    #[test]
    fn a_new_size_recreates_the_session_and_starts_with_an_idr() {
        let mut enc = VideoToolbox::new(256, 128, 30, 2_000, false).expect("hardware encoder");
        let small = TestSurface::new(256, 128, PIXEL_BGRA);
        encode_until_output(&mut enc, &small.frame(SurfaceFormat::Bgra, 256, 128, ColorTag::Srgb), true);
        let large = TestSurface::new(512, 256, PIXEL_BGRA);
        let (idr, au) = encode_until_output(&mut enc, &large.frame(SurfaceFormat::Bgra, 512, 256, ColorTag::Srgb), false);
        assert!(idr, "a resized stream starts with an IDR");
        assert!(!au.is_empty());
    }

    #[test]
    fn a_frame_that_does_not_match_its_surface_is_refused() {
        let mut enc = VideoToolbox::new(256, 128, 30, 2_000, false).expect("hardware encoder");
        let surface = TestSurface::new(256, 128, PIXEL_BGRA);
        let mut out = Vec::new();
        let wrong_format = surface.frame(SurfaceFormat::Nv12, 256, 128, ColorTag::Srgb);
        assert!(enc.encode_surface(&wrong_format, SurfaceRect::default(), true, 0, &mut out).is_err());
        let wrong_size = surface.frame(SurfaceFormat::Bgra, 300, 128, ColorTag::Srgb);
        assert!(enc.encode_surface(&wrong_size, SurfaceRect::default(), true, 0, &mut out).is_err());
        let null_surface = unsafe { SurfaceFrame::new(null_mut(), SurfaceFormat::Bgra, 256, 128, ColorTag::Srgb) };
        assert!(enc.encode_surface(&null_surface, SurfaceRect::default(), true, 0, &mut out).is_err());
    }
}
