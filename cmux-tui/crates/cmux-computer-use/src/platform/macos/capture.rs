//! Screenshots without a host (tests and the CLI): CoreGraphics'
//! `CGWindowListCreateImage` / `CGDisplayCreateImage`. Both are obsoleted in
//! the macOS 15 SDK in favor of ScreenCaptureKit (which the Swift worker
//! uses through [`crate::desktop::HostServices`]), so they are looked up at
//! run time and this path says so when the OS no longer has them.

use std::ffi::c_void;
use std::sync::OnceLock;

use super::roles;
use super::sys::*;
use crate::desktop::{DResult, DesktopError, Point, RawFrame, Rect};

const LIST_INCLUDING_WINDOW: u32 = 1 << 3;
const IMAGE_BOUNDS_IGNORE_FRAMING: u32 = 1 << 0;
const IMAGE_BEST_RESOLUTION: u32 = 1 << 3;
/// kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big: RGBA bytes.
const BITMAP_RGBA: u32 = 1 | (4 << 12);

type WindowImageFn = unsafe extern "C" fn(CGRect, u32, u32, u32) -> CFTypeRef;
type DisplayImageFn = unsafe extern "C" fn(u32) -> CFTypeRef;

fn window_image_fn() -> Option<WindowImageFn> {
    static F: OnceLock<Option<WindowImageFn>> = OnceLock::new();
    *F.get_or_init(|| {
        let p = symbol(c"CGWindowListCreateImage")?;
        // SAFETY: the symbol has this C signature.
        Some(unsafe { std::mem::transmute::<*mut c_void, WindowImageFn>(p) })
    })
}

fn display_image_fn() -> Option<DisplayImageFn> {
    static F: OnceLock<Option<DisplayImageFn>> = OnceLock::new();
    *F.get_or_init(|| {
        let p = symbol(c"CGDisplayCreateImage")?;
        // SAFETY: the symbol has this C signature.
        Some(unsafe { std::mem::transmute::<*mut c_void, DisplayImageFn>(p) })
    })
}

pub fn screen_capture_granted() -> bool {
    // SAFETY: no arguments.
    unsafe { CGPreflightScreenCaptureAccess() }
}

fn unavailable() -> DesktopError {
    DesktopError::Unsupported(
        "this macOS has no CoreGraphics screenshots; screenshots come from the cmux Computer Use worker (ScreenCaptureKit)".into(),
    )
}

/// Draws a CGImage into tightly packed RGBA8.
fn rgba_of(image: &Cf) -> DResult<(u32, u32, Vec<u8>)> {
    // SAFETY: image is a live CGImage; the bitmap context draws into `buf`,
    // which is width * height * 4 bytes and outlives the context.
    unsafe {
        let w = CGImageGetWidth(image.ptr());
        let h = CGImageGetHeight(image.ptr());
        if w == 0 || h == 0 {
            return Err(DesktopError::Failed("the screenshot is empty".into()));
        }
        let mut buf = vec![0u8; w * h * 4];
        let space = Cf::created(CGColorSpaceCreateDeviceRGB())
            .ok_or_else(|| DesktopError::Failed("no RGB color space".into()))?;
        let ctx = Cf::created(CGBitmapContextCreate(
            buf.as_mut_ptr().cast(),
            w,
            h,
            8,
            w * 4,
            space.ptr(),
            BITMAP_RGBA,
        ))
        .ok_or_else(|| DesktopError::Failed("could not create a bitmap context".into()))?;
        let rect = CGRect {
            origin: CGPoint { x: 0.0, y: 0.0 },
            size: CGSize { width: w as f64, height: h as f64 },
        };
        CGContextDrawImage(ctx.ptr(), rect, image.ptr());
        drop(ctx);
        Ok((w as u32, h as u32, buf))
    }
}

fn frame_from(image: Cf, origin: Point, points_wide: f64) -> DResult<RawFrame> {
    let (width, height, rgba) = rgba_of(&image)?;
    Ok(RawFrame {
        width,
        height,
        rgba,
        scale: roles::scale_of(width as usize, points_wide),
        origin,
    })
}

/// One window, also when covered by others.
pub fn window(id: u32, frame: &Rect) -> DResult<RawFrame> {
    if !screen_capture_granted() {
        return Err(DesktopError::PermissionMissing("screen_capture".into()));
    }
    let f = window_image_fn().ok_or_else(unavailable)?;
    let null = CGRect {
        origin: CGPoint { x: f64::INFINITY, y: f64::INFINITY },
        size: CGSize { width: 0.0, height: 0.0 },
    };
    // SAFETY: f is CGWindowListCreateImage; the result is +1 or null.
    let image = Cf::created(unsafe {
        f(null, LIST_INCLUDING_WINDOW, id, IMAGE_BOUNDS_IGNORE_FRAMING | IMAGE_BEST_RESOLUTION)
    })
    .ok_or_else(|| DesktopError::Failed(format!("window {id} gave no image")))?;
    frame_from(image, Point { x: frame.x, y: frame.y }, frame.width)
}

/// One display (`None`: the main one). Ids are CGDirectDisplayIDs.
pub fn display(id: Option<&str>) -> DResult<RawFrame> {
    if !screen_capture_granted() {
        return Err(DesktopError::PermissionMissing("screen_capture".into()));
    }
    let f = display_image_fn().ok_or_else(unavailable)?;
    let display = match id {
        // SAFETY: no arguments.
        None => unsafe { CGMainDisplayID() },
        Some(s) => s
            .trim()
            .parse::<u32>()
            .map_err(|_| DesktopError::TargetNotFound(format!("display {s}")))?,
    };
    // SAFETY: plain value call.
    let bounds = unsafe { CGDisplayBounds(display) };
    if bounds.size.width <= 0.0 {
        return Err(DesktopError::TargetNotFound(format!("display {display}")));
    }
    // SAFETY: f is CGDisplayCreateImage; the result is +1 or null.
    let image = Cf::created(unsafe { f(display) })
        .ok_or_else(|| DesktopError::Failed(format!("display {display} gave no image")))?;
    frame_from(image, Point { x: bounds.origin.x, y: bounds.origin.y }, bounds.size.width)
}
