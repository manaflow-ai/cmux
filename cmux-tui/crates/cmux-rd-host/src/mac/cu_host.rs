//! cmux Computer Use's pixels in the Screen Sharing helper: the engine's
//! [`HostServices`] backed by ScreenCaptureKit's one-shot screenshots
//! (`SCScreenshotManager`, macOS 14 or later), so its macOS desktop never falls back to
//! CoreGraphics' `CGWindowListCreateImage`, obsoleted in the macOS 15 SDK. The helper's
//! `__computer-use-worker` mode hands [`computer_use_host_services`] to the engine. Same
//! process and code signature as the screen sharing capture, so one Screen Recording grant
//! covers both. Every call asks ScreenCaptureKit for its content afresh (windows come and go
//! between calls) and waits for one picture; nothing streams.

use super::capture::shareable_content;
use super::sys::{self, block, cf, cg, msg, sel, AutoreleasePool, Block, CGRect, Class, Id, Sel};
use cmux_computer_use::desktop::{
    App, CaptureTarget, DResult, DesktopError, HostServices, Point, RawFrame,
};
use std::ffi::{c_long, c_void, CStr};
use std::sync::mpsc::{sync_channel, SyncSender};
use std::sync::Arc;
use std::time::Duration;

/// How long one screenshot may take (ScreenCaptureKit asks the window server).
const SHOT_TIMEOUT: Duration = Duration::from_secs(10);
/// SCCaptureResolutionBest: the display's full pixel density.
const CAPTURE_RESOLUTION_BEST: c_long = 1;
/// The largest side a screenshot may have, in pixels (a 6K display is 6016 wide).
const MAX_SIDE: f64 = 16384.0;

cmux_encode::framework! {
    pub mod cgi = "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics" {
        fn CGImageGetWidth(image: *mut ::std::ffi::c_void) -> usize;
        fn CGImageGetHeight(image: *mut ::std::ffi::c_void) -> usize;
        fn CGPreflightScreenCaptureAccess() -> bool;
    }
}

/// The engine's [`HostServices`] through ScreenCaptureKit, or None when this macOS has no
/// ScreenCaptureKit screenshots (before macOS 14), where the engine's CoreGraphics capture still
/// works. Pass it to `MacDesktop::new`.
pub fn computer_use_host_services() -> Option<Arc<dyn HostServices>> {
    sys::load().ok()?;
    cgi::available().ok()?;
    if sys::class(c"SCScreenshotManager").is_null() {
        return None;
    }
    Some(Arc::new(ScreenCaptureKitHost))
}

/// Screenshots for cmux Computer Use from ScreenCaptureKit.
struct ScreenCaptureKitHost;

impl HostServices for ScreenCaptureKitHost {
    fn capture(&self, target: &CaptureTarget) -> DResult<RawFrame> {
        require_grant()?;
        let content = Content::fetch()?;
        let _pool = AutoreleasePool::new();
        match target {
            CaptureTarget::Window(id) => {
                let id: u32 = id
                    .trim()
                    .parse()
                    .map_err(|_| DesktopError::TargetNotFound(format!("window {id}")))?;
                let window = content
                    .windows()
                    .into_iter()
                    .find(|&w| window_id(w) == id)
                    .ok_or_else(|| DesktopError::TargetNotFound(format!("window {id}")))?;
                // SAFETY: -[SCWindow frame]: the window's frame in global points, top left first.
                let frame = unsafe { rect_of(window, c"frame") };
                // SAFETY: -[SCContentFilter initWithDesktopIndependentWindow:] with a live window.
                let filter = Owned(unsafe {
                    msg::<unsafe extern "C" fn(Id, Sel, Id) -> Id>()(
                        sys::send_id(sys::class(c"SCContentFilter"), c"alloc"),
                        sel(c"initWithDesktopIndependentWindow:"),
                        window,
                    )
                });
                shoot(&filter, frame, true)
            }
            CaptureTarget::Display(display) => {
                let (display, bounds) = content.display(display.as_deref())?;
                let filter = Owned(display_filter(display, None));
                shoot(&filter, bounds, false)
            }
        }
    }

    fn capture_display_excluding(
        &self,
        display: Option<&str>,
        exclude_pids: &[u32],
    ) -> DResult<RawFrame> {
        require_grant()?;
        let content = Content::fetch()?;
        let _pool = AutoreleasePool::new();
        let (display, bounds) = content.display(display)?;
        let apps: Vec<Id> = content
            .applications()
            .into_iter()
            .filter(|&app| u32::try_from(app_pid(app)).is_ok_and(|pid| exclude_pids.contains(&pid)))
            .collect();
        let filter = Owned(display_filter(display, Some(&apps)));
        shoot(&filter, bounds, false)
    }

    fn capture_apps(&self) -> DResult<Vec<App>> {
        require_grant()?;
        let content = Content::fetch()?;
        let _pool = AutoreleasePool::new();
        let mut apps: Vec<App> = content
            .applications()
            .into_iter()
            .filter_map(|app| {
                let pid = u32::try_from(app_pid(app)).ok().filter(|p| *p > 0)?;
                Some(App {
                    id: sys::string(sys::send_id(app, c"bundleIdentifier")),
                    name: sys::string(sys::send_id(app, c"applicationName")),
                    pid,
                    frontmost: false,
                    hidden: false,
                })
            })
            .collect();
        apps.sort_by_key(|a| a.pid);
        apps.dedup_by_key(|a| a.pid);
        Ok(apps)
    }

    /// The engine asks macOS itself (same process, same grant).
    fn request_permission(&self, _which: &str) -> DResult<()> {
        Err(DesktopError::Unsupported("the engine asks macOS directly".into()))
    }

    /// `computer-use status` reads the grant the person sees in System Settings, not this
    /// process's old answer.
    fn screen_capture_granted(&self) -> Option<bool> {
        Some(screen_capture() != ScreenCapture::Missing)
    }
}

/// Screen Recording for this worker process.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ScreenCapture {
    Granted,
    /// Granted in System Settings after this process first read no: macOS keeps a running
    /// process's denial, so only a fresh worker can capture. This one is about to exit.
    GrantedAfterStart,
    Missing,
}

/// How long a worker that found a new grant keeps serving, so the answer it is writing reaches
/// the daemon, before it exits. The daemon starts the next worker 200 ms after the exit
/// (cmux-tui-core `computer_use_host`, a worker that ran 30 s or more).
const RESTART_AFTER: Duration = Duration::from_millis(300);
/// How long the fresh `permissions` read may take.
const PROBE_TIMEOUT: Duration = Duration::from_secs(3);

fn screen_capture() -> ScreenCapture {
    // SAFETY: no arguments; the framework loaded (computer_use_host_services checked it).
    if unsafe { cgi::CGPreflightScreenCaptureAccess() } {
        return ScreenCapture::Granted;
    }
    // Only on a no: one short-lived child of this same helper (`permissions`, the read the app
    // already uses), so macOS checks the same identity and answers afresh.
    if fresh_screen_recording() != Some(true) {
        return ScreenCapture::Missing;
    }
    restart_for_new_grant();
    ScreenCapture::GrantedAfterStart
}

fn require_grant() -> DResult<()> {
    match screen_capture() {
        ScreenCapture::Granted => Ok(()),
        ScreenCapture::GrantedAfterStart => Err(DesktopError::Failed(
            "Screen Recording was just turned on; Computer Use is restarting to use it. Try again in a second."
                .into(),
        )),
        ScreenCapture::Missing => Err(DesktopError::PermissionMissing("screen_capture".into())),
    }
}

/// `screen_recording` from a fresh `<this executable> permissions`, or None when it could not
/// be read in time.
fn fresh_screen_recording() -> Option<bool> {
    use std::io::Read;
    let exe = std::env::current_exe().ok()?;
    // Owned here: a probe that outlives PROBE_TIMEOUT is killed and reaped below.
    let mut child = cmux_process::Command::new(exe)
        .arg("permissions")
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::piped())
        .stderr(cmux_process::Stdio::null())
        .spawn()
        .ok()?;
    // The snapshot is one short JSON line, far below a pipe's buffer, so waiting first cannot
    // block the child on a full pipe.
    let Ok(Some(status)) = child.wait_timeout(PROBE_TIMEOUT) else {
        let _ = child.kill();
        let _ = child.wait();
        return None;
    };
    let mut stdout = Vec::new();
    child.stdout.take()?.read_to_end(&mut stdout).ok()?;
    if !status.success() {
        return None;
    }
    parse_screen_recording(&stdout)
}

fn parse_screen_recording(stdout: &[u8]) -> Option<bool> {
    let line = std::str::from_utf8(stdout).ok()?.lines().next()?;
    serde_json::from_str::<serde_json::Value>(line).ok()?.get("screen_recording")?.as_bool()
}

/// Exits this worker once, [`RESTART_AFTER`] from now; the daemon starts a fresh one, which
/// sees the grant. Nothing else restarts: not cmux, not the daemon.
fn restart_for_new_grant() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        eprintln!(
            "cmux Computer Use: Screen Recording was granted; restarting the worker to use it"
        );
        let _ = std::thread::Builder::new().name("cmux-cu-grant-restart".into()).spawn(|| {
            std::thread::sleep(RESTART_AFTER);
            // Only a fresh process can use the new grant; replies are flushed per line.
            // crash-allow: a deliberate clean exit the daemon's supervisor restarts from
            std::process::exit(0);
        });
    });
}

#[cfg(test)]
mod grant_tests {
    use super::parse_screen_recording;

    #[test]
    fn reads_the_permissions_snapshot() {
        assert_eq!(
            parse_screen_recording(b"{\"screen_recording\":true,\"accessibility\":false}\n"),
            Some(true)
        );
        assert_eq!(
            parse_screen_recording(b"{\"screen_recording\":false,\"accessibility\":true}\n"),
            Some(false)
        );
    }

    #[test]
    fn anything_else_is_no_answer() {
        assert_eq!(parse_screen_recording(b""), None);
        assert_eq!(parse_screen_recording(b"not json\n"), None);
        assert_eq!(parse_screen_recording(b"{\"accessibility\":true}\n"), None);
    }
}

/// An Objective-C object this code owns (+1), released on drop.
struct Owned(Id);

impl Drop for Owned {
    fn drop(&mut self) {
        sys::release(self.0);
    }
}

/// One SCShareableContent, retained.
struct Content(Owned);

impl Content {
    fn fetch() -> DResult<Self> {
        shareable_content().map(|c| Self(Owned(c))).map_err(|e| DesktopError::Failed(e.to_string()))
    }

    fn list(&self, name: &CStr) -> Vec<Id> {
        objects(sys::send_id(self.0 .0, name))
    }

    fn windows(&self) -> Vec<Id> {
        self.list(c"windows")
    }

    fn applications(&self) -> Vec<Id> {
        self.list(c"applications")
    }

    /// The SCDisplay `id` names (a CGDirectDisplayID; None: the main display) and its bounds in
    /// global points.
    fn display(&self, id: Option<&str>) -> DResult<(Id, CGRect)> {
        let wanted = match id {
            // SAFETY: CGMainDisplayID has no preconditions.
            None => unsafe { cg::CGMainDisplayID() },
            Some(s) => s
                .trim()
                .parse::<u32>()
                .map_err(|_| DesktopError::TargetNotFound(format!("display {s}")))?,
        };
        let display = self
            .list(c"displays")
            .into_iter()
            // SAFETY: -[SCDisplay displayID] returns a CGDirectDisplayID.
            .find(|&d| unsafe { msg::<unsafe extern "C" fn(Id, Sel) -> u32>()(d, sel(c"displayID")) } == wanted)
            .ok_or_else(|| DesktopError::TargetNotFound(format!("display {wanted}")))?;
        // SAFETY: a display id ScreenCaptureKit listed.
        Ok((display, unsafe { cg::CGDisplayBounds(wanted) }))
    }
}

/// An NSArray's objects (borrowed from the array).
fn objects(list: Id) -> Vec<Id> {
    if list.is_null() {
        return Vec::new();
    }
    // SAFETY: -[NSArray count] and -objectAtIndex: with an index below count.
    unsafe {
        let count = msg::<unsafe extern "C" fn(Id, Sel) -> usize>()(list, sel(c"count"));
        (0..count)
            .map(|i| {
                msg::<unsafe extern "C" fn(Id, Sel, usize) -> Id>()(list, sel(c"objectAtIndex:"), i)
            })
            .collect()
    }
}

fn window_id(window: Id) -> u32 {
    // SAFETY: -[SCWindow windowID] returns a CGWindowID.
    unsafe { msg::<unsafe extern "C" fn(Id, Sel) -> u32>()(window, sel(c"windowID")) }
}

fn app_pid(app: Id) -> i32 {
    // SAFETY: -[SCRunningApplication processID] returns a pid_t.
    unsafe { msg::<unsafe extern "C" fn(Id, Sel) -> i32>()(app, sel(c"processID")) }
}

/// A +1 SCContentFilter of `display`, without the windows of `exclude_apps` when given.
fn display_filter(display: Id, exclude_apps: Option<&[Id]>) -> Id {
    let alloc = sys::send_id(sys::class(c"SCContentFilter"), c"alloc");
    // SAFETY: -[SCContentFilter initWithDisplay:excludingApplications:exceptingWindows:] and
    // -initWithDisplay:excludingWindows: with a live display and NSArrays of live objects.
    unsafe {
        match exclude_apps {
            Some(apps) => msg::<unsafe extern "C" fn(Id, Sel, Id, Id, Id) -> Id>()(
                alloc,
                sel(c"initWithDisplay:excludingApplications:exceptingWindows:"),
                display,
                array(apps),
                array(&[]),
            ),
            None => msg::<unsafe extern "C" fn(Id, Sel, Id, Id) -> Id>()(
                alloc,
                sel(c"initWithDisplay:excludingWindows:"),
                display,
                array(&[]),
            ),
        }
    }
}

/// An autoreleased NSArray of `items`.
fn array(items: &[Id]) -> Id {
    let list = sys::send_id(sys::class(c"NSMutableArray"), c"array");
    for &item in items {
        // SAFETY: -[NSMutableArray addObject:] with a live object.
        unsafe { msg::<unsafe extern "C" fn(Id, Sel, Id)>()(list, sel(c"addObject:"), item) };
    }
    list
}

/// A method returning a CGRect. arm64 returns any struct through objc_msgSend.
///
/// # Safety
/// `name` is a no-argument method of `object` returning a CGRect.
#[cfg(target_arch = "aarch64")]
unsafe fn rect_of(object: Id, name: &CStr) -> CGRect {
    // SAFETY: the caller's contract.
    unsafe { msg::<unsafe extern "C" fn(Id, Sel) -> CGRect>()(object, sel(name)) }
}

/// A method returning a CGRect. On x86_64 a struct this large comes back through
/// objc_msgSend_stret, which libobjc (loaded by `sys::load`) exports there only.
///
/// # Safety
/// `name` is a no-argument method of `object` returning a CGRect.
#[cfg(target_arch = "x86_64")]
unsafe fn rect_of(object: Id, name: &CStr) -> CGRect {
    type Stret = unsafe extern "C" fn(*mut CGRect, Id, Sel);
    // SAFETY: a NUL-terminated symbol name looked up in the loaded images.
    let address = unsafe { libc::dlsym(libc::RTLD_DEFAULT, c"objc_msgSend_stret".as_ptr()) };
    let mut rect = CGRect::default();
    if !address.is_null() {
        // SAFETY: objc_msgSend_stret with the method's signature (result pointer first).
        unsafe { std::mem::transmute::<*mut c_void, Stret>(address)(&mut rect, object, sel(name)) };
    }
    rect
}

type ShotAnswer = Result<usize, String>;

/// `SCScreenshotManager`'s completion handler: the CGImage (retained here, released by the
/// caller) or the error's text.
extern "C" fn screenshot_done(block: *mut Block<SyncSender<ShotAnswer>>, image: Id, error: Id) {
    let answer = if image.is_null() {
        Err(if error.is_null() { "no picture".to_string() } else { sys::error_text(error) })
    } else {
        // SAFETY: a live CGImage the handler borrows; retained so it outlives the handler.
        Ok(unsafe { cf::CFRetain(image.cast_const()) } as usize)
    };
    // SAFETY: the block this handler was built with (leaked, never freed).
    if let Err(late) = unsafe { &(*block).context }.send(answer) {
        // The caller gave up waiting: the retained image is nobody's.
        if let Ok(image) = late.0 {
            // SAFETY: the reference retained above.
            unsafe { cf::CFRelease(image as *const c_void) };
        }
    }
}

/// One picture of `filter` covering `frame` (global points), at the content's full pixel
/// density, without the cursor; `window`: leave the window's shadow out (the picture is its
/// frame, as the engine's CoreGraphics capture took it).
fn shoot(filter: &Owned, frame: CGRect, window: bool) -> DResult<RawFrame> {
    if filter.0.is_null() {
        return Err(DesktopError::Failed("ScreenCaptureKit gave no content filter".into()));
    }
    if !(frame.size.width > 0.0 && frame.size.height > 0.0) {
        return Err(DesktopError::Failed("the window or display has no size".into()));
    }
    // SAFETY: -[SCContentFilter pointPixelScale] (macOS 14) returns a float.
    let scale = f64::from(unsafe {
        msg::<unsafe extern "C" fn(Id, Sel) -> f32>()(filter.0, sel(c"pointPixelScale"))
    });
    let scale = if scale.is_finite() && scale > 0.0 { scale } else { 1.0 };
    let width = (frame.size.width * scale).round().clamp(1.0, MAX_SIDE) as usize;
    let height = (frame.size.height * scale).round().clamp(1.0, MAX_SIDE) as usize;

    let config = Owned(sys::send_id(sys::class(c"SCStreamConfiguration"), c"new"));
    // SAFETY: SCStreamConfiguration setters with their argument types (size_t, BOOL, NSInteger).
    unsafe {
        let set_size = msg::<unsafe extern "C" fn(Id, Sel, usize)>();
        set_size(config.0, sel(c"setWidth:"), width);
        set_size(config.0, sel(c"setHeight:"), height);
        let set_bool = msg::<unsafe extern "C" fn(Id, Sel, bool)>();
        set_bool(config.0, sel(c"setShowsCursor:"), false);
        if window {
            set_bool(config.0, sel(c"setIgnoreShadowsSingleWindow:"), true);
        }
        msg::<unsafe extern "C" fn(Id, Sel, c_long)>()(
            config.0,
            sel(c"setCaptureResolution:"),
            CAPTURE_RESOLUTION_BEST,
        );
    }

    let (tx, rx) = sync_channel::<ShotAnswer>(1);
    let done = block(screenshot_done as *const c_void, c"v@?^{CGImage=}@", tx);
    // SAFETY: +[SCScreenshotManager captureImageWithFilter:configuration:completionHandler:]
    // (macOS 14) with live objects and a block of the (CGImageRef, NSError *) handler type.
    unsafe {
        msg::<unsafe extern "C" fn(Class, Sel, Id, Id, *mut c_void)>()(
            sys::class(c"SCScreenshotManager"),
            sel(c"captureImageWithFilter:configuration:completionHandler:"),
            filter.0,
            config.0,
            done.cast(),
        );
    }
    let image = rx
        .recv_timeout(SHOT_TIMEOUT)
        .map_err(|_| DesktopError::Failed("ScreenCaptureKit did not answer the screenshot".into()))?
        .map_err(|e| DesktopError::Failed(format!("ScreenCaptureKit screenshot failed: {e}")))?;
    let image = Image(image as sys::CGImageRef);
    let (pixels_wide, pixels_high, rgba) = rgba_of(image.0)?;
    Ok(RawFrame {
        width: pixels_wide,
        height: pixels_high,
        rgba,
        scale: f64::from(pixels_wide) / frame.size.width,
        origin: Point { x: frame.origin.x, y: frame.origin.y },
    })
}

/// A CGImage this code holds (+1), released on drop.
struct Image(sys::CGImageRef);

impl Drop for Image {
    fn drop(&mut self) {
        // SAFETY: the reference the screenshot handler retained.
        unsafe { cf::CFRelease(self.0.cast_const()) };
    }
}

/// A CGImage drawn into tightly packed RGBA8 (sRGB, premultiplied), top row first.
fn rgba_of(image: sys::CGImageRef) -> DResult<(u32, u32, Vec<u8>)> {
    // SAFETY: a live CGImage.
    let (w, h) = unsafe { (cgi::CGImageGetWidth(image), cgi::CGImageGetHeight(image)) };
    if w == 0 || h == 0 {
        return Err(DesktopError::Failed("the screenshot is empty".into()));
    }
    let (Ok(width), Ok(height)) = (u32::try_from(w), u32::try_from(h)) else {
        return Err(DesktopError::Failed("the screenshot is too large".into()));
    };
    let mut rgba = vec![0u8; w * h * 4];
    // SAFETY: the context draws into `rgba` (w * h * 4 bytes, outliving the context); the color
    // space and context are released here.
    unsafe {
        let space = cg::CGColorSpaceCreateWithName(cg::kCGColorSpaceSRGB());
        let context = cg::CGBitmapContextCreate(
            rgba.as_mut_ptr().cast(),
            w,
            h,
            8,
            w * 4,
            space,
            sys::BITMAP_RGBA_PREMULTIPLIED,
        );
        cg::CGColorSpaceRelease(space);
        if context.is_null() {
            return Err(DesktopError::Failed("could not create a bitmap context".into()));
        }
        let rect = CGRect {
            origin: sys::CGPoint::new(0.0, 0.0),
            size: sys::CGSize { width: w as f64, height: h as f64 },
        };
        cg::CGContextDrawImage(context, rect, image);
        cg::CGContextRelease(context);
    }
    Ok((width, height, rgba))
}
