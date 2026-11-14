use super::*;
use crate::videotoolbox::{
    CFRelease, CFTypeRef, CVPixelBufferRef, dict, kCVPixelBufferIOSurfacePropertiesKey,
};
use std::ptr::{null, null_mut};

crate::framework! {
    mod cv_sys = "/System/Library/Frameworks/CoreVideo.framework/CoreVideo" {
        fn CVPixelBufferCreate(a: *const c_void, w: usize, h: usize, fmt: u32, attrs: *const c_void, out: *mut CVPixelBufferRef) -> i32;
        fn CVPixelBufferGetIOSurface(pb: CVPixelBufferRef) -> *mut c_void;
    }
}
use cv_sys::*;

/// An IOSurface-backed pixel buffer; the surface lives as long as the buffer.
struct TestSurface(CVPixelBufferRef);

impl TestSurface {
    fn new(width: u32, height: u32, format: u32) -> Self {
        let mut pb: CVPixelBufferRef = null_mut();
        // SAFETY: creating an IOSurface-backed buffer; attrs released after use.
        let status = unsafe {
            let empty = dict(&[]);
            let attrs = dict(&[(kCVPixelBufferIOSurfacePropertiesKey(), empty)]);
            let s = CVPixelBufferCreate(
                null(),
                width as usize,
                height as usize,
                format,
                attrs,
                &mut pb,
            );
            CFRelease(attrs);
            CFRelease(empty);
            s
        };
        assert_eq!(status, 0, "CVPixelBufferCreate");
        Self(pb)
    }

    fn frame(
        &self,
        format: SurfaceFormat,
        width: u32,
        height: u32,
        color: ColorTag,
    ) -> SurfaceFrame {
        // SAFETY: the buffer (and so its surface) outlives every encode in the tests.
        unsafe {
            SurfaceFrame::new(CVPixelBufferGetIOSurface(self.0), format, width, height, color)
        }
    }
}

impl Drop for TestSurface {
    fn drop(&mut self) {
        // SAFETY: releasing the buffer we created.
        unsafe { CFRelease(self.0 as CFTypeRef) };
    }
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
    // SAFETY: a NULL surface is refused before any use.
    let null_surface =
        unsafe { SurfaceFrame::new(null_mut(), SurfaceFormat::Bgra, 256, 128, ColorTag::Srgb) };
    assert!(enc.encode_surface(&null_surface, SurfaceRect::default(), true, 0, &mut out).is_err());
}
