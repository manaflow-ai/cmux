//! `cmux-rd host`: accepts viewers on one port (TCP for control, UDP for datagrams),
//! admits them through the `cmux-rd-core` session table, and streams this OS's desktop
//! with `stream.rs`. One viewer at a time in phase 1.
//!
//! `--listen-systemd` (Linux) is the production Cloud mode instead: no TCP or UDP port; the
//! listening Unix socket comes from systemd (systemd.rs), only the root link receiver
//! (`--peer-uid`) may connect, and the link already admitted the machine's owner.

use crate::args::Opts;
use crate::carrier::SocketCarrier;
use crate::clock::now_ns;
use crate::stream::{MediaSession, SessionCfg};
use crate::wire::{write_control, Control, DatagramOut, FrameReader, FRAME_CONTROL};
use crate::Res;
use cmux_rd_core::policy::{ConsentRule, HostPolicy, Mode, Principal, PrincipalClass};
use cmux_rd_core::service::{negotiate, Negotiated, SERVICE_DESKTOP};
use cmux_rd_core::session::{Actor, SessionId, SessionTable, StartRequest};
use cmux_rd_proto::{MAX_DATAGRAM_DEFAULT, OVERLAY_PORT};
use std::io::{self, Read, Write};
use std::net::{IpAddr, SocketAddr, TcpListener, TcpStream, UdpSocket};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::time::Duration;

/// Linux: an X display name. macOS: `main` or a display's index, left to right.
#[cfg(target_os = "linux")]
const DEFAULT_DISPLAY: &str = ":99";
#[cfg(target_os = "macos")]
const DEFAULT_DISPLAY: &str = "main";
/// Linux: Cisco's OpenH264 binary. macOS: the hardware encoder, fed the captured IOSurface.
#[cfg(target_os = "linux")]
pub(crate) const DEFAULT_CODEC: &str = "openh264";
#[cfg(target_os = "macos")]
pub(crate) const DEFAULT_CODEC: &str = "videotoolbox";
/// X apps draw one change with several requests, so the Linux host waits briefly for the
/// rest; ScreenCaptureKit delivers whole composited frames, so the macOS host never waits.
#[cfg(target_os = "linux")]
pub(crate) const DEFAULT_SETTLE_US: u64 = 1000;
#[cfg(target_os = "macos")]
pub(crate) const DEFAULT_SETTLE_US: u64 = 0;

pub fn run(opts: &Opts) -> Res<()> {
    set_xauthority(opts)?;
    if opts.flag("listen-systemd") {
        return run_systemd(opts);
    }
    // Until the link token (lane 12) authenticates hello claims, the host trusts them, so by
    // default it listens on loopback only and refuses every non-loopback peer. A private
    // single-tenant overlay needs the explicit flag below.
    let (reach, bind) = reach_and_bind(opts)?;
    // The per-launch token from the parent (the daemon) through an inherited pipe.
    let token_fd: i32 = opts.get("token-fd").ok_or("--token-fd N is required: the daemon passes the session token through an inherited pipe")?.parse()?;
    let token = crate::token::Token::read_fd(token_fd)?;
    eprintln!(
        "cmux-rd host: development only. The host trusts the principal claims in each hello until the link \
         token (lane 12) authenticates them, so it serves {}.",
        match reach {
            Reach::LoopbackOnly => "loopback peers only (reach it through SSH or a tunnel)",
            Reach::SingleTenantOverlay => "a private single-tenant overlay (--single-tenant-overlay 1): every process on that network can claim the owner",
        }
    );
    let port: u16 = opts.num_or("port", OVERLAY_PORT)?;
    let owner =
        opts.get("owner").ok_or("--owner <user> is required (the host's owner)")?.to_string();
    let cfg = session_cfg(opts)?;
    if let Some(dir) = &cfg.upstream_record {
        // Fail at start, not at the first viewer.
        crate::upstream::RecordSink::new(dir, cfg.upstream_record_max_bytes)
            .map_err(|e| format!("--upstream-record {}: {e}", dir.display()))?;
        eprintln!(
            "cmux-rd host: development only: --upstream-record writes the viewer's microphone, camera and \
             screen share to {}",
            dir.display()
        );
    }
    let policy = owner_policy(owner);
    #[cfg(target_os = "linux")]
    let _browser = browser(opts, &cfg)?;
    #[cfg(not(target_os = "linux"))]
    if opts.get("browser").is_some() {
        return Err("--browser needs a Linux host (a virtual X display)".into());
    }
    let mut table = SessionTable::new(policy);
    let listener = TcpListener::bind(SocketAddr::new(bind, port))?;
    let udp = UdpSocket::bind(SocketAddr::new(bind, port))?;
    udp.set_nonblocking(true)?;
    crate::wire::grow_udp_buffers(&udp);
    eprintln!("cmux-rd host: listening on {bind}:{port} (tcp control, udp datagrams)");
    for conn in listener.incoming() {
        let stream = match conn {
            Ok(s) => s,
            Err(e) => {
                eprintln!("accept failed: {e}");
                continue;
            }
        };
        let peer = stream.peer_addr().map(|a| a.to_string()).unwrap_or_default();
        match stream.peer_addr() {
            Ok(addr) if peer_allowed(addr.ip(), reach) => {}
            _ => {
                eprintln!("refused peer {peer}: not allowed in {reach:?} mode");
                continue;
            }
        }
        match serve_viewer(stream, Some(&udp), &mut table, &cfg, &Admission::Token(&token)) {
            Ok(reason) => eprintln!("viewer {peer} ended: {reason}"),
            Err(e) => eprintln!("viewer {peer} failed: {e}"),
        }
        for event in table.take_audit() {
            eprintln!("audit: {event:?}");
        }
    }
    Ok(())
}

/// The session settings from the options (every mode).
fn session_cfg(opts: &Opts) -> Res<SessionCfg> {
    Ok(SessionCfg {
        display: opts.str_or("display", DEFAULT_DISPLAY),
        max_fps: opts.num_or("max-fps", 60)?,
        start_kbps: opts.num_or("start-kbps", 8000)?,
        max_kbps: opts.num_or("max-kbps", 50_000)?,
        preset: opts.str_or("preset", "ultrafast"),
        // High for hardware decoders (VideoToolbox); the Linux bench decoder needs baseline.
        profile: opts.str_or("profile", "high"),
        codec: opts.str_or("codec", DEFAULT_CODEC),
        content: opts.str_or("content", "screen"),
        openh264_lib: opts.get("openh264-lib").map(str::to_owned),
        threads: opts.num_or("threads", 2)?,
        stats_every_ms: opts.num_or("stats-ms", 1000)?,
        settle_us: opts.num_or("settle-us", DEFAULT_SETTLE_US)?,
        upstream_record: opts.get("upstream-record").map(std::path::PathBuf::from),
        upstream_record_max_bytes: opts
            .num_or::<u64>("upstream-record-max-mb", 1024)?
            .saturating_mul(1 << 20),
        frames_in_flight: 1,
        input_frame_now: opts.flag("input-frame-now"),
        max_width: opts
            .get("max-width")
            .map(|w| w.parse().map_err(|_| format!("--max-width {w}: a pixel count")))
            .transpose()?,
    })
}

/// The host's owner is the only principal admitted without a grant.
fn owner_policy(owner: String) -> HostPolicy {
    HostPolicy {
        enabled: true,
        owner_user: owner,
        grants: Vec::new(),
        consent: ConsentRule::AskOthers,
        unattended_allowed: true,
    }
}

/// `--xauthority PATH`: the X cookie for the display connections (Linux), as `XAUTHORITY`.
/// Set before any thread or X connection starts.
fn set_xauthority(opts: &Opts) -> Res<()> {
    let Some(path) = opts.get("xauthority") else {
        return Ok(());
    };
    #[cfg(target_os = "linux")]
    {
        std::fs::File::open(path).map_err(|e| format!("--xauthority {path}: {e}"))?;
        std::env::set_var("XAUTHORITY", path);
        Ok(())
    }
    #[cfg(not(target_os = "linux"))]
    {
        Err(format!("--xauthority {path} needs a Linux host (an X display)").into())
    }
}

/// `--browser URL`: the cloud browser. Chromium runs full screen in the display and
/// outlives viewers; the supervisor restarts it and stops it with the host.
#[cfg(target_os = "linux")]
fn browser(opts: &Opts, cfg: &SessionCfg) -> Res<Option<crate::browser::BrowserSupervisor>> {
    match opts.get("browser") {
        Some(url) => Ok(Some(start_browser(opts, &cfg.display, url)?)),
        None => Ok(None),
    }
}

/// The principal a systemd-socket connection serves: the link admitted the machine's owner.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub const MACHINE_OWNER: &str = "owner";

/// Options that `--listen-systemd` refuses: the TCP development modes, and the cloud browser
/// (a Chromium with an optional CDP port does not belong on the agent display's host).
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
const NOT_WITH_SYSTEMD: &[&str] = &[
    "token-fd",
    "bind",
    "port",
    "single-tenant-overlay",
    "upstream-record",
    "browser",
    "browser-cdp-port",
];

/// `--listen-systemd --peer-uid N`: the production Cloud mode (Linux). See systemd.rs.
#[cfg(target_os = "linux")]
fn run_systemd(opts: &Opts) -> Res<()> {
    let peer_uid: u32 = opts
        .get("peer-uid")
        .ok_or("--listen-systemd needs --peer-uid N (the uid of the link receiver, 0)")?
        .parse()
        .map_err(|_| "--peer-uid: a uid")?;
    if let Some(bad) = NOT_WITH_SYSTEMD.iter().find(|k| opts.get(k).is_some()) {
        return Err(format!("--{bad} is not used with --listen-systemd").into());
    }
    let idle_ms = opts.num_or::<u64>("idle-exit-s", 120)?.saturating_mul(1000);
    let listener = crate::systemd::listener_from_env()?;
    let cfg = session_cfg(opts)?;
    let owner = opts.str_or("owner", MACHINE_OWNER);
    let mut table = SessionTable::new(owner_policy(owner.clone()));
    eprintln!(
        "cmux-rd host: systemd socket; only uid {peer_uid} (the link receiver) may connect; the link admitted \
         the owner, so no hello token is used; exits after {} s with no viewer",
        idle_ms / 1000
    );
    loop {
        let Some(stream) = crate::systemd::accept_within(&listener, idle_ms)? else {
            eprintln!(
                "cmux-rd host: idle for {} s; exiting (the socket unit starts it again)",
                idle_ms / 1000
            );
            return Ok(());
        };
        let stream = match crate::systemd::admit_peer(stream, peer_uid) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("{e}");
                continue;
            }
        };
        match serve_viewer(stream, None, &mut table, &cfg, &Admission::LinkOwner(&owner)) {
            Ok(reason) => eprintln!("viewer ended: {reason}"),
            Err(e) => eprintln!("viewer failed: {e}"),
        }
        for event in table.take_audit() {
            eprintln!("audit: {event:?}");
        }
    }
}

#[cfg(not(target_os = "linux"))]
fn run_systemd(_opts: &Opts) -> Res<()> {
    Err("--listen-systemd needs a Linux host (systemd socket activation)".into())
}

/// Starts the cloud browser at the display's full size (read from the X server).
#[cfg(target_os = "linux")]
fn start_browser(opts: &Opts, display: &str, url: &str) -> Res<crate::browser::BrowserSupervisor> {
    let (conn, screen_num) = x11rb::connect(Some(display))?;
    let screen = &x11rb::connection::Connection::setup(&conn).roots[screen_num];
    let (w, h) = (u32::from(screen.width_in_pixels), u32::from(screen.height_in_pixels));
    drop(conn);
    let program = opts.str_or("browser-bin", "google-chrome");
    let profile = opts.str_or("browser-profile", "/tmp/cmux-rd-browser-profile");
    let mut cmd = crate::browser::BrowserCommand::chrome(&program, display, url, w, h, &profile);
    // `--browser-cdp-port N`: CDP on 127.0.0.1:N for an agent on this machine (off by default).
    if let Some(port) = opts.get("browser-cdp-port") {
        let port: u16 =
            port.parse().map_err(|_| format!("invalid value for --browser-cdp-port: {port}"))?;
        cmd = cmd.with_cdp_port(port);
        eprintln!("cmux-rd host: browser CDP on 127.0.0.1:{port} (loopback only)");
    }
    let sup = crate::browser::BrowserSupervisor::start(cmd, crate::browser::Backoff::default())
        .map_err(|e| format!("--browser: cannot start {program}: {e}"))?;
    eprintln!("cmux-rd host: browser {program} ({w}x{h}, pid {}) showing {url}", sup.pid());
    Ok(sup)
}

/// Which peers the host serves while hello claims are unauthenticated.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reach {
    /// The default: loopback binds and loopback peers only.
    LoopbackOnly,
    /// Explicit opt-in: a private single-tenant overlay (RFC 1918, CGNAT, ULA) or loopback.
    SingleTenantOverlay,
}

/// Loopback, RFC 1918, CGNAT (overlay) or IPv6 ULA; never the unspecified address.
fn is_private(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            let o = v4.octets();
            v4.is_loopback() || v4.is_private() || (o[0] == 100 && (o[1] & 0xc0) == 64)
        }
        IpAddr::V6(v6) => v6.is_loopback() || (v6.segments()[0] & 0xfe00) == 0xfc00,
    }
}

/// May the host listen on `bind` in this mode?
pub fn bind_allowed(bind: IpAddr, reach: Reach) -> Result<(), String> {
    match reach {
        Reach::LoopbackOnly if bind.is_loopback() => Ok(()),
        Reach::LoopbackOnly => Err(format!(
            "--bind {bind} is not loopback; until the link token authenticates hello claims, the host binds \
             loopback only (a private single-tenant overlay needs --single-tenant-overlay 1)"
        )),
        Reach::SingleTenantOverlay if is_private(bind) => Ok(()),
        Reach::SingleTenantOverlay => Err(format!("--bind {bind} is not a loopback or private overlay address")),
    }
}

/// The serving mode and bind address from the options: loopback only unless the exact
/// `--single-tenant-overlay 1` is given; the bind defaults to 127.0.0.1 and must fit the mode.
pub fn reach_and_bind(opts: &Opts) -> Result<(Reach, IpAddr), String> {
    let reach = if opts.get("single-tenant-overlay") == Some("1") {
        Reach::SingleTenantOverlay
    } else {
        Reach::LoopbackOnly
    };
    let bind: IpAddr =
        opts.str_or("bind", "127.0.0.1").parse().map_err(|e| format!("--bind: {e}"))?;
    bind_allowed(bind, reach)?;
    Ok((reach, bind))
}

/// May a viewer connecting from `peer` be served in this mode? Checked before the hello is read.
/// IPv4-mapped IPv6 addresses are judged as IPv4.
pub fn peer_allowed(peer: IpAddr, reach: Reach) -> bool {
    let peer = peer.to_canonical();
    match reach {
        Reach::LoopbackOnly => peer.is_loopback(),
        Reach::SingleTenantOverlay => is_private(peer),
    }
}

/// Most bytes in any hello or start string.
const MAX_CLAIM: usize = 256;

fn parse_class(class: &str) -> PrincipalClass {
    match class {
        "user" => PrincipalClass::User,
        "mux" => PrincipalClass::Mux,
        "run" => PrincipalClass::Run,
        _ => PrincipalClass::Agent,
    }
}

/// A viewer's control stream: TCP (development) or the systemd Unix socket.
pub(crate) trait ViewerStream: Read + Write + AsRawFd {
    /// Socket options before the hello (TCP: no delay, keepalive).
    fn prepare(&self) -> io::Result<()>;
    fn nonblocking(&self, on: bool) -> io::Result<()>;
    fn read_timeout(&self, timeout: Option<Duration>) -> io::Result<()>;
    fn close(&self);
    /// The viewer's address for the UDP carrier; `None` on a Unix socket.
    fn peer_ip(&self) -> Option<IpAddr>;
}

impl ViewerStream for TcpStream {
    fn prepare(&self) -> io::Result<()> {
        self.set_nodelay(true)?;
        crate::wire::harden_tcp(self);
        Ok(())
    }
    fn nonblocking(&self, on: bool) -> io::Result<()> {
        self.set_nonblocking(on)
    }
    fn read_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
        self.set_read_timeout(timeout)
    }
    fn close(&self) {
        let _ = self.shutdown(std::net::Shutdown::Both);
    }
    fn peer_ip(&self) -> Option<IpAddr> {
        self.peer_addr().ok().map(|a| a.ip())
    }
}

impl ViewerStream for UnixStream {
    fn prepare(&self) -> io::Result<()> {
        Ok(())
    }
    fn nonblocking(&self, on: bool) -> io::Result<()> {
        self.set_nonblocking(on)
    }
    fn read_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
        self.set_read_timeout(timeout)
    }
    fn close(&self) {
        let _ = self.shutdown(std::net::Shutdown::Both);
    }
    fn peer_ip(&self) -> Option<IpAddr> {
        None
    }
}

/// How a connection's principal is established.
pub(crate) enum Admission<'a> {
    /// Development: the exact per-launch token in the hello; the hello's claims name the principal.
    Token(&'a crate::token::Token),
    /// The systemd socket: the link admitted the machine's owner (this user name) before the
    /// connection reached the host; the hello's token and principal claims are not used.
    #[cfg_attr(not(target_os = "linux"), allow(dead_code))]
    LinkOwner(&'a str),
}

/// Reads one control message, waiting up to 5 s.
fn read_control<S: ViewerStream>(stream: &mut S, reader: &mut FrameReader) -> Res<Control> {
    let deadline = now_ns() + 5_000_000_000;
    loop {
        if let Some((ty, payload)) = reader.next()? {
            if ty == FRAME_CONTROL {
                return Ok(serde_json::from_slice(&payload)?);
            }
            continue;
        }
        if now_ns() > deadline {
            return Err("no control message within 5 s".into());
        }
        crate::fdwait::wait_readable(
            &[std::os::fd::AsRawFd::as_raw_fd(stream)],
            Some(200_000_000),
        )?;
        reader.fill(stream)?;
        // Close at once, before any parse or reply, when the peer speaks something else
        // (an HTTP request from a browser page must never reach the control parser).
        if reader.foreign_prefix() {
            stream.close();
            return Err("not the cmux.rd protocol (for example HTTP): closed (reset)".into());
        }
    }
}

fn serve_viewer<S: ViewerStream>(
    mut stream: S,
    udp: Option<&UdpSocket>,
    table: &mut SessionTable,
    cfg: &SessionCfg,
    admission: &Admission<'_>,
) -> Res<String> {
    stream.prepare()?;
    stream.nonblocking(true)?;
    let mut reader = FrameReader::default();
    let Control::Hello {
        user,
        install,
        class,
        interactive,
        udp_port,
        max_datagram,
        token: provided,
        service,
        caps,
    } = read_control(&mut stream, &mut reader)?
    else {
        return Err("first message must be hello".into());
    };
    // Before anything else (no session, no frame): the exact per-launch token. On the
    // systemd socket the link admitted the owner already and the hello carries no token.
    if let Admission::Token(token) = admission {
        if !token.matches_hex(provided.as_ref().map(|s| s.0.as_str())) {
            let _ = write_control(&mut stream, &Control::Refused { reason: "BadToken".into() });
            return Ok("refused: missing or wrong session token".into());
        }
    }
    // Route by service (C1): this host serves remote desktop only. Upstream
    // media (C4) is offered only when the desktop has a sink for it (today the
    // development recording sink, `--upstream-record DIR`).
    let sink = crate::upstream::session_sink(
        cfg.upstream_record.as_deref(),
        cfg.upstream_record_max_bytes,
    );
    let host_caps = crate::upstream::offered_caps(&*sink);
    let negotiated = match negotiate(&service, &caps, &[SERVICE_DESKTOP], &host_caps) {
        Ok(n) => n,
        Err(refusal) => {
            write_control(&mut stream, &Control::Refused { reason: refusal.reason().into() })?;
            return Ok(format!("refused: {}", refusal.reason()));
        }
    };
    if [&user, &install, &class].iter().any(|v| v.len() > MAX_CLAIM) {
        return Err("hello field too long".into());
    }
    if udp_port.is_some_and(|p| p < 1024) {
        return Err("udp_port below 1024 refused".into());
    }
    // The datagram path: the viewer's UDP port when this host has one, else the stream.
    let out = match (udp_port, udp, stream.peer_ip()) {
        (None, _, _) => DatagramOut::Stream,
        (Some(p), Some(sock), Some(ip)) => {
            DatagramOut::Udp { sock: sock.try_clone()?, peer: SocketAddr::new(ip, p) }
        }
        (Some(_), _, _) => {
            write_control(&mut stream, &Control::Refused { reason: "StreamCarrierOnly".into() })?;
            return Ok("refused: this host serves the stream carrier only".into());
        }
    };
    let principal = match admission {
        Admission::Token(_) => Principal { user, install, class: parse_class(&class), interactive },
        // The link's owner, a person at the app: the hello's user, class and interactive
        // claims are not used.
        Admission::LinkOwner(owner) => Principal {
            user: owner.to_string(),
            install,
            class: PrincipalClass::User,
            interactive: true,
        },
    };
    // Never larger than the viewer asked for: a smaller path MTU would fragment or drop.
    if max_datagram < 512 {
        return Err("max_datagram below 512 refused".into());
    }
    let max_datagram = max_datagram.min(MAX_DATAGRAM_DEFAULT);
    let Control::Start { key, mode } = read_control(&mut stream, &mut reader)? else {
        return Err("second message must be start".into());
    };
    if key.len() > MAX_CLAIM || mode.len() > MAX_CLAIM {
        return Err("start field too long".into());
    }
    let mode = if mode == "control" { Mode::Control } else { Mode::View };
    let now_ms = now_ns() / 1_000_000;
    let start = StartRequest {
        key: &key,
        caller: Some(&principal),
        for_client: None,
        mode,
        console_user: None,
        now_ms,
    };
    let session = match table.start(start) {
        Ok(id) => id,
        Err(reason) => {
            write_control(&mut stream, &Control::Refused { reason: format!("{reason:?}") })?;
            return Ok(format!("refused: {reason:?}"));
        }
    };
    let reason = match stream_session(
        &mut stream,
        &mut reader,
        udp,
        table,
        cfg,
        session,
        &principal,
        out,
        max_datagram,
        &negotiated,
        sink,
    ) {
        Ok(reason) => reason,
        Err(e) => format!("failed: {e}"),
    };
    // Every exit path ends the session in the table (single writer of rd_session).
    let _ = table.stop(session, &Actor::Remote(Some(principal.clone())));
    let _ = write_control(&mut stream, &Control::Ended { reason: reason.clone() });
    stream.nonblocking(false)?;
    stream.read_timeout(Some(Duration::from_millis(200)))?;
    Ok(reason)
}

#[allow(clippy::too_many_arguments)]
fn stream_session<S: ViewerStream>(
    stream: &mut S,
    reader: &mut FrameReader,
    udp: Option<&UdpSocket>,
    table: &mut SessionTable,
    cfg: &SessionCfg,
    session: SessionId,
    principal: &Principal,
    out: DatagramOut,
    max_datagram: usize,
    negotiated: &Negotiated,
    sink: Box<dyn crate::upstream::UpstreamSink>,
) -> Res<String> {
    // Datagrams left over from an earlier viewer must not reach this session (bounded).
    let mut scratch = [0u8; 2048];
    for _ in 0..256 {
        if udp.is_none_or(|u| u.recv_from(&mut scratch).is_err()) {
            break;
        }
    }
    let carrier_name = match out {
        DatagramOut::Udp { .. } => "udp",
        DatagramOut::Stream => "stream",
    };
    let mut media = MediaSession::open(cfg, max_datagram, &negotiated.caps, sink)?;
    let (width, height) = media.size();
    write_control(
        stream,
        &Control::Welcome {
            encoder: media.encoder_name(),
            width,
            height,
            max_datagram,
            carrier: carrier_name.into(),
            service: negotiated.service.clone(),
            caps: negotiated.caps.clone(),
        },
    )?;
    write_control(stream, &Control::Started { session })?;
    let mut carrier = SocketCarrier::new(stream, reader, udp, out);
    let reason = media.run(&mut carrier, table, session, principal);
    media.release_input();
    media.close_upstreams();
    Ok(reason)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_real_loopback_connection_passes_the_default_check() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        let addr = listener.local_addr().expect("addr");
        let _client = std::net::TcpStream::connect(addr).expect("connect");
        let (accepted, _) = listener.accept().expect("accept");
        assert!(peer_allowed(accepted.peer_addr().expect("peer").ip(), Reach::LoopbackOnly));
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn listen_systemd_refuses_the_development_and_browser_options() {
        for extra in [
            &["--token-fd", "3"][..],
            &["--port", "4103"],
            &["--browser", "https://example.com"],
            &["--browser-cdp-port", "9222"],
        ] {
            let mut args: Vec<String> =
                ["--listen-systemd", "--peer-uid", "0"].iter().map(|s| s.to_string()).collect();
            args.extend(extra.iter().map(|s| s.to_string()));
            let err = run_systemd(&Opts::parse(&args).expect("parse")).expect_err("refused");
            assert!(
                err.to_string().contains("is not used with --listen-systemd"),
                "{extra:?}: {err}"
            );
        }
        let args: Vec<String> = ["--listen-systemd"].iter().map(|s| s.to_string()).collect();
        let err = run_systemd(&Opts::parse(&args).expect("parse")).expect_err("no peer uid");
        assert!(err.to_string().contains("--peer-uid"), "{err}");
    }

    #[test]
    fn an_http_request_is_closed_before_any_reply() {
        for prefix in [
            "GET / HTTP/1.1\r\n",
            "POST /x HTTP/1.1\r\n",
            "OPTIONS * HTTP/1.1",
            "PUT /",
            "HEAD /",
            "CONNECT a:1",
        ] {
            let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
            let addr = listener.local_addr().expect("addr");
            let mut client = std::net::TcpStream::connect(addr).expect("connect");
            std::io::Write::write_all(&mut client, prefix.as_bytes()).expect("write");
            let (mut server, _) = listener.accept().expect("accept");
            server.set_nonblocking(true).expect("nonblocking");
            let mut reader = FrameReader::default();
            let err = read_control(&mut server, &mut reader).expect_err("refused");
            assert!(err.to_string().contains("not the cmux.rd protocol"), "{prefix}: {err}");
            // Nothing was sent back; the connection is closed.
            client.set_read_timeout(Some(std::time::Duration::from_secs(2))).expect("timeout");
            let mut buf = [0u8; 16];
            assert_eq!(std::io::Read::read(&mut client, &mut buf).unwrap_or(0), 0, "{prefix}");
        }
    }
}
