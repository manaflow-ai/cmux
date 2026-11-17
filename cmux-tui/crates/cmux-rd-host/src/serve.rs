//! `cmux-rd serve`: one device hub session, driven by the app that approved it
//! (plans/cmux-next/remote-desktop-mac-host.md section 7). The app holds the
//! device key and the hub's signaling; this process holds the session key,
//! the secure link and the media. They talk in JSON lines:
//!
//! stdin, first line (the approved session):
//!   {"session":"<hub session id>","peer_key":"<viewer session key, 64 hex>",
//!    "viewer":{"user":"..","install":".."},"scope":"view"|"control",
//!    "stun":["host:port",..],"display":"main","max_fps":60,"max_width":null,
//!    "capture":"x11"|"portal" (Linux, optional)}
//! On Linux the display is the session's X display (`--display`, else `$DISPLAY`, else
//! `:0`; `--xauthority` or `XAUTHORITY` for its cookie) and the capture backend is
//! `capture_backend::CaptureBackend` (`--capture`, else portal in a Wayland session).
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
use crate::capture_backend::CaptureBackend;
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
    /// Linux: `x11` or `portal` (else `--capture`, else the session type decides).
    #[serde(default)]
    capture: Option<String>,
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

pub(crate) fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

pub(crate) fn unhex32(text: &str) -> Option<[u8; 32]> {
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

/// The display the session streams. macOS: the viewer's pick (`main` or an index). Linux: the
/// session's X display (`--display`, else `$DISPLAY`, else `:0`); the viewer's `main` means it.
fn session_display(opts: &Opts, setup: &Setup) -> String {
    #[cfg(target_os = "linux")]
    {
        crate::capture_backend::x_display(
            setup.display.as_deref(),
            opts.get("display"),
            std::env::var("DISPLAY").ok().as_deref(),
        )
    }
    #[cfg(not(target_os = "linux"))]
    {
        setup.display.clone().unwrap_or_else(|| opts.str_or("display", "main"))
    }
}

/// Linux's display list for the viewer's picker: the X screen's size (one display; an X
/// screen spans every monitor). A portal session learns its size only once the person picks
/// the screen, so its list is empty until the stream starts; an X display that cannot be
/// opened says why.
#[cfg(target_os = "linux")]
fn linux_displays(capture: CaptureBackend, display: &str) -> AppLine {
    let listed = match capture {
        CaptureBackend::X11 => x11rb::connect(Some(display))
            .map_err(|e| format!("X display {display}: {e}"))
            .map(|(conn, screen)| {
                let root = &x11rb::connection::Connection::setup(&conn).roots[screen];
                vec![(u32::from(root.width_in_pixels), u32::from(root.height_in_pixels))]
            }),
        CaptureBackend::Portal => capture.available().map(|()| Vec::new()),
    };
    match listed {
        Ok(sizes) => AppLine { displays: Some(sizes), current: Some(0), ..AppLine::default() },
        Err(e) => AppLine {
            displays: Some(Vec::new()),
            current: Some(0),
            error: Some(e),
            ..AppLine::default()
        },
    }
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

    fn path_rtt_us(&self) -> Option<u64> {
        self.link.path_rtt_us()
    }

    fn send_datagram(&mut self, datagram: &[u8]) -> io::Result<()> {
        self.link.send_datagram(datagram)
    }

    fn send_control(&mut self, control: &Control) -> io::Result<()> {
        self.link.send_control(control)
    }
}

/// Start bitrate off a direct LAN path (the congestion controller's own start).
const WAN_START_KBPS: u32 = 8_000;
/// Start bitrate on a direct LAN path. The controller grows only 8% per second of
/// flowing frames, so from 8 Mbps it took about 24 s of motion to reach 50 Mbps; a LAN
/// carries 30 Mbps at once, and a rising delay still cuts it within a few frames.
const LAN_START_KBPS: u32 = 30_000;
/// A round trip under this counts as LAN when the path's class does not say so (a peer
/// first learned during the handshake is classed `direct_wan`).
const LAN_RTT_US: u64 = 5_000;

/// The start bitrate when `--start-kbps` is not given, from the current path's class and
/// medium (wire names) and round trip; never above `max_kbps`. A relay is never LAN.
fn default_start_kbps(
    path_kind: Option<&str>,
    medium: Option<&str>,
    rtt_us: Option<u64>,
    max_kbps: u32,
) -> u32 {
    let relay = matches!(path_kind, Some("turn_relay" | "do_relay" | "via_cloud_region"));
    let lan = !relay
        && (path_kind == Some("direct_lan")
            || matches!(medium, Some("lan" | "link"))
            || rtt_us.is_some_and(|rtt| rtt < LAN_RTT_US));
    let start = if lan { LAN_START_KBPS } else { WAN_START_KBPS };
    start.min(max_kbps)
}

/// Whether a session with the setup line's `scope` (`view` or `control`) starts view only
/// when its capture does or does not apply input: one that applies none (the Wayland portal
/// without a RemoteDesktop grant) is view only, so the viewer is told view, not a control
/// session whose input is dropped.
fn view_only_for(scope: &str, applies_input: bool) -> Res<bool> {
    match scope {
        "view" => Ok(true),
        "control" => Ok(!applies_input),
        other => Err(format!("scope {other}: use view or control").into()),
    }
}

pub fn run(opts: &Opts) -> Res<()> {
    let mut first = String::new();
    io::stdin().lock().read_line(&mut first)?;
    let setup: Setup = serde_json::from_str(&first).map_err(|e| format!("setup line: {e}"))?;
    let peer_key = unhex32(&setup.peer_key).ok_or("peer_key must be 64 hex characters")?;
    let stun: Vec<SocketAddr> = setup
        .stun
        .iter()
        .filter_map(|s| std::net::ToSocketAddrs::to_socket_addrs(s).ok()?.find(SocketAddr::is_ipv4))
        .collect();
    // Linux: the X cookie (`--xauthority`, else the session's XAUTHORITY, which x11rb reads),
    // the capture backend and the display, before any X connection.
    #[cfg(target_os = "linux")]
    crate::host::set_xauthority(opts)?;
    // Capture setup states (a Wayland portal waiting for the person at the screen) reach the app.
    #[cfg(all(feature = "portal", target_os = "linux"))]
    crate::desktop::set_status_sink(Box::new(|state, message| {
        say(AppLine {
            status: Some(cmux_rd_proto::app_line::LineStatus {
                state: state.to_owned(),
                message: message.to_owned(),
            }),
            ..AppLine::default()
        })
    }));
    let capture = CaptureBackend::from_env(setup.capture.as_deref().or(opts.get("capture")))?;
    let view_only = view_only_for(&setup.scope, capture.applies_input())?;
    let display = session_display(opts, &setup);
    // The displays first, so the viewer can offer a display picker; then the session key.
    #[cfg(target_os = "linux")]
    say(linux_displays(capture, &display));
    #[cfg(target_os = "macos")]
    match crate::desktop::displays() {
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
        // `--link-bind IP:PORT` (measurement only): the link's UDP socket on one interface's
        // address, so a Mac with Ethernet and Wi-Fi on one subnet sends from Wi-Fi when asked
        // (scripts/screen-share-vs.py --link wifi). The app never passes it.
        bind: opts.str_or("link-bind", "0.0.0.0:0").parse()?,
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
    let reason = match serve_session(opts, &setup, &display, capture, view_only, &mut carrier) {
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
    display: &str,
    capture: CaptureBackend,
    view_only: bool,
    carrier: &mut ServeCarrier,
) -> Res<String> {
    let started = Instant::now();
    let mut hello = None;
    let mut start = None;
    // The current path's class and medium (wire names), from the last path change.
    let mut path_kind: Option<&'static str> = None;
    let mut path_medium: Option<&'static str> = None;
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
                NetEvent::Endpoint(path @ EndpointEvent::PathChanged { .. }) => {
                    // The path's class picks the start bitrate.
                    if let EndpointEvent::PathChanged { kind, medium, .. } = &path {
                        path_kind = kind.map(|k| k.wire_name());
                        path_medium = medium.map(|m| m.wire_name());
                    }
                    // The round trip sizes the frames in flight when the stream starts.
                    carrier.link.record_path(path);
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
    let mut host_caps = crate::upstream::offered_caps(&*sink);
    // The cursor as metadata where this desktop reports it: the viewer draws one cursor.
    if crate::desktop::reports_cursor() {
        host_caps.push(cmux_rd_core::service::caps::CURSOR);
    }
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
    let display = display.to_owned();
    // The viewer's rate wins; else the display's refresh rate (60 when it cannot be read).
    let max_fps = setup.max_fps.unwrap_or_else(|| crate::desktop::default_max_fps(&display));
    // `--encode-profile ultra`: frames at that rate up to 120, a higher ceiling, and the
    // encoder's ultra settings. Standard (the default) is unchanged.
    let encode_profile = opts.encode_profile()?;
    let max_fps = encode_profile.stream_fps(max_fps);
    let explicit_max_kbps = opts.get("max-kbps").map(|_| opts.num_or("max-kbps", 0)).transpose()?;
    let max_kbps = cmux_rd_core::profile::max_kbps(encode_profile, explicit_max_kbps, 50_000);
    let start_kbps = opts.num_or(
        "start-kbps",
        default_start_kbps(path_kind, path_medium, carrier.link.rtt_us, max_kbps),
    )?;
    let cfg = SessionCfg {
        display,
        max_fps,
        encode_profile,
        start_kbps,
        max_kbps,
        preset: String::new(),
        profile: opts.str_or("profile", "high"),
        codec: opts.str_or("codec", crate::host::DEFAULT_CODEC),
        content: "screen".into(),
        openh264_lib: None,
        threads: crate::encoder::default_threads(),
        stats_every_ms: 1000,
        settle_us: crate::host::DEFAULT_SETTLE_US,
        upstream_record: None,
        upstream_record_max_bytes: 0,
        max_width: setup.max_width,
        // On by default: the frame that shows an input's effect goes out at once instead of
        // waiting out the frame-rate interval. `--input-frame-now 0` turns it off.
        input_frame_now: opts.flag_or("input-frame-now", true),
        // Enough frames in flight to cover the path's round trip, at least two: the next
        // frame encodes while the last one waits for its acknowledgement.
        frames_in_flight: carrier
            .link
            .rtt_us
            .map_or(2, |rtt| cmux_rd_engine::frames_in_flight_for(rtt, max_fps))
            .max(2),
        capture,
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn portal_sessions_control_only_with_a_remote_desktop_grant() {
        // Without the grant the portal drops input: a control session there would not be one.
        let x11 = CaptureBackend::X11.applies_input_with(false);
        assert!(view_only_for("view", x11).unwrap());
        assert!(!view_only_for("control", x11).unwrap());
        let portal = CaptureBackend::Portal.applies_input_with(false);
        assert!(view_only_for("view", portal).unwrap());
        assert!(view_only_for("control", portal).unwrap());
        let granted = CaptureBackend::Portal.applies_input_with(true);
        assert!(view_only_for("view", granted).unwrap());
        assert!(!view_only_for("control", granted).unwrap());
        assert!(view_only_for("full", x11).is_err());
    }

    #[test]
    fn a_lan_path_starts_at_the_lan_bitrate() {
        assert_eq!(default_start_kbps(Some("direct_lan"), None, None, 50_000), 30_000);
        assert_eq!(default_start_kbps(Some("direct_wan"), Some("lan"), None, 50_000), 30_000);
        assert_eq!(default_start_kbps(Some("direct_wan"), Some("link"), None, 50_000), 30_000);
        // A peer learned in the handshake is classed WAN; a sub-5 ms round trip is LAN.
        assert_eq!(default_start_kbps(Some("direct_wan"), None, Some(1_200), 50_000), 30_000);
        assert_eq!(default_start_kbps(None, None, Some(4_999), 50_000), 30_000);
    }

    #[test]
    fn other_paths_keep_the_old_start_and_max_caps_both() {
        assert_eq!(default_start_kbps(None, None, None, 50_000), 8_000);
        assert_eq!(
            default_start_kbps(Some("direct_wan"), Some("routed"), Some(5_000), 50_000),
            8_000
        );
        assert_eq!(default_start_kbps(Some("direct_wan"), None, Some(40_000), 50_000), 8_000);
        // A relay is never LAN, whatever its round trip.
        assert_eq!(default_start_kbps(Some("turn_relay"), Some("lan"), Some(1_000), 50_000), 8_000);
        assert_eq!(default_start_kbps(Some("direct_lan"), None, None, 20_000), 20_000);
        assert_eq!(default_start_kbps(None, None, None, 4_000), 4_000);
    }
}
