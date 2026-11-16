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

use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use base64::Engine as _;
use sha2::{Digest, Sha256};

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

type Served = Arc<Mutex<VecDeque<(String, PathBuf)>>>;

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
    pub(super) fn url(&self, path: &Path) -> Result<String, String> {
        // One token per file however it is named (macOS: /tmp is /private/tmp).
        let path = &path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
        let mut served = self.served.lock().map_err(|_| "deck viewer lock".to_owned())?;
        let known = served.iter().position(|(_, served)| served == path);
        let token = match known.and_then(|at| served.remove(at)) {
            Some((token, path)) => {
                served.push_back((token.clone(), path));
                token
            }
            None => {
                let mut bytes = [0u8; 16];
                getrandom::fill(&mut bytes).map_err(|error| error.to_string())?;
                let token: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
                served.push_back((token.clone(), path.to_path_buf()));
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
    let path = match served.lock() {
        Ok(served) => {
            served.iter().find(|(served, _)| served == token).map(|(_, path)| path.clone())
        }
        Err(_) => None,
    };
    let Some(path) = path else { return text("404 Not Found", "not found") };
    match rest {
        "" => page(&path),
        "deck.pptx" => deck(&path),
        _ => text("404 Not Found", "not found"),
    }
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
