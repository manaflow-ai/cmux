//! `--serve`: one remote tab over `cmux.rd/1` (service `rb/1`) on the rd
//! stream carrier (remote-tab-r2.md section 1, steps 3 and 5). macOS only.
//!
//! Threads: the CEF UI thread (the process main thread) owns the tab, the
//! pump and the encoder, and runs every shim call. A network thread accepts
//! one viewer at a time and does the rd handshake; a reader thread per
//! viewer posts its frames to the UI thread with `rb_shim_post`; a writer
//! thread per viewer writes what the UI thread sends, so a slow socket never
//! blocks the UI thread. Captured IOSurfaces are encoded on the UI thread
//! inside the frame callback (VideoToolbox, no CPU copy); the pump keeps the
//! latest lease for gated and recovery encodes.

use std::ffi::{CStr, CString, c_char, c_int, c_void};
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::mpsc::{self, Sender};
use std::sync::{Mutex, TryLockError};
use std::time::{Duration, Instant};

use cmux_encode::videotoolbox::{
    ColorTag, SurfaceEncoder, SurfaceFormat, SurfaceFrame, SurfaceRect, VideoToolbox,
};
use cmux_rd_core::flow::Rect;
use cmux_rd_core::service::negotiate;
use cmux_rd_engine::EngineConfig;
use cmux_rd_proto::control::Control as RdControl;
use cmux_rd_proto::{
    MAX_DATAGRAM_DEFAULT, SERVICE_REMOTE_BROWSER, STREAM_CONTROL, STREAM_DATAGRAM, StreamDeframer,
    encode_stream_frame,
};
use cmux_remote_browser::proto::{Control, ScreenInfo, SurfaceKind, ViewerCaps};

use crate::ffi::{
    RbCallbacks, RbFrame, ShimPresentation, rb_shim_capture_refresh, rb_shim_context_menu_result,
    rb_shim_dialog_result, rb_shim_frame_release, rb_shim_popup_menu_result, rb_shim_post,
    rb_shim_post_delayed, rb_shim_quit, rb_shim_run, rb_shim_surface_close,
};
use crate::pump::{FrameEncoder, Pump, PumpOut};
use crate::shim_ui;
use crate::tab::{DEFAULT_SCREEN, HostTab, SurfaceOut};

const FPS: u32 = 60;
const START_KBPS: u32 = 8000;
/// A popup stream's first bitrate (the engine then sets its share).
const POPUP_KBPS: u32 = 600;
/// The viewer id of the stream carrier's single viewer.
const VIEWER: &str = "rd-viewer";

/// `--serve` options.
#[derive(Debug, Clone)]
pub struct Options {
    pub listen: SocketAddr,
    pub url: String,
    /// Exit after the first viewer leaves.
    pub once: bool,
    /// Quit when stdin reaches end of file (`--lifeline`, the app's launch
    /// contract in `launch.rs`).
    pub lifeline: bool,
}

/// One capture lease; dropping it gives the frame back to Viz (UI thread).
pub struct Lease {
    lease: i64,
    surface: *mut c_void,
    width: u32,
    height: u32,
}

// SAFETY: a lease is created, encoded and dropped on the CEF UI thread only
// (the host state that holds it lives there; the Mutex only satisfies the
// static's Sync bound).
unsafe impl Send for Lease {}

impl Drop for Lease {
    fn drop(&mut self) {
        // SAFETY: the lease came from the frame callback; UI thread.
        unsafe { rb_shim_frame_release(self.lease) }
    }
}

/// VideoToolbox over capture leases.
pub struct Vt(VideoToolbox);

impl FrameEncoder for Vt {
    type Frame = Lease;

    fn encode(
        &mut self,
        f: &Lease,
        damage: Rect,
        force_idr: bool,
        pts_us: i64,
        out: &mut Vec<u8>,
    ) -> Result<bool, String> {
        // SAFETY: the lease keeps the IOSurface alive until it is dropped,
        // after this synchronous call.
        let frame = unsafe {
            SurfaceFrame::new(f.surface, SurfaceFormat::Bgra, f.width, f.height, ColorTag::Srgb)
        };
        let damage =
            SurfaceRect { x: damage.x, y: damage.y, width: damage.width, height: damage.height };
        self.0.encode_surface(&frame, damage, force_idr, pts_us, out).map_err(|e| e.to_string())
    }

    fn set_kbps(&mut self, kbps: u32) {
        self.0.set_bitrate(kbps);
    }

    fn kbps(&self) -> u32 {
        self.0.kbps()
    }
}

/// What the network threads hand the UI thread.
enum Net {
    Joined { writer: Sender<Vec<u8>>, max_datagram: usize },
    Frame(u8, Vec<u8>),
    Left,
}

struct Viewer {
    writer: Sender<Vec<u8>>,
    pump: Pump<Vt>,
}

struct Host {
    opts: Options,
    tab: HostTab,
    viewer: Option<Viewer>,
    t0: Instant,
    /// The tick already posted for this deadline (microseconds).
    timer: Option<u64>,
    first_frame_seen: bool,
    refresh_wanted: bool,
}

static HOST: Mutex<Option<Host>> = Mutex::new(None);

type Work = Box<dyn FnOnce(&mut Host)>;

/// Runs `f` on the host now, or, when a shim call made from inside the host
/// re-entered a callback (the lock is held on this thread), as a posted UI
/// task right after.
fn dispatch(f: impl FnOnce(&mut Host) + 'static) {
    match HOST.try_lock() {
        Ok(mut guard) => {
            if let Some(h) = guard.as_mut() {
                f(h);
            }
        }
        Err(TryLockError::WouldBlock) => {
            let work: Box<Work> = Box::new(Box::new(f));
            // SAFETY: `on_work` takes the box back on the UI thread.
            unsafe { rb_shim_post(on_work, Box::into_raw(work).cast::<c_void>()) }
        }
        Err(TryLockError::Poisoned(_)) => {}
    }
}

unsafe extern "C" fn on_work(ctx: *mut c_void) {
    // SAFETY: `dispatch` leaked this box for exactly this call.
    let work = unsafe { Box::from_raw(ctx.cast::<Work>()) };
    dispatch(*work);
}

impl Host {
    fn now(&self) -> u64 {
        u64::try_from(self.t0.elapsed().as_micros()).unwrap_or(u64::MAX)
    }

    fn send_frame(&self, kind: u8, payload: &[u8]) {
        let Some(v) = self.viewer.as_ref() else { return };
        let mut out = Vec::with_capacity(payload.len() + 5);
        if encode_stream_frame(kind, payload, &mut out).is_ok() {
            let _ = v.writer.send(out);
        }
    }

    fn send_rd(&self, control: &RdControl) {
        if let Ok(json) = serde_json::to_vec(control) {
            self.send_frame(STREAM_CONTROL, &json);
        }
    }

    fn send_rb(&self, controls: Vec<Control>) {
        for c in controls {
            let Ok(body) = serde_json::to_value(&c) else { continue };
            self.send_rd(&RdControl::Service { service: SERVICE_REMOTE_BROWSER.into(), body });
        }
    }

    fn apply(&mut self, out: PumpOut) {
        for d in &out.datagrams {
            self.send_frame(STREAM_DATAGRAM, d);
        }
        let mut p = ShimPresentation;
        // The input skipped a gap (a lost release may be in it): release
        // what the viewer holds before the events after the gap apply.
        if out.release_all {
            let (keys, buttons) = self.tab.held();
            eprintln!("serve: release_all: {keys} keys, {buttons} buttons");
            self.tab.release_all(&mut p);
        }
        for event in &out.input {
            // A refused event (Blink would drop it) is not an error here.
            let _ = self.tab.input(event, &mut p);
        }
        if out.refresh {
            self.refresh_wanted = true;
        }
        self.refresh();
    }

    /// Applies what the tab decided for a popup surface: streams on the
    /// viewer's pump, messages to the viewer.
    fn surface_outs(&mut self, outs: Vec<SurfaceOut>) {
        for out in outs {
            match out {
                SurfaceOut::Control(c) => {
                    eprintln!("serve: {}", serde_json::to_string(&c).unwrap_or_default());
                    self.send_rb(vec![c]);
                }
                SurfaceOut::AddStream { surface, stream, width, height } => {
                    let Some(v) = self.viewer.as_mut() else { continue };
                    let added = VideoToolbox::new(width, height, FPS, POPUP_KBPS, false)
                        .map_err(|e| e.to_string())
                        .and_then(|vt| {
                            v.pump
                                .add_stream(stream, width, height, Vt(vt))
                                .map_err(|e| format!("{e:?}"))
                        });
                    if let Err(e) = added {
                        // The viewer cannot see it: close it in the page.
                        eprintln!("serve: surface {surface} stream {stream}: {e}");
                        if let Ok(id) = c_int::try_from(surface) {
                            // SAFETY: plain value; UI thread.
                            unsafe { rb_shim_surface_close(id) };
                        }
                    }
                }
                SurfaceOut::RemoveStream { stream } => {
                    if let Some(v) = self.viewer.as_mut() {
                        v.pump.remove_stream(stream);
                    }
                }
            }
        }
    }

    /// Asks the capture for a full frame when the pump waits for one.
    fn refresh(&mut self) {
        if !self.refresh_wanted || !self.tab.capturing() {
            return;
        }
        if let Some(browser) = self.tab.browser {
            // SAFETY: plain value; UI thread.
            if unsafe { rb_shim_capture_refresh(browser) } == 1 {
                self.refresh_wanted = false;
            }
        }
    }

    /// Posts a tick for the pump's next deadline (none while idle).
    fn arm(&mut self) {
        let Some(due) = self.viewer.as_ref().and_then(|v| v.pump.next_deadline_us()) else {
            return;
        };
        if self.timer.is_some_and(|t| t <= due) {
            return;
        }
        self.timer = Some(due);
        let ms = i64::try_from(due.saturating_sub(self.now()).div_ceil(1000)).unwrap_or(1);
        // SAFETY: a plain function; no context.
        unsafe { rb_shim_post_delayed(on_timer, std::ptr::null_mut(), ms) }
    }

    fn joined(&mut self, writer: Sender<Vec<u8>>, max_datagram: usize) {
        let screen = self.tab.session.canonical_screen().unwrap_or(DEFAULT_SCREEN);
        let width = (f64::from(screen.css_width) * screen.scale).ceil() as u32;
        let height = (f64::from(screen.css_height) * screen.scale).ceil() as u32;
        let encoder = match VideoToolbox::new(width, height, FPS, START_KBPS, false) {
            Ok(vt) => Vt(vt),
            Err(e) => {
                eprintln!("serve: VideoToolbox: {e}");
                return;
            }
        };
        let cfg =
            EngineConfig { width, height, max_fps: FPS, max_datagram, ..EngineConfig::default() };
        let now = self.now();
        self.viewer = Some(Viewer { writer, pump: Pump::new(cfg, encoder, now) });
        self.first_frame_seen = false;
        // The stream carrier's viewer opens the tab by joining (the rd
        // hello named the service); an explicit rb.open later only updates
        // its screen.
        let open = Control::Open {
            tab: "tab-1".into(),
            profile: "remote".into(),
            viewer: VIEWER.into(),
            screen: ScreenInfo {
                css_width: screen.css_width,
                css_height: screen.css_height,
                scale: screen.scale,
                refresh_hz: FPS,
                color_space: "srgb".into(),
            },
            caps: ViewerCaps { codecs: vec!["h264".into()], tile_codecs: vec![], max_fps: FPS },
        };
        let replies = self.tab.control(VIEWER, &open, &mut ShimPresentation);
        self.send_rb(replies);
        let out = self.viewer.as_mut().map(|v| v.pump.start(now)).unwrap_or_default();
        self.apply(out);
    }

    fn left(&mut self) {
        let replies = self.tab.control(VIEWER, &Control::Close, &mut ShimPresentation);
        drop(replies);
        // Dropping the pump gives its held lease back.
        self.viewer = None;
        self.refresh_wanted = false;
        if self.opts.once {
            // SAFETY: UI thread.
            unsafe { rb_shim_quit() }
        }
    }

    fn net_frame(&mut self, kind: u8, payload: &[u8]) {
        let now = self.now();
        if kind == STREAM_DATAGRAM {
            let out = match self.viewer.as_mut() {
                Some(v) => v.pump.datagram(payload, true, now),
                None => return,
            };
            self.apply(out);
            return;
        }
        match serde_json::from_slice::<RdControl>(payload) {
            Ok(RdControl::Service { body, .. }) => {
                let Ok(msg) = serde_json::from_value::<Control>(body) else { return };
                let replies = self.tab.control(VIEWER, &msg, &mut ShimPresentation);
                self.send_rb(replies);
            }
            Ok(RdControl::Stop) => {
                self.send_rd(&RdControl::Ended { reason: "stopped".into() });
            }
            _ => {}
        }
    }
}

unsafe extern "C" fn on_net(ctx: *mut c_void) {
    // SAFETY: `post_net` leaked this box for exactly this call.
    let event = unsafe { Box::from_raw(ctx.cast::<Net>()) };
    dispatch(move |h| {
        match *event {
            Net::Joined { writer, max_datagram } => h.joined(writer, max_datagram),
            Net::Frame(kind, payload) => h.net_frame(kind, &payload),
            Net::Left => h.left(),
        }
        h.arm();
    });
}

fn post_net(event: Net) {
    let ctx = Box::into_raw(Box::new(event)).cast::<c_void>();
    // SAFETY: `on_net` takes the box back on the UI thread.
    unsafe { rb_shim_post(on_net, ctx) }
}

unsafe extern "C" fn on_timer(_: *mut c_void) {
    dispatch(|h| {
        h.timer = None;
        let now = h.now();
        let out = h.viewer.as_mut().map(|v| v.pump.tick(true, now)).unwrap_or_default();
        h.apply(out);
        h.arm();
    });
}

unsafe extern "C" fn on_quit(_: *mut c_void) {
    // SAFETY: UI thread (posted through `rb_shim_post`).
    unsafe { rb_shim_quit() }
}

unsafe extern "C" fn on_ready(_: *mut c_void) {
    let Some((addr, lifeline)) =
        HOST.lock().ok().and_then(|g| g.as_ref().map(|h| (h.opts.listen, h.opts.lifeline)))
    else {
        return;
    };
    if lifeline {
        std::thread::spawn(|| {
            crate::launch::watch_lifeline(std::io::stdin().lock(), || {
                eprintln!("serve: lifeline closed, quitting");
                // SAFETY: `on_quit` runs on the UI thread and takes no context.
                unsafe { rb_shim_post(on_quit, std::ptr::null_mut()) }
            });
        });
    }
    std::thread::spawn(move || {
        if let Err(e) = listen(addr) {
            eprintln!("serve: {e}");
        }
    });
}

unsafe extern "C" fn on_tab_created(_: *mut c_void, _request: c_int, browser: c_int) {
    dispatch(move |h| {
        h.tab.tab_created(browser, &mut ShimPresentation);
        h.refresh();
    });
}

/// Title and URL changes come once the tab has its view: a capture the shim
/// refused before starts now.
unsafe extern "C" fn on_page_text(_: *mut c_void, _browser: c_int, text: *const c_char) {
    if !text.is_null() {
        // SAFETY: NUL-terminated for the call.
        let text = unsafe { CStr::from_ptr(text) }.to_string_lossy();
        eprintln!("serve: page {text}");
    }
    dispatch(|h| {
        h.tab.retry_capture(&mut ShimPresentation);
        h.refresh();
    });
}

/// A C string of a shim callback (valid for the call), or `None` for NULL.
fn text(p: *const c_char) -> Option<String> {
    // SAFETY: the shim passes NUL-terminated strings valid for the call.
    (!p.is_null()).then(|| unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned())
}

/// A page context menu: shown on the viewer with an rb token (or cancelled
/// in Chromium when the menu is refused).
unsafe extern "C" fn on_context_menu(
    _: *mut c_void,
    _browser: c_int,
    token: i64,
    x: c_int,
    y: c_int,
    items: *const c_char,
) {
    let menu = shim_ui::context_menu(x, y, &text(items).unwrap_or_default());
    dispatch(move |h| match menu {
        Ok(menu) => {
            let out = h.tab.menu_opened(token, menu, &mut ShimPresentation);
            h.send_rb(out);
        }
        Err(e) => {
            eprintln!("serve: context menu JSON: {e}");
            // SAFETY: plain values; UI thread. Cancels so Chromium does not wait.
            unsafe { rb_shim_context_menu_result(token, -1) };
        }
    });
}

/// A `<select>` popup, or (NULL items) the page closed the popup itself.
#[allow(clippy::too_many_arguments)]
unsafe extern "C" fn on_popup_menu(
    _: *mut c_void,
    _browser: c_int,
    token: i64,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    items: *const c_char,
    selected: c_int,
    multiple: c_int,
) {
    let Some(items) = text(items) else {
        dispatch(move |h| {
            let out = h.tab.menu_closed_by_page(token);
            h.send_rb(out);
        });
        return;
    };
    let menu = shim_ui::select_menu(x, y, width, height, &items, selected, multiple != 0);
    dispatch(move |h| match menu {
        Ok(menu) => {
            let out = h.tab.menu_opened(token, menu, &mut ShimPresentation);
            h.send_rb(out);
        }
        Err(e) => {
            eprintln!("serve: popup menu JSON: {e}");
            // SAFETY: a null array with a negative count cancels; UI thread.
            unsafe { rb_shim_popup_menu_result(token, std::ptr::null(), -1) };
        }
    });
}

/// A JS dialog: shown on the viewer with an rb token (an unknown kind is
/// dismissed in Chromium).
#[allow(clippy::too_many_arguments)]
unsafe extern "C" fn on_dialog(
    _: *mut c_void,
    _browser: c_int,
    token: i64,
    kind: *const c_char,
    origin: *const c_char,
    message: *const c_char,
    default_text: *const c_char,
    is_reload: c_int,
) {
    let dialog = shim_ui::dialog(
        &text(kind).unwrap_or_default(),
        &text(origin).unwrap_or_default(),
        &text(message).unwrap_or_default(),
        text(default_text).as_deref(),
        is_reload != 0,
    );
    dispatch(move |h| match dialog {
        Some(dialog) => {
            let out = h.tab.dialog_opened(token, dialog, &mut ShimPresentation);
            h.send_rb(out);
        }
        None => {
            // SAFETY: plain values; UI thread.
            unsafe { rb_shim_dialog_result(token, 0, std::ptr::null()) };
        }
    });
}

unsafe extern "C" fn on_dialog_reset(_: *mut c_void, _browser: c_int) {
    dispatch(|h| {
        let out = h.tab.dialog_reset();
        h.send_rb(out);
    });
}

unsafe extern "C" fn on_frame(_: *mut c_void, _browser: c_int, f: *const RbFrame) {
    // SAFETY: valid for the call.
    let f = unsafe { &*f };
    let lease = Lease {
        lease: f.lease,
        surface: f.io_surface,
        width: u32::try_from(f.coded_width).unwrap_or(0),
        height: u32::try_from(f.coded_height).unwrap_or(0),
    };
    if f.io_surface.is_null() {
        return; // CPU frames are the Linux host's (dropping releases).
    }
    let damage = frame_damage(f, lease.width, lease.height);
    dispatch(move |h| {
        if !h.first_frame_seen {
            h.first_frame_seen = true;
            let replies = h.tab.first_frame(&mut ShimPresentation);
            h.send_rb(replies);
        }
        let now = h.now();
        let Some(v) = h.viewer.as_mut() else { return };
        h.refresh_wanted = false;
        let out = v.pump.frame(lease, damage, now, now);
        h.apply(out);
        h.arm();
    });
}

/// A popup surface opened, moved or went (RP7).
#[allow(clippy::too_many_arguments)]
unsafe extern "C" fn on_surface(
    _: *mut c_void,
    _browser: c_int,
    surface: c_int,
    kind: c_int,
    visible: c_int,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
) {
    let Ok(surface) = u32::try_from(surface) else { return };
    // cef_cmux.h CMUX_RP_SURFACE_PAGE_POPUP; Views bubbles are not surfaces yet.
    let kind = if kind == 1 { SurfaceKind::PagePopup } else { SurfaceKind::Bubble };
    let anchor = HostTab::anchor(x, y, width, height);
    eprintln!("serve: surface {surface} visible {visible} at {x},{y} {width}x{height}");
    dispatch(move |h| {
        let outs =
            h.tab.surface_changed(surface, kind, visible != 0, anchor, &mut ShimPresentation);
        h.surface_outs(outs);
    });
}

/// A captured frame of a popup surface: the first one (or one of a new
/// size) shows the surface on its own stream; each is encoded there.
unsafe extern "C" fn on_surface_frame(_: *mut c_void, surface: c_int, f: *const RbFrame) {
    // SAFETY: valid for the call.
    let f = unsafe { &*f };
    let lease = Lease {
        lease: f.lease,
        surface: f.io_surface,
        width: u32::try_from(f.coded_width).unwrap_or(0),
        height: u32::try_from(f.coded_height).unwrap_or(0),
    };
    let Ok(surface) = u32::try_from(surface) else { return };
    if f.io_surface.is_null() || lease.width == 0 || lease.height == 0 {
        return;
    }
    let damage = frame_damage(f, lease.width, lease.height);
    dispatch(move |h| {
        let outs = h.tab.surface_frame(surface, lease.width, lease.height);
        h.surface_outs(outs);
        let Some(stream) = h.tab.surface_stream(surface) else { return };
        let now = h.now();
        let Some(v) = h.viewer.as_mut() else { return };
        let out = v.pump.frame_on(stream, lease, damage, now, now);
        h.apply(out);
        h.arm();
    });
}

/// The frame's update rect, or all of it.
fn frame_damage(f: &RbFrame, width: u32, height: u32) -> Rect {
    if f.has_update_rect == 0 {
        return Rect { x: 0, y: 0, width, height };
    }
    Rect {
        x: u32::try_from(f.update_x).unwrap_or(0),
        y: u32::try_from(f.update_y).unwrap_or(0),
        width: u32::try_from(f.update_width).unwrap_or(width),
        height: u32::try_from(f.update_height).unwrap_or(height),
    }
}

fn listen(addr: SocketAddr) -> std::io::Result<()> {
    let listener = TcpListener::bind(addr)?;
    let bound = listener.local_addr()?;
    eprintln!("serve: listening on {bound} (service {SERVICE_REMOTE_BROWSER})");
    // The readiness line the app waits for (launch.rs): one flushed stdout line.
    let mut stdout = std::io::stdout().lock();
    writeln!(stdout, "{}", crate::launch::listening_line(bound))?;
    stdout.flush()?;
    drop(stdout);
    for conn in listener.incoming() {
        let conn = conn?;
        conn.set_nodelay(true)?;
        match session(conn) {
            Ok(reason) => eprintln!("serve: session ended: {reason}"),
            Err(e) => eprintln!("serve: session failed: {e}"),
        }
    }
    Ok(())
}

fn write_rd(stream: &mut TcpStream, control: &RdControl) -> std::io::Result<()> {
    let json = serde_json::to_vec(control).map_err(std::io::Error::other)?;
    let mut out = Vec::with_capacity(json.len() + 5);
    encode_stream_frame(STREAM_CONTROL, &json, &mut out)
        .map_err(|e| std::io::Error::other(format!("{e:?}")))?;
    stream.write_all(&out)
}

/// One viewer: the rd handshake here, then frames to the UI thread until EOF.
fn session(mut stream: TcpStream) -> std::io::Result<String> {
    stream.set_read_timeout(Some(Duration::from_secs(10)))?;
    let mut deframer = StreamDeframer::default();
    let mut buf = vec![0u8; 64 * 1024];
    let hello = loop {
        if let Ok(Some((kind, payload))) = deframer.next_frame() {
            if kind == STREAM_CONTROL {
                break serde_json::from_slice::<RdControl>(&payload)
                    .map_err(std::io::Error::other)?;
            }
            continue;
        }
        let n = stream.read(&mut buf)?;
        if n == 0 {
            return Ok("left before hello".into());
        }
        deframer.extend(&buf[..n]);
    };
    let RdControl::Hello { service, caps, max_datagram, .. } = hello else {
        return Ok("the first control message is not hello".into());
    };
    let negotiated = match negotiate(&service, &caps, &[SERVICE_REMOTE_BROWSER], &[]) {
        Ok(n) => n,
        Err(refusal) => {
            write_rd(&mut stream, &RdControl::Refused { reason: refusal.reason().into() })?;
            return Ok(format!("refused hello for service {service}"));
        }
    };
    let max_datagram = max_datagram.clamp(512, MAX_DATAGRAM_DEFAULT);
    let w = (f64::from(DEFAULT_SCREEN.css_width) * DEFAULT_SCREEN.scale).ceil() as u32;
    let h = (f64::from(DEFAULT_SCREEN.css_height) * DEFAULT_SCREEN.scale).ceil() as u32;
    write_rd(
        &mut stream,
        &RdControl::Welcome {
            encoder: "videotoolbox".into(),
            width: w,
            height: h,
            max_datagram,
            carrier: "stream".into(),
            service: negotiated.service,
            caps: negotiated.caps,
        },
    )?;
    write_rd(&mut stream, &RdControl::Started { session: 1 })?;
    stream.set_read_timeout(None)?;
    let (tx, rx) = mpsc::channel::<Vec<u8>>();
    let mut out = stream.try_clone()?;
    let writer = std::thread::spawn(move || {
        for bytes in rx {
            if out.write_all(&bytes).is_err() {
                return;
            }
        }
    });
    post_net(Net::Joined { writer: tx, max_datagram });
    let reason = loop {
        while let Ok(Some((kind, payload))) = deframer.next_frame() {
            post_net(Net::Frame(kind, payload));
        }
        match stream.read(&mut buf) {
            Ok(0) => break "viewer left".to_string(),
            Ok(n) => deframer.extend(&buf[..n]),
            Err(e) => break format!("read: {e}"),
        }
    };
    let _ = stream.shutdown(std::net::Shutdown::Both);
    post_net(Net::Left);
    let _ = writer.join();
    Ok(reason)
}

/// Runs the host until `rb_shim_quit` and returns the process exit code.
pub fn run(argv: &mut [*mut c_char], opts: Options) -> i32 {
    let cache = std::env::var("CMUX_RB_CACHE_DIR").unwrap_or_else(|_| "/tmp/cmux-rb-host".into());
    let cache = CString::new(cache).unwrap_or_default();
    let url = opts.url.clone();
    if let Ok(mut guard) = HOST.lock() {
        *guard = Some(Host {
            opts,
            tab: HostTab::new(1, 1, &url),
            viewer: None,
            t0: Instant::now(),
            timer: None,
            first_frame_seen: false,
            refresh_wanted: false,
        });
    }
    let callbacks = RbCallbacks {
        context: std::ptr::null_mut(),
        on_ready: Some(on_ready),
        on_tab_created: Some(on_tab_created),
        on_tab_closed: None,
        on_title: Some(on_page_text),
        on_url: Some(on_page_text),
        on_frame: Some(on_frame),
        on_key_unhandled: None,
        on_context_menu: Some(on_context_menu),
        on_popup_menu: Some(on_popup_menu),
        on_needs_begin_frames: None,
        on_dialog: Some(on_dialog),
        on_dialog_reset: Some(on_dialog_reset),
        on_surface: Some(on_surface),
        on_surface_frame: Some(on_surface_frame),
    };
    // SAFETY: argv, the strings and the callbacks outlive the call.
    unsafe {
        rb_shim_run(
            c_int::try_from(argv.len()).unwrap_or(0),
            argv.as_mut_ptr(),
            cache.as_ptr(),
            0,
            &callbacks,
        )
    }
}
