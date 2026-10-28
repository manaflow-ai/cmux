//! Server and client command handlers: identify, ping, server stats,
//! daemon shutdown, config reload, client info, focus reports, client list,
//! pairing responses, machine usage and listening ports, and window titles.
//! Each function is one `Command` arm of `handle_command_with_cancellation`.

use crate::panic_free::JsonFields;
use anyhow::Context;

use super::PROTOCOL_VERSION;
use super::capabilities::identify_capabilities_for;
use super::daemon_build::{stamped_build_commit, stamped_ghostty_commit};
use crate::platform;

use super::ClientIdentityWire;
use super::machine_usage_json;
use super::origin_gate;
use super::server_stats;
use super::{AsyncReply, MessageWriter, Response, send_response};
use crate::Mux;
use crate::MuxEvent;
use crate::PaneId;
use crate::mux::DaemonHandoffRequest;
use crate::startup_marks::{StartupMark, StartupMarks};
use crate::work_reply::{Unanswered, WorkReply};
use cmux_threads::work::{Lane, Priority, Shutdown};
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

/// `debug-daemon-locks`: the registry and state locks' wait and hold time
/// by caller class and request op (server/server_stats.rs).
pub(super) fn daemon_locks(mux: &Arc<Mux>, client: u64) -> anyhow::Result<Value> {
    if !mux.control_clients.is_unix(client) {
        return Err(server_stats::DaemonLocksRefused::NotLocal.into());
    }
    Ok(serde_json::to_value(server_stats::daemon_locks(mux))?)
}

/// `server-threads`: every registered daemon thread with its declared,
/// desired and kernel QoS and scheduler priority, the work lanes, and the
/// process's task role (server/server_stats.rs).
pub(super) fn server_threads(mux: &Arc<Mux>, client: u64) -> anyhow::Result<Value> {
    if !mux.control_clients.is_unix(client) {
        return Err(server_stats::ThreadDiagnosticsRefused::NotLocal.into());
    }
    Ok(serde_json::to_value(server_stats::server_threads(mux))?)
}

/// `server-blocking`: the blocking calls made on threads that disallow
/// blocking, by call site (server/server_stats.rs).
pub(super) fn server_blocking(mux: &Arc<Mux>, client: u64) -> anyhow::Result<Value> {
    if !mux.control_clients.is_unix(client) {
        return Err(server_stats::ThreadDiagnosticsRefused::NotLocal.into());
    }
    Ok(serde_json::to_value(server_stats::server_blocking(mux))?)
}

/// `trace-start`, `trace-stop` and `trace-status` (server/trace_control.rs):
/// owner only, refused before `call` reads a parameter.
pub(super) fn trace_control(
    mux: &Arc<Mux>,
    client: u64,
    call: impl FnOnce() -> anyhow::Result<super::trace_control::Call>,
) -> anyhow::Result<Value> {
    use super::trace_control::{TraceControlRefused, run_live};
    if !mux.control_clients.is_unix(client) {
        return Err(TraceControlRefused::NotLocal.into());
    }
    Ok(run_live(mux, call()?)?)
}

/// `memory-report` (server/memory_report.rs): owner only, refused before
/// anything is read.
pub(super) fn memory_report(mux: &Arc<Mux>, client: u64) -> anyhow::Result<Value> {
    use super::memory_report::{MemoryReportRefused, report};
    // A local socket with a bound `cmux link` peer is remote as well.
    if !mux.control_clients.is_unix(client) || mux.is_remote_client(client) {
        return Err(MemoryReportRefused::NotLocal.into());
    }
    Ok(report(mux))
}

/// `identify`'s optional flags. Each adds fields to the reply and is off by
/// default, so strict older SDK decoders keep reading the default reply
/// (machine_identity_reader_tests.rs); an unknown flag is ignored, as older
/// daemons ignore these.
#[derive(Debug, Default, serde::Deserialize)]
pub(super) struct IdentifyParams {
    #[serde(default)]
    pub(super) machine_metadata: bool,
    /// Adds `api_revision`, `min_api_revision`, `crate_version`,
    /// `install` and `update_command` (server/api_revision_wire.rs).
    #[serde(default)]
    pub(super) revisions: bool,
    /// Adds `startup_marks`, the serving daemon's startup timeline
    /// (`startup-marks-v1`, startup_marks.rs); `null` when no daemon serves
    /// this mux.
    #[serde(default)]
    pub(super) startup_marks: bool,
}

pub(super) fn identify(
    mux: &Arc<Mux>,
    client: u64,
    params: IdentifyParams,
) -> anyhow::Result<Value> {
    let IdentifyParams { machine_metadata, revisions, startup_marks } = params;
    let (registry_id, generation) = mux.registry_identity();
    let (build_id, cli_path) = super::daemon_build::identify_build_fields();
    let capabilities = identify_capabilities_for(mux, client);
    let frames_offered = capabilities.contains(&super::line_connection::IPC_FRAMES_CAPABILITY);
    let mut identity = json!({
        "app": "cmux-tui",
        // The npm/PyPI release (the crate version in the app and local builds).
        "version": crate::release::DISTRIBUTION_VERSION,
        "build_commit": stamped_build_commit(),
        "build_id": build_id,
        "cli_path": cli_path,
        "ghostty_commit": stamped_ghostty_commit(),
        "protocol": PROTOCOL_VERSION,
        "capabilities": capabilities,
        "session": mux.session,
        "pid": std::process::id(),
        "session_id": registry_id,
        "machine_name": crate::machine_name::machine_name(),
        "registry_id": registry_id,
        "generation": generation,
        "workspace_revision": mux.with_state(|state| state.workspace_revision),
        "terminal_revision": mux.terminal_registry_revision()?,
        "daemon_handoff": 1,
        "lifecycle_ready": mux.server_lifecycle_ready(),
        "launch_snapshot_path": mux.launch_snapshot_path(),
    });
    // Opt-in like machine metadata: strict pre-revision SDKs decode the
    // default reply with deny_unknown_fields (machine_identity_reader_tests.rs).
    if revisions {
        let (current, base) = super::api_revision_wire::identify_fields();
        let channel = crate::release::InstallChannel::current();
        identity.insert("api_revision", json!(current));
        identity.insert("min_api_revision", json!(base));
        identity.insert("crate_version", json!(env!("CARGO_PKG_VERSION")));
        // How this daemon was installed and how to update it, for a client's refusal text.
        identity.insert("install", json!(channel.as_str()));
        identity.insert("update_command", json!(channel.update_command()));
        // The stream frame cut (bench-daemon-latency.py --bulk-interference).
        identity.insert("bulk_frame_max", json!(mux.bulk_frame_max()));
        // What a client checks before it sends REQUEST frames: the schema
        // its method table must come from, and the methods this daemon
        // answers on frames (server/frame_dispatch.rs).
        if frames_offered {
            identity.insert("sdk_schema_digest", json!(super::frame_dispatch::sdk_schema_digest()));
            identity.insert("framed_methods", json!(super::frame_dispatch::framed_method_ids()));
        }
    }
    if machine_metadata {
        identity.insert("machine_id", json!(mux.machine_public_id));
        identity.insert("session_resource_id", json!(mux.session_public_id));
        identity.insert("machine_platform", crate::resource_api::machine_platform());
        identity.insert("machine_capabilities", crate::resource_api::machine_capabilities());
    }
    // Before the timeline is read, so the first identify that asks reports
    // itself; one served before lifecycle readiness is not counted.
    mux.mark_startup(StartupMark::FirstIdentifyServed);
    if startup_marks {
        identity
            .insert("startup_marks", mux.startup_marks().map_or(Value::Null, StartupMarks::wire));
    }
    Ok(identity)
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
    api_revision: Option<u32>,
    version: Option<String>,
    install: Option<String>,
    remote: bool,
) -> anyhow::Result<Value> {
    // Refuse an unsupported revision before changing anything else; the
    // refusal names the client's own update command.
    if let Some(revision) = api_revision {
        mux.control_clients.set_api_revision(client, revision).map_err(|error| {
            anyhow::anyhow!(
                "{}",
                super::api_revision_wire::too_old_text(
                    &error.to_string(),
                    version.as_deref(),
                    install.as_deref()
                )
            )
        })?;
    }
    let identity =
        ClientIdentityWire { user_id, display_name, device_kind, device_name, device_id };
    let identity_changed = !identity.is_empty();
    let (name, kind) = mux.control_clients.set_info(client, name, kind, capabilities)?;
    if identity_changed {
        mux.control_clients.set_sizing_identity(client, identity);
    }
    if remote {
        mux.control_clients.mark_remote_device(client);
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

/// `machine-listening-tcp` runs ss or netstat to completion, so it runs on a
/// work item of the System lane and answers from there; the request thread
/// goes on at once (Chrome posts blocking work to a MayBlock task runner,
/// base/task/task_traits.h). The inventory is a view's poll: UserVisible.
/// It only reads, so shutdown never waits for it (ContinueOnShutdown); a
/// refused, dropped or panicked item still answers its id.
pub(super) fn start_machine_listening_tcp(
    mux: &Arc<Mux>,
    id: Option<Value>,
    reply: AsyncReply,
    writer: &MessageWriter,
) -> bool {
    let item_writer = writer.clone();
    let answer = WorkReply::new(move |listing: Result<anyhow::Result<Value>, Unanswered>| {
        let listing = listing.unwrap_or_else(|why| {
            Err(match why {
                Unanswered::ShuttingDown => anyhow::anyhow!("the daemon is shutting down"),
                Unanswered::Panicked => {
                    anyhow::anyhow!("internal error: the listening-port read stopped unexpectedly")
                }
            })
        });
        reply.reply(|| respond(&item_writer, id, listing));
    });
    // A refused item is dropped here, and `answer` answers it.
    let _ = mux.work.post(
        Priority::UserVisible,
        Lane::System,
        Shutdown::ContinueOnShutdown,
        move || answer.run(machine_listening_tcp_json),
    );
    true
}

fn respond(writer: &MessageWriter, id: Option<Value>, answer: anyhow::Result<Value>) -> bool {
    let response = match answer {
        Ok(data) => Response {
            id,
            ok: true,
            data: Some(data),
            error: None,
            error_code: None,
            error_delivery: None,
        },
        Err(error) => Response {
            id,
            ok: false,
            data: None,
            error: Some(error.to_string()),
            error_code: None,
            error_delivery: None,
        },
    };
    send_response(writer, response)
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
            crate::request_path::note(crate::request_path::BlockingKind::ChildProcess);
            let output = match cmux_process::Command::new(program)
                .args(arguments)
                .qos_ceiling(cmux_threads::HELPER_CHILD)
                .output()
            {
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
