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
    Error {
        message: String,
    },
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
mod tests {
    use super::*;

    #[test]
    fn frame_round_trip() {
        let req = GuestRequest::Exec {
            program: "echo".into(),
            args: vec!["hi".into()],
            env: vec![("A".into(), "b".into())],
            cwd: None,
            stdin: String::new(),
            timeout_ms: 0,
        };
        let mut buf = Vec::new();
        write_frame(&mut buf, &req).unwrap();
        let back: GuestRequest = read_frame(&mut buf.as_slice()).unwrap();
        assert_eq!(back, req);
    }

    #[test]
    fn oversize_length_is_refused() {
        let mut buf = (u32::MAX).to_be_bytes().to_vec();
        buf.extend_from_slice(b"{}");
        let err = read_frame::<_, GuestResponse>(&mut buf.as_slice()).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
    }
}
