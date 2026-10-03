//! The metadata service read (vm-image.md 6.2): the EC2-style token PUT,
//! then `GET latest/meta-data/instance-id`.
//!
//! Rules learned on the provider: concurrent readers stall and a request
//! in flight across a snapshot or pause hangs until its timeout. So there
//! is one reader (the agent's own event loop, synchronously), each attempt
//! has a 250 ms budget, retries are counted by attempts (a monotonic budget
//! would expire across a pause), and the loop only reads on a wake, so no
//! request is ever left in flight while parked.

use std::io::{self, Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::time::{Duration, Instant};

/// The link-local metadata address.
pub const DEFAULT_ADDR: &str = "169.254.169.254:80";
/// Budget for one attempt (token plus id).
pub const ATTEMPT_TIMEOUT: Duration = Duration::from_millis(250);
/// Attempts per wake.
pub const DEFAULT_ATTEMPTS: u32 = 8;
/// Longest accepted response.
const MAX_RESPONSE: u64 = 8 * 1024;
/// Longest accepted instance id.
const MAX_ID_LEN: usize = 128;

/// One read of the instance id. A trait so the agent can be driven by a
/// fake in tests.
pub trait InstanceIdSource {
    fn fetch_once(&mut self) -> io::Result<String>;
}

/// The real client.
pub struct Mmds {
    pub addr: SocketAddr,
    pub timeout: Duration,
}

impl InstanceIdSource for Mmds {
    fn fetch_once(&mut self) -> io::Result<String> {
        let deadline = Instant::now() + self.timeout;
        let token = request(
            self.addr,
            deadline,
            "PUT /latest/api/token HTTP/1.1\r\nHost: 169.254.169.254\r\nX-metadata-token-ttl-seconds: 60\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        )?;
        let token = token.trim();
        if token.is_empty() || !token.bytes().all(|b| b.is_ascii_graphic()) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "metadata token is not a header value",
            ));
        }
        let get = format!(
            "GET /latest/meta-data/instance-id HTTP/1.1\r\nHost: 169.254.169.254\r\nX-aws-ec2-metadata-token: {token}\r\nConnection: close\r\n\r\n"
        );
        request(self.addr, deadline, &get)
    }
}

fn remaining(deadline: Instant) -> io::Result<Duration> {
    let left = deadline.saturating_duration_since(Instant::now());
    if left.is_zero() {
        return Err(io::Error::new(io::ErrorKind::TimedOut, "metadata attempt budget spent"));
    }
    Ok(left)
}

/// One HTTP/1.1 exchange on a fresh connection; returns the body of a 200.
fn request(addr: SocketAddr, deadline: Instant, head: &str) -> io::Result<String> {
    let mut stream = TcpStream::connect_timeout(&addr, remaining(deadline)?)?;
    stream.set_nodelay(true)?;
    stream.set_write_timeout(Some(remaining(deadline)?))?;
    stream.write_all(head.as_bytes())?;
    let mut raw = Vec::new();
    loop {
        stream.set_read_timeout(Some(remaining(deadline)?))?;
        let mut chunk = [0u8; 1024];
        let n = stream.read(&mut chunk)?;
        if n == 0 {
            break;
        }
        raw.extend_from_slice(&chunk[..n]);
        if raw.len() as u64 > MAX_RESPONSE {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "metadata response too large"));
        }
        if let Some(body) = complete_body(&raw)? {
            return Ok(body);
        }
    }
    complete_body(&raw)?
        .or_else(|| parse_response(&raw).ok().map(|(_, body)| body))
        .ok_or_else(|| io::Error::new(io::ErrorKind::UnexpectedEof, "metadata response truncated"))
}

/// The body once the response is complete per `Content-Length`; `None`
/// while more bytes are needed (or when there is no length: read to EOF).
fn complete_body(raw: &[u8]) -> io::Result<Option<String>> {
    let Some(end) = find(raw, b"\r\n\r\n") else { return Ok(None) };
    let head = std::str::from_utf8(&raw[..end]).map_err(|_| bad("metadata header is not UTF-8"))?;
    let Some(len) = content_length(head) else { return Ok(None) };
    if raw.len() < end + 4 + len {
        return Ok(None);
    }
    parse_response(&raw[..end + 4 + len]).map(|(_, body)| Some(body))
}

fn parse_response(raw: &[u8]) -> io::Result<(u16, String)> {
    let end = find(raw, b"\r\n\r\n").ok_or_else(|| bad("metadata header incomplete"))?;
    let head = std::str::from_utf8(&raw[..end]).map_err(|_| bad("metadata header is not UTF-8"))?;
    let status: u16 = head
        .lines()
        .next()
        .and_then(|line| line.split(' ').nth(1))
        .and_then(|code| code.parse().ok())
        .ok_or_else(|| bad("metadata status line"))?;
    if status != 200 {
        return Err(io::Error::other(format!("metadata status {status}")));
    }
    let body = String::from_utf8(raw[end + 4..].to_vec())
        .map_err(|_| bad("metadata body is not UTF-8"))?;
    Ok((status, body))
}

fn content_length(head: &str) -> Option<usize> {
    head.lines().skip(1).find_map(|line| {
        let (name, value) = line.split_once(':')?;
        name.trim().eq_ignore_ascii_case("content-length").then(|| value.trim().parse().ok())?
    })
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

fn bad(msg: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, msg)
}

/// Accepts an instance id only when it is safe to write into files and
/// pass as one argv element: 1 to 128 of `[A-Za-z0-9._-]`.
pub fn valid_instance_id(raw: &str) -> Option<String> {
    let id = raw.trim();
    let ok = !id.is_empty()
        && id.len() <= MAX_ID_LEN
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'));
    ok.then(|| id.to_owned())
}

/// The result of one wake's read.
#[derive(Debug, PartialEq, Eq)]
pub struct IdRead {
    pub instance_id: Option<String>,
    pub attempts: u32,
}

/// Reads the id with at most `attempts` attempts. An invalid id counts as
/// a failed attempt; nothing here sleeps between attempts.
pub fn read_instance_id(source: &mut dyn InstanceIdSource, attempts: u32) -> IdRead {
    let attempts = attempts.max(1);
    for n in 1..=attempts {
        if let Ok(raw) = source.fetch_once()
            && let Some(id) = valid_instance_id(&raw)
        {
            return IdRead { instance_id: Some(id), attempts: n };
        }
    }
    IdRead { instance_id: None, attempts }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;
    use std::thread;

    struct Script(Vec<io::Result<String>>);

    impl InstanceIdSource for Script {
        fn fetch_once(&mut self) -> io::Result<String> {
            if self.0.is_empty() { Err(io::Error::other("done")) } else { self.0.remove(0) }
        }
    }

    #[test]
    fn retries_by_attempt_count_and_rejects_unsafe_ids() {
        let mut src = Script(vec![
            Err(io::Error::other("timeout")),
            Ok("i-1\n/../x".to_owned()),
            Ok(" vm-abc.1_2 \n".to_owned()),
        ]);
        assert_eq!(
            read_instance_id(&mut src, 5),
            IdRead { instance_id: Some("vm-abc.1_2".to_owned()), attempts: 3 }
        );
        let mut empty = Script(vec![Ok(String::new()), Ok("  ".to_owned())]);
        assert_eq!(read_instance_id(&mut empty, 2), IdRead { instance_id: None, attempts: 2 });
        assert_eq!(valid_instance_id(&"a".repeat(129)), None);
        assert_eq!(valid_instance_id("a b"), None);
    }

    #[test]
    fn mmds_client_does_the_token_dance() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let mut seen = Vec::new();
            for reply in ["tok-1", "vm-42"] {
                let (mut s, _) = listener.accept().unwrap();
                let mut buf = [0u8; 2048];
                let n = s.read(&mut buf).unwrap();
                seen.push(String::from_utf8_lossy(&buf[..n]).into_owned());
                let resp =
                    format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n{reply}", reply.len());
                s.write_all(resp.as_bytes()).unwrap();
            }
            seen
        });
        let mut mmds = Mmds { addr, timeout: Duration::from_secs(2) };
        assert_eq!(mmds.fetch_once().unwrap(), "vm-42");
        let seen = server.join().unwrap();
        assert!(seen[0].starts_with("PUT /latest/api/token "));
        assert!(seen[0].contains("X-metadata-token-ttl-seconds: 60"));
        assert!(seen[1].starts_with("GET /latest/meta-data/instance-id "));
        assert!(seen[1].contains("X-aws-ec2-metadata-token: tok-1"));
    }

    #[test]
    fn non_200_is_an_error() {
        let raw = b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n";
        assert!(parse_response(raw).is_err());
    }
}
