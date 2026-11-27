//! `cmux-rd surface-source --tab d~<display> --lifeline 1`: this Mac's display as an `sf/1`
//! frame source for cmux-mobile-host's `surface` service (cmux-next-ios
//! `rust/crates/cmux-mobile-host/src/surface.rs`), so a standalone hostd
//! (`CMUX_MOBILE_SURFACE_SOURCE=<this executable>`, `CMUX_MOBILE_MAC_DISPLAY=1`) streams the Mac
//! screen to a phone as rd/1 on its link with no cmux app. The screen-stream-eval `iphone-link`
//! target runs it so; the capture and encode are the `rd` target's own (ScreenCaptureKit,
//! VideoToolbox from the captured IOSurface), so it needs the same Screen Recording grant.
//!
//! The launch contract is hostd's lifeline one: the source's secret is the first stdin line,
//! stdin stays open while hostd wants the source (EOF ends the process), and the source prints
//! `{"listening":"127.0.0.1:PORT"}` once it takes connections. Each connection is one viewer:
//! hostd's `hello {secret}`, then `encode {idr, kbps}` answered by exactly one access unit or
//! `skip`; the source sends `size` first and `damage` when the screen changed.
//!
//! A `d~` tab is view only, so hostd forwards no phone input. For latency measurement only,
//! `CMUX_RD_SURFACE_EVAL_INPUT=127.0.0.1:PORT` with `CMUX_RD_SURFACE_EVAL_TOKEN=T` (both set, a
//! loopback address) opens a UDP socket that injects `T key` (an "a" press) or `T click X Y`
//! (a left click at fractions of the stream, top-left origin) as local input, the way the rd
//! bench's input reaches `cmux-rd host`. The iOS Simulator shares this Mac's loopback, so the
//! eval's phone app sends its samples there.

use crate::args::Opts;
use crate::desktop::{Desktop, FrameSource};
use crate::fdwait::wait_readable;
use crate::stream::SessionCfg;
use crate::Res;
use cmux_rd_core::flow::Rect;
use cmux_rd_proto::InputEvent;
use serde_json::{json, Value};
use std::io::{BufRead, Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream, UdpSocket};
use std::os::fd::AsRawFd;
use std::sync::mpsc::{channel, Receiver};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// An sf/1 frame's largest payload (hostd's `MAX_SOURCE_FRAME`).
const MAX_FRAME: usize = 8 * 1024 * 1024;
/// HID usage of the "a" key (the marker page counts it).
const KEY_A: u32 = 0x0007_0004;

/// The clock hostd stamps frames with (`surface_clock_us`): CLOCK_UPTIME_RAW in µs.
fn surface_clock_us() -> u64 {
    let mut now = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    // SAFETY: `now` is a valid timespec to write, and the clock id is valid.
    unsafe { libc::clock_gettime(libc::CLOCK_UPTIME_RAW, &mut now) };
    now.tv_sec as u64 * 1_000_000 + now.tv_nsec as u64 / 1000
}

/// The capture `--display` a `d~<display>` tab names: `main` for 0, else `id:<CGDirectDisplayID>`.
pub fn display_of(tab: &str) -> Option<String> {
    let digits = tab.strip_prefix("d~")?;
    if digits.is_empty() || digits.len() > 10 || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    if digits.len() > 1 && digits.starts_with('0') {
        return None;
    }
    let id: u32 = digits.parse().ok()?;
    Some(if id == 0 { "main".to_owned() } else { format!("id:{id}") })
}

/// One eval input datagram: `TOKEN key` or `TOKEN click X Y` (fractions of the stream).
pub fn eval_input(datagram: &[u8], token: &str, size: (u32, u32)) -> Option<Vec<InputEvent>> {
    let text = std::str::from_utf8(datagram).ok()?;
    let mut words = text.split_ascii_whitespace();
    if !equal_secrets(words.next()?, token) {
        return None;
    }
    match words.next()? {
        "key" => Some(vec![
            InputEvent::Key { usage: KEY_A, down: true },
            InputEvent::Key { usage: KEY_A, down: false },
        ]),
        "click" => {
            let unit = |w: Option<&str>| {
                w?.parse::<f64>().ok().filter(|v| v.is_finite()).map(|v| v.clamp(0.0, 1.0))
            };
            let (x, y) = (unit(words.next())?, unit(words.next())?);
            let x = (x * f64::from(size.0.saturating_sub(1))).round() as i32;
            let y = (y * f64::from(size.1.saturating_sub(1))).round() as i32;
            Some(vec![
                InputEvent::Pointer { x, y },
                InputEvent::Button { button: 0, down: true },
                InputEvent::Button { button: 0, down: false },
            ])
        }
        _ => None,
    }
}

fn equal_secrets(a: &str, b: &str) -> bool {
    a.len() == b.len() && a.bytes().zip(b.bytes()).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

fn frame(kind: u8, payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(5 + payload.len());
    out.push(kind);
    out.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    out.extend_from_slice(payload);
    out
}

fn json_frame(value: &Value) -> Vec<u8> {
    frame(1, &serde_json::to_vec(value).unwrap_or_default())
}

fn access_unit(idr: bool, capture_us: u64, annex_b: &[u8]) -> Vec<u8> {
    let mut payload = Vec::with_capacity(9 + annex_b.len());
    payload.push(u8::from(idr));
    payload.extend_from_slice(&capture_us.to_be_bytes());
    payload.extend_from_slice(annex_b);
    frame(2, &payload)
}

/// Reads sf/1 JSON frames out of a byte stream (hostd sends only JSON).
#[derive(Default)]
pub struct Deframer {
    buffer: Vec<u8>,
}

impl Deframer {
    pub fn extend(&mut self, bytes: &[u8]) {
        self.buffer.extend_from_slice(bytes);
    }

    pub fn next_json(&mut self) -> Result<Option<Value>, String> {
        if self.buffer.len() < 5 {
            return Ok(None);
        }
        let len =
            u32::from_be_bytes([self.buffer[1], self.buffer[2], self.buffer[3], self.buffer[4]])
                as usize;
        if len > MAX_FRAME {
            return Err("an sf/1 frame over the limit".into());
        }
        if self.buffer.len() < 5 + len {
            return Ok(None);
        }
        let kind = self.buffer[0];
        let payload: Vec<u8> = self.buffer.drain(..5 + len).skip(5).collect();
        if kind != 1 {
            return Err(format!("an sf/1 frame of kind {kind} from hostd"));
        }
        serde_json::from_slice(&payload).map(Some).map_err(|_| "sf/1 JSON".to_owned())
    }
}

fn session_cfg(display: String, opts: &Opts) -> Res<SessionCfg> {
    let max_fps = match opts.get("max-fps") {
        Some(_) => opts.num_or("max-fps", 60)?,
        None => crate::desktop::default_max_fps(&display),
    };
    Ok(SessionCfg {
        display,
        display_pick: None,
        window: None,
        max_fps,
        encode_profile: cmux_rd_core::profile::EncodeProfile::Standard,
        start_kbps: opts.num_or("start-kbps", 8000)?,
        max_kbps: opts.num_or("max-kbps", 50_000)?,
        pin_kbps: None,
        preset: "ultrafast".into(),
        profile: opts.str_or("profile", "high"),
        codec: "videotoolbox".into(),
        openh264_lib: None,
        content: "screen".into(),
        threads: 1,
        stats_every_ms: 1000,
        settle_us: 0,
        upstream_record: None,
        upstream_record_max_bytes: 0,
        frames_in_flight: 2,
        input_frame_now: false,
        ltr: false,
        rtt_tail_probe: false,
        resolution_ladder: false,
        max_qp: cmux_rd_core::resolution::DEFAULT_MAX_QP,
        max_width: opts
            .get("max-width")
            .map(|w| w.parse().map_err(|_| format!("--max-width {w}: a pixel count")))
            .transpose()?,
        show_cursor: true,
        capture: crate::capture_backend::CaptureBackend::default(),
        sharp_text: false,
    })
}

/// The eval's input socket, when both of its variables are set.
fn eval_socket() -> Res<Option<(UdpSocket, String)>> {
    let (Ok(addr), Ok(token)) =
        (std::env::var("CMUX_RD_SURFACE_EVAL_INPUT"), std::env::var("CMUX_RD_SURFACE_EVAL_TOKEN"))
    else {
        return Ok(None);
    };
    let addr: SocketAddr =
        addr.parse().map_err(|_| format!("CMUX_RD_SURFACE_EVAL_INPUT {addr}: an address"))?;
    if !addr.ip().is_loopback() || token.len() < 16 {
        return Err("CMUX_RD_SURFACE_EVAL_INPUT must be loopback, with a token of 16+ bytes".into());
    }
    let socket = UdpSocket::bind(addr)?;
    socket.set_nonblocking(true)?;
    Ok(Some((socket, token)))
}

pub fn run(opts: &Opts) -> Res<()> {
    let tab = opts.get("tab").ok_or("--tab d~<display> is required")?;
    let display = display_of(tab).ok_or_else(|| format!("--tab {tab}: not a d~<display> tab"))?;
    let cfg = session_cfg(display, opts)?;
    let stdin = std::io::stdin();
    let mut secret = String::new();
    stdin.lock().read_line(&mut secret)?;
    let secret = secret.trim().to_owned();
    if secret.is_empty() {
        return Err("no secret on stdin".into());
    }
    // hostd holds stdin open while it wants this source; its end (or hostd's) ends us.
    let lifeline = opts.flag("lifeline");
    let eval = Arc::new(Mutex::new(eval_socket()?));
    let listener = TcpListener::bind("127.0.0.1:0")?;
    let mut out = std::io::stdout();
    writeln!(out, "{}", json!({"listening": listener.local_addr()?.to_string()}))?;
    out.flush()?;
    // One viewer at a time: hostd connects once per phone viewer of the tab, and a second
    // capture of the same display would only double the work.
    listener.set_nonblocking(true)?;
    loop {
        let mut fds = vec![listener.as_raw_fd()];
        if lifeline {
            fds.push(0);
        }
        wait_readable(&fds, None)?;
        if lifeline_closed(lifeline) {
            return Ok(());
        }
        let stream = match listener.accept() {
            Ok((stream, _)) => stream,
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => continue,
            Err(error) => {
                eprintln!("cmux-rd surface-source: accept: {error}");
                continue;
            }
        };
        // An accepted socket inherits the listener's O_NONBLOCK on macOS.
        stream.set_nonblocking(false)?;
        if let Err(error) = session(stream, &secret, &cfg, &eval, lifeline) {
            eprintln!("cmux-rd surface-source: session ended: {error}");
        }
    }
}

/// With `--lifeline`: whether hostd closed this source's stdin (it no longer wants the source).
/// hostd writes nothing after the secret line, so a readable stdin is its end.
fn lifeline_closed(lifeline: bool) -> bool {
    if !lifeline {
        return false;
    }
    let mut pfd = libc::pollfd { fd: 0, events: libc::POLLIN, revents: 0 };
    // SAFETY: one valid pollfd for the call.
    if unsafe { libc::poll(&mut pfd, 1, 0) } <= 0 {
        return false;
    }
    let mut sink = [0u8; 256];
    // SAFETY: the buffer is valid for its length.
    let n = unsafe { libc::read(0, sink.as_mut_ptr().cast(), sink.len()) };
    n == 0 || (n < 0 && std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted)
}

/// One encode hostd asked for.
struct Job {
    idr: bool,
    kbps: u32,
}

fn session(
    mut stream: TcpStream,
    secret: &str,
    cfg: &SessionCfg,
    eval: &Mutex<Option<(UdpSocket, String)>>,
    lifeline: bool,
) -> Res<()> {
    stream.set_nodelay(true)?;
    stream.set_read_timeout(Some(Duration::from_secs(10)))?;
    let mut deframer = Deframer::default();
    let mut buffer = vec![0u8; 64 * 1024];
    let hello = loop {
        if let Some(value) = deframer.next_json()? {
            break value;
        }
        let n = stream.read(&mut buffer)?;
        if n == 0 {
            return Err("hostd closed before its hello".into());
        }
        deframer.extend(&buffer[..n]);
    };
    if hello["t"] != "hello" || !equal_secrets(hello["secret"].as_str().unwrap_or(""), secret) {
        return Err("unauthorized".into());
    }
    stream.set_read_timeout(None)?;
    let writer = Arc::new(Mutex::new(stream.try_clone()?));
    let send = |bytes: &[u8]| -> Res<()> {
        writer.lock().map_err(|_| "writer poisoned")?.write_all(bytes)?;
        Ok(())
    };
    let (mut desktop, source) = match crate::desktop::open(cfg, false, cfg.ltr) {
        Ok(halves) => halves,
        Err(error) => {
            let _ = send(&json_frame(&json!({"t": "error", "message": error.to_string()})));
            return Err(error);
        }
    };
    desktop.ready_for_start()?;
    let (width, height) = desktop.size();
    send(&json_frame(&json!({"t": "size", "width": width, "height": height})))?;
    send(&json_frame(&json!({"t": "damage"})))?;
    let (jobs, job_rx) = channel::<Job>();
    let encode_writer = Arc::clone(&writer);
    let encoder = std::thread::Builder::new()
        .name("cmux-rd-surface-encode".into())
        .spawn(move || encode_loop(source, job_rx, encode_writer, (width, height)))?;
    let eval = eval.lock().map_err(|_| "eval socket poisoned")?;
    let mut rects = Vec::new();
    let result = loop {
        let mut fds = vec![stream.as_raw_fd(), desktop.fd()];
        if let Some((socket, _)) = eval.as_ref() {
            fds.push(socket.as_raw_fd());
        }
        if lifeline {
            fds.push(0);
        }
        wait_readable(&fds, Some(1_000_000_000))?;
        if lifeline_closed(lifeline) {
            break Ok(());
        }
        rects.clear();
        desktop.drain(&mut rects)?;
        if !rects.is_empty() {
            send(&json_frame(&json!({"t": "damage"})))?;
        }
        if let Some((socket, token)) = eval.as_ref() {
            let mut datagram = [0u8; 256];
            while let Ok(n) = socket.recv(&mut datagram) {
                for event in eval_input(&datagram[..n], token, (width, height)).unwrap_or_default()
                {
                    desktop.inject(&event)?;
                }
            }
        }
        stream.set_nonblocking(true)?;
        let read = stream.read(&mut buffer);
        stream.set_nonblocking(false)?;
        match read {
            Ok(0) => break Ok(()),
            Ok(n) => deframer.extend(&buffer[..n]),
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
            Err(error) => break Err(error.into()),
        }
        let mut stop = None;
        while let Some(line) = deframer.next_json()? {
            if line["t"] == "encode" {
                let job = Job {
                    idr: line["idr"].as_bool().unwrap_or(false),
                    kbps: line["kbps"].as_u64().and_then(|k| u32::try_from(k).ok()).unwrap_or(0),
                };
                if jobs.send(job).is_err() {
                    stop = Some(Err("the encode thread ended".into()));
                    break;
                }
            }
            // `visible` and input lines: a view-only display source has nothing to do with them.
        }
        if let Some(stop) = stop {
            break stop;
        }
    };
    let _ = desktop.release_all();
    drop(jobs);
    let _ = encoder.join();
    result
}

fn encode_loop(
    mut source: Box<dyn FrameSource>,
    jobs: Receiver<Job>,
    writer: Arc<Mutex<TcpStream>>,
    (width, height): (u32, u32),
) {
    let full = Rect { x: 0, y: 0, width, height };
    let mut out = Vec::new();
    while let Ok(job) = jobs.recv() {
        if job.kbps > 0 {
            source.set_bitrate(job.kbps);
        }
        out.clear();
        let captured = source.capture(full).map(|()| surface_clock_us());
        let answer = match captured.and_then(|capture_us| {
            source.encode(job.idr, capture_us as i64, &mut out).map(|idr| (idr, capture_us))
        }) {
            Ok((idr, capture_us)) if !out.is_empty() => access_unit(idr, capture_us, &out),
            Ok(_) => json_frame(&json!({"t": "skip"})),
            Err(error) => {
                eprintln!("cmux-rd surface-source: encode: {error}");
                json_frame(&json!({"t": "skip"}))
            }
        };
        let Ok(mut writer) = writer.lock() else { return };
        if writer.write_all(&answer).is_err() {
            return;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn display_tabs_map_to_capture_displays() {
        assert_eq!(display_of("d~0").as_deref(), Some("main"));
        assert_eq!(display_of("d~69734272").as_deref(), Some("id:69734272"));
        for bad in ["d~", "d~01", "d~-1", "s3", "d~99999999999"] {
            assert_eq!(display_of(bad), None, "{bad}");
        }
    }

    #[test]
    fn eval_input_needs_the_token() {
        let token = "0123456789abcdef";
        assert_eq!(eval_input(b"0123456789abcdef key", token, (100, 50)).map(|v| v.len()), Some(2));
        assert!(eval_input(b"0123456789abcdeX key", token, (100, 50)).is_none());
        let click = eval_input(b"0123456789abcdef click 0.5 1", token, (101, 51)).unwrap();
        assert!(matches!(click[0], InputEvent::Pointer { x: 50, y: 50 }));
        assert!(eval_input(b"0123456789abcdef click nan 1", token, (101, 51)).is_none());
    }

    #[test]
    fn deframer_reads_json_frames() {
        let mut d = Deframer::default();
        let bytes = json_frame(&json!({"t": "encode", "idr": true, "kbps": 9000}));
        d.extend(&bytes[..3]);
        assert_eq!(d.next_json().unwrap(), None);
        d.extend(&bytes[3..]);
        assert_eq!(d.next_json().unwrap().unwrap()["kbps"], 9000);
        let mut bad = Deframer::default();
        bad.extend(&access_unit(true, 1, &[0, 0, 0, 1]));
        assert!(bad.next_json().is_err());
    }
}
