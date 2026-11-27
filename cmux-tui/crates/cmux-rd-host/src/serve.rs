//! `cmux-rd serve`: one device hub session, driven by the app that approved it
//! (plans/cmux-next/remote-desktop-mac-host.md section 7). The app holds the
//! device key and the hub's signaling; this process holds the session key,
//! the secure link and the media. They talk in JSON lines:
//!
//! stdin, first line (the approved session):
//!   {"session":"<hub session id>","peer_key":"<viewer session key, 64 hex>",
//!    "viewer":{"user":"..","install":".."},"scope":"view"|"control",
//!    "stun":["host:port",..],"display":"main","max_fps":60,"max_width":null,
//!    "max_kbps":null,"cursor":null (the viewer's Customize wishes, src/serve_wish.rs),
//!    "window":null (or a window id from the `windows` line: share that one window),
//!    "capture":"x11"|"portal" (Linux, optional)}
//! On Linux the display is the session's X display (`--display`, else `$DISPLAY`, else
//! `:0`; `--xauthority` or `XAUTHORITY` for its cookie) and the capture backend is
//! `capture_backend::CaptureBackend` (`--capture`, else portal in a Wayland session).
//! stdin, later: {"candidate":"host 192.168.1.4:51000"} or {"stop":true}, and
//!   {"exclude_windows":[123,456]}: the app's window ids (CGWindowID) the capture leaves out,
//!   the whole list each time, sent before the capture starts and on every change (macOS)
//! stdout: {"key":"<this side's session key>"} first (the app signs it for the
//!   viewer), then {"candidate":".."}, {"candidates_done":true} (sent once this side's host
//!   candidates are known, the app answers then; reflexive and relayed candidates may follow it),
//!   {"connected":true}, {"path":{"kind":"direct_wan","rtt_ms":3.2}},
//!   and last {"ended":"<reason>"}.
//!
//! The viewer's peer key was checked against its device key by the app before
//! this process starts; the link refuses any other key. A `view` scope starts
//! the session in view mode whatever the viewer asks, so no input is applied.

use crate::args::Opts;
use crate::capture_backend::CaptureBackend;
use crate::carrier::{Carrier, Incoming, LinkCarrier, MediaQueueStats};
use crate::stream::{MediaSession, OpenedDesktop, SessionCfg};
use crate::wire::Control;
use crate::Res;
use cmux_rd_core::policy::{ConsentRule, HostPolicy, Mode, Principal, PrincipalClass};
use cmux_rd_core::profile::EncodeProfile;
use cmux_rd_core::service::{negotiate, SERVICE_DESKTOP};
use cmux_rd_core::session::{Actor, SessionTable, StartRequest};
use cmux_rd_link::net::{Candidate, Net, NetConfig, NetEvent};
use cmux_rd_link::{EndpointEvent, Event, KeyPair, Role};
use cmux_rd_proto::app_line::{AppLine, LinePath};
use serde::Deserialize;
use std::io::{self, BufRead, Read, Write};
use std::os::fd::RawFd;
use std::time::{Duration, Instant};

/// How long the viewer has to connect and say hello after the host starts.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Deserialize)]
struct Viewer {
    user: String,
    install: String,
}

#[derive(Deserialize)]
struct Setup {
    /// Raw signed peer marker: omission preserves the legacy protocol.
    #[serde(default)]
    peer_carrier: crate::carrier::LinkMode,
    session: String,
    peer_key: String,
    viewer: Viewer,
    scope: String,
    #[serde(default)]
    stun: Vec<String>,
    /// The hub's TURN relays, for a relayed path when no direct one works.
    #[serde(default)]
    turn: Vec<crate::carrier::TurnSetup>,
    /// TCP and TLS relays, used after the UDP ones, for a network that blocks UDP.
    #[serde(default)]
    turn_stream: Vec<crate::carrier::TurnSetup>,
    #[serde(default)]
    display: Option<String>,
    #[serde(default)]
    max_fps: Option<u32>,
    #[serde(default)]
    max_width: Option<u32>,
    /// The viewer's bitrate cap in kbit/s (`a=cmux-rd-max-kbps`; src/serve_wish.rs).
    #[serde(default)]
    max_kbps: Option<u32>,
    /// Whether the stream shows the cursor (`a=cmux-rd-cursor`; none: it does).
    #[serde(default)]
    cursor: Option<bool>,
    /// Share this one window (an id from the `windows` app line) instead of a display.
    #[serde(default)]
    window: Option<u32>,
    /// This side reaches the viewer through TURN alone.
    #[serde(default)]
    relay_only: bool,
    /// Linux: `x11` or `portal` (else `--capture`, else the session type decides).
    #[serde(default)]
    capture: Option<String>,
    /// The person sharing turned clipboard text sync on for this session (default off).
    #[serde(default)]
    clipboard: bool,
    /// The profile the viewer asks for (`standard` or `ultra`, the person's choice).
    #[serde(default)]
    encode_profile: Option<String>,
}

/// The session's profile: the viewer's choice, else `--encode-profile`, else standard. A
/// profile this host does not know runs standard, so a newer viewer still gets a picture.
fn session_profile(opts: &Opts, setup: &Setup) -> Result<EncodeProfile, String> {
    match setup.encode_profile.as_deref() {
        Some(asked) => Ok(EncodeProfile::parse(asked).unwrap_or_default()),
        None => opts.encode_profile(),
    }
}

#[derive(Deserialize)]
struct Later {
    #[serde(default)]
    candidate: Option<String>,
    #[serde(default)]
    stop: bool,
    /// SECURITY: the app windows only the person at this Mac may see (the join consent ask, a
    /// revealed password), which the capture must leave out; the whole list, replacing the last.
    #[serde(default)]
    #[cfg_attr(not(target_os = "macos"), allow(dead_code))]
    exclude_windows: Option<Vec<u32>>,
}

/// Prints one line for the app (`AppLine`, the type the app's line reader reads back).
fn say(line: AppLine) {
    let _ = write_line(&mut io::stdout().lock(), &line);
}

/// One app line on `out`, then a flush: the app reads stdout through a pipe, where nothing
/// else flushes it, so each line must reach the pipe whole before the next stage waits on
/// the app (cmuxterm-hq#13721: the answer waits for every candidate line).
fn write_line(out: &mut impl Write, line: &AppLine) -> io::Result<()> {
    writeln!(out, "{}", line.to_json())?;
    out.flush()
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

/// Linux's display list for the viewer's picker: the whole X screen first (an X screen spans
/// every monitor), then each RandR monitor when it has two or more (`x11_view::listing`; the
/// viewer's pick is the index). A portal session learns its size only once the person picks
/// the screen, so its list is empty until the stream starts; an X display that cannot be
/// opened says why.
#[cfg(target_os = "linux")]
fn linux_displays(capture: CaptureBackend, display: &str, pick: Option<&str>) -> AppLine {
    let listed = match capture {
        CaptureBackend::X11 => x11rb::connect(Some(display))
            .map_err(|e| format!("X display {display}: {e}"))
            .map(|(conn, screen)| {
                let root = &x11rb::connection::Connection::setup(&conn).roots[screen];
                let size = (u32::from(root.width_in_pixels), u32::from(root.height_in_pixels));
                let monitors = crate::x11_view::monitors(&conn, root.root, size);
                let sizes =
                    crate::x11_view::listing(size, &monitors).iter().map(|r| (r.w, r.h)).collect();
                // The windows the viewer may share one of (the setup line's `window`).
                let windows = crate::x11_window::list(&conn, root.root, size)
                    .into_iter()
                    .map(|w| cmux_rd_proto::app_line::LineWindow {
                        id: w.id,
                        title: w.title,
                        width: w.rect.w,
                        height: w.rect.h,
                    })
                    .collect();
                (sizes, windows)
            }),
        // The portal shares what the person picks in its own dialog.
        CaptureBackend::Portal => capture.available().map(|()| (Vec::new(), Vec::new())),
    };
    match listed {
        Ok((sizes, windows)) => {
            // The viewer's pick is current when it is on the list (else the share refuses it).
            let current =
                pick.and_then(|w| w.trim().parse::<usize>().ok()).filter(|&i| i < sizes.len());
            AppLine {
                displays: Some(sizes),
                windows: Some(windows),
                current: Some(current.unwrap_or(0)),
                ..AppLine::default()
            }
        }
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
                self.link.invalidate();
                return Err("stopped by the host".into());
            }
            if let Some(c) = later.candidate.as_deref().and_then(Candidate::from_wire) {
                self.link.net.add_remote_candidate(c);
            }
            #[cfg(target_os = "macos")]
            if let Some(ids) = later.exclude_windows {
                crate::mac::capture::set_excluded_windows(ids);
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
    fn drain_departures(&mut self, out: &mut Vec<cmux_rd_proto::DatagramDeparture>) {
        self.link.drain_departures(out);
    }

    fn departure_overflows(&self) -> u64 {
        self.link.departure_overflows()
    }

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

    fn media_queue_stats(&self) -> Option<MediaQueueStats> {
        self.link.media_queue_stats()
    }

    fn send_datagram(&mut self, datagram: &[u8]) -> io::Result<()> {
        self.link.send_datagram(datagram)
    }

    fn send_datagram_frame(&mut self, datagrams: Vec<Vec<u8>>, droppable: bool) -> io::Result<()> {
        self.link.send_datagram_frame(datagrams, droppable)
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
const LAN_RTT_US: u64 = cmux_rd_core::cc::LAN_RTT_US;

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
    let (stun, stun_later) = crate::carrier::stun_servers(&setup.stun, setup.relay_only);
    // Linux: the X cookie (`--xauthority`, else the session's XAUTHORITY, which x11rb reads),
    // the capture backend and the display, before any X connection.
    #[cfg(target_os = "linux")]
    crate::host::check_xauthority(opts)?;
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
    say(linux_displays(capture, &display, setup.display.as_deref()));
    #[cfg(target_os = "macos")]
    match crate::desktop::displays(&display) {
        Ok((sizes, current, ids)) => say(AppLine {
            displays: Some(sizes),
            // The windows the viewer may share one of (the setup line's `window`).
            windows: Some(crate::desktop::windows()),
            current: Some(current),
            display_ids: (!ids.is_empty()).then_some(ids),
            ..AppLine::default()
        }),
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
        turn: crate::carrier::turn_servers_with_stream(&setup.turn, &setup.turn_stream),
        relay_only: setup.relay_only,
    })?;
    if let Some(later) = stun_later {
        net.add_stun_later(later);
    }
    // SAFETY: fcntl on our own stdin, after the blocking setup read.
    unsafe {
        libc::fcntl(
            libc::STDIN_FILENO,
            libc::F_SETFL,
            libc::fcntl(libc::STDIN_FILENO, libc::F_GETFL) | libc::O_NONBLOCK,
        );
    }
    let mut carrier = ServeCarrier {
        link: LinkCarrier::new(net, crate::wg_carrier::Role::Host, setup.peer_carrier)?,
        app: AppLines { buf: Vec::new() },
    };
    let reason = match serve_session(opts, &setup, &display, capture, view_only, &mut carrier) {
        Ok(reason) => reason,
        Err(e) => format!("failed: {e}"),
    };
    if let Some(fallback) = carrier.link.take_fallback() {
        say(AppLine { fallback: Some(fallback), ..AppLine::default() });
    } else {
        let _ = carrier.send_control(&Control::Ended { reason: reason.clone() });
        say(AppLine { ended: Some(reason), ..AppLine::default() });
    }
    // Dropping the carrier closes the link (the viewer sees the close at once).
    drop(carrier);
    Ok(())
}

/// What this session shares, for the app and for checks that compare the viewer's pick with
/// the picture that arrives (`capturing`): the setup line's pick, the source it resolved to and
/// the streamed size, in the mode this host applies (a `view` scope is view whatever the viewer
/// asked).
fn capturing_line(
    setup: &Setup,
    rect: Option<[u32; 4]>,
    (width, height): (u32, u32),
    mode: Mode,
) -> AppLine {
    AppLine {
        capturing: Some(cmux_rd_proto::app_line::LineCapturing {
            source: if setup.window.is_some() { "window" } else { "display" }.into(),
            display: setup.display.clone(),
            window: setup.window,
            rect,
            width,
            height,
            max_width: setup.max_width,
            mode: match mode {
                Mode::Control => "control",
                Mode::View => "view",
            }
            .into(),
            scope: setup.scope.clone(),
        }),
        ..AppLine::default()
    }
}

/// When `candidates_done` goes to the app, which answers then: at the first host candidate
/// (one is known at once, so a session never waits for STUN or TURN), or when gathering ends
/// for a side with none (relay only). Once.
#[derive(Default)]
struct AnswerGate {
    ready: bool,
    said: bool,
}

impl AnswerGate {
    fn candidate(&mut self, kind: cmux_rd_link::net::CandidateKind) {
        self.ready |= kind == cmux_rd_link::net::CandidateKind::Host;
    }

    fn gathered(&mut self) {
        self.ready = true;
    }

    /// True once, when the answer can go.
    fn due(&mut self) -> bool {
        self.ready && !std::mem::replace(&mut self.said, true)
    }
}

/// The session's settings known before the viewer's hello: the frame rate, profile and bitrate
/// cap from the setup line and the options. The start bitrate is the off-LAN one until the path
/// is known (the capture opens at it during the handshake; the session sets the path's before
/// the first frame), and two frames in flight until the round trip is.
fn session_cfg(
    opts: &Opts,
    setup: &Setup,
    display: &str,
    capture: CaptureBackend,
    show_cursor: bool,
) -> Res<SessionCfg> {
    let display = display.to_owned();
    // The viewer's rate wins; else the display's refresh rate (60 when it cannot be read).
    let max_fps = setup.max_fps.unwrap_or_else(|| crate::desktop::default_max_fps(&display));
    // Ultra (the viewer's choice or `--encode-profile ultra`): frames at that rate up to 120,
    // a higher ceiling, and the encoder's ultra settings. Standard (the default) is unchanged.
    let encode_profile = session_profile(opts, setup)?;
    let max_fps = encode_profile.stream_fps(max_fps);
    let explicit_max_kbps = opts.get("max-kbps").map(|_| opts.num_or("max-kbps", 0)).transpose()?;
    // The host's ceiling (profile and `--max-kbps`), then the viewer's Customize cap within it:
    // one cap, the congestion controller's `max_bps`.
    let host_max_kbps = cmux_rd_core::profile::max_kbps(encode_profile, explicit_max_kbps, 50_000);
    // `--pin-kbps N` (bench builds) holds the controller at N: start, floor and ceiling.
    let pin_kbps = crate::host::pin_kbps(opts)?;
    let max_kbps =
        pin_kbps.unwrap_or_else(|| crate::serve_wish::max_kbps(setup.max_kbps, host_max_kbps));
    let start_kbps = match pin_kbps {
        Some(pin) => pin,
        None => crate::serve_wish::start_kbps(
            opts.num_or("start-kbps", default_start_kbps(None, None, None, max_kbps))?,
            max_kbps,
        ),
    };
    Ok(SessionCfg {
        display,
        display_pick: setup.display.clone(),
        window: setup.window,
        max_fps,
        encode_profile,
        start_kbps,
        max_kbps,
        pin_kbps,
        preset: String::new(),
        profile: opts.str_or("profile", "high"),
        codec: opts.str_or("codec", crate::host::DEFAULT_CODEC),
        content: "screen".into(),
        openh264_lib: None,
        threads: crate::encoder::default_threads(),
        // `--stats-every-ms 100` (the bench's 100 ms rate series); 100 ms is the floor.
        stats_every_ms: opts.num_or("stats-every-ms", 1000u64)?,
        settle_us: crate::host::DEFAULT_SETTLE_US,
        upstream_record: None,
        upstream_record_max_bytes: 0,
        max_width: setup.max_width,
        show_cursor,
        // On by default: the frame that shows an input's effect goes out at once instead of
        // waiting out the frame-rate interval. `--input-frame-now 0` turns it off.
        input_frame_now: opts.flag_or("input-frame-now", true),
        // Off by default: `--rtt-tail-probe 1` probes a lost newest frame after a round
        // trip instead of 250 ms (design D6), for measuring before it ships.
        rtt_tail_probe: opts.flag_or("rtt-tail-probe", false),
        // Off by default: `--resolution-ladder 1` makes the picture smaller, not blurrier,
        // below the bits-per-pixel floor (design D5), with `--max-qp N` as its QP ceiling.
        resolution_ladder: opts.flag_or("resolution-ladder", false),
        max_qp: crate::host::ladder_max_qp(opts)?,
        // Set from the path's round trip once the viewer starts.
        frames_in_flight: 2,
        capture,
        sharp_text: false,
    })
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
    // The answer goes as soon as this side's host candidates are known: the reflexive and
    // relayed ones trickle after it (the app relays them as candidates), so the viewer no longer
    // waits for a STUN round trip and the TURN allocations (3 s at most, `RELAY_GATHER_US`)
    // before it can even start its handshake. Relay only has no host candidate: it waits for
    // the relay's, as before.
    let mut answer = AnswerGate::default();
    // The session's settings that do not wait for the viewer: they come from the setup line and
    // the options. The path's (start bitrate, frames in flight) are set once the viewer starts.
    let show_cursor = crate::serve_wish::show_cursor(setup.cursor);
    let mut cfg = session_cfg(opts, setup, display, capture, show_cursor)?;
    // The capture and encoder open once the answer has gone, while it crosses the hub and the
    // link shakes hands, not after the viewer's start: ScreenCaptureKit's start and its first
    // frame (or X11's, or the portal's) no longer sit between the link and the first frame. An
    // open error waits for the viewer's start, where it ended the session before. It opens for
    // the cursor this host offers; a viewer that negotiates the other choice gets it reopened.
    let mut desktop: Option<Res<OpenedDesktop>> = None;
    // The current path's class and medium (wire names), from the last path change.
    let mut path_kind: Option<&'static str> = None;
    let mut path_medium: Option<&'static str> = None;
    // Lines that came in the same read as the setup sit in stdin's buffer, where a wait on the
    // descriptor never sees them.
    carrier.pump_app()?;
    while hello.is_none() || start.is_none() || !carrier.link.media_ready() {
        let left = CONNECT_TIMEOUT.saturating_sub(started.elapsed());
        if left.is_zero() {
            return Ok("the viewer did not connect within 30 s".into());
        }
        crate::fdwait::wait_readable(&carrier.fds(), Some(left.as_nanos().min(25_000_000) as u64))?;
        carrier.pump_app().map_err(|e| e.to_string())?;
        for event in carrier.link.events() {
            if let Some(line) = event.phase_line() {
                println!("{line}");
            }
            match event {
                NetEvent::Candidate(c) => {
                    say(AppLine { candidate: Some(c.to_wire()), ..AppLine::default() });
                    answer.candidate(c.kind);
                }
                NetEvent::CandidatesDone => answer.gathered(),
                NetEvent::Endpoint(EndpointEvent::Link(Event::Established)) => {
                    say(AppLine { connected: true, ..AppLine::default() })
                }
                NetEvent::Endpoint(EndpointEvent::Link(Event::Control(record))) => {
                    match serde_json::from_slice::<Control>(&record) {
                        Ok(h @ Control::Hello { .. }) => hello = Some(h),
                        Ok(s @ Control::Start { .. }) => start = Some(s),
                        Ok(Control::Stop | Control::Ended { .. } | Control::Refused { .. }) => {
                            return Ok("viewer stopped or refused the session".into());
                        }
                        _ => {}
                    }
                }
                NetEvent::Endpoint(EndpointEvent::Link(Event::Closed)) => {
                    return Ok("viewer closed the link".into());
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
        // After the whole batch: the reflexive candidate that came with the host ones still
        // goes in the answer itself.
        if answer.due() {
            say(AppLine { candidates_done: true, ..AppLine::default() });
        }
        carrier.report_paths();
        if carrier.link.retry_ready() {
            return Ok("carrier retry acknowledged".into());
        }
        if answer.said && desktop.is_none() {
            let cursor = show_cursor && crate::desktop::reports_cursor();
            desktop = Some(OpenedDesktop::open(&cfg, cursor));
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
    let sink = crate::upstream::session_sink(None, 0);
    let mut host_caps = crate::upstream::offered_caps(&*sink);
    // The cursor as metadata where this desktop reports it: the viewer draws one cursor.
    if show_cursor && crate::desktop::reports_cursor() {
        host_caps.push(cmux_rd_core::service::caps::CURSOR);
    }
    // Frames over one FEC block keep their parity, in interleaved blocks (design D6).
    host_caps.push(cmux_rd_core::service::caps::FEC_BLOCKS);
    if crate::desktop::scales_pictures() {
        host_caps.push(cmux_rd_core::service::caps::VIDEO_SCALED);
    }
    // An OpenH264 viewer asks for Constrained Baseline (cmux#50591).
    if crate::stream::offers_h264_baseline(&opts.str_or("codec", crate::host::DEFAULT_CODEC)) {
        host_caps.push(cmux_rd_core::service::caps::H264_BASELINE);
    }
    // A viewer whose person turned on sharper Linux text gets OpenH264's screen usage.
    if crate::stream::offers_sharp_text(&opts.str_or("codec", crate::host::DEFAULT_CODEC)) {
        host_caps.push(cmux_rd_core::service::caps::SHARP_TEXT);
    }
    // The session clock (C8; the engine answers every ping) and the stage ledger (D8).
    host_caps.extend([cmux_rd_core::service::caps::CLOCK, cmux_rd_core::service::caps::LEDGER]);
    // Clipboard text only when the app's setup turned it on and this host has a clipboard it
    // can watch (macOS). A `view` scope session still never applies or sends one: it never
    // holds control (clipboard.rs).
    if crate::clipboard::offered(setup.clipboard) {
        host_caps.push(cmux_rd_core::service::caps::CLIPBOARD_TEXT);
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
    // A pinned rate (`--pin-kbps`) keeps its start; else the path sets it.
    if cfg.pin_kbps.is_none() {
        cfg.start_kbps = crate::serve_wish::start_kbps(
            opts.num_or(
                "start-kbps",
                default_start_kbps(path_kind, path_medium, carrier.link.rtt_us, cfg.max_kbps),
            )?,
            cfg.max_kbps,
        );
    }
    // Enough frames in flight to cover the path's round trip, at least two: the next
    // frame encodes while the last one waits for its acknowledgement.
    cfg.frames_in_flight = carrier
        .link
        .rtt_us
        .map_or(2, |rtt| cmux_rd_engine::frames_in_flight_for(rtt, cfg.max_fps))
        .max(2);
    let desktop = match desktop {
        Some(opened) => opened?,
        None => OpenedDesktop::open(&cfg, crate::stream::wants_cursor(&negotiated.caps))?,
    };
    let max_datagram = carrier.link.max_datagram();
    let mut media = MediaSession::on_desktop(desktop, &cfg, max_datagram, &negotiated.caps, sink)?;
    let (width, height) = media.size();
    carrier.send_control(&Control::Welcome {
        encoder: media.encoder_name(),
        width,
        height,
        max_datagram,
        carrier: carrier.link.wire_name().into(),
        service: negotiated.service.clone(),
        caps: negotiated.caps.clone(),
    })?;
    carrier.send_control(&Control::Started { session })?;
    say(capturing_line(setup, media.source_rect(), (width, height), mode));
    let reason = media.run(carrier, &mut table, session, &principal);
    media.release_input();
    media.close_upstreams();
    let _ = table.stop(session, &Actor::Remote(Some(principal.clone())));
    Ok(reason)
}

#[cfg(test)]
#[path = "serve_tests.rs"]
mod tests;
