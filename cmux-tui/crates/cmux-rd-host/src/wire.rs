//! Carriers for `cmux.rd/1` until the overlay datagram service (port 4103, lane 12) lands:
//! UDP datagrams, or one TCP stream that carries control messages and datagrams as frames
//! `u8 type (1 control JSON, 2 datagram)`, `u32 len`, payload.

use serde::{Deserialize, Serialize};
use std::io::{self, Read, Write};
use std::net::{SocketAddr, TcpStream, UdpSocket};

pub const FRAME_CONTROL: u8 = 1;
pub const FRAME_DATAGRAM: u8 = 2;
const MAX_FRAME: usize = 1 << 20;

/// Control messages (JSON) on the stream.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "snake_case")]
pub enum Control {
    /// Client to host, first message. Phase 1: the claims are trusted because the host
    /// listens only on the private VPC or overlay address; the link `hello` token replaces them.
    Hello {
        user: String,
        install: String,
        class: String,
        interactive: bool,
        udp_port: Option<u16>,
        max_datagram: usize,
    },
    Start {
        key: String,
        mode: String,
    },
    Stop,
    Welcome {
        encoder: String,
        width: u32,
        height: u32,
        max_datagram: usize,
        carrier: String,
    },
    Started {
        session: u64,
    },
    Refused {
        reason: String,
    },
    Ended {
        reason: String,
    },
    Stats {
        kbps: u32,
        frames: u64,
        keyframes: u64,
        cpu_pct: f64,
        encode_ms_p50: f64,
        loss_pct: f64,
    },
}

/// Accumulates bytes from a non-blocking stream and yields complete frames.
#[derive(Default)]
pub struct FrameReader {
    buf: Vec<u8>,
}

impl FrameReader {
    /// Reads what is available; returns Err on EOF or a hard error.
    pub fn fill(&mut self, s: &mut TcpStream) -> io::Result<()> {
        let mut chunk = [0u8; 65536];
        // Bounded: process what is buffered before reading more from a fast sender.
        while self.buf.len() <= MAX_FRAME + 5 {
            match s.read(&mut chunk) {
                Ok(0) => return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "peer closed")),
                Ok(n) => self.buf.extend_from_slice(&chunk[..n]),
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => return Ok(()),
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(e) => return Err(e),
            }
        }
        Ok(())
    }

    pub fn next(&mut self) -> io::Result<Option<(u8, Vec<u8>)>> {
        if self.buf.len() < 5 {
            return Ok(None);
        }
        let len = u32::from_le_bytes([self.buf[1], self.buf[2], self.buf[3], self.buf[4]]) as usize;
        if len > MAX_FRAME {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "frame too large"));
        }
        if self.buf.len() < 5 + len {
            return Ok(None);
        }
        let ty = self.buf[0];
        let payload = self.buf[5..5 + len].to_vec();
        self.buf.drain(..5 + len);
        Ok(Some((ty, payload)))
    }
}

pub fn write_frame(s: &mut TcpStream, ty: u8, payload: &[u8]) -> io::Result<()> {
    let mut out = Vec::with_capacity(5 + payload.len());
    out.push(ty);
    out.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    out.extend_from_slice(payload);
    write_all_nb(s, &out)
}

pub fn write_control(s: &mut TcpStream, c: &Control) -> io::Result<()> {
    let json = serde_json::to_vec(c).map_err(io::Error::other)?;
    write_frame(s, FRAME_CONTROL, &json)
}

/// Writes all bytes to a non-blocking stream, waiting for writability when the kernel
/// buffer is full (flow control keeps this rare: at most one frame is in flight).
fn write_all_nb(s: &mut TcpStream, mut bytes: &[u8]) -> io::Result<()> {
    // One deadline for the whole write: a viewer that drains slowly cannot hold the loop.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(1);
    while !bytes.is_empty() {
        let left = deadline.saturating_duration_since(std::time::Instant::now());
        if left.is_zero() {
            return Err(io::Error::new(io::ErrorKind::TimedOut, "send stalled for 1 s"));
        }
        match s.write(bytes) {
            Ok(0) => return Err(io::Error::new(io::ErrorKind::WriteZero, "closed")),
            Ok(n) => bytes = &bytes[n..],
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                let mut pfd = libc::pollfd {
                    fd: std::os::fd::AsRawFd::as_raw_fd(s),
                    events: libc::POLLOUT,
                    revents: 0,
                };
                // SAFETY: one valid pollfd; bounded wait.
                let rc = unsafe { libc::poll(&mut pfd, 1, left.as_millis().clamp(1, 1000) as i32) };
                if rc == 0 {
                    return Err(io::Error::new(io::ErrorKind::TimedOut, "send stalled for 1 s"));
                }
            }
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(e) => return Err(e),
        }
    }
    Ok(())
}

/// Where media datagrams go.
pub enum DatagramOut {
    Udp { sock: UdpSocket, peer: SocketAddr },
    Stream,
}

impl DatagramOut {
    pub fn send(&self, stream: &mut TcpStream, datagram: &[u8]) -> io::Result<()> {
        match self {
            DatagramOut::Udp { sock, peer } => match sock.send_to(datagram, peer) {
                Ok(_) => Ok(()),
                // A full socket buffer drops the datagram, like loss on the path.
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => Ok(()),
                Err(e) => Err(e),
            },
            DatagramOut::Stream => write_frame(stream, FRAME_DATAGRAM, datagram),
        }
    }
}

/// TCP keepalive (2 s idle, 1 s interval, 3 probes) and a 10 s user timeout, so a viewer
/// that vanishes without a FIN ends its session quickly.
pub fn harden_tcp(s: &TcpStream) {
    use std::os::fd::AsRawFd;
    let fd = s.as_raw_fd();
    let set = |level: i32, name: i32, value: i32| {
        // SAFETY: setsockopt with a valid fd and a pointer to a local int.
        unsafe {
            libc::setsockopt(fd, level, name, (&value as *const i32).cast(), std::mem::size_of::<i32>() as libc::socklen_t);
        }
    };
    set(libc::SOL_SOCKET, libc::SO_KEEPALIVE, 1);
    set(libc::IPPROTO_TCP, libc::TCP_KEEPIDLE, 2);
    set(libc::IPPROTO_TCP, libc::TCP_KEEPINTVL, 1);
    set(libc::IPPROTO_TCP, libc::TCP_KEEPCNT, 3);
    set(libc::IPPROTO_TCP, libc::TCP_USER_TIMEOUT, 10_000);
}
