//! A TURN server reached over TCP or TLS-over-TCP (RFC 8656 §3.1), for a network that
//! blocks UDP: the allocation is still UDP on the server's side, so the peer sends to the
//! relayed address as to any other, but this side talks to the server over one stream.
//!
//! On a stream, STUN messages and ChannelData messages follow each other with nothing
//! between them: a STUN message is its 20-byte header plus the length in it (always a
//! multiple of 4), a ChannelData message its 4-byte header plus the length in it, padded
//! to a multiple of 4 (RFC 8656 §12.5). [`Deframer`] splits what arrives; [`frame`] pads
//! what leaves. The sans-IO [`crate::turn::TurnClient`] is the same as over UDP.
//!
//! The socket is nonblocking from its connect on: the driver waits on it beside the UDP
//! socket ([`StreamRelay::raw`], [`StreamRelay::wants_write`]) and never blocks on it.

use super::sys::{self, Raw};
use std::io::{self, Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::sync::{Arc, OnceLock};

/// How long the TCP connect and the TLS handshake together may take.
pub(super) const CONNECT_US: u64 = 5_000_000;
/// Bytes this side lets wait for the stream before it drops a packet, as a full UDP send
/// buffer would: a slow relay must not grow a queue of stale video.
const MAX_BACKLOG: usize = 1 << 20;
/// Most bytes read from one stream in one driver turn, so a busy relay cannot starve the
/// UDP socket.
const MAX_READ_PER_TURN: usize = 1 << 20;
const READ_CHUNK: usize = 64 * 1024;

/// The stream is not TURN framing (a byte that starts neither a STUN message nor
/// ChannelData, or a STUN length that is not a multiple of 4): nothing after it can be
/// trusted to start a message, so the relay ends.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct Desync(pub u8);

/// Splits a TURN stream into whole messages, without their padding.
#[derive(Default)]
pub(super) struct Deframer {
    buf: Vec<u8>,
    /// Where the next message starts in `buf`; consumed bytes are dropped in bulk.
    start: usize,
}

impl Deframer {
    pub(super) fn push(&mut self, bytes: &[u8]) {
        if self.start > 0 {
            self.buf.drain(..self.start);
            self.start = 0;
        }
        self.buf.extend_from_slice(bytes);
    }

    /// The next whole message: a STUN message, or a ChannelData message without its
    /// padding. `None` until all of it (and its padding) arrived.
    pub(super) fn next_frame(&mut self) -> Result<Option<&[u8]>, Desync> {
        let available = self.buf.get(self.start..).unwrap_or_default();
        let Some(&[first, _, l0, l1]) = available.first_chunk::<4>() else { return Ok(None) };
        let length = usize::from(u16::from_be_bytes([l0, l1]));
        let (whole, padded) = match first {
            0..=3 if length % 4 == 0 => (20 + length, 20 + length),
            0x40..=0x4F => (4 + length, (4 + length).next_multiple_of(4)),
            other => return Err(Desync(other)),
        };
        if available.len() < padded {
            return Ok(None);
        }
        let at = self.start;
        self.start += padded;
        Ok(self.buf.get(at..at + whole))
    }
}

/// `packet` as it goes on a stream: ChannelData padded to a multiple of 4 (a STUN
/// message already is one).
pub(super) fn frame(packet: &[u8], out: &mut Vec<u8>) {
    out.extend_from_slice(packet);
    if matches!(packet.first(), Some(0x40..=0x4F)) {
        out.resize(out.len() + (packet.len().next_multiple_of(4) - packet.len()), 0);
    }
}

/// The TLS client settings, read once per process: the OS trust store, not a compiled-in
/// root list (a bundled list kept trusting the leaked emSign roots, manaflow-ai/cmux#25452),
/// and the workspace's ring provider.
fn tls_config() -> Result<Arc<rustls::ClientConfig>, String> {
    static CONFIG: OnceLock<Result<Arc<rustls::ClientConfig>, String>> = OnceLock::new();
    CONFIG
        .get_or_init(|| {
            let mut roots = rustls::RootCertStore::empty();
            let (added, _) =
                roots.add_parsable_certificates(rustls_native_certs::load_native_certs().certs);
            if added == 0 {
                return Err("no platform root certificates".to_owned());
            }
            let config = rustls::ClientConfig::builder_with_provider(Arc::new(
                rustls::crypto::ring::default_provider(),
            ))
            .with_safe_default_protocol_versions()
            .map_err(|e| e.to_string())?
            .with_root_certificates(roots)
            .with_no_client_auth();
            Ok(Arc::new(config))
        })
        .clone()
}

enum Phase {
    /// The TCP connect is in flight; the relay gives up at `deadline_us`.
    Connecting { deadline_us: u64 },
    /// Connected (TLS: the handshake may still run, until `deadline_us`).
    Open { deadline_us: u64 },
}

/// One TCP or TLS connection to a TURN server.
pub(super) struct StreamRelay {
    tcp: TcpStream,
    /// TLS: the name the server's certificate must carry; the connection once TCP is up.
    tls_name: Option<rustls::pki_types::ServerName<'static>>,
    tls: Option<Box<rustls::ClientConnection>>,
    phase: Phase,
    /// Framed bytes not yet taken by the socket (TCP) or by rustls (TLS).
    out: Vec<u8>,
    deframer: Deframer,
}

impl StreamRelay {
    /// Starts a nonblocking connect to `server`; `tls_name` asks for TLS with that name.
    pub(super) fn connect(
        server: SocketAddr,
        tls_name: Option<&str>,
        now_us: u64,
    ) -> io::Result<Self> {
        let tls_name = tls_name
            .map(|name| {
                rustls::pki_types::ServerName::try_from(name.to_owned())
                    .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))
            })
            .transpose()?;
        let socket = socket2::Socket::new(
            socket2::Domain::for_address(server),
            socket2::Type::STREAM,
            Some(socket2::Protocol::TCP),
        )?;
        socket.set_nonblocking(true)?;
        // Small control messages and media both go out at once.
        socket.set_tcp_nodelay(true)?;
        match socket.connect(&server.into()) {
            Ok(()) => {}
            Err(e) if in_progress(&e) => {}
            Err(e) => return Err(e),
        }
        Ok(Self {
            tcp: socket.into(),
            tls_name,
            tls: None,
            phase: Phase::Connecting { deadline_us: now_us.saturating_add(CONNECT_US) },
            out: Vec::new(),
            deframer: Deframer::default(),
        })
    }

    pub(super) fn raw(&self) -> Raw {
        sys::raw_stream(&self.tcp)
    }

    /// TCP is up and, for TLS, the handshake is done: the TURN client may start.
    pub(super) fn is_ready(&self) -> bool {
        matches!(self.phase, Phase::Open { .. })
            && self.tls.as_ref().is_none_or(|tls| !tls.is_handshaking())
    }

    /// The driver should wake when the socket can take bytes.
    pub(super) fn wants_write(&self) -> bool {
        matches!(self.phase, Phase::Connecting { .. })
            || !self.out.is_empty()
            || self.tls.as_ref().is_some_and(|tls| tls.wants_write())
    }

    /// When the connect or the handshake gives up, while either runs.
    pub(super) fn deadline_us(&self) -> Option<u64> {
        match self.phase {
            Phase::Connecting { deadline_us } => Some(deadline_us),
            Phase::Open { deadline_us } if !self.is_ready() => Some(deadline_us),
            Phase::Open { .. } => None,
        }
    }

    /// Moves the connect and the handshake on, and writes what waits. An error ends the relay.
    pub(super) fn poll(&mut self, now_us: u64) -> Result<(), String> {
        if let Phase::Connecting { deadline_us } = self.phase {
            if let Some(e) = self.tcp.take_error().map_err(|e| e.to_string())? {
                return Err(format!("connect: {e}"));
            }
            match self.tcp.peer_addr() {
                Ok(_) => {
                    self.phase = Phase::Open { deadline_us };
                    if let Some(name) = self.tls_name.clone() {
                        let mut tls = rustls::ClientConnection::new(tls_config()?, name)
                            .map_err(|e| format!("tls: {e}"))?;
                        tls.set_buffer_limit(Some(MAX_BACKLOG));
                        self.tls = Some(Box::new(tls));
                    }
                }
                Err(_) if now_us >= deadline_us => return Err("connect timed out".to_owned()),
                Err(_) => return Ok(()),
            }
        }
        if !self.is_ready() && self.deadline_us().is_some_and(|at| now_us >= at) {
            return Err("tls handshake timed out".to_owned());
        }
        self.flush()
    }

    /// Queues one TURN message (framed) and writes what the socket takes now. `None` when
    /// the backlog is full or the stream is not ready: the packet is dropped, as UDP would.
    pub(super) fn send(&mut self, packet: &[u8]) -> Option<usize> {
        if !self.is_ready() || self.out.len() + packet.len() > MAX_BACKLOG {
            return None;
        }
        let before = self.out.len();
        frame(packet, &mut self.out);
        let wire = self.out.len() - before;
        // A write error shows on the next read or poll, which ends the relay.
        let _ = self.flush();
        Some(wire)
    }

    fn flush(&mut self) -> Result<(), String> {
        match self.tls.as_deref_mut() {
            None => {
                let mut written = 0;
                while written < self.out.len() {
                    match (&self.tcp).write(self.out.get(written..).unwrap_or_default()) {
                        Ok(0) => return Err("the relay closed the stream".to_owned()),
                        Ok(n) => written += n,
                        Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                        Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                        Err(e) => return Err(format!("write: {e}")),
                    }
                }
                self.out.drain(..written);
            }
            Some(tls) => {
                if !tls.is_handshaking() && !self.out.is_empty() {
                    let taken = tls.writer().write(&self.out).map_err(|e| format!("tls: {e}"))?;
                    self.out.drain(..taken);
                }
                while tls.wants_write() {
                    match tls.write_tls(&mut &self.tcp) {
                        Ok(0) => return Err("the relay closed the stream".to_owned()),
                        Ok(_) => {}
                        Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                        Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                        Err(e) => return Err(format!("write: {e}")),
                    }
                }
            }
        }
        Ok(())
    }

    /// Reads what arrived and hands each whole TURN message to `each`. An error (the
    /// server closed, a TLS alert, a stream that is not TURN framing) ends the relay.
    pub(super) fn read(&mut self, mut each: impl FnMut(&[u8])) -> Result<(), String> {
        const CLOSED: &str = "the relay closed the stream";
        if matches!(self.phase, Phase::Connecting { .. }) {
            return Ok(());
        }
        let mut chunk = [0u8; READ_CHUNK];
        let mut total = 0;
        while total < MAX_READ_PER_TURN {
            let (n, more) = match self.tls.as_deref_mut() {
                None => match (&self.tcp).read(&mut chunk) {
                    Ok(0) => return Err(CLOSED.to_owned()),
                    Ok(n) => {
                        self.deframer.push(chunk.get(..n).unwrap_or_default());
                        (n, true)
                    }
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                    Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                    Err(e) => return Err(format!("read: {e}")),
                },
                Some(tls) => {
                    let (n, more) = match tls.read_tls(&mut &self.tcp) {
                        Ok(0) => return Err(CLOSED.to_owned()),
                        Ok(n) => (n, true),
                        Err(e) if e.kind() == io::ErrorKind::WouldBlock => (0, false),
                        Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                        Err(e) => return Err(format!("read: {e}")),
                    };
                    let state = tls.process_new_packets().map_err(|e| format!("tls: {e}"))?;
                    let mut left = state.plaintext_bytes_to_read();
                    while left > 0 {
                        let got = tls.reader().read(&mut chunk).map_err(|e| format!("tls: {e}"))?;
                        if got == 0 {
                            break;
                        }
                        self.deframer.push(chunk.get(..got).unwrap_or_default());
                        left = left.saturating_sub(got);
                    }
                    (n, more)
                }
            };
            total += n;
            loop {
                match self.deframer.next_frame() {
                    Ok(Some(message)) => each(message),
                    Ok(None) => break,
                    Err(Desync(byte)) => {
                        return Err(format!("the relay stream is not TURN (byte {byte:#04x})"));
                    }
                }
            }
            if !more {
                break;
            }
        }
        // The handshake's answers and anything rustls queued while reading go out now.
        self.flush()
    }

    /// The last messages (an allocation's Refresh with lifetime 0), written once, best effort.
    pub(super) fn close(&mut self, packets: Vec<Vec<u8>>) {
        for packet in packets {
            let _ = self.send(&packet);
        }
        if let Some(tls) = self.tls.as_deref_mut() {
            tls.send_close_notify();
        }
        let _ = self.flush();
        let _ = self.tcp.shutdown(std::net::Shutdown::Write);
    }
}

/// A nonblocking connect that has started and not yet finished.
fn in_progress(e: &io::Error) -> bool {
    #[cfg(unix)]
    if e.raw_os_error() == Some(libc::EINPROGRESS) {
        return true;
    }
    e.kind() == io::ErrorKind::WouldBlock
}

#[cfg(test)]
#[path = "stream_relay_tests.rs"]
mod tests;
