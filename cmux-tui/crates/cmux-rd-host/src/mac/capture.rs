//! Display capture with ScreenCaptureKit. The stream delivers a frame only when the display
//! changed (an idle frame carries no pixels and is ignored); each complete frame replaces
//! the newest pixel buffer, adds its dirty rectangles, and writes one byte to a pipe whose
//! read end wakes the session's poll(2) loop. Nothing is copied: the encoder reads the
//! pixel buffer's IOSurface.

use crate::fdwait::wait_readable;
use crate::Res;
use cmux_rd_core::flow::Rect;
use core_graphics::display::CGDisplay;
use screencapturekit::cm::SCFrameStatus;
use screencapturekit::prelude::*;
use screencapturekit::CVPixelBuffer;
use std::os::fd::RawFd;
use std::sync::{Arc, Mutex};

/// The largest picture the viewer's H.264 level (5.2) decodes at 60 fps. A larger display is
/// scaled down on the GPU by ScreenCaptureKit, keeping its aspect ratio.
const MAX_SIZE: (f64, f64) = (3840.0, 2160.0);
/// Frames ScreenCaptureKit may have in flight. The session holds one (the newest, so a
/// recovery keyframe can be encoded with no new capture) and encodes another.
const QUEUE_DEPTH: u32 = 4;

/// The streamed display in global points (CGEvent coordinates).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Bounds {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(Default)]
struct Shared {
    newest: Option<CVPixelBuffer>,
    dirty: Vec<Rect>,
}

/// One end of the wake pipe, closed on drop.
struct Fd(RawFd);

impl Fd {
    /// One byte into the pipe; a full pipe already holds a wake-up, so nothing is lost.
    fn wake(&self) {
        // SAFETY: writing one byte from a local to the pipe end this value owns.
        unsafe { libc::write(self.0, [1u8].as_ptr().cast(), 1) };
    }
}

impl Drop for Fd {
    fn drop(&mut self) {
        // SAFETY: closing a descriptor this value owns, once.
        unsafe { libc::close(self.0) };
    }
}

pub struct Capture {
    stream: SCStream,
    shared: Arc<Mutex<Shared>>,
    wake_read: Fd,
    size: (u32, u32),
    bounds: Bounds,
}

/// The display's size in pixels fitted into [`MAX_SIZE`] and `max_width`, keeping its aspect;
/// even, as 4:2:0 needs.
fn fit(width: u32, height: u32, max_width: Option<u32>) -> (u32, u32) {
    let limit = max_width.map_or(MAX_SIZE.0, |w| f64::from(w).min(MAX_SIZE.0));
    let scale = (limit / f64::from(width)).min(MAX_SIZE.1 / f64::from(height)).min(1.0);
    let even = |value: f64| (value.round() as u32) & !1;
    (even(f64::from(width) * scale), even(f64::from(height) * scale))
}

/// Dirty rectangles arrive in display points; the stream is in pixels.
fn to_pixels(rect: (f64, f64, f64, f64), scale: f64, size: (u32, u32)) -> Option<Rect> {
    let (x0, y0) = ((rect.0 * scale).floor().max(0.0), (rect.1 * scale).floor().max(0.0));
    let x1 = ((rect.0 + rect.2) * scale).ceil().min(f64::from(size.0));
    let y1 = ((rect.1 + rect.3) * scale).ceil().min(f64::from(size.1));
    (x1 > x0 && y1 > y0).then_some(Rect {
        x: x0 as u32,
        y: y0 as u32,
        width: (x1 - x0) as u32,
        height: (y1 - y0) as u32,
    })
}

fn wake_pipe() -> Res<(Fd, Fd)> {
    let mut fds = [0; 2];
    // SAFETY: pipe(2) fills the two-element array we own.
    if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    let (read, write) = (Fd(fds[0]), Fd(fds[1]));
    for fd in fds {
        // SAFETY: fcntl on descriptors we just created.
        unsafe {
            libc::fcntl(fd, libc::F_SETFL, libc::fcntl(fd, libc::F_GETFL) | libc::O_NONBLOCK);
            libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC);
        }
    }
    Ok((read, write))
}

/// `main` (the menu bar display) or a display's index counted left to right.
fn pick(displays: &[SCDisplay], which: &str) -> Res<SCDisplay> {
    if which == "main" {
        let main = CGDisplay::main().id;
        return displays
            .iter()
            .find(|d| d.display_id() == main)
            .or(displays.first())
            .cloned()
            .ok_or_else(|| "no display to capture (is Screen Recording allowed?)".into());
    }
    let index: usize =
        which.parse().map_err(|_| format!("--display {which}: use main or an index"))?;
    displays.get(index).cloned().ok_or_else(|| format!("no display {index}").into())
}

impl Capture {
    pub fn start(which: &str, fps: u32, max_width: Option<u32>) -> Res<Self> {
        let content = SCShareableContent::get()
            .map_err(|e| format!("screen capture is not allowed or failed: {e:?}"))?;
        let mut displays = content.displays();
        displays.sort_by(|a, b| a.frame().origin.x.total_cmp(&b.frame().origin.x));
        let display = pick(&displays, which)?;
        let frame = display.frame();
        let bounds = Bounds {
            x: frame.origin.x,
            y: frame.origin.y,
            width: frame.size.width,
            height: frame.size.height,
        };
        let native = match CGDisplay::new(display.display_id()).display_mode() {
            Some(mode) => (mode.pixel_width() as u32, mode.pixel_height() as u32),
            None => (display.width(), display.height()),
        };
        let size = fit(native.0, native.1, max_width);
        let scale = f64::from(size.0) / bounds.width.max(1.0);
        let filter = SCContentFilter::create()
            .with_display(&display)
            .with_excluding_windows(&[])
            .build()
            .map_err(|e| format!("capture filter: {e:?}"))?;
        let configuration = SCStreamConfiguration::new()
            .with_width(size.0)
            .with_height(size.1)
            .with_fps(fps.max(1))
            .with_pixel_format(PixelFormat::YCbCr_420v)
            .with_queue_depth(QUEUE_DEPTH)
            .with_shows_cursor(true)
            .with_color_space_name("kCGColorSpaceSRGB")
            .map_err(|e| format!("capture configuration: {e:?}"))?;
        let (wake_read, wake_write) = wake_pipe()?;
        let shared = Arc::new(Mutex::new(Shared::default()));
        let mut stream =
            SCStream::new(&filter, &configuration).map_err(|e| format!("capture stream: {e:?}"))?;
        let sink = shared.clone();
        stream
            .add_output_handler(
                move |sample: CMSampleBuffer, kind: SCStreamOutputType| {
                    if kind != SCStreamOutputType::Screen
                        || sample.frame_status() != Some(SCFrameStatus::Complete)
                    {
                        return;
                    }
                    let Some(buffer) = sample.pixel_buffer() else { return };
                    let dirty = sample.dirty_rects().unwrap_or_default();
                    {
                        let mut shared = sink.lock().unwrap_or_else(|p| p.into_inner());
                        shared.newest = Some(buffer);
                        let rects = dirty.iter().filter_map(|r| {
                            to_pixels(
                                (r.origin.x, r.origin.y, r.size.width, r.size.height),
                                scale,
                                size,
                            )
                        });
                        let before = shared.dirty.len();
                        shared.dirty.extend(rects);
                        // A complete frame with no dirty rectangles still changed something.
                        if shared.dirty.len() == before {
                            shared.dirty.push(Rect { x: 0, y: 0, width: size.0, height: size.1 });
                        }
                    }
                    // A method call, so the closure owns the whole `Fd` (a field access would
                    // capture only the number and close the pipe when `start` returns).
                    wake_write.wake();
                },
                SCStreamOutputType::Screen,
            )
            .map_err(|e| format!("capture output handler: {e:?}"))?;
        stream.start_capture().map_err(|e| format!("capture did not start: {e:?}"))?;
        eprintln!(
            "cmux-rd host: capturing display {} ({}x{} px, {}x{} pt at {},{}), {fps} fps",
            display.display_id(),
            size.0,
            size.1,
            bounds.width,
            bounds.height,
            bounds.x,
            bounds.y
        );
        Ok(Self { stream, shared, wake_read, size, bounds })
    }

    pub fn size(&self) -> (u32, u32) {
        self.size
    }

    pub fn bounds(&self) -> Bounds {
        self.bounds
    }

    pub fn fd(&self) -> RawFd {
        self.wake_read.0
    }

    fn clear_wakes(&self) {
        let mut scratch = [0u8; 256];
        // SAFETY: reading into a local buffer from our non-blocking read end.
        while unsafe { libc::read(self.wake_read.0, scratch.as_mut_ptr().cast(), scratch.len()) }
            > 0
        {}
    }

    /// Blocks on the wake pipe until the display's first frame arrives.
    pub fn wait_first_frame(&self, timeout_ns: u64) -> Res<()> {
        let deadline = crate::clock::now_ns() + timeout_ns;
        loop {
            if self.shared.lock().unwrap_or_else(|p| p.into_inner()).newest.is_some() {
                return Ok(());
            }
            let left = deadline.saturating_sub(crate::clock::now_ns());
            if left == 0 {
                return Err(
                    "no frame from the display within 3 s (is Screen Recording allowed?)".into()
                );
            }
            wait_readable(&[self.wake_read.0], Some(left))?;
            self.clear_wakes();
        }
    }

    /// Damage since the last call.
    pub fn drain(&self, out: &mut Vec<Rect>) {
        self.clear_wakes();
        out.append(&mut self.shared.lock().unwrap_or_else(|p| p.into_inner()).dirty);
    }

    /// The newest complete frame (kept, so a recovery keyframe needs no new capture).
    pub fn newest(&self) -> Option<CVPixelBuffer> {
        self.shared.lock().unwrap_or_else(|p| p.into_inner()).newest.clone()
    }
}

impl Drop for Capture {
    fn drop(&mut self) {
        let _ = self.stream.stop_capture();
    }
}
