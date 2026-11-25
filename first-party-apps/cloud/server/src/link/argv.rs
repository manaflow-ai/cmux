//! The link carrier command: the per-machine local socket and the Mac app's
//! carrier socket each stream connects to (super::dial, super::carrier).
//!
//! No credential is ever on argv, in the environment or in a file this
//! server reads: the app's `cmux carrier serve` child holds it (super::dial).

use super::dial::DialCode;
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};

/// Where the link keeps its state and its local socket.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LinkPaths {
    /// The remote client's state directory (owner only, 0700).
    pub state_dir: PathBuf,
    /// Directory of the link's local socket (short: `sun_path` is 104 bytes).
    pub socket_dir: PathBuf,
    pub device_name: String,
}

impl LinkPaths {
    /// The link's local v12 socket: `cmux-link-<12 hex>.sock`, one per machine.
    pub fn link_socket(&self, machine: &str) -> PathBuf {
        let seed = format!("{}\0{machine}", self.state_dir.display());
        let hash: String =
            Sha256::digest(seed.as_bytes()).iter().take(6).map(|b| format!("{b:02x}")).collect();
        self.socket_dir.join(format!("cmux-link-{hash}.sock"))
    }
}

/// A fully built carrier command.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LinkCommand {
    /// The Mac app's carrier socket of the machine (its `cmux carrier
    /// serve`, super::dial): each stream is one connection to it.
    pub upstream: PathBuf,
    pub state_dir: PathBuf,
    /// The carrier's local socket: each connection to it is one stream.
    pub local_socket: PathBuf,
}

/// The carrier command for `machine`, whose streams go to the app's
/// carrier socket `upstream`.
pub fn link_command(paths: &LinkPaths, machine: &str, upstream: &Path) -> LinkCommand {
    LinkCommand {
        upstream: upstream.to_path_buf(),
        state_dir: paths.state_dir.clone(),
        local_socket: paths.link_socket(machine),
    }
}

/// The carrier's event lines (super::carrier): ready with its socket, or
/// a stream's typed dial refusal.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LinkLine {
    Connected {
        local_socket: PathBuf,
    },
    /// The typed code and the detail of what failed, if one came.
    DialFailed(DialCode, Option<String>),
    Other,
}

/// `{"event":"carrier-ready","local_socket":...}`.
pub fn ready_line(local_socket: &Path) -> String {
    serde_json::json!({ "event": "carrier-ready", "local_socket": local_socket.to_string_lossy() })
        .to_string()
}

/// `{"event":"dial-failed","error_code":...,"reason":...}`: the reason is
/// an unavailable link's text, or the refusal's detail.
pub fn dial_failed_line(code: &DialCode, detail: Option<&str>) -> String {
    let reason = match code {
        DialCode::Unavailable(why) => why.as_str(),
        _ => detail.unwrap_or(""),
    };
    serde_json::json!({ "event": "dial-failed", "error_code": code.as_str(), "reason": reason })
        .to_string()
}

pub fn parse_line(line: &str) -> LinkLine {
    let Ok(value) = serde_json::from_str::<Value>(line) else { return LinkLine::Other };
    match value["event"].as_str() {
        Some("carrier-ready") => match value["local_socket"].as_str() {
            Some(socket) if !socket.is_empty() => {
                LinkLine::Connected { local_socket: PathBuf::from(socket) }
            }
            _ => LinkLine::Other,
        },
        Some("dial-failed") => {
            let code = value["error_code"].as_str().unwrap_or_default();
            match code {
                "unavailable" => LinkLine::DialFailed(
                    DialCode::Unavailable(
                        value["reason"].as_str().unwrap_or("the carrier is unavailable").to_owned(),
                    ),
                    None,
                ),
                other => LinkLine::DialFailed(
                    DialCode::parse(other),
                    value["reason"].as_str().and_then(super::dial::clip_detail),
                ),
            }
        }
        _ => LinkLine::Other,
    }
}
