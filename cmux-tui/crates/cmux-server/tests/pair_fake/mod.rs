//! A local stand-in for the API Worker's pairing routes: `POST
//! /v1/pair/begin` checks the proof of possession like the backend
//! (RFC 7638 thumbprint, ES256 raw r||s over `beginProofMessage`), and `GET
//! /v1/pair/wait` (WebSocket) follows a script.

#![allow(dead_code)]

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use ring::signature::{ECDSA_P256_SHA256_FIXED, UnparsedPublicKey};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tungstenite::Message;
use tungstenite::handshake::server::{Request, Response};
use tungstenite::protocol::CloseFrame;
use tungstenite::protocol::frame::coding::CloseCode;

pub const CODE: &str = "7KQ4M2XD";
pub const SECRET: &str =
    "AAAAAAAAAAAAAAAAAAAAAA.00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff";

/// What the wait socket does after `{t:"pending"}`.
#[derive(Clone, Copy, Debug)]
pub enum Script {
    /// `{t:"paired", host, team, user, install}`, close 1000.
    Paired,
    /// `{t:"refused"}`, close 4403.
    Refused,
    /// Close 4403 with no frame.
    CloseRefused,
    /// Close 4408 (expired).
    Expired,
    /// Nothing more until the client goes away.
    Hold,
}

#[derive(Clone, Debug)]
pub struct WaitSeen {
    pub uri: String,
    pub protocols: String,
}

pub struct FakeApi {
    pub base: String,
    pub begins: Arc<Mutex<Vec<Value>>>,
    pub waits: Arc<Mutex<Vec<WaitSeen>>>,
    pub refused_proofs: Arc<Mutex<usize>>,
}

pub fn thumbprint(x: &str, y: &str) -> String {
    let canonical = format!(r#"{{"crv":"P-256","kty":"EC","x":"{x}","y":"{y}"}}"#);
    URL_SAFE_NO_PAD.encode(Sha256::digest(canonical.as_bytes()))
}

/// Verifies a begin body like the backend's `handlePairBegin`.
pub fn proof_ok(body: &Value, environment: &str) -> bool {
    let s = |v: &Value| v.as_str().unwrap_or_default().to_owned();
    let jwk = &body["public_jwk"];
    if s(&jwk["kty"]) != "EC" || s(&jwk["crv"]) != "P-256" {
        return false;
    }
    let (x, y) = (s(&jwk["x"]), s(&jwk["y"]));
    let (Ok(xb), Ok(yb)) = (URL_SAFE_NO_PAD.decode(&x), URL_SAFE_NO_PAD.decode(&y)) else {
        return false;
    };
    let mut point = vec![4u8];
    point.extend_from_slice(&xb);
    point.extend_from_slice(&yb);
    let message = format!(
        "cmux-pair-begin\n{environment}\n{}\n{}\n{}",
        thumbprint(&x, &y),
        s(&body["wg_public_key"]),
        body["issued_at"].as_u64().unwrap_or_default()
    );
    let Ok(sig) = URL_SAFE_NO_PAD.decode(s(&body["signature"])) else { return false };
    sig.len() == 64
        && UnparsedPublicKey::new(&ECDSA_P256_SHA256_FIXED, &point)
            .verify(message.as_bytes(), &sig)
            .is_ok()
}

impl FakeApi {
    pub fn start(environment: &str, script: Script) -> FakeApi {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let api = FakeApi {
            base,
            begins: Arc::default(),
            waits: Arc::default(),
            refused_proofs: Arc::default(),
        };
        let (begins, waits, refused) =
            (api.begins.clone(), api.waits.clone(), api.refused_proofs.clone());
        let environment = environment.to_owned();
        thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(stream) = stream else { continue };
                let (begins, waits, refused, environment) =
                    (begins.clone(), waits.clone(), refused.clone(), environment.clone());
                thread::spawn(move || {
                    let mut head = [0u8; 64];
                    let n = stream.peek(&mut head).unwrap_or(0);
                    if head[..n].starts_with(b"GET ") {
                        serve_wait(stream, script, &waits);
                    } else {
                        serve_begin(stream, &environment, &begins, &refused);
                    }
                });
            }
        });
        api
    }

    pub fn begin_count(&self) -> usize {
        self.begins.lock().unwrap().len()
    }
}

fn serve_begin(
    stream: TcpStream,
    environment: &str,
    begins: &Mutex<Vec<Value>>,
    refused: &Mutex<usize>,
) {
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut length = 0usize;
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    let path_ok = line.starts_with("POST /v1/pair/begin ");
    loop {
        line.clear();
        reader.read_line(&mut line).unwrap();
        if line == "\r\n" || line.is_empty() {
            break;
        }
        if let Some((name, value)) = line.split_once(':')
            && name.eq_ignore_ascii_case("content-length")
        {
            length = value.trim().parse().unwrap();
        }
    }
    let mut body = vec![0u8; length];
    reader.read_exact(&mut body).unwrap();
    let body: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);
    let (status, reply) = if !path_ok {
        (404, json!({"error": "not found"}))
    } else if !proof_ok(&body, environment) {
        *refused.lock().unwrap() += 1;
        (403, json!({"error": "proof of possession failed"}))
    } else {
        let jwk = &body["public_jwk"];
        let thumb = thumbprint(jwk["x"].as_str().unwrap(), jwk["y"].as_str().unwrap());
        let now = body["issued_at"].as_u64().unwrap();
        begins.lock().unwrap().push(body);
        (
            200,
            json!({
                "code": CODE, "display": "7KQ4-M2XD", "expires_at": now + 600_000,
                "collect_secret": SECRET, "thumbprint": thumb,
                "verification_uri": format!("http://localhost/pair?c={CODE}"),
            }),
        )
    };
    let text = reply.to_string();
    let mut stream = stream;
    let _ = write!(
        stream,
        "HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{text}",
        text.len()
    );
}

// tungstenite's handshake callback returns its own large error type.
#[allow(clippy::result_large_err)]
fn serve_wait(stream: TcpStream, script: Script, waits: &Mutex<Vec<WaitSeen>>) {
    let mut seen = None;
    let callback = |req: &Request, mut resp: Response| {
        let protocols = req
            .headers()
            .get("Sec-WebSocket-Protocol")
            .and_then(|v| v.to_str().ok())
            .unwrap_or_default()
            .to_owned();
        seen = Some(WaitSeen { uri: req.uri().to_string(), protocols });
        resp.headers_mut().insert("Sec-WebSocket-Protocol", "cmux.pair.v1".parse().unwrap());
        Ok(resp)
    };
    let Ok(mut ws) = tungstenite::accept_hdr(stream, callback) else { return };
    waits.lock().unwrap().push(seen.take().unwrap());
    let _ = ws.send(Message::text(json!({"t": "pending", "expires_at": 1}).to_string()));
    let close = |code: u16, reason: &str| {
        Some(CloseFrame { code: CloseCode::from(code), reason: reason.to_owned().into() })
    };
    match script {
        Script::Paired => {
            let result = json!({"t": "paired", "host": "host_1", "team": "team_1", "user": "user_1", "install": "inst_1"});
            let _ = ws.send(Message::text(result.to_string()));
            let _ = ws.close(close(1000, "paired"));
        }
        Script::Refused => {
            let _ = ws.send(Message::text(json!({"t": "refused"}).to_string()));
            let _ = ws.close(close(4403, "refused"));
        }
        Script::CloseRefused => {
            let _ = ws.close(close(4403, "refused"));
        }
        Script::Expired => {
            let _ = ws.close(close(4408, "expired"));
        }
        Script::Hold => {
            ws.get_ref().set_read_timeout(Some(Duration::from_secs(30))).unwrap();
            while ws.read().is_ok() {}
            return;
        }
    }
    // Drain until the client closes.
    while ws.read().is_ok() {}
}
