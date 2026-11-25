//! Sans-I/O HTTP/1.1 for the LocalAPI: one GET request, one response with a
//! body that is `Content-Length`, chunked, or read to close. The transport
//! feeds bytes in; this module says when the response is complete and
//! refuses one larger than the cap before reading on.

use base64::Engine;

use crate::Error;

/// The Host header tailscaled's LocalAPI expects on every transport.
pub const LOCALAPI_HOST: &str = "local-tailscaled.sock";
/// Largest response head (status line and headers).
pub const MAX_HEAD: usize = 16 * 1024;

/// The read-only endpoints this crate may call. A closed set, so no caller
/// can reach a mutating LocalAPI route through it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Endpoint {
    Status,
    Prefs,
    ProfileCurrent,
    /// `whois?addr=IP` (an address, optionally with a port).
    WhoIs(String),
}

impl Endpoint {
    pub fn path(&self) -> String {
        match self {
            Self::Status => "/localapi/v0/status".into(),
            Self::Prefs => "/localapi/v0/prefs".into(),
            Self::ProfileCurrent => "/localapi/v0/profiles/current".into(),
            Self::WhoIs(addr) => format!("/localapi/v0/whois?addr={}", encode_query(addr)),
        }
    }
}

/// The request bytes. `token` is the macOS same-user token (sent as Basic
/// auth with an empty user, as tailscale's safesocket does).
pub fn request(endpoint: &Endpoint, token: Option<&str>) -> Vec<u8> {
    let mut req = format!(
        "GET {} HTTP/1.1\r\nHost: {LOCALAPI_HOST}\r\nSec-Tailscale: localapi\r\nAccept-Encoding: identity\r\nConnection: close\r\n",
        endpoint.path()
    );
    if let Some(token) = token {
        let basic = base64::engine::general_purpose::STANDARD.encode(format!(":{token}"));
        req.push_str(&format!("Authorization: Basic {basic}\r\n"));
    }
    req.push_str("\r\n");
    req.into_bytes()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Framing {
    Length(usize),
    Chunked,
    Close,
}

#[derive(Debug)]
struct Head {
    status: u16,
    body_start: usize,
    framing: Framing,
}

/// Accumulates one response.
#[derive(Debug)]
pub struct ResponseReader {
    buf: Vec<u8>,
    head: Option<Head>,
    max_body: usize,
}

/// What the reader needs next.
#[derive(Debug, PartialEq, Eq)]
pub enum Progress {
    More,
    /// Complete: status and decoded body.
    Done {
        status: u16,
        body: Vec<u8>,
    },
}

impl ResponseReader {
    pub fn new(max_body: usize) -> Self {
        Self { buf: Vec::new(), head: None, max_body }
    }

    /// Feeds bytes read from the connection; `eof` when the peer closed.
    pub fn feed(&mut self, bytes: &[u8], eof: bool) -> Result<Progress, Error> {
        self.buf.extend_from_slice(bytes);
        if self.head.is_none() {
            match split_after(&self.buf, b"\r\n\r\n") {
                Some((head, _)) => self.head = Some(parse_head(head)?),
                None if self.buf.len() > MAX_HEAD => {
                    return Err(Error::Http("response head too large".into()));
                }
                None if eof => return Err(Error::Http("connection closed before headers".into())),
                None => return Ok(Progress::More),
            }
        }
        let Some(head) = self.head.as_ref() else { return Ok(Progress::More) };
        let body = self.buf.get(head.body_start..).unwrap_or_default();
        // Raw bytes past the cap (with room for chunk framing) are refused
        // before reading on, whatever the framing says.
        let slack = (self.max_body / 8).saturating_add(1024);
        if body.len() > self.max_body.saturating_add(slack) {
            return Err(Error::TooLarge);
        }
        match head.framing {
            Framing::Length(n) => {
                if n > self.max_body {
                    return Err(Error::TooLarge);
                }
                if let Some(whole) = body.get(..n) {
                    return Ok(Progress::Done { status: head.status, body: whole.to_vec() });
                }
                if eof {
                    return Err(Error::Http("connection closed mid-body".into()));
                }
                Ok(Progress::More)
            }
            Framing::Close => {
                if body.len() > self.max_body {
                    return Err(Error::TooLarge);
                }
                if eof {
                    return Ok(Progress::Done { status: head.status, body: body.to_vec() });
                }
                Ok(Progress::More)
            }
            Framing::Chunked => match dechunk(body, self.max_body)? {
                Some(decoded) => Ok(Progress::Done { status: head.status, body: decoded }),
                None if eof => Err(Error::Http("connection closed mid-chunk".into())),
                None => Ok(Progress::More),
            },
        }
    }
}

/// `hay` split just past the first `needle`: (up to and including it, the rest).
fn split_after<'a>(hay: &'a [u8], needle: &[u8]) -> Option<(&'a [u8], &'a [u8])> {
    let at = hay.windows(needle.len()).position(|w| w == needle)?;
    hay.split_at_checked(at.checked_add(needle.len())?)
}

fn parse_head(head: &[u8]) -> Result<Head, Error> {
    let text = std::str::from_utf8(head).map_err(|_| Error::Http("non-UTF-8 head".into()))?;
    let mut lines = text.split("\r\n");
    let status_line = lines.next().unwrap_or("");
    let mut parts = status_line.splitn(3, ' ');
    let version = parts.next().unwrap_or("");
    if !version.starts_with("HTTP/1.") {
        return Err(Error::Http("not an HTTP/1.x response".into()));
    }
    let status: u16 = parts
        .next()
        .and_then(|s| s.parse().ok())
        .ok_or_else(|| Error::Http("bad status line".into()))?;
    let mut framing = Framing::Close;
    for line in lines {
        let Some((name, value)) = line.split_once(':') else { continue };
        let value = value.trim();
        if name.eq_ignore_ascii_case("transfer-encoding") {
            if value.to_ascii_lowercase().contains("chunked") {
                framing = Framing::Chunked;
            }
        } else if name.eq_ignore_ascii_case("content-length") && framing != Framing::Chunked {
            let n = value.parse().map_err(|_| Error::Http("bad Content-Length".into()))?;
            framing = Framing::Length(n);
        }
    }
    if status == 204 || status == 304 {
        framing = Framing::Length(0);
    }
    Ok(Head { status, body_start: head.len(), framing })
}

/// Decodes a complete chunked body; `None` while it is incomplete.
fn dechunk(mut raw: &[u8], max_body: usize) -> Result<Option<Vec<u8>>, Error> {
    let mut out = Vec::new();
    loop {
        let Some((size_line, rest)) = split_after(raw, b"\r\n") else { return Ok(None) };
        let size_text =
            std::str::from_utf8(size_line).map_err(|_| Error::Http("bad chunk size".into()))?;
        let size_text = size_text.split(';').next().unwrap_or("").trim();
        let size = usize::from_str_radix(size_text, 16)
            .map_err(|_| Error::Http("bad chunk size".into()))?;
        if out.len().saturating_add(size) > max_body {
            return Err(Error::TooLarge);
        }
        raw = rest;
        if size == 0 {
            // Trailers end with an empty line; tailscaled sends none.
            return Ok(split_after(raw, b"\r\n").map(|_| out));
        }
        let Some((data, rest)) = raw.split_at_checked(size) else { return Ok(None) };
        let Some(rest) = rest.strip_prefix(b"\r\n") else {
            return if rest.len() < 2 {
                Ok(None)
            } else {
                Err(Error::Http("bad chunk end".into()))
            };
        };
        out.extend_from_slice(data);
        raw = rest;
    }
}

fn encode_query(value: &str) -> String {
    value
        .bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'.' | b'-' | b'_' => (b as char).to_string(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}
