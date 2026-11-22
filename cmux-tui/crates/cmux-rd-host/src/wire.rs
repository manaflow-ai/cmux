//! Carriers for `cmux.rd/1` until the overlay datagram service (port 4103, lane 12) lands:
//! UDP datagrams, or one TCP stream that carries control messages and datagrams as frames
//! `u8 type (1 control JSON, 2 datagram)`, `u32 len`, payload.

use std::io::{self, Read, Write};
use std::net::{SocketAddr, TcpStream, UdpSocket};

pub const FRAME_CONTROL: u8 = 1;
pub const FRAME_DATAGRAM: u8 = 2;
const MAX_FRAME: usize = 1 << 20;

pub use cmux_rd_proto::control::Control;

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

    /// True when the buffered start of the stream is not this protocol: the first byte of
    /// every valid stream is a control frame (type 1). An HTTP request (for example a
    /// cross-protocol POST from a browser page) starts with an ASCII method instead.
    pub fn foreign_prefix(&self) -> bool {
        self.buf.first().is_some_and(|&b| b != FRAME_CONTROL)
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

#[cfg(target_os = "linux")]
/// TCP keepalive (2 s idle, 1 s interval, 3 probes) and a 10 s user timeout, so a viewer
/// that vanishes without a FIN ends its session quickly.
pub fn harden_tcp(s: &TcpStream) {
    use std::os::fd::AsRawFd;
    let fd = s.as_raw_fd();
    let set = |level: i32, name: i32, value: i32| {
        // SAFETY: setsockopt with a valid fd and a pointer to a local int.
        unsafe {
            libc::setsockopt(
                fd,
                level,
                name,
                (&value as *const i32).cast(),
                std::mem::size_of::<i32>() as libc::socklen_t,
            );
        }
    };
    set(libc::SOL_SOCKET, libc::SO_KEEPALIVE, 1);
    set(libc::IPPROTO_TCP, libc::TCP_KEEPIDLE, 2);
    set(libc::IPPROTO_TCP, libc::TCP_KEEPINTVL, 1);
    set(libc::IPPROTO_TCP, libc::TCP_KEEPCNT, 3);
    set(libc::IPPROTO_TCP, libc::TCP_USER_TIMEOUT, 10_000);
}

/// Larger UDP buffers so a keyframe burst (hundreds of datagrams) is not dropped by the
/// kernel before pacing exists.
pub fn grow_udp_buffers(s: &std::net::UdpSocket) {
    use std::os::fd::AsRawFd;
    let size: i32 = 4 << 20;
    for name in [libc::SO_SNDBUF, libc::SO_RCVBUF] {
        // SAFETY: setsockopt with a valid fd and a pointer to a local int.
        unsafe {
            libc::setsockopt(
                s.as_raw_fd(),
                libc::SOL_SOCKET,
                name,
                (&size as *const i32).cast(),
                std::mem::size_of::<i32>() as libc::socklen_t,
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_rd_proto::{
        encode_stream_frame, StreamDeframer, MAX_STREAM_FRAME, STREAM_CONTROL, STREAM_DATAGRAM,
    };
    use std::net::TcpListener;
    use std::time::{Duration, Instant};

    /// The stream carrier bytes of `{"t":"stop"}` then a 3-byte datagram. The
    /// same vector is pinned in cmux-rd-proto's tests/wire.rs, so the host's
    /// framing and the viewer's (cmux-rd-ffi through cmux-rd-proto) cannot drift.
    const GOLDEN: &[u8] = &[
        1, 12, 0, 0, 0, b'{', b'"', b't', b'"', b':', b'"', b's', b't', b'o', b'p', b'"', b'}', 2,
        3, 0, 0, 0, 7, 7, 7,
    ];

    fn pair() -> (TcpStream, TcpStream) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let client = TcpStream::connect(listener.local_addr().expect("addr")).expect("connect");
        let (server, _) = listener.accept().expect("accept");
        (client, server)
    }

    #[test]
    fn a_hello_without_service_or_caps_is_a_desktop_hello() {
        let json = br#"{"t":"hello","user":"u","install":"i","class":"user","interactive":true,"udp_port":null,"max_datagram":1152}"#;
        let Control::Hello { service, caps, .. } = serde_json::from_slice(json).expect("hello")
        else {
            panic!("not a hello");
        };
        assert_eq!(service, "desktop");
        assert!(caps.is_empty());
    }

    #[test]
    fn welcome_echoes_the_service_and_the_accepted_caps() {
        let welcome = Control::Welcome {
            encoder: "x264".into(),
            width: 1,
            height: 1,
            max_datagram: 1152,
            carrier: "stream".into(),
            service: "desktop".into(),
            caps: vec!["stream.open".into()],
        };
        let json = serde_json::to_value(&welcome).expect("json");
        assert_eq!(json["service"], "desktop");
        assert_eq!(json["caps"][0], "stream.open");
    }

    #[test]
    fn host_and_proto_framing_share_constants() {
        assert_eq!(FRAME_CONTROL, STREAM_CONTROL);
        assert_eq!(FRAME_DATAGRAM, STREAM_DATAGRAM);
        assert_eq!(MAX_FRAME, MAX_STREAM_FRAME);
    }

    #[test]
    fn host_writes_the_golden_bytes_and_proto_reads_them() {
        let (mut tx, mut rx) = pair();
        write_frame(&mut tx, FRAME_CONTROL, br#"{"t":"stop"}"#).expect("control");
        write_frame(&mut tx, FRAME_DATAGRAM, &[7, 7, 7]).expect("datagram");
        drop(tx);
        let mut bytes = Vec::new();
        rx.read_to_end(&mut bytes).expect("read");
        assert_eq!(bytes, GOLDEN);
        let mut d = StreamDeframer::default();
        d.extend(&bytes);
        assert_eq!(
            d.next_frame().expect("frame"),
            Some((STREAM_CONTROL, br#"{"t":"stop"}"#.to_vec()))
        );
        assert_eq!(d.next_frame().expect("frame"), Some((STREAM_DATAGRAM, vec![7, 7, 7])));
        assert_eq!(d.next_frame().expect("end"), None);
    }

    #[test]
    fn proto_writes_the_golden_bytes_and_the_host_reads_them() {
        let mut bytes = Vec::new();
        encode_stream_frame(STREAM_CONTROL, br#"{"t":"stop"}"#, &mut bytes).expect("control");
        encode_stream_frame(STREAM_DATAGRAM, &[7, 7, 7], &mut bytes).expect("datagram");
        assert_eq!(bytes, GOLDEN);
        let (mut tx, mut rx) = pair();
        tx.write_all(&bytes).expect("write");
        rx.set_nonblocking(true).expect("nonblocking");
        let mut reader = FrameReader::default();
        let mut frames = Vec::new();
        let deadline = Instant::now() + Duration::from_secs(5);
        while frames.len() < 2 && Instant::now() < deadline {
            reader.fill(&mut rx).expect("fill");
            while let Some(frame) = reader.next().expect("next") {
                frames.push(frame);
            }
            // Test-only wait for loopback delivery.
            std::thread::sleep(Duration::from_millis(5));
        }
        assert_eq!(
            frames,
            vec![(FRAME_CONTROL, br#"{"t":"stop"}"#.to_vec()), (FRAME_DATAGRAM, vec![7, 7, 7])]
        );
    }
}
