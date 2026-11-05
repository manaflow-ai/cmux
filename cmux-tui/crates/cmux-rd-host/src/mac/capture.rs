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
use std::time::Duration;

/// The largest picture the viewer's H.264 level (5.2) decodes at 60 fps. A larger display is
/// scaled down on the GPU by ScreenCaptureKit, keeping its aspect ratio.
const MAX_SIZE: (f64, f64) = (3840.0, 2160.0);
/// Frames ScreenCaptureKit may have in flight. The session holds one (the newest, so a
/// recovery keyframe can be encoded with no new capture) and encodes another.
const QUEUE_DEPTH: c_long = 4;
/// kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange.
const PIXEL_420V: u32 = u32::from_be_bytes(*b"420v");
/// SCStreamOutputTypeScreen and SCFrameStatusComplete.
const OUTPUT_SCREEN: c_long = 0;
const FRAME_COMPLETE: i64 = 0;
/// How long a session end waits for ScreenCaptureKit to confirm the stop.
const STOP_TIMEOUT: Duration = Duration::from_secs(2);
/// How long ScreenCaptureKit may take to answer (it asks the window server).
const ANSWER_TIMEOUT: Duration = Duration::from_secs(10);

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
}

/// The live output objects (by address) and their sinks.
type SinkList = Mutex<Vec<(usize, Arc<Sink>)>>;

/// The live output objects and their sinks, by object address. The handler runs on the
/// capture queue with only the object pointer to go on.
fn sinks() -> &'static SinkList {
    static SINKS: OnceLock<SinkList> = OnceLock::new();
    SINKS.get_or_init(Mutex::default)
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

/// The displays ScreenCaptureKit offers, as (SCDisplay retained, display id), left to right.
/// Empty, or an error, when Screen Recording is not allowed.
fn shareable_displays() -> Res<(Id, Vec<(Id, u32)>)> {
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

/// Every display's streamed size (native pixels fitted to the decoder, as a session
/// captures it), left to right, and the index of the main (menu bar) display.
pub fn displays() -> Res<(Vec<(u32, u32)>, usize)> {
    let (content, displays) = shareable_displays()?;
    // SAFETY: CGMainDisplayID has no preconditions.
    let main = unsafe { cg::CGMainDisplayID() };
    let current = displays.iter().position(|d| d.1 == main).unwrap_or(0);
    let sizes = displays
        .iter()
        .map(|&(_, id)| {
            let native = native_size(id);
            fit(native.0, native.1, None)
        })
        .collect();
    release_all(content, &displays);
    Ok((sizes, current))
}

/// `main` (the menu bar display) or a display's index counted left to right.
fn pick(displays: &[(Id, u32)], which: &str) -> Res<(Id, u32)> {
    if which == "main" {
        // SAFETY: CGMainDisplayID has no preconditions.
        let main = unsafe { cg::CGMainDisplayID() };
        return displays
            .iter()
            .find(|d| d.1 == main)
            .or(displays.first())
            .copied()
            .ok_or_else(|| "no display to capture (is Screen Recording allowed?)".into());
    }
    let index: usize =
        which.parse().map_err(|_| format!("--display {which}: use main or an index"))?;
    displays.get(index).copied().ok_or_else(|| format!("no display {index}").into())
}

/// How long ago, in µs, the mach absolute time `then` was. The Mach timebase and clock calls are
/// deprecated in favour of the `mach2` crate, which cmux-rd-host does not depend on; they are not
/// defective.
#[allow(deprecated)]
fn mach_age_us(then: u64) -> u64 {
    static BASE: OnceLock<(u64, u64)> = OnceLock::new();
    let (numer, denom) = *BASE.get_or_init(|| {
        let mut base = libc::mach_timebase_info { numer: 1, denom: 1 };
        // SAFETY: mach_timebase_info writes into a valid struct.
        unsafe { libc::mach_timebase_info(&mut base) };
        (u64::from(base.numer), u64::from(base.denom.max(1)))
    });
    // SAFETY: mach_absolute_time has no preconditions.
    let ticks = unsafe { libc::mach_absolute_time() }.saturating_sub(then);
    (u128::from(ticks) * u128::from(numer) / u128::from(denom) / 1000) as u64
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
        if buffer.is_null() {
            return;
        }
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
        let arrived = crate::clock::now_ns() / 1000;
        // The display time is in mach absolute time: its age now, taken off the protocol clock.
        let shown = number(info, sck::SCStreamFrameInfoDisplayTime())
            .map(|display| arrived.saturating_sub(mach_age_us(display as u64)));
        {
            let mut shared = sink.shared.lock().unwrap_or_else(|p| p.into_inner());
            shared.newest = Some(PixelBuffer(Retained::retain(buffer.cast_const())));
            shared.newest_times = shown.map(|shown| (shown, arrived));
            // A complete frame with no dirty rectangles still changed something.
            if rects.is_empty() {
                rects.push(Rect { x: 0, y: 0, width: sink.size.0, height: sink.size.1 });
            }
            shared.dirty.append(&mut rects);
        }
    }
    sink.wake.wake();
}

/// The output class, registered once: an NSObject that conforms to SCStreamOutput.
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
    pub fn start(which: &str, fps: u32, max_width: Option<u32>) -> Res<Self> {
        let (content, displays) = shareable_displays()?;
        let picked = pick(&displays, which);
        let result = picked.and_then(|(display, id)| Self::stream(display, id, fps, max_width));
        release_all(content, &displays);
        result
    }

    fn stream(display: Id, id: u32, fps: u32, max_width: Option<u32>) -> Res<Self> {
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
        // just created (alloc/init pairs return +1 references this capture releases).
        unsafe {
            // The pipe, the output and its queue first: every later error path releases them.
            let (wake_read, wake_write) = wake_pipe()?;
            let class = output_class()?;
            let output = sys::send_id(sys::send_id(class, c"alloc"), c"init");
            let queue = sys::system::dispatch_queue_create(
                c"com.cmuxterm.rd.capture".as_ptr(),
                std::ptr::null(),
            );
            let empty = sys::send_id(sys::class(c"NSArray"), c"array");
            let filter = msg::<unsafe extern "C" fn(Id, Sel, Id, Id) -> Id>()(
                sys::send_id(sys::class(c"SCContentFilter"), c"alloc"),
                sel(c"initWithDisplay:excludingWindows:"),
                display,
                empty,
            );
            let config = sys::send_id(sys::class(c"SCStreamConfiguration"), c"new");
            if filter.is_null() || config.is_null() {
                sys::release(filter);
                sys::release(config);
                sys::release(output);
                sys::system::dispatch_release(queue);
                return Err("ScreenCaptureKit did not make a filter and configuration".into());
            }
            let set_size = msg::<unsafe extern "C" fn(Id, Sel, usize)>();
            set_size(config, sel(c"setWidth:"), size.0 as usize);
            set_size(config, sel(c"setHeight:"), size.1 as usize);
            let interval =
                CMTime { value: 1, timescale: fps.max(1) as i32, flags: CM_TIME_VALID, epoch: 0 };
            msg::<unsafe extern "C" fn(Id, Sel, CMTime)>()(
                config,
                sel(c"setMinimumFrameInterval:"),
                interval,
            );
            msg::<unsafe extern "C" fn(Id, Sel, u32)>()(
                config,
                sel(c"setPixelFormat:"),
                PIXEL_420V,
            );
            msg::<unsafe extern "C" fn(Id, Sel, c_long)>()(
                config,
                sel(c"setQueueDepth:"),
                QUEUE_DEPTH,
            );
            msg::<unsafe extern "C" fn(Id, Sel, bool)>()(config, sel(c"setShowsCursor:"), true);
            msg::<unsafe extern "C" fn(Id, Sel, *const c_void)>()(
                config,
                sel(c"setColorSpaceName:"),
                cg::kCGColorSpaceSRGB(),
            );
            let stream = msg::<unsafe extern "C" fn(Id, Sel, Id, Id, Id) -> Id>()(
                sys::send_id(sys::class(c"SCStream"), c"alloc"),
                sel(c"initWithFilter:configuration:delegate:"),
                filter,
                config,
                null_mut(),
            );
            sys::release(filter);
            sys::release(config);
            if stream.is_null() {
                sys::release(output);
                sys::system::dispatch_release(queue);
                return Err("ScreenCaptureKit did not make a stream".into());
            }
            let shared = Arc::new(Mutex::new(Shared::default()));
            let sink = Arc::new(Sink { shared: shared.clone(), wake: wake_write, scale, size });
            sinks().lock().unwrap_or_else(|p| p.into_inner()).push((output as usize, sink));
            let mut error: Id = null_mut();
            let added = msg::<
                unsafe extern "C" fn(Id, Sel, Id, c_long, sys::DispatchQueue, *mut Id) -> bool,
            >()(
                stream,
                sel(c"addStreamOutput:type:sampleHandlerQueue:error:"),
                output,
                OUTPUT_SCREEN,
                queue,
                &raw mut error,
            );
            let capture = Self { stream, output, queue, shared, wake_read, size, bounds, added };
            if !added {
                return Err(format!("capture output handler: {}", sys::error_text(error)).into());
            }
            let (tx, rx) = sync_channel::<StartAnswer>(1);
            let started = block(capture_started as *const c_void, c"v@?@", tx);
            msg::<unsafe extern "C" fn(Id, Sel, *mut c_void)>()(
                stream,
                sel(c"startCaptureWithCompletionHandler:"),
                started.cast(),
            );
            rx.recv_timeout(ANSWER_TIMEOUT)
                .map_err(|_| "capture did not start (no answer from ScreenCaptureKit)")?
                .map_err(|e| format!("capture did not start: {e}"))?;
            eprintln!(
                "cmux-rd host: capturing display {id} ({}x{} px, {}x{} pt at {},{}), {fps} fps",
                size.0, size.1, bounds.width, bounds.height, bounds.x, bounds.y
            );
            Ok(capture)
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
    pub fn newest(&self) -> Option<(PixelBuffer, Option<(u64, u64)>)> {
        let shared = self.shared.lock().unwrap_or_else(|p| p.into_inner());
        shared.newest.clone().map(|frame| (frame, shared.newest_times))
    }
}

impl Drop for Capture {
    fn drop(&mut self) {
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
    fn sizes_fit_the_decoder_and_stay_even() {
        assert_eq!(fit(3456, 2234, None), (3342, 2160));
        assert_eq!(fit(1920, 1080, Some(1280)), (1280, 720));
        assert_eq!(fit(1366, 768, None), (1366, 768));
    }

    #[test]
    fn dirty_points_become_clamped_pixels() {
        let rect = to_pixels((10.0, 20.0, 5.0, 5.0), 2.0, (100, 100));
        assert_eq!(rect, Some(Rect { x: 20, y: 40, width: 10, height: 10 }));
        assert_eq!(to_pixels((60.0, 60.0, 10.0, 10.0), 2.0, (100, 100)), None);
    }
}
