//! The link process command, ported from the Swift `CloudMachineLink`
//! (Packages/macOS/CmuxNext/Sources/CmuxNextCloud/Link): `cmux-tui remote
//! connect <route> … --headless --json --exit-with-parent --lanes single
//! [--carrier] --wireguard-hub <sock>`. Flags checked against
//! `cmux-tui/crates/cmux-tui/src/remote_cli.rs`.
//!
//! No credential is ever on argv: the attach token is not used (the
//! machine's daemon grants carrier authentication on its private route) and
//! is not even kept (see [`AttachEndpoint`]).

use crate::api::{CloudError, codes};
use serde::Deserialize;
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};

/// `POST /api/vm/:id/attach-endpoint {transport: "cmux-remote"}`, minus the
/// token: serde drops unknown fields, so the token never reaches a struct,
/// a log line or argv.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AttachEndpoint {
    pub transport: String,
    pub route: String,
    #[serde(default)]
    pub trusted_carrier: bool,
}

impl AttachEndpoint {
    /// Decodes and checks the answer. The route is a positional argument, so
    /// it must be a `ws://` or `wss://` URL that cannot read as a flag.
    pub fn decode(answer: Value) -> Result<Self, CloudError> {
        let endpoint: Self = serde_json::from_value(answer)
            .map_err(|e| CloudError::new(codes::BAD_RESPONSE, format!("attach-endpoint: {e}")))?;
        if endpoint.transport != "cmux-remote" {
            return Err(CloudError::new(
                codes::BAD_RESPONSE,
                format!("attach-endpoint answered transport {:?}", endpoint.transport),
            ));
        }
        let route = endpoint.route.as_str();
        let scheme_ok = route.starts_with("ws://") || route.starts_with("wss://");
        let clean =
            route.len() <= 2048 && !route.chars().any(|c| c.is_whitespace() || c.is_control());
        if !scheme_ok || !clean {
            return Err(CloudError::new(
                codes::BAD_RESPONSE,
                "attach-endpoint answered a bad route",
            ));
        }
        Ok(endpoint)
    }
}

/// Where the link keeps its state and socket, and what it runs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LinkPaths {
    /// The `cmux-tui` binary (injected by the host).
    pub binary: PathBuf,
    /// The WireGuard hub's SOCKS socket (`cmux-tui wg hub`).
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

/// A fully built link process command.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LinkCommand {
    pub binary: PathBuf,
    pub args: Vec<String>,
    /// Added to a cleared environment (see the spawner).
    pub env: Vec<(String, String)>,
    pub state_dir: PathBuf,
    pub local_socket: PathBuf,
}

fn arg(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

/// The `remote connect` argv for one machine.
pub fn link_command(paths: &LinkPaths, machine: &str, endpoint: &AttachEndpoint) -> LinkCommand {
    let local_socket = paths.link_socket(machine);
    let mut args: Vec<String> = vec![
        "remote".into(),
        "connect".into(),
        endpoint.route.clone(),
        "--device-name".into(),
        paths.device_name.clone(),
        "--state-dir".into(),
        arg(&paths.state_dir),
        "--local-socket".into(),
        arg(&local_socket),
        "--headless".into(),
        "--json".into(),
        "--exit-with-parent".into(),
        "--lanes".into(),
        "single".into(),
        // The link's own bound on the first connection; the server has no timer.
        "--connect-timeout-seconds".into(),
        "20".into(),
    ];
    if endpoint.trusted_carrier {
        args.push("--carrier".into());
    }
    args.push("--wireguard-hub".into());
    args.push(arg(&paths.hub_socket));
    LinkCommand {
        binary: paths.binary.clone(),
        args,
        env: vec![("CMUX_REMOTE_STATE_DIR".into(), arg(&paths.state_dir))],
        state_dir: paths.state_dir.clone(),
        local_socket,
    }
}

/// The JSON lines `remote connect --headless --json` prints. The first
/// `connection-snapshot` names the local socket.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LinkLine {
    Connected { local_socket: PathBuf },
    Other,
}

pub fn parse_line(line: &str) -> LinkLine {
    let Ok(value) = serde_json::from_str::<Value>(line) else { return LinkLine::Other };
    match (value["event"].as_str(), value["local_socket"].as_str()) {
        (Some("connection-snapshot"), Some(socket)) if !socket.is_empty() => {
            LinkLine::Connected { local_socket: PathBuf::from(socket) }
        }
        _ => LinkLine::Other,
    }
}
