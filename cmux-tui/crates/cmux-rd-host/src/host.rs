//! `cmux-rd host`: accepts viewers on one port (TCP for control, UDP for datagrams),
//! admits them through the `cmux-rd-core` session table, and streams with `stream.rs`.
//! One viewer at a time in phase 1.

use crate::args::Opts;
use crate::clock::now_ns;
use crate::stream::{MediaSession, SessionCfg};
use crate::wire::{write_control, Control, DatagramOut, FrameReader, FRAME_CONTROL};
use crate::Res;
use cmux_rd_core::policy::{ConsentRule, HostPolicy, Mode, Principal, PrincipalClass};
use cmux_rd_core::session::{Actor, SessionId, SessionTable, StartRequest};
use cmux_rd_proto::{MAX_DATAGRAM_DEFAULT, OVERLAY_PORT};
use std::net::{IpAddr, SocketAddr, TcpListener, TcpStream, UdpSocket};
use std::time::Duration;

pub fn run(opts: &Opts) -> Res<()> {
    // Until the link token (lane 12) authenticates hello claims, the host trusts them, so by
    // default it listens on loopback only and refuses every non-loopback peer. A private
    // single-tenant overlay needs the explicit flag below.
    let reach = if opts.get("single-tenant-overlay") == Some("1") {
        Reach::SingleTenantOverlay
    } else {
        Reach::LoopbackOnly
    };
    let bind: IpAddr = opts.str_or("bind", "127.0.0.1").parse()?;
    if let Err(e) = bind_allowed(bind, reach) {
        return Err(e.into());
    }
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
    let cfg = SessionCfg {
        display: opts.str_or("display", ":99"),
        max_fps: opts.num_or("max-fps", 60)?,
        start_kbps: opts.num_or("start-kbps", 8000)?,
        max_kbps: opts.num_or("max-kbps", 50_000)?,
        preset: opts.str_or("preset", "ultrafast"),
        // High for hardware decoders (VideoToolbox); the Linux bench decoder needs baseline.
        profile: opts.str_or("profile", "high"),
        codec: opts.str_or("codec", "openh264"),
        content: opts.str_or("content", "screen"),
        threads: opts.num_or("threads", 2)?,
        stats_every_ms: opts.num_or("stats-ms", 1000)?,
        settle_us: opts.num_or("settle-us", 1000)?,
    };
    let policy = HostPolicy {
        enabled: true,
        owner_user: owner,
        grants: Vec::new(),
        consent: ConsentRule::AskOthers,
        unattended_allowed: true,
    };
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
        match serve_viewer(stream, &udp, &mut table, &cfg) {
            Ok(reason) => eprintln!("viewer {peer} ended: {reason}"),
            Err(e) => eprintln!("viewer {peer} failed: {e}"),
        }
        for event in table.take_audit() {
            eprintln!("audit: {event:?}");
        }
    }
    Ok(())
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

/// May a viewer connecting from `peer` be served in this mode? Checked before the hello is read.
pub fn peer_allowed(peer: IpAddr, reach: Reach) -> bool {
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

/// Reads one control message, waiting up to 5 s.
fn read_control(stream: &mut TcpStream, reader: &mut FrameReader) -> Res<Control> {
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
    }
}

fn serve_viewer(
    mut stream: TcpStream,
    udp: &UdpSocket,
    table: &mut SessionTable,
    cfg: &SessionCfg,
) -> Res<String> {
    stream.set_nodelay(true)?;
    crate::wire::harden_tcp(&stream);
    stream.set_nonblocking(true)?;
    let mut reader = FrameReader::default();
    let Control::Hello { user, install, class, interactive, udp_port, max_datagram } =
        read_control(&mut stream, &mut reader)?
    else {
        return Err("first message must be hello".into());
    };
    if [&user, &install, &class].iter().any(|v| v.len() > MAX_CLAIM) {
        return Err("hello field too long".into());
    }
    if udp_port.is_some_and(|p| p < 1024) {
        return Err("udp_port below 1024 refused".into());
    }
    let principal = Principal { user, install, class: parse_class(&class), interactive };
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
        udp_port,
        max_datagram,
    ) {
        Ok(reason) => reason,
        Err(e) => format!("failed: {e}"),
    };
    // Every exit path ends the session in the table (single writer of rd_session).
    let _ = table.stop(session, &Actor::Remote(Some(principal.clone())));
    let _ = write_control(&mut stream, &Control::Ended { reason: reason.clone() });
    stream.set_nonblocking(false)?;
    stream.set_read_timeout(Some(Duration::from_millis(200)))?;
    Ok(reason)
}

#[allow(clippy::too_many_arguments)]
fn stream_session(
    stream: &mut TcpStream,
    reader: &mut FrameReader,
    udp: &UdpSocket,
    table: &mut SessionTable,
    cfg: &SessionCfg,
    session: SessionId,
    principal: &Principal,
    udp_port: Option<u16>,
    max_datagram: usize,
) -> Res<String> {
    // Datagrams left over from an earlier viewer must not reach this session (bounded).
    let mut scratch = [0u8; 2048];
    for _ in 0..256 {
        if udp.recv_from(&mut scratch).is_err() {
            break;
        }
    }
    let peer_ip = stream.peer_addr()?.ip();
    let out = match udp_port {
        Some(p) => DatagramOut::Udp { sock: udp.try_clone()?, peer: SocketAddr::new(peer_ip, p) },
        None => DatagramOut::Stream,
    };
    let carrier = if udp_port.is_some() { "udp" } else { "stream" };
    let mut media = MediaSession::open(cfg, max_datagram, out, peer_ip)?;
    let (width, height) = media.size();
    write_control(
        stream,
        &Control::Welcome {
            encoder: media.encoder_name(),
            width,
            height,
            max_datagram,
            carrier: carrier.into(),
        },
    )?;
    write_control(stream, &Control::Started { session })?;
    let reason = media.run(stream, reader, udp, table, session, principal);
    media.release_input();
    Ok(reason)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ip(s: &str) -> IpAddr {
        s.parse().expect("ip")
    }

    #[test]
    fn default_mode_refuses_every_non_loopback_peer() {
        for peer in
            ["10.250.93.2", "100.64.1.2", "192.168.1.5", "8.8.8.8", "fd7c::1", "2001:db8::1"]
        {
            assert!(!peer_allowed(ip(peer), Reach::LoopbackOnly), "{peer}");
        }
        assert!(peer_allowed(ip("127.0.0.1"), Reach::LoopbackOnly));
        assert!(peer_allowed(ip("::1"), Reach::LoopbackOnly));
    }

    #[test]
    fn default_mode_binds_loopback_only() {
        assert!(bind_allowed(ip("127.0.0.1"), Reach::LoopbackOnly).is_ok());
        for bind in ["0.0.0.0", "10.250.93.1", "100.64.0.1", "::"] {
            assert!(bind_allowed(ip(bind), Reach::LoopbackOnly).is_err(), "{bind}");
        }
    }

    #[test]
    fn overlay_mode_is_private_only() {
        assert!(bind_allowed(ip("10.250.93.1"), Reach::SingleTenantOverlay).is_ok());
        assert!(bind_allowed(ip("0.0.0.0"), Reach::SingleTenantOverlay).is_err());
        assert!(bind_allowed(ip("8.8.8.8"), Reach::SingleTenantOverlay).is_err());
        assert!(peer_allowed(ip("10.250.93.2"), Reach::SingleTenantOverlay));
        assert!(!peer_allowed(ip("8.8.8.8"), Reach::SingleTenantOverlay));
    }
}
