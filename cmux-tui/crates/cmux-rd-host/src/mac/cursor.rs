//! The macOS cursor as metadata (cap `cursor`, crate::cursor): where the system cursor is
//! (a CGEvent's location, in global display points) and the shape every app sees
//! (`+[NSCursor currentSystemCursor]`), drawn into premultiplied RGBA at the stream's pixel
//! scale. The capture leaves the cursor out of its pictures for such a session.
//!
//! A shape is read only when the window server's cursor seed changes (the private
//! `CGSCurrentCursorSeed`, looked up at run time); without it, at most every
//! [`SHAPE_EVERY`]. Reading a shape copies its image from the window server, so a still or
//! moving cursor that keeps its shape costs one location read per sample.

use super::capture::Bounds;
use super::sys::{self, appkit, cg, msg, sel, send_id, AutoreleasePool, CGImageRef, CGPoint};
use super::sys::{CGRect, CGSize, Id, Sel};
use crate::cursor::{CursorImage, CursorSample};
use cmux_rd_proto::MAX_CURSOR_SIDE;
use std::ffi::c_void;
use std::sync::OnceLock;
use std::time::{Duration, Instant};

/// Between shape reads when the window server's cursor seed is not available.
const SHAPE_EVERY: Duration = Duration::from_millis(33);

type SeedFn = unsafe extern "C" fn() -> i32;

/// `CGSCurrentCursorSeed`: a counter the window server bumps when the cursor's shape changes.
fn seed_fn() -> Option<SeedFn> {
    static SEED: OnceLock<Option<usize>> = OnceLock::new();
    let address = *SEED.get_or_init(|| {
        // SAFETY: a NUL-terminated name; RTLD_DEFAULT searches the images already loaded
        // (CoreGraphics is, after sys::load).
        let address = unsafe { libc::dlsym(libc::RTLD_DEFAULT, c"CGSCurrentCursorSeed".as_ptr()) };
        (!address.is_null()).then_some(address as usize)
    });
    // SAFETY: the symbol is `int CGSCurrentCursorSeed(void)`.
    address.map(|a| unsafe { std::mem::transmute::<*mut c_void, SeedFn>(a as *mut c_void) })
}

/// Whether this Mac can report its cursor: the host frameworks and AppKit's NSCursor load.
pub fn available() -> bool {
    sys::load().is_ok() && appkit::available().is_ok() && !sys::class(c"NSCursor").is_null()
}

/// Reads one display's cursor in its stream's pixels.
pub struct CursorReader {
    bounds: Bounds,
    /// Stream pixels per display point, per axis.
    scale: (f64, f64),
    seed: Option<i32>,
    shape: u32,
    shape_read: Option<Instant>,
}

impl CursorReader {
    pub fn new(bounds: Bounds, size: (u32, u32)) -> Self {
        let scale =
            (f64::from(size.0) / bounds.width.max(1.0), f64::from(size.1) / bounds.height.max(1.0));
        Self { bounds, scale, seed: None, shape: 0, shape_read: None }
    }

    pub fn sample(&mut self) -> Option<CursorSample> {
        let point = location()?;
        let (x, y) = to_pixels(point, self.bounds, self.scale);
        let seed = seed_fn().map(|f| {
            // SAFETY: a no-argument window server query.
            unsafe { f() }
        });
        let due = match seed {
            Some(seed) => self.seed != Some(seed),
            None => self.shape_read.is_none_or(|t| t.elapsed() >= SHAPE_EVERY),
        };
        let mut image = None;
        if due {
            if let Some(read) = read_shape(self.scale.0) {
                let id = read.id();
                self.seed = seed;
                self.shape_read = Some(Instant::now());
                if id != self.shape {
                    self.shape = id;
                    image = Some(read);
                }
            }
        }
        // macOS has no public query for another app's hidden cursor: always shown.
        Some(CursorSample { x, y, visible: true, shape: self.shape, image })
    }
}

/// Global display points to stream pixels (the injector's inverse, `input.rs`).
fn to_pixels(point: CGPoint, bounds: Bounds, scale: (f64, f64)) -> (i32, i32) {
    let px = ((point.x - bounds.x) * scale.0).floor();
    let py = ((point.y - bounds.y) * scale.1).floor();
    let clamp = |v: f64| v.clamp(f64::from(i32::MIN), f64::from(i32::MAX)) as i32;
    (clamp(px), clamp(py))
}

/// The cursor's location in global display points (top left origin).
fn location() -> Option<CGPoint> {
    // SAFETY: a NULL source makes an event that only carries the current location; it is
    // released below.
    unsafe {
        let event = cg::CGEventCreate(std::ptr::null_mut());
        if event.is_null() {
            return None;
        }
        let point = cg::CGEventGetLocation(event);
        sys::cf::CFRelease(event as *const c_void);
        Some(point)
    }
}

/// The system cursor's shape at `scale` stream pixels per point, at most
/// [`MAX_CURSOR_SIDE`] on a side.
fn read_shape(scale: f64) -> Option<CursorImage> {
    let _pool = AutoreleasePool::new();
    let cursor = send_id(sys::class(c"NSCursor"), c"currentSystemCursor");
    if cursor.is_null() {
        return None;
    }
    let image = send_id(cursor, c"image");
    if image.is_null() {
        return None;
    }
    // SAFETY: -hotSpot returns an NSPoint and -size an NSSize (two doubles, in registers);
    // -CGImageForProposedRect:context:hints: returns an autoreleased CGImage (or NULL).
    let (hot, size, cg_image) = unsafe {
        let hot = msg::<unsafe extern "C" fn(Id, Sel) -> CGPoint>()(cursor, sel(c"hotSpot"));
        let size = msg::<unsafe extern "C" fn(Id, Sel) -> CGSize>()(image, sel(c"size"));
        let cg_image = msg::<unsafe extern "C" fn(Id, Sel, *const CGRect, Id, Id) -> CGImageRef>()(
            image,
            sel(c"CGImageForProposedRect:context:hints:"),
            std::ptr::null(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
        );
        (hot, size, cg_image)
    };
    if cg_image.is_null() || !(size.width > 0.0 && size.height > 0.0) {
        return None;
    }
    let (width, height, k) = fit_shape(size, scale);
    let mut rgba = vec![0u8; width as usize * height as usize * 4];
    // SAFETY: a bitmap context over `rgba` (width * 4 bytes a row), released before the
    // buffer is moved; the color space is released once the context holds it.
    unsafe {
        let space = cg::CGColorSpaceCreateWithName(cg::kCGColorSpaceSRGB());
        let context = cg::CGBitmapContextCreate(
            rgba.as_mut_ptr().cast(),
            width as usize,
            height as usize,
            8,
            width as usize * 4,
            space,
            sys::BITMAP_RGBA_PREMULTIPLIED,
        );
        cg::CGColorSpaceRelease(space);
        if context.is_null() {
            return None;
        }
        let rect = CGRect {
            origin: CGPoint::new(0.0, 0.0),
            size: CGSize { width: f64::from(width), height: f64::from(height) },
        };
        cg::CGContextDrawImage(context, rect, cg_image);
        cg::CGContextRelease(context);
    }
    // A bitmap context's memory holds the top row first; the hotspot counts from the top left.
    let hot_x = ((hot.x * k).round().max(0.0) as u32).min(width - 1);
    let hot_y = ((hot.y * k).round().max(0.0) as u32).min(height - 1);
    Some(CursorImage { width, height, hot_x, hot_y, rgba })
}

/// A shape `size` points large at `scale` pixels per point: its pixel size (at least 1, at
/// most [`MAX_CURSOR_SIDE`] on a side, aspect kept) and the pixels per point used.
fn fit_shape(size: CGSize, scale: f64) -> (u32, u32, f64) {
    let side = size.width.max(size.height) * scale;
    let max = f64::from(MAX_CURSOR_SIDE);
    let k = if side > max { scale * max / side } else { scale };
    let px = |v: f64| ((v * k).round() as u32).clamp(1, MAX_CURSOR_SIDE);
    (px(size.width), px(size.height), k)
}

#[cfg(test)]
#[path = "cursor_tests.rs"]
mod tests;
