//! [`LoopbackTunnel`]: the real [`PortTunnel`]. Each stream is one
//! connection to the link's local socket (the carrier) that speaks
//! `loopback-forward-v1` (cmux-tui/spec/commands.md "Loopback forwarding"):
//! `identify`, `set-client-info {capabilities: ["loopback-forward-v1"]}`,
//! `loopback-open`, then `loopback-data` / `loopback-credit` /
//! `loopback-shutdown` with credit windows both ways.
//!
//! SHORTCUT (flagged): one daemon connection per stream, not one
//! multiplexed connection per machine like the Swift `LoopbackForwardClient`.
//! It costs three round trips per new TCP connection; the daemon's limit of
//! 512 streams still holds.

use super::tunnel::{PortTunnel, TunnelAbort, TunnelConn, TunnelError, TunnelWrite};
use crate::connector::iface::Carrier;
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

pub const CAPABILITY: &str = "loopback-forward-v1";
/// This client's receive window (the spec default).
pub const WINDOW: usize = 256 * 1024;
/// Largest decoded payload of one `loopback-data` line.
const FRAME: usize = 64 * 1024;
/// Bound on each handshake answer.
const HANDSHAKE: Duration = Duration::from_secs(10);
const STREAM: u64 = 1;

pub struct LoopbackTunnel;

struct Credit {
    bytes: usize,
    closed: bool,
}

struct Shared {
    socket: UnixStream,
    /// One writer at a time: data frames (the write half) and credit grants
    /// (the read half) share the socket, and a line must never interleave.
    writing: Mutex<()>,
    credit: Mutex<Credit>,
    ready: Condvar,
}

impl Shared {
    fn send(&self, line: &Value) -> io::Result<()> {
        let mut text = line.to_string();
        text.push('\n');
        let _one = self.writing.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        (&self.socket).write_all(text.as_bytes())
    }

    fn credit(&self) -> std::sync::MutexGuard<'_, Credit> {
        self.credit.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    fn end(&self) {
        self.credit().closed = true;
        self.ready.notify_all();
    }
}

impl TunnelAbort for Shared {
    fn abort(&self) {
        self.end();
        let _ = self.socket.shutdown(std::net::Shutdown::Both);
    }
}

impl PortTunnel for LoopbackTunnel {
    fn open(&self, carrier: &Carrier, host: &str, port: u16) -> Result<TunnelConn, TunnelError> {
        let down = |e: io::Error| TunnelError::Down(e.to_string());
        let socket = UnixStream::connect(&carrier.socket).map_err(down)?;
        socket.set_read_timeout(Some(HANDSHAKE)).map_err(down)?;
        let mut lines = BufReader::new(socket.try_clone().map_err(down)?);
        let shared = Arc::new(Shared {
            socket,
            writing: Mutex::new(()),
            credit: Mutex::new(Credit { bytes: 0, closed: false }),
            ready: Condvar::new(),
        });
        let mut early = VecDeque::new();
        let identity =
            request(&shared, &mut lines, &mut early, json!({"id": 1, "cmd": "identify"}))?;
        let capable = identity["capabilities"]
            .as_array()
            .is_some_and(|caps| caps.iter().any(|c| c == CAPABILITY));
        if !capable {
            return Err(TunnelError::Unsupported(format!(
                "the machine's cmux-tui lacks {CAPABILITY}; update the machine's image"
            )));
        }
        let info = json!({"id": 2, "cmd": "set-client-info", "name": "cmux-cloud port forward",
            "kind": "loopback-forward", "capabilities": [CAPABILITY]});
        request(&shared, &mut lines, &mut early, info)?;
        let open = json!({"id": 3, "cmd": "loopback-open", "stream": STREAM, "host": host,
            "port": port, "window": WINDOW});
        let opened = request(&shared, &mut lines, &mut early, open)?;
        let window = opened["window"].as_u64().and_then(|w| usize::try_from(w).ok()).unwrap_or(0);
        shared.credit().bytes = window;
        shared.socket.set_read_timeout(None).map_err(down)?;
        let reader = Reader {
            lines,
            early,
            buffer: Vec::new(),
            at: 0,
            ungranted: 0,
            eof: false,
            shared: Arc::clone(&shared),
        };
        Ok(TunnelConn {
            reader: Box::new(reader),
            writer: Box::new(Writer { shared: Arc::clone(&shared) }),
            abort: shared,
        })
    }
}

/// Sends one request and waits for its answer; stream events that arrive
/// first are kept in `early` for the reader.
fn request(
    shared: &Shared,
    lines: &mut BufReader<UnixStream>,
    early: &mut VecDeque<Value>,
    line: Value,
) -> Result<Value, TunnelError> {
    let id = line["id"].clone();
    shared.send(&line).map_err(|e| TunnelError::Down(e.to_string()))?;
    loop {
        let message = next_line(lines).map_err(|e| TunnelError::Down(e.to_string()))?;
        if message.get("event").is_some() {
            early.push_back(message);
            continue;
        }
        if message["id"] != id {
            continue;
        }
        if message["ok"] == true {
            return Ok(message["data"].clone());
        }
        let text = message["error"].as_str().unwrap_or("refused").to_owned();
        return Err(TunnelError::Refused {
            code: message["error_code"].as_str().unwrap_or("loopback.error").to_owned(),
            message: text,
        });
    }
}

fn next_line(lines: &mut impl BufRead) -> io::Result<Value> {
    let mut line = Vec::new();
    loop {
        line.clear();
        if lines.read_until(b'\n', &mut line)? == 0 {
            return Err(io::Error::new(io::ErrorKind::ConnectionAborted, "the link closed"));
        }
        if line.iter().all(u8::is_ascii_whitespace) {
            continue;
        }
        return serde_json::from_slice(&line)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e));
    }
}

struct Reader {
    lines: BufReader<UnixStream>,
    early: VecDeque<Value>,
    buffer: Vec<u8>,
    at: usize,
    /// Bytes given to the caller and not yet granted back to the daemon.
    ungranted: usize,
    eof: bool,
    shared: Arc<Shared>,
}

impl Reader {
    /// Applies one event; `Err` ends the stream.
    fn apply(&mut self, event: &Value) -> io::Result<()> {
        if event["stream"] != STREAM {
            return Ok(());
        }
        match event["event"].as_str() {
            Some("loopback-data") => {
                let data = event["data"].as_str().unwrap_or_default();
                let bytes = STANDARD
                    .decode(data)
                    .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
                self.buffer.drain(..self.at);
                self.at = 0;
                self.buffer.extend_from_slice(&bytes);
            }
            Some("loopback-credit") => {
                let bytes = event["bytes"].as_u64().and_then(|b| usize::try_from(b).ok());
                self.shared.credit().bytes += bytes.unwrap_or(0);
                self.shared.ready.notify_all();
            }
            Some("loopback-eof") => self.eof = true,
            Some("loopback-closed") => {
                self.shared.end();
                self.eof = true;
                if let Some(error) = event["error"].as_str() {
                    return Err(io::Error::new(io::ErrorKind::ConnectionReset, error.to_owned()));
                }
            }
            _ => {}
        }
        Ok(())
    }
}

impl Read for Reader {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        loop {
            if self.at < self.buffer.len() {
                let n = out.len().min(self.buffer.len() - self.at);
                out[..n].copy_from_slice(&self.buffer[self.at..self.at + n]);
                self.at += n;
                self.ungranted += n;
                if self.ungranted >= WINDOW / 4 || self.at == self.buffer.len() {
                    let grant = std::mem::take(&mut self.ungranted);
                    let line = json!({"cmd": "loopback-credit", "stream": STREAM, "bytes": grant});
                    self.shared.send(&line)?;
                }
                return Ok(n);
            }
            if self.eof {
                return Ok(0);
            }
            let event = match self.early.pop_front() {
                Some(event) => event,
                None => match next_line(&mut self.lines) {
                    Ok(event) => event,
                    Err(e) => {
                        self.shared.end();
                        return Err(e);
                    }
                },
            };
            self.apply(&event)?;
        }
    }
}

struct Writer {
    shared: Arc<Shared>,
}

impl Write for Writer {
    fn write(&mut self, data: &[u8]) -> io::Result<usize> {
        if data.is_empty() {
            return Ok(0);
        }
        let n = {
            let mut credit = self.shared.credit();
            while credit.bytes == 0 && !credit.closed {
                credit = self.shared.ready.wait(credit).unwrap_or_else(|e| e.into_inner());
            }
            if credit.closed {
                return Err(io::Error::new(io::ErrorKind::BrokenPipe, "the stream ended"));
            }
            let n = data.len().min(credit.bytes).min(FRAME);
            credit.bytes -= n;
            n
        };
        let line =
            json!({"cmd": "loopback-data", "stream": STREAM, "data": STANDARD.encode(&data[..n])});
        self.shared.send(&line)?;
        Ok(n)
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl TunnelWrite for Writer {
    fn shutdown_write(&mut self) -> io::Result<()> {
        self.shared.send(&json!({"cmd": "loopback-shutdown", "stream": STREAM}))
    }
}
