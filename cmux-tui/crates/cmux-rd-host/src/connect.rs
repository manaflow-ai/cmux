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
//! An `ended` that starts `host: ` carries the host's own cmux.rd/1 `ended` reason (for example
//! `host: failed: <capture error>`), read off the link whether or not the pane was attached, so
//! the app can say why the host stopped rather than only that the link closed.
//! stdin later: {"candidate":".."} or {"stop":true}
//!
//! One pane connects to the socket; a second connection is refused.

use crate::fdwait::wait_readable;
use crate::wire::{write_frame, FrameReader, FRAME_CONTROL, FRAME_DATAGRAM};
use crate::Res;
use cmux_rd_link::net::{Candidate, Net, NetConfig, NetEvent};
use cmux_rd_link::{EndpointEvent, Event, KeyPair, Role};
use cmux_rd_proto::app_line::{AppLine, LinePath};
use serde::Deserialize;
use std::io::{self, BufRead, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};

#[derive(Deserialize)]
struct Answer {
    session: String,
    peer_key: String,
    #[serde(default)]
    stun: Vec<String>,
    /// The hub's TURN relays, for a relayed path when no direct one works.
    #[serde(default)]
    turn: Vec<crate::carrier::TurnSetup>,
    #[serde(default)]
    candidates: Vec<String>,
    socket: String,
    /// The person's "relay only": this side reaches the host through TURN alone.
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
    say(AppLine {
        key: Some(keys.public.iter().map(|b| format!("{b:02x}")).collect::<String>()),
        ..AppLine::default()
    });
    let mut line = String::new();
    io::stdin().lock().read_line(&mut line)?;
    let answer: Answer = serde_json::from_str(&line).map_err(|e| format!("answer line: {e}"))?;
    let peer = unhex32(&answer.peer_key).ok_or("peer_key must be 64 hex characters")?;
    let (stun, stun_later) = crate::carrier::stun_servers(&answer.stun, answer.relay_only);
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
        turn: crate::carrier::turn_servers(&answer.turn),
        relay_only: answer.relay_only,
    })?;
    if let Some(later) = stun_later {
        net.add_stun_later(later);
    }
    // A host that dies without a close ends this viewer instead of freezing it.
    net.set_peer_lost(Some(std::time::Duration::from_micros(cmux_rd_link::PEER_LOST_US)));
    for c in answer.candidates.iter().filter_map(|c| Candidate::from_wire(c)) {
        net.add_remote_candidate(c);
    }
    say(AppLine { listening: true, ..AppLine::default() });
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
    say(AppLine { ended: Some(reason), ..AppLine::default() });
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
    // Lines that came in the same read as the answer sit in stdin's buffer, where a wait on the
    // descriptor never sees them: the first pass reads them before waiting.
    let mut first = true;
    // The host's `ended` reason, once it said one (the link closes right after).
    let mut host_said: Option<String> = None;
    loop {
        let mut fds = vec![net.event_fd(), libc::STDIN_FILENO];
        match &pane {
            Some(stream) => fds.push(stream.as_raw_fd()),
            None => fds.push(listener.as_raw_fd()),
        }
        if !std::mem::take(&mut first) {
            wait_readable(&fds, Some(1_000_000_000))?;
        }
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
            if let Some(line) = event.phase_line() {
                println!("{line}");
            }
            match event {
                NetEvent::Candidate(c) => {
                    say(AppLine { candidate: Some(c.to_wire()), ..AppLine::default() })
                }
                NetEvent::Endpoint(EndpointEvent::Link(Event::Established)) => {
                    say(AppLine { connected: true, ..AppLine::default() });
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
                NetEvent::Endpoint(EndpointEvent::Link(Event::Control(record))) => {
                    if let Some(reason) = host_ended(&record) {
                        host_said = Some(reason);
                    }
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
                    return Ok(ended_line(host_said.as_deref(), None));
                }
                NetEvent::Failed(reason) => {
                    return Ok(ended_line(host_said.as_deref(), Some(reason.as_str())));
                }
                _ => {}
            }
        }
    }
}

/// The host's reason when `record` is its cmux.rd/1 `ended` control message.
fn host_ended(record: &[u8]) -> Option<String> {
    match serde_json::from_slice::<crate::wire::Control>(record).ok()? {
        crate::wire::Control::Ended { reason } => Some(reason),
        _ => None,
    }
}

/// The `ended` line once the link closed (`link_failed`: it failed, and why): the host's own
/// reason when it said one before (`host: <reason>`), else what this side saw.
fn ended_line(host_said: Option<&str>, link_failed: Option<&str>) -> String {
    match (host_said, link_failed) {
        (Some(reason), _) => format!("host: {reason}"),
        (None, Some(why)) => format!("link failed: {why}"),
        (None, None) => "the host ended the session".into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_hosts_own_reason_wins_over_the_close() {
        let ended = serde_json::to_vec(&crate::wire::Control::Ended {
            reason: "failed: capture: no frame".into(),
        })
        .unwrap();
        let said = host_ended(&ended);
        assert_eq!(said.as_deref(), Some("failed: capture: no frame"));
        let started = serde_json::to_vec(&crate::wire::Control::Started { session: 1 }).unwrap();
        assert_eq!(host_ended(&started), None);
        assert_eq!(host_ended(b"not json"), None);
        assert_eq!(ended_line(said.as_deref(), None), "host: failed: capture: no frame");
        assert_eq!(ended_line(said.as_deref(), Some("timeout")), "host: failed: capture: no frame");
        assert_eq!(ended_line(None, Some("timeout")), "link failed: timeout");
        assert_eq!(ended_line(None, None), "the host ended the session");
    }
}
