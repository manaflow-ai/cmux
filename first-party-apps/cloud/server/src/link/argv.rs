//! The link carrier command: the per-machine local socket and the `cmux
//! link dial --host <host_…>` each stream runs (super::dial, super::carrier).
//!
//! No credential is ever on argv or in the environment: `cmux link`
//! resolves the host and mints its own dial token (contract 1.7).

use super::dial::{DialCode, dial_args};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};

/// Where the link keeps its state and socket, and what it runs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LinkPaths {
    /// The `cmux` binary that runs `link dial` (injected by the host).
    pub binary: PathBuf,
    /// The live `cmux link` socket the host reported (`hub_socket`); a null
    /// one means no link runs (super::config::LinkConfig::NoHub).
    pub hub_socket: PathBuf,
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
    /// The `cmux` binary; each stream runs `binary args`.
    pub binary: PathBuf,
    /// The argv of one dial (super::dial::dial_args).
    pub args: Vec<String>,
    /// The dial child's whole environment: the carrier clears everything else.
    pub env: Vec<(String, String)>,
    pub state_dir: PathBuf,
    /// The carrier's local socket: each connection to it is one dial.
    pub local_socket: PathBuf,
}

/// The carrier command for `machine`, whose overlay host id is `host`.
/// `child_env` is the whole environment of each dial child
/// (crate::app_env::AppEnv::child_env).
pub fn link_command(
    paths: &LinkPaths,
    machine: &str,
    host: &str,
    child_env: &[(String, String)],
) -> LinkCommand {
    LinkCommand {
        binary: paths.binary.clone(),
        args: dial_args(host, &paths.hub_socket),
        env: child_env.to_vec(),
        state_dir: paths.state_dir.clone(),
        local_socket: paths.link_socket(machine),
    }
}

/// The carrier's event lines (super::carrier): ready with its socket, or
/// a stream's typed dial refusal.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LinkLine {
    Connected { local_socket: PathBuf },
    DialFailed(DialCode),
    Other,
}

/// `{"event":"carrier-ready","local_socket":...}`.
pub fn ready_line(local_socket: &Path) -> String {
    serde_json::json!({ "event": "carrier-ready", "local_socket": local_socket.to_string_lossy() })
        .to_string()
}

/// `{"event":"dial-failed","error_code":...,"reason":...}`.
pub fn dial_failed_line(code: &DialCode) -> String {
    let reason = match code {
        DialCode::Unavailable(why) => why.as_str(),
        _ => "",
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
            LinkLine::DialFailed(match code {
                "unavailable" => DialCode::Unavailable(
                    value["reason"].as_str().unwrap_or("cmux link is unavailable").to_owned(),
                ),
                other => DialCode::parse(other),
            })
        }
        _ => LinkLine::Other,
    }
}
