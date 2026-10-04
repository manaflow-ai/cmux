//! [`HostRelay`]: the real [`ControlPlane`], one JSON-lines channel to the
//! host that supervises this server.
//!
//! TODO(APP-R1): replace this channel with the app platform's provider
//! channel and its credential relay op (`op:cmux.credential.relay` in the
//! manifest, not defined yet). Until then the shape is:
//!
//! - host -> server: `{"type":"op","id","op","args","origin","idempotency_key"}`
//! - server -> host: `{"type":"result","id","ok","result"|"error"}`
//! - server -> host: `{"type":"event","event":"cloud.machine.watch","data"}`
//!   with `data` = `{"type":"upsert","revision","machine"}` or
//!   `{"type":"removed","revision","id"}`; `{"type":"event","event":"cloud.link.changed",...}`
//! - server -> host: `{"type":"relay.request","id","op","method","path","body","idempotency_key"}`
//! - host -> server: `{"type":"relay.response","id","status","body","error_code"}`
//!   or `{"type":"relay.error","id","code":"not_signed_in"|"unavailable","message"}`
//! - server -> host: `{"type":"relay.session","id"}`; host -> server:
//!   `{"type":"relay.session","id","signed_in","team"}`
//!
//! The host adds the bearer when it sends the HTTP call; no line in either
//! direction carries a credential. The host answers every relay request,
//! with `relay.error` when its own HTTP deadline passes; the server has no
//! timer of its own. Op lines that arrive while a relay call
//! waits are queued and served in order after it.

use super::control_plane::{ControlPlane, HttpCall, HttpReply, RelayError, SessionStatus};
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::io::{BufRead, Write};

pub struct HostRelay<R, W> {
    reader: R,
    writer: W,
    next_id: u64,
    queued: VecDeque<Value>,
}

impl<R: BufRead, W: Write> HostRelay<R, W> {
    pub fn new(reader: R, writer: W) -> Self {
        Self { reader, writer, next_id: 0, queued: VecDeque::new() }
    }

    /// The next host message that is not a relay answer: queued ones first.
    /// `None` at end of input.
    pub fn next_message(&mut self) -> std::io::Result<Option<Value>> {
        if let Some(m) = self.queued.pop_front() {
            return Ok(Some(m));
        }
        self.read_line()
    }

    /// Writes one JSON line to the host.
    pub fn send(&mut self, message: &Value) -> std::io::Result<()> {
        serde_json::to_writer(&mut self.writer, message)?;
        self.writer.write_all(b"\n")?;
        self.writer.flush()
    }

    fn read_line(&mut self) -> std::io::Result<Option<Value>> {
        let mut line = Vec::new();
        loop {
            line.clear();
            if self.reader.read_until(b'\n', &mut line)? == 0 {
                return Ok(None);
            }
            if line.iter().all(u8::is_ascii_whitespace) {
                continue;
            }
            // A line that is not JSON (or not UTF-8) is answered as invalid;
            // it never stops the server.
            return match serde_json::from_slice(&line) {
                Ok(v) => Ok(Some(v)),
                Err(e) => Ok(Some(json!({ "type": "invalid", "error": e.to_string() }))),
            };
        }
    }

    fn exchange(&mut self, mut request: Value) -> Result<Value, RelayError> {
        self.next_id += 1;
        let id = format!("r{}", self.next_id);
        request["id"] = json!(id);
        let kind = request["type"].clone();
        self.send(&request).map_err(|e| RelayError::Unavailable(e.to_string()))?;
        loop {
            let message = self
                .read_line()
                .map_err(|e| RelayError::Unavailable(e.to_string()))?
                .ok_or_else(|| RelayError::Unavailable("the host closed the channel".into()))?;
            let is_answer = message["type"].as_str().is_some_and(|t| t.starts_with("relay."));
            if !is_answer {
                self.queued.push_back(message);
                continue;
            }
            if message["id"] != json!(id) {
                // An answer to no call that is waiting: never apply it to this one.
                continue;
            }
            if message["type"] == "relay.error" {
                return Err(match message["code"].as_str() {
                    Some("not_signed_in") => RelayError::NotSignedIn,
                    _ => RelayError::Unavailable(
                        message["message"].as_str().unwrap_or("relay error").to_owned(),
                    ),
                });
            }
            let expected = if kind == "relay.session" { "relay.session" } else { "relay.response" };
            if message["type"] != expected {
                return Err(RelayError::Unavailable("unexpected relay answer".into()));
            }
            return Ok(message);
        }
    }
}

impl<R: BufRead, W: Write> ControlPlane for HostRelay<R, W> {
    fn call(&mut self, call: &HttpCall) -> Result<HttpReply, RelayError> {
        let mut request = serde_json::to_value(call).expect("HttpCall serializes");
        request["type"] = json!("relay.request");
        let answer = self.exchange(request)?;
        let status = answer["status"]
            .as_u64()
            .and_then(|s| u16::try_from(s).ok())
            .ok_or_else(|| RelayError::Unavailable("relay answer has no status".into()))?;
        Ok(HttpReply {
            status,
            body: answer.get("body").cloned().unwrap_or(Value::Null),
            error_code: answer["error_code"].as_str().map(str::to_owned),
        })
    }

    fn session(&mut self) -> Result<SessionStatus, RelayError> {
        let answer = self.exchange(json!({ "type": "relay.session" }))?;
        Ok(SessionStatus {
            signed_in: answer["signed_in"].as_bool().unwrap_or(false),
            team: answer["team"].as_str().map(str::to_owned),
        })
    }
}
