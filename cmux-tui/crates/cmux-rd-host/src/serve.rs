//! `cmux-rd serve`: one device hub session, driven by the app that approved it
//! (plans/cmux-next/remote-desktop-mac-host.md section 7). The app holds the
//! device key and the hub's signaling; this process holds the session key,
//! the secure link and the media. They talk in JSON lines:
//!
//! stdin, first line (the approved session):
//!   {"session":"<hub session id>","peer_key":"<viewer session key, 64 hex>",
//!    "viewer":{"user":"..","install":".."},"scope":"view"|"control",
//!    "stun":["host:port",..],"display":"main","max_fps":60,"max_width":null}
//! stdin, later: {"candidate":"host 192.168.1.4:51000"} or {"stop":true}
//! stdout: {"key":"<this side's session key>"} first (the app signs it for the
//!   viewer), then {"candidate":".."}, {"candidates_done":true},
//!   {"connected":true}, {"path":{"kind":"direct_wan","rtt_ms":3.2}},
//!   and last {"ended":"<reason>"}.
//!
//! The viewer's peer key was checked against its device key by the app before
//! this process starts; the link refuses any other key. A `view` scope starts
//! the session in view mode whatever the viewer asks, so no input is applied.

use crate::args::Opts;
use crate::carrier::{Carrier, Incoming, LinkCarrier};
use crate::stream::{MediaSession, SessionCfg};
use crate::wire::Control;
use crate::Res;
use cmux_rd_core::policy::{ConsentRule, HostPolicy, Mode, Principal, PrincipalClass};
use cmux_rd_core::service::{negotiate, SERVICE_DESKTOP};
use cmux_rd_core::session::{Actor, SessionTable, StartRequest};
use cmux_rd_link::net::{Candidate, Net, NetConfig, NetEvent};
use cmux_rd_link::{EndpointEvent, Event, KeyPair, Role};
use cmux_rd_proto::app_line::{AppLine, LinePath};
use serde::Deserialize;
use std::io::{self, BufRead, Read, Write};
use std::net::SocketAddr;
use std::os::fd::RawFd;
use std::time::{Duration, Instant};

/// How long the viewer has to connect and say hello after the host starts.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(30);
/// Datagram size inside the link: the rd shard size minus the seal overhead fits one
/// 1280-byte IPv6 minimum MTU path with headroom for a relay's framing.
const MAX_DATAGRAM: usize = 1152 - cmux_rd_link::SEAL_OVERHEAD;

#[derive(Deserialize)]
struct Viewer {
    user: String,
    install: String,
}

#[derive(Deserialize)]
struct Setup {
    session: String,
    peer_key: String,
    viewer: Viewer,
    scope: String,
    #[serde(default)]
    stun: Vec<String>,
    /// The hub's TURN relays, for a relayed path when no direct one works.
    #[serde(default)]
    turn: Vec<crate::carrier::TurnSetup>,
    #[serde(default)]
    display: Option<String>,
    #[serde(default)]
    max_fps: Option<u32>,
    #[serde(default)]
    max_width: Option<u32>,
    /// This side reaches the viewer through TURN alone.
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

/// Prints one line for the app (`AppLine`, the type the app's line reader reads back).
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

/// Reads the app's later lines without blocking (stdin is non-blocking after setup).
struct AppLines {
    buf: Vec<u8>,
}

impl AppLines {
    fn read(&mut self) -> Result<Vec<Later>, String> {
        let mut chunk = [0u8; 4096];
        loop {
            match io::stdin().lock().read(&mut chunk) {
                Ok(0) => return Err("the app closed the session's input".into()),
                Ok(n) => self.buf.extend_from_slice(&chunk[..n]),
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(e) => return Err(format!("app input failed: {e}")),
            }
        }
        let mut lines = Vec::new();
        while let Some(end) = self.buf.iter().position(|b| *b == b'\n') {
            let line: Vec<u8> = self.buf.drain(..=end).collect();
            if let Ok(later) = serde_json::from_slice::<Later>(&line) {
                lines.push(later);
            }
        }
        Ok(lines)
    }
}

/// The link carrier plus the app's input: candidates that arrive during the
/// session reach the endpoint, `stop` ends it, path changes go to the app.
struct ServeCarrier {
    link: LinkCarrier,
    app: AppLines,
}

impl ServeCarrier {
    fn pump_app(&mut self) -> Result<(), String> {
        for later in self.app.read()? {
            if later.stop {
                return Err("stopped by the host".into());
            }
            if let Some(c) = later.candidate.as_deref().and_then(Candidate::from_wire) {
                self.link.net.add_remote_candidate(c);
            }
        }
        Ok(())
    }

    fn report_paths(&mut self) {
        for event in self.link.paths.drain(..) {
            if let EndpointEvent::PathChanged { kind, rtt_us, .. } = event {
                say(AppLine {
                    path: Some(LinePath {
                        kind: kind.map(|k| k.wire_name().to_owned()),
                        rtt_ms: rtt_us.map(|us| us as f64 / 1000.0),
                    }),
                    ..AppLine::default()
                });
            }
        }
    }
}

impl Carrier for ServeCarrier {
    fn fds(&self) -> Vec<RawFd> {
        let mut fds = self.link.fds();
        fds.push(libc::STDIN_FILENO);
        fds
    }

    fn receive(&mut self, out: &mut Vec<Incoming>) -> Result<(), String> {
        self.pump_app()?;
        let result = self.link.receive(out);
        self.report_paths();
        result
    }

    fn send_datagram(&mut self, datagram: &[u8]) -> io::Result<()> {
        self.link.send_datagram(datagram)
    }

    fn send_control(&mut self, control: &Control) -> io::Result<()> {
        self.link.send_control(control)
    }
}

pub fn run(opts: &Opts) -> Res<()> {
    let mut first = String::new();
    io::stdin().lock().read_line(&mut first)?;
    let setup: Setup = serde_json::from_str(&first).map_err(|e| format!("setup line: {e}"))?;
    let peer_key = unhex32(&setup.peer_key).ok_or("peer_key must be 64 hex characters")?;
    let view_only = match setup.scope.as_str() {
        "view" => true,
        "control" => false,
        other => return Err(format!("scope {other}: use view or control").into()),
    };
    let stun: Vec<SocketAddr> = setup
        .stun
        .iter()
        .filter_map(|s| std::net::ToSocketAddrs::to_socket_addrs(s).ok()?.find(SocketAddr::is_ipv4))
        .collect();
    // The displays first, so the viewer can offer a display picker; then the session key.
    #[cfg(target_os = "macos")]
    match crate::mac::capture::displays() {
        Ok((sizes, current)) => {
            say(AppLine { displays: Some(sizes), current: Some(current), ..AppLine::default() })
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
        turn: crate::carrier::turn_servers(&setup.turn),
        relay_only: setup.relay_only,
    })?;
    // SAFETY: fcntl on our own stdin, after the blocking setup read.
    unsafe {
        libc::fcntl(
            libc::STDIN_FILENO,
            libc::F_SETFL,
            libc::fcntl(libc::STDIN_FILENO, libc::F_GETFL) | libc::O_NONBLOCK,
        );
    }
    let mut carrier = ServeCarrier {
        link: LinkCarrier { net, paths: Vec::new(), rtt_us: None },
        app: AppLines { buf: Vec::new() },
    };
    let reason = match serve_session(opts, &setup, view_only, &mut carrier) {
        Ok(reason) => reason,
        Err(e) => format!("failed: {e}"),
    };
    let _ = carrier.send_control(&Control::Ended { reason: reason.clone() });
    say(AppLine { ended: Some(reason), ..AppLine::default() });
    // Dropping the carrier closes the link (the viewer sees the close at once).
    drop(carrier);
    Ok(())
}

/// Waits for the link and the viewer's hello and start, then streams.
fn serve_session(
    opts: &Opts,
    setup: &Setup,
    view_only: bool,
    carrier: &mut ServeCarrier,
) -> Res<String> {
    let started = Instant::now();
    let mut hello = None;
    let mut start = None;
    // Lines that came in the same read as the setup sit in stdin's buffer, where a wait on the
    // descriptor never sees them.
    carrier.pump_app()?;
    while hello.is_none() || start.is_none() {
        let left = CONNECT_TIMEOUT.saturating_sub(started.elapsed());
        if left.is_zero() {
            return Ok("the viewer did not connect within 30 s".into());
        }
        crate::fdwait::wait_readable(&carrier.fds(), Some(left.as_nanos() as u64))?;
        carrier.pump_app().map_err(|e| e.to_string())?;
        for event in carrier.link.net.events() {
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
                NetEvent::Endpoint(EndpointEvent::Link(Event::Control(record))) => {
                    match serde_json::from_slice::<Control>(&record) {
                        Ok(h @ Control::Hello { .. }) => hello = Some(h),
                        Ok(s @ Control::Start { .. }) => start = Some(s),
                        _ => {}
                    }
                }
                NetEvent::Endpoint(EndpointEvent::Link(Event::Closed)) => {
                    return Ok("viewer closed the link".into())
                }
                NetEvent::Endpoint(path @ EndpointEvent::PathChanged { rtt_us, .. }) => {
                    // The round trip sizes the frames in flight when the stream starts.
                    if rtt_us.is_some() {
                        carrier.link.rtt_us = rtt_us;
                    }
                    carrier.link.paths.push(path)
                }
                NetEvent::Failed(reason) => return Ok(format!("link failed: {reason}")),
                _ => {}
            }
        }
        carrier.report_paths();
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
    let sink = crate::upstream::session_sink(None, 0);
    let host_caps = crate::upstream::offered_caps(&*sink);
    let negotiated = match negotiate(&service, &caps, &[SERVICE_DESKTOP], &host_caps) {
        Ok(n) => n,
        Err(refusal) => {
            carrier.send_control(&Control::Refused { reason: refusal.reason().into() })?;
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
            carrier.send_control(&Control::Refused { reason: format!("{reason:?}") })?;
            return Ok(format!("refused: {reason:?}"));
        }
    };
    let display = setup.display.clone().unwrap_or_else(|| opts.str_or("display", "main"));
    // The viewer's rate wins; else the display's refresh rate (60 when it cannot be read).
    let max_fps = setup.max_fps.unwrap_or_else(|| crate::desktop::default_max_fps(&display));
    let cfg = SessionCfg {
        display,
        max_fps,
        start_kbps: opts.num_or("start-kbps", 8000)?,
        max_kbps: opts.num_or("max-kbps", 50_000)?,
        preset: String::new(),
        profile: opts.str_or("profile", "high"),
        codec: opts.str_or("codec", crate::host::DEFAULT_CODEC),
        content: "screen".into(),
        openh264_lib: None,
        threads: 2,
        stats_every_ms: 1000,
        settle_us: crate::host::DEFAULT_SETTLE_US,
        upstream_record: None,
        upstream_record_max_bytes: 0,
        max_width: setup.max_width,
        input_frame_now: opts.flag("input-frame-now"),
        // Enough frames in flight to cover the path's round trip, at least two: the next
        // frame encodes while the last one waits for its acknowledgement.
        frames_in_flight: carrier
            .link
            .rtt_us
            .map_or(2, |rtt| cmux_rd_engine::frames_in_flight_for(rtt, max_fps))
            .max(2),
    };
    let mut media = MediaSession::open(&cfg, MAX_DATAGRAM, &negotiated.caps, sink)?;
    let (width, height) = media.size();
    carrier.send_control(&Control::Welcome {
        encoder: media.encoder_name(),
        width,
        height,
        max_datagram: MAX_DATAGRAM,
        carrier: "link".into(),
        service: negotiated.service.clone(),
        caps: negotiated.caps.clone(),
    })?;
    carrier.send_control(&Control::Started { session })?;
    let reason = media.run(carrier, &mut table, session, &principal);
    media.release_input();
    media.close_upstreams();
    let _ = table.stop(session, &Actor::Remote(Some(principal.clone())));
    Ok(reason)
}
