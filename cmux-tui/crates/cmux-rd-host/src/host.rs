//! `cmux-rd host`: accepts viewers on one port (TCP for control, UDP for datagrams),
//! admits them through the `cmux-rd-core` session table, and streams with `stream.rs`.
//! One viewer at a time in phase 1.

use crate::args::Opts;
use crate::clock::now_ns;
use crate::stream::{MediaSession, SessionCfg};
use crate::wire::{write_control, Control, DatagramOut, FrameReader, FRAME_CONTROL};
use crate::Res;
use cmux_rd_core::policy::{ConsentRule, HostPolicy, Mode, Principal, PrincipalClass};
use cmux_rd_core::session::{Actor, SessionTable, StartRequest};
use cmux_rd_proto::{MAX_DATAGRAM_DEFAULT, MAX_DATAGRAM_VPC, OVERLAY_PORT};
use std::net::{IpAddr, SocketAddr, TcpListener, TcpStream, UdpSocket};
use std::time::Duration;

pub fn run(opts: &Opts) -> Res<()> {
    let bind: IpAddr = opts.str_or("bind", "0.0.0.0").parse()?;
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
    stream.set_nonblocking(true)?;
    let mut reader = FrameReader::default();
    let Control::Hello { user, install, class, interactive, udp_port, max_datagram } =
        read_control(&mut stream, &mut reader)?
    else {
        return Err("first message must be hello".into());
    };
    let principal = Principal { user, install, class: parse_class(&class), interactive };
    let max_datagram = if max_datagram <= MAX_DATAGRAM_VPC {
        MAX_DATAGRAM_VPC
    } else {
        MAX_DATAGRAM_DEFAULT.min(max_datagram)
    };
    let Control::Start { key, mode } = read_control(&mut stream, &mut reader)? else {
        return Err("second message must be start".into());
    };
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
    let peer_ip = stream.peer_addr()?.ip();
    let out = match udp_port {
        Some(p) => DatagramOut::Udp { sock: udp.try_clone()?, peer: SocketAddr::new(peer_ip, p) },
        None => DatagramOut::Stream,
    };
    let carrier = if udp_port.is_some() { "udp" } else { "stream" };
    let mut media = MediaSession::open(cfg, max_datagram, out, peer_ip)?;
    let (width, height) = media.size();
    write_control(
        &mut stream,
        &Control::Welcome {
            encoder: media.encoder_name(),
            width,
            height,
            max_datagram,
            carrier: carrier.into(),
        },
    )?;
    write_control(&mut stream, &Control::Started { session })?;
    let reason = media.run(&mut stream, &mut reader, udp, table, session, &principal);
    let _ = table.stop(session, &Actor::Remote(Some(principal.clone())));
    let _ = write_control(&mut stream, &Control::Ended { reason: reason.clone() });
    stream.set_nonblocking(false)?;
    stream.set_read_timeout(Some(Duration::from_millis(200)))?;
    Ok(reason)
}
