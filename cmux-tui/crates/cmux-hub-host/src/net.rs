//! HTTPS and WebSocket for the device hub, over std sockets and the rustls this crate
//! already links (ring provider, the platform trust store, certificate checks on). One
//! request per connection (`Connection: close`). `http://` and `ws://` are accepted only for
//! a loopback hub (development).

use crate::b64;
use crate::Res;
use std::io::{self, Read, Write};
use std::net::{SocketAddr, TcpStream, ToSocketAddrs};
use std::sync::Arc;
use std::time::Duration;

/// The User-Agent of this host's hub requests.
#[cfg(not(windows))]
const USER_AGENT: &str = "cmux-rd-linux-host";
#[cfg(windows)]
const USER_AGENT: &str = "cmux-rd-windows-host";

const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const IO_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_HEADER: usize = 32 * 1024;
const MAX_BODY: usize = 4 * 1024 * 1024;
/// The hub's frames are at most 64 KiB; anything far larger is not the hub.
const MAX_MESSAGE: usize = 1 << 20;

/// A parsed `https://host[:port]/path?query` (or `wss://`, or loopback `http://`/`ws://`).
#[derive(Debug, Clone, PartialEq)]
pub struct Url {
    pub tls: bool,
    pub host: String,
    pub port: u16,
    /// Path and query, as sent (`/` at least).
    pub target: String,
}

impl Url {
    #[allow(
        clippy::indexing_slicing,
        clippy::string_slice,
        reason = "every cut is at an ASCII delimiter find returned in the same string"
    )]
    pub fn parse(text: &str) -> Res<Self> {
        let (tls, rest) = if let Some(r) =
            text.strip_prefix("https://").or_else(|| text.strip_prefix("wss://"))
        {
            (true, r)
        } else if let Some(r) = text.strip_prefix("http://").or_else(|| text.strip_prefix("ws://"))
        {
            (false, r)
        } else {
            return Err(format!("{text}: not an https or wss URL").into());
        };
        let (authority, target) = match rest.find(['/', '?']) {
            Some(i) if rest.as_bytes()[i] == b'/' => (&rest[..i], rest[i..].to_owned()),
            Some(i) => (&rest[..i], format!("/{}", &rest[i..])),
            None => (rest, "/".to_owned()),
        };
        if authority.is_empty() || authority.contains('@') {
            return Err(format!("{text}: bad host").into());
        }
        // `[v6]:port`, `[v6]`, `host:port` or `host`.
        let split = match authority.strip_prefix('[') {
            Some(v6) => {
                let close = v6.find(']').ok_or_else(|| format!("{text}: bad host"))?;
                let port = v6[close + 1..].strip_prefix(':');
                (&authority[..close + 2], port)
            }
            None => match authority.split_once(':') {
                Some((h, p)) => (h, Some(p)),
                None => (authority, None),
            },
        };
        let port = match split.1 {
            Some(p) => p.parse().map_err(|_| format!("{text}: bad port"))?,
            None if tls => 443,
            None => 80,
        };
        let host = split.0.to_owned();
        let loopback = matches!(host.as_str(), "localhost" | "127.0.0.1" | "[::1]");
        if !tls && !loopback {
            return Err(format!("{text}: only a loopback hub may be reached without TLS").into());
        }
        Ok(Self { tls, host, port, target })
    }

    /// `origin` + `path` (a path starting with `/`).
    pub fn join(origin: &str, path: &str) -> Res<Self> {
        Self::parse(&format!("{}{path}", origin.trim_end_matches('/')))
    }
}

/// The addresses `Conn::open` tries, in the resolver's order. Without TLS only loopback
/// addresses are kept: the name alone (`localhost`) is no proof, a hosts file or resolver can
/// send it anywhere, and a cleartext request carries the Stack token and device signatures.
fn addresses(url: &Url, resolved: Vec<SocketAddr>) -> Res<Vec<SocketAddr>> {
    let kept: Vec<SocketAddr> =
        resolved.into_iter().filter(|a| url.tls || a.ip().is_loopback()).collect();
    if kept.is_empty() {
        return Err(if url.tls {
            format!("{} has no address", url.host)
        } else {
            format!("{} has no loopback address; a hub without TLS must be local", url.host)
        }
        .into());
    }
    Ok(kept)
}

/// A connected byte stream (TLS or loopback TCP) with its socket for timeouts.
pub struct Conn {
    io: Box<dyn ReadWrite>,
    tcp: TcpStream,
}

trait ReadWrite: Read + Write + Send {}
impl<T: Read + Write + Send> ReadWrite for T {}

impl Conn {
    pub fn open(url: &Url) -> Res<Self> {
        let host = url.host.trim_start_matches('[').trim_end_matches(']');
        let mut last = None;
        let mut connected = None;
        for addr in addresses(url, (host, url.port).to_socket_addrs()?.collect())? {
            match TcpStream::connect_timeout(&addr, CONNECT_TIMEOUT) {
                Ok(tcp) => {
                    connected = Some(tcp);
                    break;
                }
                Err(e) => last = Some(e),
            }
        }
        let tcp = match (connected, last) {
            (Some(tcp), _) => tcp,
            (None, Some(e)) => return Err(e.into()),
            (None, None) => return Err(format!("{} has no address", url.host).into()),
        };
        tcp.set_read_timeout(Some(IO_TIMEOUT))?;
        tcp.set_write_timeout(Some(IO_TIMEOUT))?;
        tcp.set_nodelay(true)?;
        let io: Box<dyn ReadWrite> = if url.tls {
            let name = rustls::pki_types::ServerName::try_from(host.to_owned())
                .map_err(|e| format!("server name {host}: {e}"))?;
            let conn = rustls::ClientConnection::new(tls_config()?, name)?;
            Box::new(rustls::StreamOwned::new(conn, tcp.try_clone()?))
        } else {
            Box::new(tcp.try_clone()?)
        };
        Ok(Self { io, tcp })
    }

    pub fn set_read_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
        self.tcp.set_read_timeout(timeout)
    }
}

impl Drop for Conn {
    fn drop(&mut self) {
        let _ = self.tcp.shutdown(std::net::Shutdown::Both);
    }
}

fn tls_config() -> Res<Arc<rustls::ClientConfig>> {
    static CONFIG: std::sync::OnceLock<Result<Arc<rustls::ClientConfig>, String>> =
        std::sync::OnceLock::new();
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
        .map_err(Into::into)
}

/// One HTTP response: status and body.
pub struct Response {
    pub status: u16,
    pub body: Vec<u8>,
}

/// One HTTP/1.1 request with `Connection: close`.
pub fn request(
    method: &str,
    url: &Url,
    headers: &[(String, String)],
    body: Option<&[u8]>,
) -> Res<Response> {
    let mut conn = Conn::open(url)?;
    let mut head = format!(
        "{method} {} HTTP/1.1\r\nHost: {}\r\nUser-Agent: {USER_AGENT}\r\nAccept: application/json\r\nAccept-Encoding: identity\r\nConnection: close\r\n",
        url.target,
        host_header(url)
    );
    for (k, v) in headers {
        head.push_str(&format!("{k}: {v}\r\n"));
    }
    if let Some(body) = body {
        head.push_str(&format!(
            "Content-Type: application/json\r\nContent-Length: {}\r\n",
            body.len()
        ));
    }
    head.push_str("\r\n");
    conn.io.write_all(head.as_bytes())?;
    if let Some(body) = body {
        conn.io.write_all(body)?;
    }
    conn.io.flush()?;
    let mut raw = Vec::new();
    match (&mut conn.io).take((MAX_HEADER + MAX_BODY) as u64).read_to_end(&mut raw) {
        Ok(_) => {}
        Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => {}
        Err(e) => return Err(e.into()),
    }
    parse_response(&raw)
}

fn host_header(url: &Url) -> String {
    if (url.tls && url.port == 443) || (!url.tls && url.port == 80) {
        url.host.clone()
    } else {
        format!("{}:{}", url.host, url.port)
    }
}

/// A complete response: status, then a body by `Content-Length`, chunked, or to the end.
#[allow(clippy::indexing_slicing, reason = "end is where the 4-byte header end was found in raw")]
pub fn parse_response(raw: &[u8]) -> Res<Response> {
    let end = raw.windows(4).position(|w| w == b"\r\n\r\n").ok_or("no HTTP header")?;
    let head = std::str::from_utf8(&raw[..end]).map_err(|_| "header is not text")?;
    let mut lines = head.split("\r\n");
    let status_line = lines.next().unwrap_or_default();
    let status: u16 = status_line
        .split_whitespace()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .ok_or_else(|| format!("bad status line {status_line:?}"))?;
    let (mut length, mut chunked) = (None, false);
    for line in lines {
        let Some((k, v)) = line.split_once(':') else { continue };
        match k.trim().to_ascii_lowercase().as_str() {
            "content-length" => length = v.trim().parse::<usize>().ok(),
            "transfer-encoding" => chunked = v.to_ascii_lowercase().contains("chunked"),
            _ => {}
        }
    }
    let rest = &raw[end + 4..];
    let body = if chunked {
        dechunk(rest)?
    } else if let Some(n) = length {
        rest.get(..n).ok_or("response body is cut short")?.to_vec()
    } else {
        rest.to_vec()
    };
    Ok(Response { status, body })
}

#[allow(clippy::indexing_slicing, reason = "eol is where the 2-byte line end was found in rest")]
fn dechunk(mut rest: &[u8]) -> Res<Vec<u8>> {
    let mut out = Vec::new();
    loop {
        let eol = rest.windows(2).position(|w| w == b"\r\n").ok_or("bad chunk")?;
        let size_text = std::str::from_utf8(&rest[..eol]).map_err(|_| "bad chunk")?;
        let size = usize::from_str_radix(size_text.split(';').next().unwrap_or("").trim(), 16)
            .map_err(|_| "bad chunk size")?;
        rest = &rest[eol + 2..];
        if size == 0 {
            return Ok(out);
        }
        out.extend_from_slice(rest.get(..size).ok_or("chunk cut short")?);
        rest = rest.get(size + 2..).ok_or("chunk cut short")?;
        if out.len() > MAX_BODY {
            return Err("response too large".into());
        }
    }
}

/// A message from the server.
#[derive(Debug, PartialEq)]
pub enum Message {
    Text(String),
    /// The server closed: code and reason.
    Closed(u16, String),
}

/// A client WebSocket (RFC 6455): text frames, masked; answers pings; reassembles fragments.
pub struct WebSocket {
    conn: Conn,
    buf: Vec<u8>,
    partial: Vec<u8>,
    closed: bool,
}

const WS_GUID: &str = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

impl WebSocket {
    /// Opens `url` with `headers`; the server must answer 101 with the right accept key.
    #[allow(
        clippy::indexing_slicing,
        reason = "n is what read returned for chunk, and end was found in buf"
    )]
    pub fn connect(url: &Url, headers: &[(String, String)]) -> Res<Self> {
        let mut conn = Conn::open(url)?;
        let mut nonce = [0u8; 16];
        ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut nonce)
            .map_err(|_| "no randomness")?;
        let key = b64::encode(&nonce);
        let mut head = format!(
            "GET {} HTTP/1.1\r\nHost: {}\r\nUser-Agent: {USER_AGENT}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n",
            url.target,
            host_header(url)
        );
        for (k, v) in headers {
            head.push_str(&format!("{k}: {v}\r\n"));
        }
        head.push_str("\r\n");
        conn.io.write_all(head.as_bytes())?;
        conn.io.flush()?;
        let mut buf = Vec::new();
        let mut chunk = [0u8; 4096];
        let end = loop {
            if let Some(end) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                break end;
            }
            if buf.len() > MAX_HEADER {
                return Err("WebSocket answer header too large".into());
            }
            let n = match conn.io.read(&mut chunk) {
                // A signal interrupts this timed read too (see `recv`); read again.
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                read => read?,
            };
            if n == 0 {
                return Err("the hub closed the WebSocket before answering".into());
            }
            buf.extend_from_slice(&chunk[..n]);
        };
        let head = String::from_utf8_lossy(&buf[..end]).into_owned();
        let status = head.split_whitespace().nth(1).unwrap_or("");
        if status != "101" {
            let body = parse_response(&buf).map(|r| r.body).unwrap_or_default();
            return Err(crate::hub::HubError::from_body(status.parse().unwrap_or(0), &body).into());
        }
        let expected = accept_key(&key);
        let accepted = head.split("\r\n").any(|line| {
            line.split_once(':').is_some_and(|(k, v)| {
                k.trim().eq_ignore_ascii_case("sec-websocket-accept") && v.trim() == expected
            })
        });
        if !accepted {
            return Err("the WebSocket answer has the wrong accept key".into());
        }
        buf.drain(..end + 4);
        Ok(Self { conn, buf, partial: Vec::new(), closed: false })
    }

    pub fn send_text(&mut self, text: &str) -> Res<()> {
        self.send_frame(0x1, text.as_bytes())
    }

    fn send_frame(&mut self, opcode: u8, payload: &[u8]) -> Res<()> {
        let frame = encode_frame(opcode, payload)?;
        self.conn.io.write_all(&frame)?;
        self.conn.io.flush()?;
        Ok(())
    }

    /// Sends a close frame (best effort).
    pub fn close(&mut self) {
        if !self.closed {
            self.closed = true;
            let _ = self.send_frame(0x8, &1000u16.to_be_bytes());
        }
    }

    /// The next message, waiting at most `timeout`; None when nothing complete arrived.
    #[allow(clippy::indexing_slicing, reason = "n is what read returned for chunk")]
    pub fn recv(&mut self, timeout: Duration) -> Res<Option<Message>> {
        loop {
            if let Some(message) = self.take_message()? {
                return Ok(Some(message));
            }
            self.conn.set_read_timeout(Some(timeout.max(Duration::from_millis(1))))?;
            let mut chunk = [0u8; 16 * 1024];
            match self.conn.io.read(&mut chunk) {
                Ok(0) => return Ok(Some(Message::Closed(1006, "connection closed".into()))),
                Ok(n) => self.buf.extend_from_slice(&chunk[..n]),
                // A signal to this process (a child's SIGCHLD, a SIGTERM) interrupts a read with
                // a timeout even under SA_RESTART (signal(7)): nothing arrived, the socket is fine.
                Err(e)
                    if matches!(
                        e.kind(),
                        io::ErrorKind::WouldBlock
                            | io::ErrorKind::TimedOut
                            | io::ErrorKind::Interrupted
                    ) =>
                {
                    return Ok(None)
                }
                Err(e) => return Err(e.into()),
            }
        }
    }

    #[allow(
        clippy::indexing_slicing,
        reason = "the close payload is at least 2 bytes where it is read"
    )]
    fn take_message(&mut self) -> Res<Option<Message>> {
        while let Some((fin, opcode, payload, used)) = decode_frame(&self.buf)? {
            self.buf.drain(..used);
            match opcode {
                0x0..=0x2 => {
                    self.partial.extend_from_slice(&payload);
                    if self.partial.len() > MAX_MESSAGE {
                        return Err("WebSocket message too large".into());
                    }
                    if fin {
                        let text = String::from_utf8(std::mem::take(&mut self.partial))
                            .map_err(|_| "WebSocket text is not UTF-8")?;
                        return Ok(Some(Message::Text(text)));
                    }
                }
                0x8 => {
                    let code = payload.get(..2).map_or(1005, |b| u16::from_be_bytes([b[0], b[1]]));
                    let reason =
                        String::from_utf8_lossy(payload.get(2..).unwrap_or_default()).into_owned();
                    self.close();
                    return Ok(Some(Message::Closed(code, reason)));
                }
                0x9 => self.send_frame(0xA, &payload)?,
                _ => {}
            }
        }
        Ok(None)
    }
}

/// `Sec-WebSocket-Accept` for `key`.
pub fn accept_key(key: &str) -> String {
    let digest = ring::digest::digest(
        &ring::digest::SHA1_FOR_LEGACY_USE_ONLY,
        format!("{key}{WS_GUID}").as_bytes(),
    );
    b64::encode(digest.as_ref())
}

/// A masked client frame.
#[allow(clippy::indexing_slicing, reason = "the mask index is i % 4 of a 4-byte mask")]
pub fn encode_frame(opcode: u8, payload: &[u8]) -> Res<Vec<u8>> {
    let mut mask = [0u8; 4];
    ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut mask)
        .map_err(|_| "no randomness")?;
    let mut frame = vec![0x80 | opcode];
    match payload.len() {
        n if n < 126 => frame.push(0x80 | n as u8),
        n if n <= 0xffff => {
            frame.push(0x80 | 126);
            frame.extend_from_slice(&(n as u16).to_be_bytes());
        }
        n => {
            frame.push(0x80 | 127);
            frame.extend_from_slice(&(n as u64).to_be_bytes());
        }
    }
    frame.extend_from_slice(&mask);
    frame.extend(payload.iter().enumerate().map(|(i, b)| b ^ mask[i % 4]));
    Ok(frame)
}

/// One decoded frame: (fin, opcode, unmasked payload, bytes used).
pub type Frame = (bool, u8, Vec<u8>, usize);

/// One complete frame at the start of `buf`.
#[allow(
    clippy::indexing_slicing,
    reason = "each header byte read is behind a length check, and the mask is 4 bytes"
)]
pub fn decode_frame(buf: &[u8]) -> Res<Option<Frame>> {
    if buf.len() < 2 {
        return Ok(None);
    }
    let fin = buf[0] & 0x80 != 0;
    let opcode = buf[0] & 0x0f;
    let masked = buf[1] & 0x80 != 0;
    let (len, mut at) = match buf[1] & 0x7f {
        126 if buf.len() >= 4 => (usize::from(u16::from_be_bytes([buf[2], buf[3]])), 4),
        127 if buf.len() >= 10 => {
            let mut b = [0u8; 8];
            b.copy_from_slice(&buf[2..10]);
            (usize::try_from(u64::from_be_bytes(b)).map_err(|_| "frame too large")?, 10)
        }
        126 | 127 => return Ok(None),
        n => (usize::from(n), 2),
    };
    if len > MAX_MESSAGE {
        return Err("WebSocket frame too large".into());
    }
    let mask = if masked {
        let Some(m) = buf.get(at..at + 4) else { return Ok(None) };
        at += 4;
        Some([m[0], m[1], m[2], m[3]])
    } else {
        None
    };
    let Some(data) = buf.get(at..at + len) else { return Ok(None) };
    let payload = match mask {
        Some(m) => data.iter().enumerate().map(|(i, b)| b ^ m[i % 4]).collect(),
        None => data.to_vec(),
    };
    Ok(Some((fin, opcode, payload, at + len)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn urls_need_tls_except_loopback() {
        let u = Url::parse("https://hub.example/v1/sessions/s/ws?ticket=a.b.c").unwrap();
        assert_eq!(
            (u.tls, u.host.as_str(), u.port, u.target.as_str()),
            (true, "hub.example", 443, "/v1/sessions/s/ws?ticket=a.b.c")
        );
        let u = Url::parse("wss://hub.example:8443").unwrap();
        assert_eq!((u.port, u.target.as_str()), (8443, "/"));
        assert!(Url::parse("http://hub.example/v1").is_err());
        assert!(Url::parse("http://127.0.0.1:8787/v1").is_ok());
        assert!(Url::parse("https://user@hub.example/").is_err());
        assert_eq!(Url::join("https://hub.example/", "/v1/me").unwrap().target, "/v1/me");
    }

    #[test]
    fn accept_key_matches_rfc_6455() {
        assert_eq!(accept_key("dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=");
    }

    #[test]
    fn frames_round_trip_masked_and_unmasked() {
        for len in [0usize, 5, 125, 126, 70_000] {
            let payload = vec![7u8; len];
            let frame = encode_frame(0x1, &payload).unwrap();
            let (fin, op, back, used) = decode_frame(&frame).unwrap().unwrap();
            assert!(fin);
            assert_eq!((op, back, used), (0x1, payload, frame.len()));
            assert!(decode_frame(&frame[..frame.len() - 1]).unwrap().is_none() || len == 0);
        }
        let server = [0x81, 0x02, b'h', b'i'];
        assert_eq!(decode_frame(&server).unwrap().unwrap().2, b"hi");
    }

    #[test]
    fn responses_read_length_and_chunked_bodies() {
        let r = parse_response(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}extra").unwrap();
        assert_eq!((r.status, r.body.as_slice()), (200, &b"{}"[..]));
        let r = parse_response(b"HTTP/1.1 403 Forbidden\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n").unwrap();
        assert_eq!((r.status, r.body.as_slice()), (403, &b"abcde"[..]));
    }

    #[test]
    fn a_plaintext_hub_is_reached_only_on_a_loopback_address() {
        let local = Url::parse("http://localhost:8787/v1").unwrap();
        let remote: SocketAddr = "203.0.113.7:8787".parse().unwrap();
        let v4: SocketAddr = "127.0.0.1:8787".parse().unwrap();
        let v6: SocketAddr = "[::1]:8787".parse().unwrap();
        // A hosts file or resolver that sends `localhost` elsewhere gets no cleartext.
        assert!(addresses(&local, vec![remote]).is_err());
        assert_eq!(addresses(&local, vec![remote, v6, v4]).unwrap(), vec![v6, v4]);
        // TLS checks the certificate; every address is tried, in the resolver's order.
        let tls = Url::parse("https://hub.example").unwrap();
        assert_eq!(addresses(&tls, vec![v6, remote]).unwrap(), vec![v6, remote]);
        assert!(addresses(&tls, vec![]).is_err());
    }

    /// A signal to the process (a helper's SIGCHLD when it exits) interrupts a timed socket
    /// read even under SA_RESTART (signal(7)). That is nothing arriving, never the socket
    /// closing: a share whose own helper crashed read it as "signaling closed before the
    /// viewer connected", and the hub was never told the share failed.
    #[cfg(unix)]
    #[test]
    fn a_signal_during_a_read_is_no_message_and_the_socket_stays_open() {
        use std::io::BufRead;
        use std::os::unix::thread::JoinHandleExt;
        extern "C" fn ignore(_: libc::c_int) {}
        // SAFETY: a zeroed sigaction is valid; the handler does nothing, which is
        // async-signal-safe, and SIGUSR2 is used by nothing else in this crate's tests.
        unsafe {
            let mut action: libc::sigaction = std::mem::zeroed();
            action.sa_sigaction = ignore as extern "C" fn(libc::c_int) as libc::sighandler_t;
            action.sa_flags = libc::SA_RESTART;
            libc::sigemptyset(&mut action.sa_mask);
            assert_eq!(libc::sigaction(libc::SIGUSR2, &action, std::ptr::null_mut()), 0);
        }
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let (send_now, sent) = std::sync::mpsc::channel::<()>();
        let server = std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = io::BufReader::new(stream.try_clone().unwrap());
            let mut key = String::new();
            loop {
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                if line.trim_end().is_empty() {
                    break;
                }
                if let Some(v) = line.trim_end().strip_prefix("Sec-WebSocket-Key: ") {
                    key = v.to_owned();
                }
            }
            let mut out = &stream;
            write!(
                out,
                "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {}\r\n\r\n",
                accept_key(&key)
            )
            .unwrap();
            sent.recv().unwrap();
            out.write_all(&[0x81, 2, b'h', b'i']).unwrap();
            // Held open until the client is done.
            let _ = io::copy(&mut reader, &mut io::sink());
        });
        let url = Url::parse(&format!("ws://127.0.0.1:{port}/")).unwrap();
        let mut ws = WebSocket::connect(&url, &[]).unwrap();
        let reader = std::thread::spawn(move || {
            let first = ws.recv(Duration::from_secs(30)).map_err(|e| e.to_string());
            (ws, first)
        });
        // Signal the reading thread until its read returns: it spends nearly all its time
        // blocked in recv, so one of these lands there.
        let thread = reader.as_pthread_t();
        while !reader.is_finished() {
            // SAFETY: the reading thread has not been joined, so its pthread_t is live.
            unsafe { libc::pthread_kill(thread, libc::SIGUSR2) };
            std::thread::yield_now();
        }
        let (mut ws, first) = reader.join().unwrap();
        assert!(matches!(first, Ok(None)), "an interrupted read: {first:?}");
        send_now.send(()).unwrap();
        let next = ws.recv(Duration::from_secs(30)).unwrap();
        assert!(matches!(next, Some(Message::Text(ref t)) if t == "hi"), "{next:?}");
        ws.close();
        drop(ws);
        server.join().unwrap();
    }
}
