//! Page files on the daemon's WebSocket listener (cx-hnmbt.2): the first
//! step of page-router-v1 (spec/transports.md "App listener and page files").
//!
//! A plain `GET /pages/<page>/[<file>]` (no WebSocket upgrade) gets a file of
//! the page bundle directory, so a browser opens a cmux page at the
//! listener's own origin and its WebSocket passes the localhost rule with no
//! extra flag. The request passes the same Host/Origin rule as a WebSocket
//! handshake before anything is read from disk. Nothing outside the bundle
//! is served: path segments are plain names (no `..`, no dot files, no
//! percent escapes), and the resolved file must stay under the bundle root.

use cmux_threads::checked::fs as files;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};

/// Largest request head the listener reads before it decides. Browsers send
/// every 127.0.0.1 cookie (cookies ignore the port), so a handshake head can
/// be large; a bigger one gets 431.
pub(crate) const REQUEST_HEAD_MAX_BYTES: usize = 64 * 1024;
/// Largest page file served.
const PAGE_FILE_MAX_BYTES: u64 = 32 * 1024 * 1024;

/// One parsed HTTP request head.
pub(crate) struct RequestHead {
    pub method: String,
    pub target: String,
    headers: Vec<(String, String)>,
}

impl RequestHead {
    /// Every value of header `name` (case-insensitive), in order.
    pub fn values(&self, name: &str) -> Vec<&str> {
        self.headers
            .iter()
            .filter(|(key, _)| key.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.as_str())
            .collect()
    }

    /// Every field name, in order, as sent.
    #[cfg(any(test, feature = "fuzz"))]
    pub fn names(&self) -> impl Iterator<Item = &str> {
        self.headers.iter().map(|(name, _)| name.as_str())
    }

    /// Whether the request asks for a WebSocket upgrade.
    pub fn is_websocket_upgrade(&self) -> bool {
        self.values("upgrade").iter().any(|value| value.trim().eq_ignore_ascii_case("websocket"))
    }
}

/// Reads up to the end of the request head. Returns every byte read (the
/// head and anything after it, for the WebSocket handshake to replay) and the
/// parsed head; None for a closed, oversized or malformed request.
pub(crate) fn read_request_head(
    stream: &mut (impl Read + Write),
) -> Option<(Vec<u8>, RequestHead)> {
    read_request_head_within(stream, REQUEST_HEAD_MAX_BYTES)
}

/// `read_request_head` with the head limit `max_bytes`, past which it answers
/// 431. Generic over the stream and the limit so the fuzz target (cmux-tui/fuzz
/// `page_request_head`) drives it with in-memory reads and reaches the 431
/// branch with short inputs.
pub(crate) fn read_request_head_within(
    stream: &mut (impl Read + Write),
    max_bytes: usize,
) -> Option<(Vec<u8>, RequestHead)> {
    let mut bytes = Vec::with_capacity(1024);
    let mut chunk = [0u8; 4096];
    let end = loop {
        if let Some(end) = bytes.windows(4).position(|window| window == b"\r\n\r\n") {
            break end;
        }
        if bytes.len() >= max_bytes {
            let _ = stream.write_all(&plain(431, "Request Header Fields Too Large"));
            return None;
        }
        let read = stream.read(&mut chunk).ok()?;
        if read == 0 {
            return None;
        }
        bytes.extend_from_slice(chunk.get(..read)?);
    };
    let head = std::str::from_utf8(bytes.get(..end)?).ok()?;
    // Lines end only at CRLF; a bare CR or LF, or any other control byte but
    // HTAB, makes the head malformed (RFC 9112 sections 2.2 and 5.5).
    if head
        .split("\r\n")
        .any(|line| line.bytes().any(|byte| byte.is_ascii_control() && byte != b'\t'))
    {
        return None;
    }
    let mut lines = head.split("\r\n");
    // request-line = method SP request-target SP HTTP-version, exactly three
    // parts (RFC 9112 section 3); the method is a token (RFC 9110 section 9.1).
    // Chromium's embedded server splits it into the same three parts
    // (net/server/http_server.cc, ParseHeaders).
    let mut request_line = lines.next()?.split(' ');
    let (method, target, version) =
        (request_line.next()?, request_line.next()?, request_line.next()?);
    if request_line.next().is_some()
        || !is_token(method)
        || target.is_empty()
        || !is_http1_version(version)
    {
        return None;
    }
    let mut headers = Vec::new();
    for line in lines {
        // field-line = field-name ":" OWS field-value OWS (RFC 9112 section 5).
        // The name is a token, so whitespace before the colon (section 5.1)
        // or at the line start, obs-fold (section 5.2), makes it malformed.
        let (name, value) = line.split_once(':')?;
        if !is_token(name) {
            return None;
        }
        headers.push((name.to_owned(), value.trim_matches([' ', '\t']).to_owned()));
    }
    let parsed = RequestHead { method: method.to_owned(), target: target.to_owned(), headers };
    Some((bytes, parsed))
}

/// A non-empty run of `tchar` (RFC 9110 section 5.6.2).
fn is_token(text: &str) -> bool {
    !text.is_empty()
        && text
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"!#$%&'*+-.^_`|~".contains(&byte))
}

/// `HTTP/1.` and one digit (RFC 9112 section 2.3): the listener speaks
/// HTTP/1.x only.
fn is_http1_version(version: &str) -> bool {
    version
        .strip_prefix("HTTP/1.")
        .is_some_and(|minor| minor.len() == 1 && minor.bytes().all(|byte| byte.is_ascii_digit()))
}

/// Answers one page file request and closes the connection.
pub(super) fn serve(
    mut stream: TcpStream,
    head: &RequestHead,
    policy: &cmux_local_auth::ListenerPolicy,
    pages: Option<&Path>,
) {
    let reply = respond(head, policy, pages);
    let _ = stream.write_all(&reply);
    let _ = stream.flush();
    let _ = stream.shutdown(std::net::Shutdown::Both);
}

fn respond(
    head: &RequestHead,
    policy: &cmux_local_auth::ListenerPolicy,
    pages: Option<&Path>,
) -> Vec<u8> {
    if policy.check(&head.values("host"), &head.values("origin")).is_err() {
        return plain(403, "Forbidden");
    }
    if head.method != "GET" && head.method != "HEAD" {
        return plain(405, "Method Not Allowed");
    }
    let Some(file) = pages.and_then(|root| resolve(root, &head.target)) else {
        return plain(404, "Not Found");
    };
    let Ok(body) = read_file(&file) else { return plain(404, "Not Found") };
    let content_type = content_type(&file);
    let body = with_shared_chunks_here(body, content_type);
    let mut response = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\n\
         X-Content-Type-Options: nosniff\r\nCache-Control: no-store\r\n\
         Referrer-Policy: no-referrer\r\nCross-Origin-Resource-Policy: same-origin\r\n\
         X-Frame-Options: DENY\r\nConnection: close\r\n",
        body.len()
    );
    if content_type.starts_with("text/html") {
        response.push_str(&format!(
            "Content-Security-Policy: {}\r\n",
            page_policy(head.values("host").first().copied())
        ));
    }
    response.push_str("\r\n");
    let mut bytes = response.into_bytes();
    if head.method == "GET" {
        bytes.extend_from_slice(&body);
    }
    bytes
}

/// The page policy: no network but this listener's WebSocket (by the Host the
/// browser used, which the listener rule already checked), no frames, no
/// plugins, nothing else than the bundle and its own files. Inline script
/// stays allowed: each page is one self-contained index.html
/// (build-pages-web.sh).
fn page_policy(host: Option<&str>) -> String {
    let websocket = host
        .filter(|host| {
            !host.is_empty()
                && host.bytes().all(|byte| byte.is_ascii_alphanumeric() || b".:-[]".contains(&byte))
        })
        .map_or_else(String::new, |host| format!(" ws://{host}"));
    format!(
        "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; \
         img-src 'self' data: blob:; media-src 'self' blob:; font-src 'self' data:; \
         connect-src 'self'{websocket}; \
         base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
    )
}

/// The bundle file for `target` (`/pages/<page>/[<file>...]`), or None.
fn resolve(root: &Path, target: &str) -> Option<PathBuf> {
    let path = target.split(['?', '#']).next()?;
    let rest = path.strip_prefix("/pages/")?;
    let mut segments: Vec<&str> = rest.split('/').collect();
    if segments.last() == Some(&"") {
        segments.pop();
        segments.push("index.html");
    }
    if segments.len() < 2 || segments.len() > 4 {
        return None;
    }
    let plain = |segment: &str| {
        !segment.is_empty()
            && !segment.starts_with('.')
            && segment.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte))
    };
    if !segments.iter().all(|segment| plain(segment)) {
        return None;
    }
    let root = files::canonicalize(root).ok()?;
    let file = segments.iter().fold(root.clone(), |path, segment| path.join(segment));
    let file = files::canonicalize(file).ok()?;
    let is_file = files::metadata(&file).is_ok_and(|metadata| metadata.is_file());
    (file.starts_with(&root) && is_file).then_some(file)
}

/// The origin the app's pages import their shared chunks from (build-pages.mjs
/// `SHARED_ORIGIN`, CmuxNextPages `PageID.sharedOrigin`), and the path of the
/// same chunks (the bundle's `_shared/`) on this listener.
const SHARED_CHUNK_ORIGIN: &[u8] = b"cmux-page://cmux.shared/";
const SHARED_CHUNK_PATH: &[u8] = b"/pages/_shared/";

/// `body` with every shared chunk URL of a page or script named by its path
/// on this listener, since a browser has no cmux-page:// scheme; any other
/// file unchanged.
fn with_shared_chunks_here(body: Vec<u8>, content_type: &str) -> Vec<u8> {
    let names_chunks =
        content_type.starts_with("text/html") || content_type.starts_with("text/javascript");
    if !names_chunks || !body.windows(SHARED_CHUNK_ORIGIN.len()).any(|w| w == SHARED_CHUNK_ORIGIN) {
        return body;
    }
    let mut served = Vec::with_capacity(body.len());
    let mut rest = body.as_slice();
    while let Some(at) =
        rest.windows(SHARED_CHUNK_ORIGIN.len()).position(|w| w == SHARED_CHUNK_ORIGIN)
    {
        let (before, after) = rest.split_at(at);
        served.extend_from_slice(before);
        served.extend_from_slice(SHARED_CHUNK_PATH);
        rest = after.get(SHARED_CHUNK_ORIGIN.len()..).unwrap_or_default();
    }
    served.extend_from_slice(rest);
    served
}

fn read_file(path: &Path) -> std::io::Result<Vec<u8>> {
    let file = files::open(path)?;
    if file.metadata()?.len() > PAGE_FILE_MAX_BYTES {
        return Err(std::io::Error::other("page file too large"));
    }
    let mut body = Vec::new();
    file.take(PAGE_FILE_MAX_BYTES).read_to_end(&mut body)?;
    Ok(body)
}

fn content_type(path: &Path) -> &'static str {
    match path.extension().and_then(|extension| extension.to_str()) {
        Some("html") => "text/html; charset=utf-8",
        Some("js" | "mjs") => "text/javascript; charset=utf-8",
        Some("css") => "text/css; charset=utf-8",
        Some("json") => "application/json",
        Some("svg") => "image/svg+xml",
        Some("png") => "image/png",
        Some("wasm") => "application/wasm",
        Some("woff2") => "font/woff2",
        _ => "application/octet-stream",
    }
}

fn plain(status: u16, reason: &str) -> Vec<u8> {
    format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: text/plain; charset=utf-8\r\n\
         Content-Length: {}\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n{reason}",
        reason.len()
    )
    .into_bytes()
}

/// Page bundle folders relative to the parent of the binary's directory:
/// the portable install layout (Linux, Windows), then the macOS app, whose
/// binary is `Contents/Resources/bin/cmux-tui` and whose pages are in the
/// CmuxNextPages resource bundle. The app-bundle entry lets an owner that the
/// CLI or an agent starts from the bundled binary (no `CMUX_TUI_PAGES_DIR`)
/// serve the same pages (cx-hnmbt.7).
const PAGE_BUNDLE_LAYOUTS: [&str; 2] =
    ["share/cmux-tui/pages", "CmuxNext_CmuxNextPages.bundle/Contents/Resources/pages"];

/// The page bundle directory: `CMUX_TUI_PAGES_DIR` (a host that bundles the
/// pages, such as the cmux app, sets it), else the first of
/// [`PAGE_BUNDLE_LAYOUTS`] next to the binary's directory (as invoked, then
/// with symlinks resolved), else none (every page request is a 404).
pub fn page_bundle_dir() -> Option<PathBuf> {
    if let Some(dir) = std::env::var_os("CMUX_TUI_PAGES_DIR").filter(|value| !value.is_empty()) {
        return Some(PathBuf::from(dir));
    }
    let exe = std::env::current_exe().ok()?;
    let resolved = files::canonicalize(&exe).ok();
    [Some(exe), resolved]
        .into_iter()
        .flatten()
        .filter_map(|exe| exe.parent()?.parent().map(PathBuf::from))
        .flat_map(|root| PAGE_BUNDLE_LAYOUTS.map(|layout| root.join(layout)))
        .find(|dir| files::metadata(dir).is_ok_and(|metadata| metadata.is_dir()))
}

#[cfg(test)]
mod tests;
