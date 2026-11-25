//! A fake HTTP server on a local port (the cmux-cloud-api tests' shape): each connection's
//! request is recorded and answered by the test's handler.

#![allow(dead_code)]

use std::io::{Read, Write as _};
use std::net::{TcpListener, TcpStream};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;

/// One request the fake saw.
#[derive(Debug, Clone)]
pub struct Seen {
    pub method: String,
    /// Path and query.
    pub target: String,
    /// `name: value` lines, names lower-cased.
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Seen {
    pub fn header(&self, name: &str) -> Option<String> {
        self.headers.iter().find(|(n, _)| n == name).map(|(_, v)| v.clone())
    }
    pub fn text(&self) -> String {
        String::from_utf8_lossy(&self.body).into_owned()
    }
    pub fn json(&self) -> serde_json::Value {
        serde_json::from_slice(&self.body).unwrap_or(serde_json::Value::Null)
    }
    /// The form body's decoded pairs.
    pub fn form(&self) -> Vec<(String, String)> {
        self.text()
            .split('&')
            .filter_map(|pair| pair.split_once('='))
            .map(|(k, v)| (k.to_owned(), decode(v)))
            .collect()
    }
    pub fn form_value(&self, name: &str) -> Option<String> {
        self.form().into_iter().find(|(k, _)| k == name).map(|(_, v)| v)
    }
}

fn decode(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).unwrap();
            out.push(u8::from_str_radix(hex, 16).unwrap());
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).unwrap()
}

/// How the fake answers one request.
pub enum Reply {
    /// Status, extra headers, body (sent as JSON unless a `content-type` header is given).
    Answer(u16, Vec<(&'static str, String)>, String),
    /// Read the request, then never answer (until the test ends).
    Stall,
    /// Close the connection without an answer.
    Drop,
}

pub fn ok(body: serde_json::Value) -> Reply {
    Reply::Answer(200, Vec::new(), body.to_string())
}

pub fn status(code: u16, body: serde_json::Value) -> Reply {
    Reply::Answer(code, Vec::new(), body.to_string())
}

pub type Log = Arc<Mutex<Vec<Seen>>>;

/// Starts the fake; answers its origin and the log of requests.
pub fn serve(handler: impl Fn(&Seen) -> Reply + Send + Sync + 'static) -> (String, Log) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let log: Log = Arc::new(Mutex::new(Vec::new()));
    let seen = Arc::clone(&log);
    let handler = Arc::new(handler);
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(stream) = stream else { continue };
            let handler = Arc::clone(&handler);
            let seen = Arc::clone(&seen);
            std::thread::spawn(move || answer(stream, &*handler, &seen));
        }
    });
    (origin, log)
}

fn answer(mut stream: TcpStream, handler: &dyn Fn(&Seen) -> Reply, log: &Log) {
    let mut buffer = Vec::new();
    let mut chunk = [0_u8; 65536];
    let (head, body) = loop {
        let n = stream.read(&mut chunk).unwrap_or(0);
        buffer.extend_from_slice(&chunk[..n]);
        if let Some(end) = buffer.windows(4).position(|w| w == b"\r\n\r\n") {
            let head = String::from_utf8_lossy(&buffer[..end]).to_string();
            let length = head
                .lines()
                .find_map(|l| {
                    l.to_ascii_lowercase()
                        .strip_prefix("content-length:")
                        .map(|v| v.trim().parse::<usize>().unwrap())
                })
                .unwrap_or(0);
            if buffer.len() >= end + 4 + length || n == 0 {
                break (head, buffer[end + 4..].to_vec());
            }
        } else if n == 0 {
            return;
        }
    };
    let mut lines = head.split("\r\n");
    let request_line = lines.next().unwrap_or_default().to_owned();
    let mut parts = request_line.split(' ');
    let method = parts.next().unwrap_or_default().to_owned();
    let target = parts.next().unwrap_or_default().to_owned();
    let headers = lines
        .filter_map(|l| l.split_once(':'))
        .map(|(n, v)| (n.trim().to_ascii_lowercase(), v.trim().to_owned()))
        .collect();
    let seen = Seen { method, target, headers, body };
    let reply = handler(&seen);
    log.lock().unwrap().push(seen);
    match reply {
        Reply::Answer(status, headers, body) => {
            let mut head = format!(
                "HTTP/1.1 {status} X\r\ncontent-length: {}\r\nconnection: close\r\n",
                body.len()
            );
            if !headers.iter().any(|(n, _)| n.eq_ignore_ascii_case("content-type")) {
                head.push_str("content-type: application/json\r\n");
            }
            for (name, value) in headers {
                head.push_str(&format!("{name}: {value}\r\n"));
            }
            head.push_str("\r\n");
            let _ = stream.write_all(head.as_bytes());
            let _ = stream.write_all(body.as_bytes());
        }
        Reply::Stall => std::thread::sleep(Duration::from_secs(30)),
        Reply::Drop => {}
    }
}

/// A JWT-shaped token (unsigned) that expires `expires_in` seconds from now (negative: expired)
/// after a `lifetime`.
pub fn token(expires_in: i64, lifetime: i64, tag: &str) -> String {
    let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs() as i64;
    let payload = serde_json::json!({ "exp": now + expires_in, "iat": now + expires_in - lifetime, "tag": tag });
    format!(
        "{}.{}.sig",
        URL_SAFE_NO_PAD.encode(br#"{"alg":"none"}"#),
        URL_SAFE_NO_PAD.encode(payload.to_string())
    )
}

/// A port nothing listens on.
pub fn closed_origin() -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    drop(listener);
    origin
}
