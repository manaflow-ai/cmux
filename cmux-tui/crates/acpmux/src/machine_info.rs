//! The agent-facing machine capability snapshot.
//!
//! This module deliberately projects only state acpmux already owns. It does not
//! probe the host, run a shell, or carry secret values through the MCP response.

use serde_json::{Value, json};
use std::path::PathBuf;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum MachineKind {
    Local,
    Cloud,
    Unknown,
}

impl MachineKind {
    fn as_str(self) -> &'static str {
        match self {
            Self::Local => "local",
            Self::Cloud => "cloud",
            Self::Unknown => "unknown",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Port {
    pub port: u16,
    pub preview_url: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct SecretStatus {
    pub name: String,
    pub status: String,
}

/// Inputs are intentionally value-only and contain no secret material.
#[derive(Debug, Clone, Default)]
pub(crate) struct State {
    pub machine_kind: Option<MachineKind>,
    pub provider: Option<String>,
    pub machine_id: Option<String>,
    pub machine_name: Option<String>,
    pub team_id: Option<String>,
    pub joined: Option<bool>,
    pub workspace_id: Option<String>,
    pub repo_root: Option<PathBuf>,
    pub branch: Option<String>,
    pub background_jobs: Vec<Value>,
    /// `None` means acpmux has no listening-port inventory. `Some([])` means
    /// the inventory is known and no ports are listening.
    pub ports: Option<Vec<Port>>,
    pub browser_available: Option<bool>,
    pub display_available: Option<bool>,
    pub preview_urls: Option<Vec<String>>,
    pub verify_command: Option<String>,
    pub secrets: Vec<SecretStatus>,
    pub unavailable: Vec<String>,
}

const PORTS_INSTEAD: &str =
    "acpmux has no listening-port inventory; use the machine's port inspection or forwarding tool.";
const PREVIEW_INSTEAD: &str =
    "No preview URL is recorded; expose a Cloud port through the machine's forwarding tool.";
const BROWSER_INSTEAD: &str =
    "A browser is unavailable here; use the browser tool on a machine that advertises one.";
const DISPLAY_INSTEAD: &str =
    "A display is unavailable here; use a machine with computer-use/display capability.";
const VERIFY_INSTEAD: &str =
    "No verify/test command is recorded; inspect the repository's documented check command.";

fn capability(
    available: Option<bool>,
    instead: &'static str,
    unavailable: &mut Vec<String>,
) -> Value {
    match available {
        Some(true) => json!({"available": true, "instead": null}),
        Some(false) | None => {
            unavailable.push(instead.to_owned());
            json!({"available": available, "instead": instead})
        }
    }
}

pub(crate) fn render(state: State) -> Value {
    let mut unavailable = state.unavailable;
    let machine_kind = state.machine_kind.unwrap_or(MachineKind::Unknown);
    if state.machine_kind.is_none() {
        unavailable.push(
            "Machine identity is unavailable; inspect the host enrollment or local machine settings."
                .to_owned(),
        );
    }

    let ports = match state.ports {
        Some(ports) => {
            let listening: Vec<Value> = ports
                .iter()
                .map(|port| json!({"port": port.port, "previewUrl": port.preview_url}))
                .collect();
            json!({"available": true, "listening": listening, "instead": null})
        }
        None => {
            unavailable.push(PORTS_INSTEAD.to_owned());
            json!({"available": false, "listening": [], "instead": PORTS_INSTEAD})
        }
    };

    let preview_urls = match state.preview_urls {
        Some(urls) => json!({"available": true, "urls": urls, "instead": null}),
        None => {
            unavailable.push(PREVIEW_INSTEAD.to_owned());
            json!({"available": false, "urls": [], "instead": PREVIEW_INSTEAD})
        }
    };

    let verify = match state.verify_command {
        Some(command) => json!({"available": true, "command": command, "instead": null}),
        None => {
            unavailable.push(VERIFY_INSTEAD.to_owned());
            json!({"available": false, "command": null, "instead": VERIFY_INSTEAD})
        }
    };

    json!({
        "machine": {
            "kind": machine_kind.as_str(),
            "provider": state.provider,
            "machineId": state.machine_id,
            "name": state.machine_name,
            "teamId": state.team_id,
            "joined": state.joined,
            "workspaceId": state.workspace_id,
        },
        "repo": {"root": state.repo_root, "branch": state.branch},
        "backgroundJobs": state.background_jobs,
        "ports": ports,
        "previewUrls": preview_urls,
        "browser": capability(state.browser_available, BROWSER_INSTEAD, &mut unavailable),
        "display": capability(state.display_available, DISPLAY_INSTEAD, &mut unavailable),
        "verify": verify,
        "secrets": state.secrets.into_iter().map(|secret| {
            json!({"name": secret.name, "status": secret.status})
        }).collect::<Vec<_>>(),
        "unavailable": unavailable,
    })
}

#[cfg(test)]
mod tests;
