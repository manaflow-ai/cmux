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

use anyhow::{Context, anyhow};
use base64::Engine;
use cmux_remote::admin::{
    AdminRequest, AdminResponse, UnixPeerAuthError, call_admin, call_admin_with_peer_exit,
    verify_unix_peer_owner,
};
use cmux_remote::bridge::LocalPortForward;
use cmux_remote::client::WorkspaceClient;
use cmux_remote::connection::ReconnectPolicy;
use cmux_remote::crypto::ClientAuthMode;
use cmux_remote::identity::{
    ClientIdentityStore, EnrollmentInvitation, EnrollmentRelayAccess, KnownDaemon, KnownDaemonAuth,
    MAX_INVITATION_URI_BYTES, credential_free_route_hint, default_state_dir,
};
use cmux_remote::provider::{
    IrohPathMode, ProviderError, ROUTING_DIRECT_ADDRS, ROUTING_NODE_ID, ROUTING_RELAY_URL,
    RelayCredentialSource, SshProvider, SshProviderConfig, SupportedClientAuthModes,
    sanitized_route,
};
use cmux_remote::secure_directory::{DirectoryAccess, ensure_secure_directory};
use cmux_remote::ssh_bootstrap::{BUILD_IDENTITY, DISTRIBUTION_VERSION, NPM_BOOTSTRAP_VERSION};
use cmux_remote_protocol::{
    LanePolicy, REMOTE_PROTOCOL_VERSION, RoutePolicy, SessionId, WorkspaceRequest,
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
};
use crate::session::{RemoteSession, Session};

const DEFAULT_STARTUP_TIMEOUT: Duration = Duration::from_secs(90);
const ENROLLMENT_APPROVAL_TIMEOUT: Duration = Duration::from_secs(5 * 60);
const MAX_RPC_STDIN_LINE_BYTES: usize = 16 * 1024 * 1024;
const MAX_CLIENT_RELAY_ROUTES: usize = 4;
const DETACHED_TERM_GRACE: Duration = Duration::from_millis(500);
const DETACHED_KILL_GRACE: Duration = Duration::from_secs(1);

pub fn is_remote_invocation(args: &[String]) -> bool {
    crate::cli::is_remote_invocation(args)
}

pub fn run(args: &[String], usage: &str) -> i32 {
    match run_inner(args, usage) {
        Ok(()) => 0,
        Err(error) => {
            crate::client_log::stderr_log!("remote", "cmux-tui: {error:#}");
            1
        }
    }
}

fn run_inner(args: &[String], usage: &str) -> anyhow::Result<()> {
    if remote_help_requested(&args[1..]) {
        print!("{}", remote_help(args.first().map(String::as_str)));
        return Ok(());
    }
    match args.first().map(String::as_str) {
        Some("connect") => run_connect(&args[1..], None),
        Some("ssh") => run_ssh(&args[1..]),
        Some("forward") => run_forward(&args[1..]),
        Some("rpc") => run_rpc(&args[1..]),
        Some("enroll") => run_enroll(&args[1..]),
        Some("known-daemons") => run_known_daemons(&args[1..]),
        Some("remote-probe") => run_probe(&args[1..]),
        Some("remote-link") => run_remote_link(&args[1..]),
        Some("remote-sidecar") => run_remote_sidecar(&args[1..]),
        Some("remote-stop") => run_remote_stop(&args[1..]),
        Some("install-self") => run_install_self(&args[1..]),
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
        Some("rpc") => client.rpc_help,
        Some("enroll") => client.enroll_help,
        Some("known-daemons") => client.known_daemons_help,
        Some("remote-probe") => client.remote_probe_help,
        Some("remote-link") => client.remote_link_help,
        Some("remote-stop") => catalog().remote.remote_stop_help,
        Some("install-self") => client.install_self_help,
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
    headless: bool,
    json: bool,
    ssh_session: String,
    ssh_binary: String,
    remote_binary: String,
    remote_state_dir: Option<String>,
    ssh_args: Vec<String>,
    auto_install: bool,
    upgrade: bool,
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
                let attempts = value("--reconnect-attempts")?;
                flags.reconnect.maximum_attempts = if attempts == "unlimited" {
                    None
                } else {
                    let attempts = attempts.parse::<u32>().map_err(|_| {
                        anyhow!(
                            catalog()
                                .remote_client
                                .invalid_option_value("--reconnect-attempts", "N|unlimited")
                        )
                    })?;
                    if attempts == 0 {
                        return Err(anyhow!(
                            catalog().remote_client.option_must_be_positive("--reconnect-attempts")
                        ));
                    }
                    Some(attempts)
                };
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
            "--headless" => flags.headless = true,
            "--json" => flags.json = true,
            "--session" => flags.ssh_session = value("--session")?,
            "--ssh-binary" => flags.ssh_binary = value("--ssh-binary")?,
            "--remote-binary" => flags.remote_binary = value("--remote-binary")?,
            "--remote-state-dir" => {
                flags.remote_state_dir = Some(value("--remote-state-dir")?);
            }
            "--ssh-arg" => flags.ssh_args.push(value("--ssh-arg")?),
            "--no-install" => flags.auto_install = false,
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
                return Err(anyhow!(catalog().remote_client.unknown_option(option)));
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
    if flags.json && !flags.headless {
        return Err(anyhow!(catalog().remote_client.json_requires_headless));
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

fn run_connect(args: &[String], preset_route: Option<String>) -> anyhow::Result<()> {
    let mut flags = parse_connect_flags(args)?;
    if preset_route.is_some() {
        flags.route = preset_route;
    }
    connect_with_flags(flags)
}

fn connect_with_flags(flags: ConnectFlags) -> anyhow::Result<()> {
    let headless = flags.headless;
    let json = flags.json;
    let connected = start_connected(flags)?;
    if headless {
        if json {
            let runtime = tokio_runtime()?;
            runtime.block_on(async {
                let mut previous = None;
                let mut finished = connected.runtime.subscribe_finished();
                while !crate::shutdown_requested() && !connected.runtime.is_finished() {
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
                Ok::<_, io::Error>(())
            })?;
        } else {
            println!("{}", connected.runtime.info().local_socket.display());
            while !crate::shutdown_requested() && !connected.runtime.is_finished() {
                thread::sleep(Duration::from_millis(100));
            }
        }
        return connected.runtime.shutdown();
    }

    let remote = RemoteSession::connect(&connected.runtime.info().local_socket)?;
    let result = crate::run_tui(Session::Remote(remote), connected.route, None);
    let shutdown = connected.runtime.shutdown();
    result.and(shutdown)
}

struct ConnectedRuntime {
    runtime: crate::remote_runtime::ClientRuntimeHandle,
    route: String,
}

fn start_connected(mut flags: ConnectFlags) -> anyhow::Result<ConnectedRuntime> {
    let startup_started = Instant::now();
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
        extra_args: flags.ssh_args.clone(),
        maximum_frame_bytes: crate::remote_runtime::MAX_CARRIER_FRAME_BYTES,
    };
    let relay_route_names = relay_routes.keys().cloned().collect::<Vec<_>>();
    let providers = Arc::new(client_provider_registry(ssh.clone(), relay_routes, flags.iroh_path)?);
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
    let runtime = start_client_runtime(ClientRuntimeOptions {
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
    })?;

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
    routes.sort_by_key(|route| {
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
        let workspace =
            match client.request(WorkspaceRequest::OpenWorkspace { root: workspace_root }).await? {
                WorkspaceResponse::Workspace { id, .. } => id,
                _ => return Err(anyhow!("unexpected open-workspace response")),
            };
        let route = match client
            .request(WorkspaceRequest::CreateRoute {
                workspace,
                host,
                port,
                policy: RoutePolicy::LoopbackOnly,
            })
            .await?
        {
            WorkspaceResponse::RouteCreated { route, .. } => route,
            _ => return Err(anyhow!("unexpected create-route response")),
        };
        let forward =
            LocalPortForward::bind(connected.runtime.multiplexer().clone(), route, listen).await?;
        println!("{}", forward.webview_url(&scheme)?);
        let mut finished = connected.runtime.subscribe_finished();
        while !crate::shutdown_requested() && !*finished.borrow() {
            if finished.changed().await.is_err() {
                break;
            }
        }
        forward.shutdown().await;
        let _ = client.request(WorkspaceRequest::CloseRoute { route }).await;
        Ok::<_, anyhow::Error>(())
    });
    let shutdown = connected.runtime.shutdown();
    result.and(shutdown)
}

#[derive(Debug, PartialEq, Eq)]
enum RpcInputEvent {
    Line(String),
    End,
    RuntimeFinished,
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

fn run_rpc(args: &[String]) -> anyhow::Result<()> {
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

fn run_ssh(args: &[String]) -> anyhow::Result<()> {
    connect_with_flags(direct_ssh_flags(args)?)
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
        extra_args: options.ssh_args.clone(),
        maximum_frame_bytes: crate::remote_runtime::MAX_CARRIER_FRAME_BYTES,
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum EnrollAdminAction {
    Status,
    Create,
    Pending,
    Approve,
    Deny,
    Devices,
    Connections,
    Revoke,
    Disconnect,
}

impl EnrollAdminAction {
    fn parse(action: &str) -> anyhow::Result<Self> {
        match action {
            "status" => Ok(Self::Status),
            "create" => Ok(Self::Create),
            "pending" => Ok(Self::Pending),
            "approve" => Ok(Self::Approve),
            "deny" => Ok(Self::Deny),
            "devices" => Ok(Self::Devices),
            "connections" => Ok(Self::Connections),
            "revoke" => Ok(Self::Revoke),
            "disconnect" => Ok(Self::Disconnect),
            other => Err(anyhow!(catalog().remote_client.unknown_action("enroll", other))),
        }
    }

    fn name(self) -> &'static str {
        match self {
            Self::Status => "status",
            Self::Create => "create",
            Self::Pending => "pending",
            Self::Approve => "approve",
            Self::Deny => "deny",
            Self::Devices => "devices",
            Self::Connections => "connections",
            Self::Revoke => "revoke",
            Self::Disconnect => "disconnect",
        }
    }

    fn positional_arity(self) -> usize {
        match self {
            Self::Approve | Self::Deny | Self::Revoke => 1,
            Self::Disconnect => 2,
            Self::Status | Self::Create | Self::Pending | Self::Devices | Self::Connections => 0,
        }
    }
}

enum InvitationTicketArg {
    File(PathBuf),
}

struct EnrollAdminArgs {
    action: EnrollAdminAction,
    positionals: Vec<String>,
    session: String,
    state_dir: Option<PathBuf>,
    admin_socket: Option<PathBuf>,
    json: bool,
    ttl_seconds: u64,
    advertised_routes: Vec<String>,
    relay_routes: Vec<String>,
    relay_slots: Vec<String>,
    relay_tickets: Vec<InvitationTicketArg>,
}

fn parse_enroll_admin_args(args: &[String]) -> anyhow::Result<EnrollAdminArgs> {
    let (action, mut index) = match args.first() {
        Some(action) => (EnrollAdminAction::parse(action)?, 1),
        None => (EnrollAdminAction::Status, 0),
    };
    let mut parsed = EnrollAdminArgs {
        action,
        positionals: Vec::new(),
        session: "main".into(),
        state_dir: None,
        admin_socket: None,
        json: false,
        ttl_seconds: 300,
        advertised_routes: Vec::new(),
        relay_routes: Vec::new(),
        relay_slots: Vec::new(),
        relay_tickets: Vec::new(),
    };
    let mut seen = BTreeSet::new();
    let mut options_ended = false;
    while index < args.len() {
        let argument = &args[index];
        index += 1;
        if !options_ended && argument == "--" {
            options_ended = true;
            continue;
        }
        if options_ended || !argument.starts_with("--") {
            parsed.positionals.push(argument.clone());
            continue;
        }
        match argument.as_str() {
            "--session" => {
                require_unique_flag(&mut seen, "--session")?;
                parsed.session = strict_option_value(args, &mut index, "--session")?;
            }
            "--state-dir" => {
                require_unique_flag(&mut seen, "--state-dir")?;
                parsed.state_dir =
                    Some(strict_option_value(args, &mut index, "--state-dir")?.into());
            }
            "--admin-socket" => {
                require_unique_flag(&mut seen, "--admin-socket")?;
                parsed.admin_socket =
                    Some(strict_option_value(args, &mut index, "--admin-socket")?.into());
            }
            "--json" => {
                require_unique_flag(&mut seen, "--json")?;
                parsed.json = true;
            }
            "--ttl" => {
                require_create_action(action, "--ttl")?;
                require_unique_flag(&mut seen, "--ttl")?;
                parsed.ttl_seconds =
                    strict_option_value(args, &mut index, "--ttl")?.parse().map_err(|_| {
                        anyhow!(catalog().remote_client.invalid_option_value("--ttl", "seconds"))
                    })?;
                if parsed.ttl_seconds == 0 {
                    return Err(anyhow!(catalog().remote_client.option_must_be_positive("--ttl")));
                }
            }
            "--advertise" => {
                require_create_action(action, "--advertise")?;
                parsed.advertised_routes.push(strict_option_value(
                    args,
                    &mut index,
                    "--advertise",
                )?);
            }
            "--relay-route" => {
                require_create_action(action, "--relay-route")?;
                parsed.relay_routes.push(strict_option_value(args, &mut index, "--relay-route")?);
            }
            "--relay-slot" => {
                require_create_action(action, "--relay-slot")?;
                parsed.relay_slots.push(strict_option_value(args, &mut index, "--relay-slot")?);
            }
            option if is_inline_secret_option(option, "--relay-ticket") => {
                return Err(anyhow!(catalog().remote_client.inline_enroll_relay_ticket_rejected));
            }
            "--relay-ticket-file" => {
                require_create_action(action, "--relay-ticket-file")?;
                parsed.relay_tickets.push(InvitationTicketArg::File(
                    strict_option_value(args, &mut index, "--relay-ticket-file")?.into(),
                ));
            }
            option => {
                return Err(anyhow!(
                    catalog()
                        .remote_client
                        .unknown_option_for_command(option, &format!("enroll {}", action.name()))
                ));
            }
        }
    }
    let expected = action.positional_arity();
    if parsed.positionals.len() != expected {
        return Err(anyhow!(catalog().remote_client.enroll_arity(action.name(), expected)));
    }
    Ok(parsed)
}

fn require_create_action(action: EnrollAdminAction, option: &str) -> anyhow::Result<()> {
    if action != EnrollAdminAction::Create {
        return Err(anyhow!(catalog().remote_client.option_create_only(option)));
    }
    Ok(())
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

fn run_enroll(args: &[String]) -> anyhow::Result<()> {
    if args.first().is_some_and(|action| action == "connect") {
        return run_connect(&args[1..], None);
    }
    let parsed = parse_enroll_admin_args(args)?;
    let admin_socket = parsed.admin_socket.clone().unwrap_or_else(|| {
        load_runtime_info(&parsed.session, parsed.state_dir.as_deref())
            .map(|runtime| runtime.admin_socket)
            .or_else(|_| {
                daemon_paths(&parsed.session, parsed.state_dir.as_deref())
                    .map(|(_, _, admin)| admin)
            })
            .unwrap_or_else(|_| PathBuf::from("/nonexistent"))
    });
    let request = match parsed.action {
        EnrollAdminAction::Status => AdminRequest::Status,
        EnrollAdminAction::Create => AdminRequest::CreateInvitation {
            ttl_seconds: parsed.ttl_seconds,
            route_hints: parsed.advertised_routes.clone(),
            relay_access: invitation_relay_access(&parsed)?,
        },
        EnrollAdminAction::Pending => AdminRequest::Pending,
        EnrollAdminAction::Approve => {
            AdminRequest::Approve { invitation_id: parsed.positionals[0].clone() }
        }
        EnrollAdminAction::Deny => {
            AdminRequest::Deny { invitation_id: parsed.positionals[0].clone() }
        }
        EnrollAdminAction::Devices => AdminRequest::Devices,
        EnrollAdminAction::Connections => AdminRequest::Connections,
        EnrollAdminAction::Revoke => {
            AdminRequest::Revoke { device_id: parsed.positionals[0].clone() }
        }
        EnrollAdminAction::Disconnect => AdminRequest::Disconnect {
            device_id: parsed.positionals[0].clone(),
            session_id: parsed.positionals[1].clone(),
        },
    };
    let response = tokio_runtime()?.block_on(call_admin(&admin_socket, &request))?;
    print_admin_response(parsed.action.name(), response, parsed.json)
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum KnownDaemonsAction {
    List,
    Forget(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct KnownDaemonsArgs {
    action: KnownDaemonsAction,
    state_dir: Option<PathBuf>,
    json: bool,
}

fn parse_known_daemons_args(args: &[String]) -> anyhow::Result<KnownDaemonsArgs> {
    let mut state_dir = None;
    let mut json = false;
    let mut seen = BTreeSet::new();
    let mut positionals = Vec::new();
    let mut options_ended = false;
    let mut index = 0;
    while index < args.len() {
        let argument = &args[index];
        index += 1;
        if !options_ended && argument == "--" {
            options_ended = true;
            continue;
        }
        if options_ended || !argument.starts_with("--") {
            positionals.push(argument.clone());
            continue;
        }
        match argument.as_str() {
            "--state-dir" => {
                require_unique_flag(&mut seen, "--state-dir")?;
                state_dir = Some(strict_option_value(args, &mut index, "--state-dir")?.into());
            }
            "--json" => {
                require_unique_flag(&mut seen, "--json")?;
                json = true;
            }
            option => {
                return Err(anyhow!(
                    catalog().remote_client.unknown_option_for_command(option, "known-daemons")
                ));
            }
        }
    }
    let action = match positionals.as_slice() {
        [] => KnownDaemonsAction::List,
        [action] if action == "list" => KnownDaemonsAction::List,
        [action, fingerprint] if action == "forget" => {
            KnownDaemonsAction::Forget(fingerprint.clone())
        }
        [action] if action == "forget" => {
            return Err(anyhow!(catalog().remote_client.known_forget_arity));
        }
        [action, ..] if action == "forget" => {
            return Err(anyhow!(catalog().remote_client.known_forget_arity));
        }
        [action, ..] => {
            return Err(anyhow!(catalog().remote_client.unknown_action("known-daemons", action)));
        }
    };
    Ok(KnownDaemonsArgs { action, state_dir, json })
}

fn run_known_daemons(args: &[String]) -> anyhow::Result<()> {
    let parsed = parse_known_daemons_args(args)?;
    let messages = &catalog().remote_client;
    let client_root = parsed
        .state_dir
        .or_else(default_state_dir)
        .ok_or_else(|| anyhow!(messages.known_state_dir_unavailable))?
        .join("client");
    let store = ClientIdentityStore::load_or_create(client_root)?;
    if let KnownDaemonsAction::Forget(fingerprint) = parsed.action {
        let forgotten = tokio_runtime()?.block_on(store.forget_daemon(&fingerprint))?;
        if !forgotten {
            return Err(anyhow!(messages.known_daemon_not_known(&fingerprint)));
        }
        if parsed.json {
            println!(
                "{}",
                serde_json::json!({
                    "forgotten": true,
                    "fingerprint": fingerprint,
                })
            );
        } else {
            println!("{}", messages.known_daemon_forgotten(&fingerprint));
        }
        return Ok(());
    }
    let daemons = tokio_runtime()?.block_on(store.known_daemons());
    if parsed.json {
        println!("{}", serde_json::to_string_pretty(&daemons)?);
        return Ok(());
    }
    if daemons.is_empty() {
        println!("{}", messages.known_daemons_empty);
        return Ok(());
    }
    for daemon in daemons {
        println!(
            "{}\t{}\t{}",
            daemon.name,
            daemon.fingerprint,
            match daemon.auth {
                KnownDaemonAuth::Enrolled => messages.known_daemon_auth_enrolled,
                KnownDaemonAuth::Carrier => messages.known_daemon_auth_carrier,
            }
        );
        for route in daemon.route_hints {
            println!("  {route}");
        }
    }
    Ok(())
}

fn invitation_relay_access(args: &EnrollAdminArgs) -> anyhow::Result<Vec<EnrollmentRelayAccess>> {
    if args.relay_routes.is_empty() && args.relay_slots.is_empty() && args.relay_tickets.is_empty()
    {
        return Ok(Vec::new());
    }
    if args.relay_routes.len() != args.relay_slots.len()
        || args.relay_routes.len() != args.relay_tickets.len()
    {
        return Err(anyhow!(
            "each invitation relay needs one --relay-route, one --relay-slot, and one --relay-ticket-file"
        ));
    }
    if args.relay_routes.len() > 2 {
        return Err(anyhow!("an invitation supports at most two relay bootstrap routes"));
    }

    args.relay_routes
        .iter()
        .zip(&args.relay_slots)
        .zip(&args.relay_tickets)
        .map(|((route, slot), source)| {
            let InvitationTicketArg::File(path) = source;
            let ticket = read_invitation_ticket_file(path)?;
            Ok(EnrollmentRelayAccess { route: route.clone(), slot: slot.clone(), ticket })
        })
        .collect()
}

fn read_invitation_ticket_file(path: &Path) -> anyhow::Result<String> {
    Ok(cmux_remote::secret_file::read_owner_only_string(path, 4 * 1024 + 2)
        .with_context(|| format!("could not read relay ticket file {}", path.display()))?
        .trim()
        .to_string())
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

fn print_admin_response(action: &str, response: AdminResponse, json: bool) -> anyhow::Result<()> {
    if !response.ok {
        return Err(anyhow!(response.error.unwrap_or_else(|| "admin request failed".into())));
    }
    let result = response.result.unwrap_or(Value::Null);
    if json {
        println!("{}", serde_json::to_string_pretty(&result)?);
    } else if action == "create" {
        println!("{}", result["uri"].as_str().ok_or_else(|| anyhow!("missing invitation URI"))?);
    } else {
        println!("{}", serde_json::to_string_pretty(&result)?);
    }
    Ok(())
}

/// Advertised by `remote-probe --json` so a control plane can choose routes the client can use.
pub const PROBE_CAPABILITIES: &[&str] = &["direct-ws-user-agent"];

fn run_probe(args: &[String]) -> anyhow::Result<()> {
    let value = serde_json::json!({
        "app": "cmux-tui",
        "version": env!("CARGO_PKG_VERSION"),
        "distribution_version": DISTRIBUTION_VERSION,
        "npm_bootstrap_version": NPM_BOOTSTRAP_VERSION,
        "build_identity": BUILD_IDENTITY,
        "remote_protocol": REMOTE_PROTOCOL_VERSION,
        "os": std::env::consts::OS,
        "arch": std::env::consts::ARCH,
        // Client-side transport capabilities a control plane can key routing on.
        // `direct-ws-user-agent`: direct WebSocket dials carry a User-Agent, which
        // hosted ingress on branded machine domains requires.
        "capabilities": PROBE_CAPABILITIES,
    });
    if args.iter().any(|argument| argument == "--json") {
        println!("{}", serde_json::to_string(&value)?);
    } else {
        println!(
            "cmux-tui {} remote-protocol={} {}-{}",
            env!("CARGO_PKG_VERSION"),
            REMOTE_PROTOCOL_VERSION,
            std::env::consts::OS,
            std::env::consts::ARCH
        );
    }
    Ok(())
}

struct PendingInstall {
    parent_fd: std::os::fd::RawFd,
    name: std::ffi::CString,
    armed: bool,
}

impl Drop for PendingInstall {
    fn drop(&mut self) {
        if self.armed {
            unsafe {
                libc::unlinkat(self.parent_fd, self.name.as_ptr(), 0);
            }
        }
    }
}

fn install_path_component(
    component: &std::ffi::OsStr,
    description: &str,
) -> anyhow::Result<std::ffi::CString> {
    use std::os::unix::ffi::OsStrExt as _;

    std::ffi::CString::new(component.as_bytes())
        .with_context(|| format!("{description} contains a NUL byte"))
}

fn open_install_parent(path: &Path) -> anyhow::Result<std::os::fd::OwnedFd> {
    use std::os::fd::FromRawFd as _;
    use std::os::unix::ffi::OsStrExt as _;

    let encoded = std::ffi::CString::new(path.as_os_str().as_bytes())
        .context("install parent contains a NUL byte")?;
    let descriptor = unsafe {
        libc::open(
            encoded.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if descriptor < 0 {
        return Err(io::Error::last_os_error()).context("could not open install parent");
    }
    // SAFETY: `open` returned a new owned descriptor.
    let descriptor = unsafe { std::os::fd::OwnedFd::from_raw_fd(descriptor) };
    let mut status = std::mem::MaybeUninit::<libc::stat>::uninit();
    if unsafe { libc::fstat(descriptor.as_raw_fd(), status.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error()).context("could not inspect install parent");
    }
    // SAFETY: `fstat` initialized the structure on success.
    let status = unsafe { status.assume_init() };
    if status.st_uid != unsafe { libc::geteuid() } || status.st_mode & 0o022 != 0 {
        return Err(anyhow!(
            "install parent must be owned by the current user and not group or world writable"
        ));
    }
    Ok(descriptor)
}

fn run_install_self(args: &[String]) -> anyhow::Result<()> {
    use std::os::fd::FromRawFd as _;

    let destination = flag_value(args, "--destination")
        .map(expand_home)
        .transpose()?
        .ok_or_else(|| anyhow!("install-self needs --destination"))?;
    let source = std::env::current_exe()?;
    let parent = destination.parent().ok_or_else(|| anyhow!("destination has no parent"))?;
    let parent = if parent.as_os_str().is_empty() { Path::new(".") } else { parent };
    let destination_name =
        destination.file_name().ok_or_else(|| anyhow!("destination has no file name"))?;
    if destination_name == "." || destination_name == ".." {
        return Err(anyhow!("destination has an invalid file name"));
    }
    let destination_name = install_path_component(destination_name, "destination file name")?;
    fs::create_dir_all(parent)?;
    let parent = open_install_parent(parent)?;
    let temporary_name =
        std::ffi::CString::new(format!(".cmux-tui-install-{}", uuid::Uuid::new_v4()))
            .expect("UUID staging name has no NUL bytes");
    let temporary_descriptor = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            temporary_name.as_ptr(),
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            0o600,
        )
    };
    if temporary_descriptor < 0 {
        return Err(io::Error::last_os_error()).context("could not create staged install");
    }
    // SAFETY: `openat` returned a new owned descriptor.
    let mut temporary = unsafe { fs::File::from_raw_fd(temporary_descriptor) };
    let mut pending =
        PendingInstall { parent_fd: parent.as_raw_fd(), name: temporary_name, armed: true };
    let mut source_file =
        fs::File::open(&source).with_context(|| format!("could not open {}", source.display()))?;
    io::copy(&mut source_file, &mut temporary)
        .with_context(|| format!("could not copy {}", source.display()))?;
    temporary.flush().context("could not flush staged install")?;
    temporary.sync_all().context("could not sync staged install")?;
    if unsafe { libc::fchmod(temporary.as_raw_fd(), 0o755) } != 0 {
        return Err(io::Error::last_os_error()).context("could not set staged install permissions");
    }
    temporary.sync_all().context("could not sync staged install permissions")?;
    if unsafe {
        libc::renameat(
            parent.as_raw_fd(),
            pending.name.as_ptr(),
            parent.as_raw_fd(),
            destination_name.as_ptr(),
        )
    } != 0
    {
        return Err(io::Error::last_os_error()).context("could not install remote binary");
    }
    pending.armed = false;
    if unsafe { libc::fsync(parent.as_raw_fd()) } != 0 {
        return Err(io::Error::last_os_error()).context("could not sync install parent");
    }
    println!("{}", destination.display());
    Ok(())
}

fn run_remote_link(args: &[String]) -> anyhow::Result<()> {
    if !args.iter().any(|argument| argument == "--stdio") {
        return Err(anyhow!("remote-link currently requires --stdio"));
    }
    let session = flag_value(args, "--session").unwrap_or_else(|| "main".into());
    let state_dir = flag_value(args, "--state-dir").map(PathBuf::from);
    let mux_socket = flag_value(args, "--mux-socket").map(PathBuf::from);
    let (session_state, default_link, _) = daemon_paths(&session, state_dir.as_deref())?;
    let link = flag_value(args, "--link-socket").map(PathBuf::from).unwrap_or(default_link);
    ensure_daemon(&session, state_dir.as_deref(), &session_state, &link, mux_socket.as_deref())?;
    tokio_runtime()?.block_on(proxy_stdio(&link))
}

struct RemoteStopArgs {
    session: String,
    state_dir: Option<PathBuf>,
    acknowledge_failed_finalization: bool,
    acknowledge_legacy_finalization: bool,
}

fn parse_remote_stop_args(args: &[String]) -> anyhow::Result<RemoteStopArgs> {
    let mut session = "main".to_string();
    let mut state_dir = None;
    let mut acknowledge_failed_finalization = false;
    let mut acknowledge_legacy_finalization = false;
    let mut seen = BTreeSet::new();
    let mut index = 0;
    while index < args.len() {
        let argument = &args[index];
        index += 1;
        match argument.as_str() {
            "--session" => {
                require_unique_flag(&mut seen, "--session")?;
                session = strict_option_value(args, &mut index, "--session")?;
            }
            "--state-dir" => {
                require_unique_flag(&mut seen, "--state-dir")?;
                state_dir = Some(strict_option_value(args, &mut index, "--state-dir")?.into());
            }
            "--acknowledge-failed-finalization" => {
                require_unique_flag(&mut seen, "--acknowledge-failed-finalization")?;
                acknowledge_failed_finalization = true;
            }
            "--acknowledge-legacy-finalization" => {
                require_unique_flag(&mut seen, "--acknowledge-legacy-finalization")?;
                acknowledge_legacy_finalization = true;
            }
            option if option.starts_with("--") => {
                return Err(anyhow!(catalog().remote.remote_stop_unknown_option(option)));
            }
            _ => return Err(anyhow!(catalog().remote.remote_stop_no_positional)),
        }
    }
    if acknowledge_failed_finalization && acknowledge_legacy_finalization {
        return Err(anyhow!(catalog().remote.remote_stop_acknowledgements_mutually_exclusive));
    }
    Ok(RemoteStopArgs {
        session,
        state_dir,
        acknowledge_failed_finalization,
        acknowledge_legacy_finalization,
    })
}

fn run_remote_stop(args: &[String]) -> anyhow::Result<()> {
    let parsed = parse_remote_stop_args(args)?;
    let (state_dir, default_link, default_admin) =
        daemon_paths(&parsed.session, parsed.state_dir.as_deref())?;
    let runtime = match load_runtime_info(&parsed.session, parsed.state_dir.as_deref()) {
        Ok(runtime) => runtime,
        Err(_)
            if UnixStream::connect(&default_link).is_err()
                && UnixStream::connect(&default_admin).is_err() =>
        {
            if parsed.acknowledge_failed_finalization {
                return tokio_runtime()?.block_on(acknowledge_failed_shutdown_outcome(
                    &state_dir,
                    &parsed.session,
                    &default_link,
                    &default_admin,
                ));
            }
            if parsed.acknowledge_legacy_finalization {
                return tokio_runtime()?.block_on(acknowledge_legacy_shutdown_state(
                    &state_dir,
                    &parsed.session,
                    &default_link,
                    &default_admin,
                ));
            }
            let runtime_path = state_dir.join("runtime.json");
            match fs::symlink_metadata(&runtime_path) {
                Ok(_) => {
                    return Err(anyhow!(
                        catalog()
                            .remote
                            .invalid_runtime_metadata(&runtime_path.display().to_string())
                    ));
                }
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(error) => {
                    return Err(error).with_context(|| {
                        catalog()
                            .remote
                            .inspect_runtime_metadata(&runtime_path.display().to_string())
                    });
                }
            }
            verify_inactive_shutdown_outcome(&state_dir)?;
            if inactive_daemon_needs_legacy_acknowledgement(&state_dir)? {
                return Err(anyhow!(catalog().remote.inactive_legacy_needs_migration));
            }
            return Ok(());
        }
        Err(error) => {
            return Err(error.context(catalog().remote.refuse_live_invalid_lifecycle));
        }
    };
    if parsed.acknowledge_failed_finalization {
        return tokio_runtime()?.block_on(acknowledge_failed_shutdown_outcome(
            &runtime.state_dir,
            &parsed.session,
            &runtime.link_socket,
            &runtime.admin_socket,
        ));
    }
    if parsed.acknowledge_legacy_finalization {
        return tokio_runtime()?.block_on(acknowledge_legacy_shutdown_state(
            &runtime.state_dir,
            &parsed.session,
            &runtime.link_socket,
            &runtime.admin_socket,
        ));
    }
    if !runtime.replaceable_sidecar {
        return Err(anyhow!(catalog().remote.embedded_daemon_stop_refused));
    }
    let runtime_file = runtime.state_dir.join("runtime.json");
    let state_dir = runtime.state_dir;
    let lifecycle_id = runtime.lifecycle_id;
    let link = runtime.link_socket;
    let admin = runtime.admin_socket;
    let shutdown_request = shutdown_request_for_lifecycle(lifecycle_id.as_deref());
    let (response, mut peer_exit) =
        tokio_runtime()?.block_on(call_admin_with_peer_exit(&admin, &shutdown_request))?;
    if !response.ok {
        return Err(anyhow!(
            response.error.unwrap_or_else(|| catalog().remote.daemon_shutdown_failed.to_owned())
        ));
    }
    let deadline = Instant::now() + Duration::from_secs(20);
    while Instant::now() < deadline {
        let process_exited =
            peer_exit.has_exited().context(catalog().remote.observe_daemon_exit)?;
        if process_exited && UnixStream::connect(&link).is_err() && !runtime_file.exists() {
            match lifecycle_id.as_deref() {
                Some(lifecycle_id) => verify_shutdown_outcome(&state_dir, lifecycle_id),
                None => Ok(()),
            }?;
            tokio_runtime()?
                .block_on(complete_verified_daemon_stop(&state_dir, &parsed.session))?;
            return Ok(());
        }
        thread::sleep(Duration::from_millis(50));
    }
    Err(anyhow!(catalog().remote.daemon_stop_timeout))
}

fn shutdown_request_for_lifecycle(lifecycle_id: Option<&str>) -> AdminRequest {
    match lifecycle_id {
        Some(lifecycle_id) => {
            AdminRequest::ShutdownLifecycle { lifecycle_id: lifecycle_id.to_owned() }
        }
        None => AdminRequest::Shutdown,
    }
}

fn verify_inactive_shutdown_outcome(state_dir: &Path) -> anyhow::Result<()> {
    let path = state_dir.join("shutdown.json");
    match fs::symlink_metadata(&path) {
        Ok(_) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => {
            return Err(error).with_context(|| {
                catalog().remote.verify_previous_finalization_path(&path.display().to_string())
            });
        }
    }
    let outcome =
        load_shutdown_outcome(state_dir).context(catalog().remote.verify_previous_finalization)?;
    match outcome.status {
        DaemonShutdownStatus::Succeeded => Ok(()),
        DaemonShutdownStatus::Failed => {
            Err(anyhow!(catalog().remote.previous_finalization_failed_ack))
        }
    }
}

fn verify_shutdown_outcome(state_dir: &Path, lifecycle_id: &str) -> anyhow::Result<()> {
    let outcome = load_shutdown_outcome(state_dir).context(catalog().remote.verify_finalization)?;
    if outcome.lifecycle_id != lifecycle_id {
        return Err(anyhow!(catalog().remote.finalization_wrong_lifecycle));
    }
    match outcome.status {
        DaemonShutdownStatus::Succeeded => Ok(()),
        DaemonShutdownStatus::Failed => Err(anyhow!(catalog().remote.finalization_failed)),
    }
}

fn run_remote_sidecar(args: &[String]) -> anyhow::Result<()> {
    let session = flag_value(args, "--session").unwrap_or_else(|| "main".into());
    let mux_socket = flag_value(args, "--mux-socket")
        .map(PathBuf::from)
        .ok_or_else(|| anyhow!("remote-sidecar needs --mux-socket"))?;
    let mut mux_monitor = open_mux_monitor(&mux_socket)?;
    let state_dir = flag_value(args, "--state-dir").map(PathBuf::from);
    let link_socket = flag_value(args, "--link-socket").map(PathBuf::from);
    let runtime = start_daemon_runtime(
        mux_socket.clone(),
        DaemonRuntimeOptions {
            session,
            state_dir,
            link_socket,
            admin_socket: None,
            direct_websocket: None,
            allow_insecure_non_loopback: false,
            workspace_http: None,
            relays: Vec::new(),
            iroh: false,
            advertised_routes: Vec::new(),
            resume_lease: cmux_remote::daemon::DEFAULT_RESUME_LEASE,
            replaceable_sidecar: true,
        },
    )?;
    let mut mux_disappeared = false;
    let mut monitor_error = None;
    while !crate::shutdown_requested() && !runtime.is_finished() {
        match mux_monitor_disconnected(&mut mux_monitor, &mux_socket) {
            Ok(false) => {}
            Ok(true) => {
                mux_disappeared = true;
                break;
            }
            Err(error) => {
                mux_disappeared = true;
                monitor_error = Some(error);
                break;
            }
        }
    }
    if !mux_disappeared {
        return runtime.shutdown();
    }

    // The runtime owns its socket and metadata paths through shutdown. A
    // separate check-then-unlink cleanup can remove a replacement daemon that
    // binds the same path after this runtime releases it.
    let lifecycle = runtime.shutdown();
    match (lifecycle, monitor_error) {
        (result, None) => result,
        (Ok(()), Some(error)) => Err(error.context("mux socket health monitor failed")),
        (Err(lifecycle), Some(monitor)) => Err(anyhow!(
            "mux socket health monitor failed: {monitor:#}; sidecar cleanup failed: {lifecycle:#}"
        )),
    }
}

fn ensure_daemon(
    session: &str,
    state_root: Option<&Path>,
    session_state: &Path,
    link: &Path,
    mux_socket_override: Option<&Path>,
) -> anyhow::Result<()> {
    let _lock = lock_daemon_start(session_state)?;
    if UnixStream::connect(link).is_ok() {
        return Ok(());
    }

    // Spawn the daemon from this client's own running build (open inode on
    // Linux) so an in-place binary upgrade cannot leave a long-lived client
    // exec'ing a "(deleted)" path, and daemon/client builds never skew.
    let executable = cmux_tui_core::platform::self_exe_for_spawn()?;
    let log_path = session_state.join("daemon.log");
    let mux_socket = mux_socket_override
        .map(Path::to_path_buf)
        .or_else(|| std::env::var_os("CMUX_MUX_SOCKET").map(PathBuf::from))
        .map_or_else(|| cmux_tui_core::server::try_default_socket_path(session), Ok)?;
    if UnixStream::connect(&mux_socket).is_err() {
        let log = open_private_daemon_file(&log_path, true)
            .with_context(|| format!("could not open daemon log {}", log_path.display()))?;
        let mut mux_owner = Command::new(&executable);
        mux_owner
            .args(["--headless", "--session", session, "--socket"])
            .arg(&mux_socket)
            .stdin(Stdio::null())
            .stdout(Stdio::from(log.try_clone()?))
            .stderr(Stdio::from(log));
        configure_detached_process(&mut mux_owner);
        let mut child = mux_owner.spawn().context("could not start remote mux owner")?;
        wait_for_detached_socket(
            &mut child,
            &mux_socket,
            Duration::from_secs(20),
            "remote mux owner",
            &log_path,
        )?;
    }

    let log = open_private_daemon_file(&log_path, true)
        .with_context(|| format!("could not open daemon log {}", log_path.display()))?;
    let mut command = Command::new(executable);
    command
        .args(["remote-sidecar", "--session", session, "--mux-socket"])
        .arg(&mux_socket)
        .arg("--link-socket")
        .arg(link);
    if let Some(state_root) = state_root {
        command.arg("--state-dir").arg(state_root);
    }
    command.stdin(Stdio::null());
    command.stdout(Stdio::from(log.try_clone()?)).stderr(Stdio::from(log));
    configure_detached_process(&mut command);
    let mut child = command.spawn().context("could not start remote daemon")?;
    wait_for_detached_socket(&mut child, link, Duration::from_secs(20), "remote daemon", &log_path)
}

fn wait_for_detached_socket(
    child: &mut Child,
    socket: &Path,
    timeout: Duration,
    process_name: &str,
    log_path: &Path,
) -> anyhow::Result<()> {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if UnixStream::connect(socket).is_ok() {
            return Ok(());
        }
        match child.try_wait() {
            Ok(Some(status)) => {
                return Err(anyhow!(
                    "{process_name} exited {status}; inspect {}",
                    log_path.display()
                ));
            }
            Ok(None) => {}
            Err(error) => {
                let cleanup = terminate_detached_process(child);
                return match cleanup {
                    Ok(()) => Err(error).with_context(|| {
                        format!("could not inspect {process_name}; inspect {}", log_path.display())
                    }),
                    Err(cleanup) => Err(anyhow!(
                        "could not inspect {process_name}: {error}; process cleanup failed: {cleanup}; inspect {}",
                        log_path.display()
                    )),
                };
            }
        }
        thread::sleep(Duration::from_millis(50));
    }
    match terminate_detached_process(child) {
        Ok(()) => Err(anyhow!("{process_name} did not create {}", socket.display())),
        Err(error) => Err(anyhow!(
            "{process_name} did not create {}; process cleanup failed: {error}",
            socket.display()
        )),
    }
}

fn terminate_detached_process(child: &mut Child) -> io::Result<()> {
    if child.try_wait()?.is_some() {
        return Ok(());
    }
    signal_detached_process_group(child, libc::SIGTERM)?;
    if wait_for_child_exit(child, DETACHED_TERM_GRACE)? {
        return Ok(());
    }
    signal_detached_process_group(child, libc::SIGKILL)?;
    if wait_for_child_exit(child, DETACHED_KILL_GRACE)? {
        return Ok(());
    }
    Err(io::Error::new(
        io::ErrorKind::TimedOut,
        format!("detached process {} did not exit after SIGKILL", child.id()),
    ))
}

fn signal_detached_process_group(child: &Child, signal: libc::c_int) -> io::Result<()> {
    let process_group = libc::pid_t::try_from(child.id())
        .map_err(|_| io::Error::other("detached child PID does not fit pid_t"))?;
    if unsafe { libc::kill(-process_group, signal) } == 0 {
        return Ok(());
    }
    let error = io::Error::last_os_error();
    if error.raw_os_error() == Some(libc::ESRCH) { Ok(()) } else { Err(error) }
}

fn wait_for_child_exit(child: &mut Child, timeout: Duration) -> io::Result<bool> {
    let deadline = Instant::now() + timeout;
    loop {
        if child.try_wait()?.is_some() {
            return Ok(true);
        }
        if Instant::now() >= deadline {
            return Ok(false);
        }
        thread::sleep(Duration::from_millis(10));
    }
}

fn configure_detached_process(command: &mut Command) {
    use std::os::unix::process::CommandExt;

    unsafe {
        command.pre_exec(|| {
            if libc::setsid() < 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
}

fn open_mux_monitor(path: &Path) -> anyhow::Result<UnixStream> {
    let stream = UnixStream::connect(path).with_context(|| {
        format!("cannot attach remote sidecar to mux socket {}", path.display())
    })?;
    stream.set_read_timeout(Some(Duration::from_millis(250)))?;
    Ok(stream)
}

fn mux_monitor_disconnected(stream: &mut UnixStream, path: &Path) -> anyhow::Result<bool> {
    use std::os::unix::fs::FileTypeExt;

    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_socket() => {}
        Ok(_) => return Ok(true),
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(true),
        Err(error) => return Err(error.into()),
    }

    let mut byte = [0_u8; 1];
    match stream.read(&mut byte) {
        Ok(0) => Ok(true),
        Ok(_) => Ok(false),
        Err(error)
            if matches!(
                error.kind(),
                io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut | io::ErrorKind::Interrupted
            ) =>
        {
            Ok(false)
        }
        Err(error)
            if matches!(
                error.kind(),
                io::ErrorKind::BrokenPipe
                    | io::ErrorKind::ConnectionAborted
                    | io::ErrorKind::ConnectionReset
                    | io::ErrorKind::NotConnected
            ) =>
        {
            Ok(true)
        }
        Err(error) => Err(error.into()),
    }
}

fn open_private_daemon_file(path: &Path, append: bool) -> io::Result<fs::File> {
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};

    let mut options = OpenOptions::new();
    options
        .read(!append)
        .write(true)
        .create(true)
        .append(append)
        .truncate(false)
        .mode(0o600)
        // Opening a hostile FIFO must return so its type can be rejected
        // below, rather than waiting for a peer that never arrives.
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK);
    let file = options.open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "daemon state path is not a regular file",
        ));
    }
    if metadata.uid() != unsafe { libc::geteuid() } {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "daemon state file is not owned by the effective user",
        ));
    }
    if metadata.nlink() != 1 {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "daemon state file has unexpected hard links",
        ));
    }
    // Existing files may predate this check and have inherited a broad umask.
    // Tighten the inode through the open descriptor, avoiding a pathname race.
    if metadata.permissions().mode() & 0o077 != 0 {
        file.set_permissions(fs::Permissions::from_mode(0o600))?;
    }
    Ok(file)
}

fn lock_daemon_start(session_state: &Path) -> anyhow::Result<fs::File> {
    ensure_secure_directory(session_state, DirectoryAccess::OwnerControlled).with_context(
        || format!("could not prepare secure daemon state directory {}", session_state.display()),
    )?;
    let lock_path = session_state.join("start.lock");
    let lock = open_private_daemon_file(&lock_path, false)
        .with_context(|| format!("could not open daemon start lock {}", lock_path.display()))?;
    let locked = unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) };
    if locked != 0 {
        return Err(io::Error::last_os_error().into());
    }
    Ok(lock)
}

async fn proxy_stdio(link: &Path) -> anyhow::Result<()> {
    proxy_stdio_with_io(link, tokio::io::stdin(), tokio::io::stdout(), verify_unix_peer_owner).await
}

async fn proxy_stdio_with_io<R, W, V>(
    link: &Path,
    mut stdin: R,
    mut stdout: W,
    verify_peer: V,
) -> anyhow::Result<()>
where
    R: tokio::io::AsyncRead + Unpin,
    W: tokio::io::AsyncWrite + Unpin,
    V: FnOnce(&tokio::net::UnixStream) -> Result<(), UnixPeerAuthError>,
{
    use tokio::io::{AsyncWriteExt, copy};

    let stream = tokio::net::UnixStream::connect(link).await?;
    verify_peer(&stream)?;
    let (mut socket_read, mut socket_write) = stream.into_split();
    let upload = async {
        copy(&mut stdin, &mut socket_write).await?;
        socket_write.shutdown().await
    };
    let download = async {
        copy(&mut socket_read, &mut stdout).await?;
        stdout.shutdown().await
    };
    tokio::try_join!(upload, download)?;
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
mod tests {
    #[test]
    fn probe_capabilities_include_direct_ws_user_agent() {
        assert!(super::PROBE_CAPABILITIES.contains(&"direct-ws-user-agent"));
    }

    use super::*;

    fn seed_legacy_authorization_state(state_dir: &Path) {
        let auth_state_dir = state_dir.join("auth");
        fs::create_dir_all(&auth_state_dir).unwrap();
        fs::write(
            auth_state_dir.join("devices.json"),
            serde_json::to_vec_pretty(&serde_json::json!({
                "version": 1,
                "revision": 0,
                "revocation_generation": 0,
                "devices": [],
                "invitations": [],
            }))
            .unwrap(),
        )
        .unwrap();
    }

    #[tokio::test]
    async fn rpc_stdin_wait_stops_when_remote_runtime_finishes_without_eof() {
        let (_stdin_tx, mut stdin_rx) = tokio::sync::mpsc::channel::<io::Result<String>>(1);
        let (finished_tx, mut finished_rx) = tokio::sync::watch::channel(false);
        finished_tx.send_replace(true);

        let event = tokio::time::timeout(
            Duration::from_millis(100),
            next_rpc_input(&mut stdin_rx, &mut finished_rx),
        )
        .await
        .expect("RPC input stayed blocked after the remote runtime finished")
        .unwrap();

        assert!(matches!(event, RpcInputEvent::RuntimeFinished));
    }

    fn test_provider_registry() -> Arc<cmux_remote::provider::ProviderRegistry> {
        Arc::new(
            client_provider_registry(
                SshProviderConfig::default(),
                BTreeMap::new(),
                IrohPathMode::Auto,
            )
            .unwrap(),
        )
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn stdio_proxy_rejects_failed_peer_authentication_before_forwarding_data() {
        use cmux_remote::admin::UnixPeerAuthError;
        use tokio::io::AsyncReadExt;
        use tokio::net::UnixListener;

        let directory = tempfile::tempdir().unwrap();
        let socket = directory.path().join("impostor-link.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let responder = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut byte = [0_u8; 1];
            tokio::time::timeout(Duration::from_secs(1), stream.read(&mut byte))
                .await
                .expect("stdio proxy kept the rejected connection open")
                .unwrap()
        });
        let expected_uid = unsafe { libc::geteuid() };
        let peer_uid = expected_uid.wrapping_add(1);

        let error = proxy_stdio_with_io(&socket, tokio::io::empty(), tokio::io::sink(), |_| {
            Err(UnixPeerAuthError::WrongUid { peer_uid, expected_uid })
        })
        .await
        .unwrap_err();

        assert!(matches!(
            error.downcast_ref::<UnixPeerAuthError>(),
            Some(UnixPeerAuthError::WrongUid { .. })
        ));
        assert_eq!(responder.await.unwrap(), 0, "stdio data leaked to the rejected Unix responder");
    }

    #[test]
    fn initial_ssh_bootstrap_uses_startup_budget_not_reconnect_attempt_budget() {
        let startup_timeout = Duration::from_secs(2);
        let flags = ConnectFlags {
            reconnect: ReconnectPolicy {
                attempt_timeout: Duration::from_millis(20),
                ..ReconnectPolicy::default()
            },
            auto_install: true,
            upgrade: true,
            ..ConnectFlags::default()
        };

        let bootstrap = initial_ssh_bootstrap_options(&flags, startup_timeout);
        assert_eq!(bootstrap.attempt_timeout, startup_timeout);
        assert_ne!(bootstrap.attempt_timeout, flags.reconnect.attempt_timeout);
        assert!(bootstrap.auto_install);
        assert!(bootstrap.upgrade);
    }

    #[test]
    fn iroh_url_query_becomes_non_secret_routing_hints() {
        let mut url =
            Url::parse("iroh://abc?relay=https%3A%2F%2Frelay.example&direct=127.0.0.1%3A1234")
                .unwrap();
        let mut routing = BTreeMap::new();
        extract_iroh_routing(&mut url, &mut routing).unwrap();
        assert_eq!(url.as_str(), "iroh://abc");
        assert_eq!(routing[ROUTING_RELAY_URL], "https://relay.example");
        assert_eq!(routing[ROUTING_DIRECT_ADDRS], "127.0.0.1:1234");
    }

    #[test]
    fn iroh_route_candidates_keep_query_hints_isolated() {
        let routes = [
            "iroh://first?relay=https%3A%2F%2Ffirst-relay.example&direct=127.0.0.1%3A1111"
                .to_string(),
            "iroh://second?relay=https%3A%2F%2Fsecond-relay.example&direct=127.0.0.1%3A2222"
                .to_string(),
        ];

        let candidates =
            resolve_route_candidates(&routes, &BTreeMap::new(), &test_provider_registry()).unwrap();

        assert_eq!(candidates[0].endpoint.as_str(), "iroh://first");
        assert_eq!(candidates[0].routing[ROUTING_RELAY_URL], "https://first-relay.example");
        assert_eq!(candidates[0].routing[ROUTING_DIRECT_ADDRS], "127.0.0.1:1111");
        assert_eq!(candidates[1].endpoint.as_str(), "iroh://second");
        assert_eq!(candidates[1].routing[ROUTING_RELAY_URL], "https://second-relay.example");
        assert_eq!(candidates[1].routing[ROUTING_DIRECT_ADDRS], "127.0.0.1:2222");
    }

    #[test]
    fn unsupported_future_route_does_not_block_supported_fallback() {
        let routes = [
            "future+quic://user:secret@future.example/capability?ticket=secret".to_string(),
            "wss://supported.example/v1/link".to_string(),
        ];

        let candidates =
            resolve_route_candidates(&routes, &BTreeMap::new(), &test_provider_registry()).unwrap();

        assert_eq!(candidates.len(), 1);
        assert_eq!(candidates[0].endpoint.as_str(), "wss://supported.example/v1/link");
    }

    #[test]
    fn unsupported_routes_report_schemes_without_endpoint_secrets() {
        let routes = [
            "future+quic://user:password@future.example/private-capability?ticket=route-secret"
                .to_string(),
            "next+tcp://other.example/another-secret".to_string(),
        ];

        let error = resolve_route_candidates(&routes, &BTreeMap::new(), &test_provider_registry())
            .expect_err("unsupported routes should fail");
        let message = error.to_string();

        assert!(message.contains("future+quic"));
        assert!(message.contains("next+tcp"));
        for secret in ["user", "password", "private-capability", "route-secret", "another-secret"] {
            assert!(!message.contains(secret), "{secret:?} leaked in {message:?}");
        }
    }

    #[test]
    fn malformed_route_errors_do_not_echo_credentials() {
        let routes = ["wss://dont-leak-me@[".to_string()];

        let error = resolve_route_candidates(&routes, &BTreeMap::new(), &test_provider_registry())
            .expect_err("malformed route should fail");

        assert!(!error.to_string().contains("dont-leak-me"));
    }

    #[test]
    fn unsupported_route_parameters_do_not_echo_query_credentials() {
        let routes = ["iroh://node?query-secret-marker=value".to_string()];

        let error = resolve_route_candidates(&routes, &BTreeMap::new(), &test_provider_registry())
            .expect_err("unsupported route parameter should fail");

        assert!(!error.to_string().contains("query-secret-marker"));
    }

    #[test]
    fn generic_route_resolution_rejects_option_like_ssh_destinations() {
        let routes = ["ssh://-Fvalidation@localhost".to_string()];

        let error = resolve_route_candidates(&routes, &BTreeMap::new(), &test_provider_registry())
            .expect_err("option-like SSH destination should fail");

        assert!(error.to_string().contains("safe OpenSSH destination"));
    }

    #[test]
    fn parse_lane_policy_and_relay_flags() {
        let args = [
            "relay+wss://host",
            "--lanes",
            "isolated",
            "--relay-slot",
            "slot",
            "--relay-ticket-command",
            "ticket-command",
        ]
        .map(str::to_string);
        let parsed = parse_connect_flags(&args).unwrap();
        assert_eq!(parsed.lanes, LanePolicy::Isolated);
        assert!(parsed.lanes_explicit);
        assert_eq!(parsed.relay_slots, ["slot"]);
        assert_eq!(parsed.relay_credentials.len(), 1);
    }

    #[test]
    fn invitation_file_parser_is_unambiguous_and_help_safe() {
        let parsed = parse_connect_flags(&[
            "ws://daemon.example/v1/link".into(),
            "--invite-file".into(),
            "-".into(),
        ])
        .unwrap();
        assert!(matches!(
            parsed.invitation,
            Some(InvitationArg::File(path)) if path == Path::new("-")
        ));
        assert!(!remote_help_requested(&["--invite-file".into(), "-h".into()]));

        let args = ["--invite-file", "first", "--invite-file", "second"]
            .into_iter()
            .map(str::to_string)
            .collect::<Vec<_>>();
        assert!(parse_connect_flags(&args).is_err(), "unexpectedly accepted {args:?}");
    }

    #[test]
    fn positional_invitations_are_rejected_before_loading_or_connecting() {
        let error = parse_connect_flags(&["cmux://enroll/positional-secret".into()])
            .err()
            .expect("positional invitation should fail");
        assert!(!error.to_string().contains("positional-secret"));
    }

    #[test]
    fn invitation_input_accepts_one_lf_or_crlf_and_preserves_following_stdin() {
        for input in [b"cmux://enroll/value\n".as_slice(), b"cmux://enroll/value\r\n"] {
            let mut input = io::Cursor::new(input);
            assert_eq!(&*read_invitation_uri_to_end(&mut input).unwrap(), "cmux://enroll/value");
        }

        let mut input = io::Cursor::new(b"cmux://enroll/value\nrpc-request\n");
        assert_eq!(&*read_invitation_uri_line(&mut input).unwrap(), "cmux://enroll/value");
        let mut remaining = String::new();
        input.read_to_string(&mut remaining).unwrap();
        assert_eq!(remaining, "rpc-request\n");
    }

    #[test]
    fn invitation_input_rejects_malformed_data_without_echoing_it() {
        let secret = "do-not-echo-this-secret";
        let malformed = [
            Vec::new(),
            format!("cmux://enroll/{secret}\nsecond").into_bytes(),
            vec![0xff, 0xfe, 0xfd],
            vec![b'x'; MAX_INVITATION_URI_BYTES + 1],
        ];
        for bytes in malformed {
            let error = read_invitation_uri_to_end(&mut io::Cursor::new(bytes))
                .expect_err("malformed invitation should fail");
            assert!(!error.to_string().contains(secret));
        }
    }

    #[cfg(unix)]
    #[test]
    fn invitation_file_requires_owner_only_permissions() {
        use std::os::unix::fs::PermissionsExt;

        let directory = tempfile::tempdir().unwrap();
        let invitation = directory.path().join("invitation");
        fs::write(&invitation, "cmux://enroll/value\n").unwrap();
        fs::set_permissions(&invitation, fs::Permissions::from_mode(0o600)).unwrap();
        assert_eq!(&*read_invitation_uri(&invitation).unwrap(), "cmux://enroll/value");

        fs::set_permissions(&invitation, fs::Permissions::from_mode(0o640)).unwrap();
        assert!(read_invitation_uri(&invitation).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn invitation_file_rejects_non_regular_paths_without_blocking() {
        use std::ffi::CString;
        use std::os::unix::ffi::OsStrExt;

        let directory = tempfile::tempdir().unwrap();
        let fifo = directory.path().join("invitation.fifo");
        let fifo_path = CString::new(fifo.as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(fifo_path.as_ptr(), 0o600) }, 0);

        let started = Instant::now();
        let error = read_invitation_uri(&fifo).unwrap_err().to_string();
        assert!(started.elapsed() < Duration::from_secs(1));
        assert!(error.contains("regular file"));
    }

    #[test]
    fn ssh_can_distinguish_transport_default_from_an_explicit_lane_policy() {
        let default = parse_connect_flags(&["host".into()]).unwrap();
        assert!(!default.lanes_explicit);
        let explicit =
            parse_connect_flags(&["host".into(), "--lanes".into(), "isolated".into()]).unwrap();
        assert!(explicit.lanes_explicit);
    }

    #[tokio::test]
    async fn explicit_daemon_pins_carrier_routes_while_unpinned_routes_discover() {
        let directory = tempfile::tempdir().unwrap();
        let store = ClientIdentityStore::load_or_create(directory.path()).unwrap();
        let key = cmux_remote::crypto::StaticIdentity::generate().unwrap().public_key();
        let known = store
            .pin_carrier_daemon("remote".into(), key, vec!["ssh://remote.example".into()])
            .await
            .unwrap();

        for route in ["ssh://remote.example", "unix:///tmp/cmux-remote.sock"] {
            let pinned = select_explicit_route_identity(
                &store,
                Some(&known.fingerprint),
                route,
                SupportedClientAuthModes::DeviceOrCarrier,
            )
            .await
            .unwrap();
            assert!(matches!(pinned.auth, ClientAuthMode::Carrier));
            assert_eq!(pinned.expected_daemon, Some(key));
            assert_eq!(
                pinned.known.as_ref().map(|daemon| &daemon.fingerprint),
                Some(&known.fingerprint)
            );
            assert!(!pinned.carrier_discovery);

            let unpinned = select_explicit_route_identity(
                &store,
                None,
                route,
                SupportedClientAuthModes::DeviceOrCarrier,
            )
            .await
            .unwrap();
            assert!(matches!(unpinned.auth, ClientAuthMode::Carrier));
            assert!(unpinned.expected_daemon.is_none());
            assert!(unpinned.known.is_none());
            assert!(unpinned.carrier_discovery);
        }

        assert!(
            select_explicit_route_identity(
                &store,
                Some("unknown"),
                "ssh://remote.example",
                SupportedClientAuthModes::DeviceOrCarrier,
            )
            .await
            .is_err()
        );
    }

    #[test]
    fn connection_json_diagnostics_require_headless_mode() {
        assert!(parse_connect_flags(&["unix:///tmp/cmux.sock".into(), "--json".into()]).is_err());
        let flags = parse_connect_flags(&[
            "unix:///tmp/cmux.sock".into(),
            "--headless".into(),
            "--json".into(),
        ])
        .unwrap();
        assert!(flags.headless);
        assert!(flags.json);
    }

    #[test]
    fn parses_explicit_iroh_path_policy() {
        for (value, expected) in [
            ("auto", IrohPathMode::Auto),
            ("direct-only", IrohPathMode::DirectOnly),
            ("relay-only", IrohPathMode::RelayOnly),
        ] {
            let flags =
                parse_connect_flags(&["iroh://node".into(), "--iroh-path".into(), value.into()])
                    .unwrap();
            assert_eq!(flags.iroh_path, expected);
        }
        assert!(
            parse_connect_flags(&["iroh://node".into(), "--iroh-path".into(), "direct".into(),])
                .is_err()
        );
    }

    #[test]
    fn help_detection_does_not_consume_ssh_argument_values() {
        assert!(!remote_help_requested(&["host".into(), "--ssh-arg".into(), "-h".into()]));
        assert!(!remote_help_requested(&["--invite-file".into(), "-h".into()]));
        assert!(remote_help_requested(&["host".into(), "--help".into()]));
        assert!(!remote_help_requested(&[
            "--invite".into(),
            "inline-secret".into(),
            "--help".into(),
        ]));
        assert!(!remote_help_requested(&[
            "--relay-ticket".into(),
            "inline-secret".into(),
            "--help".into(),
        ]));
        assert!(!remote_help_requested(&[
            "--help".into(),
            "--invite".into(),
            "inline-secret".into(),
        ]));
        assert!(!remote_help_requested(&["--invite=inline-secret".into(), "--help".into(),]));
        assert!(!remote_help_requested(&["--relay-ticket=inline-secret".into(), "--help".into(),]));
        assert!(
            parse_connect_flags(&["--help".into(), "--invite".into(), "inline-secret".into(),])
                .is_err()
        );
    }

    #[test]
    fn reconnect_backoff_is_configurable() {
        let args = [
            "ws://host/v1/link",
            "--reconnect-attempts",
            "7",
            "--reconnect-initial-ms",
            "25",
            "--reconnect-max-ms",
            "400",
            "--reconnect-attempt-timeout-ms",
            "2000",
            "--reconnect-jitter",
            "none",
            "--heartbeat-interval-ms",
            "1000",
            "--heartbeat-timeout-ms",
            "3000",
        ]
        .map(str::to_string);
        let parsed = parse_connect_flags(&args).unwrap();
        assert_eq!(parsed.reconnect.maximum_attempts, Some(7));
        assert_eq!(parsed.reconnect.initial_delay, Duration::from_millis(25));
        assert_eq!(parsed.reconnect.maximum_delay, Duration::from_millis(400));
        assert_eq!(parsed.reconnect.attempt_timeout, Duration::from_secs(2));
        assert!(!parsed.reconnect.full_jitter);
        assert_eq!(parsed.reconnect.heartbeat_interval, Some(Duration::from_secs(1)));
        assert_eq!(parsed.reconnect.heartbeat_timeout, Duration::from_secs(3));
    }

    #[test]
    fn every_remote_subcommand_help_exits_without_running_the_command() {
        for command in ["connect", "ssh", "forward", "rpc", "enroll", "remote-probe"] {
            let args = [command.to_string(), "--help".to_string()];
            assert!(run_inner(&args, "unused").is_ok(), "{command}");
            assert!(remote_help(Some(command)).starts_with("USAGE:"));
        }
    }

    #[test]
    fn rpc_stdin_rejects_an_oversized_line_without_consuming_the_whole_line() {
        let mut input = io::Cursor::new(vec![b'x'; 4_096]);
        let error = read_rpc_stdin_line(&mut input, 64)
            .expect_err("oversized RPC input should be rejected");

        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
        assert!(
            input.position() <= 65,
            "RPC reader consumed {} bytes before enforcing a 64-byte limit",
            input.position()
        );
    }

    #[test]
    fn rpc_stdin_accepts_exact_limit_for_lf_crlf_and_eof() {
        for input in [b"1234\n".as_slice(), b"1234\r\n", b"1234"] {
            let mut input = io::Cursor::new(input);
            assert_eq!(read_rpc_stdin_line(&mut input, 4).unwrap().as_deref(), Some("1234"));
            assert_eq!(read_rpc_stdin_line(&mut input, 4).unwrap(), None);
        }
    }

    #[test]
    fn rpc_stdin_rejects_invalid_utf8_within_the_limit() {
        let mut input = io::Cursor::new([0xff, b'\n']);
        let error = read_rpc_stdin_line(&mut input, 4).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
    }

    #[cfg(unix)]
    #[test]
    fn local_unix_route_is_promoted_and_remote_unix_route_is_demoted() {
        let directory = tempfile::tempdir().unwrap();
        let local_path = directory.path().join("remote.sock");
        let _listener = std::os::unix::net::UnixListener::bind(&local_path).unwrap();
        let local = Url::parse(&format!("unix://{}", local_path.display())).unwrap();
        let missing =
            Url::parse(&format!("unix://{}", directory.path().join("missing.sock").display()))
                .unwrap();
        let websocket = Url::parse("wss://daemon.example/v1/link").unwrap();
        let providers = test_provider_registry();
        let candidate = |endpoint| {
            ResolvedRouteCandidate::resolve(endpoint, BTreeMap::new(), &providers).unwrap()
        };
        let mut routes = vec![
            candidate(missing.clone()),
            candidate(websocket.clone()),
            candidate(local.clone()),
        ];

        promote_reachable_unix_routes(&mut routes);

        assert_eq!(routes, [candidate(local), candidate(websocket), candidate(missing)]);
    }

    #[test]
    fn sidecar_mux_monitor_detects_the_connected_server_closing() {
        let directory = tempfile::tempdir().unwrap();
        let mux = directory.path().join("mux.sock");
        let listener = std::os::unix::net::UnixListener::bind(&mux).unwrap();
        let (accepted_tx, accepted_rx) = std::sync::mpsc::sync_channel(1);
        let (close_tx, close_rx) = std::sync::mpsc::sync_channel(1);
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            accepted_tx.send(()).unwrap();
            close_rx.recv().unwrap();
            drop(stream);
        });
        let mut monitor = open_mux_monitor(&mux).unwrap();
        accepted_rx.recv().unwrap();

        assert!(!mux_monitor_disconnected(&mut monitor, &mux).unwrap());
        close_tx.send(()).unwrap();
        server.join().unwrap();
        assert!(mux_monitor_disconnected(&mut monitor, &mux).unwrap());
    }

    #[cfg(unix)]
    #[test]
    fn daemon_state_files_are_private_and_existing_permissions_are_tightened() {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};

        let directory = tempfile::tempdir().unwrap();
        let log_path = directory.path().join("daemon.log");
        fs::write(&log_path, b"old log\n").unwrap();
        fs::set_permissions(&log_path, fs::Permissions::from_mode(0o644)).unwrap();

        let mut log = open_private_daemon_file(&log_path, true).unwrap();
        log.write_all(b"new log\n").unwrap();
        let metadata = fs::metadata(&log_path).unwrap();
        assert_eq!(metadata.uid(), unsafe { libc::geteuid() });
        assert_eq!(metadata.nlink(), 1);
        assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
        assert_eq!(fs::read_to_string(&log_path).unwrap(), "old log\nnew log\n");

        let lock_path = directory.path().join("start.lock");
        let lock = open_private_daemon_file(&lock_path, false).unwrap();
        assert_eq!(fs::metadata(&lock_path).unwrap().permissions().mode() & 0o777, 0o600);
        drop(lock);
    }

    #[cfg(unix)]
    #[test]
    fn daemon_state_files_refuse_symlinks_without_touching_target() {
        let directory = tempfile::tempdir().unwrap();
        let target = directory.path().join("target.log");
        let link = directory.path().join("daemon.log");
        fs::write(&target, b"keep\n").unwrap();
        std::os::unix::fs::symlink(&target, &link).unwrap();

        let error = open_private_daemon_file(&link, true).unwrap_err();
        assert_eq!(error.raw_os_error(), Some(libc::ELOOP));
        assert_eq!(fs::read_to_string(&target).unwrap(), "keep\n");
    }

    #[cfg(unix)]
    #[test]
    fn daemon_state_fifo_is_rejected_without_blocking() {
        use std::os::unix::ffi::OsStrExt;
        use std::os::unix::fs::{FileTypeExt, OpenOptionsExt};
        use std::sync::mpsc;

        let directory = tempfile::tempdir().unwrap();
        let fifo = directory.path().join("daemon.log");
        let fifo_bytes = std::ffi::CString::new(fifo.as_os_str().as_bytes()).unwrap();
        let result = unsafe { libc::mkfifo(fifo_bytes.as_ptr(), 0o600) };
        assert_eq!(result, 0, "mkfifo failed: {}", io::Error::last_os_error());

        let (sender, receiver) = mpsc::channel();
        let path = fifo.clone();
        let worker = thread::spawn(move || {
            sender.send(open_private_daemon_file(&path, true).map(|_| ())).unwrap();
        });

        let outcome = receiver.recv_timeout(Duration::from_secs(1));
        if outcome.is_err() {
            // Release a writer that used blocking open in an unfixed build so
            // this regression test fails promptly instead of leaking a thread.
            let reader =
                OpenOptions::new().read(true).custom_flags(libc::O_NONBLOCK).open(&fifo).unwrap();
            let _ = receiver.recv_timeout(Duration::from_secs(1));
            drop(reader);
            worker.join().unwrap();
            panic!("opening a daemon FIFO blocked before type validation");
        }
        worker.join().unwrap();
        let error = outcome.unwrap().unwrap_err();
        assert!(
            error.kind() == io::ErrorKind::InvalidInput
                || error.raw_os_error() == Some(libc::ENXIO),
            "unexpected FIFO rejection: {error}"
        );
        assert!(fs::symlink_metadata(&fifo).unwrap().file_type().is_fifo());
    }

    #[cfg(unix)]
    #[test]
    fn daemon_state_lock_rejects_insecure_parent_before_creation() {
        use std::os::unix::fs::PermissionsExt;

        let directory = tempfile::tempdir().unwrap();
        let shared = directory.path().join("shared");
        fs::create_dir(&shared).unwrap();
        fs::set_permissions(&shared, fs::Permissions::from_mode(0o777)).unwrap();
        let state = shared.join("sessions").join("main");

        let error = lock_daemon_start(&state).unwrap_err();
        assert!(error.to_string().contains("secure daemon state directory"));
        assert!(!state.exists());
    }

    #[cfg(unix)]
    #[test]
    fn daemon_state_lock_rejects_symlink_parent_before_creation() {
        let directory = tempfile::tempdir().unwrap();
        let target = tempfile::tempdir().unwrap();
        let alias = directory.path().join("alias");
        std::os::unix::fs::symlink(target.path(), &alias).unwrap();
        let state = alias.join("sessions").join("main");

        let error = lock_daemon_start(&state).unwrap_err();
        assert!(error.to_string().contains("secure daemon state directory"));
        assert!(!target.path().join("sessions").exists());
    }

    #[cfg(unix)]
    #[test]
    fn timed_out_detached_child_is_killed_and_reaped() {
        let directory = tempfile::tempdir().unwrap();
        let socket = directory.path().join("missing.sock");
        let log = directory.path().join("daemon.log");
        let mut command = Command::new("/bin/sleep");
        command.arg("30");
        configure_detached_process(&mut command);
        let mut child = command.spawn().unwrap();
        let pid = child.id() as libc::pid_t;

        let error = wait_for_detached_socket(
            &mut child,
            &socket,
            Duration::from_millis(100),
            "test detached child",
            &log,
        )
        .unwrap_err();
        let survived_timeout = child.try_wait().unwrap().is_none();
        if survived_timeout {
            unsafe {
                libc::kill(-pid, libc::SIGKILL);
            }
            child.wait().unwrap();
        }

        assert!(error.to_string().contains("did not create"), "{error:#}");
        assert!(!survived_timeout, "timed-out detached child was left running");
    }

    #[test]
    fn enrollment_startup_covers_invitation_and_approval_windows() {
        let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs();
        let invitation = EnrollmentInvitation {
            version: 1,
            id: "id".into(),
            secret: "secret".into(),
            daemon_public_key: "key".into(),
            daemon_fingerprint: "fingerprint".into(),
            daemon_name: "daemon".into(),
            expires_at_unix: now + 120,
            route_hints: vec![],
            relay_access: vec![],
            approval_required: true,
        };

        assert!(
            invitation_timeout(&invitation)
                >= Duration::from_secs(120) + ENROLLMENT_APPROVAL_TIMEOUT
        );
    }

    #[test]
    fn relay_credentials_support_exact_route_scoped_forms() {
        let routes = client_relay_options(
            Some("relay+wss://native.example"),
            vec![],
            vec!["slot".into()],
            vec![ClientRelayCredentialArg::File("ticket".into())],
        )
        .unwrap();
        let native_route = Url::parse("relay+wss://native.example").unwrap().to_string();
        assert_eq!(routes[&native_route].slot, "slot");

        let routes = client_relay_options(
            None,
            vec!["relay+wss://native.example".into(), "relay+do://worker.example".into()],
            vec!["native-slot".into(), "do-slot".into()],
            vec![
                ClientRelayCredentialArg::Command { program: "native-ticket".into(), args: vec![] },
                ClientRelayCredentialArg::File("do-ticket".into()),
            ],
        )
        .unwrap();
        let durable_object_route = Url::parse("relay+do://worker.example").unwrap().to_string();
        assert_eq!(routes[&native_route].slot, "native-slot");
        assert_eq!(routes[&durable_object_route].slot, "do-slot");

        assert!(
            client_relay_options(
                Some("relay+wss://native.example"),
                vec![],
                vec!["slot".into(), "extra".into()],
                vec![
                    ClientRelayCredentialArg::File("ticket".into()),
                    ClientRelayCredentialArg::File("extra".into()),
                ],
            )
            .is_err()
        );
        assert!(
            client_relay_options(
                None,
                vec![],
                vec!["slot".into()],
                vec![ClientRelayCredentialArg::File("ticket".into())],
            )
            .is_err()
        );
        assert!(
            client_relay_options(
                Some("wss://not-a-relay.example/v1/link"),
                vec![],
                vec!["slot".into()],
                vec![ClientRelayCredentialArg::File("ticket".into())],
            )
            .is_err()
        );
    }

    #[test]
    fn connect_rejects_inline_invitation_and_ticket_arguments() {
        let marker = "inline-secret-marker";
        for args in [
            vec!["--invite".to_string(), marker.to_string()],
            vec!["--relay-ticket".to_string(), marker.to_string()],
            vec![format!("--invite={marker}")],
            vec![format!("--relay-ticket={marker}")],
        ] {
            let Err(error) = parse_connect_flags(&args) else {
                panic!("inline secret arguments were accepted: {args:?}");
            };
            assert!(!error.to_string().contains(marker));
        }
    }

    #[test]
    fn enroll_create_rejects_inline_relay_ticket() {
        let marker = "inline-enrollment-secret-marker";
        for args in [
            vec![
                "create".to_string(),
                "--relay-route".to_string(),
                "relay+wss://relay.example".to_string(),
                "--relay-slot".to_string(),
                "slot".to_string(),
                "--relay-ticket".to_string(),
                marker.to_string(),
            ],
            vec!["create".to_string(), format!("--relay-ticket={marker}")],
        ] {
            let Err(error) = parse_enroll_admin_args(&args) else {
                panic!("inline enrollment relay ticket was accepted");
            };
            assert!(!error.to_string().contains(marker));
        }
    }

    #[test]
    fn enrollment_positionals_ignore_owner_options() {
        let args = [
            "disconnect",
            "--session",
            "dev",
            "device-id",
            "--json",
            "0123456789abcdef0123456789abcdef",
        ]
        .map(str::to_string);
        let parsed = parse_enroll_admin_args(&args).unwrap();
        assert_eq!(parsed.positionals, ["device-id", "0123456789abcdef0123456789abcdef"]);
        assert_eq!(parsed.session, "dev");
        assert!(parsed.json);
    }

    #[test]
    fn enrollment_positionals_accept_url_safe_identifiers_beginning_with_hyphen() {
        let approve = [
            "approve",
            "-mRUA1nkvEa07LQJx8XtvQ",
            "--admin-socket",
            "/tmp/cmux-admin.sock",
            "--json",
        ]
        .map(str::to_string);
        assert_eq!(
            parse_enroll_admin_args(&approve).unwrap().positionals,
            ["-mRUA1nkvEa07LQJx8XtvQ"]
        );

        let deny =
            ["deny", "--admin-socket", "/tmp/cmux-admin.sock", "-another-url-safe-id", "--json"]
                .map(str::to_string);
        assert_eq!(parse_enroll_admin_args(&deny).unwrap().positionals, ["-another-url-safe-id"]);

        let disconnect = ["disconnect", "--session", "dev", "-device-id", "-session-id", "--json"]
            .map(str::to_string);
        assert_eq!(
            parse_enroll_admin_args(&disconnect).unwrap().positionals,
            ["-device-id", "-session-id"]
        );
    }

    #[test]
    fn enrollment_admin_parser_rejects_unknown_duplicate_missing_and_inapplicable_arguments() {
        for args in [
            vec!["status", "--wat"],
            vec!["status", "--json", "--json"],
            vec!["status", "--state-dir"],
            vec!["status", "--ttl", "60"],
            vec!["status", "unexpected"],
            vec!["approve"],
            vec!["approve", "id", "extra"],
            vec!["disconnect", "device-only"],
            vec!["disconnect", "device", "session", "extra"],
        ] {
            let args = args.into_iter().map(str::to_string).collect::<Vec<_>>();
            assert!(parse_enroll_admin_args(&args).is_err(), "unexpectedly accepted {args:?}");
        }
    }

    #[test]
    fn known_daemon_parser_is_strict_and_supports_forget() {
        let parsed = parse_known_daemons_args(
            &["forget", "fingerprint", "--state-dir", "/tmp/client-state", "--json"]
                .map(str::to_string),
        )
        .unwrap();
        assert_eq!(parsed.action, KnownDaemonsAction::Forget("fingerprint".into()));
        assert_eq!(parsed.state_dir, Some("/tmp/client-state".into()));
        assert!(parsed.json);

        for args in [
            vec!["forget"],
            vec!["forget", "fingerprint", "extra"],
            vec!["list", "extra"],
            vec!["--json", "--json"],
            vec!["--state-dir"],
            vec!["--unknown"],
        ] {
            let args = args.into_iter().map(str::to_string).collect::<Vec<_>>();
            assert!(parse_known_daemons_args(&args).is_err(), "unexpectedly accepted {args:?}");
        }
    }

    #[test]
    fn remote_stop_parser_rejects_ambiguous_admin_arguments() {
        let parsed = parse_remote_stop_args(
            &["--session", "dev", "--state-dir", "/tmp/remote-state"].map(str::to_string),
        )
        .unwrap();
        assert_eq!(parsed.session, "dev");
        assert_eq!(parsed.state_dir, Some("/tmp/remote-state".into()));
        assert!(!parsed.acknowledge_failed_finalization);
        assert!(!parsed.acknowledge_legacy_finalization);
        assert!(
            parse_remote_stop_args(&["--acknowledge-failed-finalization".into()])
                .unwrap()
                .acknowledge_failed_finalization
        );
        assert!(
            parse_remote_stop_args(&["--acknowledge-legacy-finalization".into()])
                .unwrap()
                .acknowledge_legacy_finalization
        );

        for args in [
            vec!["--session"],
            vec!["--session", "dev", "--session", "other"],
            vec!["--state-dir"],
            vec!["--acknowledge-failed-finalization", "--acknowledge-failed-finalization"],
            vec!["--acknowledge-legacy-finalization", "--acknowledge-legacy-finalization"],
            vec!["--acknowledge-failed-finalization", "--acknowledge-legacy-finalization"],
            vec!["--unknown"],
            vec!["unexpected"],
        ] {
            let args = args.into_iter().map(str::to_string).collect::<Vec<_>>();
            assert!(parse_remote_stop_args(&args).is_err(), "unexpectedly accepted {args:?}");
        }
    }

    #[test]
    fn remote_stop_recovery_copy_uses_selected_locale() {
        let status = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "remote_cli::tests::remote_stop_recovery_copy_locale_fixture",
                "--nocapture",
            ])
            .env("CMUX_TEST_REMOTE_STOP_LOCALE_FIXTURE", "1")
            .env("LC_ALL", "ja_JP.UTF-8")
            .status()
            .unwrap();

        assert!(status.success(), "Japanese remote-stop recovery copy was not localized");
    }

    #[test]
    fn remote_client_help_and_parser_errors_use_selected_locale() {
        let status = Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "remote_cli::tests::remote_client_locale_fixture", "--nocapture"])
            .env("CMUX_TEST_REMOTE_CLIENT_LOCALE_FIXTURE", "1")
            .env("LC_ALL", "ja_JP.UTF-8")
            .status()
            .unwrap();

        assert!(status.success(), "remote client help or parser errors were not localized");
    }

    #[test]
    fn remote_client_locale_fixture() {
        if std::env::var_os("CMUX_TEST_REMOTE_CLIENT_LOCALE_FIXTURE").is_none() {
            return;
        }

        fn assert_japanese(value: &str) {
            assert!(
                value.chars().any(|character| {
                    matches!(
                        character,
                        '\u{3040}'..='\u{30ff}' | '\u{3400}'..='\u{9fff}'
                    )
                }),
                "expected Japanese text, got {value:?}"
            );
        }

        struct FailingInvitationReader;

        impl Read for FailingInvitationReader {
            fn read(&mut self, _buffer: &mut [u8]) -> io::Result<usize> {
                Err(io::Error::other("fixture read failure"))
            }
        }

        for command in [
            "connect",
            "ssh",
            "forward",
            "rpc",
            "enroll",
            "known-daemons",
            "remote-probe",
            "remote-link",
            "install-self",
        ] {
            assert_japanese(remote_help(Some(command)));
        }

        for args in [
            vec!["--lanes", "invalid"],
            vec!["--reconnect-attempts", "0"],
            vec!["--reconnect-jitter", "invalid"],
            vec!["--relay-ticket-command-arg", "value"],
            vec!["--iroh-path", "invalid"],
            vec!["--port", "invalid"],
            vec!["--unknown"],
            vec!["first", "second"],
            vec!["--json"],
        ] {
            let args = args.into_iter().map(str::to_string).collect::<Vec<_>>();
            let error =
                parse_connect_flags(&args).err().expect("invalid connect arguments were accepted");
            assert_japanese(&error.to_string());
        }
        assert_japanese(&run_ssh(&[]).unwrap_err().to_string());
        assert_japanese(&ssh_url("invalid destination").unwrap_err().to_string());
        assert_japanese(&run_forward(&[]).unwrap_err().to_string());
        assert_japanese(&run_rpc(&["--request".into()]).unwrap_err().to_string());
        let missing_invitation = tempfile::tempdir().unwrap().path().join("missing-invitation");
        assert_japanese(&read_invitation_uri(&missing_invitation).unwrap_err().to_string());
        assert_japanese(
            &read_invitation_uri_line(&mut FailingInvitationReader).unwrap_err().to_string(),
        );
        for bytes in [
            Vec::new(),
            b"cmux://enroll/value\nsecond".to_vec(),
            vec![0xff, 0xfe, 0xfd],
            vec![b'x'; MAX_INVITATION_URI_BYTES + 1],
        ] {
            assert_japanese(
                &read_invitation_uri_to_end(&mut io::Cursor::new(bytes)).unwrap_err().to_string(),
            );
        }
        let mut oversized = io::Cursor::new(vec![b'x'; 128]);
        assert_japanese(&read_rpc_stdin_line(&mut oversized, 8).unwrap_err().to_string());
        assert_japanese(
            &client_relay_options(
                None,
                vec![],
                vec!["slot".into()],
                vec![ClientRelayCredentialArg::File("ticket".into())],
            )
            .unwrap_err()
            .to_string(),
        );
        assert_japanese(
            &client_relay_options(
                Some("wss://not-a-relay.example/v1/link"),
                vec![],
                vec!["slot".into()],
                vec![ClientRelayCredentialArg::File("ticket".into())],
            )
            .unwrap_err()
            .to_string(),
        );
        for result in [
            client_relay_options(None, vec![], vec!["slot".into()], vec![]),
            client_relay_options(
                None,
                vec![],
                vec!["one".into(), "two".into()],
                vec![
                    ClientRelayCredentialArg::File("one".into()),
                    ClientRelayCredentialArg::File("two".into()),
                ],
            ),
            client_relay_options(None, vec!["relay+wss://one.example".into()], vec![], vec![]),
            client_relay_options(
                None,
                (0..5).map(|index| format!("relay+wss://relay-{index}.example")).collect(),
                (0..5).map(|index| format!("slot-{index}")).collect(),
                (0..5)
                    .map(|index| ClientRelayCredentialArg::File(format!("ticket-{index}").into()))
                    .collect(),
            ),
            client_relay_options(
                None,
                vec!["wss://not-a-relay.example".into()],
                vec!["slot".into()],
                vec![ClientRelayCredentialArg::File("ticket".into())],
            ),
            client_relay_options(
                None,
                vec!["relay+wss://relay.example".into(), "relay+wss://relay.example".into()],
                vec!["one".into(), "two".into()],
                vec![
                    ClientRelayCredentialArg::File("one".into()),
                    ClientRelayCredentialArg::File("two".into()),
                ],
            ),
        ] {
            assert_japanese(&result.unwrap_err().to_string());
        }

        let directory = tempfile::tempdir().unwrap();
        let store = ClientIdentityStore::load_or_create(directory.path()).unwrap();
        let key = cmux_remote::crypto::StaticIdentity::generate().unwrap().public_key();
        let known = tokio_runtime()
            .unwrap()
            .block_on(store.pin_carrier_daemon(
                "remote".into(),
                key,
                vec!["ssh://remote.example".into()],
            ))
            .unwrap();
        let error = tokio_runtime()
            .unwrap()
            .block_on(select_explicit_route_identity(
                &store,
                Some(&known.fingerprint),
                "wss://remote.example/v1/link",
                SupportedClientAuthModes::DeviceOnly,
            ))
            .err()
            .expect("carrier-only daemon unexpectedly accepted a device-auth route");
        assert_japanese(&error.to_string());

        for args in [
            vec!["unknown"],
            vec!["status", "--unknown"],
            vec!["status", "--json", "--json"],
            vec!["status", "--state-dir"],
            vec!["status", "--ttl", "60"],
            vec!["approve"],
            vec!["disconnect", "device-only"],
            vec!["create", "--ttl", "invalid"],
            vec!["create", "--ttl", "0"],
            vec!["create", "--relay-ticket", "secret"],
        ] {
            let args = args.into_iter().map(str::to_string).collect::<Vec<_>>();
            let error = parse_enroll_admin_args(&args)
                .err()
                .expect("invalid enrollment arguments were accepted");
            assert_japanese(&error.to_string());
        }

        for args in [
            vec!["forget"],
            vec!["forget", "fingerprint", "extra"],
            vec!["list", "extra"],
            vec!["--json", "--json"],
            vec!["--state-dir"],
            vec!["--unknown"],
        ] {
            let args = args.into_iter().map(str::to_string).collect::<Vec<_>>();
            assert_japanese(&parse_known_daemons_args(&args).unwrap_err().to_string());
        }
    }

    #[test]
    fn remote_stop_recovery_copy_locale_fixture() {
        if std::env::var_os("CMUX_TEST_REMOTE_STOP_LOCALE_FIXTURE").is_none() {
            return;
        }

        let help = remote_help(Some("remote-stop"));
        assert!(help.contains("使用方法"), "{help}");
        assert!(help.contains("停止済み"), "{help}");

        let error = parse_remote_stop_args(
            &["--acknowledge-failed-finalization", "--acknowledge-legacy-finalization"]
                .map(str::to_string),
        )
        .err()
        .expect("mutually exclusive recovery flags were accepted")
        .to_string();
        assert!(error.contains("同時に指定できません"), "{error}");

        let directory = tempfile::tempdir_in("/tmp").unwrap();
        let authorization = cmux_remote::identity::AuthDatabase::load_or_create(
            directory.path().join("auth"),
            "localized-stop",
            true,
        )
        .unwrap();
        let error = tokio_runtime()
            .unwrap()
            .block_on(complete_verified_daemon_stop(directory.path(), "localized-stop"))
            .expect_err("stopped-daemon authorization lease unexpectedly had two owners")
            .to_string();
        assert!(error.contains("停止済みデーモンの認可リース"), "{error}");
        drop(authorization);
    }

    #[test]
    fn modern_shutdown_request_binds_the_inspected_lifecycle() {
        let request = shutdown_request_for_lifecycle(Some("inspected-lifecycle"));
        let encoded = serde_json::to_value(request).unwrap();

        assert_eq!(encoded["method"], "shutdown-lifecycle");
        assert_eq!(encoded["lifecycle_id"], "inspected-lifecycle");
        assert_eq!(
            shutdown_request_for_lifecycle(None),
            AdminRequest::Shutdown,
            "legacy runtime metadata must retain its compatible shutdown request"
        );
    }

    #[cfg(unix)]
    #[test]
    fn remote_stop_refuses_embedded_server_with_canonical_owner_command() {
        let directory = tempfile::tempdir().unwrap();
        let session = "embedded-owner";
        let (state_dir, link_socket, admin_socket) =
            daemon_paths(session, Some(directory.path())).unwrap();
        fs::create_dir_all(&state_dir).unwrap();
        fs::write(
            state_dir.join("runtime.json"),
            serde_json::to_vec(&crate::remote_runtime::DaemonRuntimeInfo {
                session: session.into(),
                state_dir,
                link_socket,
                admin_socket,
                daemon_fingerprint: "embedded-daemon".into(),
                routes: Vec::new(),
                direct_websocket: None,
                iroh_node_id: None,
                lifecycle_id: Some("embedded-lifecycle".into()),
                replaceable_sidecar: false,
            })
            .unwrap(),
        )
        .unwrap();

        let error = run_remote_stop(
            &["--session", session, "--state-dir", directory.path().to_string_lossy().as_ref()]
                .map(str::to_string),
        )
        .expect_err("remote stop terminated an embedded server");

        assert!(error.to_string().contains("cmux server stop"), "{error:#}");
        assert!(error.to_string().contains("SSH"), "{error:#}");
    }

    #[cfg(unix)]
    #[test]
    fn legacy_sidecar_process_fixture() {
        use std::os::unix::net::UnixListener;

        let Some(state_dir) = std::env::var_os("CMUX_TEST_LEGACY_SIDECAR_STATE") else {
            return;
        };
        let state_dir = PathBuf::from(state_dir);
        let link_socket = PathBuf::from(std::env::var_os("CMUX_TEST_LEGACY_SIDECAR_LINK").unwrap());
        let admin_socket =
            PathBuf::from(std::env::var_os("CMUX_TEST_LEGACY_SIDECAR_ADMIN").unwrap());
        let ready = PathBuf::from(std::env::var_os("CMUX_TEST_LEGACY_SIDECAR_READY").unwrap());
        let cleanup = PathBuf::from(std::env::var_os("CMUX_TEST_LEGACY_SIDECAR_CLEANUP").unwrap());
        let release = std::env::var_os("CMUX_TEST_LEGACY_SIDECAR_RELEASE").map(PathBuf::from);
        let final_write =
            PathBuf::from(std::env::var_os("CMUX_TEST_LEGACY_SIDECAR_FINAL_WRITE").unwrap());
        let session = std::env::var("CMUX_TEST_LEGACY_SIDECAR_SESSION")
            .unwrap_or_else(|_| "legacy-handoff".into());
        let lifecycle_id = std::env::var("CMUX_TEST_LEGACY_SIDECAR_LIFECYCLE_ID").ok();
        fs::create_dir_all(&state_dir).unwrap();
        let link_listener = UnixListener::bind(&link_socket).unwrap();
        let admin_listener = UnixListener::bind(&admin_socket).unwrap();
        let runtime = crate::remote_runtime::DaemonRuntimeInfo {
            session,
            state_dir: state_dir.clone(),
            link_socket: link_socket.clone(),
            admin_socket: admin_socket.clone(),
            daemon_fingerprint: "legacy-daemon".into(),
            routes: vec![format!("unix://{}", link_socket.display())],
            direct_websocket: None,
            iroh_node_id: None,
            lifecycle_id: lifecycle_id.clone(),
            replaceable_sidecar: true,
        };
        fs::write(state_dir.join("runtime.json"), serde_json::to_vec_pretty(&runtime).unwrap())
            .unwrap();
        fs::write(&ready, b"ready").unwrap();

        let (stream, _) = admin_listener.accept().unwrap();
        let mut stream = io::BufReader::new(stream);
        let mut request = String::new();
        stream.read_line(&mut request).unwrap();
        let expected_request = match &lifecycle_id {
            Some(lifecycle_id) => {
                AdminRequest::ShutdownLifecycle { lifecycle_id: lifecycle_id.clone() }
            }
            None => AdminRequest::Shutdown,
        };
        assert_eq!(serde_json::from_str::<AdminRequest>(&request).unwrap(), expected_request);
        serde_json::to_writer(
            stream.get_mut(),
            &AdminResponse { ok: true, result: Some(serde_json::json!({})), error: None },
        )
        .unwrap();
        stream.get_mut().write_all(b"\n").unwrap();
        stream.get_mut().flush().unwrap();
        drop(stream);
        drop(admin_listener);
        drop(link_listener);
        fs::remove_file(&admin_socket).unwrap();
        fs::remove_file(&link_socket).unwrap();
        if let Some(lifecycle_id) = lifecycle_id {
            fs::write(
                state_dir.join("shutdown.json"),
                serde_json::to_vec_pretty(&serde_json::json!({
                    "version": 1,
                    "lifecycle_id": lifecycle_id,
                    "status": "failed",
                }))
                .unwrap(),
            )
            .unwrap();
        }
        fs::remove_file(state_dir.join("runtime.json")).unwrap();
        fs::write(&cleanup, b"legacy-cleanup-published").unwrap();

        if let Some(release) = release {
            let deadline = Instant::now() + Duration::from_secs(5);
            while !release.exists() {
                assert!(
                    Instant::now() < deadline,
                    "legacy sidecar finalization was never released"
                );
                thread::sleep(Duration::from_millis(1));
            }
        }
        fs::write(final_write, b"legacy-final-auth-write").unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn remote_stop_waits_for_legacy_sidecar_process_exit_before_upgrade_handoff() {
        let directory = tempfile::tempdir_in("/tmp").unwrap();
        let session = "legacy-handoff";
        let (state_dir, link_socket, admin_socket) =
            daemon_paths(session, Some(directory.path())).unwrap();
        seed_legacy_authorization_state(&state_dir);
        let ready = directory.path().join("legacy-ready");
        let cleanup = directory.path().join("legacy-cleanup-published");
        let release = directory.path().join("release-legacy-finalization");
        let final_write = directory.path().join("legacy-final-auth-write");
        let mut child = Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "remote_cli::tests::legacy_sidecar_process_fixture", "--nocapture"])
            .env("CMUX_TEST_LEGACY_SIDECAR_STATE", &state_dir)
            .env("CMUX_TEST_LEGACY_SIDECAR_LINK", &link_socket)
            .env("CMUX_TEST_LEGACY_SIDECAR_ADMIN", &admin_socket)
            .env("CMUX_TEST_LEGACY_SIDECAR_READY", &ready)
            .env("CMUX_TEST_LEGACY_SIDECAR_CLEANUP", &cleanup)
            .env("CMUX_TEST_LEGACY_SIDECAR_RELEASE", &release)
            .env("CMUX_TEST_LEGACY_SIDECAR_FINAL_WRITE", &final_write)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
        let ready_deadline = Instant::now() + Duration::from_secs(5);
        while !ready.exists() {
            if let Some(status) = child.try_wait().unwrap() {
                panic!("legacy sidecar fixture exited before startup: {status}");
            }
            assert!(Instant::now() < ready_deadline, "legacy sidecar fixture did not start");
            thread::sleep(Duration::from_millis(1));
        }

        let state_root = directory.path().to_string_lossy().into_owned();
        let stopper = thread::spawn(move || {
            run_remote_stop(
                &["--session", session, "--state-dir", state_root.as_str()].map(str::to_string),
            )
        });
        let cleanup_deadline = Instant::now() + Duration::from_secs(5);
        while !cleanup.exists() {
            assert!(
                !stopper.is_finished(),
                "remote-stop returned before the legacy daemon published lifecycle cleanup"
            );
            assert!(
                Instant::now() < cleanup_deadline,
                "legacy daemon did not publish lifecycle cleanup"
            );
            thread::sleep(Duration::from_millis(1));
        }
        let early_return_deadline = Instant::now() + Duration::from_millis(500);
        while !stopper.is_finished() && Instant::now() < early_return_deadline {
            thread::sleep(Duration::from_millis(1));
        }
        let returned_before_process_exit = stopper.is_finished();

        fs::write(&release, b"release").unwrap();
        let stop_result = stopper.join().unwrap();
        let child_status = child.wait().unwrap();
        assert!(stop_result.is_ok(), "remote-stop failed: {stop_result:?}");
        assert!(child_status.success(), "legacy sidecar fixture failed: {child_status}");
        assert!(
            final_write.exists(),
            "legacy sidecar did not complete its final authorization write"
        );
        assert!(
            !returned_before_process_exit,
            "remote-stop returned after runtime.json removal but before legacy process exit"
        );
        assert!(
            state_dir.join("lifecycle-fence.json").exists(),
            "process-fenced legacy shutdown did not publish a lifecycle fence"
        );
        assert_eq!(
            cmux_remote::identity::persisted_auth_state_version(&state_dir.join("auth")).unwrap(),
            Some(cmux_remote::identity::AUTH_STATE_VERSION),
            "process-fenced legacy shutdown did not publish its rollback fence"
        );
    }

    #[cfg(unix)]
    #[test]
    fn remote_stop_rejects_failed_authorization_finalization() {
        let directory = tempfile::tempdir_in("/tmp").unwrap();
        let session = "failed-finalization";
        let lifecycle_id = "failed-finalization-instance";
        let (state_dir, link_socket, admin_socket) =
            daemon_paths(session, Some(directory.path())).unwrap();
        let ready = directory.path().join("failed-finalization-ready");
        let cleanup = directory.path().join("failed-finalization-cleanup");
        let final_write = directory.path().join("failed-finalization-auth-write");
        let mut child = Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "remote_cli::tests::legacy_sidecar_process_fixture", "--nocapture"])
            .env("CMUX_TEST_LEGACY_SIDECAR_STATE", &state_dir)
            .env("CMUX_TEST_LEGACY_SIDECAR_LINK", &link_socket)
            .env("CMUX_TEST_LEGACY_SIDECAR_ADMIN", &admin_socket)
            .env("CMUX_TEST_LEGACY_SIDECAR_READY", &ready)
            .env("CMUX_TEST_LEGACY_SIDECAR_CLEANUP", &cleanup)
            .env("CMUX_TEST_LEGACY_SIDECAR_FINAL_WRITE", &final_write)
            .env("CMUX_TEST_LEGACY_SIDECAR_SESSION", session)
            .env("CMUX_TEST_LEGACY_SIDECAR_LIFECYCLE_ID", lifecycle_id)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
        let ready_deadline = Instant::now() + Duration::from_secs(5);
        while !ready.exists() {
            if let Some(status) = child.try_wait().unwrap() {
                panic!("failed-finalization fixture exited before startup: {status}");
            }
            assert!(Instant::now() < ready_deadline, "failed-finalization fixture did not start");
            thread::sleep(Duration::from_millis(1));
        }

        let stop_result = run_remote_stop(
            &["--session", session, "--state-dir", directory.path().to_string_lossy().as_ref()]
                .map(str::to_string),
        );
        let child_status = child.wait().unwrap();
        assert!(child_status.success(), "failed-finalization fixture failed: {child_status}");
        assert!(final_write.exists(), "fixture did not complete its final authorization write");
        let error = stop_result.expect_err("failed authorization finalization reported success");
        assert!(error.to_string().contains("authorization finalization"), "{error:#}");
    }

    #[cfg(unix)]
    #[test]
    fn shutdown_outcome_requires_exact_lifecycle_and_success() {
        let directory = tempfile::tempdir().unwrap();
        let outcome = directory.path().join("shutdown.json");
        let missing = verify_shutdown_outcome(directory.path(), "current").unwrap_err();
        assert!(missing.to_string().contains("authorization finalization"), "{missing:#}");

        fs::write(&outcome, b"{not-json").unwrap();
        let malformed = verify_shutdown_outcome(directory.path(), "current").unwrap_err();
        assert!(malformed.to_string().contains("authorization finalization"), "{malformed:#}");

        fs::write(
            &outcome,
            serde_json::to_vec(&serde_json::json!({
                "version": 1,
                "lifecycle_id": "stale",
                "status": "succeeded",
            }))
            .unwrap(),
        )
        .unwrap();
        let stale = verify_shutdown_outcome(directory.path(), "current").unwrap_err();
        assert!(stale.to_string().contains("different daemon lifecycle"), "{stale:#}");

        fs::write(
            &outcome,
            serde_json::to_vec(&serde_json::json!({
                "version": 1,
                "lifecycle_id": "current",
                "status": "failed",
            }))
            .unwrap(),
        )
        .unwrap();
        let failed = verify_shutdown_outcome(directory.path(), "current").unwrap_err();
        assert!(failed.to_string().contains("authorization finalization failed"), "{failed:#}");

        fs::write(
            &outcome,
            serde_json::to_vec(&serde_json::json!({
                "version": 1,
                "lifecycle_id": "current",
                "status": "succeeded",
            }))
            .unwrap(),
        )
        .unwrap();
        verify_shutdown_outcome(directory.path(), "current").unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn remote_stop_without_runtime_rejects_failed_authorization_finalization() {
        let directory = tempfile::tempdir().unwrap();
        let session = "inactive-failed-finalization";
        let (state_dir, _, _) = daemon_paths(session, Some(directory.path())).unwrap();
        fs::create_dir_all(&state_dir).unwrap();
        fs::write(
            state_dir.join("shutdown.json"),
            serde_json::to_vec(&serde_json::json!({
                "version": 1,
                "lifecycle_id": "failed-lifecycle",
                "status": "failed",
            }))
            .unwrap(),
        )
        .unwrap();

        let error = run_remote_stop(
            &["--session", session, "--state-dir", directory.path().to_string_lossy().as_ref()]
                .map(str::to_string),
        )
        .expect_err("inactive failed authorization finalization was treated as clean");
        assert!(error.to_string().contains("authorization finalization"), "{error:#}");
    }

    #[cfg(unix)]
    #[test]
    fn remote_stop_without_runtime_rejects_malformed_authorization_finalization() {
        let directory = tempfile::tempdir().unwrap();
        let session = "inactive-malformed-finalization";
        let (state_dir, _, _) = daemon_paths(session, Some(directory.path())).unwrap();
        fs::create_dir_all(&state_dir).unwrap();
        fs::write(state_dir.join("shutdown.json"), b"{not-json").unwrap();

        let error = run_remote_stop(
            &["--session", session, "--state-dir", directory.path().to_string_lossy().as_ref()]
                .map(str::to_string),
        )
        .expect_err("inactive malformed authorization finalization was treated as clean");
        assert!(error.to_string().contains("authorization finalization"), "{error:#}");
    }

    #[cfg(unix)]
    #[test]
    fn remote_stop_explicitly_acknowledges_inactive_failed_authorization_finalization() {
        let directory = tempfile::tempdir().unwrap();
        let session = "acknowledge-failed-finalization";
        let (state_dir, _, _) = daemon_paths(session, Some(directory.path())).unwrap();
        fs::create_dir_all(&state_dir).unwrap();
        let outcome = state_dir.join("shutdown.json");
        fs::write(
            &outcome,
            serde_json::to_vec(&serde_json::json!({
                "version": 1,
                "lifecycle_id": "failed-lifecycle",
                "status": "failed",
            }))
            .unwrap(),
        )
        .unwrap();

        run_remote_stop(
            &[
                "--session",
                session,
                "--state-dir",
                directory.path().to_string_lossy().as_ref(),
                "--acknowledge-failed-finalization",
            ]
            .map(str::to_string),
        )
        .unwrap();

        assert!(!outcome.exists());
        run_remote_stop(
            &["--session", session, "--state-dir", directory.path().to_string_lossy().as_ref()]
                .map(str::to_string),
        )
        .unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn remote_stop_explicitly_acknowledges_inactive_legacy_authorization_state() {
        let directory = tempfile::tempdir().unwrap();
        let session = "acknowledge-inactive-legacy";
        let (state_dir, _, _) = daemon_paths(session, Some(directory.path())).unwrap();
        seed_legacy_authorization_state(&state_dir);
        persist_daemon_lifecycle_fence(&state_dir).unwrap();

        let error = run_remote_stop(
            &["--session", session, "--state-dir", directory.path().to_string_lossy().as_ref()]
                .map(str::to_string),
        )
        .expect_err("inactive legacy state migrated without explicit acknowledgement");
        assert!(error.to_string().contains("--acknowledge-legacy-finalization"), "{error:#}");

        run_remote_stop(
            &[
                "--session",
                session,
                "--state-dir",
                directory.path().to_string_lossy().as_ref(),
                "--acknowledge-legacy-finalization",
            ]
            .map(str::to_string),
        )
        .unwrap();

        assert!(state_dir.join("lifecycle-fence.json").exists());
        assert_eq!(
            cmux_remote::identity::persisted_auth_state_version(&state_dir.join("auth")).unwrap(),
            Some(cmux_remote::identity::AUTH_STATE_VERSION)
        );
        let runtime = start_daemon_runtime(
            directory.path().join("missing-mux.sock"),
            DaemonRuntimeOptions {
                session: session.into(),
                state_dir: Some(directory.path().to_path_buf()),
                link_socket: None,
                admin_socket: None,
                direct_websocket: None,
                allow_insecure_non_loopback: false,
                workspace_http: None,
                relays: Vec::new(),
                iroh: false,
                advertised_routes: Vec::new(),
                resume_lease: Duration::from_secs(2),
                replaceable_sidecar: true,
            },
        )
        .expect("acknowledged legacy state remained blocked");
        runtime.shutdown().unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn remote_stop_failed_acknowledgement_does_not_create_empty_authorization_state() {
        let directory = tempfile::tempdir().unwrap();
        let session = "empty-failed-acknowledgement";
        let (state_dir, _, _) = daemon_paths(session, Some(directory.path())).unwrap();

        run_remote_stop(
            &[
                "--session",
                session,
                "--state-dir",
                directory.path().to_string_lossy().as_ref(),
                "--acknowledge-failed-finalization",
            ]
            .map(str::to_string),
        )
        .expect_err("empty failed-finalization acknowledgement succeeded");

        assert!(
            !state_dir.join("auth").exists(),
            "rejected acknowledgement created authorization state"
        );
    }

    #[cfg(unix)]
    #[test]
    fn remote_stop_acknowledges_matching_stale_runtime_finalization() {
        let directory = tempfile::tempdir().unwrap();
        let session = "acknowledge-stale-runtime";
        let lifecycle_id = "stale-runtime-lifecycle";
        let (state_dir, link_socket, admin_socket) =
            daemon_paths(session, Some(directory.path())).unwrap();
        fs::create_dir_all(&state_dir).unwrap();
        let runtime_path = state_dir.join("runtime.json");
        fs::write(
            &runtime_path,
            serde_json::to_vec(&crate::remote_runtime::DaemonRuntimeInfo {
                session: session.into(),
                state_dir: state_dir.clone(),
                link_socket,
                admin_socket,
                daemon_fingerprint: "stopped-daemon".into(),
                routes: Vec::new(),
                direct_websocket: None,
                iroh_node_id: None,
                lifecycle_id: Some(lifecycle_id.into()),
                replaceable_sidecar: true,
            })
            .unwrap(),
        )
        .unwrap();
        let outcome = state_dir.join("shutdown.json");
        fs::write(
            &outcome,
            serde_json::to_vec(&serde_json::json!({
                "version": 1,
                "lifecycle_id": lifecycle_id,
                "status": "failed",
            }))
            .unwrap(),
        )
        .unwrap();

        run_remote_stop(
            &[
                "--session",
                session,
                "--state-dir",
                directory.path().to_string_lossy().as_ref(),
                "--acknowledge-failed-finalization",
            ]
            .map(str::to_string),
        )
        .unwrap();

        assert!(!runtime_path.exists());
        assert!(!outcome.exists());
    }

    #[cfg(unix)]
    #[test]
    fn remote_stop_acknowledgement_uses_recorded_custom_sockets() {
        let directory = tempfile::tempdir_in("/tmp").unwrap();
        let session = "acknowledge-custom-sockets";
        let lifecycle_id = "custom-socket-lifecycle";
        let (state_dir, default_link, _) = daemon_paths(session, Some(directory.path())).unwrap();
        fs::create_dir_all(&state_dir).unwrap();
        let _unrelated_default_listener =
            std::os::unix::net::UnixListener::bind(&default_link).unwrap();
        let runtime_path = state_dir.join("runtime.json");
        fs::write(
            &runtime_path,
            serde_json::to_vec(&crate::remote_runtime::DaemonRuntimeInfo {
                session: session.into(),
                state_dir: state_dir.clone(),
                link_socket: state_dir.join("custom-link.sock"),
                admin_socket: state_dir.join("custom-admin.sock"),
                daemon_fingerprint: "stopped-daemon".into(),
                routes: Vec::new(),
                direct_websocket: None,
                iroh_node_id: None,
                lifecycle_id: Some(lifecycle_id.into()),
                replaceable_sidecar: true,
            })
            .unwrap(),
        )
        .unwrap();
        let outcome = state_dir.join("shutdown.json");
        fs::write(
            &outcome,
            serde_json::to_vec(&serde_json::json!({
                "version": 1,
                "lifecycle_id": lifecycle_id,
                "status": "failed",
            }))
            .unwrap(),
        )
        .unwrap();

        run_remote_stop(
            &[
                "--session",
                session,
                "--state-dir",
                directory.path().to_string_lossy().as_ref(),
                "--acknowledge-failed-finalization",
            ]
            .map(str::to_string),
        )
        .unwrap();

        assert!(!runtime_path.exists());
        assert!(!outcome.exists());
    }

    #[cfg(unix)]
    #[test]
    fn remote_stop_acknowledges_stale_failed_runtime_finalization() {
        let directory = tempfile::tempdir().unwrap();
        let session = "acknowledge-stale-failed-runtime";
        let (state_dir, link_socket, admin_socket) =
            daemon_paths(session, Some(directory.path())).unwrap();
        fs::create_dir_all(&state_dir).unwrap();
        let runtime_path = state_dir.join("runtime.json");
        fs::write(
            &runtime_path,
            serde_json::to_vec(&crate::remote_runtime::DaemonRuntimeInfo {
                session: session.into(),
                state_dir: state_dir.clone(),
                link_socket,
                admin_socket,
                daemon_fingerprint: "stopped-daemon".into(),
                routes: Vec::new(),
                direct_websocket: None,
                iroh_node_id: None,
                lifecycle_id: Some("runtime-lifecycle".into()),
                replaceable_sidecar: true,
            })
            .unwrap(),
        )
        .unwrap();
        let outcome = state_dir.join("shutdown.json");
        fs::write(
            &outcome,
            serde_json::to_vec(&serde_json::json!({
                "version": 1,
                "lifecycle_id": "different-lifecycle",
                "status": "failed",
            }))
            .unwrap(),
        )
        .unwrap();

        run_remote_stop(
            &[
                "--session",
                session,
                "--state-dir",
                directory.path().to_string_lossy().as_ref(),
                "--acknowledge-failed-finalization",
            ]
            .map(str::to_string),
        )
        .unwrap();

        assert!(!runtime_path.exists());
        assert!(!outcome.exists());
    }

    #[cfg(unix)]
    #[test]
    fn remote_stop_refuses_recovery_while_recorded_socket_is_active() {
        let directory = tempfile::tempdir().unwrap();
        let session = "reject-active-recovery";
        let (state_dir, _, admin_socket) = daemon_paths(session, Some(directory.path())).unwrap();
        let link_socket = directory.path().join("recorded-active-link.sock");
        fs::create_dir_all(&state_dir).unwrap();
        let listener = std::os::unix::net::UnixListener::bind(&link_socket).unwrap();
        let runtime_path = state_dir.join("runtime.json");
        fs::write(
            &runtime_path,
            serde_json::to_vec(&crate::remote_runtime::DaemonRuntimeInfo {
                session: session.into(),
                state_dir: state_dir.clone(),
                link_socket,
                admin_socket,
                daemon_fingerprint: "active-daemon".into(),
                routes: Vec::new(),
                direct_websocket: None,
                iroh_node_id: None,
                lifecycle_id: Some("active-lifecycle".into()),
                replaceable_sidecar: true,
            })
            .unwrap(),
        )
        .unwrap();

        let error = run_remote_stop(
            &[
                "--session",
                session,
                "--state-dir",
                directory.path().to_string_lossy().as_ref(),
                "--acknowledge-failed-finalization",
            ]
            .map(str::to_string),
        )
        .expect_err("active daemon recovery was acknowledged");

        assert!(error.to_string().contains("daemon socket"), "{error:#}");
        assert!(runtime_path.exists());
        assert!(
            !state_dir.join("auth").exists(),
            "rejected recovery created authorization state before probing the active socket"
        );
        drop(listener);
    }

    #[cfg(unix)]
    #[test]
    fn remote_stop_refuses_legacy_acknowledgement_while_recorded_socket_is_active() {
        let directory = tempfile::tempdir().unwrap();
        let session = "reject-active-legacy-acknowledgement";
        let (state_dir, _, admin_socket) = daemon_paths(session, Some(directory.path())).unwrap();
        let link_socket = directory.path().join("recorded-active-legacy-link.sock");
        seed_legacy_authorization_state(&state_dir);
        let listener = std::os::unix::net::UnixListener::bind(&link_socket).unwrap();
        fs::write(
            state_dir.join("runtime.json"),
            serde_json::to_vec(&crate::remote_runtime::DaemonRuntimeInfo {
                session: session.into(),
                state_dir: state_dir.clone(),
                link_socket,
                admin_socket,
                daemon_fingerprint: "active-legacy-daemon".into(),
                routes: Vec::new(),
                direct_websocket: None,
                iroh_node_id: None,
                lifecycle_id: None,
                replaceable_sidecar: true,
            })
            .unwrap(),
        )
        .unwrap();

        let error = run_remote_stop(
            &[
                "--session",
                session,
                "--state-dir",
                directory.path().to_string_lossy().as_ref(),
                "--acknowledge-legacy-finalization",
            ]
            .map(str::to_string),
        )
        .expect_err("active legacy daemon was acknowledged");

        assert!(error.to_string().contains("daemon socket"), "{error:#}");
        assert!(!state_dir.join("lifecycle-fence.json").exists());
        assert_eq!(
            cmux_remote::identity::persisted_auth_state_version(&state_dir.join("auth")).unwrap(),
            Some(1),
            "rejected recovery migrated authorization state before probing the active socket"
        );
        drop(listener);
    }

    #[cfg(unix)]
    #[test]
    fn remote_stop_explicitly_removes_malformed_inactive_runtime_metadata() {
        let directory = tempfile::tempdir().unwrap();
        let session = "acknowledge-malformed-runtime";
        let (state_dir, _, _) = daemon_paths(session, Some(directory.path())).unwrap();
        drop(
            cmux_remote::identity::AuthDatabase::load_or_create(
                state_dir.join("auth"),
                session,
                true,
            )
            .unwrap(),
        );
        persist_daemon_lifecycle_fence(&state_dir).unwrap();
        let runtime_path = state_dir.join("runtime.json");
        fs::write(&runtime_path, b"{not-json").unwrap();

        let error = run_remote_stop(
            &["--session", session, "--state-dir", directory.path().to_string_lossy().as_ref()]
                .map(str::to_string),
        )
        .expect_err("malformed runtime metadata was reported as stopped");
        assert!(error.to_string().contains("--acknowledge-legacy-finalization"), "{error:#}");

        run_remote_stop(
            &[
                "--session",
                session,
                "--state-dir",
                directory.path().to_string_lossy().as_ref(),
                "--acknowledge-legacy-finalization",
            ]
            .map(str::to_string),
        )
        .unwrap();

        assert!(!runtime_path.exists());
    }

    #[cfg(unix)]
    #[test]
    fn malformed_runtime_and_failed_outcome_have_a_complete_recovery_path() {
        let directory = tempfile::tempdir().unwrap();
        let session = "acknowledge-malformed-runtime-and-failure";
        let (state_dir, _, _) = daemon_paths(session, Some(directory.path())).unwrap();
        drop(
            cmux_remote::identity::AuthDatabase::load_or_create(
                state_dir.join("auth"),
                session,
                true,
            )
            .unwrap(),
        );
        persist_daemon_lifecycle_fence(&state_dir).unwrap();
        let runtime_path = state_dir.join("runtime.json");
        let outcome_path = state_dir.join("shutdown.json");
        fs::write(&runtime_path, b"{not-json").unwrap();
        fs::write(
            &outcome_path,
            serde_json::to_vec(&serde_json::json!({
                "version": 1,
                "lifecycle_id": "failed-lifecycle",
                "status": "failed",
            }))
            .unwrap(),
        )
        .unwrap();

        run_remote_stop(
            &[
                "--session",
                session,
                "--state-dir",
                directory.path().to_string_lossy().as_ref(),
                "--acknowledge-legacy-finalization",
            ]
            .map(str::to_string),
        )
        .unwrap();
        assert!(!runtime_path.exists());
        assert!(outcome_path.exists(), "legacy recovery discarded failed shutdown evidence");

        run_remote_stop(
            &[
                "--session",
                session,
                "--state-dir",
                directory.path().to_string_lossy().as_ref(),
                "--acknowledge-failed-finalization",
            ]
            .map(str::to_string),
        )
        .unwrap();
        assert!(!outcome_path.exists());
    }

    #[cfg(unix)]
    #[test]
    fn remote_stop_acknowledges_malformed_outcome_without_runtime_metadata() {
        let directory = tempfile::tempdir().unwrap();
        let session = "acknowledge-malformed-outcome";
        let (state_dir, _, _) = daemon_paths(session, Some(directory.path())).unwrap();
        fs::create_dir_all(&state_dir).unwrap();
        let outcome = state_dir.join("shutdown.json");
        fs::write(&outcome, b"{not-json").unwrap();

        run_remote_stop(
            &[
                "--session",
                session,
                "--state-dir",
                directory.path().to_string_lossy().as_ref(),
                "--acknowledge-failed-finalization",
            ]
            .map(str::to_string),
        )
        .unwrap();

        assert!(!outcome.exists());
    }

    #[cfg(unix)]
    #[test]
    fn remote_stop_acknowledges_unclean_runtime_without_current_failure_outcome() {
        for case in ["missing", "stale-success", "malformed"] {
            let directory = tempfile::tempdir().unwrap();
            let session = format!("acknowledge-unclean-{case}");
            let lifecycle_id = format!("unclean-runtime-{case}");
            let (state_dir, link_socket, admin_socket) =
                daemon_paths(&session, Some(directory.path())).unwrap();
            fs::create_dir_all(&state_dir).unwrap();
            let runtime_path = state_dir.join("runtime.json");
            fs::write(
                &runtime_path,
                serde_json::to_vec(&crate::remote_runtime::DaemonRuntimeInfo {
                    session: session.clone(),
                    state_dir: state_dir.clone(),
                    link_socket,
                    admin_socket,
                    daemon_fingerprint: "unclean-daemon".into(),
                    routes: Vec::new(),
                    direct_websocket: None,
                    iroh_node_id: None,
                    lifecycle_id: Some(lifecycle_id),
                    replaceable_sidecar: true,
                })
                .unwrap(),
            )
            .unwrap();
            let outcome = state_dir.join("shutdown.json");
            match case {
                "missing" => {}
                "stale-success" => fs::write(
                    &outcome,
                    serde_json::to_vec(&serde_json::json!({
                        "version": 1,
                        "lifecycle_id": "prior-lifecycle",
                        "status": "succeeded",
                    }))
                    .unwrap(),
                )
                .unwrap(),
                "malformed" => fs::write(&outcome, b"{not-json").unwrap(),
                _ => unreachable!(),
            }

            run_remote_stop(
                &[
                    "--session",
                    session.as_str(),
                    "--state-dir",
                    directory.path().to_string_lossy().as_ref(),
                    "--acknowledge-failed-finalization",
                ]
                .map(str::to_string),
            )
            .unwrap_or_else(|error| panic!("{case}: {error:#}"));

            assert!(!runtime_path.exists(), "{case}");
            assert!(!outcome.exists(), "{case}");
        }
    }

    #[test]
    fn relay_invitation_access_reads_owner_supplied_ticket_file() {
        use std::os::unix::fs::PermissionsExt as _;

        let directory = tempfile::tempdir().unwrap();
        let ticket = directory.path().join("ticket");
        fs::write(&ticket, "short-lived-ticket\n").unwrap();
        fs::set_permissions(&ticket, fs::Permissions::from_mode(0o600)).unwrap();
        let args = vec![
            "create".into(),
            "--relay-route".into(),
            "relay+do://relay.example".into(),
            "--relay-slot".into(),
            "slot".into(),
            "--relay-ticket-file".into(),
            ticket.to_string_lossy().into_owned(),
        ];
        let parsed = parse_enroll_admin_args(&args).unwrap();
        let access = invitation_relay_access(&parsed).unwrap();
        assert_eq!(access[0].ticket, "short-lived-ticket");
        assert!(!format!("{:?}", access[0]).contains("short-lived-ticket"));
    }

    #[cfg(unix)]
    #[test]
    fn invitation_relay_ticket_file_requires_owner_only_permissions() {
        use std::os::unix::fs::PermissionsExt as _;

        let directory = tempfile::tempdir().unwrap();
        let ticket = directory.path().join("ticket");
        fs::write(&ticket, "short-lived-ticket\n").unwrap();
        fs::set_permissions(&ticket, fs::Permissions::from_mode(0o600)).unwrap();
        assert_eq!(read_invitation_ticket_file(&ticket).unwrap(), "short-lived-ticket");

        fs::set_permissions(&ticket, fs::Permissions::from_mode(0o640)).unwrap();
        assert!(read_invitation_ticket_file(&ticket).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn invitation_relay_ticket_file_accepts_maximum_ticket_with_newline() {
        use std::os::unix::fs::PermissionsExt as _;

        let directory = tempfile::tempdir().unwrap();
        let ticket = directory.path().join("ticket");
        let mut contents = vec![b'x'; 4 * 1024];
        contents.push(b'\n');
        fs::write(&ticket, contents).unwrap();
        fs::set_permissions(&ticket, fs::Permissions::from_mode(0o600)).unwrap();

        assert_eq!(read_invitation_ticket_file(&ticket).unwrap().len(), 4 * 1024);
    }

    #[cfg(unix)]
    #[test]
    fn invitation_relay_ticket_file_rejects_symlinks() {
        use std::os::unix::fs::{PermissionsExt as _, symlink};

        let directory = tempfile::tempdir().unwrap();
        let target = directory.path().join("target");
        let link = directory.path().join("ticket");
        fs::write(&target, "short-lived-ticket\n").unwrap();
        fs::set_permissions(&target, fs::Permissions::from_mode(0o600)).unwrap();
        symlink(&target, &link).unwrap();

        assert!(read_invitation_ticket_file(&link).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn install_self_does_not_follow_predictable_staging_symlink() {
        use std::os::unix::fs::symlink;

        let directory = tempfile::tempdir().unwrap();
        let sentinel = directory.path().join("sentinel");
        let destination = directory.path().join("cmux-tui");
        let predictable =
            directory.path().join(format!(".cmux-tui-install-{}", std::process::id()));
        fs::write(&sentinel, b"keep").unwrap();
        symlink(&sentinel, &predictable).unwrap();

        run_install_self(&["--destination".into(), destination.to_string_lossy().into_owned()])
            .unwrap();

        assert_eq!(fs::read(&sentinel).unwrap(), b"keep");
        assert!(fs::symlink_metadata(&destination).unwrap().file_type().is_file());
    }

    #[cfg(unix)]
    #[test]
    fn install_self_atomically_replaces_destination_symlink() {
        use std::os::unix::fs::symlink;

        let directory = tempfile::tempdir().unwrap();
        let sentinel = directory.path().join("sentinel");
        let destination = directory.path().join("cmux-tui");
        fs::write(&sentinel, b"keep").unwrap();
        symlink(&sentinel, &destination).unwrap();

        run_install_self(&["--destination".into(), destination.to_string_lossy().into_owned()])
            .unwrap();

        assert_eq!(fs::read(&sentinel).unwrap(), b"keep");
        assert!(fs::symlink_metadata(&destination).unwrap().file_type().is_file());
    }

    #[cfg(unix)]
    #[test]
    fn install_self_rejects_group_or_world_writable_parent() {
        use std::os::unix::fs::PermissionsExt as _;

        let directory = tempfile::tempdir().unwrap();
        let parent = directory.path().join("shared");
        fs::create_dir(&parent).unwrap();
        fs::set_permissions(&parent, fs::Permissions::from_mode(0o777)).unwrap();
        let destination = parent.join("cmux-tui");

        assert!(
            run_install_self(
                &["--destination".into(), destination.to_string_lossy().into_owned(),]
            )
            .is_err()
        );
        assert!(!destination.exists());
    }

    #[test]
    fn relay_invitation_access_supports_native_and_durable_object_fallbacks() {
        use std::os::unix::fs::PermissionsExt as _;

        let directory = tempfile::tempdir().unwrap();
        let native_ticket = directory.path().join("native-ticket");
        let durable_object_ticket = directory.path().join("do-ticket");
        for (path, contents) in
            [(&native_ticket, "native-ticket\n"), (&durable_object_ticket, "do-ticket\n")]
        {
            fs::write(path, contents).unwrap();
            fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
        }
        let args = vec![
            "create".into(),
            "--relay-route".into(),
            "relay+wss://relay.example".into(),
            "--relay-slot".into(),
            "native-slot".into(),
            "--relay-ticket-file".into(),
            native_ticket.to_string_lossy().into_owned(),
            "--relay-route".into(),
            "relay+do://worker.example".into(),
            "--relay-slot".into(),
            "do-slot".into(),
            "--relay-ticket-file".into(),
            durable_object_ticket.to_string_lossy().into_owned(),
        ];

        let parsed = parse_enroll_admin_args(&args).unwrap();
        let access = invitation_relay_access(&parsed).unwrap();
        assert_eq!(access.len(), 2);
        assert_eq!(access[0].slot, "native-slot");
        assert_eq!(access[1].slot, "do-slot");
    }

    #[test]
    fn relay_invitation_access_rejects_incomplete_groups() {
        let args = ["create", "--relay-route", "relay+do://worker.example"].map(str::to_string);
        let parsed = parse_enroll_admin_args(&args).unwrap();
        assert!(invitation_relay_access(&parsed).is_err());
    }
}
