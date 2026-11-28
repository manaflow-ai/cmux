//! The guest agent's wire protocol: one request and one response per vsock connection, each a
//! 4-byte big-endian length followed by that many bytes of JSON.
//!
//! The host reaches the agent through Firecracker's vsock bridge: it connects to the VM's
//! `v.sock` Unix socket, writes `CONNECT <GUEST_AGENT_PORT>\n`, reads `OK <n>\n`, then frames.

use std::io::{self, Read, Write};

use serde::{Deserialize, Serialize};

/// The vsock port `cmux-vmd-guest` listens on.
pub const GUEST_AGENT_PORT: u32 = 52;

/// Largest frame either side accepts (files and exec output ride in frames).
pub const MAX_FRAME: usize = 256 * 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum GuestRequest {
    Ping,
    Exec {
        program: String,
        #[serde(default)]
        args: Vec<String>,
        #[serde(default)]
        env: Vec<(String, String)>,
        #[serde(default)]
        cwd: Option<String>,
        /// base64
        #[serde(default)]
        stdin: String,
        /// Kill the process after this many milliseconds; 0 = no limit.
        #[serde(default)]
        timeout_ms: u64,
    },
    ReadFile {
        path: String,
    },
    WriteFile {
        path: String,
        /// base64
        data: String,
        #[serde(default)]
        mode: Option<u32>,
    },
    /// Step the guest's realtime clock to the host's. The host sends it right after a snapshot
    /// restore or a resume: kvmclock stops while the VM is paused or saved, so the guest wakes
    /// with its wall clock in the past, and cmux-host's clock-set wake (`TFD_TIMER_CANCEL_ON_SET`)
    /// is what makes it re-read its identity and bind.
    SetClock {
        /// Host `CLOCK_REALTIME` in nanoseconds since the Unix epoch, read just before sending.
        unix_ns: u64,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "result", rename_all = "snake_case")]
pub enum GuestResponse {
    Pong {
        /// Guest uptime in milliseconds, from /proc/uptime.
        uptime_ms: u64,
    },
    Exec {
        exit_code: i32,
        /// base64
        stdout: String,
        /// base64
        stderr: String,
    },
    File {
        /// base64
        data: String,
    },
    Ok,
    /// The answer to [`GuestRequest::SetClock`]: how far the guest's clock moved (host time
    /// minus the guest's old time, in nanoseconds; positive means the guest was behind).
    Clock {
        stepped_ns: i64,
    },
    Error {
        message: String,
    },
}

/// How far a [`GuestRequest::SetClock`] to `host_ns` moves a guest clock that reads `guest_ns`
/// (both nanoseconds since the Unix epoch), clamped to `i64`.
pub fn clock_step_ns(guest_ns: u64, host_ns: u64) -> i64 {
    let step = i128::from(host_ns) - i128::from(guest_ns);
    i64::try_from(step).unwrap_or(if step < 0 { i64::MIN } else { i64::MAX })
}

pub fn write_frame<W: Write, T: Serialize>(w: &mut W, value: &T) -> io::Result<()> {
    let body = serde_json::to_vec(value).map_err(io::Error::other)?;
    if body.len() > MAX_FRAME {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "frame too large"));
    }
    let len = u32::try_from(body.len()).map_err(io::Error::other)?;
    w.write_all(&len.to_be_bytes())?;
    w.write_all(&body)?;
    w.flush()
}

pub fn read_frame<R: Read, T: for<'de> Deserialize<'de>>(r: &mut R) -> io::Result<T> {
    let mut len = [0u8; 4];
    r.read_exact(&mut len)?;
    let len = u32::from_be_bytes(len) as usize;
    if len > MAX_FRAME {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "frame too large"));
    }
    let mut body = vec![0u8; len];
    r.read_exact(&mut body)?;
    serde_json::from_slice(&body).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
}

#[cfg(test)]
#[path = "proto_tests.rs"]
mod tests;
