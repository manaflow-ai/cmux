//! `cmux-rd connect`: the viewer side of one device hub session, for the app's
//! pane (plans/cmux-next/remote-desktop-mac-host.md section 7). The pane's rd
//! transport rides an ordered byte stream (`RemoteRdByteStream`); this process
//! gives it one on a private Unix socket and carries it over the secure link,
//! passing control messages and datagrams through unchanged. So the pane keeps
//! its decoder, presenters and input, and the link stays in Rust.
//!
//! JSON lines with the app, like `serve`:
//! stdout first: {"key":"<this side's session key>"} (the app signs it: the offer)
//! stdin first: {"session":"..","peer_key":"<host session key, checked by the app>",
//!   "stun":[..],"candidates":[..],"socket":"<path in a 0700 directory>"}
//! stdout then: {"candidate":".."}, {"listening":true}, {"connected":true},
//!   {"path":{..}}, {"ended":".."}
//! stdin later: {"candidate":".."} or {"stop":true}
//!
//! One pane connects to the socket; a second connection is refused.

use crate::fdwait::wait_readable;
use crate::wire::{write_frame, FrameReader, FRAME_CONTROL, FRAME_DATAGRAM};
use crate::Res;
use cmux_rd_link::net::{Candidate, Net, NetConfig, NetEvent};
use cmux_rd_link::{EndpointEvent, Event, KeyPair, Role};
use serde::Deserialize;
use serde_json::json;
use std::io::{self, BufRead, Read, Write};
use std::net::SocketAddr;
use std::os::fd::AsRawFd;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};

#[derive(Deserialize)]
struct Answer {
    session: String,
    peer_key: String,
    #[serde(default)]
    stun: Vec<String>,
    #[serde(default)]
    candidates: Vec<String>,
    socket: String,
}

#[derive(Deserialize)]
struct Later {
    #[serde(default)]
    candidate: Option<String>,
    #[serde(default)]
    stop: bool,
}

fn say(line: serde_json::Value) {
    let mut out = io::stdout().lock();
    let _ = writeln!(out, "{line}");
    let _ = out.flush();
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

pub fn run() -> Res<()> {
    let keys = KeyPair::generate()?;
    say(json!({"key": keys.public.iter().map(|b| format!("{b:02x}")).collect::<String>()}));
    let mut line = String::new();
    io::stdin().lock().read_line(&mut line)?;
    let answer: Answer = serde_json::from_str(&line).map_err(|e| format!("answer line: {e}"))?;
    let peer = unhex32(&answer.peer_key).ok_or("peer_key must be 64 hex characters")?;
    let stun: Vec<SocketAddr> = answer
        .stun
        .iter()
        .filter_map(|s| std::net::ToSocketAddrs::to_socket_addrs(s).ok()?.find(SocketAddr::is_ipv4))
        .collect();
    // The socket's directory is the app's private one; the socket itself is the user's only.
    let _ = std::fs::remove_file(&answer.socket);
    let listener = UnixListener::bind(&answer.socket)?;
    std::fs::set_permissions(&answer.socket, std::fs::Permissions::from_mode(0o600))?;
    listener.set_nonblocking(true)?;
    let net = Net::start(NetConfig {
        role: Role::Initiator,
        session: answer.session.into_bytes(),
        local: keys,
        expected_remote: peer,
        stun,
        bind: "0.0.0.0:0".parse()?,
    })?;
    for c in answer.candidates.iter().filter_map(|c| Candidate::from_wire(c)) {
        net.add_remote_candidate(c);
    }
    say(json!({"listening": true}));
    // SAFETY: fcntl on our own stdin, after the blocking answer read.
    unsafe {
        libc::fcntl(
            libc::STDIN_FILENO,
            libc::F_SETFL,
            libc::fcntl(libc::STDIN_FILENO, libc::F_GETFL) | libc::O_NONBLOCK,
        );
    }
    let reason = bridge(&net, &listener).unwrap_or_else(|e| format!("failed: {e}"));
    let _ = std::fs::remove_file(&answer.socket);
    say(json!({"ended": reason}));
    drop(net);
    Ok(())
}

/// Reads the app's later lines without blocking.
fn app_lines(buf: &mut Vec<u8>) -> Result<Vec<Later>, String> {
    let mut chunk = [0u8; 4096];
    loop {
        match io::stdin().lock().read(&mut chunk) {
            Ok(0) => return Err("the app closed the session's input".into()),
            Ok(n) => buf.extend_from_slice(&chunk[..n]),
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
            Err(e) => return Err(format!("app input failed: {e}")),
        }
    }
    let mut lines = Vec::new();
    while let Some(end) = buf.iter().position(|b| *b == b'\n') {
        let line: Vec<u8> = buf.drain(..=end).collect();
        if let Ok(later) = serde_json::from_slice::<Later>(&line) {
            lines.push(later);
        }
    }
    Ok(lines)
}

fn bridge(net: &Net, listener: &UnixListener) -> Res<String> {
    let mut pane: Option<UnixStream> = None;
    let mut reader = FrameReader::default();
    let mut app = Vec::new();
    loop {
        let mut fds = vec![net.event_fd(), libc::STDIN_FILENO];
        match &pane {
            Some(stream) => fds.push(stream.as_raw_fd()),
            None => fds.push(listener.as_raw_fd()),
        }
        wait_readable(&fds, Some(1_000_000_000))?;
        for later in app_lines(&mut app)? {
            if later.stop {
                return Ok("stopped by the viewer".into());
            }
            if let Some(c) = later.candidate.as_deref().and_then(Candidate::from_wire) {
                net.add_remote_candidate(c);
            }
        }
        match &mut pane {
            None => match listener.accept() {
                Ok((stream, _)) => {
                    stream.set_nonblocking(true)?;
                    pane = Some(stream);
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
                Err(e) => return Err(e.into()),
            },
            Some(stream) => {
                // A second pane is refused at once.
                if let Ok((extra, _)) = listener.accept() {
                    drop(extra);
                }
                if let Err(e) = reader.fill(stream) {
                    return Ok(format!("the pane closed: {e}"));
                }
                while let Some((ty, payload)) = reader.next()? {
                    match ty {
                        FRAME_CONTROL => net.send_control(payload),
                        FRAME_DATAGRAM => net.send_datagram(payload),
                        _ => {}
                    }
                }
            }
        }
        for event in net.events() {
            match event {
                NetEvent::Candidate(c) => say(json!({"candidate": c.to_wire()})),
                NetEvent::Endpoint(EndpointEvent::Link(Event::Established)) => {
                    say(json!({"connected": true}));
                }
                NetEvent::Endpoint(EndpointEvent::PathChanged { kind, rtt_us, .. }) => {
                    say(json!({"path": {
                        "kind": kind.map(|k| k.wire_name()),
                        "rtt_ms": rtt_us.map(|us| us as f64 / 1000.0),
                    }}));
                }
                NetEvent::Endpoint(EndpointEvent::Link(Event::Control(record))) => {
                    if let Some(stream) = &mut pane {
                        write_frame(stream, FRAME_CONTROL, &record)?;
                    }
                }
                NetEvent::Endpoint(EndpointEvent::Link(Event::Datagram(datagram))) => {
                    if let Some(stream) = &mut pane {
                        write_frame(stream, FRAME_DATAGRAM, &datagram)?;
                    }
                }
                NetEvent::Endpoint(EndpointEvent::Link(Event::Closed)) => {
                    return Ok("the host ended the session".into());
                }
                NetEvent::Failed(reason) => return Ok(format!("link failed: {reason}")),
                _ => {}
            }
        }
    }
}
