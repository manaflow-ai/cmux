//! `--source synthetic` on a macOS host (bench builds; the picture and its rules are in
//! `crate::synthetic`): generated NV12 IOSurfaces instead of ScreenCaptureKit frames, encoded
//! by the same VideoToolbox surface path as captured frames and sent the same way, and viewer
//! input bumping the marker counter instead of posting CGEvents. No Screen Recording or
//! Accessibility grant is needed, so a run is two Macs over ssh.

use super::sys::{cf, cv, CFDictionaryRef, CFStringRef, CFTypeRef, CVPixelBufferRef};
use crate::desktop::{Desktop, FrameSource, Halves};
use crate::stream::SessionCfg;
use crate::synthetic::{self, Motion, Nv12, Painter, Synthetic};
use crate::Res;
use cmux_encode::framework;
use cmux_encode::videotoolbox::{
    ColorTag, SurfaceEncoder, SurfaceFormat, SurfaceFrame, SurfaceRect, VideoToolbox,
};
use cmux_rd_core::flow::Rect;
use cmux_rd_core::profile::EncodeProfile;
use cmux_rd_proto::InputEvent;
use std::ffi::{c_long, c_void};
use std::io::{Read, Write};
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::net::UnixStream;
use std::ptr::{null, null_mut};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

/// kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, as ScreenCaptureKit delivers.
const PIXEL_420V: u32 = u32::from_be_bytes(*b"420v");

#[repr(C)]
pub struct CallBacks {
    _p: [u8; 0],
}

framework! {
    mod cf_new = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation" {
        ref kCFTypeDictionaryKeyCallBacks: CallBacks;
        ref kCFTypeDictionaryValueCallBacks: CallBacks;
        fn CFDictionaryCreate(a: *const c_void, keys: *const CFTypeRef, values: *const CFTypeRef, n: c_long, kcb: *const CallBacks, vcb: *const CallBacks) -> CFDictionaryRef;
    }
}

framework! {
    mod cv_new = "/System/Library/Frameworks/CoreVideo.framework/CoreVideo" {
        static kCVPixelBufferIOSurfacePropertiesKey: CFStringRef;
        fn CVPixelBufferCreate(a: *const c_void, w: usize, h: usize, fmt: u32, attrs: CFDictionaryRef, out: *mut CVPixelBufferRef) -> i32;
    }
}

/// What both halves share: the marker counter and the wake that tells the loop a frame is due.
struct Shared {
    counter: AtomicU32,
    wake: UnixStream,
    stop: AtomicBool,
}

impl Shared {
    fn wake(&self) {
        // A full socket buffer already holds a wake-up, so a failed write loses nothing.
        let _ = (&self.wake).write(&[1]);
    }
}

/// The loop thread's half: damage when a frame is due, and input as marker bumps.
pub struct SyntheticDesktop {
    shared: Arc<Shared>,
    wake_read: UnixStream,
    size: (u32, u32),
    motion: Motion,
    ticker: Option<JoinHandle<()>>,
    /// The first due frame reports the whole picture (all of it is new to the viewer).
    reported_whole: bool,
}

/// The encode thread's half: paints the next picture into its IOSurface and encodes it.
pub struct SyntheticFrames {
    shared: Arc<Shared>,
    surface: PixelBuffer,
    painter: Painter,
    size: (u32, u32),
    motion: Motion,
    /// Frames the bars have moved.
    moved: u64,
    picked: Option<Rect>,
    picked_times: Option<(u64, u64)>,
    encoder: VideoToolbox,
    name: String,
}

/// An IOSurface-backed NV12 pixel buffer this source owns.
struct PixelBuffer(CVPixelBufferRef);

// SAFETY: the buffer is used by one thread at a time (the session's encode thread).
unsafe impl Send for PixelBuffer {}

impl PixelBuffer {
    fn new(width: u32, height: u32) -> Res<Self> {
        cf_new::available()?;
        cv_new::available()?;
        let mut buffer: CVPixelBufferRef = null_mut();
        // SAFETY: CoreFoundation calls with the standard callbacks; both dictionaries are
        // released once the buffer is created (it keeps its own copy of the attributes).
        let status = unsafe {
            let empty = cf_new::CFDictionaryCreate(
                null(),
                null(),
                null(),
                0,
                cf_new::kCFTypeDictionaryKeyCallBacks(),
                cf_new::kCFTypeDictionaryValueCallBacks(),
            );
            if empty.is_null() {
                return Err("CFDictionaryCreate failed".into());
            }
            let key: CFTypeRef = cv_new::kCVPixelBufferIOSurfacePropertiesKey();
            let attrs = cf_new::CFDictionaryCreate(
                null(),
                &key,
                &empty,
                1,
                cf_new::kCFTypeDictionaryKeyCallBacks(),
                cf_new::kCFTypeDictionaryValueCallBacks(),
            );
            if attrs.is_null() {
                cf::CFRelease(empty);
                return Err("CFDictionaryCreate failed".into());
            }
            let status = cv_new::CVPixelBufferCreate(
                null(),
                width as usize,
                height as usize,
                PIXEL_420V,
                attrs,
                &mut buffer,
            );
            cf::CFRelease(attrs);
            cf::CFRelease(empty);
            status
        };
        if status != 0 || buffer.is_null() {
            return Err(
                format!("CVPixelBufferCreate {width}x{height} 420v failed: {status}").into()
            );
        }
        Ok(Self(buffer))
    }

    /// Paints one picture (`Painter::paint`) with the buffer locked for writing.
    fn paint(&mut self, painter: &Painter, size: (u32, u32), counter: u32, phase: u32) -> Res<()> {
        let buffer = self.0;
        // SAFETY: our own pixel buffer, locked for the writes and unlocked before return;
        // the plane slices cover rows x bytes-per-row of each plane and end with the lock.
        unsafe {
            if cv::CVPixelBufferLockBaseAddress(buffer, 0) != 0 {
                return Err("CVPixelBufferLockBaseAddress failed".into());
            }
            let result = match (plane(buffer, 0), plane(buffer, 1)) {
                (Some((y, y_stride)), Some((uv, uv_stride))) => {
                    painter.paint(
                        &mut Nv12 {
                            y,
                            y_stride,
                            uv,
                            uv_stride,
                            width: size.0 as usize,
                            height: size.1 as usize,
                        },
                        counter,
                        phase,
                    );
                    Ok(())
                }
                _ => Err("the synthetic pixel buffer has no planes".into()),
            };
            cv::CVPixelBufferUnlockBaseAddress(buffer, 0);
            result
        }
    }

    fn io_surface(&self) -> Option<*mut c_void> {
        // SAFETY: a live pixel buffer.
        let surface = unsafe { cv::CVPixelBufferGetIOSurface(self.0) };
        (!surface.is_null()).then_some(surface)
    }

    /// The marker read back from the luma plane (tests).
    #[cfg(test)]
    fn marker(&self) -> Option<u16> {
        let buffer = self.0;
        // SAFETY: as in `paint`, read-only.
        unsafe {
            cv::CVPixelBufferLockBaseAddress(buffer, 1);
            let base = cv::CVPixelBufferGetBaseAddressOfPlane(buffer, 0);
            let stride = cv::CVPixelBufferGetBytesPerRowOfPlane(buffer, 0);
            let rows = cv::CVPixelBufferGetHeightOfPlane(buffer, 0);
            let read = crate::marker::decode_luma_at(
                std::slice::from_raw_parts(base, stride * rows),
                stride,
                true,
                (0, 0),
            );
            cv::CVPixelBufferUnlockBaseAddress(buffer, 1);
            read
        }
    }
}

/// One plane of a locked pixel buffer and its bytes per row.
///
/// # Safety
/// `buffer` is locked for writing for as long as the slice is used, and the two planes of one
/// buffer never overlap.
unsafe fn plane<'a>(buffer: CVPixelBufferRef, index: usize) -> Option<(&'a mut [u8], usize)> {
    // SAFETY: getters on a live, locked pixel buffer.
    let (base, stride, rows) = unsafe {
        (
            cv::CVPixelBufferGetBaseAddressOfPlane(buffer, index).cast_mut(),
            cv::CVPixelBufferGetBytesPerRowOfPlane(buffer, index),
            cv::CVPixelBufferGetHeightOfPlane(buffer, index),
        )
    };
    let len = stride.checked_mul(rows)?;
    // SAFETY: the plane's rows x bytes-per-row, while the caller holds the lock.
    (!base.is_null()).then(|| (unsafe { std::slice::from_raw_parts_mut(base, len) }, stride))
}

impl Drop for PixelBuffer {
    fn drop(&mut self) {
        // SAFETY: the reference CVPixelBufferCreate gave this value.
        unsafe { cf::CFRelease(self.0 as CFTypeRef) }
    }
}

/// Opens both halves of a synthetic desktop for one session.
pub fn open(cfg: &SessionCfg, source: Synthetic, ltr: bool) -> Res<Halves> {
    if cfg.codec != "videotoolbox" {
        return Err(format!(
            "codec {} is not available on a macOS host (it encodes surfaces with videotoolbox)",
            cfg.codec
        )
        .into());
    }
    super::sys::load()?;
    let (width, height) = synthetic::fit(source.size, cfg.max_width);
    let surface = PixelBuffer::new(width, height)?;
    let fps = super::encoder_fps(width, height, cfg.max_fps.max(1));
    let encoder =
        VideoToolbox::with_ltr(width, height, fps, cfg.start_kbps, cfg.profile == "baseline", ltr)?;
    let name = format!("{} from synthetic iosurface", cmux_encode::H264Encoder::name(&encoder));
    let (wake_read, wake) = UnixStream::pair()?;
    wake_read.set_nonblocking(true)?;
    wake.set_nonblocking(true)?;
    let shared =
        Arc::new(Shared { counter: AtomicU32::new(0), wake, stop: AtomicBool::new(false) });
    // The first picture goes out at once.
    shared.wake();
    // Moving pictures are due every frame interval; a still one only when input bumps it.
    let ticker = (source.motion != Motion::Still).then(|| {
        let shared = shared.clone();
        let interval = Duration::from_nanos(1_000_000_000 / u64::from(fps.max(1)));
        std::thread::Builder::new().name("cmux-rd-synthetic".into()).spawn(move || {
            let mut deadline = Instant::now() + interval;
            while !shared.stop.load(Ordering::Relaxed) {
                synthetic::sleep_until(deadline);
                shared.wake();
                deadline = synthetic::next_tick(deadline, interval, Instant::now());
            }
        })
    });
    let ticker = ticker.transpose()?;
    eprintln!(
        "cmux-rd host: synthetic source {width}x{height}, {fps} fps, {:?}, {:?}",
        source.motion, source.scene
    );
    let frames = SyntheticFrames {
        shared: shared.clone(),
        surface,
        painter: Painter::new(source.scene, width as usize, height as usize),
        size: (width, height),
        motion: source.motion,
        moved: 0,
        picked: None,
        picked_times: None,
        encoder,
        name,
    };
    let desktop = SyntheticDesktop {
        shared,
        wake_read,
        size: (width, height),
        motion: source.motion,
        ticker,
        reported_whole: false,
    };
    Ok((Box::new(desktop), Box::new(frames)))
}

impl SyntheticDesktop {
    /// What changes in a due frame: the whole picture first and whenever it moves, else the
    /// marker row.
    fn damage(&mut self) -> Rect {
        let (width, height) = self.size;
        if !std::mem::replace(&mut self.reported_whole, true) {
            return Rect { x: 0, y: 0, width, height };
        }
        match self.motion {
            Motion::Still => Rect {
                x: 0,
                y: 0,
                width: crate::marker::CELLS as u32 * crate::marker::CELL,
                height: crate::marker::CELL,
            },
            Motion::Moving | Motion::Tick => Rect { x: 0, y: 0, width, height },
        }
    }
}

impl Desktop for SyntheticDesktop {
    fn size(&self) -> (u32, u32) {
        self.size
    }

    fn fd(&self) -> RawFd {
        self.wake_read.as_raw_fd()
    }

    fn drain(&mut self, out: &mut Vec<Rect>) -> Res<()> {
        let mut scratch = [0u8; 256];
        let mut due = false;
        while let Ok(1..) = (&self.wake_read).read(&mut scratch) {
            due = true;
        }
        if due {
            out.push(self.damage());
        }
        Ok(())
    }

    /// A press bumps the marker and makes a frame due at once; nothing reaches the system.
    fn inject(&mut self, event: &InputEvent) -> Res<()> {
        if synthetic::bumps(event) {
            self.shared.counter.fetch_add(1, Ordering::Relaxed);
            self.shared.wake();
        }
        Ok(())
    }

    fn release_all(&mut self) -> Res<()> {
        Ok(())
    }
}

impl Drop for SyntheticDesktop {
    fn drop(&mut self) {
        self.shared.stop.store(true, Ordering::Relaxed);
        if let Some(ticker) = self.ticker.take() {
            let _ = ticker.join();
        }
    }
}

impl FrameSource for SyntheticFrames {
    /// Paints the picture now: the counter as of this moment, the bars one step on.
    fn capture(&mut self, damage: Rect) -> Res<()> {
        let counter = match self.motion {
            Motion::Tick => self.shared.counter.fetch_add(1, Ordering::Relaxed).wrapping_add(1),
            Motion::Moving | Motion::Still => self.shared.counter.load(Ordering::Relaxed),
        };
        if self.motion != Motion::Still {
            self.moved += 1;
        }
        self.surface.paint(&self.painter, self.size, counter, synthetic::phase(self.moved))?;
        // The picture exists the moment it is painted: shown and handed over at once.
        let now = crate::clock::now_ns() / 1000;
        self.picked = Some(damage);
        self.picked_times = Some((now, now));
        Ok(())
    }

    fn picked_times(&self) -> Option<(u64, u64)> {
        self.picked_times
    }

    fn encode(&mut self, force_idr: bool, pts_us: i64, out: &mut Vec<u8>) -> Res<bool> {
        let (width, height) = self.size;
        let damage = self.picked.take().ok_or("encode before capture")?;
        let surface = self.surface.io_surface().ok_or("the synthetic buffer has no IOSurface")?;
        // SAFETY: `self.surface` owns the IOSurface and outlives encode_surface, which is
        // synchronous.
        let picture = unsafe {
            SurfaceFrame::new(surface, SurfaceFormat::Nv12, width, height, ColorTag::Srgb)
        };
        let hint =
            SurfaceRect { x: damage.x, y: damage.y, width: damage.width, height: damage.height };
        self.encoder.encode_surface(&picture, hint, force_idr, pts_us, out)
    }

    fn set_bitrate(&mut self, kbps: u32) {
        SurfaceEncoder::set_bitrate(&mut self.encoder, kbps);
    }

    fn set_profile(&mut self, profile: EncodeProfile, refine: bool) {
        self.encoder.set_ultra(profile.is_ultra());
        self.encoder.set_refine(refine);
    }

    fn applies_profile(&self) -> bool {
        true
    }

    fn set_changed_pixels(&mut self, pixels: u64) {
        self.encoder.set_changed_pixels(pixels);
    }

    fn kbps(&self) -> u32 {
        SurfaceEncoder::kbps(&self.encoder)
    }

    fn encoder_name(&self) -> String {
        self.name.clone()
    }

    /// The resolution ladder's picture, scaled on the GPU and capped by its QP ceiling the way
    /// the captured display's is (`MacFrames::set_picture`), so a synthetic run measures it.
    fn set_picture(&mut self, picture: Option<cmux_rd_core::resolution::Picture>) {
        self.encoder.set_picture_size(picture.map(|p| (p.width, p.height)));
        self.encoder.set_max_qp(picture.and_then(|p| p.max_qp));
    }

    fn idr_cause(&self) -> Option<&'static str> {
        cmux_encode::H264Encoder::idr_cause(&self.encoder)
    }
}

#[cfg(test)]
#[path = "synthetic_tests.rs"]
mod tests;
