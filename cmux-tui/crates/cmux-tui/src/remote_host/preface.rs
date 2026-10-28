//! The one-line preface on a remote host connection (remote-hosts.md 7).

use crate::json_fields::JsonFields;
use std::io::{self, Read, Write};
use std::net::TcpStream;
use std::time::Instant;

use serde_json::{Value, json};

pub(crate) const PREFACE_VERSION: u64 = 1;
/// Longest preface or reply line.
pub(crate) const MAX_LINE: usize = 4096;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Op {
    Probe,
    Connect,
}

pub(crate) fn request(op: Op) -> String {
    let op = match op {
        Op::Probe => "probe",
        Op::Connect => "connect",
    };
    format!("{}\n", json!({"cmux_host": PREFACE_VERSION, "op": op}))
}

pub(crate) fn parse_request(line: &str) -> Option<Op> {
    let value: Value = serde_json::from_str(line).ok()?;
    if value.field("cmux_host").as_u64() != Some(PREFACE_VERSION) {
        return None;
    }
    match value.field("op").as_str()? {
        "probe" => Some(Op::Probe),
        "connect" => Some(Op::Connect),
        _ => None,
    }
}

/// Reads one `\n`-terminated line by `deadline` (one bound for the whole
/// line, not per byte: a peer that trickles bytes is cut off), one byte at a
/// time so that nothing after it (the daemon protocol) is consumed. `None`
/// when the peer closed first.
pub(crate) fn read_line(stream: &mut TcpStream, deadline: Instant) -> io::Result<Option<String>> {
    let mut line = Vec::with_capacity(128);
    let mut byte = [0u8; 1];
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return Err(io::Error::new(io::ErrorKind::TimedOut, "preface line timed out"));
        }
        stream.set_read_timeout(Some(left))?;
        match stream.read(&mut byte)? {
            0 => return Ok(None),
            _ if byte[0] == b'\n' => break,
            _ => {
                if line.len() >= MAX_LINE {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "preface line is too long",
                    ));
                }
                line.push(byte[0]);
            }
        }
    }
    String::from_utf8(line)
        .map(Some)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "preface is not UTF-8"))
}

pub(crate) fn write_value(stream: &mut impl Write, value: &Value) -> io::Result<()> {
    let mut line = serde_json::to_vec(value)?;
    line.push(b'\n');
    stream.write_all(&line)?;
    stream.flush()
}

pub(crate) fn refusal(code: &str) -> Value {
    json!({"ok": false, "error_code": code})
}
