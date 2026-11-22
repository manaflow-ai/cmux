//! Display capture with ScreenCaptureKit, bound at run time (`super::sys`). The stream delivers
//! a frame only when the display changed (an idle frame carries no pixels and is ignored);
//! each complete frame replaces the newest pixel buffer, adds its dirty rectangles, and writes
//! one byte to a pipe whose read end wakes the session's poll(2) loop. Nothing is copied: the
//! encoder reads the pixel buffer's IOSurface.

use super::sys::{
    self, block, cf, cg, cm, cv, msg, objc, sck, sel, AutoreleasePool, Block, CGRect,
    CMSampleBufferRef, CMTime, Class, Id, Retained, Sel, CF_NUMBER_SINT64, CM_TIME_VALID,
};
use crate::fdwait::wait_readable;
use crate::Res;
use cmux_rd_core::flow::Rect;
use std::ffi::{c_long, c_void, CStr};
use std::os::fd::RawFd;
use std::ptr::null_mut;
use std::sync::mpsc::{sync_channel, SyncSender};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

#[cfg(feature = "bench")]
const PRESENTED_QUEUE_CAPACITY: usize = 4096;

/// The largest picture the viewer's H.264 level (5.2) decodes at 60 fps. A larger display is
/// scaled down on the GPU by ScreenCaptureKit, keeping its aspect ratio.
const MAX_SIZE: (f64, f64) = (3840.0, 2160.0);
/// Frames ScreenCaptureKit may have in flight. The session holds one (the newest, so a
/// recovery keyframe can be encoded with no new capture) and encodes another.
const QUEUE_DEPTH: c_long = 4;
/// The frame rate when the display's refresh rate cannot be read.
pub const FALLBACK_FPS: u32 = 60;
/// The highest refresh rate taken from a display mode (the viewer's settings allow up to 240).
const MAX_REFRESH_FPS: u32 = 240;
/// kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange.
const PIXEL_420V: u32 = u32::from_be_bytes(*b"420v");
/// SCStreamOutputTypeScreen and SCFrameStatusComplete.
const OUTPUT_SCREEN: c_long = 0;
const FRAME_COMPLETE: i64 = 0;
/// How long a session end waits for ScreenCaptureKit to confirm the stop.
const STOP_TIMEOUT: Duration = Duration::from_secs(2);
/// How long ScreenCaptureKit may take to answer (it asks the window server).
const ANSWER_TIMEOUT: Duration = Duration::from_secs(10);
/// SCStreamErrorUserStopped: the person stopped this capture from the macOS menu bar's
/// screen-recording item. That is their Stop Sharing, so the session ends and is never restarted.
const STOPPED_BY_PERSON: c_long = -3817;
/// A stream ScreenCaptureKit stops for any other reason (another app's recording, a display
/// change or sleep) is restarted, at most this many times within [`RESTART_WINDOW`]; past that
/// the session ends with the reason instead of leaving the viewer on a frozen or black picture.
const MAX_RESTARTS: usize = 3;
const RESTART_WINDOW: Duration = Duration::from_secs(30);
/// How often, and how far apart, an exclusion update asks again for a window ScreenCaptureKit does
/// not list yet (the app sends a window's id as it first shows).
const MISSING_WINDOW_RETRIES: u32 = 8;
const MISSING_WINDOW_RETRY: Duration = Duration::from_millis(250);

/// The streamed display in global points (CGEvent coordinates).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Bounds {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

/// A captured frame: a retained CVPixelBuffer.
#[derive(Clone)]
pub struct PixelBuffer(Retained);

impl PixelBuffer {
    /// Read the observer's marker without copying a captured image. The lock is
    /// released on every return, including an invalid marker or read failure.
    #[cfg(feature = "bench")]
    pub fn marker(&self, origin: (usize, usize), cell: usize) -> Option<u16> {
        struct Unlock(sys::CVPixelBufferRef);
        impl Drop for Unlock {
            fn drop(&mut self) {
                // SAFETY: this guard owns a successful read-only lock.
                unsafe {
                    cv::CVPixelBufferUnlockBaseAddress(self.0, 1);
                }
            }
        }
        let buffer = self.0.as_ptr().cast_mut();
        // SAFETY: retained NV12 pixel buffer from our ScreenCaptureKit stream;
        // its luma allocation stays locked for the slice's entire lifetime.
        unsafe {
            if cv::CVPixelBufferLockBaseAddress(buffer, 1) != 0 {
                return None;
            }
            let _unlock = Unlock(buffer);
            let base = cv::CVPixelBufferGetBaseAddressOfPlane(buffer, 0);
            let stride = cv::CVPixelBufferGetBytesPerRowOfPlane(buffer, 0);
            let length = stride.checked_mul(cv::CVPixelBufferGetHeightOfPlane(buffer, 0))?;
            if base.is_null() || length > isize::MAX as usize {
                return None;
            }
            crate::observe::read_marker(
                std::slice::from_raw_parts(base, length),
                stride,
                origin,
                cell,
            )
        }
    }

    #[cfg(feature = "bench")]
    pub fn marker_nonce(&self, origin: (usize, usize), cell: usize) -> Option<(u16, [u8; 16])> {
        struct Unlock(sys::CVPixelBufferRef);
        impl Drop for Unlock {
            fn drop(&mut self) {
                // SAFETY: this guard owns a successful read-only lock.
                unsafe { cv::CVPixelBufferUnlockBaseAddress(self.0, 1) };
            }
        }
        let buffer = self.0.as_ptr().cast_mut();
        // SAFETY: retained NV12 pixel buffer from our ScreenCaptureKit stream.
        unsafe {
            if cv::CVPixelBufferLockBaseAddress(buffer, 1) != 0 {
                return None;
            }
            let _unlock = Unlock(buffer);
            let base = cv::CVPixelBufferGetBaseAddressOfPlane(buffer, 0);
            let stride = cv::CVPixelBufferGetBytesPerRowOfPlane(buffer, 0);
            let length = stride.checked_mul(cv::CVPixelBufferGetHeightOfPlane(buffer, 0))?;
            if base.is_null() || length > isize::MAX as usize {
                return None;
            }
            crate::observe::read_marker_nonce(
                std::slice::from_raw_parts(base, length),
                stride,
                origin,
                cell,
            )
        }
    }

    /// Bounded luma sample for explicitly enabled, local benchmark quality evidence.
    #[cfg(feature = "bench")]
    pub fn eval_roi(&self) -> Option<Vec<u8>> {
        let buffer = self.0.as_ptr().cast_mut();
        // SAFETY: the retained ScreenCaptureKit NV12 image remains locked while copied.
        unsafe {
            if cv::CVPixelBufferLockBaseAddress(buffer, 1) != 0 {
                return None;
            }
            let base = cv::CVPixelBufferGetBaseAddressOfPlane(buffer, 0);
            let stride = cv::CVPixelBufferGetBytesPerRowOfPlane(buffer, 0);
            let length = stride.checked_mul(cv::CVPixelBufferGetHeightOfPlane(buffer, 0));
            let result = match length {
                Some(length) if !base.is_null() && length <= isize::MAX as usize => {
                    crate::eval::roi(std::slice::from_raw_parts(base, length), stride)
                }
                _ => None,
            };
            cv::CVPixelBufferUnlockBaseAddress(buffer, 1);
            result
        }
    }

    /// The buffer's IOSurface (owned by the buffer).
    pub fn io_surface(&self) -> Option<*mut c_void> {
        // SAFETY: a live CVPixelBuffer.
        let surface = unsafe { cv::CVPixelBufferGetIOSurface(self.0.as_ptr().cast_mut()) };
        (!surface.is_null()).then_some(surface)
    }
}

#[derive(Default)]
struct Shared {
    newest: Option<PixelBuffer>,
    /// The newest frame's display time and its arrival here, on the protocol clock in µs.
    newest_times: Option<(u64, u64)>,
    dirty: Vec<Rect>,
    /// ScreenCaptureKit stopped the stream (`stream:didStopWithError:`): its error code and text.
    stopped: Option<(c_long, String)>,
    #[cfg(feature = "bench")]
    presented: Option<crate::observe::PresentedSampleQueue>,
}

#[cfg(feature = "bench")]
#[derive(Clone, Copy)]
pub struct MarkerConfig {
    pub origin: (usize, usize),
    pub cell: usize,
    pub expected_nonce: Option<[u8; 16]>,
}

#[cfg(feature = "bench")]
pub struct PresentedBatch {
    pub samples: Vec<crate::observe::PresentedMarkerSample>,
    pub queue_overflow: bool,
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

/// What the output object's sample handler writes into (one per stream).
struct Sink {
    shared: Arc<Mutex<Shared>>,
    wake: Fd,
    /// Stream pixels per display point, and the stream size.
    scale: f64,
    size: (u32, u32),
    #[cfg(feature = "bench")]
    marker: Option<MarkerConfig>,
}

/// The live output objects (by address) and their sinks.
type SinkList = Mutex<Vec<(usize, Arc<Sink>)>>;

/// The live output objects and their sinks, by object address. The handler runs on the
/// capture queue with only the object pointer to go on.
fn sinks() -> &'static SinkList {
    static SINKS: OnceLock<SinkList> = OnceLock::new();
    SINKS.get_or_init(Mutex::default)
}

/// SECURITY: the windows every capture leaves out, by window id (CGWindowID, the app's
/// `NSWindow.windowNumber`): prompts only the person at this Mac may see, such as the join consent
/// ask or a revealed password. Their `NSWindow.sharingType = .none` alone does not keep them out of
/// a ScreenCaptureKit capture since macOS 15.4. The app sends the list (`serve`'s
/// `exclude_windows` line); sorted, no duplicates, no 0.
fn excluded_ids() -> &'static Mutex<Vec<u32>> {
    static IDS: OnceLock<Mutex<Vec<u32>>> = OnceLock::new();
    IDS.get_or_init(Mutex::default)
}

fn current_exclusions() -> Vec<u32> {
    excluded_ids().lock().unwrap_or_else(|p| p.into_inner()).clone()
}

/// The running streams (SCStream address, display id). Held while a capture starts or restarts
/// and while a new exclusion list is applied, so a stream made during a change still gets the
/// newest list, and a stream leaves the list (under this lock) before its capture releases it.
fn live_streams() -> &'static Mutex<Vec<(usize, u32)>> {
    static STREAMS: OnceLock<Mutex<Vec<(usize, u32)>>> = OnceLock::new();
    STREAMS.get_or_init(Mutex::default)
}

/// The ids as the list keeps them: sorted, no duplicates, no 0 (no window has it).
fn exclusion_list(ids: impl IntoIterator<Item = u32>) -> Vec<u32> {
    let mut ids: Vec<u32> = ids.into_iter().filter(|&id| id != 0).collect();
    ids.sort_unstable();
    ids.dedup();
    ids
}

/// Leaves the windows `ids` out of every capture: those that start or restart later, and the
/// running ones, whose filters are replaced on a background thread (ScreenCaptureKit is asked for
/// its window list again, which may take a moment). Returns at once. Only `serve` (the `link`
/// feature) sends it.
#[cfg_attr(not(feature = "link"), allow(dead_code))]
pub fn set_excluded_windows(ids: impl IntoIterator<Item = u32>) {
    let ids = exclusion_list(ids);
    {
        let mut current = excluded_ids().lock().unwrap_or_else(|p| p.into_inner());
        if *current == ids {
            return;
        }
        *current = ids;
    }
    spawn_apply_exclusions();
}

/// Runs [`apply_exclusions`] on its own thread. Each pass applies the newest list once it holds the
/// live streams' lock, so updates that overlap still end on the last list sent.
fn spawn_apply_exclusions() {
    let spawned =
        std::thread::Builder::new().name("cmux-rd-exclude".into()).spawn(apply_exclusions);
    if let Err(e) = spawned {
        eprintln!("cmux-rd host: could not update the excluded windows: {e}");
    }
}

/// Replaces every live stream's filter with one that leaves out the newest list. A window the app
/// just showed may not be in ScreenCaptureKit's window list yet: while one is missing, it asks again
/// a few times, [`MISSING_WINDOW_RETRY`] apart.
fn apply_exclusions() {
    for attempt in 0..=MISSING_WINDOW_RETRIES {
        if attempt > 0 {
            std::thread::sleep(MISSING_WINDOW_RETRY);
        }
        if apply_exclusions_once() {
            return;
        }
    }
    eprintln!("cmux-rd host: an excluded window is not in ScreenCaptureKit's window list");
}

/// One pass of [`apply_exclusions`]; false when an excluded window was not found (so not left out).
fn apply_exclusions_once() -> bool {
    // The running streams, each retained, so the update below runs with the list unlocked: a slow
    // ScreenCaptureKit answer never holds a capture's start, restart or end.
    let streams: Vec<(usize, u32)> = {
        let live = live_streams().lock().unwrap_or_else(|p| p.into_inner());
        live.iter()
            .map(|&(stream, display_id)| {
                // SAFETY: -[NSObject retain] on a stream still in the list (Drop takes it out under
                // this lock before releasing it); balanced by the release after its update below.
                unsafe {
                    msg::<unsafe extern "C" fn(Id, Sel) -> Id>()(stream as Id, sel(c"retain"))
                };
                (stream, display_id)
            })
            .collect()
    };
    if streams.is_empty() {
        return true;
    }
    let release_streams = |streams: &[(usize, u32)]| {
        for &(stream, _) in streams {
            sys::release(stream as Id);
        }
    };
    let excluded = current_exclusions();
    let (content, displays) = match shareable_displays() {
        Ok(found) => found,
        Err(e) => {
            eprintln!("cmux-rd host: excluded windows not updated: {e}");
            release_streams(&streams);
            return false;
        }
    };
    let _pool = AutoreleasePool::new();
    let mut all_found = true;
    for &(stream, display_id) in streams.iter() {
        let Some(&(display, _)) = displays.iter().find(|d| d.1 == display_id) else { continue };
        // SAFETY: a display and the content it came from, both retained until release_all below,
        // under the pool above.
        let (filter, found) = unsafe { display_filter(content, display, &excluded) };
        all_found &= found == excluded.len();
        if filter.is_null() {
            eprintln!("cmux-rd host: excluded windows not updated: no filter");
            continue;
        }
        let (tx, rx) = sync_channel::<StartAnswer>(1);
        let updated = block(capture_started as *const c_void, c"v@?@", tx);
        // SAFETY: -[SCStream updateContentFilter:completionHandler:] on a live stream (this thread
        // holds its own reference until release_streams below), with a block of the (NSError *)
        // handler type. A stream its capture stopped meanwhile answers with an error, which is logged.
        unsafe {
            msg::<unsafe extern "C" fn(Id, Sel, Id, *mut c_void)>()(
                stream as Id,
                sel(c"updateContentFilter:completionHandler:"),
                filter,
                updated.cast(),
            );
        }
        sys::release(filter);
        match rx.recv_timeout(ANSWER_TIMEOUT) {
            Ok(Ok(())) => eprintln!(
                "cmux-rd host: display {display_id} now leaves out {} window(s)",
                excluded.len()
            ),
            Ok(Err(e)) => eprintln!("cmux-rd host: excluded windows not updated: {e}"),
            Err(_) => eprintln!("cmux-rd host: excluded windows not updated: no answer"),
        }
    }
    release_all(content, &displays);
    release_streams(&streams);
    all_found
}

/// A filter (+1 reference, null when ScreenCaptureKit makes none) on `display` that leaves out the
/// windows of `content` whose id is in `excluded`, and how many of those windows it found.
///
/// # Safety
/// `content` is a live SCShareableContent and `display` one of its SCDisplays; an autorelease
/// pool is in place.
unsafe fn display_filter(content: Id, display: Id, excluded: &[u32]) -> (Id, usize) {
    let mut found = 0;
    let windows = sys::send_id(sys::class(c"NSMutableArray"), c"array");
    // SAFETY: -[NSArray count] and -objectAtIndex: (an index below count) on the content's
    // windows, -[SCWindow windowID] (a CGWindowID), -[NSMutableArray addObject:] with a live
    // window, and -[SCContentFilter initWithDisplay:excludingWindows:] with the caller's display.
    unsafe {
        if !excluded.is_empty() {
            let list = sys::send_id(content, c"windows");
            let count = msg::<unsafe extern "C" fn(Id, Sel) -> usize>()(list, sel(c"count"));
            for index in 0..count {
                let window = msg::<unsafe extern "C" fn(Id, Sel, usize) -> Id>()(
                    list,
                    sel(c"objectAtIndex:"),
                    index,
                );
                let id = msg::<unsafe extern "C" fn(Id, Sel) -> u32>()(window, sel(c"windowID"));
                if excluded.binary_search(&id).is_ok() {
                    found += 1;
                    msg::<unsafe extern "C" fn(Id, Sel, Id)>()(windows, sel(c"addObject:"), window);
                }
            }
        }
        let filter = msg::<unsafe extern "C" fn(Id, Sel, Id, Id) -> Id>()(
            sys::send_id(sys::class(c"SCContentFilter"), c"alloc"),
            sel(c"initWithDisplay:excludingWindows:"),
            display,
            windows,
        );
        (filter, found)
    }
}

pub struct Capture {
    stream: Id,
    /// The output was added to the stream (removed again before the stream is released).
    added: bool,
    output: Id,
    queue: sys::DispatchQueue,
    shared: Arc<Mutex<Shared>>,
    wake_read: Fd,
    size: (u32, u32),
    bounds: Bounds,
    restart: Restart,
    /// The stream is in [`live_streams`] (only a started capture is; `start` holds that lock while
    /// a failed one drops).
    registered: bool,
}

/// What a restart needs to make the same stream again, and when it last did.
struct Restart {
    display: u32,
    fps: u32,
    shows_cursor: bool,
    /// The restarts within the last [`RESTART_WINDOW`].
    at: Vec<Instant>,
}

/// Whether a stream ScreenCaptureKit stopped with `code` may restart now, given the restarts
/// `at` (kept to the last [`RESTART_WINDOW`], `now` added when it may); else why the session ends.
fn restart_allowed(code: c_long, reason: &str, at: &mut Vec<Instant>, now: Instant) -> Res<()> {
    if code == STOPPED_BY_PERSON {
        return Err("sharing was stopped from the macOS menu bar".into());
    }
    at.retain(|then| now.duration_since(*then) < RESTART_WINDOW);
    if at.len() >= MAX_RESTARTS {
        return Err(format!("the screen capture keeps stopping ({reason})").into());
    }
    at.push(now);
    Ok(())
}

/// A stream of `display` at `size`, its stops reported to `delegate` (the capture's output),
/// leaving out the windows `excluded`; and whether every one of them was found in `content`.
///
/// # Safety
/// `content` is a live SCShareableContent, `display` one of its SCDisplays and `delegate` a live
/// CmuxRdCaptureOutput; an autorelease pool is in place.
unsafe fn new_stream(
    content: Id,
    display: Id,
    excluded: &[u32],
    size: (u32, u32),
    fps: u32,
    shows_cursor: bool,
    delegate: Id,
) -> Res<(Id, bool)> {
    // SAFETY: each message is sent with its documented C signature to the object just created
    // (alloc/init pairs return +1 references released here or by the caller); `display_filter`
    // gets the caller's content, display and pool.
    unsafe {
        let (filter, found) = display_filter(content, display, excluded);
        let config = sys::send_id(sys::class(c"SCStreamConfiguration"), c"new");
        if filter.is_null() || config.is_null() {
            sys::release(filter);
            sys::release(config);
            return Err("ScreenCaptureKit did not make a filter and configuration".into());
        }
        let set_size = msg::<unsafe extern "C" fn(Id, Sel, usize)>();
        set_size(config, sel(c"setWidth:"), size.0 as usize);
        set_size(config, sel(c"setHeight:"), size.1 as usize);
        msg::<unsafe extern "C" fn(Id, Sel, CMTime)>()(
            config,
            sel(c"setMinimumFrameInterval:"),
            min_frame_interval(fps),
        );
        msg::<unsafe extern "C" fn(Id, Sel, u32)>()(config, sel(c"setPixelFormat:"), PIXEL_420V);
        msg::<unsafe extern "C" fn(Id, Sel, c_long)>()(config, sel(c"setQueueDepth:"), QUEUE_DEPTH);
        // Without the cursor when the viewer draws it from metadata (cap `cursor`): one
        // cursor on the viewer's screen, not the local one over a baked-in copy.
        msg::<unsafe extern "C" fn(Id, Sel, bool)>()(config, sel(c"setShowsCursor:"), shows_cursor);
        msg::<unsafe extern "C" fn(Id, Sel, *const c_void)>()(
            config,
            sel(c"setColorSpaceName:"),
            cg::kCGColorSpaceSRGB(),
        );
        // The delegate hears `stream:didStopWithError:`: without one a stream ScreenCaptureKit
        // stopped (another app's recording, a display change) left the viewer on a stale or
        // black picture with no error.
        let stream = msg::<unsafe extern "C" fn(Id, Sel, Id, Id, Id) -> Id>()(
            sys::send_id(sys::class(c"SCStream"), c"alloc"),
            sel(c"initWithFilter:configuration:delegate:"),
            filter,
            config,
            delegate,
        );
        sys::release(filter);
        sys::release(config);
        if stream.is_null() {
            return Err("ScreenCaptureKit did not make a stream".into());
        }
        Ok((stream, found == excluded.len()))
    }
}

/// Adds the capture's output to `stream`, its samples handled on `queue`.
fn add_output(stream: Id, output: Id, queue: sys::DispatchQueue) -> Res<()> {
    let mut error: Id = null_mut();
    // SAFETY: -[SCStream addStreamOutput:type:sampleHandlerQueue:error:] on live objects.
    let added = unsafe {
        msg::<unsafe extern "C" fn(Id, Sel, Id, c_long, sys::DispatchQueue, *mut Id) -> bool>()(
            stream,
            sel(c"addStreamOutput:type:sampleHandlerQueue:error:"),
            output,
            OUTPUT_SCREEN,
            queue,
            &raw mut error,
        )
    };
    if added {
        Ok(())
    } else {
        Err(format!("capture output handler: {}", sys::error_text(error)).into())
    }
}

/// Starts `stream` and waits (bounded) for ScreenCaptureKit's answer.
fn start_stream(stream: Id) -> Res<()> {
    let (tx, rx) = sync_channel::<StartAnswer>(1);
    let started = block(capture_started as *const c_void, c"v@?@", tx);
    // SAFETY: -[SCStream startCaptureWithCompletionHandler:] with a block of the handler's type.
    unsafe {
        msg::<unsafe extern "C" fn(Id, Sel, *mut c_void)>()(
            stream,
            sel(c"startCaptureWithCompletionHandler:"),
            started.cast(),
        );
    }
    rx.recv_timeout(ANSWER_TIMEOUT)
        .map_err(|_| "capture did not start (no answer from ScreenCaptureKit)")?
        .map_err(|e| format!("capture did not start: {e}"))?;
    Ok(())
}

// SAFETY: the stream, output and queue are Objective-C objects used through thread-safe
// messages (stop, release); the session owns the capture on one thread.
unsafe impl Send for Capture {}

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

/// The native pixel size of a display (its mode), else its point size.
fn native_size(display: u32) -> (u32, u32) {
    // SAFETY: a display id; the copied mode is released here.
    unsafe {
        let mode = cg::CGDisplayCopyDisplayMode(display);
        if mode.is_null() {
            let bounds = cg::CGDisplayBounds(display);
            return (bounds.size.width as u32, bounds.size.height as u32);
        }
        let size = (
            cg::CGDisplayModeGetPixelWidth(mode) as u32,
            cg::CGDisplayModeGetPixelHeight(mode) as u32,
        );
        cg::CGDisplayModeRelease(mode);
        size
    }
}

/// A display's refresh rate in Hz from its current mode, rounded (59.94 is 60). None when the mode
/// reads 0, as some built-in panels' modes do, or there is no mode.
fn refresh_rate(display: u32) -> Option<u32> {
    // SAFETY: a display id; the copied mode is released here.
    let hz = unsafe {
        let mode = cg::CGDisplayCopyDisplayMode(display);
        if mode.is_null() {
            return None;
        }
        let hz = cg::CGDisplayModeGetRefreshRate(mode);
        cg::CGDisplayModeRelease(mode);
        hz
    };
    hz_to_fps(hz)
}

/// ScreenCaptureKit's minimum frame interval for `fps`: 90% of the frame interval, not all of it.
/// ScreenCaptureKit drops a frame whose display time comes less than the minimum after the last
/// one it delivered. At exactly 1/fps, a cap that is a whole fraction of the refresh rate (60 fps on
/// a 120 Hz panel, the fallback when a built-in panel's mode reads 0 Hz) sits on the display's own
/// cadence (two 8.33 ms refreshes are 16.67 ms), so timestamp rounding drops frames at random and
/// that frame's change shows one refresh later. ScreenCaptureKit never delivers faster than the
/// display, and the session's frame gate still holds the cap.
fn min_frame_interval(fps: u32) -> CMTime {
    let fps = fps.clamp(1, MAX_REFRESH_FPS);
    CMTime { value: 9, timescale: (fps * 10) as i32, flags: CM_TIME_VALID, epoch: 0 }
}

/// A mode's refresh rate as a frame rate: rounded, at most [`MAX_REFRESH_FPS`], None for 0.
fn hz_to_fps(hz: f64) -> Option<u32> {
    (hz.is_finite() && hz >= 1.0).then(|| (hz.round() as u32).min(MAX_REFRESH_FPS))
}

/// The refresh rate of the display `which` names (`main`, an index or `id:<n>`, as [`Capture::start`] picks
/// it), else [`FALLBACK_FPS`] when it reads 0 or the display list is not available.
pub fn refresh_fps(which: &str) -> u32 {
    let Ok((content, displays)) = shareable_displays() else { return FALLBACK_FPS };
    let rate = pick(&displays, which).ok().and_then(|(_, id)| refresh_rate(id));
    release_all(content, &displays);
    rate.unwrap_or(FALLBACK_FPS)
}

type ContentAnswer = Result<Id, String>;

extern "C" fn shareable_content_done(
    block: *mut Block<SyncSender<ContentAnswer>>,
    content: Id,
    error: Id,
) {
    let answer = if content.is_null() {
        Err(sys::error_text(error))
    } else {
        // Retained, so it outlives the handler's autorelease pool.
        Ok(sys::send_id(content, c"retain"))
    };
    // SAFETY: the block this handler was built with (leaked, never freed).
    if let Err(late) = unsafe { &(*block).context }.send(answer) {
        // The caller gave up waiting: the retained content is nobody's.
        if let Ok(content) = late.0 {
            sys::release(content);
        }
    }
}

/// What ScreenCaptureKit can capture now, as a retained SCShareableContent the caller releases
/// (also the Computer Use screenshots, `super::cu_host`). An error when Screen Recording is not
/// allowed.
pub(super) fn shareable_content() -> Res<Id> {
    sys::load()?;
    let _pool = AutoreleasePool::new();
    let (tx, rx) = sync_channel::<ContentAnswer>(1);
    let done = block(shareable_content_done as *const c_void, c"v@?@@", tx);
    // SAFETY: +[SCShareableContent getShareableContentWithCompletionHandler:] with a block of
    // the (SCShareableContent *, NSError *) handler type.
    unsafe {
        msg::<unsafe extern "C" fn(Class, Sel, *mut c_void)>()(
            sys::class(c"SCShareableContent"),
            sel(c"getShareableContentWithCompletionHandler:"),
            done.cast(),
        );
    }
    let content = rx
        .recv_timeout(ANSWER_TIMEOUT)
        .map_err(|_| "screen capture did not answer (is Screen Recording allowed?)")?
        .map_err(|e| format!("screen capture is not allowed or failed: {e}"))?;
    Ok(content)
}

/// The displays ScreenCaptureKit offers, as (SCDisplay retained, display id), left to right.
/// Empty, or an error, when Screen Recording is not allowed.
fn shareable_displays() -> Res<(Id, Vec<(Id, u32)>)> {
    let content = shareable_content()?;
    let _pool = AutoreleasePool::new();
    let list = sys::send_id(content, c"displays");
    // SAFETY: -[NSArray count] and -objectAtIndex: on the displays array.
    let count = unsafe { msg::<unsafe extern "C" fn(Id, Sel) -> usize>()(list, sel(c"count")) };
    let mut displays = Vec::with_capacity(count);
    for index in 0..count {
        // SAFETY: an index below count.
        let display = unsafe {
            msg::<unsafe extern "C" fn(Id, Sel, usize) -> Id>()(list, sel(c"objectAtIndex:"), index)
        };
        // SAFETY: -[SCDisplay displayID] returns a CGDirectDisplayID.
        let id =
            unsafe { msg::<unsafe extern "C" fn(Id, Sel) -> u32>()(display, sel(c"displayID")) };
        displays.push((sys::send_id(display, c"retain"), id));
    }
    // SAFETY: display ids from ScreenCaptureKit.
    displays.sort_by(|a, b| unsafe {
        cg::CGDisplayBounds(a.1).origin.x.total_cmp(&cg::CGDisplayBounds(b.1).origin.x)
    });
    Ok((content, displays))
}

fn release_all(content: Id, displays: &[(Id, u32)]) {
    for (display, _) in displays {
        sys::release(*display);
    }
    sys::release(content);
}

/// Every display's streamed size, the index `which` picks, and every display's CGDirectDisplayID.
pub type Displays = (Vec<(u32, u32)>, usize, Vec<u32>);

/// Every display's streamed size (native pixels fitted to the decoder, as a session
/// captures it), left to right, the index of the display `which` picks (as [`Capture::start`]
/// picks it), and every display's CGDirectDisplayID in the same order. Only `serve` (the `link`
/// feature) asks.
#[cfg_attr(not(feature = "link"), allow(dead_code))]
pub fn displays(which: &str) -> Res<Displays> {
    let (content, displays) = shareable_displays()?;
    let ids: Vec<u32> = displays.iter().map(|d| d.1).collect();
    // SAFETY: CGMainDisplayID has no preconditions.
    let main = unsafe { cg::CGMainDisplayID() };
    let current = super::display_pick::pick_index(&ids, main, which).unwrap_or(0);
    let sizes = displays
        .iter()
        .map(|&(_, id)| {
            let native = native_size(id);
            fit(native.0, native.1, None)
        })
        .collect();
    release_all(content, &displays);
    Ok((sizes, current, ids))
}

/// `main` (the menu bar display), a display's index counted left to right, or `id:<n>`, the
/// display whose CGDirectDisplayID is n (a run's virtual display, from a screen link).
fn pick(displays: &[(Id, u32)], which: &str) -> Res<(Id, u32)> {
    let ids: Vec<u32> = displays.iter().map(|d| d.1).collect();
    // SAFETY: CGMainDisplayID has no preconditions.
    let main = unsafe { cg::CGMainDisplayID() };
    let index = super::display_pick::pick_index(&ids, main, which)?;
    Ok(displays[index])
}

/// The mach timebase (numerator, denominator: ns a tick). The Mach timebase and clock calls are
/// deprecated in favour of the `mach2` crate, which cmux-rd-host does not depend on; they are not
/// defective.
#[allow(deprecated)]
fn mach_timebase() -> (u32, u32) {
    static BASE: OnceLock<(u32, u32)> = OnceLock::new();
    *BASE.get_or_init(|| {
        let mut base = libc::mach_timebase_info { numer: 1, denom: 1 };
        // SAFETY: mach_timebase_info writes into a valid struct.
        unsafe { libc::mach_timebase_info(&mut base) };
        (base.numer, base.denom.max(1))
    })
}

/// The mach clock now (see [`mach_timebase`] for the deprecation).
#[allow(deprecated)]
fn mach_now() -> u64 {
    // SAFETY: mach_absolute_time has no preconditions.
    unsafe { libc::mach_absolute_time() }
}

/// The CoreFoundation number at `key` in `dictionary`, as an i64.
fn number(dictionary: *const c_void, key: *const c_void) -> Option<i64> {
    // SAFETY: a frame-info dictionary and one of its keys.
    let value = unsafe { cf::CFDictionaryGetValue(dictionary, key) };
    if value.is_null() {
        return None;
    }
    let mut out = 0i64;
    // SAFETY: the value is a CFNumber (ScreenCaptureKit's frame status).
    let ok = unsafe { cf::CFNumberGetValue(value, CF_NUMBER_SINT64, (&raw mut out).cast()) };
    (ok != 0).then_some(out)
}

/// `-[CmuxRdCaptureOutput stream:didOutputSampleBuffer:ofType:]`, on the capture queue.
extern "C" fn did_output(
    this: Id,
    _cmd: Sel,
    _stream: Id,
    sample: CMSampleBufferRef,
    kind: c_long,
) {
    if kind != OUTPUT_SCREEN || sample.is_null() {
        return;
    }
    let sink = {
        let sinks = sinks().lock().unwrap_or_else(|p| p.into_inner());
        sinks.iter().find(|(object, _)| *object == this as usize).map(|(_, sink)| sink.clone())
    };
    let Some(sink) = sink else { return };
    // SAFETY: the sample buffer ScreenCaptureKit handed this method; its attachments array
    // and image buffer are borrowed from it for the length of the call.
    unsafe {
        let attachments = cm::CMSampleBufferGetSampleAttachmentsArray(sample, 0);
        if attachments.is_null() || cf::CFArrayGetCount(attachments) == 0 {
            return;
        }
        let info = cf::CFArrayGetValueAtIndex(attachments, 0);
        if number(info, sck::SCStreamFrameInfoStatus()) != Some(FRAME_COMPLETE) {
            return;
        }
        let buffer = cm::CMSampleBufferGetImageBuffer(sample);
        let mut rects = Vec::new();
        let dirty = cf::CFDictionaryGetValue(info, sck::SCStreamFrameInfoDirtyRects());
        if !dirty.is_null() {
            for index in 0..cf::CFArrayGetCount(dirty) {
                let mut rect = CGRect::default();
                let item = cf::CFArrayGetValueAtIndex(dirty, index);
                if cg::CGRectMakeWithDictionaryRepresentation(item, &raw mut rect) != 0 {
                    rects.extend(to_pixels(
                        (rect.origin.x, rect.origin.y, rect.size.width, rect.size.height),
                        sink.scale,
                        sink.size,
                    ));
                }
            }
        }
        // Both clocks read together: the display time (mach absolute time: the vsync the window
        // server composited this frame for, usually still ahead when the frame arrives here)
        // moves onto the protocol clock by its distance from `mach`, ahead or behind.
        let mach = mach_now();
        let arrived = crate::clock::now_ns() / 1000;
        let shown = number(info, sck::SCStreamFrameInfoDisplayTime()).map(|display| {
            let (numer, denom) = mach_timebase();
            crate::clock::mach_to_protocol_us(arrived, mach, display as u64, numer, denom)
        });
        let frame = (!buffer.is_null()).then(|| PixelBuffer(Retained::retain(buffer.cast_const())));
        #[cfg(feature = "bench")]
        let (counter, nonce) = sink.marker.map_or((None, None), |marker| {
            frame.as_ref().map_or((None, None), |pixels| {
                if marker.expected_nonce.is_some() {
                    pixels
                        .marker_nonce(marker.origin, marker.cell)
                        .map_or((None, None), |(counter, nonce)| (Some(counter), Some(nonce)))
                } else {
                    (pixels.marker(marker.origin, marker.cell), None)
                }
            })
        });
        {
            let mut shared = sink.shared.lock().unwrap_or_else(|p| p.into_inner());
            #[cfg(feature = "bench")]
            {
                if let Some(presented) = shared.presented.as_mut() {
                    presented.push(crate::observe::PresentedMarkerSample {
                        counter,
                        nonce,
                        display_us: shown,
                        arrived_us: arrived,
                    });
                }
            }
            if let Some(frame) = frame {
                shared.newest = Some(frame);
                shared.newest_times = shown.map(|shown| (shown, arrived));
                // A complete frame with no dirty rectangles still changed something.
                if rects.is_empty() {
                    rects.push(Rect { x: 0, y: 0, width: sink.size.0, height: sink.size.1 });
                }
                shared.dirty.append(&mut rects);
            }
        }
    }
    sink.wake.wake();
}

/// `-[CmuxRdCaptureOutput stream:didStopWithError:]` (SCStreamDelegate), on a ScreenCaptureKit
/// queue: records why and wakes the session, whose next drain restarts the stream or ends it.
extern "C" fn did_stop(this: Id, _cmd: Sel, _stream: Id, error: Id) {
    let sink = {
        let sinks = sinks().lock().unwrap_or_else(|p| p.into_inner());
        sinks.iter().find(|(object, _)| *object == this as usize).map(|(_, sink)| sink.clone())
    };
    let Some(sink) = sink else { return };
    let stopped = if error.is_null() {
        (0, "no reason given".to_string())
    } else {
        // SAFETY: -[NSError code] on the error ScreenCaptureKit passed in.
        let code = unsafe { msg::<unsafe extern "C" fn(Id, Sel) -> c_long>()(error, sel(c"code")) };
        (code, sys::error_text(error))
    };
    eprintln!("cmux-rd host: the screen capture stopped ({}: {})", stopped.0, stopped.1);
    sink.shared.lock().unwrap_or_else(|p| p.into_inner()).stopped = Some(stopped);
    sink.wake.wake();
}

/// The output class, registered once: an NSObject that conforms to SCStreamOutput and, for the
/// stream's stop, SCStreamDelegate.
fn output_class() -> Res<Class> {
    static CLASS: OnceLock<Result<usize, String>> = OnceLock::new();
    let class = CLASS.get_or_init(|| {
        // SAFETY: registers a new NSObject subclass with one method, once per process.
        unsafe {
            let class = objc::objc_allocateClassPair(
                sys::class(c"NSObject"),
                c"CmuxRdCaptureOutput".as_ptr(),
                0,
            );
            if class.is_null() {
                return Err("could not create the capture output class".to_string());
            }
            let protocol = objc::objc_getProtocol(c"SCStreamOutput".as_ptr());
            if !protocol.is_null() {
                objc::class_addProtocol(class, protocol);
            }
            let delegate = objc::objc_getProtocol(c"SCStreamDelegate".as_ptr());
            if !delegate.is_null() {
                objc::class_addProtocol(class, delegate);
            }
            let stop_types: &CStr = c"v@:@@";
            objc::class_addMethod(
                class,
                sel(c"stream:didStopWithError:"),
                did_stop as *const c_void,
                stop_types.as_ptr(),
            );
            let types: &CStr = c"v@:@^vq";
            objc::class_addMethod(
                class,
                sel(c"stream:didOutputSampleBuffer:ofType:"),
                did_output as *const c_void,
                types.as_ptr(),
            );
            objc::objc_registerClassPair(class);
            Ok(class as usize)
        }
    });
    class.clone().map(|c| c as Class).map_err(Into::into)
}

type StartAnswer = Result<(), String>;

extern "C" fn capture_started(block: *mut Block<SyncSender<StartAnswer>>, error: Id) {
    let answer = if error.is_null() { Ok(()) } else { Err(sys::error_text(error)) };
    // SAFETY: the block this handler was built with (leaked, never freed).
    let _ = unsafe { &(*block).context }.send(answer);
}

extern "C" fn capture_stopped(block: *mut Block<SyncSender<()>>, _error: Id) {
    // SAFETY: the block this handler was built with (leaked, never freed).
    let _ = unsafe { &(*block).context }.send(());
}

impl Capture {
    /// A capture that draws the cursor, for the bench's observer (`observe.rs`, its one caller).
    #[cfg(feature = "bench")]
    pub fn start(which: &str, fps: u32, max_width: Option<u32>) -> Res<Self> {
        Self::start_with_marker(which, fps, max_width, true, None)
    }

    /// A session's capture: `shows_cursor` false leaves the cursor out of the pictures (the
    /// viewer draws it from cursor metadata, cap `cursor`).
    pub fn start_for_session(
        which: &str,
        fps: u32,
        max_width: Option<u32>,
        shows_cursor: bool,
    ) -> Res<Self> {
        Self::start_with_marker(which, fps, max_width, shows_cursor, None)
    }

    #[cfg(feature = "bench")]
    pub fn start_observing(
        which: &str,
        fps: u32,
        max_width: Option<u32>,
        marker: MarkerConfig,
    ) -> Res<Self> {
        Self::start_with_marker(which, fps, max_width, true, Some(marker))
    }

    fn start_with_marker(
        which: &str,
        fps: u32,
        max_width: Option<u32>,
        shows_cursor: bool,
        #[cfg(feature = "bench")] marker: Option<MarkerConfig>,
        #[cfg(not(feature = "bench"))] marker: Option<()>,
    ) -> Res<Self> {
        // Held from reading the exclusion list until the stream is in the live list: a change sent
        // meanwhile is applied to this stream once it is there.
        let mut streams = live_streams().lock().unwrap_or_else(|p| p.into_inner());
        let excluded = current_exclusions();
        let (content, displays) = shareable_displays()?;
        let picked = pick(&displays, which);
        let result = picked.and_then(|(display, id)| {
            Self::stream(content, display, id, fps, max_width, shows_cursor, &excluded, marker)
        });
        release_all(content, &displays);
        let (mut capture, all_found) = result?;
        streams.push((capture.stream as usize, capture.restart.display));
        capture.registered = true;
        drop(streams);
        if !all_found {
            // A window the app just showed is not listed yet: ask again until it is.
            spawn_apply_exclusions();
        }
        Ok(capture)
    }

    #[allow(clippy::too_many_arguments)]
    fn stream(
        content: Id,
        display: Id,
        id: u32,
        fps: u32,
        max_width: Option<u32>,
        shows_cursor: bool,
        excluded: &[u32],
        #[cfg(feature = "bench")] marker: Option<MarkerConfig>,
        #[cfg(not(feature = "bench"))] marker: Option<()>,
    ) -> Res<(Self, bool)> {
        #[cfg(not(feature = "bench"))]
        let _ = marker;
        let _pool = AutoreleasePool::new();
        // SAFETY: a display id from ScreenCaptureKit.
        let frame = unsafe { cg::CGDisplayBounds(id) };
        let bounds = Bounds {
            x: frame.origin.x,
            y: frame.origin.y,
            width: frame.size.width,
            height: frame.size.height,
        };
        let native = native_size(id);
        let size = fit(native.0, native.1, max_width);
        let scale = f64::from(size.0) / bounds.width.max(1.0);
        // SAFETY: each message below is sent with its documented C signature to the object
        // just created (alloc/init pairs return +1 references this capture releases); `content`
        // and `display` are retained by `start_with_marker` for this call, under the pool above.
        unsafe {
            // The pipe, the output and its queue first: every later error path releases them.
            let (wake_read, wake_write) = wake_pipe()?;
            let class = output_class()?;
            let output = sys::send_id(sys::send_id(class, c"alloc"), c"init");
            let queue = sys::system::dispatch_queue_create(
                c"com.cmuxterm.rd.capture".as_ptr(),
                std::ptr::null(),
            );
            let made = new_stream(content, display, excluded, size, fps, shows_cursor, output);
            let (stream, all_found) = match made {
                Ok(made) => made,
                Err(e) => {
                    sys::release(output);
                    sys::system::dispatch_release(queue);
                    return Err(e);
                }
            };
            let shared = Arc::new(Mutex::new(Shared {
                #[cfg(feature = "bench")]
                presented: marker.map(|_| {
                    crate::observe::PresentedSampleQueue::with_capacity(PRESENTED_QUEUE_CAPACITY)
                }),
                ..Shared::default()
            }));
            let sink = Arc::new(Sink {
                shared: shared.clone(),
                wake: wake_write,
                scale,
                size,
                #[cfg(feature = "bench")]
                marker,
            });
            sinks().lock().unwrap_or_else(|p| p.into_inner()).push((output as usize, sink));
            let added = add_output(stream, output, queue);
            let restart = Restart { display: id, fps, shows_cursor, at: Vec::new() };
            let capture = Self {
                stream,
                output,
                queue,
                shared,
                wake_read,
                size,
                bounds,
                added: added.is_ok(),
                restart,
                registered: false,
            };
            added?;
            start_stream(stream)?;
            eprintln!(
                "cmux-rd host: capturing display {id} ({}x{} px, {}x{} pt at {},{}), {fps} fps, leaving out {} window(s)",
                size.0, size.1, bounds.width, bounds.height, bounds.x, bounds.y, excluded.len()
            );
            Ok((capture, all_found))
        }
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

    /// After ScreenCaptureKit stopped the stream: the same stream again, or the reason the
    /// session ends. A stop the person made from the macOS menu bar ends it (their Stop
    /// Sharing); any other stop restarts, at most [`MAX_RESTARTS`] times in [`RESTART_WINDOW`].
    pub fn recover(&mut self) -> Res<()> {
        let stopped = self.shared.lock().unwrap_or_else(|p| p.into_inner()).stopped.take();
        let Some((code, reason)) = stopped else { return Ok(()) };
        restart_allowed(code, &reason, &mut self.restart.at, Instant::now())?;
        self.restart_stream().map_err(|e| {
            format!("the screen capture stopped ({reason}) and did not restart: {e}").into()
        })
    }

    /// Replaces the stopped stream with a new one of the same display, size and rate, with the
    /// same output, queue and wake pipe: the session and the encode thread keep their handles.
    fn restart_stream(&mut self) -> Res<()> {
        let _pool = AutoreleasePool::new();
        // As in `start_with_marker`: held from reading the exclusion list until the new stream
        // replaces the old one in the live list, so a change sent meanwhile reaches it.
        let mut streams = live_streams().lock().unwrap_or_else(|p| p.into_inner());
        let excluded = current_exclusions();
        let (content, displays) = shareable_displays()?;
        let wanted = self.restart.display;
        let made = displays
            .iter()
            .find(|d| d.1 == wanted)
            .map(|d| d.0)
            .ok_or_else(|| format!("display {wanted} is no longer there").into())
            .and_then(|display| {
                // SAFETY: a display ScreenCaptureKit just listed and its content (both retained
                // until release_all below), this capture's own output, under the pool above.
                unsafe {
                    new_stream(
                        content,
                        display,
                        &excluded,
                        self.size,
                        self.restart.fps,
                        self.restart.shows_cursor,
                        self.output,
                    )
                }
            });
        release_all(content, &displays);
        let (stream, all_found) = made?;
        // The new stream takes the old one's place in the live list before the old is released.
        if self.registered {
            if let Some(entry) = streams.iter_mut().find(|e| e.0 == self.stream as usize) {
                entry.0 = stream as usize;
            }
        }
        // The old stream already stopped: its output leaves it before it is released.
        if self.added {
            let mut error: Id = null_mut();
            // SAFETY: -[SCStream removeStreamOutput:type:error:] on this capture's own stream.
            unsafe {
                msg::<unsafe extern "C" fn(Id, Sel, Id, c_long, *mut Id) -> bool>()(
                    self.stream,
                    sel(c"removeStreamOutput:type:error:"),
                    self.output,
                    OUTPUT_SCREEN,
                    &raw mut error,
                );
            }
        }
        sys::release(self.stream);
        self.stream = stream;
        self.added = false;
        add_output(stream, self.output, self.queue)?;
        self.added = true;
        start_stream(stream)?;
        drop(streams);
        if !all_found {
            spawn_apply_exclusions();
        }
        eprintln!(
            "cmux-rd host: the screen capture restarted, leaving out {} window(s)",
            excluded.len()
        );
        Ok(())
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

    /// The newest complete frame (kept, so a recovery keyframe needs no new capture), with its
    /// display and arrival times when ScreenCaptureKit gave a display time.
    #[cfg(feature = "bench")]
    pub fn newest(&self) -> Option<(PixelBuffer, Option<(u64, u64)>)> {
        self.frames().newest()
    }

    /// A reader of the newest frame for the session's encode thread.
    pub fn frames(&self) -> Frames {
        Frames(self.shared.clone())
    }

    #[cfg(feature = "bench")]
    pub fn take_presented(&self) -> PresentedBatch {
        self.clear_wakes();
        let mut shared = self.shared.lock().unwrap_or_else(|p| p.into_inner());
        shared.dirty.clear();
        PresentedBatch {
            samples: shared.presented.as_mut().map_or_else(Vec::new, |queue| queue.take()),
            queue_overflow: shared.presented.as_ref().is_some_and(|queue| queue.overflowed()),
        }
    }
}

/// The newest captured frame of a [`Capture`], read from another thread (the session's encode
/// thread) while the capture's owner drains damage.
pub struct Frames(Arc<Mutex<Shared>>);

impl Frames {
    /// The newest complete frame (kept, so a recovery keyframe needs no new capture), with its
    /// display and arrival times when ScreenCaptureKit gave a display time.
    pub fn newest(&self) -> Option<(PixelBuffer, Option<(u64, u64)>)> {
        let shared = self.0.lock().unwrap_or_else(|p| p.into_inner());
        shared.newest.clone().map(|frame| (frame, shared.newest_times))
    }
}

impl Drop for Capture {
    fn drop(&mut self) {
        // Out of the live list first (waiting for an exclusion update that uses it), so nothing
        // messages the stream after it is released below.
        if self.registered {
            live_streams()
                .lock()
                .unwrap_or_else(|p| p.into_inner())
                .retain(|(stream, _)| *stream != self.stream as usize);
        }
        let _pool = AutoreleasePool::new();
        let (tx, rx) = sync_channel::<()>(1);
        let stopped = block(capture_stopped as *const c_void, c"v@?@", tx);
        // SAFETY: each message is sent with its documented C signature to this capture's own
        // stream. The output leaves the stream first, then the stop is awaited (bounded), so no
        // frame reaches the output after it is released.
        unsafe {
            if self.added {
                let mut error: Id = null_mut();
                msg::<unsafe extern "C" fn(Id, Sel, Id, c_long, *mut Id) -> bool>()(
                    self.stream,
                    sel(c"removeStreamOutput:type:error:"),
                    self.output,
                    OUTPUT_SCREEN,
                    &raw mut error,
                );
            }
            msg::<unsafe extern "C" fn(Id, Sel, *mut c_void)>()(
                self.stream,
                sel(c"stopCaptureWithCompletionHandler:"),
                stopped.cast(),
            );
        }
        let _ = rx.recv_timeout(STOP_TIMEOUT);
        sinks()
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .retain(|(object, _)| *object != self.output as usize);
        sys::release(self.stream);
        sys::release(self.output);
        // SAFETY: the queue this capture created; ScreenCaptureKit retains it while it uses it.
        unsafe { sys::system::dispatch_release(self.queue) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_stop_from_the_menu_bar_ends_the_share() {
        let mut at = Vec::new();
        let ended = restart_allowed(STOPPED_BY_PERSON, "stopped", &mut at, Instant::now());
        assert_eq!(ended.unwrap_err().to_string(), "sharing was stopped from the macOS menu bar");
        assert!(at.is_empty());
    }

    #[test]
    fn other_stops_restart_until_they_repeat_too_often() {
        let start = Instant::now();
        let mut at = Vec::new();
        for i in 0..MAX_RESTARTS as u64 {
            let now = start + Duration::from_secs(i);
            assert!(restart_allowed(-3821, "display changed", &mut at, now).is_ok());
        }
        let now = start + Duration::from_secs(MAX_RESTARTS as u64);
        let ended = restart_allowed(-3821, "display changed", &mut at, now).unwrap_err();
        assert_eq!(ended.to_string(), "the screen capture keeps stopping (display changed)");
        // Once the window has passed, a stop restarts again.
        let later = start + RESTART_WINDOW + Duration::from_secs(MAX_RESTARTS as u64);
        assert!(restart_allowed(-3821, "display changed", &mut at, later).is_ok());
    }

    #[test]
    fn sizes_fit_the_decoder_and_stay_even() {
        assert_eq!(fit(3456, 2234, None), (3342, 2160));
        assert_eq!(fit(1920, 1080, Some(1280)), (1280, 720));
        assert_eq!(fit(1366, 768, None), (1366, 768));
    }

    #[test]
    fn refresh_rates_round_and_zero_means_unknown() {
        assert_eq!(hz_to_fps(120.0), Some(120));
        assert_eq!(hz_to_fps(119.88), Some(120));
        assert_eq!(hz_to_fps(59.94), Some(60));
        assert_eq!(hz_to_fps(0.0), None);
        assert_eq!(hz_to_fps(f64::NAN), None);
        assert_eq!(hz_to_fps(500.0), Some(MAX_REFRESH_FPS));
    }

    #[test]
    fn the_minimum_frame_interval_stays_clear_of_the_display_cadence() {
        let seconds = |t: CMTime| t.value as f64 / f64::from(t.timescale);
        // 60 fps on a 120 Hz panel: below two refreshes (16.67 ms), above one (8.33 ms).
        let at_60 = seconds(min_frame_interval(60));
        assert!(at_60 < 2.0 / 120.0 - 0.001 && at_60 > 1.0 / 120.0, "{at_60}");
        // At the refresh rate itself: below one refresh.
        assert!(seconds(min_frame_interval(120)) < 1.0 / 120.0 - 0.0005);
        assert!(seconds(min_frame_interval(0)) > 0.0);
        assert_eq!(min_frame_interval(1000).timescale, (MAX_REFRESH_FPS * 10) as i32);
    }

    #[test]
    fn exclusion_lists_are_sorted_unique_and_skip_zero() {
        assert_eq!(exclusion_list([456, 0, 123, 456]), vec![123, 456]);
        assert_eq!(exclusion_list([]), Vec::<u32>::new());
        assert!(exclusion_list([9, 3, 7]).binary_search(&7).is_ok());
    }

    #[test]
    fn dirty_points_become_clamped_pixels() {
        let rect = to_pixels((10.0, 20.0, 5.0, 5.0), 2.0, (100, 100));
        assert_eq!(rect, Some(Rect { x: 20, y: 40, width: 10, height: 10 }));
        assert_eq!(to_pixels((60.0, 60.0, 10.0, 10.0), 2.0, (100, 100)), None);
    }
}
