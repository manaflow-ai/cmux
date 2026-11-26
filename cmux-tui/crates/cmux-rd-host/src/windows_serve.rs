//! `cmux-rd serve` on Windows: one device hub session over the secure link, with the same JSON
//! lines as the Unix `serve` (src/serve.rs: the setup line, then candidates or `stop` on stdin;
//! the displays, this side's session key, candidates, `connected`, path changes and `ended` on
//! stdout), driven by `windows-host run` (cmux-hub-host's session.rs) the way the Mac app and
//! `linux-host run` drive theirs.
//!
//! The Unix `serve` waits on file descriptors (stdin, the link's event pipe); here a thread
//! reads stdin into a channel and the loop waits on the link (`Net::wait`, a loopback socket
//! under `WSAPoll`) at most until the next frame or [`APP_POLL`]. The media is the Windows
//! session of `cmux-rd host` (GDI capture, OpenH264, SendInput: src/windows/session.rs) over
//! the link instead of a TCP stream. A `view` scope starts the session in view mode whatever
//! the viewer asks: the engine applies no input and nothing is injected.

use crate::args::Opts;
use crate::encoder::{self, EncCfg};
use crate::windows::{GdiCapture, Incoming, WindowsSession, Wire};
use crate::Res;
use cmux_rd_core::policy::{ConsentRule, HostPolicy, Mode, Principal, PrincipalClass};
use cmux_rd_core::service::{negotiate, SERVICE_DESKTOP};
use cmux_rd_core::session::{Actor, SessionTable, StartRequest};
use cmux_rd_link::net::{Candidate, Net, NetConfig, NetEvent, TurnServer};
use cmux_rd_link::{EndpointEvent, Event, KeyPair, Role};
use cmux_rd_proto::app_line::{AppLine, LinePath};
use cmux_rd_proto::control::Control;
use serde::Deserialize;
use std::io::{self, BufRead, Write};
use std::net::SocketAddr;
use std::sync::mpsc::{self, Receiver, TryRecvError};
use std::time::{Duration, Instant};

mod selftest;
pub use selftest::run as selftest;

/// How long the viewer has to connect and say hello after the host starts.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(30);
/// The rd datagram inside the link: as the Unix `serve` (one 1280-byte IPv6 minimum MTU path
/// with headroom for a relay's framing, minus the seal).
const MAX_DATAGRAM: usize = 1152 - cmux_rd_link::SEAL_OVERHEAD;
/// The longest the loop waits before it reads the app's lines again (they do not wake the link).
const APP_POLL: Duration = Duration::from_millis(20);

#[derive(Deserialize)]
struct Viewer {
    user: String,
    install: String,
}

#[derive(Deserialize)]
struct Turn {
    addr: String,
    username: String,
    password: String,
}

/// The setup line (the Unix `serve`'s; `display` and `capture` are not used: GDI captures
/// the whole virtual screen).
#[derive(Deserialize)]
struct Setup {
    session: String,
    peer_key: String,
    viewer: Viewer,
    scope: String,
    #[serde(default)]
    stun: Vec<String>,
    #[serde(default)]
    turn: Vec<Turn>,
    #[serde(default)]
    max_fps: Option<u32>,
    #[serde(default)]
    relay_only: bool,
}

#[derive(Deserialize)]
struct Later {
    #[serde(default)]
    candidate: Option<String>,
    #[serde(default)]
    stop: bool,
}

/// Prints one line for the driver.
fn say(line: AppLine) {
    let mut out = io::stdout().lock();
    let _ = writeln!(out, "{}", line.to_json());
    let _ = out.flush();
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn unhex32(text: &str) -> Option<[u8; 32]> {
    let text = text.trim();
    if text.len() != 64 {
        return None;
    }
    let mut out = [0u8; 32];
    for (i, byte) in out.iter_mut().enumerate() {
        *byte = u8::from_str_radix(text.get(2 * i..2 * i + 2)?, 16).ok()?;
    }
    Some(out)
}

/// The first IPv4 address `host:port` resolves to.
fn resolve(text: &str) -> Option<SocketAddr> {
    std::net::ToSocketAddrs::to_socket_addrs(text).ok()?.find(SocketAddr::is_ipv4)
}

/// Whether a session with the setup line's `scope` starts view only (Windows applies input
/// through SendInput, so `control` is control).
fn view_only_for(scope: &str) -> Res<bool> {
    match scope {
        "view" => Ok(true),
        "control" => Ok(false),
        other => Err(format!("scope {other}: use view or control").into()),
    }
}

/// The app's lines: a thread reads stdin, so the session loop never blocks on it.
fn app_lines() -> Receiver<String> {
    let (tx, rx) = mpsc::channel();
    let _ = std::thread::Builder::new().name("rd-serve-stdin".into()).spawn(move || {
        for line in io::stdin().lock().lines() {
            let Ok(line) = line else { break };
            if tx.send(line).is_err() {
                break;
            }
        }
    });
    rx
}

/// The secure link and the app's lines, as the session's [`Wire`].
struct LinkWire {
    net: Net,
    app: Receiver<String>,
}

impl LinkWire {
    /// Applies the app's lines: candidates go to the link; `stop` or the end of input ends it.
    fn pump_app(&mut self) -> Result<(), String> {
        loop {
            match self.app.try_recv() {
                Ok(line) => {
                    let Ok(later) = serde_json::from_str::<Later>(&line) else { continue };
                    if later.stop {
                        return Err("stopped by the host".into());
                    }
                    if let Some(c) = later.candidate.as_deref().and_then(Candidate::from_wire) {
                        self.net.add_remote_candidate(c);
                    }
                }
                Err(TryRecvError::Empty) => return Ok(()),
                Err(TryRecvError::Disconnected) => {
                    return Err("the app closed the session's input".into())
                }
            }
        }
    }

    /// One link event: what the driver must hear (candidates, connected, path) goes to stdout;
    /// what the session must hear goes to `out`.
    fn on_event(&mut self, event: NetEvent, out: &mut Vec<Incoming>) -> Result<(), String> {
        match event {
            NetEvent::Candidate(c) => {
                say(AppLine { candidate: Some(c.to_wire()), ..AppLine::default() })
            }
            NetEvent::CandidatesDone => {
                say(AppLine { candidates_done: true, ..AppLine::default() })
            }
            NetEvent::Endpoint(EndpointEvent::Link(Event::Established)) => {
                say(AppLine { connected: true, ..AppLine::default() })
            }
            NetEvent::Endpoint(EndpointEvent::Link(Event::Datagram(d))) => {
                out.push(Incoming::Datagram(d));
            }
            NetEvent::Endpoint(EndpointEvent::Link(Event::Control(record))) => {
                if let Ok(control) = serde_json::from_slice::<Control>(&record) {
                    out.push(Incoming::Control(control));
                }
            }
            NetEvent::Endpoint(EndpointEvent::Link(Event::Closed)) => {
                return Err("viewer closed the link".into());
            }
            NetEvent::Endpoint(EndpointEvent::PathChanged { kind, rtt_us, .. }) => {
                say(AppLine {
                    path: Some(LinePath {
                        kind: kind.map(|k| k.wire_name().to_owned()),
                        rtt_ms: rtt_us.map(|us| us as f64 / 1000.0),
                    }),
                    ..AppLine::default()
                });
            }
            NetEvent::Failed(reason) => return Err(format!("link failed: {reason}")),
            _ => {}
        }
        Ok(())
    }
}

impl Wire for LinkWire {
    fn receive(&mut self, out: &mut Vec<Incoming>) -> Res<bool> {
        self.pump_app()?;
        for event in self.net.events() {
            self.on_event(event, out)?;
        }
        Ok(true)
    }

    fn send_datagram(&mut self, datagram: &[u8]) -> Res<()> {
        self.net.send_datagram(datagram.to_vec());
        Ok(())
    }

    fn send_control(&mut self, control: &Control) -> Res<()> {
        self.net.send_control(serde_json::to_vec(control)?);
        Ok(())
    }

    fn wait(&mut self, limit: Duration) {
        self.net.wait(Some(limit.min(APP_POLL)));
    }
}

pub fn run(opts: &Opts) -> Res<()> {
    let app = app_lines();
    let first = app.recv().map_err(|_| "no setup line on stdin")?;
    let setup: Setup = serde_json::from_str(&first).map_err(|e| format!("setup line: {e}"))?;
    let peer_key = unhex32(&setup.peer_key).ok_or("peer_key must be 64 hex characters")?;
    let view_only = view_only_for(&setup.scope)?;
    let stun: Vec<SocketAddr> = setup.stun.iter().filter_map(|s| resolve(s)).collect();
    let turn: Vec<TurnServer> = setup
        .turn
        .iter()
        .filter_map(|t| {
            Some(TurnServer {
                addr: resolve(&t.addr)?,
                username: t.username.clone(),
                password: t.password.clone(),
            })
        })
        .collect();
    // The displays first (the viewer's picker): GDI captures the whole virtual screen as one.
    let capture = GdiCapture::new(None);
    match &capture {
        Ok(c) => {
            say(AppLine { displays: Some(vec![c.size()]), current: Some(0), ..AppLine::default() })
        }
        Err(e) => say(AppLine {
            displays: Some(Vec::new()),
            current: Some(0),
            error: Some(e.to_string()),
            ..AppLine::default()
        }),
    }
    let keys = KeyPair::generate()?;
    say(AppLine { key: Some(hex(&keys.public)), ..AppLine::default() });
    let net = Net::start(NetConfig {
        role: Role::Responder,
        session: setup.session.as_bytes().to_vec(),
        local: keys,
        expected_remote: peer_key,
        stun,
        bind: "0.0.0.0:0".parse()?,
        turn,
        relay_only: setup.relay_only,
    })?;
    let mut wire = LinkWire { net, app };
    let reason = match serve_session(opts, &setup, view_only, capture, &mut wire) {
        Ok(reason) => reason,
        Err(e) => format!("failed: {e}"),
    };
    let _ = wire.send_control(&Control::Ended { reason: reason.clone() });
    say(AppLine { ended: Some(reason), ..AppLine::default() });
    // Dropping the link closes it (the viewer sees the close at once).
    drop(wire);
    Ok(())
}

/// Waits for the link and the viewer's hello and start, then streams. The end reason.
fn serve_session(
    opts: &Opts,
    setup: &Setup,
    view_only: bool,
    capture: Res<GdiCapture>,
    wire: &mut LinkWire,
) -> Res<String> {
    let started = Instant::now();
    let (mut hello, mut start) = (None, None);
    let mut incoming = Vec::new();
    while hello.is_none() || start.is_none() {
        let left = CONNECT_TIMEOUT.saturating_sub(started.elapsed());
        if left.is_zero() {
            return Ok("the viewer did not connect within 30 s".into());
        }
        if let Err(reason) = wire.receive(&mut incoming) {
            return Ok(reason.to_string());
        }
        for item in incoming.drain(..) {
            match item {
                Incoming::Control(h @ Control::Hello { .. }) => hello = Some(h),
                Incoming::Control(s @ Control::Start { .. }) => start = Some(s),
                // Input or feedback before the session started has nothing to act on.
                _ => {}
            }
        }
        if hello.is_none() || start.is_none() {
            wire.wait(left);
        }
    }
    let (Some(Control::Hello { service, caps, .. }), Some(Control::Start { key, mode })) =
        (hello, start)
    else {
        return Ok("no hello and start".into());
    };
    // The viewer is who the hub says (its key was checked); its claims in hello are not used.
    let principal = Principal {
        user: setup.viewer.user.clone(),
        install: setup.viewer.install.clone(),
        class: PrincipalClass::User,
        interactive: true,
    };
    // No upstream media (microphone, camera) on Windows yet: no host capability offered.
    let negotiated = match negotiate(&service, &caps, &[SERVICE_DESKTOP], &[]) {
        Ok(n) => n,
        Err(refusal) => {
            wire.send_control(&Control::Refused { reason: refusal.reason().into() })?;
            return Ok(format!("refused: {}", refusal.reason()));
        }
    };
    // The hub approved this viewer for this host: it is the session's owner here.
    let mut table = SessionTable::new(HostPolicy {
        enabled: true,
        owner_user: principal.user.clone(),
        grants: Vec::new(),
        consent: ConsentRule::AskOthers,
        unattended_allowed: true,
    });
    let mode = if mode == "control" && !view_only { Mode::Control } else { Mode::View };
    let control = matches!(mode, Mode::Control);
    let now_ms = u64::try_from(started.elapsed().as_millis()).unwrap_or(0);
    let session = match table.start(StartRequest {
        key: &key,
        caller: Some(&principal),
        for_client: None,
        mode,
        console_user: None,
        now_ms,
    }) {
        Ok(id) => id,
        Err(reason) => {
            wire.send_control(&Control::Refused { reason: format!("{reason:?}") })?;
            return Ok(format!("refused: {reason:?}"));
        }
    };
    let capture = capture?;
    let (width, height) = capture.size();
    let max_fps = setup.max_fps.unwrap_or(60).clamp(1, 120);
    let start_kbps: u32 = opts.num_or("start-kbps", 8000)?;
    let encoder = encoder::open(&EncCfg {
        width,
        height,
        fps: max_fps,
        kbps: start_kbps,
        threads: opts.num_or("threads", 2)?,
        codec: &opts.str_or("codec", "openh264"),
        screen_content: true,
        preset: "ultrafast",
        profile: "baseline",
        openh264_lib: opts.get("openh264-lib"),
    })?;
    wire.send_control(&Control::Welcome {
        encoder: encoder.name(),
        width,
        height,
        max_datagram: MAX_DATAGRAM,
        carrier: "link".into(),
        service: negotiated.service.clone(),
        caps: negotiated.caps.clone(),
    })?;
    wire.send_control(&Control::Started { session })?;
    let mut media = WindowsSession::new(
        capture,
        encoder,
        MAX_DATAGRAM,
        max_fps,
        start_kbps,
        opts.num_or("max-kbps", 50_000)?,
    );
    media.may_inject = control && table.may_inject_input(session, &principal);
    let reason = match media.run(wire) {
        Ok(()) => "stopped by viewer".to_owned(),
        Err(e) => e.to_string(),
    };
    let _ = table.stop(session, &Actor::Remote(Some(principal.clone())));
    Ok(reason)
}

#[cfg(test)]
#[path = "windows_serve_tests.rs"]
mod tests;
