//! `cmux-remote-browser-testhost`: a test-only remote browser tab host.
//!
//! It listens on 127.0.0.1 only, accepts one viewer at a time over the rd
//! stream carrier (one TCP connection, `u8 kind, u32 len` frames), answers a
//! `hello` for service `rb/1` with `welcome` and `started`, sends
//! `rb.opened`, and then streams synthetic H.264 frames of a moving bar
//! through the shared rd engine (packetize, FEC, congestion control). It
//! exists so the Mac client (CmuxNextRemoteBrowser) is proven over the real
//! wire before the CEF host (cmux-remote-browser-host) streams.
//!
//! It also plays a tiny page for the Mac client's GUI proof: a right-click
//! (rb pointer `down`, button 2) opens a context menu (`rb.menu.show`), a
//! Cmd-click (button 0 with the Command modifier) opens a background tab
//! (`rb.open_tab`), and `rb.navigate` answers with `rb.page` for that URL.
//!
//! Usage: cmux-remote-browser-testhost [--port 4103] [--width 1280]
//!        [--height 720] [--fps 30] [--frames 0] [--once]
//! `--frames N` stops after N frames (0 = until the viewer leaves);
//! `--once` exits after the first viewer.

use std::io::{Read, Write};
use std::net::{Ipv4Addr, TcpListener, TcpStream};
use std::process::ExitCode;
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::thread;
use std::time::{Duration, Instant};

use cmux_encode::openh264::{OpenH264, OpenH264Api};
use cmux_encode::{EncCfg, H264Encoder, I420};
use cmux_rd_core::service::negotiate;
use cmux_rd_engine::{EncodeRequest, Encoded, EngineConfig, MediaEngine, Output};
use cmux_rd_proto::InputEvent;
use cmux_rd_proto::control::Control;
use cmux_rd_proto::{
    MAX_DATAGRAM_DEFAULT, OVERLAY_PORT, SERVICE_REMOTE_BROWSER, STREAM_CONTROL, STREAM_DATAGRAM,
    StreamDeframer, encode_stream_frame,
};
use serde_json::{Value, json};

type Res<T> = Result<T, Box<dyn std::error::Error + Send + Sync>>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Options {
    port: u16,
    width: u32,
    height: u32,
    fps: u32,
    frames: u64,
    once: bool,
}

fn parse(args: &[String]) -> Result<Options, String> {
    let mut o =
        Options { port: OVERLAY_PORT, width: 1280, height: 720, fps: 30, frames: 0, once: false };
    let mut it = args.iter();
    while let Some(flag) = it.next() {
        if flag == "--once" {
            o.once = true;
            continue;
        }
        let value = it.next().ok_or_else(|| format!("{flag}: missing value"))?;
        let number = |v: &str| v.parse::<u64>().map_err(|_| format!("{flag}: expected a number"));
        match flag.as_str() {
            "--port" => o.port = u16::try_from(number(value)?).map_err(|_| "--port: too large")?,
            "--width" => {
                o.width = u32::try_from(number(value)?).map_err(|_| "--width: too large")?
            }
            "--height" => {
                o.height = u32::try_from(number(value)?).map_err(|_| "--height: too large")?
            }
            "--fps" => o.fps = u32::try_from(number(value)?).map_err(|_| "--fps: too large")?,
            "--frames" => o.frames = number(value)?,
            other => return Err(format!("unknown option {other}")),
        }
    }
    if o.port < 1024
        || o.width < 16
        || o.height < 16
        || !o.width.is_multiple_of(2)
        || !o.height.is_multiple_of(2)
        || o.fps == 0
    {
        return Err("need port >= 1024, even width and height >= 16, fps > 0".into());
    }
    Ok(o)
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let options = match parse(&args) {
        Ok(o) => o,
        Err(e) => {
            eprintln!("cmux-remote-browser-testhost: {e}");
            return ExitCode::from(2);
        }
    };
    match serve(options) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("cmux-remote-browser-testhost: {e}");
            ExitCode::FAILURE
        }
    }
}

fn serve(o: Options) -> Res<()> {
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, o.port))?;
    eprintln!("listening on 127.0.0.1:{} (service {SERVICE_REMOTE_BROWSER})", o.port);
    for conn in listener.incoming() {
        let conn = conn?;
        conn.set_nodelay(true)?;
        match session(conn, o) {
            Ok(reason) => eprintln!("session ended: {reason}"),
            Err(e) => eprintln!("session failed: {e}"),
        }
        if o.once {
            break;
        }
    }
    Ok(())
}

fn write_frame(stream: &mut TcpStream, kind: u8, payload: &[u8]) -> Res<()> {
    let mut out = Vec::with_capacity(payload.len() + 5);
    encode_stream_frame(kind, payload, &mut out).map_err(|e| format!("frame: {e:?}"))?;
    stream.write_all(&out)?;
    Ok(())
}

fn write_control(stream: &mut TcpStream, control: &Control) -> Res<()> {
    write_frame(stream, STREAM_CONTROL, &serde_json::to_vec(control)?)
}

/// Frames read from the viewer, from a reader thread (EOF ends the stream).
fn reader(mut stream: TcpStream) -> Receiver<(u8, Vec<u8>)> {
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let mut deframer = StreamDeframer::default();
        let mut buf = [0u8; 16 * 1024];
        loop {
            let n = match stream.read(&mut buf) {
                Ok(0) | Err(_) => return,
                Ok(n) => n,
            };
            deframer.extend(&buf[..n]);
            while let Ok(Some(frame)) = deframer.next_frame() {
                if tx.send(frame).is_err() {
                    return;
                }
            }
        }
    });
    rx
}

fn session(mut stream: TcpStream, o: Options) -> Res<String> {
    let frames = reader(stream.try_clone()?);
    let hello = loop {
        let (kind, payload) =
            frames.recv_timeout(Duration::from_secs(10)).map_err(|_| "no hello within 10 s")?;
        if kind == STREAM_CONTROL {
            break serde_json::from_slice::<Control>(&payload)?;
        }
    };
    let Control::Hello { service, caps, max_datagram, .. } = hello else {
        return Err("the first control message is not hello".into());
    };
    let negotiated = match negotiate(&service, &caps, &[SERVICE_REMOTE_BROWSER], &[]) {
        Ok(n) => n,
        Err(refusal) => {
            write_control(&mut stream, &Control::Refused { reason: refusal.reason().into() })?;
            return Ok(format!("refused hello for service {service}"));
        }
    };
    let max_datagram = max_datagram.clamp(512, MAX_DATAGRAM_DEFAULT);
    write_control(
        &mut stream,
        &Control::Welcome {
            encoder: "openh264-test".into(),
            width: o.width,
            height: o.height,
            max_datagram,
            carrier: "stream".into(),
            service: negotiated.service.clone(),
            caps: negotiated.caps.clone(),
        },
    )?;
    write_control(&mut stream, &Control::Started { session: 1 })?;
    write_control(
        &mut stream,
        &Control::Service {
            service: negotiated.service,
            body: serde_json::json!({"t": "rb.opened", "session": 1, "main_stream": 0}),
        },
    )?;
    stream_frames(&mut stream, &frames, o, max_datagram)
}

fn stream_frames(
    stream: &mut TcpStream,
    frames: &Receiver<(u8, Vec<u8>)>,
    o: Options,
    max_datagram: usize,
) -> Res<String> {
    let t0 = Instant::now();
    let now = || u64::try_from(t0.elapsed().as_micros()).unwrap_or(u64::MAX);
    let cfg = EngineConfig {
        width: o.width,
        height: o.height,
        max_fps: o.fps,
        max_datagram,
        ..EngineConfig::default()
    };
    let mut engine = MediaEngine::new(cfg, now());
    let mut encoder = OpenH264::new(
        &EncCfg {
            width: o.width,
            height: o.height,
            fps: o.fps,
            kbps: 4000,
            threads: 1,
            screen_content: true,
        },
        OpenH264Api::from_source(),
    )?;
    let mut picture = I420::new(o.width as usize, o.height as usize);
    let interval = Duration::from_micros(1_000_000 / u64::from(o.fps));
    let mut next_paint = Instant::now();
    let mut painted: u64 = 0;
    let mut pending = engine.start(now());
    let mut page = Page::default();
    loop {
        if let Some(req) = pending.take() {
            let out = encode_one(&mut engine, &mut encoder, &mut picture, &req, painted, now())?;
            pending = send(stream, out)?;
        }
        if o.frames > 0 && painted >= o.frames {
            return Ok(format!("sent {painted} frames"));
        }
        let wait = next_paint.saturating_duration_since(Instant::now());
        let deadline =
            engine.next_deadline_us().map(|d| Duration::from_micros(d.saturating_sub(now())));
        match frames.recv_timeout(deadline.map_or(wait, |d| d.min(wait))) {
            Ok((STREAM_DATAGRAM, datagram)) => {
                let out = engine.on_datagram(&datagram, true, now());
                for event in &out.inject {
                    if let InputEvent::Service { bytes, .. } = event
                        && let Some(reply) = page.input(bytes)
                    {
                        write_service(stream, reply)?;
                    }
                }
                pending = pending.or(send(stream, out)?);
            }
            Ok((_, control)) => match serde_json::from_slice::<Control>(&control) {
                Ok(Control::Stop) => {
                    write_control(stream, &Control::Ended { reason: "stopped".into() })?;
                    return Ok("viewer stopped".into());
                }
                Ok(Control::Service { body, .. }) => {
                    if let Some(reply) = page.control(&body) {
                        write_service(stream, reply)?;
                    }
                }
                _ => {}
            },
            Err(RecvTimeoutError::Disconnected) => return Ok("viewer left".into()),
            Err(RecvTimeoutError::Timeout) => {}
        }
        let out = engine.tick(false, now());
        pending = pending.or(send(stream, out)?);
        if Instant::now() >= next_paint {
            next_paint += interval;
            painted += 1;
            let full = cmux_rd_core::flow::Rect { x: 0, y: 0, width: o.width, height: o.height };
            pending = pending.or(engine.damage(0, full, now()));
        }
    }
}

fn write_service(stream: &mut TcpStream, body: Value) -> Res<()> {
    let service = SERVICE_REMOTE_BROWSER.to_string();
    write_control(stream, &Control::Service { service, body })
}

/// rb modifier bit of the Command key (`cmux_remote_browser::proto::modifiers`).
const MOD_COMMAND: u64 = 1 << 3;

/// The test page's answers to viewer input and control messages. Tokens and
/// requests count up from 1.
#[derive(Debug, Default)]
struct Page {
    menus: u64,
    tabs: u64,
}

impl Page {
    /// One rb input event (JSON in an rd service event).
    fn input(&mut self, bytes: &[u8]) -> Option<Value> {
        let event: Value = serde_json::from_slice(bytes).ok()?;
        if event["e"] != "pointer" || event["kind"] != "down" {
            return None;
        }
        let (x, y) = (event["x"].as_f64()?, event["y"].as_f64()?);
        match event["button"].as_u64()? {
            2 => {
                self.menus += 1;
                let item = |id: i64, label: &str| json!({"id": id, "type": "command", "label": label, "enabled": true, "checked": false, "items": []});
                Some(json!({"t": "rb.menu.show", "token": self.menus, "menu": {
                    "kind": "context", "anchor": {"x": x, "y": y, "width": 0.0, "height": 0.0}, "surface": 0,
                    "items": [item(100, "Back"), item(102, "Reload"),
                              {"id": -1, "type": "separator", "label": "", "enabled": true, "checked": false, "items": []},
                              item(50150, "Copy")],
                    "selected": null, "multiple": false, "right_aligned": false}}))
            }
            0 if event["modifiers"].as_u64()? & MOD_COMMAND != 0 => {
                self.tabs += 1;
                Some(json!({"t": "rb.open_tab", "request": self.tabs,
                    "url": format!("https://example.com/link-{}", self.tabs),
                    "disposition": "background_tab", "user_gesture": true}))
            }
            _ => None,
        }
    }

    /// One rb control message from the viewer.
    fn control(&mut self, body: &Value) -> Option<Value> {
        if body["t"] != "rb.navigate" {
            return None;
        }
        let url = body["url"].as_str()?;
        Some(json!({"t": "rb.page", "url": url, "title": format!("Test host: {url}"),
            "loading": false, "can_go_back": true, "can_go_forward": false}))
    }
}

/// Paints frame `n` (a bar that moves 8 px per frame on gray) and encodes it.
fn encode_one(
    engine: &mut MediaEngine,
    encoder: &mut OpenH264,
    picture: &mut I420,
    req: &EncodeRequest,
    n: u64,
    now_us: u64,
) -> Res<Output> {
    paint(picture, n);
    let mut access_unit = Vec::new();
    let pts = i64::try_from(now_us).unwrap_or(i64::MAX);
    let idr = encoder.encode(picture, req.force_idr, pts, &mut access_unit)?;
    let encoded = Encoded { access_unit, idr, t_capture_us: now_us };
    engine.encoded(req, Some(encoded), now_us).map_err(|e| format!("packetize: {e:?}").into())
}

fn paint(picture: &mut I420, n: u64) {
    let width = picture.width;
    picture.y.fill(96);
    picture.u.fill(128);
    picture.v.fill(128);
    let bar = usize::try_from((n * 8) % width as u64).unwrap_or(0);
    for row in picture.y.chunks_mut(width) {
        let end = (bar + 32).min(width);
        row[bar..end].fill(235);
    }
}

/// Writes the datagrams of `out` and returns its next encode request.
fn send(stream: &mut TcpStream, out: Output) -> Res<Option<EncodeRequest>> {
    for datagram in &out.datagrams {
        write_frame(stream, STREAM_DATAGRAM, datagram)?;
    }
    Ok(out.encode)
}

#[cfg(test)]
mod tests;
