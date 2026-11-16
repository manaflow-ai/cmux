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
//!
//! With `"assemble":true` in the answer (design D7, screen-share-under-100ms.md piece 5)
//! stream 0's video and parity datagrams stop here: [`ViewerHop`] reassembles them, sends
//! their feedback, and writes the pane one whole frame at a time (`STREAM_LOCAL_FRAME`),
//! the next once the pane reports the last consumed (`STREAM_LOCAL_REPORT`).

use crate::fdwait::wait_readable;
use crate::viewer_hop::ViewerHop;
use crate::wire::{write_frame, FrameReader, FRAME_CONTROL, FRAME_DATAGRAM};
use crate::Res;
use cmux_rd_link::net::{Candidate, Net, NetConfig, NetEvent};
use cmux_rd_link::{EndpointEvent, Event, KeyPair, Role};
use cmux_rd_proto::app_line::{AppLine, LineHop, LinePath};
use cmux_rd_proto::{LocalReport, STREAM_LOCAL_FRAME, STREAM_LOCAL_REPORT};
use serde::Deserialize;
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
    /// The hub's TURN relays, for a relayed path when no direct one works.
    #[serde(default)]
    turn: Vec<crate::carrier::TurnSetup>,
    #[serde(default)]
    candidates: Vec<String>,
    socket: String,
    /// The person's "relay only": this side reaches the host through TURN alone.
    #[serde(default)]
    relay_only: bool,
    /// The app takes whole frames of stream 0 (design D7): this process reassembles it
    /// and runs its feedback ([`ViewerHop`]). An older app leaves it out and gets
    /// datagrams, as before.
    #[serde(default)]
    assemble: bool,
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
        turn: crate::carrier::turn_servers(&answer.turn),
        relay_only: answer.relay_only,
    })?;
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
    let hop = answer.assemble.then(|| ViewerHop::new(HOP_DEADLINE_US, HOP_NACK_AFTER_US));
    let reason = bridge(&net, &listener, hop).unwrap_or_else(|e| format!("failed: {e}"));
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

/// Reassembly deadline and NACK delay of the hop's receiver: the values the app's session
/// used while it reassembled (RemoteRdSession's defaults).
const HOP_DEADLINE_US: u64 = 200_000;
const HOP_NACK_AFTER_US: u64 = 5_000;
/// How often the hop's frame timings are summarized (an `AppLine` `hop`).
const HOP_LOG_US: u64 = 5_000_000;

/// Monotonic microseconds on the clock the app reads too: `CLOCK_UPTIME_RAW` on macOS
/// (mach absolute time: `DispatchTime.uptimeNanoseconds`, `CACurrentMediaTime`), so a
/// frame's release time here and its presented time there subtract.
fn now_us() -> u64 {
    #[cfg(target_os = "macos")]
    let clock = libc::CLOCK_UPTIME_RAW;
    #[cfg(not(target_os = "macos"))]
    let clock = libc::CLOCK_MONOTONIC;
    let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    // SAFETY: a valid clock id and a pointer to a local timespec.
    unsafe { libc::clock_gettime(clock, &mut ts) };
    (ts.tv_sec as u64).saturating_mul(1_000_000) + (ts.tv_nsec as u64) / 1_000
}

/// The hop's per-frame timings, summarized on one `hop` line every [`HOP_LOG_US`].
#[derive(Default)]
struct HopLog {
    since_us: u64,
    decoded: Vec<u64>,
    decode: Vec<u64>,
    presented: Vec<u64>,
}

/// The `q` quantile of `v` in milliseconds (sorts `v`).
fn quantile_ms(v: &mut [u64], q: f64) -> Option<f64> {
    v.sort_unstable();
    let i = ((v.len() as f64 - 1.0) * q).round() as usize;
    v.get(i).map(|us| *us as f64 / 1000.0)
}

impl HopLog {
    fn note(&mut self, hop: &mut ViewerHop, now: u64) {
        for t in hop.take_timings() {
            self.decoded.extend(t.release_to_decoded_us);
            self.decode.extend(t.decode_us.map(u64::from));
            self.presented.extend(t.release_to_presented_us);
        }
        if now.saturating_sub(self.since_us) < HOP_LOG_US {
            return;
        }
        self.since_us = now;
        if self.presented.is_empty() && self.decoded.is_empty() {
            return;
        }
        let s = hop.stats();
        let line = LineHop {
            release_to_decoded_ms_p50: quantile_ms(&mut self.decoded, 0.5),
            decode_ms_p50: quantile_ms(&mut self.decode, 0.5),
            release_to_presented_ms_p50: quantile_ms(&mut self.presented, 0.5),
            release_to_presented_ms_p95: quantile_ms(&mut self.presented, 0.95),
            presented: self.presented.len() as u64,
            sent: s.sent,
            replaced: s.replaced,
            overrun: s.overrun,
            credit_timeouts: s.credit_timeouts,
        };
        say(AppLine { hop: Some(line), ..AppLine::default() });
        self.decoded.clear();
        self.decode.clear();
        self.presented.clear();
    }
}

fn bridge(net: &Net, listener: &UnixListener, mut hop: Option<ViewerHop>) -> Res<String> {
    let mut pane: Option<UnixStream> = None;
    let mut reader = FrameReader::default();
    let mut app = Vec::new();
    let mut hop_log = HopLog::default();
    // Lines that came in the same read as the answer sit in stdin's buffer, where a wait on the
    // descriptor never sees them: the first pass reads them before waiting.
    let mut first = true;
    loop {
        let mut fds = vec![net.event_fd(), libc::STDIN_FILENO];
        match &pane {
            Some(stream) => fds.push(stream.as_raw_fd()),
            None => fds.push(listener.as_raw_fd()),
        }
        if !std::mem::take(&mut first) {
            // The hop's reassembly deadlines, NACKs and feedback are due on time, not at
            // the next packet.
            let wait_ns = hop.as_ref().map_or(1_000_000_000, |h| {
                h.next_deadline_us()
                    .saturating_sub(now_us())
                    .saturating_mul(1_000)
                    .min(1_000_000_000)
            });
            wait_readable(&fds, Some(wait_ns))?;
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
                        STREAM_LOCAL_REPORT => {
                            if let (Some(h), Ok(report)) = (&mut hop, LocalReport::decode(&payload))
                            {
                                h.on_report(report, now_us());
                            }
                        }
                        _ => {}
                    }
                }
            }
        }
        for event in net.events() {
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
                    if let Some(stream) = &mut pane {
                        write_frame(stream, FRAME_CONTROL, &record)?;
                    }
                }
                NetEvent::Endpoint(EndpointEvent::Link(Event::Datagram(datagram))) => {
                    match &mut hop {
                        // The display stream's media stays here: reassembled into frames.
                        Some(h) if ViewerHop::takes(&datagram) => {
                            h.push_datagram(&datagram, now_us())
                        }
                        _ => {
                            if let Some(stream) = &mut pane {
                                write_frame(stream, FRAME_DATAGRAM, &datagram)?;
                            }
                        }
                    }
                }
                NetEvent::Endpoint(EndpointEvent::Link(Event::Closed)) => {
                    return Ok("the host ended the session".into());
                }
                NetEvent::Failed(reason) => return Ok(format!("link failed: {reason}")),
                _ => {}
            }
        }
        if let Some(h) = &mut hop {
            let now = now_us();
            h.tick(now);
            if let Some(stream) = &mut pane {
                if let Some(frame) = h.next_frame(now) {
                    // One write per frame: the app reads it whole.
                    write_frame(stream, STREAM_LOCAL_FRAME, &frame.encode())?;
                }
            }
            for datagram in h.feedback(now) {
                net.send_datagram(datagram);
            }
            hop_log.note(h, now);
        }
    }
}
