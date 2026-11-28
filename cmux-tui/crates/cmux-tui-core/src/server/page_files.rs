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

use std::io::{Read, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};

/// Largest request head the listener reads before it decides. Browsers send
/// every 127.0.0.1 cookie (cookies ignore the port), so a handshake head can
/// be large; a bigger one gets 431.
pub(super) const REQUEST_HEAD_MAX_BYTES: usize = 64 * 1024;
/// Largest page file served.
const PAGE_FILE_MAX_BYTES: u64 = 32 * 1024 * 1024;

/// One parsed HTTP request head.
pub(super) struct RequestHead {
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

    /// Whether the request asks for a WebSocket upgrade.
    pub fn is_websocket_upgrade(&self) -> bool {
        self.values("upgrade").iter().any(|value| value.trim().eq_ignore_ascii_case("websocket"))
    }
}

/// Reads up to the end of the request head. Returns every byte read (the
/// head and anything after it, for the WebSocket handshake to replay) and the
/// parsed head; None for a closed, oversized or malformed request.
pub(super) fn read_request_head(stream: &mut TcpStream) -> Option<(Vec<u8>, RequestHead)> {
    let mut bytes = Vec::with_capacity(1024);
    let mut chunk = [0u8; 4096];
    let end = loop {
        if let Some(end) = bytes.windows(4).position(|window| window == b"\r\n\r\n") {
            break end;
        }
        if bytes.len() >= REQUEST_HEAD_MAX_BYTES {
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
    let mut lines = head.split("\r\n");
    let mut request_line = lines.next()?.split(' ');
    let method = request_line.next()?.to_owned();
    let target = request_line.next()?.to_owned();
    let mut headers = Vec::new();
    for line in lines {
        let (name, value) = line.split_once(':')?;
        headers.push((name.trim().to_owned(), value.trim().to_owned()));
    }
    Some((bytes, RequestHead { method, target, headers }))
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
    let Some((file, body)) = pages.and_then(|root| page_file(root, &head.target)) else {
        return plain(404, "Not Found");
    };
    let content_type = content_type(&file);
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
        "default-src 'none'; script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval'; \
         style-src 'self' 'unsafe-inline'; \
         img-src 'self' data: blob:; media-src 'self' blob:; font-src 'self' data:; \
         connect-src 'self'{websocket}; \
         base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
    )
}

/// Suffix of a page file the pages builder stores raw-deflated (CMUX-570,
/// app size): webviews/scripts/pages/pack-pages.mjs replaces a `__shared`
/// script no first-window page imports statically by `<name>.js.deflate`.
const PACKED_SUFFIX: &str = ".deflate";

/// The file `target` names and its bytes: the file itself, else its packed
/// copy (`<file>.deflate`) inflated, under the path of the file it stands for
/// (so its content type is the script's).
fn page_file(root: &Path, target: &str) -> Option<(PathBuf, Vec<u8>)> {
    let path = target.split(['?', '#']).next()?;
    if path.ends_with(PACKED_SUFFIX) {
        return None;
    }
    if let Some(file) = resolve(root, target) {
        return read_file(&file).ok().map(|body| (file, body));
    }
    if path.ends_with('/') {
        return None;
    }
    let packed = resolve(root, &format!("{path}{PACKED_SUFFIX}"))?;
    let body = inflate(&read_file(&packed).ok()?)?;
    let name = packed.file_name()?.to_str()?.strip_suffix(PACKED_SUFFIX)?.to_owned();
    Some((packed.with_file_name(name), body))
}

/// Raw DEFLATE (RFC 1951), at most [`PAGE_FILE_MAX_BYTES`] inflated.
fn inflate(stored: &[u8]) -> Option<Vec<u8>> {
    let mut body = Vec::new();
    flate2::read::DeflateDecoder::new(stored)
        .take(PAGE_FILE_MAX_BYTES + 1)
        .read_to_end(&mut body)
        .ok()?;
    (body.len() as u64 <= PAGE_FILE_MAX_BYTES).then_some(body)
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
    let root = root.canonicalize().ok()?;
    let file = segments.iter().fold(root.clone(), |path, segment| path.join(segment));
    let file = file.canonicalize().ok()?;
    (file.starts_with(&root) && file.is_file()).then_some(file)
}

fn read_file(path: &Path) -> std::io::Result<Vec<u8>> {
    let file = std::fs::File::open(path)?;
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
    let resolved = std::fs::canonicalize(&exe).ok();
    [Some(exe), resolved]
        .into_iter()
        .flatten()
        .filter_map(|exe| exe.parent()?.parent().map(PathBuf::from))
        .flat_map(|root| PAGE_BUNDLE_LAYOUTS.map(|layout| root.join(layout)))
        .find(|dir| dir.is_dir())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn packed_tree(name: &str) -> PathBuf {
        let stamp =
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
        let root = std::env::temp_dir()
            .join(format!("cmux-page-files-{name}-{}-{stamp}", std::process::id()))
            .join("pages");
        std::fs::create_dir_all(root.join("__shared")).unwrap();
        std::fs::write(root.join("__shared/kept.js"), "export const kept = 1;").unwrap();
        let mut encoder =
            flate2::write::DeflateEncoder::new(Vec::new(), flate2::Compression::best());
        encoder.write_all(b"export const settings = 'packed';").unwrap();
        std::fs::write(root.join("__shared/page-settings.js.deflate"), encoder.finish().unwrap())
            .unwrap();
        root
    }

    #[test]
    fn a_packed_page_script_is_served_inflated_as_javascript() {
        let root = packed_tree("served");
        let (file, body) = page_file(&root, "/pages/__shared/page-settings.js?v=1").unwrap();
        assert_eq!(body, b"export const settings = 'packed';");
        assert_eq!(file.file_name().unwrap(), "page-settings.js");
        assert_eq!(content_type(&file), "text/javascript; charset=utf-8");
        // An unpacked file is read as it is.
        let (_, kept) = page_file(&root, "/pages/__shared/kept.js").unwrap();
        assert_eq!(kept, b"export const kept = 1;");
        // The packed copy itself and missing files are not served.
        assert!(page_file(&root, "/pages/__shared/page-settings.js.deflate").is_none());
        assert!(page_file(&root, "/pages/__shared/missing.js").is_none());
        let _ = std::fs::remove_dir_all(root.parent().unwrap());
    }

    #[test]
    fn a_packed_file_that_does_not_inflate_is_not_served() {
        let root = packed_tree("corrupt");
        std::fs::write(root.join("__shared/broken.js.deflate"), [0xff, 0xff, 0xff, 0xff]).unwrap();
        assert!(page_file(&root, "/pages/__shared/broken.js").is_none());
        let _ = std::fs::remove_dir_all(root.parent().unwrap());
    }
}
