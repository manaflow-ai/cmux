//! `open` on a `.pptx`: the deck previews in a browser tab, slide strip on the left and the
//! current slide fit to the pane.
//!
//! The app has no slide renderer and gains none: this server serves a small viewer page on
//! loopback (127.0.0.1, a random port, a random path token per deck, read-only, GET only),
//! and the page loads a slide renderer from a CDN, pinned by version and checked against
//! its hash, then fetches the deck's bytes from the same token. The browser caches the
//! renderer after the first open. `open {live}` watches the deck, so a changed file
//! reloads the page; a deleted one shows a one-line notice there.
//!
//! One listener and one accept thread for the life of this server, started with the first
//! deck; each connection is answered on its own short thread. At most [`MAX_DECKS`] decks
//! are served; a newer one drops the oldest.
//!
//! A Markdown deck (`md_deck`) is served here too: its page is the deck compiled from the
//! file on each load, and the files in its folder (pictures the slides name) are served
//! read-only beside it.

use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use base64::Engine as _;
use sha2::{Digest, Sha256};

use super::md_deck;

pub(super) const MAX_DECKS: usize = 64;
/// Connections answered at once; one tab makes two or three.
const MAX_CONNECTIONS: usize = 32;

/// The slide renderer: a self-contained ES module build (Apache-2.0), 2,371,205 bytes,
/// 465,687 gzipped. Changing it means changing both lines together.
pub(super) const RENDERER_URL: &str = "https://cdn.jsdelivr.net/npm/@aiden0z/pptx-renderer@1.4.0/dist/aiden0z-pptx-renderer.browser.es.js";
pub(super) const RENDERER_SRI: &str =
    "sha384-nWoyDjq4Cw0UZP+rLW/OfUcTxM1HfIiso2fL4BsfcEe4QhM5WyJiUXCGfiUtHNV6";

const PAGE: &str = include_str!("pptx_view.html");
const DECK_TYPE: &str = "application/vnd.openxmlformats-officedocument.presentationml.presentation";

/// Whether `open` shows `path` through the deck viewer.
pub(super) fn is_deck(path: &str) -> bool {
    Path::new(path)
        .extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| extension.eq_ignore_ascii_case("pptx"))
}

/// What a served deck is: a PowerPoint file the viewer renders, or Markdown compiled to
/// the deck page.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(super) enum Kind {
    Pptx,
    Markdown,
}

type Served = Arc<Mutex<VecDeque<(String, PathBuf, Kind)>>>;

/// The decks this server shows, and the loopback listener that serves them.
pub(super) struct Decks {
    port: u16,
    served: Served,
}

impl Decks {
    pub(super) fn start() -> Result<Self, String> {
        let listener = TcpListener::bind(("127.0.0.1", 0))
            .map_err(|error| format!("cannot serve the deck viewer: {error}"))?;
        let port = listener.local_addr().map_err(|error| error.to_string())?.port();
        let served = Served::default();
        let shared = served.clone();
        std::thread::Builder::new()
            .name("cmux-mcp-deck-view".into())
            .spawn(move || {
                let open = Arc::new(AtomicUsize::new(0));
                for stream in listener.incoming().flatten() {
                    // Past the cap a connection is dropped unanswered; the browser retries.
                    if open.fetch_add(1, Ordering::AcqRel) >= MAX_CONNECTIONS {
                        open.fetch_sub(1, Ordering::AcqRel);
                        continue;
                    }
                    let (served, open) = (shared.clone(), open.clone());
                    let spawned =
                        std::thread::Builder::new().name("cmux-mcp-deck-request".into()).spawn({
                            let open = open.clone();
                            move || {
                                answer(stream, port, &served);
                                open.fetch_sub(1, Ordering::AcqRel);
                            }
                        });
                    if spawned.is_err() {
                        open.fetch_sub(1, Ordering::AcqRel);
                    }
                }
            })
            .map_err(|error| format!("cannot start the deck viewer: {error}"))?;
        Ok(Self { port, served })
    }

    /// The viewer's address for `path`: the same one for a deck already served, so its
    /// open slide survives a second `open`.
    pub(super) fn url(&self, path: &Path, kind: Kind) -> Result<String, String> {
        // One token per file however it is named (macOS: /tmp is /private/tmp).
        let path = &path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
        let mut served = self.served.lock().map_err(|_| "deck viewer lock".to_owned())?;
        let known = served.iter().position(|(_, served, _)| served == path);
        let token = match known.and_then(|at| served.remove(at)) {
            Some((token, path, _)) => {
                served.push_back((token.clone(), path, kind));
                token
            }
            None => {
                let mut bytes = [0u8; 16];
                getrandom::fill(&mut bytes).map_err(|error| error.to_string())?;
                let token: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
                served.push_back((token.clone(), path.to_path_buf(), kind));
                let excess = served.len().saturating_sub(MAX_DECKS);
                served.drain(..excess);
                token
            }
        };
        Ok(format!("http://127.0.0.1:{}/{token}/", self.port))
    }
}

struct Response {
    status: &'static str,
    headers: Vec<(&'static str, String)>,
    body: Body,
}

enum Body {
    Text(String),
    File(std::fs::File, u64),
}

fn text(status: &'static str, body: &str) -> Response {
    Response {
        status,
        headers: vec![("Content-Type", "text/plain; charset=utf-8".into())],
        body: Body::Text(body.to_owned()),
    }
}

/// Answers one request on `stream`, then closes it. A connection that sends nothing (the
/// browser's spare connection, closed or timed out) is closed without an answer, so a
/// request it carries later is never met by a stray 400.
fn answer(stream: TcpStream, port: u16, served: &Served) {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(60)));
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    if !matches!(reader.read_line(&mut line), Ok(read) if read > 0) {
        return;
    }
    let (head, response) = match read_head(&line, &mut reader) {
        Some(head) => {
            let response = respond(&head, port, served);
            (Some(head), response)
        }
        None => (None, text("400 Bad Request", "bad request")),
    };
    let mut stream = reader.into_inner();
    let head_only = head.as_ref().is_some_and(|head| head.method == "HEAD");
    let _ = write_response(&mut stream, response, head_only);
}

struct Head {
    method: String,
    target: String,
    host: Option<String>,
}

/// The request line and the Host header; `None` for a malformed or oversized head.
fn read_head(first: &str, reader: &mut impl BufRead) -> Option<Head> {
    let mut limited = reader.take(16 * 1024);
    let mut line = String::new();
    let mut parts = first.split_ascii_whitespace();
    let method = parts.next()?.to_owned();
    let target = parts.next()?.to_owned();
    parts.next()?.starts_with("HTTP/1.").then_some(())?;
    let mut host = None;
    loop {
        line.clear();
        if limited.read_line(&mut line).ok()? == 0 {
            return None;
        }
        let header = line.trim_end_matches(['\r', '\n']);
        if header.is_empty() {
            break;
        }
        if let Some((name, value)) = header.split_once(':')
            && name.trim().eq_ignore_ascii_case("host")
        {
            host = Some(value.trim().to_owned());
        }
    }
    Some(Head { method, target, host })
}

fn respond(head: &Head, port: u16, served: &Served) -> Response {
    // Only this listener's own name: a page on another origin that rebinds a name to
    // 127.0.0.1 sends its own Host and gets nothing.
    if head.host.as_deref() != Some(format!("127.0.0.1:{port}").as_str()) {
        return text("421 Misdirected Request", "wrong host");
    }
    if head.method != "GET" && head.method != "HEAD" {
        let mut response = text("405 Method Not Allowed", "read-only");
        response.headers.push(("Allow", "GET, HEAD".into()));
        return response;
    }
    let target = head.target.split(['?', '#']).next().unwrap_or_default();
    let Some((token, rest)) = target.strip_prefix('/').and_then(|path| path.split_once('/')) else {
        return text("404 Not Found", "not found");
    };
    let found = match served.lock() {
        Ok(served) => served
            .iter()
            .find(|(served, _, _)| served == token)
            .map(|(_, path, kind)| (path.clone(), *kind)),
        Err(_) => None,
    };
    let Some((path, kind)) = found else { return text("404 Not Found", "not found") };
    match (kind, rest) {
        (Kind::Pptx, "") => page(&path),
        (Kind::Pptx, "deck.pptx") => deck(&path),
        (Kind::Markdown, "") => markdown_page(&path),
        (Kind::Markdown, rest) => asset(&path, rest),
        _ => text("404 Not Found", "not found"),
    }
}

/// The one CDN script a deck page may load: the PowerPoint writer its runtime loads on
/// Export .pptx. A path source matches that file only, so a slide's raw HTML cannot load
/// any other script from the host.
const WRITER_URL: &str = "https://cdn.jsdelivr.net/npm/pptxgenjs@4.0.1/dist/pptxgen.bundle.js";

/// The Markdown deck at `path`, compiled now, under a policy that runs only the deck
/// runtime (and the PowerPoint writer it loads from the CDN on Export .pptx) and reaches
/// only this listener.
fn markdown_page(path: &Path) -> Response {
    let Ok(source) = std::fs::read_to_string(path) else {
        return text("404 Not Found", "the file is gone");
    };
    let name = path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
    let html = md_deck::compile(&source, &name);
    let hash = base64::engine::general_purpose::STANDARD
        .encode(Sha256::digest(md_deck::runtime_script().as_bytes()));
    let policy = format!(
        "default-src 'none'; script-src 'sha256-{hash}' {WRITER_URL}; connect-src 'self'; \
         style-src 'unsafe-inline'; img-src 'self' blob: data:; media-src 'self' blob: data:; \
         font-src data:; base-uri 'none'; form-action 'none'"
    );
    Response {
        status: "200 OK",
        headers: vec![
            ("Content-Type", "text/html; charset=utf-8".into()),
            ("Content-Security-Policy", policy),
            ("Cache-Control", "no-store".into()),
            ("Referrer-Policy", "no-referrer".into()),
            ("X-Content-Type-Options", "nosniff".into()),
        ],
        body: Body::Text(html),
    }
}

/// A file in the Markdown deck's folder (a picture a slide names), never one above it.
fn asset(deck: &Path, relative: &str) -> Response {
    let not_found = || text("404 Not Found", "not found");
    let Some(relative) = percent_decode(relative) else { return not_found() };
    if relative.split('/').any(|part| part.is_empty() || part == "." || part == "..")
        || relative.contains('\\')
    {
        return not_found();
    }
    let Some(folder) = deck.parent().and_then(|folder| folder.canonicalize().ok()) else {
        return not_found();
    };
    let Ok(file_path) = folder.join(&relative).canonicalize() else { return not_found() };
    if !file_path.starts_with(&folder) || !file_path.is_file() {
        return not_found();
    }
    let content_type = match file_path
        .extension()
        .and_then(|extension| extension.to_str())
        .map(str::to_ascii_lowercase)
        .as_deref()
    {
        Some("png") => "image/png",
        Some("jpg" | "jpeg") => "image/jpeg",
        Some("gif") => "image/gif",
        Some("webp") => "image/webp",
        Some("avif") => "image/avif",
        Some("svg") => "image/svg+xml",
        Some("mp4") => "video/mp4",
        Some("webm") => "video/webm",
        // Only pictures and video: a slide's script or page stays unserved.
        _ => return not_found(),
    };
    let file = std::fs::File::open(&file_path);
    let length = file.as_ref().ok().and_then(|file| file.metadata().ok()).map(|meta| meta.len());
    match (file, length) {
        (Ok(file), Some(length)) => Response {
            status: "200 OK",
            headers: vec![
                ("Content-Type", content_type.into()),
                ("Cache-Control", "no-store".into()),
                ("X-Content-Type-Options", "nosniff".into()),
                // An SVG opened on its own runs nothing.
                ("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'".into()),
            ],
            body: Body::File(file, length),
        },
        _ => not_found(),
    }
}

/// `%XX` escapes decoded; `None` for a bad escape or text that is not UTF-8.
fn percent_decode(text: &str) -> Option<String> {
    let mut out = Vec::with_capacity(text.len());
    let mut bytes = text.bytes();
    while let Some(byte) = bytes.next() {
        if byte == b'%' {
            let hex = [bytes.next()?, bytes.next()?];
            out.push(u8::from_str_radix(std::str::from_utf8(&hex).ok()?, 16).ok()?);
        } else {
            out.push(byte);
        }
    }
    String::from_utf8(out).ok()
}

/// The viewer page for `path`, with a policy that lets it run only its own script and
/// the renderer it loaded, and reach only this listener and the CDN.
fn page(path: &Path) -> Response {
    let name = path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
    let html = viewer_html(&name);
    let policy = format!(
        "default-src 'none'; script-src 'sha256-{}' blob:; connect-src 'self' https://cdn.jsdelivr.net; \
         style-src 'unsafe-inline'; img-src 'self' blob: data:; media-src blob: data:; \
         font-src blob: data:; base-uri 'none'; form-action 'none'",
        script_hash(&html)
    );
    Response {
        status: "200 OK",
        headers: vec![
            ("Content-Type", "text/html; charset=utf-8".into()),
            ("Content-Security-Policy", policy),
            ("Cache-Control", "no-store".into()),
            ("Referrer-Policy", "no-referrer".into()),
            ("X-Content-Type-Options", "nosniff".into()),
        ],
        body: Body::Text(html),
    }
}

/// The deck's bytes as they are now; a missing file is a 404, which the page shows as
/// "deleted or moved".
fn deck(path: &Path) -> Response {
    let file = std::fs::File::open(path);
    let length = file.as_ref().ok().and_then(|file| file.metadata().ok()).map(|meta| meta.len());
    match (file, length) {
        (Ok(file), Some(length)) => Response {
            status: "200 OK",
            headers: vec![
                ("Content-Type", DECK_TYPE.into()),
                ("Cache-Control", "no-store".into()),
                ("X-Content-Type-Options", "nosniff".into()),
            ],
            body: Body::File(file, length),
        },
        _ => text("404 Not Found", "the file is gone"),
    }
}

/// The page with the deck's name and the renderer pinned in.
pub(super) fn viewer_html(name: &str) -> String {
    PAGE.replace("{{TITLE}}", &escape(name))
        .replace("{{LIB_URL}}", RENDERER_URL)
        .replace("{{LIB_SRI}}", RENDERER_SRI)
}

/// The base64 SHA-256 of the page's one inline script, for its policy.
pub(super) fn script_hash(html: &str) -> String {
    let script = html
        .split_once("<script type=\"module\">")
        .and_then(|(_, rest)| rest.split_once("</script>"))
        .map(|(script, _)| script)
        .unwrap_or_default();
    base64::engine::general_purpose::STANDARD.encode(Sha256::digest(script.as_bytes()))
}

fn escape(text: &str) -> String {
    let mut escaped = String::with_capacity(text.len());
    for character in text.chars() {
        match character {
            '&' => escaped.push_str("&amp;"),
            '<' => escaped.push_str("&lt;"),
            '>' => escaped.push_str("&gt;"),
            '"' => escaped.push_str("&quot;"),
            '\'' => escaped.push_str("&#39;"),
            other => escaped.push(other),
        }
    }
    escaped
}

fn write_response(
    stream: &mut TcpStream,
    response: Response,
    head_only: bool,
) -> std::io::Result<()> {
    let length = match &response.body {
        Body::Text(text) => text.len() as u64,
        Body::File(_, length) => *length,
    };
    let mut head = format!(
        "HTTP/1.1 {}\r\nContent-Length: {length}\r\nConnection: close\r\n",
        response.status
    );
    for (name, value) in &response.headers {
        head.push_str(name);
        head.push_str(": ");
        head.push_str(value);
        head.push_str("\r\n");
    }
    head.push_str("\r\n");
    stream.write_all(head.as_bytes())?;
    if !head_only {
        match response.body {
            Body::Text(text) => stream.write_all(text.as_bytes())?,
            Body::File(file, length) => {
                std::io::copy(&mut file.take(length), stream)?;
            }
        }
    }
    stream.flush()
}
