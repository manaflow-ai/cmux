//! `--webhook` triggers: a signed HTTP POST on this machine starts the automation.
//!
//! The runner serves every webhook automation on one loopback listener
//! ([`Server`], `127.0.0.1:47392` unless `CMUX_AUTOMATION_WEBHOOK_ADDR` names
//! another address). It binds only while an enabled automation has a webhook
//! trigger, so nothing listens for a person who made none. A delivery is
//! `POST /hooks/<automation id>` and passes four checks, in order:
//!
//! 1. its signature: `X-Cmux-Signature-256` or `X-Hub-Signature-256` is
//!    `sha256=<hex HMAC-SHA256 of the body>` keyed with the automation's own
//!    secret ([`Store::webhook_secret`], a 0600 file beside `automation.json`,
//!    never in it), compared in constant time;
//! 2. its filters ([`WebhookFilter`]): every `--match PATH=VALUE` on the JSON
//!    body and every `--header NAME=VALUE` holds;
//! 3. its delivery id ([`delivery_id`]): one already seen inside the dedupe
//!    window answers `duplicate` and starts nothing. The window survives a
//!    runner restart (`webhook-seen.json`);
//! 4. the automation's guardrails, as for any event ([`crate::start_event`]).
//!
//! The listener thread does the first three and hands the event to the
//! runner's loop through the watches' queue ([`crate::watch::EventSender`]),
//! which wakes it at once. Every read has a bound: a request has 5 s, its head
//! 16 KiB and its body [`MAX_BODY_BYTES`]; at most [`MAX_CONNECTIONS`] are
//! served at a time and the rest get `503`.

use std::collections::HashMap;
use std::fs;
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};

use crate::store::{Store, StoreError, write_atomic};
use crate::sys::create_private_dir;
use crate::trigger::Trigger;
use crate::watch::{EventSender, WatchEvent};

/// Where the listener binds when `CMUX_AUTOMATION_WEBHOOK_ADDR` names nothing.
pub const DEFAULT_ADDR: &str = "127.0.0.1:47392";
/// The environment variable that moves the listener.
pub const ADDR_ENV: &str = "CMUX_AUTOMATION_WEBHOOK_ADDR";
/// The path prefix of a delivery: `/hooks/<automation id>`.
pub const PATH_PREFIX: &str = "/hooks/";
/// How long a delivery id is remembered when `--dedupe` names no window.
pub const DEFAULT_DEDUPE_SECONDS: u64 = 3_600;
/// The longest dedupe window.
pub const MAX_DEDUPE_SECONDS: u64 = 7 * 86_400;
/// The largest body a delivery may carry.
pub const MAX_BODY_BYTES: usize = 1024 * 1024;
/// Connections served at once; more get `503`.
pub const MAX_CONNECTIONS: usize = 16;
/// The most filters one trigger keeps.
pub const MAX_FILTERS: usize = 32;
/// The header a sender signs with (GitHub's `X-Hub-Signature-256` works too).
pub const SIGNATURE_HEADER: &str = "x-cmux-signature-256";
/// Signature headers, in the order they are read.
pub const SIGNATURE_HEADERS: &[&str] = &[SIGNATURE_HEADER, "x-hub-signature-256"];
/// Delivery id headers, in the order they are read; with none, the body's
/// SHA-256 is the id, so the same body twice is one delivery.
pub const DELIVERY_HEADERS: &[&str] =
    &["x-cmux-delivery", "x-github-delivery", "webhook-id", "x-delivery-id", "idempotency-key"];
/// Event name headers the event line carries.
const EVENT_HEADERS: &[&str] = &["x-cmux-event", "x-github-event", "x-gitlab-event"];
/// Most delivery ids remembered per automation; the oldest go first.
const MAX_SEEN: usize = 4_096;
const MAX_HEAD_BYTES: usize = 16 * 1024;
const MAX_HEADERS: usize = 100;
const IO_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_DELIVERY_ID: usize = 200;
const SECRET_FILE: &str = "webhook.secret";
const SEEN_FILE: &str = "webhook-seen.json";
const LISTENER_FILE: &str = ".webhook.json";

/// One condition a delivery must meet.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum WebhookFilter {
    /// The JSON body's value at `path` (dot separated; a number indexes an
    /// array) equals `value`: a string as it is, anything else as JSON text
    /// (`true`, `3`). `*` only asks that the path exists.
    Json { path: String, value: String },
    /// The header `name` (any case) equals `value`.
    Header { name: String, value: String },
}

impl WebhookFilter {
    /// `--match PATH=VALUE`.
    pub fn parse_json(text: &str) -> Result<WebhookFilter, String> {
        let (path, value) = split_pair(text, "--match", "PATH=VALUE")?;
        if path.split('.').any(str::is_empty) {
            return Err(format!(
                "--match {text:?}: a path is keys joined by dots, like action or pull_request.base.ref"
            ));
        }
        Ok(WebhookFilter::Json { path, value })
    }

    /// `--header NAME=VALUE`.
    pub fn parse_header(text: &str) -> Result<WebhookFilter, String> {
        let (name, value) = split_pair(text, "--header", "NAME=VALUE")?;
        if !name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_') {
            return Err(format!("--header {text:?}: {name:?} is not a header name"));
        }
        Ok(WebhookFilter::Header { name: name.to_ascii_lowercase(), value })
    }

    /// The words a person wrote: `--match action=opened`.
    pub fn describe(&self) -> String {
        match self {
            WebhookFilter::Json { path, value } => format!("--match {path}={value}"),
            WebhookFilter::Header { name, value } => format!("--header {name}={value}"),
        }
    }

    fn holds(&self, headers: &Headers, body: Option<&Value>) -> bool {
        match self {
            WebhookFilter::Header { name, value } => headers.get(name) == Some(value.as_str()),
            WebhookFilter::Json { path, value } => {
                let Some(found) = body.and_then(|b| json_at(b, path)) else { return false };
                value == "*"
                    || match found {
                        Value::String(s) => s == value,
                        other => serde_json::from_str::<Value>(value).is_ok_and(|v| v == *other),
                    }
            }
        }
    }
}

fn split_pair(text: &str, flag: &str, form: &str) -> Result<(String, String), String> {
    match text.split_once('=') {
        Some((k, v)) if !k.trim().is_empty() => Ok((k.trim().to_string(), v.to_string())),
        _ => Err(format!("{flag} takes {form}, not {text:?}")),
    }
}

/// The value at a dot path.
pub fn json_at<'a>(body: &'a Value, path: &str) -> Option<&'a Value> {
    path.split('.').try_fold(body, |v, key| match v {
        Value::Object(map) => map.get(key),
        Value::Array(items) => key.parse::<usize>().ok().and_then(|i| items.get(i)),
        _ => None,
    })
}

/// Whether a trigger's filters and window can be kept.
pub fn validate(filters: &[WebhookFilter], dedupe_seconds: u64) -> Result<(), String> {
    if filters.len() > MAX_FILTERS {
        return Err(format!("a webhook keeps at most {MAX_FILTERS} filters"));
    }
    if dedupe_seconds > MAX_DEDUPE_SECONDS {
        return Err(format!(
            "--dedupe is at most {} days (a delivery id is remembered no longer)",
            MAX_DEDUPE_SECONDS / 86_400
        ));
    }
    Ok(())
}

/// A request's headers, names lowercased.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Headers(Vec<(String, String)>);

impl Headers {
    pub fn new(pairs: impl IntoIterator<Item = (String, String)>) -> Headers {
        Headers(pairs.into_iter().map(|(k, v)| (k.to_ascii_lowercase(), v)).collect())
    }

    /// The first value of `name` (lowercase).
    pub fn get(&self, name: &str) -> Option<&str> {
        self.0.iter().find(|(k, _)| k == name).map(|(_, v)| v.as_str())
    }
}

type HmacSha256 = Hmac<Sha256>;

/// `sha256=<hex>`: the signature a sender puts in [`SIGNATURE_HEADER`].
pub fn sign(secret: &str, body: &[u8]) -> String {
    let mut mac = match HmacSha256::new_from_slice(secret.as_bytes()) {
        Ok(mac) => mac,
        // HMAC takes a key of any length.
        Err(_) => return String::new(),
    };
    mac.update(body);
    format!("sha256={}", hex(&mac.finalize().into_bytes()))
}

/// Whether a signature header carries the body's HMAC under `secret`
/// (`sha256=<hex>` or the bare hex), checked in constant time.
pub fn verify(secret: &str, body: &[u8], headers: &Headers) -> bool {
    let Some(given) = SIGNATURE_HEADERS.iter().find_map(|h| headers.get(h)) else {
        return false;
    };
    let given = given.trim();
    let given = given.strip_prefix("sha256=").unwrap_or(given);
    let Some(bytes) = unhex(given) else { return false };
    let Ok(mut mac) = HmacSha256::new_from_slice(secret.as_bytes()) else { return false };
    mac.update(body);
    mac.verify_slice(&bytes).is_ok()
}

/// The delivery's id: the first [`DELIVERY_HEADERS`] value, else
/// `sha256:<hex>` of the body.
pub fn delivery_id(headers: &Headers, body: &[u8]) -> String {
    DELIVERY_HEADERS
        .iter()
        .filter_map(|h| headers.get(h))
        .map(str::trim)
        .find(|v| !v.is_empty())
        .map(|v| v.chars().take(MAX_DELIVERY_ID).collect())
        .unwrap_or_else(|| format!("sha256:{}", hex(&Sha256::digest(body))))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn unhex(text: &str) -> Option<Vec<u8>> {
    if !text.len().is_multiple_of(2) {
        return None;
    }
    (0..text.len()).step_by(2).map(|i| u8::from_str_radix(text.get(i..i + 2)?, 16).ok()).collect()
}

/// A new secret: 32 random bytes as hex.
pub fn new_secret() -> std::io::Result<String> {
    let mut bytes = [0u8; 32];
    fs::File::open("/dev/urandom")?.read_exact(&mut bytes)?;
    Ok(hex(&bytes))
}

/// Where the runner's listener is, as it wrote it when it bound.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ListenerInfo {
    pub addr: String,
    pub pid: u32,
    pub since: i64,
}

/// The address the listener binds: [`ADDR_ENV`], else [`DEFAULT_ADDR`].
pub fn configured_addr() -> String {
    std::env::var(ADDR_ENV).ok().filter(|v| !v.trim().is_empty()).unwrap_or(DEFAULT_ADDR.into())
}

/// `http://ADDR/hooks/ID`.
pub fn url(addr: &str, automation: &str) -> String {
    format!("http://{addr}{PATH_PREFIX}{automation}")
}

impl Store {
    /// The automation's webhook secret; made the first time it is asked for
    /// (a teleported automation gets a new one where it lands).
    pub fn webhook_secret(&self, id: &str) -> Result<String, StoreError> {
        let path = self.dir_of(id).join(SECRET_FILE);
        match fs::read_to_string(&path) {
            Ok(s) if !s.trim().is_empty() => Ok(s.trim().to_string()),
            Ok(_) => self.rotate_webhook_secret(id),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => self.rotate_webhook_secret(id),
            Err(e) => Err(e.into()),
        }
    }

    /// A new webhook secret for the automation; the old one stops working.
    pub fn rotate_webhook_secret(&self, id: &str) -> Result<String, StoreError> {
        self.get(id)?;
        create_private_dir(&self.dir_of(id))?;
        let secret = new_secret()?;
        write_atomic(&self.dir_of(id).join(SECRET_FILE), secret.as_bytes())?;
        Ok(secret)
    }

    fn webhook_seen(&self, id: &str) -> Vec<(String, i64)> {
        fs::read(self.dir_of(id).join(SEEN_FILE))
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default()
    }

    fn put_webhook_seen(&self, id: &str, seen: &[(String, i64)]) -> Result<(), StoreError> {
        let json = serde_json::to_vec(seen).map_err(|e| StoreError::Io(e.to_string()))?;
        Ok(write_atomic(&self.dir_of(id).join(SEEN_FILE), &json)?)
    }

    /// Where the runner's listener is, if one bound.
    pub fn webhook_listener(&self) -> Option<ListenerInfo> {
        fs::read(self.root().join(LISTENER_FILE)).ok().and_then(|b| serde_json::from_slice(&b).ok())
    }

    fn put_webhook_listener(&self, info: &ListenerInfo) -> Result<(), StoreError> {
        let json = serde_json::to_vec(info).map_err(|e| StoreError::Io(e.to_string()))?;
        Ok(write_atomic(&self.root().join(LISTENER_FILE), &json)?)
    }
}

/// Delivery ids seen per automation, inside their windows.
#[derive(Default)]
pub struct Dedupe {
    loaded: HashMap<String, Vec<(String, i64)>>,
}

impl Dedupe {
    /// Record `delivery` at `now_ms` unless it was seen in the last
    /// `window_ms`; `false` for a duplicate. Persisted in the store.
    pub fn first_seen(
        &mut self,
        store: &Store,
        automation: &str,
        delivery: &str,
        window_ms: i64,
        now_ms: i64,
    ) -> bool {
        let seen = self
            .loaded
            .entry(automation.to_string())
            .or_insert_with(|| store.webhook_seen(automation));
        seen.retain(|(_, at)| now_ms.saturating_sub(*at) < window_ms);
        if seen.iter().any(|(id, _)| id == delivery) {
            return false;
        }
        if window_ms > 0 {
            seen.push((delivery.to_string(), now_ms));
            if seen.len() > MAX_SEEN {
                let extra = seen.len() - MAX_SEEN;
                seen.drain(..extra);
            }
            let _ = store.put_webhook_seen(automation, seen);
        }
        true
    }

    /// Forget `delivery` (its event could not be queued, so a retry may run).
    pub fn forget(&mut self, store: &Store, automation: &str, delivery: &str) {
        if let Some(seen) = self.loaded.get_mut(automation) {
            seen.retain(|(id, _)| id != delivery);
            let _ = store.put_webhook_seen(automation, seen);
        }
    }
}

/// One parsed request.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Request {
    pub method: String,
    pub path: String,
    pub headers: Headers,
    pub body: Vec<u8>,
}

/// What the listener answers.
#[derive(Clone, Debug, PartialEq)]
pub struct Response {
    pub status: u16,
    pub body: Value,
}

impl Response {
    fn new(status: u16, body: Value) -> Response {
        Response { status, body }
    }

    /// The `status` field of the body (`accepted`, `ignored`, `duplicate`, …).
    pub fn outcome(&self) -> &str {
        self.body.get("status").and_then(Value::as_str).unwrap_or("")
    }
}

/// Everything one delivery needs; shared by the listener's threads.
pub struct Handler {
    store: Store,
    dedupe: Mutex<Dedupe>,
    sink: EventSender,
}

impl Handler {
    pub fn new(store: Store, sink: EventSender) -> Handler {
        Handler { store, dedupe: Mutex::new(Dedupe::default()), sink }
    }

    /// Answer one request at `now_ms`; an accepted delivery goes to the sink.
    pub fn handle(&self, req: &Request, now_ms: i64) -> Response {
        let path = req.path.split('?').next().unwrap_or_default();
        if path == "/health" && req.method == "GET" {
            return Response::new(200, json!({"status": "ok"}));
        }
        let Some(id) =
            path.strip_prefix(PATH_PREFIX).filter(|id| crate::store::is_automation_id(id))
        else {
            return not_found();
        };
        if req.method != "POST" {
            return Response::new(405, json!({"status": "error", "error": "POST a delivery"}));
        }
        // An unknown id and an automation with no webhook answer the same.
        let Ok(a) = self.store.get(id) else { return not_found() };
        let Trigger::Webhook { filters, dedupe_seconds } = &a.trigger else {
            return not_found();
        };
        let Ok(secret) = self.store.webhook_secret(&a.id) else {
            return Response::new(500, json!({"status": "error", "error": "no secret"}));
        };
        if !verify(&secret, &req.body, &req.headers) {
            return Response::new(
                401,
                json!({"status": "error", "error": "bad or missing signature (X-Cmux-Signature-256: sha256=HMAC)"}),
            );
        }
        let body: Option<Value> = serde_json::from_slice(&req.body).ok();
        if let Some(f) = filters.iter().find(|f| !f.holds(&req.headers, body.as_ref())) {
            return Response::new(
                200,
                json!({"status": "ignored", "reason": format!("filter {}", f.describe())}),
            );
        }
        let delivery = delivery_id(&req.headers, &req.body);
        let window_ms = (*dedupe_seconds as i64).saturating_mul(1000);
        let mut dedupe = match self.dedupe.lock() {
            Ok(d) => d,
            Err(poisoned) => poisoned.into_inner(),
        };
        if !dedupe.first_seen(&self.store, &a.id, &delivery, window_ms, now_ms) {
            return Response::new(200, json!({"status": "duplicate", "delivery": delivery}));
        }
        let event = WatchEvent {
            automation: a.id.clone(),
            text: event_text(&delivery, &req.headers, &req.body, body),
            key: format!("webhook:{delivery}:{now_ms}"),
        };
        if !self.sink.send(event) {
            dedupe.forget(&self.store, &a.id, &delivery);
            return Response::new(
                503,
                json!({"status": "error", "error": "the runner is busy; retry"}),
            );
        }
        Response::new(202, json!({"status": "accepted", "delivery": delivery}))
    }
}

fn not_found() -> Response {
    Response::new(404, json!({"status": "error", "error": "no webhook automation here"}))
}

/// The event a run sees (one JSON line): the delivery id, its event name and
/// content type, and the body (JSON as JSON, else text).
pub fn event_text(delivery: &str, headers: &Headers, raw: &[u8], body: Option<Value>) -> String {
    let event = EVENT_HEADERS.iter().find_map(|h| headers.get(h));
    let body = body.unwrap_or_else(|| Value::String(String::from_utf8_lossy(raw).into_owned()));
    json!({
        "source": "webhook",
        "delivery": delivery,
        "event": event,
        "content_type": headers.get("content-type"),
        "body": body,
    })
    .to_string()
}

/// Why a request could not be read.
#[derive(Debug, PartialEq, Eq)]
pub enum ReadError {
    /// Answer with this status and message.
    Reply(u16, &'static str),
    /// The connection went away or timed out: answer nothing.
    Gone,
}

/// Read one HTTP/1.x request, every part bounded.
pub fn read_request(stream: &mut impl Read) -> Result<Request, ReadError> {
    let mut buf = Vec::with_capacity(1024);
    let mut chunk = [0u8; 4096];
    let head_end = loop {
        if let Some(i) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            break i;
        }
        if buf.len() > MAX_HEAD_BYTES {
            return Err(ReadError::Reply(431, "the request head is too large"));
        }
        match stream.read(&mut chunk) {
            Ok(0) | Err(_) => return Err(ReadError::Gone),
            Ok(n) => buf.extend_from_slice(chunk.get(..n).unwrap_or_default()),
        }
    };
    let head = std::str::from_utf8(buf.get(..head_end).unwrap_or_default())
        .map_err(|_| ReadError::Reply(400, "the request head is not UTF-8"))?
        .to_string();
    let mut lines = head.split("\r\n");
    let mut first = lines.next().unwrap_or_default().split(' ');
    let (Some(method), Some(path), Some(version)) = (first.next(), first.next(), first.next())
    else {
        return Err(ReadError::Reply(400, "a bad request line"));
    };
    if !version.starts_with("HTTP/1.") {
        return Err(ReadError::Reply(505, "HTTP/1.1 only"));
    }
    let mut pairs = Vec::new();
    for line in lines {
        if pairs.len() >= MAX_HEADERS {
            return Err(ReadError::Reply(431, "too many headers"));
        }
        let (k, v) = line.split_once(':').ok_or(ReadError::Reply(400, "a bad header line"))?;
        pairs.push((k.trim().to_string(), v.trim().to_string()));
    }
    let headers = Headers::new(pairs);
    if headers.get("transfer-encoding").is_some() {
        return Err(ReadError::Reply(411, "send the body with Content-Length"));
    }
    let length = match headers.get("content-length") {
        Some(v) => v.parse::<usize>().map_err(|_| ReadError::Reply(400, "a bad Content-Length"))?,
        None => 0,
    };
    if length > MAX_BODY_BYTES {
        return Err(ReadError::Reply(413, "the body is larger than 1 MiB"));
    }
    let mut body = buf.split_off(head_end + 4);
    if body.len() > length {
        body.truncate(length);
    }
    while body.len() < length {
        let want = (length - body.len()).min(chunk.len());
        let Some(window) = chunk.get_mut(..want) else { return Err(ReadError::Gone) };
        match stream.read(window) {
            Ok(0) | Err(_) => return Err(ReadError::Gone),
            Ok(n) => body.extend_from_slice(chunk.get(..n).unwrap_or_default()),
        }
    }
    Ok(Request { method: method.to_string(), path: path.to_string(), headers, body })
}

fn reason(status: u16) -> &'static str {
    match status {
        200 => "OK",
        202 => "Accepted",
        400 => "Bad Request",
        401 => "Unauthorized",
        404 => "Not Found",
        405 => "Method Not Allowed",
        411 => "Length Required",
        413 => "Payload Too Large",
        431 => "Request Header Fields Too Large",
        503 => "Service Unavailable",
        505 => "HTTP Version Not Supported",
        _ => "Error",
    }
}

fn write_response(stream: &mut impl Write, r: &Response) {
    let body = r.body.to_string();
    let _ = write!(
        stream,
        "HTTP/1.1 {} {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        r.status,
        reason(r.status),
        body.len()
    );
    let _ = stream.flush();
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// The runner's webhook listener.
pub struct Server {
    addr: SocketAddr,
    stop: Arc<AtomicBool>,
}

impl Server {
    /// Bind `addr` and serve deliveries on a thread; the bound address is
    /// written to the store for `cmux automation webhook show`.
    pub fn start(store: Store, addr: &str, sink: EventSender) -> std::io::Result<Server> {
        let listener = TcpListener::bind(addr)?;
        let bound = listener.local_addr()?;
        let _ = store.put_webhook_listener(&ListenerInfo {
            addr: bound.to_string(),
            pid: std::process::id(),
            since: now_ms() / 1000,
        });
        let handler = Arc::new(Handler::new(store, sink));
        let stop = Arc::new(AtomicBool::new(false));
        let stopping = stop.clone();
        let live = Arc::new(AtomicUsize::new(0));
        std::thread::Builder::new().name("automation-webhooks".into()).spawn(move || {
            for conn in listener.incoming() {
                if stopping.load(Ordering::Relaxed) {
                    break;
                }
                let Ok(mut stream) = conn else { continue };
                if live.load(Ordering::Relaxed) >= MAX_CONNECTIONS {
                    let _ = stream.set_write_timeout(Some(IO_TIMEOUT));
                    write_response(
                        &mut stream,
                        &Response::new(503, json!({"status": "error", "error": "busy; retry"})),
                    );
                    continue;
                }
                live.fetch_add(1, Ordering::Relaxed);
                let handler = handler.clone();
                let done = live.clone();
                let spawned = std::thread::Builder::new().name("automation-webhook".into()).spawn(
                    move || {
                        serve_one(&handler, &mut stream);
                        done.fetch_sub(1, Ordering::Relaxed);
                    },
                );
                if spawned.is_err() {
                    live.fetch_sub(1, Ordering::Relaxed);
                }
            }
        })?;
        Ok(Server { addr: bound, stop })
    }

    /// The address it listens on.
    pub fn addr(&self) -> SocketAddr {
        self.addr
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        // Wake the accept loop so it sees the stop.
        let _ = TcpStream::connect_timeout(&self.addr, Duration::from_millis(200));
    }
}

fn serve_one(handler: &Handler, stream: &mut TcpStream) {
    let _ = stream.set_read_timeout(Some(IO_TIMEOUT));
    let _ = stream.set_write_timeout(Some(IO_TIMEOUT));
    let response = match read_request(stream) {
        Ok(req) => handler.handle(&req, now_ms()),
        Err(ReadError::Reply(status, why)) => {
            Response::new(status, json!({"status": "error", "error": why}))
        }
        Err(ReadError::Gone) => return,
    };
    write_response(stream, &response);
}

/// Whether any enabled automation here has a webhook trigger.
pub fn wanted(automations: &[crate::automation::Automation]) -> bool {
    automations
        .iter()
        .any(|a| a.enabled && !a.fenced() && matches!(a.trigger, Trigger::Webhook { .. }))
}

/// Post `body` to a listener at `addr`, signed with `secret`: what
/// `cmux automation webhook send` does. The answer's status and body.
pub fn send(
    addr: &str,
    automation: &str,
    secret: &str,
    body: &[u8],
    extra_headers: &[(String, String)],
) -> std::io::Result<(u16, Value)> {
    let target: SocketAddr = addr
        .parse()
        .map_err(|_| std::io::Error::new(std::io::ErrorKind::InvalidInput, "a bad address"))?;
    let mut stream = TcpStream::connect_timeout(&target, IO_TIMEOUT)?;
    stream.set_read_timeout(Some(IO_TIMEOUT))?;
    stream.set_write_timeout(Some(IO_TIMEOUT))?;
    let mut head = format!(
        "POST {PATH_PREFIX}{automation} HTTP/1.1\r\nHost: {addr}\r\nContent-Type: application/json\r\nContent-Length: {}\r\n{}: {}\r\nConnection: close\r\n",
        body.len(),
        SIGNATURE_HEADER,
        sign(secret, body)
    );
    for (k, v) in extra_headers {
        head.push_str(&format!("{k}: {v}\r\n"));
    }
    head.push_str("\r\n");
    stream.write_all(head.as_bytes())?;
    stream.write_all(body)?;
    let mut answer = Vec::new();
    stream.take(64 * 1024).read_to_end(&mut answer)?;
    let text = String::from_utf8_lossy(&answer);
    let status = text
        .split(' ')
        .nth(1)
        .and_then(|s| s.parse::<u16>().ok())
        .ok_or_else(|| std::io::Error::other("no HTTP answer"))?;
    let json = text
        .split_once("\r\n\r\n")
        .and_then(|(_, b)| serde_json::from_str(b).ok())
        .unwrap_or(Value::Null);
    Ok((status, json))
}

#[cfg(test)]
#[path = "webhook_tests.rs"]
mod tests;
