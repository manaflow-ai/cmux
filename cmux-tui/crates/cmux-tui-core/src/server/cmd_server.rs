//! Server and client command handlers: identify, ping, server stats,
//! daemon shutdown, config reload, client info, focus reports, client list,
//! pairing responses, machine usage and listening ports, and window titles.
//! Each function is one `Command` arm of `handle_command_with_cancellation`.

use anyhow::Context;

use super::PROTOCOL_VERSION;
use super::identify_capabilities;
use crate::platform;

use super::ClientIdentityWire;
use super::machine_usage_json;
use super::origin_gate;
use super::server_stats;
use crate::Mux;
use crate::MuxEvent;
use crate::PaneId;
use crate::mux::DaemonHandoffRequest;
use serde_json::Value;
use serde_json::json;
use std::sync::Arc;

pub(super) fn server_stats(
    mux: &Arc<Mux>,
    client: u64,
    include: Option<Vec<String>>,
) -> anyhow::Result<Value> {
    if !mux.control_clients.is_unix(client) {
        anyhow::bail!("server stats requires a trusted local connection");
    }
    Ok(serde_json::to_value(server_stats::server_stats(mux, include.as_deref()))?)
}

pub(super) fn identify(mux: &Arc<Mux>) -> anyhow::Result<Value> {
    let (registry_id, generation) = mux.registry_identity();
    Ok(json!({
        "app": "cmux-tui",
        "version": env!("CARGO_PKG_VERSION"),
        "build_commit": stamped_build_commit(),
        "ghostty_commit": stamped_ghostty_commit(),
        "protocol": PROTOCOL_VERSION,
        "capabilities": identify_capabilities(mux),
        "session": mux.session,
        "pid": std::process::id(),
        "session_id": registry_id,
        "machine_name": crate::machine_name::machine_name(),
        "registry_id": registry_id,
        "generation": generation,
        "workspace_revision": mux.with_state(|state| state.workspace_revision),
        "terminal_revision": mux.terminal_registry_snapshot()?.revision,
        "daemon_handoff": 1,
        "lifecycle_ready": mux.server_lifecycle_ready(),
        "launch_snapshot_path": mux.launch_snapshot_path(),
    }))
}

pub(super) fn shutdown_daemon(
    mux: &Arc<Mux>,
    client: u64,
    pid: u32,
    generation: String,
    force: bool,
    end_terminals: bool,
    keep_layout: bool,
) -> anyhow::Result<Value> {
    anyhow::ensure!(
        end_terminals || !keep_layout,
        "bad request: keep_layout requires end_terminals"
    );
    let actual_identity =
        mux.begin_daemon_handoff(client, DaemonHandoffRequest::fenced(pid, generation, force))?;
    // The fenced handoff reservation is held, so no second shutdown
    // can start while the hosts end. A failure releases it and keeps
    // this daemon serving.
    let ended_terminals = if end_terminals {
        let ended = if keep_layout {
            mux.end_all_terminals_keeping_layout()
        } else {
            mux.end_all_terminals()
        };
        match ended {
            Ok(ended) => Some(ended.len()),
            Err(error) => {
                mux.cancel_daemon_handoff(client);
                return Err(error);
            }
        }
    } else {
        None
    };
    Ok(json!({
        "accepted": true,
        "pid": actual_identity.pid,
        "generation": actual_identity.generation,
        "ended_terminals": ended_terminals,
    }))
}

pub(super) fn ping() -> anyhow::Result<Value> {
    Ok(json!({
        "ok": true,
        "version": env!("CARGO_PKG_VERSION"),
        "build_commit": stamped_build_commit(),
        "ghostty_commit": stamped_ghostty_commit(),
        "protocol": PROTOCOL_VERSION,
    }))
}

#[allow(clippy::too_many_arguments)]
pub(super) fn set_client_info(
    mux: &Arc<Mux>,
    client: u64,
    name: Option<String>,
    kind: Option<String>,
    capabilities: Option<Vec<String>>,
    user_id: Option<String>,
    display_name: Option<String>,
    device_kind: Option<String>,
    device_name: Option<String>,
    device_id: Option<String>,
) -> anyhow::Result<Value> {
    let identity =
        ClientIdentityWire { user_id, display_name, device_kind, device_name, device_id };
    let identity_changed = !identity.is_empty();
    let (name, kind) = mux.control_clients.set_info(client, name, kind, capabilities)?;
    if identity_changed {
        mux.control_clients.set_sizing_identity(client, identity);
    }
    mux.refresh_terminal_client_identity(client);
    mux.emit(MuxEvent::ClientChanged { client, name, kind });
    Ok(json!({}))
}

pub(super) fn list_clients(mux: &Arc<Mux>, client: u64) -> anyhow::Result<Value> {
    Ok(mux.control_clients_json(client))
}

pub(super) fn machine_usage(mux: &Arc<Mux>) -> anyhow::Result<Value> {
    Ok(machine_usage_json(mux.machine_usage().as_ref()))
}

pub(super) fn machine_listening_tcp() -> anyhow::Result<Value> {
    machine_listening_tcp_json()
}

pub(super) fn pairing_response(
    mux: &Arc<Mux>,
    client: u64,
    request: u64,
    approve: bool,
) -> anyhow::Result<Value> {
    if !mux.control_clients.is_unix(client) {
        anyhow::bail!("pairing decisions require a trusted local connection");
    } else if approve && !origin_gate::may_approve_pairing(mux, client) {
        anyhow::bail!(origin_gate::PAIRING_APPROVAL_NEEDS_HUMAN);
    }
    if !mux.respond_pairing(request, approve) {
        anyhow::bail!("unknown or expired pairing request {request}");
    }
    Ok(json!({}))
}

pub(super) fn reload_config(mux: &Arc<Mux>) -> anyhow::Result<Value> {
    mux.request_config_reload()?;
    Ok(json!({
        "reloaded": true,
        "path": platform::config_path().map(|path| path.display().to_string()),
    }))
}

pub(super) fn set_window_title(mux: &Arc<Mux>, title: String) -> anyhow::Result<Value> {
    mux.emit(MuxEvent::WindowTitleRequested(title));
    Ok(json!({}))
}

pub(super) fn clear_window_title(mux: &Arc<Mux>) -> anyhow::Result<Value> {
    mux.emit(MuxEvent::WindowTitleRequested(String::new()));
    Ok(json!({}))
}

pub(super) fn report_focus(
    mux: &Arc<Mux>,
    client_id: String,
    pane: PaneId,
    tab: Option<usize>,
) -> anyhow::Result<Value> {
    validate_client_focus_id(&client_id)?;
    if !mux.with_state(|state| state.panes.contains_key(&pane)) {
        anyhow::bail!("unknown pane {pane}");
    }
    // A report only writes memory (the session's last reported focus
    // and this client's own record). It never moves the live shared
    // focus, so other attached clients stay where they are.
    mux.record_session_focus(pane, tab);
    mux.remember_client_focus(client_id, pane, tab);
    Ok(json!({}))
}

pub(super) fn client_focus(mux: &Arc<Mux>, client_id: String) -> anyhow::Result<Value> {
    validate_client_focus_id(&client_id)?;
    Ok(match mux.client_focus(&client_id).or_else(|| mux.session_focus()) {
        Some((pane, tab)) => json!({"pane": pane, "tab": tab}),
        None => json!({"pane": null, "tab": null}),
    })
}

fn validate_client_focus_id(client_id: &str) -> anyhow::Result<()> {
    if client_id.is_empty()
        || client_id.len() > 128
        || !client_id.bytes().all(|byte| byte.is_ascii_graphic())
    {
        anyhow::bail!("bad request: invalid client_id");
    }
    Ok(())
}

pub(super) fn machine_listening_tcp_json() -> anyhow::Result<Value> {
    #[cfg(not(unix))]
    {
        anyhow::bail!("machine listening TCP inventory is not supported on this platform");
    }
    #[cfg(unix)]
    {
        const MAX_LISTING_BYTES: usize = 512 * 1024;
        // The Cloud daemon runs as cmux while containerd runs as root. Use the
        // guest's existing noninteractive sudo permission for this fixed read-only
        // inventory when available; otherwise preserve the unprivileged inventory.
        #[cfg(target_os = "linux")]
        let candidates: &[(&str, &[&str])] = &[
            ("sudo", &["-n", "ss", "-H", "-ltnp"]),
            ("sudo", &["-n", "netstat", "-ltnp"]),
            ("ss", &["-H", "-ltnp"]),
            ("netstat", &["-ltnp"]),
        ];
        // netstat's -p means protocol on BSD/macOS.
        #[cfg(not(target_os = "linux"))]
        let candidates: &[(&str, &[&str])] = &[("ss", &["-H", "-ltnp"]), ("netstat", &["-ltn"])];
        let mut failures = Vec::new();
        for &(program, arguments) in candidates {
            let output = match std::process::Command::new(program).args(arguments).output() {
                Ok(output) => output,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
                Err(error) => {
                    failures.push(format!("{program}: {error}"));
                    continue;
                }
            };
            if !output.status.success() {
                failures.push(format!("{program}: exited with {}", output.status));
                continue;
            }
            if output.stdout.len() > MAX_LISTING_BYTES {
                anyhow::bail!("machine listening TCP inventory exceeded {MAX_LISTING_BYTES} bytes");
            }
            let stdout = String::from_utf8(output.stdout)
                .context("machine listening TCP inventory was not UTF-8")?;
            return Ok(json!({ "stdout": stdout }));
        }
        let detail = if failures.is_empty() {
            "neither ss nor netstat is installed".to_string()
        } else {
            failures.join("; ")
        };
        anyhow::bail!("machine listening TCP inventory failed: {detail}");
    }
}

pub(super) fn stamped_build_commit() -> Option<&'static str> {
    option_env!("CMUX_TUI_BUILD_COMMIT")
        .or(option_env!("CMUX_MUX_BUILD_COMMIT"))
        .filter(|commit| !commit.is_empty())
}

pub(super) fn stamped_ghostty_commit() -> Option<&'static str> {
    option_env!("CMUX_TUI_GHOSTTY_COMMIT").filter(|commit| !commit.is_empty())
}
