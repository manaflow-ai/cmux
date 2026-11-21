//! `--serve` off macOS (docs/remote-browser-on-vm.md): one tab of a headless
//! Chromium over the DevTools pipe ([`crate::cdp`], [`crate::chromium`]),
//! streamed over cmux.rd/1 (service rb/1, stream carrier) with the launch
//! contract of the macOS host (`launch.rs`): loopback listener, the
//! per-launch secret as the hello token, quit at the lifeline's end.
//!
//! One loop thread owns the tab, the presentation and the viewer's pump.
//! Chromium's pipe, each viewer connection and the lifeline are threads that
//! post [`Event`]s to it. A screencast frame is a JPEG: it is decoded, turned
//! into I420 at the viewer's size and encoded with OpenH264; Chromium sends
//! the next frame only after the host acknowledged this one, so a slow
//! encode slows the capture instead of queueing frames.

use std::io::{BufRead, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::time::{Duration, Instant};

use cmux_encode::openh264::{OpenH264, OpenH264Api};
use cmux_encode::{EncCfg, H264Encoder, I420, bgrx_rect_to_i420, convert_threads};
use cmux_rd_core::flow::Rect;
use cmux_rd_engine::EngineConfig;
use cmux_rd_proto::control::Control as RdControl;
use cmux_rd_proto::{
    MAX_DATAGRAM_DEFAULT, SERVICE_REMOTE_BROWSER, STREAM_CONTROL, STREAM_DATAGRAM,
    encode_stream_frame,
};
use cmux_remote_browser::proto::{Control, ScreenInfo, ViewerCaps};
use cmux_remote_browser::session::ScreenSize;

use crate::cdp::{CdpEvent, CdpPresentation};
use crate::chromium::{Chromium, FromChromium};
use crate::launch::{Admitted, HELLO_DEADLINE, HelloCheck, authorize};
use crate::pump::{FrameEncoder, Pump, PumpOut};
use crate::tab::{DEFAULT_SCREEN, HostTab};

/// Software encode on a VM: 30 frames a second is the budget (the doc's
/// latency table).
pub const FPS: u32 = 30;
const START_KBPS: u32 = 6000;
const VIEWER: &str = "rd-viewer";
/// The tab's request id (one tab per host).
const REQUEST: i32 = 1;

/// Where the encoder library comes from: Cisco's (loaded with its pinned
/// hash) in the product, compiled from source in tests.
pub type EncoderApi = Arc<dyn Fn() -> Result<OpenH264Api, String> + Send + Sync>;

/// Cisco's OpenH264 (never one built from source in the product): `lib`, else
/// the copy `cmux-rd openh264-install` put in the per-user directory
/// (`$XDG_DATA_HOME/cmux/openh264` or `~/.local/share/cmux/openh264`). Its
/// pinned SHA-256 is checked on load.
pub fn cisco_api(lib: Option<&str>) -> Result<OpenH264Api, String> {
    use cmux_encode::openh264::{CiscoBinary, Platform, load_verified};
    let platform = Platform::current().ok_or("Cisco publishes no OpenH264 for this platform")?;
    let path = match lib {
        Some(lib) => PathBuf::from(lib),
        None => {
            let base = std::env::var_os("XDG_DATA_HOME")
                .map(PathBuf::from)
                .filter(|p| p.is_absolute())
                .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/share")))
                .ok_or("no per-user data directory (set HOME)")?;
            base.join("cmux/openh264").join(CiscoBinary::for_platform(platform).file_name)
        }
    };
    load_verified(&path, platform).map_err(|e| format!("{}: {e}", path.display()))
}

/// `--serve` options off macOS.
#[derive(Clone)]
pub struct Options {
    pub url: String,
    /// The per-launch secret a viewer's hello must carry (`None` admits nobody).
    pub secret: Option<String>,
    /// Exit after the first viewer leaves.
    pub once: bool,
    /// Quit at stdin's end of file (the secret line was read already).
    pub lifeline: bool,
    pub chromium: PathBuf,
    pub profile: PathBuf,
    pub encoder: EncoderApi,
}

impl std::fmt::Debug for Options {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Options")
            .field("url", &self.url)
            .field("once", &self.once)
            .field("lifeline", &self.lifeline)
            .field("chromium", &self.chromium)
            .field("profile", &self.profile)
            .finish_non_exhaustive()
    }
}

/// What the loop thread is told.
enum Event {
    Chromium(FromChromium),
    Joined { conn: u64, writer: Sender<Vec<u8>>, max_datagram: usize, stream: TcpStream },
    Frame { conn: u64, kind: u8, payload: Vec<u8> },
    Left { conn: u64 },
    Quit(&'static str),
}

/// One decoded screencast frame at the viewer's size.
pub struct Picture(I420);

/// OpenH264 over decoded pictures.
pub struct H264(OpenH264);

impl FrameEncoder for H264 {
    type Frame = Arc<Picture>;

    fn encode(
        &mut self,
        frame: &Arc<Picture>,
        _damage: Rect,
        force_idr: bool,
        pts_us: i64,
        out: &mut Vec<u8>,
    ) -> Result<bool, String> {
        self.0.encode(&frame.0, force_idr, pts_us, out).map_err(|e| e.to_string())
    }

    fn set_kbps(&mut self, kbps: u32) {
        self.0.set_bitrate(kbps);
    }

    fn kbps(&self) -> u32 {
        self.0.kbps()
    }
}

/// The pixel size of a screen, rounded down to even (I420).
pub fn pixel_size(screen: ScreenSize) -> (u32, u32) {
    let px = |css: u32| ((f64::from(css) * screen.scale).round() as u32).max(16) & !1;
    (px(screen.css_width), px(screen.css_height))
}

/// Decodes a JPEG into an I420 picture of `width` x `height` (even): the
/// image at the top left, cropped or padded black where its size differs
/// (a frame from before a resize).
pub fn jpeg_to_i420(jpeg: &[u8], width: u32, height: u32) -> Result<I420, String> {
    let mut decoder = jpeg_decoder::Decoder::new(jpeg);
    let pixels = decoder.decode().map_err(|e| format!("jpeg: {e}"))?;
    let info = decoder.info().ok_or("jpeg: no header")?;
    let (src_w, src_h) = (usize::from(info.width), usize::from(info.height));
    let channels = match info.pixel_format {
        jpeg_decoder::PixelFormat::RGB24 => 3,
        jpeg_decoder::PixelFormat::L8 => 1,
        other => return Err(format!("jpeg: pixel format {other:?}")),
    };
    let (w, h) = (width as usize, height as usize);
    let mut bgrx = vec![0u8; w * h * 4];
    for row in 0..h.min(src_h) {
        let src = &pixels[row * src_w * channels..(row + 1) * src_w * channels];
        let dst = &mut bgrx[row * w * 4..(row + 1) * w * 4];
        for (px, out) in src.chunks_exact(channels).zip(dst.chunks_exact_mut(4)) {
            let (r, g, b) =
                if channels == 3 { (px[0], px[1], px[2]) } else { (px[0], px[0], px[0]) };
            out.copy_from_slice(&[b, g, r, 255]);
        }
    }
    let mut picture = I420::new(w, h);
    bgrx_rect_to_i420(&bgrx, &mut picture, 0, 0, w, h, convert_threads());
    Ok(picture)
}

fn open_control(screen: ScreenSize) -> Control {
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

struct Viewer {
    conn: u64,
    writer: Sender<Vec<u8>>,
    stream: TcpStream,
    pump: Pump<H264>,
    size: (u32, u32),
}

struct Host {
    tab: HostTab,
    p: CdpPresentation<Chromium>,
    viewer: Option<Viewer>,
    first_frame_seen: bool,
    encoder: EncoderApi,
    t0: Instant,
    once: bool,
    served: bool,
}

fn frame_bytes(kind: u8, payload: &[u8]) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(payload.len() + 5);
    encode_stream_frame(kind, payload, &mut out).ok().map(|()| out)
}

impl Host {
    fn now(&self) -> u64 {
        u64::try_from(self.t0.elapsed().as_micros()).unwrap_or(u64::MAX)
    }

    fn send_rd(&self, control: &RdControl) {
        let Some(v) = &self.viewer else { return };
        if let Ok(json) = serde_json::to_vec(control)
            && let Some(bytes) = frame_bytes(STREAM_CONTROL, &json)
        {
            let _ = v.writer.send(bytes);
        }
    }

    fn send_rb(&self, controls: Vec<Control>) {
        for c in controls {
            let Ok(body) = serde_json::to_value(&c) else { continue };
            self.send_rd(&RdControl::Service { service: SERVICE_REMOTE_BROWSER.into(), body });
        }
    }

    fn apply(&mut self, out: PumpOut) {
        if let Some(v) = &self.viewer {
            for d in &out.datagrams {
                if let Some(bytes) = frame_bytes(STREAM_DATAGRAM, d) {
                    let _ = v.writer.send(bytes);
                }
            }
        }
        if out.release_all {
            self.tab.release_all(&mut self.p);
        }
        for (i, event) in out.input.iter().enumerate() {
            let seq = out.input_seqs.get(i).copied().flatten();
            // A refused event (Blink would drop it) is not an error here.
            let _ = self.tab.input_seq(event, seq, &mut self.p);
        }
    }

    fn joined(
        &mut self,
        conn: u64,
        writer: Sender<Vec<u8>>,
        max_datagram: usize,
        stream: TcpStream,
    ) {
        if self.viewer.is_some() {
            self.left(None);
        }
        let screen = self.tab.session.canonical_screen().unwrap_or(DEFAULT_SCREEN);
        let (width, height) = pixel_size(screen);
        let cfg =
            EncCfg { width, height, fps: FPS, kbps: START_KBPS, threads: 2, screen_content: true };
        let encoder = match (self.encoder)()
            .and_then(|api| OpenH264::new(&cfg, api).map_err(|e| e.to_string()))
        {
            Ok(e) => H264(e),
            Err(e) => {
                eprintln!("serve: encoder: {e}");
                let _ = stream.shutdown(std::net::Shutdown::Both);
                return;
            }
        };
        let engine =
            EngineConfig { width, height, max_fps: FPS, max_datagram, ..EngineConfig::default() };
        let now = self.now();
        self.viewer = Some(Viewer {
            conn,
            writer,
            stream,
            pump: Pump::new(engine, encoder, now),
            size: (width, height),
        });
        self.served = true;
        self.first_frame_seen = false;
        let replies = self.tab.control(VIEWER, &open_control(screen), &mut self.p);
        self.send_rb(replies);
        let out = self.viewer.as_mut().map(|v| v.pump.start(now)).unwrap_or_default();
        self.apply(out);
    }

    fn left(&mut self, conn: Option<u64>) -> bool {
        if conn.is_some_and(|c| self.viewer.as_ref().is_none_or(|v| v.conn != c)) {
            return false;
        }
        drop(self.tab.control(VIEWER, &Control::Close, &mut self.p));
        if let Some(v) = self.viewer.take() {
            let _ = v.stream.shutdown(std::net::Shutdown::Both);
        }
        true
    }

    fn net_frame(&mut self, conn: u64, kind: u8, payload: &[u8]) {
        if self.viewer.as_ref().is_none_or(|v| v.conn != conn) {
            return;
        }
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
                let replies = self.tab.control(VIEWER, &msg, &mut self.p);
                self.send_rb(replies);
            }
            Ok(RdControl::Stop) => self.send_rd(&RdControl::Ended { reason: "stopped".into() }),
            _ => {}
        }
    }

    fn frame(&mut self, browser: i32, jpeg: &[u8], ack: i64) {
        let size = self.viewer.as_ref().map(|v| v.size);
        if let Some((width, height)) = size {
            match jpeg_to_i420(jpeg, width, height) {
                Ok(picture) => {
                    if !self.first_frame_seen {
                        self.first_frame_seen = true;
                        let replies = self.tab.first_frame(&mut self.p);
                        self.send_rb(replies);
                    }
                    let now = self.now();
                    let full = Rect { x: 0, y: 0, width, height };
                    let out = self
                        .viewer
                        .as_mut()
                        .map(|v| v.pump.frame(Arc::new(Picture(picture)), full, now, now))
                        .unwrap_or_default();
                    self.apply(out);
                }
                Err(e) => eprintln!("serve: frame: {e}"),
            }
        }
        // After the encode: Chromium's next frame waits for this.
        self.p.ack_frame(browser, ack);
    }

    /// One message from Chromium. `Err` ends the host.
    fn chromium(&mut self, message: FromChromium) -> Result<(), String> {
        let message = match message {
            FromChromium::Message(m) => m,
            FromChromium::Gone(reason) => return Err(reason),
        };
        for event in self.p.on_message(&message) {
            match event {
                CdpEvent::TabCreated { request, browser } if request == REQUEST => {
                    self.tab.tab_created(browser, &mut self.p);
                }
                CdpEvent::TabCreated { browser, .. } => self.p_close(browser),
                CdpEvent::TabFailed { error, .. } => return Err(format!("open tab: {error}")),
                CdpEvent::Frame { browser, jpeg, ack, .. } => self.frame(browser, &jpeg, ack),
                CdpEvent::Page { change, .. } => {
                    let reply = self.tab.page_changed(change);
                    self.send_rb(reply.into_iter().collect());
                    self.tab.retry_capture(&mut self.p);
                }
                CdpEvent::Dialog { browser, dialog } => {
                    let replies = self.tab.dialog_opened(i64::from(browser), dialog, &mut self.p);
                    self.send_rb(replies);
                }
                CdpEvent::DialogClosed { browser } => {
                    let replies = self.tab.dialog_dropped(i64::from(browser));
                    self.send_rb(replies);
                }
                CdpEvent::Crashed { .. } | CdpEvent::Closed { .. } => {
                    let replies = self.tab.renderer_crashed(&mut self.p);
                    self.send_rb(replies);
                }
            }
        }
        Ok(())
    }

    fn p_close(&mut self, browser: i32) {
        use crate::tab::Presentation as _;
        self.p.close_tab(browser);
    }

    fn deadline(&self) -> Option<u64> {
        self.viewer.as_ref().and_then(|v| v.pump.next_deadline_us())
    }

    fn tick(&mut self) {
        let now = self.now();
        let out = self.viewer.as_mut().map(|v| v.pump.tick(true, now)).unwrap_or_default();
        self.apply(out);
    }
}

fn write_rd(stream: &mut TcpStream, control: &RdControl) -> std::io::Result<()> {
    crate::launch::write_control(stream, control)
}

/// One viewer: the rd handshake, then its frames to the loop until EOF.
fn session(viewer: Admitted, conn: u64, events: &Sender<Event>) -> std::io::Result<String> {
    let Admitted { mut stream, hello, mut deframer } = viewer;
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
    let (width, height) = pixel_size(DEFAULT_SCREEN);
    write_rd(
        &mut stream,
        &RdControl::Welcome {
            encoder: "openh264".into(),
            width,
            height,
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
    let joined = Event::Joined { conn, writer: tx, max_datagram, stream: stream.try_clone()? };
    if events.send(joined).is_err() {
        return Ok("host ended".into());
    }
    let mut buf = vec![0u8; 64 * 1024];
    let reason = loop {
        while let Ok(Some((kind, payload))) = deframer.next_frame() {
            let _ = events.send(Event::Frame { conn, kind, payload });
        }
        match stream.read(&mut buf) {
            Ok(0) => break "viewer left".to_string(),
            Ok(n) => deframer.extend(&buf[..n]),
            Err(e) => break format!("read: {e}"),
        }
    };
    let _ = stream.shutdown(std::net::Shutdown::Both);
    let _ = events.send(Event::Left { conn });
    let _ = writer.join();
    Ok(reason)
}

/// Serves the tab on `listener` until the lifeline ends, Chromium exits, or
/// (`once`) the first viewer leaves. Returns the process exit code.
pub fn run(listener: TcpListener, opts: Options) -> i32 {
    let (events, inbox) = mpsc::channel::<Event>();
    let chromium =
        match Chromium::start(&opts.chromium, &opts.profile, events.clone(), Event::Chromium) {
            Ok(c) => c,
            Err(e) => {
                eprintln!("serve: start {}: {e}", opts.chromium.display());
                return 1;
            }
        };
    eprintln!("serve: chromium pid {} ({})", chromium.pid(), opts.chromium.display());
    if opts.lifeline {
        let quit = events.clone();
        std::thread::spawn(move || {
            let mut stdin = std::io::stdin().lock();
            let mut line = String::new();
            while stdin.read_line(&mut line).is_ok_and(|n| n > 0) {
                line.clear();
            }
            let _ = quit.send(Event::Quit("lifeline closed"));
        });
    }
    let secret: Option<Arc<str>> = opts.secret.clone().map(Arc::from);
    let check: HelloCheck<()> = Arc::new(move |hello| authorize(secret.as_deref(), hello));
    let conns = Arc::new(AtomicU64::new(1));
    let viewers = events.clone();
    std::thread::spawn(move || {
        crate::launch::accept_viewers_each(
            listener,
            HELLO_DEADLINE,
            check,
            Arc::new(move |viewer, ()| {
                let conn = conns.fetch_add(1, Ordering::Relaxed);
                match session(viewer, conn, &viewers) {
                    Ok(reason) => eprintln!("serve: session ended: {reason}"),
                    Err(e) => eprintln!("serve: session failed: {e}"),
                }
            }),
        );
    });
    drop(events);
    let mut host = Host {
        tab: HostTab::new(REQUEST, 1, &opts.url),
        p: CdpPresentation::new(chromium),
        viewer: None,
        first_frame_seen: false,
        encoder: opts.encoder.clone(),
        t0: Instant::now(),
        once: opts.once,
        served: false,
    };
    serve_loop(&mut host, &inbox)
}

fn serve_loop(host: &mut Host, inbox: &Receiver<Event>) -> i32 {
    loop {
        let wait = host.deadline().map_or(Duration::from_secs(1), |d| {
            Duration::from_micros(d.saturating_sub(host.now()))
        });
        match inbox.recv_timeout(wait) {
            Ok(Event::Chromium(message)) => {
                if let Err(reason) = host.chromium(message) {
                    eprintln!("serve: chromium: {reason}");
                    return 1;
                }
            }
            Ok(Event::Joined { conn, writer, max_datagram, stream }) => {
                host.joined(conn, writer, max_datagram, stream);
            }
            Ok(Event::Frame { conn, kind, payload }) => host.net_frame(conn, kind, &payload),
            Ok(Event::Left { conn }) => {
                if host.left(Some(conn)) && host.once && host.served {
                    return 0;
                }
            }
            Ok(Event::Quit(reason)) => {
                eprintln!("serve: {reason}");
                return 0;
            }
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => return 0,
        }
        host.tick();
    }
}
