//! An upstream served over loopback streamable HTTP instead of a child process: acpmux's daemon
//! serves its own tool servers this way, so a chat starts no process for them. A spec's `http`
//! (`{"url": "http://127.0.0.1:PORT/mcp/...", "headers": {...}}`) names the endpoint; each
//! JSON-RPC message is one POST of its JSON there, answered as one JSON message or as an event
//! stream (`data:` lines), and a notification as 202 with no body. Loopback only: the headers
//! carry a token, and nothing goes off the machine. A plain HTTP/1.1 client over a `TcpStream`,
//! one connection per message (no TLS, no async runtime, the same on every platform).

use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, TcpStream};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, PoisonError};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::Failure;

/// The largest reply read (a tool result with screenshots stays far under it).
const MAX_REPLY_BYTES: u64 = 16 << 20;
/// The header a server names its session by; sent back on each later request.
const SESSION_HEADER: &str = "mcp-session-id";

/// Where an HTTP upstream is: its url and the headers each request carries.
#[derive(Clone, PartialEq, Eq)]
pub(in super::super) struct Http {
    pub url: String,
    pub headers: Vec<(String, String)>,
}

impl std::fmt::Debug for Http {
    /// Header values stay out: one is a bearer token.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let names: Vec<&str> = self.headers.iter().map(|(name, _)| name.as_str()).collect();
        f.debug_struct("Http").field("url", &self.url).field("headers", &names).finish()
    }
}

impl Http {
    /// `{url, headers}` in a spec, or None when it is not that.
    pub(in super::super) fn from_json(item: &Value) -> Option<Self> {
        let url = item["url"].as_str()?.to_owned();
        let headers = item["headers"]
            .as_object()
            .map(|headers| {
                headers
                    .iter()
                    .filter_map(|(k, v)| v.as_str().map(|v| (k.clone(), v.to_owned())))
                    .collect()
            })
            .unwrap_or_default();
        Some(Self { url, headers })
    }
}

/// A url's parts this client needs, once it is known to be loopback.
#[derive(Debug, PartialEq, Eq)]
pub(in super::super) struct Endpoint {
    /// The `host` header: the url's host and port as written.
    authority: String,
    /// The request target: path and query.
    target: String,
    addrs: Vec<SocketAddr>,
}

/// The parts of `url` when it is a plain `http://` url on 127.0.0.1, ::1 or localhost, else why
/// not (the same hosts as acpmux's `hosted_mcp::loopback_origin`).
pub(in super::super) fn endpoint(url: &str) -> Result<Endpoint, String> {
    let refused = || format!("{url} is not a loopback http URL (127.0.0.1, [::1] or localhost)");
    let rest = url.strip_prefix("http://").ok_or_else(refused)?;
    let (authority, target) = rest.find(['/', '?', '#']).map_or((rest, ""), |at| rest.split_at(at));
    if authority.contains('@') || target.contains('#') {
        return Err(refused());
    }
    let (host, port) = match authority.strip_prefix('[') {
        Some(v6) => {
            let (host, after) = v6.split_once(']').ok_or_else(refused)?;
            match after {
                "" => (host, None),
                _ => (host, Some(after.strip_prefix(':').ok_or_else(refused)?)),
            }
        }
        None => match authority.rsplit_once(':') {
            Some((host, port)) => (host, Some(port)),
            None => (authority, None),
        },
    };
    let port = match port {
        None => 80,
        Some(port) => port.parse::<u16>().map_err(|_| refused())?,
    };
    let ips: Vec<IpAddr> = if host.eq_ignore_ascii_case("localhost") {
        // Never resolved: a hosts file cannot send it elsewhere.
        vec![Ipv4Addr::LOCALHOST.into(), Ipv6Addr::LOCALHOST.into()]
    } else if host == "127.0.0.1" || (host == "::1" && authority.starts_with('[')) {
        vec![host.parse().map_err(|_| refused())?]
    } else {
        return Err(refused());
    };
    let target = match target.strip_prefix('?') {
        Some(query) => format!("/?{query}"),
        None if target.is_empty() => "/".to_owned(),
        None => target.to_owned(),
    };
    let addrs = ips.into_iter().map(|ip| SocketAddr::new(ip, port)).collect();
    Ok(Endpoint { authority: authority.to_owned(), target, addrs })
}

/// One HTTP upstream: its endpoint, headers and the session the server named.
pub(in super::super) struct Client {
    url: String,
    endpoint: Endpoint,
    headers: Vec<(String, String)>,
    session: Mutex<Option<String>>,
    next_id: AtomicU64,
}

impl Client {
    /// A client of `http`, or why there is none (not loopback, a header that is not one line).
    pub(in super::super) fn new(http: &Http) -> Result<Self, String> {
        let endpoint = endpoint(&http.url)?;
        let bad = |text: &str| text.contains(['\r', '\n']);
        if let Some((name, _)) =
            http.headers.iter().find(|(k, v)| k.is_empty() || k.contains(':') || bad(k) || bad(v))
        {
            return Err(format!("header {name:?} of {} is not one line", http.url));
        }
        Ok(Self {
            url: http.url.clone(),
            endpoint,
            headers: http.headers.clone(),
            session: Mutex::new(None),
            next_id: AtomicU64::new(1),
        })
    }

    pub(in super::super) fn notify(&self, method: &str, timeout: Duration) -> Result<(), String> {
        let message = json!({"jsonrpc": "2.0", "method": method});
        self.post(method, &message, None, timeout).map(|_| ()).map_err(Failure::message)
    }

    /// One request, answered or not within `timeout`.
    pub(in super::super) fn request(
        &self,
        method: &str,
        params: Value,
        timeout: Duration,
    ) -> Result<Value, Failure> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let message = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        let reply = self
            .post(method, &message, Some(id), timeout)?
            .ok_or_else(|| Failure::Lost(format!("no answer to {method}")))?;
        if let Some(error) = reply.get("error") {
            return Err(Failure::Refused(error["message"].as_str().unwrap_or("error").to_owned()));
        }
        Ok(reply["result"].clone())
    }

    /// POSTs `message` and reads the answer to request `id` (a notification: none).
    fn post(
        &self,
        method: &str,
        message: &Value,
        id: Option<u64>,
        timeout: Duration,
    ) -> Result<Option<Value>, Failure> {
        let deadline = Instant::now() + timeout;
        let late = |error: io::Error| match error.kind() {
            io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock => {
                Failure::Lost(format!("no answer to {method} in {} s", timeout.as_secs()))
            }
            _ => Failure::Lost(format!("{method}: {error}")),
        };
        // Not reached: the request did not run.
        let stream = self
            .connect(timeout)
            .map_err(|error| Failure::Unsent(format!("cannot reach {}: {error}", self.url)))?;
        let control = stream.try_clone().map_err(late)?;
        self.send(&stream, message).map_err(late)?;
        let left =
            || deadline.saturating_duration_since(Instant::now()).max(Duration::from_millis(1));
        control.set_read_timeout(Some(left())).map_err(late)?;
        let mut reader = BufReader::new(stream);
        let (status, headers) = read_head(&mut reader).map_err(late)?;
        let header = |name: &str| {
            headers.iter().find(|(k, _)| k.eq_ignore_ascii_case(name)).map(|(_, v)| v.as_str())
        };
        if let Some(session) = header(SESSION_HEADER) {
            *self.session.lock().unwrap_or_else(PoisonError::into_inner) = Some(session.to_owned());
        }
        let body = body(reader, header("transfer-encoding"), header("content-length"));
        if !(200..300).contains(&status) {
            let mut text = String::new();
            let _ = body.take(4096).read_to_string(&mut text);
            let why = format!("{method}: HTTP {status} {}", text.trim());
            return Err(match status {
                // The session ended (the daemon restarted): the next start initializes again.
                404 => Failure::Unsent(why),
                400..=499 => Failure::Refused(why),
                _ => Failure::Lost(why),
            });
        }
        let Some(id) = id else { return Ok(None) };
        if status == 202 {
            return Ok(None);
        }
        let streamed = header("content-type")
            .is_some_and(|kind| kind.trim().to_ascii_lowercase().starts_with("text/event-stream"));
        if streamed {
            let wait = || control.set_read_timeout(Some(left()));
            return events(BufReader::new(body), id, wait).map_err(late);
        }
        let mut text = Vec::new();
        body.take(MAX_REPLY_BYTES).read_to_end(&mut text).map_err(late)?;
        let reply: Value = serde_json::from_slice(&text)
            .map_err(|error| Failure::Lost(format!("{method}: the answer is no JSON: {error}")))?;
        Ok(match reply {
            Value::Array(replies) => replies.into_iter().find(|reply| answers(reply, id)),
            reply => Some(reply),
        })
    }

    fn connect(&self, timeout: Duration) -> io::Result<TcpStream> {
        let mut last = io::Error::new(io::ErrorKind::NotFound, "no address");
        for addr in &self.endpoint.addrs {
            match TcpStream::connect_timeout(addr, timeout) {
                Ok(stream) => {
                    stream.set_nodelay(true)?;
                    stream.set_write_timeout(Some(timeout))?;
                    return Ok(stream);
                }
                Err(error) => last = error,
            }
        }
        Err(last)
    }

    fn send(&self, mut stream: &TcpStream, message: &Value) -> io::Result<()> {
        let body = message.to_string();
        let Endpoint { authority, target, .. } = &self.endpoint;
        let mut head = format!(
            "POST {target} HTTP/1.1\r\nhost: {authority}\r\ncontent-type: application/json\r\n\
             accept: application/json, text/event-stream\r\ncontent-length: {}\r\n\
             connection: close\r\n",
            body.len()
        );
        for (name, value) in &self.headers {
            head.push_str(&format!("{name}: {value}\r\n"));
        }
        if let Some(session) = self.session.lock().unwrap_or_else(PoisonError::into_inner).as_ref()
        {
            head.push_str(&format!("{SESSION_HEADER}: {session}\r\n"));
        }
        head.push_str("\r\n");
        head.push_str(&body);
        stream.write_all(head.as_bytes())?;
        stream.flush()
    }
}

/// Whether `reply` is the answer to request `id`.
fn answers(reply: &Value, id: u64) -> bool {
    reply.get("method").is_none() && reply["id"].as_u64() == Some(id)
}

/// The status and headers of a reply.
fn read_head(reader: &mut impl BufRead) -> io::Result<(u16, Vec<(String, String)>)> {
    let bad = |what: &str| io::Error::new(io::ErrorKind::InvalidData, what.to_owned());
    let mut line = String::new();
    reader.read_line(&mut line)?;
    let status = line
        .split_whitespace()
        .nth(1)
        .and_then(|code| code.parse::<u16>().ok())
        .ok_or_else(|| bad("no HTTP status line"))?;
    let mut headers = Vec::new();
    loop {
        line.clear();
        if reader.read_line(&mut line)? == 0 {
            return Err(bad("the headers did not end"));
        }
        let line = line.trim_end();
        if line.is_empty() {
            return Ok((status, headers));
        }
        if let Some((name, value)) = line.split_once(':') {
            headers.push((name.trim().to_owned(), value.trim().to_owned()));
        }
    }
}

/// The reply's body: chunked, of a length, or until the server closes.
fn body<R: BufRead + 'static>(
    reader: R,
    encoding: Option<&str>,
    length: Option<&str>,
) -> Box<dyn Read> {
    if encoding.is_some_and(|e| e.to_ascii_lowercase().contains("chunked")) {
        return Box::new(Chunked { inner: reader, left: 0, done: false });
    }
    match length.and_then(|length| length.trim().parse::<u64>().ok()) {
        Some(length) => Box::new(reader.take(length)),
        None => Box::new(reader),
    }
}

/// A chunked body (its trailers are not read: the connection closes after it).
struct Chunked<R> {
    inner: R,
    left: u64,
    done: bool,
}

impl<R: BufRead> Read for Chunked<R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if self.done || buf.is_empty() {
            return Ok(0);
        }
        if self.left == 0 {
            let mut line = String::new();
            self.inner.read_line(&mut line)?;
            let size = line.split(';').next().unwrap_or_default().trim();
            let size = u64::from_str_radix(size, 16)
                .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "bad chunk size"))?;
            if size == 0 {
                self.done = true;
                return Ok(0);
            }
            self.left = size;
        }
        let want = buf.len().min(usize::try_from(self.left).unwrap_or(usize::MAX));
        let read = self.inner.read(buf.get_mut(..want).unwrap_or_default())?;
        if read == 0 {
            return Err(io::ErrorKind::UnexpectedEof.into());
        }
        self.left -= read as u64;
        if self.left == 0 {
            let mut end = String::new();
            self.inner.read_line(&mut end)?;
        }
        Ok(read)
    }
}

/// The answer to request `id` in an event stream: each event's `data:` lines joined, the
/// server's own requests and notifications skipped. `wait` sets the time left before each read.
fn events(
    reader: impl BufRead,
    id: u64,
    wait: impl Fn() -> io::Result<()>,
) -> io::Result<Option<Value>> {
    let mut data = String::new();
    let mut read = 0u64;
    let mut lines = reader.lines();
    loop {
        wait()?;
        let Some(line) = lines.next().transpose()? else { return Ok(None) };
        read += line.len() as u64 + 1;
        if read > MAX_REPLY_BYTES {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "the event stream is too long"));
        }
        if line.is_empty() {
            if let Ok(reply) = serde_json::from_str::<Value>(&data)
                && answers(&reply, id)
            {
                return Ok(Some(reply));
            }
            data.clear();
        } else if let Some(value) = line.strip_prefix("data:") {
            if !data.is_empty() {
                data.push('\n');
            }
            data.push_str(value.strip_prefix(' ').unwrap_or(value));
        }
    }
}
