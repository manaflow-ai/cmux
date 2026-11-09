//! User-facing remote daemon, connection, enrollment, and SSH bootstrap CLI.

use std::collections::{BTreeMap, BTreeSet};
use std::ffi::OsString;
use std::fs::{self, OpenOptions};
use std::io::{self, BufRead, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use crate::distribution::{DISTRIBUTION_VERSION, NPM_BOOTSTRAP_VERSION};
use anyhow::{Context, anyhow};
use base64::Engine;
use cmux_build_identity::BUILD_IDENTITY;
use cmux_json::JsonSet as _;
#[cfg(test)]
use cmux_remote::admin::UnixPeerAuthError;
use cmux_remote::admin::{AdminRequest, AdminResponse, call_admin, call_admin_with_peer_exit};
use cmux_remote::bridge::LocalPortForward;
use cmux_remote::client::WorkspaceClient;
use cmux_remote::connection::ReconnectPolicy;
use cmux_remote::crypto::ClientAuthMode;
use cmux_remote::identity::{
    ClientIdentityStore, EnrollmentInvitation, EnrollmentRelayAccess, KnownDaemon, KnownDaemonAuth,
    MAX_INVITATION_URI_BYTES, credential_free_route_hint, default_state_dir,
};
use cmux_remote::provider::{
    Dialer, IrohPathMode, ProviderError, ROUTING_DIRECT_ADDRS, ROUTING_NODE_ID, ROUTING_RELAY_URL,
    RelayCredentialSource, SocksDialer, SshProvider, SshProviderConfig, SupportedClientAuthModes,
    WireGuardDialer, sanitized_route,
};
use cmux_remote::secure_directory::{DirectoryAccess, ensure_secure_directory};
use cmux_remote_protocol::{
    LanePolicy, REMOTE_PROTOCOL_VERSION, RouteId, RoutePolicy, SessionId, WorkspaceRequest,
    WorkspaceResponse,
};
use serde_json::Value;
use url::Url;
use zeroize::Zeroizing;

use crate::localization::catalog;
#[cfg(test)]
use crate::remote_runtime::persist_daemon_lifecycle_fence;
use crate::remote_runtime::{
    ClientRuntimeOptions, DaemonRuntimeOptions, DaemonShutdownStatus, RelayClientOptions,
    ResolvedRouteCandidate, SshBootstrapOptions, acknowledge_failed_shutdown_outcome,
    acknowledge_legacy_shutdown_state, client_provider_registry, complete_verified_daemon_stop,
    daemon_paths, inactive_daemon_needs_legacy_acknowledgement, load_runtime_info,
    load_shutdown_outcome, start_client_runtime, start_daemon_runtime,
    start_recovering_client_runtime,
};
use crate::session::{RemoteSession, Session};
mod acpmux_peer;
mod daemon_lifecycle;
mod enroll;
#[cfg(test)]
mod remote_link_binding_tests;
mod remote_link_mux;
mod self_install;
use daemon_lifecycle::*;
use enroll::*;
use remote_link_mux::{mux_owner_args, socket_for};
use self_install::*;

const DEFAULT_STARTUP_TIMEOUT: Duration = Duration::from_secs(90);
const WIREGUARD_HUB_START_TIMEOUT: Duration = Duration::from_secs(10);
const WIREGUARD_HUB_HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
const ENROLLMENT_APPROVAL_TIMEOUT: Duration = Duration::from_secs(5 * 60);
const MAX_RPC_STDIN_LINE_BYTES: usize = 16 * 1024 * 1024;
const MAX_CLIENT_RELAY_ROUTES: usize = 4;
const DETACHED_TERM_GRACE: Duration = Duration::from_millis(500);
const DETACHED_KILL_GRACE: Duration = Duration::from_secs(1);
const FORWARD_CLEANUP_TIMEOUT: Duration = Duration::from_secs(2);

pub fn is_remote_invocation(args: &[String]) -> bool {
    crate::cli::is_remote_invocation(args)
}

pub fn run(
    args: &[String],
    usage: &str,
    load_config: impl FnOnce() -> crate::config::StartupConfigSnapshot,
) -> i32 {
    match run_inner(args, usage, load_config) {
        Ok(()) => 0,
        Err(error) => {
            crate::client_log::stderr_log!("remote", "{BIN}: {error:#}");
            1
        }
    }
}

fn run_inner(
    args: &[String],
    usage: &str,
    load_config: impl FnOnce() -> crate::config::StartupConfigSnapshot,
) -> anyhow::Result<()> {
    if remote_help_requested(&args[1..]) {
        print!("{}", remote_help(args.first().map(String::as_str)));
        return Ok(());
    }
    match args.first().map(String::as_str) {
        Some("connect") => run_connect(&args[1..], None, load_config),
        Some("ssh") => run_ssh(&args[1..], load_config),
        Some("forward") => run_forward(&args[1..]),
        Some("dial-tcp") => run_dial_tcp(args.get(1..).unwrap_or_default()),
        Some("browser-proxy") => run_browser_proxy(&args[1..]),
        Some("rpc") => run_rpc(&args[1..]),
        Some("enroll") => run_enroll(&args[1..], load_config),
        Some("known-daemons") => run_known_daemons(&args[1..]),
        Some("remote-probe") => run_probe(&args[1..]),
        Some("remote-link") => run_remote_link(&args[1..]),
        Some("remote-sidecar") => run_remote_sidecar(&args[1..]),
        Some("remote-stop") => run_remote_stop(&args[1..]),
        Some("remote-update-need") => run_update_need(&args[1..]),
        Some("install-self") => run_install_self(&args[1..]),
        Some("wg") => run_wg(&args[1..]),
        Some("remote") => Err(anyhow!(catalog().remote_client.remote_lifecycle_help)),
        _ => Err(anyhow!("unknown remote command\n\n{usage}")),
    }
}

fn remote_help_requested(args: &[String]) -> bool {
    const VALUE_OPTIONS: &[&str] = &[
        "--invite-file",
        "--daemon",
        "--lanes",
        "--reconnect-attempts",
        "--reconnect-initial-ms",
        "--reconnect-max-ms",
        "--reconnect-attempt-timeout-ms",
        "--reconnect-jitter",
        "--heartbeat-interval-ms",
        "--heartbeat-timeout-ms",
        "--connect-timeout-seconds",
        "--device-name",
        "--state-dir",
        "--local-socket",
        "--relay-route",
        "--relay-slot",
        "--relay-ticket-file",
        "--relay-ticket-command",
        "--relay-ticket-command-arg",
        "--iroh-relay",
        "--iroh-address",
        "--iroh-path",
        "--session",
        "--ssh-binary",
        "--remote-binary",
        "--remote-state-dir",
        "--remote-mux-socket",
        "--agent-hooks",
        "--wireguard-config",
        "--wireguard-hub",
        "--ssh-arg",
        "--workspace-root",
        "--host",
        "--port",
        "--listen",
        "--scheme",
        "--request",
        "--ttl",
        "--advertise",
        "--admin-socket",
        "--link-socket",
        "--mux-socket",
        "--destination",
    ];

    let mut index = 0;
    let mut requested = false;
    while index < args.len() {
        match args[index].as_str() {
            "-h" | "--help" => {
                requested = true;
                index += 1;
            }
            option
                if is_inline_secret_option(option, "--invite")
                    || is_inline_secret_option(option, "--relay-ticket") =>
            {
                return false;
            }
            option if VALUE_OPTIONS.contains(&option) => index += 2,
            _ => index += 1,
        }
    }
    requested
}

fn is_inline_secret_option(argument: &str, option: &str) -> bool {
    argument == option
        || argument.strip_prefix(option).is_some_and(|suffix| suffix.starts_with('='))
}

fn remote_help(command: Option<&str>) -> &'static str {
    let client = &catalog().remote_client;
    match command {
        Some("connect") => client.connect_help,
        Some("ssh") => client.ssh_help,
        Some("forward") => client.forward_help,
        Some("dial-tcp") => client.dial_tcp_help,
        Some("browser-proxy") => client.browser_proxy_help,
        Some("rpc") => client.rpc_help,
        Some("enroll") => client.enroll_help,
        Some("known-daemons") => client.known_daemons_help,
        Some("remote-probe") => client.remote_probe_help,
        Some("remote-link") => client.remote_link_help,
        Some("remote-stop") => catalog().remote.remote_stop_help,
        Some("remote-update-need") => catalog().remote.remote_update_need_help,
        Some("install-self") => client.install_self_help,
        Some("wg") => client.wg_hub_help,
        Some("remote") => client.remote_lifecycle_help,
        _ => client.command_help,
    }
}

#[derive(Default)]
struct ConnectFlags {
    route: Option<String>,
    invitation: Option<InvitationArg>,
    daemon: Option<String>,
    lanes: LanePolicy,
    lanes_explicit: bool,
    reconnect: ReconnectPolicy,
    startup_timeout: Option<Duration>,
    device_name: Option<String>,
    state_dir: Option<PathBuf>,
    local_socket: Option<PathBuf>,
    relay_routes: Vec<String>,
    relay_slots: Vec<String>,
    relay_credentials: Vec<ClientRelayCredentialArg>,
    routing: BTreeMap<String, String>,
    iroh_path: IrohPathMode,
    wireguard_config: Option<PathBuf>,
    wireguard_hub: Option<PathBuf>,
    /// Read the hub's client token (`wg hub --client-token-stdin`) as one line on
    /// stdin, so it never appears in argv, the environment or a file.
    wireguard_hub_token_stdin: bool,
    /// Dial `ws`/`wss` routes with carrier authentication: no enrollment, no
    /// invitation. Only a daemon serving a trusted-network listener accepts it.
    carrier: bool,
    /// Internal app ownership fence. The helper exits when its direct parent exits,
    /// including an abort or forced app replacement that cannot run Swift cleanup.
    exit_with_parent: bool,
    /// `--vm-kind owner`: the app asked the Cloud API's attach-endpoint for this
    /// machine, signed in, and it answered `vmKind: "owner"` (the caller's own
    /// personal VM). The acpmux peer bridge then leases the machine at the VM
    /// boundary (`acpmux_peer.rs`). Any other value, or none, keeps the sandbox.
    vm_owner: bool,
    headless: bool,
    json: bool,
    ssh_session: String,
    ssh_binary: String,
    remote_binary: String,
    remote_state_dir: Option<String>,
    remote_mux_socket: Option<String>,
    ssh_args: Vec<String>,
    /// Coding-agent providers whose hooks the SSH host installs on attach.
    agent_hooks: Vec<String>,
    auto_install: bool,
    upgrade: bool,
    /// `--ssh-forced-command`: see `SshBootstrapOptions::forced_command`.
    ssh_forced_command: bool,
    forward_workspace: Option<String>,
    forward_host: Option<String>,
    forward_port: Option<u16>,
    forward_listen: Option<std::net::SocketAddr>,
    forward_scheme: String,
    rpc_request: Option<String>,
}

enum InvitationArg {
    File(PathBuf),
}

enum ClientRelayCredentialArg {
    File(PathBuf),
    Command { program: String, args: Vec<String> },
}

fn parse_connect_flags(args: &[String]) -> anyhow::Result<ConnectFlags> {
    let mut flags = ConnectFlags {
        lanes: LanePolicy::Auto,
        ssh_session: "main".into(),
        ssh_binary: "ssh".into(),
        remote_binary: "~/.local/bin/cmux-tui".into(),
        auto_install: true,
        forward_scheme: "http".into(),
        ..ConnectFlags::default()
    };
    let mut index = 0;
    while index < args.len() {
        let argument = &args[index];
        index += 1;
        let mut value = |name: &str| -> anyhow::Result<String> {
            let value = args
                .get(index)
                .cloned()
                .ok_or_else(|| anyhow!(catalog().remote_client.option_needs_value(name)))?;
            index += 1;
            Ok(value)
        };
        match argument.as_str() {
            option if is_inline_secret_option(option, "--invite") => {
                return Err(anyhow!(catalog().remote_client.inline_invitation_rejected));
            }
            "--invite-file" => set_invitation_arg(
                &mut flags.invitation,
                InvitationArg::File(value("--invite-file")?.into()),
            )?,
            "--daemon" => flags.daemon = Some(value("--daemon")?),
            "--carrier" => flags.carrier = true,
            "--lanes" => {
                flags.lanes = value("--lanes")?.parse().map_err(|_: String| {
                    anyhow!(
                        catalog()
                            .remote_client
                            .invalid_option_value("--lanes", "auto|single|isolated")
                    )
                })?;
                flags.lanes_explicit = true;
            }
            "--reconnect-attempts" => {
                // Accepted for old apps (they pass 5) and validated, but no longer a cap: the
                // link redials in budgeted bursts and never exits while its owner holds it.
                let attempts = value("--reconnect-attempts")?;
                if attempts != "unlimited" && !attempts.parse::<u32>().is_ok_and(|n| n > 0) {
                    return Err(anyhow!(
                        catalog()
                            .remote_client
                            .invalid_option_value("--reconnect-attempts", "N|unlimited")
                    ));
                }
            }
            "--reconnect-initial-ms" => {
                flags.reconnect.initial_delay = Duration::from_millis(
                    value("--reconnect-initial-ms")?.parse().map_err(|_| {
                        anyhow!(
                            catalog()
                                .remote_client
                                .invalid_option_value("--reconnect-initial-ms", "milliseconds")
                        )
                    })?,
                );
            }
            "--reconnect-max-ms" => {
                flags.reconnect.maximum_delay =
                    Duration::from_millis(value("--reconnect-max-ms")?.parse().map_err(|_| {
                        anyhow!(
                            catalog()
                                .remote_client
                                .invalid_option_value("--reconnect-max-ms", "milliseconds")
                        )
                    })?);
            }
            "--reconnect-attempt-timeout-ms" => {
                flags.reconnect.attempt_timeout =
                    Duration::from_millis(
                        value("--reconnect-attempt-timeout-ms")?.parse().map_err(|_| {
                            anyhow!(catalog().remote_client.invalid_option_value(
                                "--reconnect-attempt-timeout-ms",
                                "milliseconds",
                            ))
                        })?,
                    );
            }
            "--reconnect-jitter" => {
                flags.reconnect.full_jitter = match value("--reconnect-jitter")?.as_str() {
                    "full" => true,
                    "none" => false,
                    _ => {
                        return Err(anyhow!(
                            catalog()
                                .remote_client
                                .invalid_option_value("--reconnect-jitter", "full|none")
                        ));
                    }
                };
            }
            "--heartbeat-interval-ms" => {
                let milliseconds =
                    value("--heartbeat-interval-ms")?.parse::<u64>().map_err(|_| {
                        anyhow!(
                            catalog()
                                .remote_client
                                .invalid_option_value("--heartbeat-interval-ms", "milliseconds",)
                        )
                    })?;
                flags.reconnect.heartbeat_interval =
                    (milliseconds != 0).then(|| Duration::from_millis(milliseconds));
            }
            "--heartbeat-timeout-ms" => {
                flags.reconnect.heartbeat_timeout = Duration::from_millis(
                    value("--heartbeat-timeout-ms")?.parse().map_err(|_| {
                        anyhow!(
                            catalog()
                                .remote_client
                                .invalid_option_value("--heartbeat-timeout-ms", "milliseconds")
                        )
                    })?,
                );
            }
            "--connect-timeout-seconds" => {
                let seconds = value("--connect-timeout-seconds")?.parse::<u64>().map_err(|_| {
                    anyhow!(
                        catalog()
                            .remote_client
                            .invalid_option_value("--connect-timeout-seconds", "positive integer")
                    )
                })?;
                if seconds == 0 {
                    return Err(anyhow!(
                        catalog()
                            .remote_client
                            .option_must_be_positive("--connect-timeout-seconds")
                    ));
                }
                flags.startup_timeout = Some(Duration::from_secs(seconds));
            }
            "--device-name" => flags.device_name = Some(value("--device-name")?),
            "--state-dir" => flags.state_dir = Some(value("--state-dir")?.into()),
            "--local-socket" => flags.local_socket = Some(value("--local-socket")?.into()),
            "--relay-route" => flags.relay_routes.push(value("--relay-route")?),
            "--relay-slot" => flags.relay_slots.push(value("--relay-slot")?),
            option if is_inline_secret_option(option, "--relay-ticket") => {
                return Err(anyhow!(catalog().remote_client.inline_relay_ticket_rejected));
            }
            "--relay-ticket-file" => {
                flags
                    .relay_credentials
                    .push(ClientRelayCredentialArg::File(value("--relay-ticket-file")?.into()));
            }
            "--relay-ticket-command" => {
                flags.relay_credentials.push(ClientRelayCredentialArg::Command {
                    program: value("--relay-ticket-command")?,
                    args: Vec::new(),
                });
            }
            "--relay-ticket-command-arg" => {
                let argument = value("--relay-ticket-command-arg")?;
                match flags.relay_credentials.last_mut() {
                    Some(ClientRelayCredentialArg::Command { args, .. }) => args.push(argument),
                    _ => {
                        return Err(anyhow!(catalog().remote_client.relay_command_arg_order));
                    }
                }
            }
            "--iroh-relay" => {
                flags.routing.insert(ROUTING_RELAY_URL.into(), value("--iroh-relay")?);
            }
            "--iroh-address" => {
                let address = value("--iroh-address")?;
                flags
                    .routing
                    .entry(ROUTING_DIRECT_ADDRS.into())
                    .and_modify(|current| {
                        current.push(',');
                        current.push_str(&address);
                    })
                    .or_insert(address);
            }
            "--iroh-path" => {
                flags.iroh_path = value("--iroh-path")?.parse().map_err(|_: String| {
                    anyhow!(
                        catalog()
                            .remote_client
                            .invalid_option_value("--iroh-path", "auto|direct-only|relay-only",)
                    )
                })?;
            }
            "--wireguard-config" => {
                let path = PathBuf::from(value("--wireguard-config")?);
                if flags.wireguard_config.replace(path).is_some() {
                    return Err(anyhow!(catalog().remote_client.option_once("--wireguard-config")));
                }
            }
            "--wireguard-hub" => {
                let path = PathBuf::from(value("--wireguard-hub")?);
                if flags.wireguard_hub.replace(path).is_some() {
                    return Err(anyhow!(catalog().remote_client.option_once("--wireguard-hub")));
                }
            }
            "--wireguard-hub-token-stdin" => flags.wireguard_hub_token_stdin = true,
            "--exit-with-parent" => flags.exit_with_parent = true,
            "--vm-kind" => flags.vm_owner = value("--vm-kind")? == "owner",
            "--headless" => flags.headless = true,
            "--json" => flags.json = true,
            "--session" => flags.ssh_session = value("--session")?,
            "--ssh-binary" => flags.ssh_binary = value("--ssh-binary")?,
            "--remote-binary" => flags.remote_binary = value("--remote-binary")?,
            "--remote-state-dir" => {
                flags.remote_state_dir = Some(value("--remote-state-dir")?);
            }
            "--remote-mux-socket" => {
                flags.remote_mux_socket = Some(value("--remote-mux-socket")?);
            }
            "--ssh-arg" => flags.ssh_args.push(value("--ssh-arg")?),
            "--agent-hooks" => {
                flags.agent_hooks.extend(agent_hook_providers(&value("--agent-hooks")?));
            }
            "--no-install" => flags.auto_install = false,
            "--ssh-forced-command" => flags.ssh_forced_command = true,
            "--upgrade" => flags.upgrade = true,
            "--workspace-root" => flags.forward_workspace = Some(value("--workspace-root")?),
            "--host" => flags.forward_host = Some(value("--host")?),
            "--port" => {
                flags.forward_port = Some(value("--port")?.parse().map_err(|_| {
                    anyhow!(catalog().remote_client.invalid_option_value("--port", "TCP port"))
                })?);
            }
            "--listen" => {
                flags.forward_listen = Some(value("--listen")?.parse().map_err(|_| {
                    anyhow!(
                        catalog().remote_client.invalid_option_value("--listen", "socket address")
                    )
                })?);
            }
            "--scheme" => flags.forward_scheme = value("--scheme")?,
            "--request" => flags.rpc_request = Some(value("--request")?),
            "-h" | "--help" => {
                return Err(anyhow!(catalog().remote_client.help_invalid_options));
            }
            option if option.starts_with('-') => {
                return Err(anyhow!(catalog().remote_client.connect_option_refused(option)));
            }
            route => {
                if route.starts_with("cmux://enroll/") {
                    return Err(anyhow!(catalog().remote_client.positional_invitation_rejected));
                }
                if flags.route.replace(route.to_string()).is_some() {
                    return Err(anyhow!(catalog().remote_client.connect_one_route));
                }
            }
        }
    }
    if flags.reconnect.initial_delay.is_zero()
        || flags.reconnect.maximum_delay < flags.reconnect.initial_delay
        || flags.reconnect.attempt_timeout.is_zero()
        || (flags.reconnect.heartbeat_interval.is_some()
            && flags.reconnect.heartbeat_timeout.is_zero())
    {
        return Err(anyhow!(catalog().remote_client.reconnect_policy_invalid));
    }
    if flags.upgrade && !flags.auto_install {
        return Err(anyhow!(catalog().remote_client.upgrade_no_install));
    }
    if flags.upgrade && flags.ssh_forced_command {
        return Err(anyhow!(catalog().remote_client.upgrade_forced_command));
    }
    if flags.json && !flags.headless {
        return Err(anyhow!(catalog().remote_client.json_requires_headless));
    }
    if flags.wireguard_config.is_some() && flags.wireguard_hub.is_some() {
        return Err(anyhow!(catalog().remote_client.wireguard_hub_conflict));
    }
    if flags.wireguard_hub_token_stdin && flags.wireguard_hub.is_none() {
        return Err(anyhow!(catalog().remote_client.wireguard_hub_token_needs_hub));
    }
    if flags.wireguard_hub_token_stdin
        && matches!(&flags.invitation, Some(InvitationArg::File(path)) if path == Path::new("-"))
    {
        return Err(anyhow!(catalog().remote_client.stdin_claimed_twice));
    }
    Ok(flags)
}

fn set_invitation_arg(
    destination: &mut Option<InvitationArg>,
    invitation: InvitationArg,
) -> anyhow::Result<()> {
    if destination.replace(invitation).is_some() {
        return Err(anyhow!(catalog().remote_client.option_once("--invite-file")));
    }
    Ok(())
}

fn run_connect(
    args: &[String],
    preset_route: Option<String>,
    load_config: impl FnOnce() -> crate::config::StartupConfigSnapshot,
) -> anyhow::Result<()> {
    let mut flags = parse_connect_flags(args)?;
    if preset_route.is_some() {
        flags.route = preset_route;
    }
    // A client with its own state directory (the app's link, cx-fdjq) keeps
    // its client log there, as `remote-link --state-dir` does (cx-bduj).
    if let Some(root) = flags.state_dir.as_deref() {
        crate::client_log::use_path(root.join("client.log"));
    }
    connect_with_flags(flags, load_config)
}

fn connect_with_flags(
    flags: ConnectFlags,
    load_config: impl FnOnce() -> crate::config::StartupConfigSnapshot,
) -> anyhow::Result<()> {
    let headless = flags.headless;
    let json = flags.json;
    let owner = flags.exit_with_parent.then(current_parent_process_id);
    let vm_owner = flags.vm_owner;
    let connected = start_connected(flags)?;
    if headless {
        if json {
            let runtime = tokio_runtime()?;
            runtime.block_on(async {
                // Off by default (`CMUX_ACPMUX_CLOUD_PEER=1`); ends with this loop.
                let _peer_bridge =
                    acpmux_peer::AcpmuxPeerBridge::spawn(&connected.runtime, vm_owner);
                let mut previous = None;
                let mut finished = connected.runtime.subscribe_finished();
                while !crate::shutdown_requested()
                    && !connected.runtime.is_finished()
                    && owner.is_none_or(parent_process_is)
                {
                    let snapshot = connected.runtime.connection_snapshot().await;
                    let mut topology = snapshot.clone();
                    if let Some(path) = topology.transport.selected_path.as_mut() {
                        path.rtt_micros = None;
                    }
                    if previous.as_ref() != Some(&topology) {
                        println!(
                            "{}",
                            serde_json::json!({
                                "event": "connection-snapshot",
                                "local_socket": connected.runtime.info().local_socket.display().to_string(),
                                "connection": snapshot,
                            })
                        );
                        io::stdout().flush()?;
                        previous = Some(topology);
                    }
                    tokio::select! {
                        _ = finished.changed() => {},
                        _ = tokio::time::sleep(Duration::from_millis(100)) => {},
                    }
                }
                // The session is gone for good (it outlived the daemon's
                // resume lease): say so, typed, so the owner stops
                // redialing it and offers a new session.
                if connected.runtime.session_unavailable() {
                    println!(
                        "{}",
                        serde_json::json!({
                            "event": "session-unavailable",
                            "local_socket": connected.runtime.info().local_socket.display().to_string(),
                        })
                    );
                    io::stdout().flush()?;
                }
                Ok::<_, io::Error>(())
            })?;
        } else {
            println!("{}", connected.runtime.info().local_socket.display());
            while !crate::shutdown_requested()
                && !connected.runtime.is_finished()
                && owner.is_none_or(parent_process_is)
            {
                thread::sleep(Duration::from_millis(100));
            }
        }
        return connected.runtime.shutdown();
    }

    let remote = RemoteSession::connect(&connected.runtime.info().local_socket)?;
    let config = load_config();
    let result = crate::run_tui(Session::Remote(remote), connected.route, None, config);
    let shutdown = connected.runtime.shutdown();
    result.and(shutdown)
}

struct ConnectedRuntime {
    runtime: crate::remote_runtime::ClientRuntimeHandle,
    route: String,
}

fn start_connected(mut flags: ConnectFlags) -> anyhow::Result<ConnectedRuntime> {
    let startup_started = Instant::now();
    let owner = flags.exit_with_parent.then(current_parent_process_id);
    let invitation = flags
        .invitation
        .take()
        .map(|InvitationArg::File(path)| read_invitation_uri(&path))
        .transpose()?
        .as_ref()
        .map(|encoded| EnrollmentInvitation::from_uri(encoded.as_str()))
        .transpose()?;
    let total_startup_timeout = flags
        .startup_timeout
        .unwrap_or_else(|| invitation.as_ref().map_or(DEFAULT_STARTUP_TIMEOUT, invitation_timeout));
    let client_root = flags
        .state_dir
        .clone()
        .or_else(default_state_dir)
        .ok_or_else(|| anyhow!(catalog().remote_client.known_state_dir_unavailable))?
        .join("client");
    let store = ClientIdentityStore::load_or_create(&client_root)?;
    let async_runtime = tokio_runtime()?;
    let direct_dialer: Option<Arc<dyn Dialer>> =
        match (flags.wireguard_config.take(), flags.wireguard_hub.take()) {
            (Some(path), _) => {
                Some(Arc::new(WireGuardDialer::new(start_wireguard(&async_runtime, &path)?)))
            }
            (None, Some(socket)) => {
                let dialer = SocksDialer::new(socket);
                Some(Arc::new(if flags.wireguard_hub_token_stdin {
                    dialer.with_token(read_hub_token_line(&mut io::stdin().lock())?)
                } else {
                    dialer
                }))
            }
            (None, None) => None,
        };
    let mut relay_routes = client_relay_options(
        flags.route.as_deref(),
        std::mem::take(&mut flags.relay_routes),
        std::mem::take(&mut flags.relay_slots),
        std::mem::take(&mut flags.relay_credentials),
    )?;
    if let Some(invitation) = &invitation {
        let mut invitation_routes = BTreeMap::new();
        for access in &invitation.relay_access {
            let endpoint = parse_route(&access.route, "invitation relay route")?;
            let route = endpoint.to_string();
            let options = RelayClientOptions {
                slot: access.slot.clone(),
                credentials: RelayCredentialSource::static_ticket(access.ticket.clone())?,
            };
            if invitation_routes.insert(route.clone(), options).is_some() {
                return Err(anyhow!(
                    catalog()
                        .remote_client
                        .invitation_relay_route_repeated(&sanitized_route(&endpoint))
                ));
            }
        }
        for (route, options) in invitation_routes {
            relay_routes.entry(route).or_insert(options);
        }
    }
    if relay_routes.len() > MAX_CLIENT_RELAY_ROUTES {
        return Err(anyhow!(catalog().remote_client.relay_route_limit(MAX_CLIENT_RELAY_ROUTES)));
    }
    let ssh = SshProviderConfig {
        ssh_binary: flags.ssh_binary.clone(),
        remote_binary: flags.remote_binary.clone(),
        remote_session: flags.ssh_session.clone(),
        remote_state_dir: flags.remote_state_dir.clone(),
        remote_mux_socket: flags.remote_mux_socket.clone(),
        extra_args: flags.ssh_args.clone(),
        maximum_frame_bytes: crate::remote_runtime::MAX_CARRIER_FRAME_BYTES,
        agent_hooks: flags.agent_hooks.clone(),
    };
    let relay_route_names = relay_routes.keys().cloned().collect::<Vec<_>>();
    let providers = Arc::new(client_provider_registry(
        ssh.clone(),
        relay_routes,
        flags.iroh_path,
        direct_dialer,
        flags.carrier,
    )?);
    let explicit_route = flags.route.take();
    let explicit_route_for_refresh = explicit_route.clone();
    let (route_strings, auth, expected_daemon, known, carrier_auth) = if let Some(invitation) =
        &invitation
    {
        if let Some(fingerprint) = flags.daemon.as_deref()
            && fingerprint != invitation.daemon_fingerprint
        {
            return Err(anyhow!(catalog().remote_client.invitation_daemon_mismatch(fingerprint)));
        }
        let mut routes = Vec::new();
        if let Some(route) = explicit_route {
            push_unique(&mut routes, route);
        }
        for route in &invitation.route_hints {
            push_unique(&mut routes, route.clone());
        }
        if routes.is_empty() {
            return Err(anyhow!(catalog().remote_client.invitation_no_routes));
        }
        (
            routes,
            ClientAuthMode::Invitation {
                id: invitation.id.clone(),
                secret: Zeroizing::new(invitation.secret_bytes()?),
            },
            Some(invitation_daemon_key(invitation)?),
            None,
            false,
        )
    } else if let Some(route) = explicit_route {
        let endpoint = parse_route(&route, "route")?;
        let selected = async_runtime.block_on(select_explicit_route_identity(
            &store,
            flags.daemon.as_deref(),
            &route,
            providers.supported_client_auth(endpoint.scheme())?,
        ))?;
        (
            vec![route],
            selected.auth,
            selected.expected_daemon,
            selected.known,
            selected.carrier_discovery,
        )
    } else {
        let known =
            async_runtime.block_on(select_known_daemon(&store, flags.daemon.as_deref(), None))?;
        if known.route_hints.is_empty() {
            return Err(anyhow!(catalog().remote_client.daemon_no_routes(&known.fingerprint)));
        }
        let key = async_runtime
            .block_on(store.daemon_key(&known.fingerprint))?
            .ok_or_else(|| anyhow!(catalog().remote_client.known_daemon_key_unavailable))?;
        let auth = match known.auth {
            KnownDaemonAuth::Enrolled => ClientAuthMode::Enrolled,
            KnownDaemonAuth::Carrier => ClientAuthMode::Carrier,
        };
        (known.route_hints.clone(), auth, Some(key), Some(known), false)
    };

    let mut routes = resolve_route_candidates(&route_strings, &flags.routing, &providers)?;
    promote_reachable_unix_routes(&mut routes);
    if flags.upgrade && routes.first().is_none_or(|route| route.endpoint.scheme() != "ssh") {
        return Err(anyhow!(catalog().remote_client.upgrade_requires_ssh));
    }
    for route in relay_route_names {
        if !routes.iter().any(|candidate| candidate.endpoint.as_str() == route) {
            let display = parse_route(&route, "relay credential route")
                .map(|route| sanitized_route(&route))
                .unwrap_or_else(|_| "<invalid route>".into());
            return Err(anyhow!(catalog().remote_client.relay_route_not_candidate(&display)));
        }
    }
    let session = SessionId(*uuid::Uuid::new_v4().as_bytes());
    let startup_timeout = remaining_startup_timeout(startup_started, total_startup_timeout)?;
    let ssh_bootstrap = initial_ssh_bootstrap_options(&flags, startup_timeout);
    // A headless link (the app's machine link) outlives a failed first connect: it redials it
    // like a later drop, and its PATH.admin answers meanwhile (cmuxterm-hq#7766). An enrollment
    // keeps its approval window, and an upgrade its one bootstrap.
    let recover_first_connect = flags.headless && invitation.is_none() && !flags.upgrade;
    let options = ClientRuntimeOptions {
        routes,
        providers,
        identity: store.identity(),
        expected_daemon,
        auth,
        device_name: flags.device_name.unwrap_or_else(default_device_name),
        session,
        lane_policy: flags.lanes,
        reconnect: flags.reconnect,
        startup_timeout,
        state_dir: client_root,
        local_socket: flags.local_socket,
        ssh,
        ssh_bootstrap,
    };
    let runtime = if recover_first_connect {
        start_recovering_client_runtime(options, move || owner.is_none_or(parent_process_is))?
    } else {
        start_client_runtime(options)?
    };

    if let Some(invitation) = &invitation {
        async_runtime.block_on(store.pin_daemon(
            invitation.daemon_name.clone(),
            invitation_daemon_key(invitation)?,
            route_strings,
        ))?;
    } else if carrier_auth {
        let name = credential_free_route_hint(&route_strings[0])?;
        async_runtime.block_on(store.pin_carrier_daemon(
            name,
            runtime.info().daemon_public_key,
            route_strings,
        ))?;
    } else if let Some(known) = known {
        if expected_daemon != Some(runtime.info().daemon_public_key) {
            return Err(anyhow!(catalog().remote_client.daemon_key_changed(&known.name)));
        }
        if let Some(route) = explicit_route_for_refresh {
            async_runtime
                .block_on(store.remember_verified_route(&known.fingerprint, &route))?
                .ok_or_else(|| anyhow!(catalog().remote_client.known_daemon_refresh_missing))?;
        }
    }

    let connected_route = runtime.info().route.clone();
    Ok(ConnectedRuntime { runtime, route: connected_route })
}

fn initial_ssh_bootstrap_options(
    flags: &ConnectFlags,
    startup_timeout: Duration,
) -> SshBootstrapOptions {
    SshBootstrapOptions {
        auto_install: flags.auto_install,
        upgrade: flags.upgrade,
        attempt_timeout: startup_timeout,
        forced_command: flags.ssh_forced_command,
    }
}

struct ExplicitRouteIdentity {
    auth: ClientAuthMode,
    expected_daemon: Option<[u8; 32]>,
    known: Option<KnownDaemon>,
    carrier_discovery: bool,
}

async fn select_explicit_route_identity(
    store: &ClientIdentityStore,
    fingerprint: Option<&str>,
    route: &str,
    supported_auth: SupportedClientAuthModes,
) -> anyhow::Result<ExplicitRouteIdentity> {
    if supported_auth == SupportedClientAuthModes::DeviceOrCarrier && fingerprint.is_none() {
        return Ok(ExplicitRouteIdentity {
            auth: ClientAuthMode::Carrier,
            expected_daemon: None,
            known: None,
            carrier_discovery: true,
        });
    }
    let known = select_known_daemon(store, fingerprint, Some(route)).await?;
    if supported_auth != SupportedClientAuthModes::DeviceOrCarrier
        && known.auth == KnownDaemonAuth::Carrier
    {
        return Err(anyhow!(
            catalog().remote_client.carrier_daemon_requires_carrier(&known.fingerprint)
        ));
    }
    let key = store
        .daemon_key(&known.fingerprint)
        .await?
        .ok_or_else(|| anyhow!("known daemon key disappeared"))?;
    Ok(ExplicitRouteIdentity {
        auth: if supported_auth == SupportedClientAuthModes::DeviceOrCarrier {
            ClientAuthMode::Carrier
        } else {
            ClientAuthMode::Enrolled
        },
        expected_daemon: Some(key),
        known: Some(known),
        carrier_discovery: false,
    })
}

fn push_unique(values: &mut Vec<String>, value: String) {
    if !values.iter().any(|existing| existing == &value) {
        values.push(value);
    }
}

fn client_relay_options(
    explicit_route: Option<&str>,
    routes: Vec<String>,
    slots: Vec<String>,
    credentials: Vec<ClientRelayCredentialArg>,
) -> anyhow::Result<BTreeMap<String, RelayClientOptions>> {
    let messages = &catalog().remote_client;
    if slots.len() != credentials.len() {
        return Err(anyhow!(messages.relay_credential_pair_required));
    }
    if routes.is_empty() {
        return match slots.len() {
            0 => Ok(BTreeMap::new()),
            1 => {
                let endpoint = explicit_route
                    .ok_or_else(|| anyhow!(messages.relay_credentials_require_explicit_route))
                    .and_then(|route| parse_route(route, "relay connection route"))?;
                let display = sanitized_route(&endpoint);
                if !is_relay_route(&endpoint) {
                    return Err(anyhow!(messages.relay_shorthand_requires_relay_route(&display)));
                }
                Ok(BTreeMap::from([(
                    endpoint.to_string(),
                    RelayClientOptions {
                        slot: slots.into_iter().next().unwrap(),
                        credentials: client_relay_credential(
                            credentials.into_iter().next().unwrap(),
                        )?,
                    },
                )]))
            }
            _ => Err(anyhow!(messages.multiple_relay_credentials_require_routes)),
        };
    }
    if routes.len() != slots.len() {
        return Err(anyhow!(messages.route_scoped_relay_credential_pair_required));
    }
    if routes.len() > MAX_CLIENT_RELAY_ROUTES {
        return Err(anyhow!(messages.relay_credential_limit(MAX_CLIENT_RELAY_ROUTES)));
    }
    let mut by_route = BTreeMap::new();
    for ((route, slot), credential) in routes.into_iter().zip(slots).zip(credentials) {
        let endpoint = parse_route(&route, "relay credential route")?;
        let display = sanitized_route(&endpoint);
        if !is_relay_route(&endpoint) {
            return Err(anyhow!(messages.relay_route_not_relay(&display)));
        }
        let route = endpoint.to_string();
        let options =
            RelayClientOptions { slot, credentials: client_relay_credential(credential)? };
        if by_route.insert(route.clone(), options).is_some() {
            return Err(anyhow!(messages.relay_route_repeated(&display)));
        }
    }
    Ok(by_route)
}

fn is_relay_route(endpoint: &Url) -> bool {
    matches!(endpoint.scheme(), "relay+ws" | "relay+wss" | "relay+https" | "relay+do")
}

fn client_relay_credential(
    credential: ClientRelayCredentialArg,
) -> anyhow::Result<RelayCredentialSource> {
    match credential {
        ClientRelayCredentialArg::File(path) => Ok(RelayCredentialSource::file(path)),
        ClientRelayCredentialArg::Command { program, args } => {
            Ok(RelayCredentialSource::command(program, args))
        }
    }
}

fn invitation_timeout(invitation: &EnrollmentInvitation) -> Duration {
    let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs();
    let remaining = invitation.expires_at_unix.saturating_sub(now);
    Duration::from_secs(remaining)
        .saturating_add(ENROLLMENT_APPROVAL_TIMEOUT)
        .saturating_add(Duration::from_secs(15))
}

fn remaining_startup_timeout(started: Instant, total: Duration) -> anyhow::Result<Duration> {
    total
        .checked_sub(started.elapsed())
        .filter(|remaining| !remaining.is_zero())
        .ok_or_else(|| anyhow!("remote connection startup timed out after {}s", total.as_secs()))
}

fn promote_reachable_unix_routes(routes: &mut [ResolvedRouteCandidate]) {
    // Cached: the key checks the filesystem, and a socket that appears or goes
    // mid-sort would give one route two keys (sort panics on such orders).
    routes.sort_by_cached_key(|route| {
        match (route.endpoint.scheme(), reachable_unix_route(&route.endpoint)) {
            ("unix", true) => 0,
            ("unix", false) => 2,
            _ => 1,
        }
    });
}

#[cfg(unix)]
fn reachable_unix_route(route: &Url) -> bool {
    use std::os::unix::fs::FileTypeExt;

    route.scheme() == "unix"
        && route
            .to_file_path()
            .ok()
            .and_then(|path| fs::symlink_metadata(path).ok())
            .is_some_and(|metadata| metadata.file_type().is_socket())
}

#[cfg(not(unix))]
fn reachable_unix_route(_: &Url) -> bool {
    false
}

fn run_forward(args: &[String]) -> anyhow::Result<()> {
    let flags = parse_connect_flags(args)?;
    let owner = flags.exit_with_parent.then(current_parent_process_id);
    let workspace_root = flags
        .forward_workspace
        .clone()
        .ok_or_else(|| anyhow!(catalog().remote_client.forward_workspace_required))?;
    let host = flags.forward_host.clone().unwrap_or_else(|| "127.0.0.1".into());
    let port =
        flags.forward_port.ok_or_else(|| anyhow!(catalog().remote_client.forward_port_required))?;
    let listen = flags
        .forward_listen
        .unwrap_or_else(|| "127.0.0.1:0".parse().expect("loopback address is valid"));
    let scheme = flags.forward_scheme.clone();
    let connected = start_connected(flags)?;
    let runtime = tokio_runtime()?;
    let result = runtime.block_on(async {
        let client = WorkspaceClient::connect(connected.runtime.multiplexer().clone()).await?;
        let route = create_loopback_route(&client, workspace_root, host, port).await?;
        let forward =
            LocalPortForward::bind(connected.runtime.multiplexer().clone(), route, listen).await?;
        println!("{}", forward.webview_url(&scheme)?);
        let mut finished = connected.runtime.subscribe_finished();
        let parent_exit = async {
            if let Some(owner) = owner {
                wait_for_parent_exit(owner).await;
            } else {
                std::future::pending::<()>().await;
            }
        };
        tokio::pin!(parent_exit);
        let mut wait_error = None;
        if !crate::shutdown_requested() && !*finished.borrow() {
            tokio::select! {
                biased;
                shutdown = crate::wait_for_shutdown_signal_async() => {
                    if shutdown.is_err() {
                        wait_error = shutdown.err();
                    }
                }
                _ = finished.changed() => {}
                _ = &mut parent_exit => {}
            }
        }
        forward.shutdown().await;
        let _ = tokio::time::timeout(
            FORWARD_CLEANUP_TIMEOUT,
            client.request(WorkspaceRequest::CloseRoute { route }),
        )
        .await;
        if let Some(error) = wait_error {
            return Err(error.into());
        }
        Ok::<_, anyhow::Error>(())
    });
    let shutdown = connected.runtime.shutdown();
    result.and(shutdown)
}

/// Opens `workspace_root` and a [`RoutePolicy::LoopbackOnly`] route to
/// `host:port` in it. The daemon scopes every route to a workspace this
/// client holds open, so a stream that needs no files still opens one; the
/// daemon refuses an address that is not loopback.
async fn create_loopback_route(
    client: &WorkspaceClient,
    workspace_root: String,
    host: String,
    port: u16,
) -> anyhow::Result<RouteId> {
    let workspace =
        match client.request(WorkspaceRequest::OpenWorkspace { root: workspace_root }).await? {
            WorkspaceResponse::Workspace { id, .. } => id,
            _ => return Err(anyhow!("unexpected open-workspace response")),
        };
    match client
        .request(WorkspaceRequest::CreateRoute {
            workspace,
            host,
            port,
            policy: RoutePolicy::LoopbackOnly,
        })
        .await?
    {
        WorkspaceResponse::RouteCreated { route, .. } => Ok(route),
        _ => Err(anyhow!("unexpected create-route response")),
    }
}

#[path = "remote_browser_proxy.rs"]
mod remote_browser_proxy;
#[path = "remote_dial_tcp.rs"]
mod remote_dial_tcp;
#[path = "remote_wg_hub.rs"]
mod remote_wg_hub;
use remote_browser_proxy::{parse_browser_proxy_args, serve_browser_proxy};
use remote_dial_tcp::run_dial_tcp;
use remote_wg_hub::run_wg;

#[derive(Debug, PartialEq, Eq)]
enum RpcInputEvent {
    Line(String),
    End,
    RuntimeFinished,
}

fn run_browser_proxy(args: &[String]) -> anyhow::Result<()> {
    let parsed = parse_browser_proxy_args(args)?;
    let flags = parse_connect_flags(&parsed.connect)?;
    let connected = start_connected(flags)?;
    let runtime = tokio_runtime()?;
    let result = runtime.block_on(serve_browser_proxy(&connected.runtime, parsed));
    let shutdown = connected.runtime.shutdown();
    result.and(shutdown)
}

fn spawn_rpc_stdin_reader() -> anyhow::Result<tokio::sync::mpsc::Receiver<io::Result<String>>> {
    let (sender, receiver) = tokio::sync::mpsc::channel(1);
    let _reader = thread::Builder::new()
        .name("cmux-rpc-stdin".into())
        .spawn(move || {
            let stdin = io::stdin();
            let mut stdin = stdin.lock();
            loop {
                match read_rpc_stdin_line(&mut stdin, MAX_RPC_STDIN_LINE_BYTES) {
                    Ok(Some(line)) => {
                        if sender.blocking_send(Ok(line)).is_err() {
                            break;
                        }
                    }
                    Ok(None) => break,
                    Err(error) => {
                        let _ = sender.blocking_send(Err(error));
                        break;
                    }
                }
            }
        })
        .context("could not start RPC stdin reader")?;
    Ok(receiver)
}

fn read_rpc_stdin_line<R: BufRead>(reader: &mut R, maximum: usize) -> io::Result<Option<String>> {
    let bounded = maximum.checked_add(1).ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidInput, "RPC stdin line limit is too large")
    })?;
    let mut bytes = Vec::new();
    let read = (&mut *reader)
        .take(u64::try_from(bounded).unwrap_or(u64::MAX))
        .read_until(b'\n', &mut bytes)?;
    if read == 0 {
        return Ok(None);
    }

    if bytes.last() == Some(&b'\n') {
        bytes.pop();
        if bytes.last() == Some(&b'\r') {
            bytes.pop();
        }
    } else if bytes.len() > maximum {
        if bytes.len() == bounded && bytes.last() == Some(&b'\r') {
            let pending = reader.fill_buf()?;
            if pending.first() == Some(&b'\n') {
                reader.consume(1);
                bytes.pop();
            } else {
                return Err(rpc_stdin_line_too_large(maximum));
            }
        } else {
            return Err(rpc_stdin_line_too_large(maximum));
        }
    }
    if bytes.len() > maximum {
        return Err(rpc_stdin_line_too_large(maximum));
    }
    String::from_utf8(bytes).map(Some).map_err(|_| {
        io::Error::new(io::ErrorKind::InvalidData, catalog().remote_client.rpc_stdin_invalid_utf8)
    })
}

fn rpc_stdin_line_too_large(maximum: usize) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, catalog().remote_client.rpc_stdin_too_large(maximum))
}

async fn next_rpc_input(
    input: &mut tokio::sync::mpsc::Receiver<io::Result<String>>,
    finished: &mut tokio::sync::watch::Receiver<bool>,
) -> anyhow::Result<RpcInputEvent> {
    if *finished.borrow() {
        return Ok(RpcInputEvent::RuntimeFinished);
    }
    tokio::select! {
        biased;
        _ = finished.changed() => Ok(RpcInputEvent::RuntimeFinished),
        line = input.recv() => match line {
            Some(Ok(line)) => Ok(RpcInputEvent::Line(line)),
            Some(Err(error)) => Err(error.into()),
            None => Ok(RpcInputEvent::End),
        },
    }
}

/// `cmux rpc action.list '{}'`: the old cmux's app socket call, which agents still write
/// (tests/tool-evals r4a: GPT 6 Astra ran it 54 times). Here `rpc` is a remote session's
/// workspace RPC and would wait for a daemon, so such a call names the app commands instead.
/// A route host (`box.local`) is not one: the method's last word is a verb, or JSON follows.
fn app_method_call(args: &[String]) -> bool {
    let Some(method) = args.first() else { return false };
    let words: Vec<&str> = method.split('.').collect();
    let shaped = words.len() >= 2
        && words.iter().all(|word| {
            !word.is_empty() && word.bytes().all(|b| b.is_ascii_lowercase() || b == b'_')
        });
    let verb = matches!(
        words.last().copied(),
        Some(
            "list"
                | "get"
                | "run"
                | "describe"
                | "search"
                | "request"
                | "call"
                | "ping"
                | "identify"
        )
    );
    shaped && (verb || args.get(1).is_some_and(|next| next.trim_start().starts_with('{')))
}

fn run_rpc(args: &[String]) -> anyhow::Result<()> {
    if let Some(method) = args.first().filter(|_| app_method_call(args)) {
        return Err(anyhow!(catalog().local_server.unknown_scope(
            &format!("rpc {method}"),
            Some("cmux action list` / `cmux action run <id>` (app actions), `cmux app identify"),
        )));
    }
    let mut flags = parse_connect_flags(args)?;
    let single = flags.rpc_request.take();
    let connected = start_connected(flags)?;
    let runtime = tokio_runtime()?;
    let result = runtime.block_on(async {
        let client = WorkspaceClient::connect(connected.runtime.multiplexer().clone()).await?;
        if let Some(encoded) = single {
            let request: WorkspaceRequest = serde_json::from_str(&encoded)
                .map_err(|_| anyhow!(catalog().remote_client.rpc_request_invalid))?;
            let response = client.request(request).await?;
            println!("{}", serde_json::to_string(&response)?);
            return Ok::<_, anyhow::Error>(());
        }
        let mut input = spawn_rpc_stdin_reader()?;
        let mut finished = connected.runtime.subscribe_finished();
        while let RpcInputEvent::Line(line) = next_rpc_input(&mut input, &mut finished).await? {
            if line.trim().is_empty() {
                continue;
            }
            let request: WorkspaceRequest = serde_json::from_str(&line)
                .map_err(|_| anyhow!(catalog().remote_client.rpc_input_invalid))?;
            let response = client.request(request).await?;
            println!("{}", serde_json::to_string(&response)?);
        }
        Ok(())
    });
    let shutdown = connected.runtime.shutdown();
    result.and(shutdown)
}

fn run_ssh(
    args: &[String],
    load_config: impl FnOnce() -> crate::config::StartupConfigSnapshot,
) -> anyhow::Result<()> {
    connect_with_flags(direct_ssh_flags(args)?, load_config)
}

fn direct_ssh_flags(args: &[String]) -> anyhow::Result<ConnectFlags> {
    let destination = args
        .first()
        .filter(|argument| !argument.starts_with('-'))
        .cloned()
        .ok_or_else(|| anyhow!(catalog().remote_client.ssh_destination_required))?;
    let mut flags = parse_connect_flags(args)?;
    flags.route = Some(ssh_url(&destination)?);
    if !flags.lanes_explicit {
        // `cmux-tui ssh` should behave like direct SSH by default: one SSH
        // process carrying all logical lanes. Users can opt into isolated
        // carriers with `--lanes isolated`.
        flags.lanes = LanePolicy::Single;
    }

    Ok(flags)
}

/// Programmatic equivalent of `cmux-tui ssh`, used by the native machine
/// rail so both entrypoints share compatibility checks, daemon startup, and
/// reconnect behavior.
pub(crate) struct ManagedSshOptions {
    pub destination: String,
    pub session: String,
    pub remote_binary: String,
    pub ssh_args: Vec<String>,
}

pub(crate) struct ManagedSshConnection {
    pub session: Session,
    pub lease: ManagedSshLease,
}

/// Keeps the local bridge and its reconnecting SSH client alive for as long
/// as the selected machine session owns it.
pub(crate) struct ManagedSshLease {
    runtime: Option<crate::remote_runtime::ClientRuntimeHandle>,
}

impl Drop for ManagedSshLease {
    fn drop(&mut self) {
        if let Some(runtime) = self.runtime.take() {
            let _ = runtime.shutdown();
        }
    }
}

pub(crate) fn validate_managed_ssh_options(options: &ManagedSshOptions) -> anyhow::Result<()> {
    ssh_url(&options.destination)?;
    SshProvider::new(SshProviderConfig {
        ssh_binary: "ssh".into(),
        remote_binary: options.remote_binary.clone(),
        remote_session: options.session.clone(),
        remote_state_dir: None,
        remote_mux_socket: None,
        extra_args: options.ssh_args.clone(),
        maximum_frame_bytes: crate::remote_runtime::MAX_CARRIER_FRAME_BYTES,
        agent_hooks: Vec::new(),
    })?;
    Ok(())
}

pub(crate) fn connect_managed_ssh(
    options: ManagedSshOptions,
) -> anyhow::Result<ManagedSshConnection> {
    let mut arguments = vec![
        options.destination,
        "--session".into(),
        options.session,
        "--remote-binary".into(),
        options.remote_binary,
    ];
    for argument in options.ssh_args {
        arguments.push("--ssh-arg".into());
        arguments.push(argument);
    }

    let connected = start_connected(direct_ssh_flags(&arguments)?)?;
    let local_socket = connected.runtime.info().local_socket.clone();
    match RemoteSession::connect(&local_socket) {
        Ok(remote) => Ok(ManagedSshConnection {
            session: Session::Remote(remote),
            lease: ManagedSshLease { runtime: Some(connected.runtime) },
        }),
        Err(connect_error) => {
            let cleanup_error = connected.runtime.shutdown().err();
            match cleanup_error {
                Some(cleanup_error) => Err(connect_error.context(cleanup_error)),
                None => Err(connect_error),
            }
        }
    }
}

fn ssh_url(destination: &str) -> anyhow::Result<String> {
    if destination.starts_with('-') || destination.bytes().any(|byte| byte.is_ascii_whitespace()) {
        return Err(anyhow!(catalog().remote_client.ssh_destination_invalid));
    }
    let url = format!("ssh://{destination}");
    Url::parse(&url).map_err(|_| anyhow!(catalog().remote_client.ssh_destination_invalid))?;
    Ok(url)
}

fn require_unique_flag(
    seen: &mut BTreeSet<&'static str>,
    option: &'static str,
) -> anyhow::Result<()> {
    if !seen.insert(option) {
        return Err(anyhow!(catalog().remote_client.option_once(option)));
    }
    Ok(())
}

fn strict_option_value(args: &[String], index: &mut usize, option: &str) -> anyhow::Result<String> {
    let value = args.get(*index).filter(|value| !value.starts_with("--")).cloned();
    let Some(value) = value else {
        return Err(anyhow!(catalog().remote_client.option_needs_value(option)));
    };
    *index += 1;
    Ok(value)
}

#[cfg(unix)]
fn current_parent_process_id() -> u32 {
    unsafe { libc::getppid() }.try_into().unwrap_or_default()
}

#[cfg(not(unix))]
fn current_parent_process_id() -> u32 {
    0
}

#[cfg(unix)]
fn parent_process_is(expected: u32) -> bool {
    current_parent_process_id() == expected
}

#[cfg(not(unix))]
fn parent_process_is(_: u32) -> bool {
    true
}

/// Returns when the process `expected` (our parent at launch) exits. It
/// waits on a kernel process-exit event (kqueue `NOTE_EXIT`, Linux pidfd,
/// `acpmux::parent_watch`); it used to re-check `getppid` every 100 ms.
/// Kernels without pidfd keep the old check as a fallback.
///
/// The kernel wait runs on a detached thread, not tokio's blocking pool: a
/// blocking task cannot be cancelled, so a runtime shut down by a signal
/// would wait for the parent to exit before the process could.
async fn wait_for_parent_exit(expected: u32) {
    if !parent_process_is(expected) {
        return;
    }
    let (sender, receiver) = tokio::sync::oneshot::channel();
    let waiter = thread::Builder::new().name("cmux-parent-exit".into()).spawn(move || {
        let _ = sender.send(acpmux::parent_watch::wait_for_parent(expected));
    });
    if waiter.is_ok() && matches!(receiver.await, Ok(Ok(()))) {
        return;
    }
    while parent_process_is(expected) {
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

/// A wg-quick file is small; anything larger is not one.
const MAX_WIREGUARD_CONFIG_BYTES: usize = 16 * 1024;

/// Bring up the in-process WireGuard tunnel named by `--wireguard-config`.
///
/// The file holds a private key, so it must be owner-only like an invitation
/// file. The tunnel lives as long as the provider registry that holds it, which
/// is the life of this `remote connect` process.
fn start_wireguard(
    runtime: &tokio::runtime::Runtime,
    path: &Path,
) -> anyhow::Result<Arc<cmux_wg::WgNet>> {
    let mut config = read_wireguard_config(path)?;
    config.ultra = ultra_setting();
    let net = runtime.block_on(cmux_wg::WgNet::start_with_new_socket(config)).map_err(|error| {
        anyhow!(catalog().remote_client.wireguard_start_failed(&error.to_string()))
    })?;
    Ok(Arc::new(net))
}

/// The ultra mode Settings asks for (`remote.ultraMode`, read at each tunnel
/// start); `CMUX_WG_ULTRA` still wins over it ([`cmux_wg::UltraMode::resolve`]).
fn ultra_setting() -> Option<cmux_wg::UltraMode> {
    cmux_tui_core::user_settings::ultra_mode().then_some(cmux_wg::UltraMode::SETTING)
}

fn read_wireguard_config(path: &Path) -> anyhow::Result<cmux_wg::WgConfig> {
    let text = cmux_remote::secret_file::read_owner_only_string(path, MAX_WIREGUARD_CONFIG_BYTES)
        .map_err(|error| {
        anyhow!(
            catalog()
                .remote_client
                .wireguard_config_unreadable(&path.display().to_string(), &error.to_string())
        )
    })?;
    cmux_wg::WgConfig::parse_wg_quick(&text).map_err(|error| {
        anyhow!(catalog().remote_client.wireguard_config_invalid(&error.to_string()))
    })
}

/// Longest hub client token accepted on stdin: SOCKS5's password field.
const MAX_HUB_TOKEN_BYTES: usize = 255;

/// One line from `reader` holding the hub's client token.
fn read_hub_token_line(
    reader: &mut impl Read,
) -> anyhow::Result<cmux_remote::provider::HubClientToken> {
    let mut bytes = Zeroizing::new(Vec::with_capacity(80));
    let mut byte = [0_u8; 1];
    while reader.read(&mut byte).context(catalog().remote_client.hub_token_invalid)? == 1 {
        if byte[0] == b'\n' {
            break;
        }
        if bytes.len() == MAX_HUB_TOKEN_BYTES {
            return Err(anyhow!(catalog().remote_client.hub_token_invalid));
        }
        bytes.push(byte[0]);
    }
    let text = std::str::from_utf8(&bytes)
        .map_err(|_| anyhow!(catalog().remote_client.hub_token_invalid))?
        .trim_end_matches('\r');
    cmux_remote::provider::HubClientToken::new(text)
        .ok_or_else(|| anyhow!(catalog().remote_client.hub_token_invalid))
}

fn read_invitation_uri(path: &Path) -> anyhow::Result<Zeroizing<String>> {
    if path == Path::new("-") {
        return read_invitation_uri_line(&mut io::stdin().lock());
    }

    let bytes = cmux_remote::secret_file::read_owner_only(path, MAX_INVITATION_URI_BYTES + 2)
        .map_err(|_| anyhow!(catalog().remote_client.invitation_path_invalid))?;
    normalize_invitation_uri(bytes)
}

#[cfg(test)]
fn read_invitation_uri_to_end(reader: &mut impl Read) -> anyhow::Result<Zeroizing<String>> {
    let mut bytes = Zeroizing::new(Vec::with_capacity(MAX_INVITATION_URI_BYTES.min(4096)));
    reader
        .take((MAX_INVITATION_URI_BYTES + 3) as u64)
        .read_to_end(&mut bytes)
        .context(catalog().remote_client.invitation_input_read_failed)?;
    normalize_invitation_uri(bytes)
}

fn read_invitation_uri_line(reader: &mut impl Read) -> anyhow::Result<Zeroizing<String>> {
    let mut bytes = Zeroizing::new(Vec::with_capacity(1024));
    loop {
        let mut byte = [0_u8; 1];
        match reader
            .read(&mut byte)
            .context(catalog().remote_client.invitation_input_read_failed)?
        {
            0 => break,
            _ => {
                bytes.push(byte[0]);
                if byte[0] == b'\n' {
                    break;
                }
                if bytes.len() > MAX_INVITATION_URI_BYTES + 2 {
                    return Err(anyhow!(
                        catalog()
                            .remote_client
                            .invitation_input_too_large(MAX_INVITATION_URI_BYTES)
                    ));
                }
            }
        }
    }
    normalize_invitation_uri(bytes)
}

fn normalize_invitation_uri(mut bytes: Zeroizing<Vec<u8>>) -> anyhow::Result<Zeroizing<String>> {
    if bytes.last() == Some(&b'\n') {
        bytes.pop();
        if bytes.last() == Some(&b'\r') {
            bytes.pop();
        }
    }
    if bytes.is_empty() {
        return Err(anyhow!(catalog().remote_client.invitation_input_empty));
    }
    if bytes.len() > MAX_INVITATION_URI_BYTES {
        return Err(anyhow!(
            catalog().remote_client.invitation_input_too_large(MAX_INVITATION_URI_BYTES)
        ));
    }
    if bytes.iter().any(|byte| matches!(byte, b'\r' | b'\n')) {
        return Err(anyhow!(catalog().remote_client.invitation_input_multiline));
    }
    let bytes = std::mem::take(&mut *bytes);
    match String::from_utf8(bytes) {
        Ok(uri) => Ok(Zeroizing::new(uri)),
        Err(error) => {
            let _invalid_bytes = Zeroizing::new(error.into_bytes());
            Err(anyhow!(catalog().remote_client.invitation_input_invalid_utf8))
        }
    }
}

struct RemoteLinkArgs {
    session: String,
    state_dir: Option<PathBuf>,
    mux_socket: Option<PathBuf>,
    link_socket: Option<PathBuf>,
    agent_hooks: Option<String>,
}

/// Strict: an unknown flag is an error, never skipped. An older remote that
/// skipped `--mux-socket` attached to its default daemon (cx-z3zh); a flag
/// this build does not know means the client is newer, so refuse loudly.
/// A new flag also gets a `remote-probe` capability
/// (`SshProviderConfig::required_remote_capabilities`).
fn parse_remote_link_args(args: &[String]) -> anyhow::Result<RemoteLinkArgs> {
    let mut parsed = RemoteLinkArgs {
        session: "main".into(),
        state_dir: None,
        mux_socket: None,
        link_socket: None,
        agent_hooks: None,
    };
    let mut stdio = false;
    let mut seen = BTreeSet::new();
    let mut index = 0;
    while index < args.len() {
        let argument = args[index].as_str();
        index += 1;
        match argument {
            "--stdio" => {
                require_unique_flag(&mut seen, "--stdio")?;
                stdio = true;
            }
            "--session" => {
                require_unique_flag(&mut seen, "--session")?;
                parsed.session = strict_option_value(args, &mut index, "--session")?;
            }
            "--state-dir" => {
                require_unique_flag(&mut seen, "--state-dir")?;
                parsed.state_dir =
                    Some(strict_option_value(args, &mut index, "--state-dir")?.into());
            }
            "--mux-socket" => {
                require_unique_flag(&mut seen, "--mux-socket")?;
                parsed.mux_socket =
                    Some(strict_option_value(args, &mut index, "--mux-socket")?.into());
            }
            "--link-socket" => {
                require_unique_flag(&mut seen, "--link-socket")?;
                parsed.link_socket =
                    Some(strict_option_value(args, &mut index, "--link-socket")?.into());
            }
            "--agent-hooks" => {
                require_unique_flag(&mut seen, "--agent-hooks")?;
                parsed.agent_hooks = Some(strict_option_value(args, &mut index, "--agent-hooks")?);
            }
            other => {
                return Err(anyhow!(catalog().remote_client.remote_link_unknown_option(other)));
            }
        }
    }
    if !stdio {
        return Err(anyhow!("remote-link currently requires --stdio"));
    }
    Ok(parsed)
}

fn run_remote_link(args: &[String]) -> anyhow::Result<()> {
    let RemoteLinkArgs { session, state_dir, mux_socket, link_socket, agent_hooks } =
        parse_remote_link_args(args)?;
    // A link with its own state directory keeps its client log there too,
    // never in the user's default state root (cx-bduj).
    if let Some(root) = state_dir.as_deref() {
        crate::client_log::use_path(root.join("client.log"));
    }
    if let Some(providers) = agent_hooks {
        install_agent_hooks(agent_hook_providers(&providers));
    }
    let link_at = |state_dir: Option<&Path>| -> anyhow::Result<UnixStream> {
        let (session_state, default_link, _) = daemon_paths(&session, state_dir)?;
        let link = link_socket.clone().unwrap_or(default_link);
        ensure_daemon(&session, state_dir, &session_state, &link, mux_socket.as_deref())
    };
    // A link that names nothing of its own (no state directory, socket or
    // mux socket) may keep its session in a private root when another
    // daemon of this machine owns the session on the default root.
    let private = (state_dir.is_none()
        && mux_socket.is_none()
        && link_socket.is_none()
        && std::env::var_os("CMUX_MUX_SOCKET").is_none())
    .then(private_link_root)
    .flatten();
    let stream = match (state_dir.as_deref(), private.as_deref()) {
        (None, Some(private)) if remote_link_mux::mux_state_root(private).exists() => {
            link_at(Some(private))?
        }
        (None, Some(private)) => match link_at(None) {
            Err(error) if error.downcast_ref::<SessionInUse>().is_some() => {
                eprintln!(
                    "cmux-tui: another daemon on this machine owns session {session}; this link keeps it in {}",
                    private.display()
                );
                if let Some(default_root) = cmux_tui_core::platform::workspace_state_dir()
                    && let Err(error) =
                        cmux_tui_core::session_state_import::decline_default_root_import(
                            &default_root,
                            &remote_link_mux::mux_state_root(private),
                            &session,
                        )
                {
                    eprintln!("cmux-tui: could not keep the private session empty: {error:#}");
                }
                link_at(Some(private))?
            }
            other => other?,
        },
        (state_dir, _) => link_at(state_dir)?,
    };
    let runtime = tokio_runtime()?;
    let result = runtime.block_on(proxy_stdio(stream));
    // Tokio reads stdin on a blocking thread that cannot be cancelled: when
    // the link side ended first, do not wait for the next byte on stdin
    // before exiting (cx-bj1o review).
    runtime.shutdown_background();
    result
}

/// `--agent-hooks claude,codex` names providers; empty items are dropped.
fn agent_hook_providers(value: &str) -> Vec<String> {
    value.split(',').map(str::trim).filter(|item| !item.is_empty()).map(str::to_owned).collect()
}

/// Installs the named providers' hooks for this host user before a client
/// attaches. The install is idempotent and never blocks the link: hooks are
/// inert outside cmux-tui terminals, and a failure only costs agent status.
fn install_agent_hooks(providers: Vec<String>) {
    if providers.is_empty() {
        return;
    }
    let plan = crate::agent_hook_install::Plan {
        action: crate::agent_hook_install::Action::Install,
        providers,
    };
    let result = crate::agent_hook_install::run(&plan);
    if result.failed {
        crate::client_log::stderr_log!(
            "remote",
            "{BIN}: agent hook install failed: {}",
            result.value["errors"]
        );
    }
}

async fn proxy_stdio(stream: UnixStream) -> anyhow::Result<()> {
    stream.set_nonblocking(true)?;
    proxy_connected_stdio_with_io(
        tokio::net::UnixStream::from_std(stream)?,
        tokio::io::stdin(),
        tokio::io::stdout(),
    )
    .await
}

#[cfg(test)]
async fn proxy_stdio_with_io<R, W, V>(
    link: &Path,
    stdin: R,
    stdout: W,
    verify_peer: V,
) -> anyhow::Result<()>
where
    R: tokio::io::AsyncRead + Unpin,
    W: tokio::io::AsyncWrite + Unpin,
    V: FnOnce(&tokio::net::UnixStream) -> Result<(), UnixPeerAuthError>,
{
    let stream = tokio::net::UnixStream::connect(link).await?;
    verify_peer(&stream)?;
    proxy_connected_stdio_with_io(stream, stdin, stdout).await
}

async fn proxy_connected_stdio_with_io<R, W>(
    stream: tokio::net::UnixStream,
    mut stdin: R,
    mut stdout: W,
) -> anyhow::Result<()>
where
    R: tokio::io::AsyncRead + Unpin,
    W: tokio::io::AsyncWrite + Unpin,
{
    use tokio::io::{AsyncWriteExt, copy};
    let (mut socket_read, mut socket_write) = stream.into_split();
    let upload = async {
        copy(&mut stdin, &mut socket_write).await?;
        socket_write.shutdown().await
    };
    let download = async {
        copy(&mut socket_read, &mut stdout).await?;
        stdout.shutdown().await
    };
    // The SSH carrier is the link: when stdin ends (the client or sshd went
    // away), nothing reads stdout anymore either. Waiting for the sidecar to
    // close its side kept this process alive, re-parented to pid 1, with the
    // link socket open, so the daemon never started the resume lease and the
    // browser runtimes of the link's streams lived on (cx-bj1o). Either side
    // ending now ends the relay; dropping the socket closes the link, and the
    // daemon keeps terminals and resumable streams for its resume lease.
    tokio::select! {
        result = upload => result?,
        result = download => result?,
    }
    Ok(())
}

async fn select_known_daemon(
    store: &ClientIdentityStore,
    fingerprint: Option<&str>,
    route: Option<&str>,
) -> anyhow::Result<KnownDaemon> {
    let daemons = store.known_daemons().await;
    if let Some(fingerprint) = fingerprint {
        return daemons
            .into_iter()
            .find(|daemon| daemon.fingerprint == fingerprint)
            .ok_or_else(|| anyhow!("daemon {fingerprint:?} is not known"));
    }
    let route = route.and_then(|route| credential_free_route_hint(route).ok());
    let matching = daemons
        .iter()
        .filter(|daemon| {
            route.as_ref().is_some_and(|route| daemon.route_hints.iter().any(|hint| hint == route))
        })
        .cloned()
        .collect::<Vec<_>>();
    match matching.as_slice() {
        [daemon] => Ok(daemon.clone()),
        [] if daemons.len() == 1 => Ok(daemons[0].clone()),
        [] if route.is_some() => {
            Err(anyhow!("no known daemon matches this route; connect with an invitation"))
        }
        [] if daemons.len() > 1 => Err(anyhow!("multiple known daemons; use --daemon FINGERPRINT")),
        [] => Err(anyhow!("no known daemons; connect with an invitation or trusted carrier")),
        _ => Err(anyhow!("multiple known daemons match this route; use --daemon FINGERPRINT")),
    }
}

fn parse_route(route: &str, description: &str) -> anyhow::Result<Url> {
    Url::parse(route).with_context(|| format!("invalid {description}"))
}

fn invitation_daemon_key(invitation: &EnrollmentInvitation) -> anyhow::Result<[u8; 32]> {
    let bytes =
        base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(&invitation.daemon_public_key)?;
    bytes.try_into().map_err(|bytes: Vec<u8>| anyhow!("daemon key has {} bytes", bytes.len()))
}

fn resolve_route_candidates(
    routes: &[String],
    iroh_routing: &BTreeMap<String, String>,
    providers: &cmux_remote::provider::ProviderRegistry,
) -> anyhow::Result<Vec<ResolvedRouteCandidate>> {
    let mut candidates = Vec::new();
    let mut unsupported_schemes = BTreeSet::new();
    for route in routes {
        let mut endpoint = parse_route(route, "route")?;
        let mut routing =
            if endpoint.scheme() == "iroh" { iroh_routing.clone() } else { BTreeMap::new() };
        extract_iroh_routing(&mut endpoint, &mut routing)?;
        match ResolvedRouteCandidate::resolve(endpoint, routing, providers) {
            Ok(candidate) if !candidates.contains(&candidate) => candidates.push(candidate),
            Ok(_) => {}
            Err(ProviderError::UnsupportedScheme(scheme)) => {
                unsupported_schemes.insert(scheme);
            }
            Err(error) => return Err(error.into()),
        }
    }
    if candidates.is_empty() && !unsupported_schemes.is_empty() {
        let schemes = unsupported_schemes
            .into_iter()
            .map(|scheme| format!("{scheme:?}"))
            .collect::<Vec<_>>()
            .join(", ");
        return Err(anyhow!("no local transport provider supports route scheme(s): {schemes}"));
    }
    Ok(candidates)
}

fn extract_iroh_routing(
    endpoint: &mut Url,
    routing: &mut BTreeMap<String, String>,
) -> anyhow::Result<()> {
    if endpoint.scheme() != "iroh" {
        return Ok(());
    }
    let query = endpoint.query_pairs().into_owned().collect::<Vec<_>>();
    endpoint.set_query(None);
    for (key, value) in query {
        let routing_key = match key.as_str() {
            "node_id" => ROUTING_NODE_ID,
            "relay" | "relay_url" => ROUTING_RELAY_URL,
            "direct" | "direct_addrs" => ROUTING_DIRECT_ADDRS,
            _ => return Err(anyhow!("Iroh route contains an unsupported parameter")),
        };
        routing.entry(routing_key.into()).or_insert(value);
    }
    Ok(())
}

fn default_device_name() -> String {
    std::env::var("HOSTNAME")
        .or_else(|_| std::env::var("COMPUTERNAME"))
        .unwrap_or_else(|_| format!("cmux-client-{}", std::process::id()))
}

fn tokio_runtime() -> anyhow::Result<tokio::runtime::Runtime> {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .context("could not start Tokio runtime")
}

fn flag_value(args: &[String], flag: &str) -> Option<String> {
    args.windows(2).find(|pair| pair[0] == flag).map(|pair| pair[1].clone())
}

fn expand_home(path: String) -> anyhow::Result<PathBuf> {
    if path == "~" {
        return std::env::var_os("HOME").map(PathBuf::from).ok_or_else(|| anyhow!("HOME is unset"));
    }
    if let Some(suffix) = path.strip_prefix("~/") {
        return std::env::var_os("HOME")
            .map(|home| PathBuf::from(home).join(suffix))
            .ok_or_else(|| anyhow!("HOME is unset"));
    }
    Ok(PathBuf::from(OsString::from(path)))
}

#[cfg(test)]
#[path = "remote_cli_tests.rs"]
mod tests;
