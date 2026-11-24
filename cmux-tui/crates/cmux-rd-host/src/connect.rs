//! `cmux-rd connect`: the viewer side of one device hub session, for the app's
//! pane (plans/cmux-next/remote-desktop-mac-host.md section 7). The pane's rd
//! transport rides an ordered byte stream (`RemoteRdByteStream`); this process
//! gives it one on a private Unix socket and carries it over the secure link,
//! passing control messages and datagrams through unchanged. So the pane keeps
//! its decoder, presenters and input, and the link stays in Rust.
//!
//! JSON lines with the app, like `serve`:
//! stdout first: {"key":"<this side's session key>"} (the app signs it: the offer)
//! stdin setup: {"session":"..","peer_key":"<host session key, checked by the app>",
//!   "stun":[..],"candidates":[..],"socket":"<path in a 0700 directory>",
//!   "relay_note":"<the hub's ticket `relayNote`, when billing could not be read>"}
//! stdout then: {"candidate":".."}, {"listening":true}, {"connected":true},
//!   {"path":{..}}, {"ended":".."}
//! An `ended` that starts `host: ` carries the host's own cmux.rd/1 `ended` reason (for example
//! `host: failed: <capture error>`), read off the link whether or not the pane was attached, so
//! the app can say why the host stopped rather than only that the link closed.
//! stdin later: {"candidate":".."} or {"stop":true}. A trickled candidate that arrives while
//! the app prepares the answer's socket directory is kept until the answer supplies the key.
//!
//! One pane connects to the socket; a second connection is refused.

use crate::carrier::{Carrier, LinkCarrier};
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
    /// Raw signed peer marker: omission preserves the legacy protocol.
    #[serde(default)]
    peer_carrier: crate::carrier::LinkMode,
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
    /// Why the hub sent no relay when billing gave no answer (its ticket's `relayNote`, "could
    /// not read your plan"), so a failed link says that rather than reading as a free plan.
    #[serde(default)]
    relay_note: Option<String>,
}

#[derive(Deserialize)]
struct Later {
    #[serde(default)]
    candidate: Option<String>,
    #[serde(default)]
    stop: bool,
}

/// The app forwards trickled routes while its answer hand-off prepares a private socket.
/// Only an answer can start the link. Keep a bounded set of parsed routes in the meantime.
fn read_answer(mut input: impl BufRead) -> Res<Answer> {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct EarlyCandidate {
        candidate: String,
    }

    const MAX_EARLY_CANDIDATES: usize = 32;
    let mut early = Vec::new();
    let mut line = String::new();
    loop {
        line.clear();
        if input.read_line(&mut line)? == 0 {
            return Err("the app closed the session's input before its answer".into());
        }
        match serde_json::from_str::<Answer>(&line) {
            Ok(mut answer) => {
                answer.candidates.extend(early.iter().map(Candidate::to_wire));
                return Ok(answer);
            }
            Err(error) => {
                let route: EarlyCandidate =
                    serde_json::from_str(&line).map_err(|_| format!("answer line: {error}"))?;
                if let Some(candidate) = Candidate::from_wire(&route.candidate) {
                    if early.len() < MAX_EARLY_CANDIDATES && !early.contains(&candidate) {
                        early.push(candidate);
                    }
                }
            }
        }
    }
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
    let answer = read_answer(io::stdin().lock())?;
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
    let mut link = LinkCarrier::new(net, crate::wg_carrier::Role::Viewer, answer.peer_carrier)?;
    say(AppLine { listening: true, ..AppLine::default() });
    // SAFETY: fcntl on our own stdin, after the blocking answer read.
    unsafe {
        libc::fcntl(
            libc::STDIN_FILENO,
            libc::F_SETFL,
            libc::fcntl(libc::STDIN_FILENO, libc::F_GETFL) | libc::O_NONBLOCK,
        );
    }
    let reason = bridge(&mut link, &listener, answer.relay_note.as_deref())
        .unwrap_or_else(|e| format!("failed: {e}"));
    let _ = std::fs::remove_file(&answer.socket);
    if let Some(fallback) = link.take_fallback() {
        say(AppLine { fallback: Some(fallback), ..AppLine::default() });
    } else {
        say(AppLine { ended: Some(reason), ..AppLine::default() });
    }
    drop(link);
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

fn bridge(
    link: &mut LinkCarrier,
    listener: &UnixListener,
    relay_note: Option<&str>,
) -> Res<String> {
    let mut pane: Option<UnixStream> = None;
    let mut reader = FrameReader::default();
    let mut app = Vec::new();
    // Lines that came in the same read as the answer sit in stdin's buffer, where a wait on the
    // descriptor never sees them: the first pass reads them before waiting.
    let mut first = true;
    // The host's `ended` reason, once it said one (the link closes right after).
    let mut host_said: Option<String> = None;
    loop {
        let mut fds = link.fds();
        fds.push(libc::STDIN_FILENO);
        match &pane {
            Some(stream) => fds.push(stream.as_raw_fd()),
            None => fds.push(listener.as_raw_fd()),
        }
        if !std::mem::take(&mut first) {
            wait_readable(&fds, Some(if link.media_ready() { 1_000_000_000 } else { 25_000_000 }))?;
        }
        for later in app_lines(&mut app)? {
            if later.stop {
                link.invalidate();
                return Ok("stopped by the viewer".into());
            }
            if let Some(c) = later.candidate.as_deref().and_then(Candidate::from_wire) {
                link.net.add_remote_candidate(c);
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
                        FRAME_CONTROL => link.net.send_control(payload),
                        FRAME_DATAGRAM => {
                            if link.media_ready() {
                                link.send_datagram(&payload)?;
                            }
                        }
                        _ => {}
                    }
                }
            }
        }
        for event in link.events() {
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
                    return Ok(ended_line(host_said.as_deref(), None, relay_note));
                }
                NetEvent::Failed(reason) => {
                    return Ok(ended_line(host_said.as_deref(), Some(reason.as_str()), relay_note));
                }
                _ => {}
            }
        }
        if link.retry_ready() {
            return Ok("carrier retry acknowledged".into());
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
/// reason when it said one before (`host: <reason>`), else what this side saw. A failed link
/// with no relay because billing could not be read says so (`relay_note`).
fn ended_line(
    host_said: Option<&str>,
    link_failed: Option<&str>,
    relay_note: Option<&str>,
) -> String {
    match (host_said, link_failed) {
        (Some(reason), _) => format!("host: {reason}"),
        (None, Some(why)) => match relay_note {
            Some(note) => format!("link failed: {why}; no relay: {note}"),
            None => format!("link failed: {why}"),
        },
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
        assert_eq!(ended_line(said.as_deref(), None, None), "host: failed: capture: no frame");
        assert_eq!(
            ended_line(said.as_deref(), Some("timeout"), None),
            "host: failed: capture: no frame"
        );
        assert_eq!(ended_line(None, Some("timeout"), None), "link failed: timeout");
        assert_eq!(ended_line(None, None, None), "the host ended the session");
    }

    #[test]
    fn a_failed_link_with_no_relay_because_billing_was_unread_says_so() {
        let note = Some("could not read your plan");
        assert_eq!(
            ended_line(None, Some("the secure handshake timed out"), note),
            "link failed: the secure handshake timed out; no relay: could not read your plan"
        );
        // The host's own reason still wins, and a link that closed cleanly needs no note.
        assert_eq!(ended_line(Some("stopped"), Some("timeout"), note), "host: stopped");
        assert_eq!(ended_line(None, None, note), "the host ended the session");
        let answer: Answer = serde_json::from_str(
            r#"{"session":"s","peer_key":"00","socket":"/tmp/x","relay_note":"could not read your plan"}"#,
        )
        .unwrap();
        assert_eq!(answer.relay_note.as_deref(), note);
    }
}
