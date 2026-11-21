//! `--serve`: remote tabs over `cmux.rd/1` (service `rb/1`) on the rd stream
//! carrier (remote-tab-r2.md section 1, steps 3 and 5). macOS only.
//!
//! Two shapes, one code path:
//! - one tab (`--serve`): the tab opens when its viewer joins; the viewer's
//!   hello carries the per-launch secret (the lifeline's first line);
//! - a shared host (`--serve --shared`, started by `--supervise`,
//!   src/supervise.rs): N tabs, each a CefBrowser with its own request context
//!   and cache directory (its own cookies and storage), opened and closed by
//!   the supervisor's lines on stdin. A tab's page opens at once (a hidden
//!   keeper viewer holds it, so a restarted host reloads every tab before its
//!   viewer is back); a viewer's hello token picks its tab, and viewers of
//!   different tabs stream at the same time.
//!
//! Threads: the CEF UI thread (the process main thread) owns the tabs, the
//! pumps and the encoders, and runs every shim call. A network thread accepts
//! callers and admits each on its own thread (`launch::accept_viewers_with`);
//! a reader thread per viewer posts its frames to the UI thread with
//! `rb_shim_post`; a writer thread per viewer writes what the UI thread sends,
//! so a slow socket never blocks the UI thread. Captured IOSurfaces are
//! encoded on the UI thread inside the frame callback (VideoToolbox, no CPU
//! copy); the pump keeps the latest lease for gated and recovery encodes.

use std::collections::BTreeMap;
use std::ffi::{CStr, CString, c_char, c_int, c_void};
use std::io::{BufRead, Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, Sender};
use std::sync::{Arc, Mutex, PoisonError, TryLockError};
use std::time::Instant;

use cmux_encode::videotoolbox::{
    ColorTag, SurfaceEncoder, SurfaceFormat, SurfaceFrame, SurfaceRect, VideoToolbox,
};
use cmux_rd_core::flow::Rect;
use cmux_rd_engine::EngineConfig;
use cmux_rd_proto::control::Control as RdControl;
use cmux_rd_proto::{
    MAX_DATAGRAM_DEFAULT, SERVICE_REMOTE_BROWSER, STREAM_CONTROL, STREAM_DATAGRAM,
    encode_stream_frame,
};
use cmux_remote_browser::proto::{Control, InputEvent, PointerKind, ScreenInfo, ViewerCaps};
use serde_json::{Value, json};

use crate::ffi::{
    RbCallbacks, RbFrame, ShimPresentation, rb_shim_capture_refresh, rb_shim_close_tab,
    rb_shim_context_menu_result, rb_shim_dialog_result, rb_shim_frame_release,
    rb_shim_popup_menu_result, rb_shim_post, rb_shim_post_delayed, rb_shim_quit, rb_shim_run,
    rb_shim_surface_close,
};
use crate::meter::Meter;
use crate::pump::{FrameEncoder, Pump, PumpOut};
use crate::shim_ui;
use crate::tab::{DEFAULT_SCREEN, HostTab, PageChange, SurfaceOut, fork_surface_kind};

const FPS: u32 = 60;
const START_KBPS: u32 = 8000;
/// A popup stream's first bitrate (the engine then sets its share).
const POPUP_KBPS: u32 = 600;
/// The viewer id of the stream carrier's single viewer.
const VIEWER: &str = "rd-viewer";
/// The hidden viewer that holds a shared host's page open while no viewer
/// streams it (never visible: it never sets the screen or starts capture).
const KEEPER: &str = "host-keeper";
/// The tab key of the one-tab host.
const ONE_TAB: u32 = 1;

/// `--serve` options.
#[derive(Debug, Clone)]
pub struct Options {
    pub listen: SocketAddr,
    /// Serve on this inherited listener instead of binding `listen`
    /// (`--listen-fd`: the supervisor's, kept across hosts).
    pub listen_fd: Option<i32>,
    pub url: String,
    /// Exit after the first viewer leaves.
    pub once: bool,
    /// Quit when stdin reaches end of file (`--lifeline`, the app's launch
    /// contract in `launch.rs`).
    pub lifeline: bool,
    /// The per-launch secret a viewer's rd hello must carry as its token (the first
    /// lifeline line). `main` refuses to start a one-tab host without one; `None`
    /// admits nobody.
    pub secret: Option<String>,
    /// A shared host: the tabs come from the supervisor's lines on stdin.
    pub shared: bool,
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

/// What the network threads hand the UI thread, for tab `key` and viewer
/// connection `conn`.
enum Net {
    Joined { writer: Sender<Vec<u8>>, max_datagram: usize, stream: Option<TcpStream> },
    Frame(u8, Vec<u8>),
    Left,
}

/// A line the supervisor sent a shared host.
enum Command {
    Open { id: String, url: String, token: String, cache: String },
    Close { id: String },
    Serve,
}

struct Viewer {
    /// The connection (a reconnect replaces it; a stale one's `Left` is ignored).
    conn: u64,
    writer: Sender<Vec<u8>>,
    /// To end the connection when the tab closes.
    stream: Option<TcpStream>,
    pump: Pump<Vt>,
    /// Media numbers for the host log (`serve: stats`).
    meter: Meter,
    /// Pump encode counters the meter has seen (frames, IDR).
    seen: (u64, u64),
}

/// One tab and its viewer.
struct Slot {
    /// The app's tab id (`tab-1` on a one-tab host).
    id: String,
    /// The tab's own cache directory (a shared host's tabs each have one).
    cache: Option<CString>,
    tab: HostTab,
    viewer: Option<Viewer>,
    t0: Instant,
    first_frame_seen: bool,
    refresh_wanted: bool,
}

struct Host {
    opts: Options,
    slots: BTreeMap<u32, Slot>,
    next_key: u32,
    /// Browsers of closed tabs, until CEF closed them (then the supervisor
    /// may remove the tab's directory).
    closing: BTreeMap<i32, String>,
    /// Closed tabs whose browser was not created yet, by request.
    closing_requests: BTreeMap<u32, String>,
    t0: Instant,
    /// The tick already posted for this deadline (microseconds).
    timer: Option<u64>,
    listening: bool,
}

static HOST: Mutex<Option<Host>> = Mutex::new(None);

/// The tokens viewers may join with, and their tabs (read by the admission
/// threads; written on the UI thread).
static TOKENS: Mutex<Vec<(String, u32)>> = Mutex::new(Vec::new());

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

/// One stdout line for the supervisor (a short line to a reader that always
/// reads: the supervisor's poll loop).
fn emit(value: Value) {
    let mut stdout = std::io::stdout().lock();
    let _ = writeln!(stdout, "{value}").and_then(|()| stdout.flush());
}

impl Slot {
    fn new(key: u32, id: &str, url: &str, cache: Option<CString>, t0: Instant) -> Self {
        let request = i32::try_from(key).unwrap_or(i32::MAX);
        Self {
            id: id.to_string(),
            cache,
            tab: HostTab::new(request, u64::from(key), url),
            viewer: None,
            t0,
            first_frame_seen: false,
            refresh_wanted: false,
        }
    }

    /// The shim for this tab: its window and its request context.
    fn shim(&self) -> ShimPresentation {
        ShimPresentation { browser: self.tab.browser, cache: self.cache.clone() }
    }

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
        self.apply_timed(out, None);
    }

    /// [`Self::apply`] for the output of a pump call that took `call_us`
    /// (the encode time when it encoded a frame).
    fn apply_timed(&mut self, out: PumpOut, call_us: Option<u64>) {
        for d in &out.datagrams {
            self.send_frame(STREAM_DATAGRAM, d);
        }
        self.meter(&out, call_us);
        let mut p = self.shim();
        // The input skipped a gap (a lost release may be in it): release
        // what the viewer holds before the events after the gap apply.
        if out.release_all {
            let (keys, buttons) = self.tab.held();
            eprintln!("serve: release_all: {keys} keys, {buttons} buttons");
            self.tab.release_all(&mut p);
        }
        for (i, event) in out.input.iter().enumerate() {
            let seq = out.input_seqs.get(i).copied().flatten();
            // A refused event (Blink would drop it) is not an error here.
            let _ = self.tab.input_seq(event, seq, &mut p);
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

    /// Counts what one pump call sent and logs a stats line once a window
    /// is full.
    fn meter(&mut self, out: &PumpOut, call_us: Option<u64>) {
        let now = self.now();
        let Some(v) = self.viewer.as_mut() else { return };
        let bytes: usize = out.datagrams.iter().map(Vec::len).sum();
        v.meter.sent(bytes);
        let stats = v.pump.stats();
        let frames = stats.encoded.saturating_sub(v.seen.0);
        let idr = stats.idr.saturating_sub(v.seen.1);
        v.seen = (stats.encoded, stats.idr);
        v.meter.encoded(frames, idr, call_us.filter(|_| frames > 0), now);
        if out.input.iter().any(draws) {
            v.meter.input(now);
        }
        let kbps = v.pump.encoder().kbps();
        if let Some(line) = v.meter.take(kbps, false, now) {
            eprintln!("serve: stats {}", serde_json::to_string(&line).unwrap_or_default());
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

    /// When this tab's viewer needs a tick: the pump's deadline, or the
    /// stats window's (so a page that went still logs its last window now,
    /// not at its next frame).
    fn deadline(&self) -> Option<u64> {
        let v = self.viewer.as_ref()?;
        match (v.pump.next_deadline_us(), v.meter.deadline_us()) {
            (Some(a), Some(b)) => Some(a.min(b)),
            (a, b) => a.or(b),
        }
    }

    fn tick(&mut self) {
        let now = self.now();
        let out = self.viewer.as_mut().map(|v| v.pump.tick(true, now)).unwrap_or_default();
        self.apply(out);
    }

    /// The tab's page opens now, held by the hidden keeper viewer (a shared
    /// host's tab: its viewer joins later, or comes back after a restart).
    fn keep_open(&mut self) {
        let mut p = self.shim();
        drop(self.tab.control(KEEPER, &open_control(DEFAULT_SCREEN), &mut p));
        drop(self.tab.control(KEEPER, &Control::Visibility { visible: false }, &mut p));
    }

    fn joined(
        &mut self,
        conn: u64,
        writer: Sender<Vec<u8>>,
        max_datagram: usize,
        stream: Option<TcpStream>,
    ) {
        // A viewer that reconnects replaces the one before it.
        if self.viewer.is_some() {
            self.left(None);
        }
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
        self.viewer = Some(Viewer {
            conn,
            writer,
            stream,
            pump: Pump::new(cfg, encoder, now),
            meter: Meter::default(),
            seen: (0, 0),
        });
        self.first_frame_seen = false;
        // The stream carrier's viewer opens the tab by joining (the rd
        // hello named the service); an explicit rb.open later only updates
        // its screen.
        let replies = self.tab.control(VIEWER, &open_control(screen), &mut self.shim());
        self.send_rb(replies);
        let out = self.viewer.as_mut().map(|v| v.pump.start(now)).unwrap_or_default();
        self.apply(out);
        // Popups still open from an earlier viewer: the new pump has none
        // of their streams.
        let outs = self.tab.rejoin_surfaces(&mut self.shim());
        self.surface_outs(outs);
    }

    /// The viewer on `conn` left (`None`: whichever viewer is there).
    /// Returns whether a viewer left.
    fn left(&mut self, conn: Option<u64>) -> bool {
        if conn.is_some_and(|c| self.viewer.as_ref().is_none_or(|v| v.conn != c)) {
            return false;
        }
        let now = self.now();
        if let Some(v) = self.viewer.as_mut() {
            let kbps = v.pump.encoder().kbps();
            if let Some(line) = v.meter.take(kbps, true, now) {
                eprintln!("serve: stats {}", serde_json::to_string(&line).unwrap_or_default());
            }
        }
        drop(self.tab.control(VIEWER, &Control::Close, &mut self.shim()));
        // Dropping the pump gives its held lease back.
        if let Some(stream) = self.viewer.take().and_then(|v| v.stream) {
            let _ = stream.shutdown(std::net::Shutdown::Both);
        }
        self.refresh_wanted = false;
        true
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
                // The streaming viewer's file policy (file_policy.rs): set here, checked by
                // the shim on the UI and IO threads.
                if let Some(policy) = crate::file_policy::FilePolicy::parse(&body) {
                    eprintln!("serve: file policy set");
                    crate::file_policy::set(policy);
                    return;
                }
                let Ok(msg) = serde_json::from_value::<Control>(body) else { return };
                let replies = self.tab.control(VIEWER, &msg, &mut self.shim());
                self.send_rb(replies);
            }
            Ok(RdControl::Stop) => {
                self.send_rd(&RdControl::Ended { reason: "stopped".into() });
            }
            _ => {}
        }
    }
}

fn open_control(screen: cmux_remote_browser::session::ScreenSize) -> Control {
    Control::Open {
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
    }
}

impl Host {
    fn now(&self) -> u64 {
        u64::try_from(self.t0.elapsed().as_micros()).unwrap_or(u64::MAX)
    }

    fn slot_of_browser(&mut self, browser: c_int) -> Option<&mut Slot> {
        self.slots.values_mut().find(|s| s.tab.browser == Some(browser))
    }

    fn slot_of_surface(&mut self, surface: u32) -> Option<&mut Slot> {
        self.slots.values_mut().find(|s| s.tab.has_surface(surface))
    }

    /// Posts a tick for the earliest viewer deadline (none while idle).
    fn arm(&mut self) {
        let Some(due) = self.slots.values().filter_map(Slot::deadline).min() else { return };
        if self.timer.is_some_and(|t| t <= due) {
            return;
        }
        self.timer = Some(due);
        let ms = i64::try_from(due.saturating_sub(self.now()).div_ceil(1000)).unwrap_or(1);
        // SAFETY: a plain function; no context.
        unsafe { rb_shim_post_delayed(on_timer, std::ptr::null_mut(), ms) }
    }

    fn net(&mut self, key: u32, conn: u64, event: Net) {
        let once = self.opts.once;
        let Some(slot) = self.slots.get_mut(&key) else { return };
        match event {
            Net::Joined { writer, max_datagram, stream } => {
                slot.joined(conn, writer, max_datagram, stream);
            }
            Net::Frame(kind, payload) => {
                if slot.viewer.as_ref().is_some_and(|v| v.conn == conn) {
                    slot.net_frame(kind, &payload);
                }
            }
            Net::Left => {
                if slot.left(Some(conn)) && once {
                    // SAFETY: UI thread.
                    unsafe { rb_shim_quit() }
                }
            }
        }
    }

    fn command(&mut self, command: Command) {
        match command {
            Command::Open { id, url, token, cache } => {
                if self.slots.values().any(|s| s.id == id) || token.is_empty() {
                    return;
                }
                let key = self.next_key;
                self.next_key += 1;
                let cache = (!cache.is_empty()).then(|| CString::new(cache).unwrap_or_default());
                let mut slot = Slot::new(key, &id, &url, cache, self.t0);
                slot.keep_open();
                self.slots.insert(key, slot);
                TOKENS.lock().unwrap_or_else(PoisonError::into_inner).push((token, key));
                emit(json!({"tab": id, "ready": true}));
            }
            Command::Close { id } => {
                let Some(key) = self.slots.iter().find(|(_, s)| s.id == id).map(|(k, _)| *k) else {
                    return;
                };
                TOKENS.lock().unwrap_or_else(PoisonError::into_inner).retain(|(_, k)| *k != key);
                let Some(mut slot) = self.slots.remove(&key) else { return };
                slot.left(None);
                match slot.tab.browser {
                    Some(browser) => {
                        self.closing.insert(browser, id);
                        // SAFETY: plain value; UI thread.
                        unsafe { rb_shim_close_tab(browser) };
                    }
                    None => {
                        self.closing_requests.insert(key, id);
                    }
                }
            }
            Command::Serve => {
                if !self.listening {
                    self.listening = true;
                    start_listening(&self.opts);
                }
            }
        }
    }
}

unsafe extern "C" fn on_net(ctx: *mut c_void) {
    // SAFETY: `post_net` leaked this box for exactly this call.
    let event = unsafe { Box::from_raw(ctx.cast::<(u32, u64, Net)>()) };
    dispatch(move |h| {
        let (key, conn, event) = *event;
        h.net(key, conn, event);
        h.arm();
    });
}

fn post_net(key: u32, conn: u64, event: Net) {
    let ctx = Box::into_raw(Box::new((key, conn, event))).cast::<c_void>();
    // SAFETY: `on_net` takes the box back on the UI thread.
    unsafe { rb_shim_post(on_net, ctx) }
}

unsafe extern "C" fn on_command(ctx: *mut c_void) {
    // SAFETY: `post_command` leaked this box for exactly this call.
    let command = unsafe { Box::from_raw(ctx.cast::<Command>()) };
    dispatch(move |h| h.command(*command));
}

fn post_command(command: Command) {
    let ctx = Box::into_raw(Box::new(command)).cast::<c_void>();
    // SAFETY: `on_command` takes the box back on the UI thread.
    unsafe { rb_shim_post(on_command, ctx) }
}

/// A supervisor line (src/supervise.rs, "Wire with the host").
fn parse_command(line: &str) -> Option<Command> {
    let v: Value = serde_json::from_str(line).ok()?;
    let s = |o: &Value, k: &str| o.get(k).and_then(Value::as_str).map(str::to_string);
    if let Some(o) = v.get("open") {
        return Some(Command::Open {
            id: s(o, "tab")?,
            url: s(o, "url")?,
            token: s(o, "token")?,
            cache: s(o, "cache").unwrap_or_default(),
        });
    }
    if let Some(o) = v.get("close") {
        return Some(Command::Close { id: s(o, "tab")? });
    }
    v.get("serve").map(|_| Command::Serve)
}

unsafe extern "C" fn on_timer(_: *mut c_void) {
    dispatch(|h| {
        h.timer = None;
        let now = h.now();
        for slot in h.slots.values_mut() {
            if slot.deadline().is_some_and(|d| d <= now) {
                slot.tick();
            }
        }
        h.arm();
    });
}

unsafe extern "C" fn on_quit(_: *mut c_void) {
    // SAFETY: UI thread (posted through `rb_shim_post`).
    unsafe { rb_shim_quit() }
}

fn quit_soon() {
    // SAFETY: `on_quit` runs on the UI thread and takes no context.
    unsafe { rb_shim_post(on_quit, std::ptr::null_mut()) }
}

unsafe extern "C" fn on_ready(_: *mut c_void) {
    let Some(opts) = HOST.lock().ok().and_then(|g| g.as_ref().map(|h| h.opts.clone())) else {
        return;
    };
    if opts.lifeline || opts.shared {
        let shared = opts.shared;
        // The lifeline; on a shared host it also carries the supervisor's lines.
        std::thread::spawn(move || {
            let stdin = std::io::stdin().lock();
            if shared {
                for line in stdin.lines() {
                    let Ok(line) = line else { break };
                    if let Some(command) = parse_command(&line) {
                        post_command(command);
                    }
                }
            } else {
                crate::launch::watch_lifeline(stdin, || {});
            }
            eprintln!("serve: lifeline closed, quitting");
            quit_soon();
        });
    }
    if opts.shared {
        // It listens once the supervisor's first lines are in (`serve`).
        return;
    }
    dispatch(|h| {
        h.listening = true;
        start_listening(&h.opts);
    });
}

fn start_listening(opts: &Options) {
    let (addr, fd, shared) = (opts.listen, opts.listen_fd, opts.shared);
    std::thread::spawn(move || {
        if let Err(e) = listen(addr, fd, shared) {
            eprintln!("serve: {e}");
        }
    });
}

unsafe extern "C" fn on_tab_created(_: *mut c_void, request: c_int, browser: c_int) {
    dispatch(move |h| {
        let key = u32::try_from(request).unwrap_or(0);
        let Some(slot) = h.slots.get_mut(&key) else {
            // Its tab closed before the browser came: close the browser now.
            if let Some(id) = h.closing_requests.remove(&key) {
                h.closing.insert(browser, id);
            }
            // SAFETY: plain value; UI thread.
            unsafe { rb_shim_close_tab(browser) };
            return;
        };
        slot.tab.tab_created(browser, &mut slot.shim());
        slot.refresh();
    });
}

unsafe extern "C" fn on_tab_closed(_: *mut c_void, browser: c_int) {
    dispatch(move |h| {
        if let Some(id) = h.closing.remove(&browser) {
            emit(json!({"tab": id, "closed": true}));
        }
    });
}

/// A page fact for the viewer (`rb.page`). Title and URL changes come once
/// the tab has its view: a capture the shim refused before starts now.
fn page_changed(browser: c_int, change: PageChange) {
    dispatch(move |h| {
        let shared = h.opts.shared;
        let Some(slot) = h.slot_of_browser(browser) else { return };
        if shared && let PageChange::Url(url) = &change {
            emit(json!({"tab": slot.id, "url": url}));
        }
        slot.tab.retry_capture(&mut slot.shim());
        slot.refresh();
        let out = slot.tab.page_changed(change);
        slot.send_rb(out.into_iter().collect());
    });
}

unsafe extern "C" fn on_title(_: *mut c_void, browser: c_int, title: *const c_char) {
    page_changed(browser, PageChange::Title(text(title).unwrap_or_default()));
}

unsafe extern "C" fn on_url(_: *mut c_void, browser: c_int, url: *const c_char) {
    let url = text(url).unwrap_or_default();
    eprintln!("serve: page {url}");
    page_changed(browser, PageChange::Url(url));
}

unsafe extern "C" fn on_loading_state(
    _: *mut c_void,
    browser: c_int,
    loading: c_int,
    can_go_back: c_int,
    can_go_forward: c_int,
) {
    page_changed(
        browser,
        PageChange::Loading {
            loading: loading != 0,
            can_go_back: can_go_back != 0,
            can_go_forward: can_go_forward != 0,
        },
    );
}

unsafe extern "C" fn on_cursor(_: *mut c_void, browser: c_int, cef_type: c_int) {
    dispatch(move |h| {
        let Some(slot) = h.slot_of_browser(browser) else { return };
        let out = slot.tab.cursor_changed(cef_type);
        slot.send_rb(out.into_iter().collect());
    });
}

/// A key the page did not handle: the viewer runs its own action for it
/// (`rb.key_unhandled` names the last key-down's input seq).
unsafe extern "C" fn on_key_unhandled(
    _: *mut c_void,
    browser: c_int,
    _code: *const c_char,
    _modifiers: c_int,
) {
    dispatch(move |h| {
        let Some(slot) = h.slot_of_browser(browser) else { return };
        let out = slot.tab.key_unhandled();
        slot.send_rb(out.into_iter().collect());
    });
}

/// The page asked for a new tab or window (the shim cancelled the native
/// popup): the App opens it as a remote tab of its own (`rb.open_tab`).
unsafe extern "C" fn on_open_tab(
    _: *mut c_void,
    browser: c_int,
    url: *const c_char,
    disposition: c_int,
    user_gesture: c_int,
) {
    let url = text(url).unwrap_or_default();
    dispatch(move |h| {
        let Some(slot) = h.slot_of_browser(browser) else { return };
        let out = slot.tab.popup_requested(&url, disposition, user_gesture != 0);
        if out.is_none() {
            eprintln!("serve: page open with disposition {disposition} opens no tab");
        }
        slot.send_rb(out.into_iter().collect());
    });
}

/// May this `file:` URL load (the shim's check before every file navigation or
/// subresource; any thread)?
unsafe extern "C" fn on_file_load(_: *mut c_void, url: *const c_char) -> c_int {
    let url = text(url).unwrap_or_default();
    let allowed = crate::file_policy::check(&url);
    if !allowed {
        eprintln!("serve: refused a file load outside the policy");
    }
    c_int::from(allowed)
}

/// The focused field changed: the viewer raises its keyboard and keeps the
/// caret in view (`rb.text_input`).
unsafe extern "C" fn on_text_input(
    _: *mut c_void,
    browser: c_int,
    input_type: c_int,
    rects: *const c_int,
    rect_count: c_int,
    caret: *const c_int,
) {
    let count = usize::try_from(rect_count).unwrap_or(0).min(64);
    let rects: Vec<[i32; 4]> = if rects.is_null() || count == 0 {
        Vec::new()
    } else {
        // SAFETY: the shim passes `rect_count` rects of four ints, valid for the call.
        unsafe { std::slice::from_raw_parts(rects, count * 4) }
            .chunks_exact(4)
            .map(|r| [r[0], r[1], r[2], r[3]])
            .collect()
    };
    let caret = (!caret.is_null()).then(|| {
        // SAFETY: a non-NULL caret is four ints, valid for the call.
        let c = unsafe { std::slice::from_raw_parts(caret, 4) };
        [c[0], c[1], c[2], c[3]]
    });
    let body = crate::file_policy::text_input(input_type, &rects, caret);
    dispatch(move |h| {
        let Some(slot) = h.slot_of_browser(browser) else { return };
        slot.send_rd(&RdControl::Service { service: SERVICE_REMOTE_BROWSER.into(), body });
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
    browser: c_int,
    token: i64,
    x: c_int,
    y: c_int,
    items: *const c_char,
) {
    let menu = shim_ui::context_menu(x, y, &text(items).unwrap_or_default());
    dispatch(move |h| {
        let slot = h.slot_of_browser(browser);
        match (menu, slot) {
            (Ok(menu), Some(slot)) => {
                let out = slot.tab.menu_opened(token, menu, &mut slot.shim());
                slot.send_rb(out);
            }
            (menu, _) => {
                if let Err(e) = menu {
                    eprintln!("serve: context menu JSON: {e}");
                }
                // SAFETY: plain values; UI thread. Cancels so Chromium does not wait.
                unsafe { rb_shim_context_menu_result(token, -1) };
            }
        }
    });
}

/// A `<select>` popup, or (NULL items) the page closed the popup itself.
#[allow(clippy::too_many_arguments)]
unsafe extern "C" fn on_popup_menu(
    _: *mut c_void,
    browser: c_int,
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
            let Some(slot) = h.slot_of_browser(browser) else { return };
            let out = slot.tab.menu_closed_by_page(token);
            slot.send_rb(out);
        });
        return;
    };
    let menu = shim_ui::select_menu(x, y, width, height, &items, selected, multiple != 0);
    dispatch(move |h| {
        let slot = h.slot_of_browser(browser);
        match (menu, slot) {
            (Ok(menu), Some(slot)) => {
                let out = slot.tab.menu_opened(token, menu, &mut slot.shim());
                slot.send_rb(out);
            }
            (menu, _) => {
                if let Err(e) = menu {
                    eprintln!("serve: popup menu JSON: {e}");
                }
                // SAFETY: a null array with a negative count cancels; UI thread.
                unsafe { rb_shim_popup_menu_result(token, std::ptr::null(), -1) };
            }
        }
    });
}

/// A JS dialog: shown on the viewer with an rb token (an unknown kind is
/// dismissed in Chromium).
#[allow(clippy::too_many_arguments)]
unsafe extern "C" fn on_dialog(
    _: *mut c_void,
    browser: c_int,
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
    dispatch(move |h| {
        let slot = h.slot_of_browser(browser);
        match (dialog, slot) {
            (Some(dialog), Some(slot)) => {
                let out = slot.tab.dialog_opened(token, dialog, &mut slot.shim());
                slot.send_rb(out);
            }
            _ => {
                // SAFETY: plain values; UI thread.
                unsafe { rb_shim_dialog_result(token, 0, std::ptr::null()) };
            }
        }
    });
}

unsafe extern "C" fn on_dialog_reset(_: *mut c_void, browser: c_int) {
    dispatch(move |h| {
        let Some(slot) = h.slot_of_browser(browser) else { return };
        let out = slot.tab.dialog_reset();
        slot.send_rb(out);
    });
}

/// Chromium dropped one dialog without an answer (its frame went away, or
/// the tab closed): the viewers close it (`rb.dialog.cancel`).
unsafe extern "C" fn on_dialog_dropped(_: *mut c_void, browser: c_int, token: i64) {
    eprintln!("serve: dialog {token} dropped by the page");
    dispatch(move |h| {
        let Some(slot) = h.slot_of_browser(browser) else { return };
        let out = slot.tab.dialog_dropped(token);
        slot.send_rb(out);
    });
}

/// A find result of the running search (`rb.find.result` when it moved).
unsafe extern "C" fn on_find_result(
    _: *mut c_void,
    browser: c_int,
    count: c_int,
    active: c_int,
    _final_update: c_int,
) {
    dispatch(move |h| {
        let Some(slot) = h.slot_of_browser(browser) else { return };
        let out = slot.tab.find_result(count, active);
        slot.send_rb(out.into_iter().collect());
    });
}

unsafe extern "C" fn on_frame(_: *mut c_void, browser: c_int, f: *const RbFrame) {
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
        let Some(slot) = h.slot_of_browser(browser) else { return };
        if !slot.first_frame_seen {
            slot.first_frame_seen = true;
            let replies = slot.tab.first_frame(&mut slot.shim());
            slot.send_rb(replies);
        }
        let now = slot.now();
        let Some(v) = slot.viewer.as_mut() else { return };
        slot.refresh_wanted = false;
        let call = Instant::now();
        let out = v.pump.frame(lease, damage, now, now);
        let call_us = u64::try_from(call.elapsed().as_micros()).unwrap_or(u64::MAX);
        slot.apply_timed(out, Some(call_us));
        h.arm();
    });
}

/// A popup surface opened, moved or went (RP7).
#[allow(clippy::too_many_arguments)]
unsafe extern "C" fn on_surface(
    _: *mut c_void,
    browser: c_int,
    surface: c_int,
    kind: c_int,
    visible: c_int,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
) {
    let Ok(surface) = u32::try_from(surface) else { return };
    let Some(kind) = fork_surface_kind(kind) else {
        eprintln!("serve: surface {surface} kind {kind} ignored");
        return;
    };
    let anchor = HostTab::anchor(x, y, width, height);
    eprintln!("serve: surface {surface} visible {visible} at {x},{y} {width}x{height}");
    dispatch(move |h| {
        let Some(slot) = h.slot_of_browser(browser) else { return };
        let outs = slot.tab.surface_changed(surface, kind, visible != 0, anchor, &mut slot.shim());
        slot.surface_outs(outs);
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
        let Some(slot) = h.slot_of_surface(surface) else { return };
        let outs = slot.tab.surface_frame(surface, lease.width, lease.height);
        slot.surface_outs(outs);
        let Some(stream) = slot.tab.surface_stream(surface) else { return };
        let now = slot.now();
        let Some(v) = slot.viewer.as_mut() else { return };
        let call = Instant::now();
        let out = v.pump.frame_on(stream, lease, damage, now, now);
        let call_us = u64::try_from(call.elapsed().as_micros()).unwrap_or(u64::MAX);
        slot.apply_timed(out, Some(call_us));
        h.arm();
    });
}

/// Input after which the page may draw (stats: input to frame).
fn draws(event: &InputEvent) -> bool {
    match event {
        InputEvent::Key { down, .. } => *down,
        InputEvent::Pointer { kind, .. } => *kind == PointerKind::Down,
        InputEvent::Wheel { .. } => true,
        _ => false,
    }
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

fn listen(addr: SocketAddr, fd: Option<i32>, shared: bool) -> std::io::Result<()> {
    let listener = match fd {
        Some(fd) => {
            use std::os::fd::FromRawFd;
            // SAFETY: the supervisor put its listening socket on this fd
            // (src/supervise.rs `LISTEN_FD`) and nothing else here owns it.
            unsafe { TcpListener::from_raw_fd(fd) }
        }
        None => TcpListener::bind(addr)?,
    };
    let bound = listener.local_addr()?;
    eprintln!("serve: listening on {bound} (service {SERVICE_REMOTE_BROWSER})");
    // The readiness line the app waits for (launch.rs): one flushed stdout line.
    emit(serde_json::from_str(&crate::launch::listening_line(bound)).unwrap_or(Value::Null));
    // The viewer is admitted (its hello carries its tab's token) before the
    // welcome: a refused viewer never opens a tab or sends input.
    let check: crate::launch::HelloCheck<u32> = Arc::new(|hello| {
        let tokens = TOKENS.lock().unwrap_or_else(PoisonError::into_inner);
        crate::launch::authorize_tab(&tokens, hello)
    });
    // A viewer connection's number: a reconnect replaces the viewer before it.
    let conns = Arc::new(AtomicU64::new(0));
    let run = move |viewer: crate::launch::Admitted, key: u32| {
        let conn = conns.fetch_add(1, Ordering::Relaxed) + 1;
        match session(viewer, key, conn) {
            Ok(reason) => eprintln!("serve: session ended: {reason}"),
            Err(e) => eprintln!("serve: session failed: {e}"),
        }
    };
    let deadline = crate::launch::HELLO_DEADLINE;
    if shared {
        // Each tab's viewer streams at the same time as the others.
        crate::launch::accept_viewers_each(listener, deadline, check, Arc::new(run));
    } else {
        crate::launch::accept_viewers_with(listener, deadline, check, run);
    }
    Ok(())
}

fn write_rd(stream: &mut TcpStream, control: &RdControl) -> std::io::Result<()> {
    crate::launch::write_control(stream, control)
}

/// One viewer of tab `key`: the rd handshake here, then frames to the UI
/// thread until EOF.
fn session(viewer: crate::launch::Admitted, key: u32, conn: u64) -> std::io::Result<String> {
    let crate::launch::Admitted { mut stream, hello, mut deframer } = viewer;
    let mut buf = vec![0u8; 64 * 1024];
    let RdControl::Hello { service, caps, max_datagram, .. } = hello else {
        return Ok("the first control message is not hello".into());
    };

    let negotiated = match crate::handshake::negotiate_hello(&service, &caps) {
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
    post_net(key, conn, Net::Joined { writer: tx, max_datagram, stream: stream.try_clone().ok() });
    let reason = loop {
        while let Ok(Some((kind, payload))) = deframer.next_frame() {
            post_net(key, conn, Net::Frame(kind, payload));
        }
        match stream.read(&mut buf) {
            Ok(0) => break "viewer left".to_string(),
            Ok(n) => deframer.extend(&buf[..n]),
            Err(e) => break format!("read: {e}"),
        }
    };
    let _ = stream.shutdown(std::net::Shutdown::Both);
    post_net(key, conn, Net::Left);
    let _ = writer.join();
    Ok(reason)
}

/// Runs the host until `rb_shim_quit` and returns the process exit code.
pub fn run(argv: &mut [*mut c_char], opts: Options) -> i32 {
    let cache = std::env::var("CMUX_RB_CACHE_DIR").unwrap_or_else(|_| "/tmp/cmux-rb-host".into());
    let cache = CString::new(cache).unwrap_or_default();
    let t0 = Instant::now();
    let mut slots = BTreeMap::new();
    if !opts.shared {
        // The one tab, opened when its viewer joins; its viewer's token is the secret.
        slots.insert(ONE_TAB, Slot::new(ONE_TAB, "tab-1", &opts.url, None, t0));
        if let Some(secret) = opts.secret.clone().filter(|s| !s.is_empty()) {
            TOKENS.lock().unwrap_or_else(PoisonError::into_inner).push((secret, ONE_TAB));
        }
    }
    if let Ok(mut guard) = HOST.lock() {
        *guard = Some(Host {
            opts,
            slots,
            next_key: ONE_TAB + 1,
            closing: BTreeMap::new(),
            closing_requests: BTreeMap::new(),
            t0,
            timer: None,
            listening: false,
        });
    }
    let callbacks = RbCallbacks {
        context: std::ptr::null_mut(),
        on_ready: Some(on_ready),
        on_tab_created: Some(on_tab_created),
        on_tab_closed: Some(on_tab_closed),
        on_title: Some(on_title),
        on_url: Some(on_url),
        on_frame: Some(on_frame),
        on_key_unhandled: Some(on_key_unhandled),
        on_context_menu: Some(on_context_menu),
        on_popup_menu: Some(on_popup_menu),
        on_needs_begin_frames: None,
        on_dialog: Some(on_dialog),
        on_dialog_reset: Some(on_dialog_reset),
        on_surface: Some(on_surface),
        on_surface_frame: Some(on_surface_frame),
        on_loading_state: Some(on_loading_state),
        on_cursor: Some(on_cursor),
        on_open_tab: Some(on_open_tab),
        on_file_load: Some(on_file_load),
        on_text_input: Some(on_text_input),
        on_dialog_dropped: Some(on_dialog_dropped),
        on_find_result: Some(on_find_result),
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
