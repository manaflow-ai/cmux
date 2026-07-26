//! User-facing remote daemon, connection, enrollment, and SSH bootstrap CLI.

use std::collections::{BTreeMap, BTreeSet};
use std::ffi::OsString;
use std::fs::{self, OpenOptions};
use std::io::{self, BufRead, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{Context, anyhow};
use base64::Engine;
use cmux_remote::admin::{
    AdminRequest, AdminResponse, UnixPeerAuthError, call_admin, verify_unix_peer_owner,
};
use cmux_remote::bridge::LocalPortForward;
use cmux_remote::client::WorkspaceClient;
use cmux_remote::connection::ReconnectPolicy;
use cmux_remote::crypto::ClientAuthMode;
use cmux_remote::identity::{
    ClientIdentityStore, EnrollmentInvitation, EnrollmentRelayAccess, KnownDaemon, KnownDaemonAuth,
    credential_free_route_hint, default_state_dir,
};
use cmux_remote::provider::{
    IrohPathMode, ProviderError, ROUTING_DIRECT_ADDRS, ROUTING_NODE_ID, ROUTING_RELAY_URL,
    RelayCredentialSource, SshProviderConfig, SupportedClientAuthModes, sanitized_route,
};
use cmux_remote::ssh_bootstrap::{BUILD_IDENTITY, DISTRIBUTION_VERSION, NPM_BOOTSTRAP_VERSION};
use cmux_remote_protocol::{
    LanePolicy, REMOTE_PROTOCOL_VERSION, RoutePolicy, SessionId, WorkspaceRequest,
    WorkspaceResponse,
};
use serde_json::Value;
use url::Url;
use zeroize::Zeroizing;

use crate::remote_runtime::{
    ClientRuntimeOptions, DaemonRuntimeOptions, RelayClientOptions, ResolvedRouteCandidate,
    SshBootstrapOptions, client_provider_registry, daemon_paths, load_runtime_info,
    start_client_runtime, start_daemon_runtime,
};
use crate::session::{RemoteSession, Session};

const REMOTE_COMMANDS: &[&str] = &[
    "connect",
    "ssh",
    "forward",
    "rpc",
    "enroll",
    "known-daemons",
    "remote-probe",
    "remote-link",
    "remote-sidecar",
    "remote-stop",
    "install-self",
];

const DEFAULT_STARTUP_TIMEOUT: Duration = Duration::from_secs(90);
const ENROLLMENT_APPROVAL_TIMEOUT: Duration = Duration::from_secs(5 * 60);
const MAX_INVITATION_URI_BYTES: usize = "cmux://enroll/".len() + 16 * 1024;

pub fn is_remote_invocation(args: &[String]) -> bool {
    args.first().is_some_and(|argument| REMOTE_COMMANDS.contains(&argument.as_str()))
}

pub fn run(args: &[String], usage: &str) -> i32 {
    match run_inner(args, usage) {
        Ok(()) => 0,
        Err(error) => {
            eprintln!("cmux-tui: {error:#}");
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
        _ => Err(anyhow!("unknown remote command\n\n{usage}")),
    }
}

fn remote_help_requested(args: &[String]) -> bool {
    const VALUE_OPTIONS: &[&str] = &[
        "--invite",
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
        "--relay-ticket",
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
    while index < args.len() {
        match args[index].as_str() {
            "-h" | "--help" => return true,
            option if VALUE_OPTIONS.contains(&option) => index += 2,
            _ => index += 1,
        }
    }
    false
}

fn remote_help(command: Option<&str>) -> &'static str {
    match command {
        Some("connect") => {
            r#"USAGE: cmux-tui connect [ROUTE|INVITATION] [OPTIONS]

ROUTES:
  unix:///ABSOLUTE/PATH | ssh://[USER@]HOST[:PORT] | ws:// | wss:// | iroh://
  relay+ws:// | relay+wss:// | relay+https:// | relay+do://

IDENTITY AND SESSION:
  --invite URI  --invite-file PATH|-  --daemon FINGERPRINT
  --device-name NAME  --session NAME
  --state-dir PATH  --local-socket PATH  --headless [--json]

  --invite-file avoids exposing the single-use invitation in process arguments.
  Regular files must be owner-only; - reads one line from stdin.

TRANSPORT:
  --lanes auto|single|isolated  --connect-timeout-seconds N
  For one relay, --relay-slot SLOT with one of --relay-ticket TICKET,
    --relay-ticket-file PATH, or --relay-ticket-command PROGRAM.
  For fallbacks, repeat up to four --relay-route ROUTE, --relay-slot SLOT,
    and credential-source groups in occurrence order.
  --relay-ticket-command-arg ARG  --iroh-relay URL  --iroh-address ADDR
  --iroh-path auto|direct-only|relay-only
  --ssh-binary PATH  --remote-binary PATH  --ssh-arg ARG  --no-install
  --remote-state-dir PATH for a non-default daemon state directory
  --upgrade explicitly replaces an SSH-managed remote sidecar after installing
    the pinned binary; terminal panes survive, while remote RPC state resets

RECONNECT:
  --reconnect-attempts N|unlimited  --reconnect-initial-ms MS
  --reconnect-max-ms MS  --reconnect-attempt-timeout-ms MS
  --reconnect-jitter full|none  --heartbeat-interval-ms MS
  --heartbeat-timeout-ms MS
"#
        }
        Some("ssh") => {
            r#"USAGE: cmux-tui ssh [USER@]HOST[:PORT] [OPTIONS]

Direct SSH uses one carrier by default. Pass --lanes auto or isolated to opt in
to multiple carriers. The remote binary is probed and, unless --no-install is
set, installed into the user account when missing or incompatible.

OPTIONS:
  --session NAME  --lanes single|auto|isolated  --headless [--json]
  --ssh-binary PATH  --remote-binary PATH  --ssh-arg ARG  --no-install
  --remote-state-dir PATH for a non-default daemon state directory
  --upgrade explicitly replaces an SSH-managed remote sidecar; terminal panes
    survive, remote clients and forwards disconnect, RPC processes stop, and
    other RPC resources reset
  --state-dir PATH  --local-socket PATH  --connect-timeout-seconds N
  --reconnect-attempts N|unlimited  --reconnect-initial-ms MS
  --reconnect-max-ms MS  --reconnect-attempt-timeout-ms MS
  --reconnect-jitter full|none  --heartbeat-interval-ms MS
  --heartbeat-timeout-ms MS
"#
        }
        Some("forward") => {
            r#"USAGE: cmux-tui forward [ROUTE|INVITATION] --workspace-root PATH --port PORT [OPTIONS]

OPTIONS:
  --host HOST  --listen ADDR  --scheme http|https
  All identity, transport, SSH, relay, Iroh, and reconnect options accepted by
  `cmux-tui connect` are also accepted.
"#
        }
        Some("rpc") => {
            r#"USAGE: cmux-tui rpc [ROUTE|INVITATION] [OPTIONS]

Reads one WorkspaceRequest JSON object per stdin line and writes one response
per line. --request JSON sends one request and exits.

OPTIONS:
  --request WORKSPACE_REQUEST_JSON
  All identity, transport, SSH, relay, Iroh, and reconnect options accepted by
  `cmux-tui connect` are also accepted.
"#
        }
        Some("enroll") => {
            r#"USAGE: cmux-tui enroll ACTION [OPTIONS]

ACTIONS:
  status | create | pending | approve ID | deny ID | devices | connections
  revoke DEVICE_ID | disconnect DEVICE_ID SESSION_ID | connect INVITATION

OPTIONS:
  --session NAME  --state-dir PATH  --admin-socket PATH  --json
  create: --ttl SECONDS  --advertise ROUTE
  create relay access: repeat --relay-route ROUTE --relay-slot SLOT with one
    --relay-ticket TICKET or --relay-ticket-file PATH, in occurrence order,
    for up to two relay fallbacks
  connect accepts every option documented by `cmux-tui connect`.
"#
        }
        Some("known-daemons") => {
            r#"USAGE: cmux-tui known-daemons [list] [--state-dir PATH] [--json]
       cmux-tui known-daemons forget FINGERPRINT [--state-dir PATH] [--json]
"#
        }
        Some("remote-probe") => "USAGE: cmux-tui remote-probe [--json]\n",
        Some("remote-link") => {
            "USAGE: cmux-tui remote-link --stdio [--session NAME] [--state-dir PATH]\n"
        }
        Some("remote-stop") => "USAGE: cmux-tui remote-stop [--session NAME] [--state-dir PATH]\n",
        Some("install-self") => "USAGE: cmux-tui install-self --destination PATH\n",
        _ => {
            r#"USAGE: cmux-tui connect|ssh|forward|rpc|enroll|known-daemons <OPTIONS>

Run `cmux-tui COMMAND --help` for command-specific routes and options.
"#
        }
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
    Inline(String),
    File(PathBuf),
}

enum ClientRelayCredentialArg {
    Ticket(String),
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
            let value = args.get(index).cloned().ok_or_else(|| anyhow!("{name} needs a value"))?;
            index += 1;
            Ok(value)
        };
        match argument.as_str() {
            "--invite" => set_invitation_arg(
                &mut flags.invitation,
                InvitationArg::Inline(value("--invite")?),
            )?,
            "--invite-file" => set_invitation_arg(
                &mut flags.invitation,
                InvitationArg::File(value("--invite-file")?.into()),
            )?,
            "--daemon" => flags.daemon = Some(value("--daemon")?),
            "--lanes" => {
                flags.lanes = value("--lanes")?.parse().map_err(|error: String| anyhow!(error))?;
                flags.lanes_explicit = true;
            }
            "--reconnect-attempts" => {
                let attempts = value("--reconnect-attempts")?;
                flags.reconnect.maximum_attempts = if attempts == "unlimited" {
                    None
                } else {
                    let attempts = attempts
                        .parse::<u32>()
                        .context("--reconnect-attempts must be a positive integer or unlimited")?;
                    if attempts == 0 {
                        return Err(anyhow!("--reconnect-attempts must be positive"));
                    }
                    Some(attempts)
                };
            }
            "--reconnect-initial-ms" => {
                flags.reconnect.initial_delay = Duration::from_millis(
                    value("--reconnect-initial-ms")?
                        .parse()
                        .context("--reconnect-initial-ms must be milliseconds")?,
                );
            }
            "--reconnect-max-ms" => {
                flags.reconnect.maximum_delay = Duration::from_millis(
                    value("--reconnect-max-ms")?
                        .parse()
                        .context("--reconnect-max-ms must be milliseconds")?,
                );
            }
            "--reconnect-attempt-timeout-ms" => {
                flags.reconnect.attempt_timeout = Duration::from_millis(
                    value("--reconnect-attempt-timeout-ms")?
                        .parse()
                        .context("--reconnect-attempt-timeout-ms must be milliseconds")?,
                );
            }
            "--reconnect-jitter" => {
                flags.reconnect.full_jitter = match value("--reconnect-jitter")?.as_str() {
                    "full" => true,
                    "none" => false,
                    other => {
                        return Err(anyhow!(
                            "--reconnect-jitter must be full or none, got {other:?}"
                        ));
                    }
                };
            }
            "--heartbeat-interval-ms" => {
                let milliseconds = value("--heartbeat-interval-ms")?
                    .parse::<u64>()
                    .context("--heartbeat-interval-ms must be milliseconds")?;
                flags.reconnect.heartbeat_interval =
                    (milliseconds != 0).then(|| Duration::from_millis(milliseconds));
            }
            "--heartbeat-timeout-ms" => {
                flags.reconnect.heartbeat_timeout = Duration::from_millis(
                    value("--heartbeat-timeout-ms")?
                        .parse()
                        .context("--heartbeat-timeout-ms must be milliseconds")?,
                );
            }
            "--connect-timeout-seconds" => {
                let seconds = value("--connect-timeout-seconds")?
                    .parse::<u64>()
                    .context("--connect-timeout-seconds must be a positive integer")?;
                if seconds == 0 {
                    return Err(anyhow!("--connect-timeout-seconds must be positive"));
                }
                flags.startup_timeout = Some(Duration::from_secs(seconds));
            }
            "--device-name" => flags.device_name = Some(value("--device-name")?),
            "--state-dir" => flags.state_dir = Some(value("--state-dir")?.into()),
            "--local-socket" => flags.local_socket = Some(value("--local-socket")?.into()),
            "--relay-route" => flags.relay_routes.push(value("--relay-route")?),
            "--relay-slot" => flags.relay_slots.push(value("--relay-slot")?),
            "--relay-ticket" => {
                flags
                    .relay_credentials
                    .push(ClientRelayCredentialArg::Ticket(value("--relay-ticket")?));
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
                        return Err(anyhow!(
                            "--relay-ticket-command-arg must follow --relay-ticket-command"
                        ));
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
                flags.iroh_path =
                    value("--iroh-path")?.parse().map_err(|error: String| anyhow!(error))?;
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
                flags.forward_port =
                    Some(value("--port")?.parse().context("--port must be a TCP port")?);
            }
            "--listen" => {
                flags.forward_listen =
                    Some(value("--listen")?.parse().context("--listen must be a socket address")?);
            }
            "--scheme" => flags.forward_scheme = value("--scheme")?,
            "--request" => flags.rpc_request = Some(value("--request")?),
            "-h" | "--help" => {
                println!(
                    "cmux-tui connect <route|invitation> [--invite URI|--invite-file PATH|-] \
                     [--daemon FINGERPRINT] [--lanes auto|single|isolated] \
                     [--relay-slot SLOT --relay-ticket TICKET]"
                );
                return Ok(flags);
            }
            option if option.starts_with('-') => return Err(anyhow!("unknown option {option:?}")),
            route => {
                if flags.route.replace(route.to_string()).is_some() {
                    return Err(anyhow!("connect accepts one route"));
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
        return Err(anyhow!(
            "reconnect delays, attempt timeout, and enabled heartbeat timeout must be positive; max delay must be at least initial"
        ));
    }
    if flags.upgrade && !flags.auto_install {
        return Err(anyhow!("--upgrade cannot be combined with --no-install"));
    }
    if flags.json && !flags.headless {
        return Err(anyhow!("--json requires --headless for connect and ssh"));
    }
    Ok(flags)
}

fn set_invitation_arg(
    destination: &mut Option<InvitationArg>,
    invitation: InvitationArg,
) -> anyhow::Result<()> {
    if destination.replace(invitation).is_some() {
        return Err(anyhow!(
            "supply exactly one of --invite or --invite-file, and do not repeat it"
        ));
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
                    tokio::time::sleep(Duration::from_millis(100)).await;
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
    let result = crate::run_tui(Session::Remote(remote), connected.route);
    let shutdown = connected.runtime.shutdown();
    result.and(shutdown)
}

struct ConnectedRuntime {
    runtime: crate::remote_runtime::ClientRuntimeHandle,
    route: String,
}

fn start_connected(mut flags: ConnectFlags) -> anyhow::Result<ConnectedRuntime> {
    let startup_started = Instant::now();
    let invitation = {
        let positional_invitation =
            flags.route.as_deref().is_some_and(|route| route.starts_with("cmux://enroll/"));
        if positional_invitation && flags.invitation.is_some() {
            return Err(anyhow!(
                "an invitation was supplied both positionally and with an invitation option"
            ));
        }
        let encoded = match flags.invitation.take() {
            Some(InvitationArg::Inline(encoded)) => Some(Zeroizing::new(encoded)),
            Some(InvitationArg::File(path)) => Some(read_invitation_uri(&path)?),
            None if positional_invitation => {
                Some(Zeroizing::new(flags.route.take().expect("route was checked")))
            }
            None => None,
        };
        encoded
            .as_ref()
            .map(|encoded| EnrollmentInvitation::from_uri(encoded.as_str()))
            .transpose()?
    };
    let total_startup_timeout = flags
        .startup_timeout
        .unwrap_or_else(|| invitation.as_ref().map_or(DEFAULT_STARTUP_TIMEOUT, invitation_timeout));
    let client_root = flags
        .state_dir
        .clone()
        .or_else(default_state_dir)
        .ok_or_else(|| anyhow!("cannot determine remote state directory; use --state-dir"))?
        .join("client");
    let store = ClientIdentityStore::load_or_create(&client_root)?;
    let async_runtime = tokio_runtime()?;
    let (relay, mut relay_routes) = client_relay_options(
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
                    "invitation repeats relay bootstrap route {}",
                    sanitized_route(&endpoint)
                ));
            }
        }
        for (route, options) in invitation_routes {
            relay_routes.entry(route).or_insert(options);
        }
    }
    if relay_routes.len() + usize::from(relay.is_some()) > 4 {
        return Err(anyhow!(
            "a client supports at most four relay credential routes including invitation bootstrap routes"
        ));
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
    let providers =
        Arc::new(client_provider_registry(ssh.clone(), relay, relay_routes, flags.iroh_path)?);
    let explicit_route = flags.route.take();
    let explicit_route_for_refresh = explicit_route.clone();
    let (route_strings, auth, expected_daemon, known, carrier_auth) = if let Some(invitation) =
        &invitation
    {
        if let Some(fingerprint) = flags.daemon.as_deref()
            && fingerprint != invitation.daemon_fingerprint
        {
            return Err(anyhow!(
                "invitation daemon fingerprint does not match --daemon {fingerprint:?}"
            ));
        }
        let mut routes = Vec::new();
        if let Some(route) = explicit_route {
            push_unique(&mut routes, route);
        }
        for route in &invitation.route_hints {
            push_unique(&mut routes, route.clone());
        }
        if routes.is_empty() {
            return Err(anyhow!("invitation contains no usable route hints"));
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
            return Err(anyhow!(
                "daemon {} has no stored routes; pass a route or enroll again",
                known.fingerprint
            ));
        }
        let key = async_runtime
            .block_on(store.daemon_key(&known.fingerprint))?
            .ok_or_else(|| anyhow!("known daemon key disappeared"))?;
        let auth = match known.auth {
            KnownDaemonAuth::Enrolled => ClientAuthMode::Enrolled,
            KnownDaemonAuth::Carrier => ClientAuthMode::Carrier,
        };
        (known.route_hints.clone(), auth, Some(key), Some(known), false)
    };

    let mut routes = resolve_route_candidates(&route_strings, &flags.routing, &providers)?;
    promote_reachable_unix_routes(&mut routes);
    if flags.upgrade && routes.first().is_none_or(|route| route.endpoint.scheme() != "ssh") {
        return Err(anyhow!("--upgrade requires SSH to be the initial route"));
    }
    for route in relay_route_names {
        if !routes.iter().any(|candidate| candidate.endpoint.as_str() == route) {
            let display = parse_route(&route, "relay credential route")
                .map(|route| sanitized_route(&route))
                .unwrap_or_else(|_| "<invalid route>".into());
            return Err(anyhow!(
                "relay credential route {display} is not one of this connection's route candidates"
            ));
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
            return Err(anyhow!("daemon key changed for {}", known.name));
        }
        if let Some(route) = explicit_route_for_refresh {
            async_runtime
                .block_on(store.remember_verified_route(&known.fingerprint, &route))?
                .ok_or_else(|| anyhow!("known daemon disappeared while refreshing its route"))?;
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
            "daemon {} is known only through a trusted SSH or Unix carrier; use that carrier route or enroll this device for network access",
            known.fingerprint
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
    routes: Vec<String>,
    slots: Vec<String>,
    credentials: Vec<ClientRelayCredentialArg>,
) -> anyhow::Result<(Option<RelayClientOptions>, BTreeMap<String, RelayClientOptions>)> {
    const MAX_CLIENT_RELAYS: usize = 4;
    if slots.len() != credentials.len() {
        return Err(anyhow!(
            "each relay credential needs one --relay-slot and one relay credential source"
        ));
    }
    if routes.is_empty() {
        return match slots.len() {
            0 => Ok((None, BTreeMap::new())),
            1 => Ok((
                Some(RelayClientOptions {
                    slot: slots.into_iter().next().unwrap(),
                    credentials: client_relay_credential(credentials.into_iter().next().unwrap())?,
                }),
                BTreeMap::new(),
            )),
            _ => Err(anyhow!(
                "multiple relay credentials require one --relay-route per credential group"
            )),
        };
    }
    if routes.len() != slots.len() {
        return Err(anyhow!(
            "each route-scoped relay credential needs one --relay-route, one --relay-slot, and one credential source"
        ));
    }
    if routes.len() > MAX_CLIENT_RELAYS {
        return Err(anyhow!("a client supports at most {MAX_CLIENT_RELAYS} relay credentials"));
    }
    let mut by_route = BTreeMap::new();
    for ((route, slot), credential) in routes.into_iter().zip(slots).zip(credentials) {
        let endpoint = parse_route(&route, "relay credential route")?;
        let display = sanitized_route(&endpoint);
        if !matches!(endpoint.scheme(), "relay+ws" | "relay+wss" | "relay+https" | "relay+do") {
            return Err(anyhow!("relay credential route {display} is not a relay route"));
        }
        let route = endpoint.to_string();
        let options =
            RelayClientOptions { slot, credentials: client_relay_credential(credential)? };
        if by_route.insert(route.clone(), options).is_some() {
            return Err(anyhow!("relay credential route {display} is repeated"));
        }
    }
    Ok((None, by_route))
}

fn client_relay_credential(
    credential: ClientRelayCredentialArg,
) -> anyhow::Result<RelayCredentialSource> {
    match credential {
        ClientRelayCredentialArg::Ticket(ticket) => {
            Ok(RelayCredentialSource::static_ticket(ticket)?)
        }
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
        .ok_or_else(|| anyhow!("forward needs --workspace-root on the daemon"))?;
    let host = flags.forward_host.clone().unwrap_or_else(|| "127.0.0.1".into());
    let port = flags.forward_port.ok_or_else(|| anyhow!("forward needs --port"))?;
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
        while !crate::shutdown_requested() && !connected.runtime.is_finished() {
            tokio::time::sleep(Duration::from_millis(100)).await;
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
            for line in stdin.lock().lines() {
                if sender.blocking_send(line).is_err() {
                    break;
                }
            }
        })
        .context("could not start RPC stdin reader")?;
    Ok(receiver)
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
                .context("--request is not a WorkspaceRequest JSON object")?;
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
            let request: WorkspaceRequest =
                serde_json::from_str(&line).context("invalid WorkspaceRequest")?;
            let response = client.request(request).await?;
            println!("{}", serde_json::to_string(&response)?);
        }
        Ok(())
    });
    let shutdown = connected.runtime.shutdown();
    result.and(shutdown)
}

fn run_ssh(args: &[String]) -> anyhow::Result<()> {
    let destination = args
        .first()
        .filter(|argument| !argument.starts_with('-'))
        .cloned()
        .ok_or_else(|| anyhow!("ssh expects the destination before options"))?;
    let mut flags = parse_connect_flags(args)?;
    flags.route = Some(ssh_url(&destination)?);
    if !flags.lanes_explicit {
        // `cmux-tui ssh` should behave like direct SSH by default: one SSH
        // process carrying all logical lanes. Users can opt into isolated
        // carriers with `--lanes isolated`.
        flags.lanes = LanePolicy::Single;
    }

    connect_with_flags(flags)
}

fn ssh_url(destination: &str) -> anyhow::Result<String> {
    if destination.starts_with('-') || destination.bytes().any(|byte| byte.is_ascii_whitespace()) {
        return Err(anyhow!("invalid SSH destination"));
    }
    let url = format!("ssh://{destination}");
    Url::parse(&url).context("invalid SSH destination")?;
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
            other => Err(anyhow!("unknown enroll action {other:?}")),
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
    Inline(String),
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
                parsed.ttl_seconds = strict_option_value(args, &mut index, "--ttl")?
                    .parse()
                    .context("--ttl must be seconds")?;
                if parsed.ttl_seconds == 0 {
                    return Err(anyhow!("--ttl must be positive"));
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
            "--relay-ticket" => {
                require_create_action(action, "--relay-ticket")?;
                parsed.relay_tickets.push(InvitationTicketArg::Inline(strict_option_value(
                    args,
                    &mut index,
                    "--relay-ticket",
                )?));
            }
            "--relay-ticket-file" => {
                require_create_action(action, "--relay-ticket-file")?;
                parsed.relay_tickets.push(InvitationTicketArg::File(
                    strict_option_value(args, &mut index, "--relay-ticket-file")?.into(),
                ));
            }
            option => {
                return Err(anyhow!("unknown option {option:?} for enroll {}", action.name()));
            }
        }
    }
    let expected = action.positional_arity();
    if parsed.positionals.len() != expected {
        return Err(anyhow!(
            "enroll {} expects exactly {expected} positional argument{}",
            action.name(),
            if expected == 1 { "" } else { "s" }
        ));
    }
    Ok(parsed)
}

fn require_create_action(action: EnrollAdminAction, option: &str) -> anyhow::Result<()> {
    if action != EnrollAdminAction::Create {
        return Err(anyhow!("{option} is only valid for enroll create"));
    }
    Ok(())
}

fn require_unique_flag(
    seen: &mut BTreeSet<&'static str>,
    option: &'static str,
) -> anyhow::Result<()> {
    if !seen.insert(option) {
        return Err(anyhow!("{option} may only be specified once"));
    }
    Ok(())
}

fn strict_option_value(args: &[String], index: &mut usize, option: &str) -> anyhow::Result<String> {
    let value = args.get(*index).filter(|value| !value.starts_with("--")).cloned();
    let Some(value) = value else {
        return Err(anyhow!("{option} needs a value"));
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
            option => return Err(anyhow!("unknown option {option:?} for known-daemons")),
        }
    }
    let action = match positionals.as_slice() {
        [] => KnownDaemonsAction::List,
        [action] if action == "list" => KnownDaemonsAction::List,
        [action, fingerprint] if action == "forget" => {
            KnownDaemonsAction::Forget(fingerprint.clone())
        }
        [action] if action == "forget" => {
            return Err(anyhow!("known-daemons forget expects exactly one fingerprint"));
        }
        [action, ..] if action == "forget" => {
            return Err(anyhow!("known-daemons forget expects exactly one fingerprint"));
        }
        [action, ..] => return Err(anyhow!("unknown known-daemons action {action:?}")),
    };
    Ok(KnownDaemonsArgs { action, state_dir, json })
}

fn run_known_daemons(args: &[String]) -> anyhow::Result<()> {
    let parsed = parse_known_daemons_args(args)?;
    let client_root = parsed
        .state_dir
        .or_else(default_state_dir)
        .ok_or_else(|| anyhow!("cannot determine remote state directory; use --state-dir"))?
        .join("client");
    let store = ClientIdentityStore::load_or_create(client_root)?;
    if let KnownDaemonsAction::Forget(fingerprint) = parsed.action {
        let forgotten = tokio_runtime()?.block_on(store.forget_daemon(&fingerprint))?;
        if !forgotten {
            return Err(anyhow!("daemon {fingerprint:?} is not known"));
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
            println!("Forgot daemon {fingerprint}.");
        }
        return Ok(());
    }
    let daemons = tokio_runtime()?.block_on(store.known_daemons());
    if parsed.json {
        println!("{}", serde_json::to_string_pretty(&daemons)?);
        return Ok(());
    }
    if daemons.is_empty() {
        println!("No known daemons.");
        return Ok(());
    }
    for daemon in daemons {
        println!(
            "{}\t{}\t{}",
            daemon.name,
            daemon.fingerprint,
            match daemon.auth {
                KnownDaemonAuth::Enrolled => "enrolled",
                KnownDaemonAuth::Carrier => "carrier",
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
            "each invitation relay needs one --relay-route, one --relay-slot, and one --relay-ticket or --relay-ticket-file"
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
            let ticket = match source {
                InvitationTicketArg::Inline(ticket) => ticket.clone(),
                InvitationTicketArg::File(path) => read_invitation_ticket_file(path)?,
            };
            Ok(EnrollmentRelayAccess { route: route.clone(), slot: slot.clone(), ticket })
        })
        .collect()
}

fn read_invitation_ticket_file(path: &Path) -> anyhow::Result<String> {
    let metadata = fs::metadata(path)
        .with_context(|| format!("could not read relay ticket file {}", path.display()))?;
    if metadata.len() > 4 * 1024 {
        return Err(anyhow!("relay ticket file exceeds 4096 bytes"));
    }
    Ok(fs::read_to_string(path)
        .with_context(|| format!("could not read relay ticket file {}", path.display()))?
        .trim()
        .to_string())
}

fn read_invitation_uri(path: &Path) -> anyhow::Result<Zeroizing<String>> {
    if path == Path::new("-") {
        return read_invitation_uri_line(&mut io::stdin().lock());
    }

    use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};

    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .with_context(|| format!("could not open invitation file {}", path.display()))?;
    let metadata = file
        .metadata()
        .with_context(|| format!("could not inspect invitation file {}", path.display()))?;
    if !metadata.file_type().is_file() {
        return Err(anyhow!("invitation path must be a regular file or - for stdin"));
    }
    if metadata.len() > (MAX_INVITATION_URI_BYTES + 2) as u64 {
        return Err(anyhow!("invitation file exceeds {MAX_INVITATION_URI_BYTES} bytes"));
    }
    if metadata.uid() != unsafe { libc::geteuid() } || metadata.permissions().mode() & 0o077 != 0 {
        return Err(anyhow!(
            "invitation file must be owned by the current user with no group or other permissions"
        ));
    }

    read_invitation_uri_to_end(&mut file)
        .with_context(|| format!("could not read invitation file {}", path.display()))
}

fn read_invitation_uri_to_end(reader: &mut impl Read) -> anyhow::Result<Zeroizing<String>> {
    let mut bytes = Zeroizing::new(Vec::with_capacity(MAX_INVITATION_URI_BYTES.min(4096)));
    reader
        .take((MAX_INVITATION_URI_BYTES + 3) as u64)
        .read_to_end(&mut bytes)
        .context("could not read invitation input")?;
    normalize_invitation_uri(bytes)
}

fn read_invitation_uri_line(reader: &mut impl Read) -> anyhow::Result<Zeroizing<String>> {
    let mut bytes = Zeroizing::new(Vec::with_capacity(1024));
    loop {
        let mut byte = [0_u8; 1];
        match reader.read(&mut byte).context("could not read invitation input")? {
            0 => break,
            _ => {
                bytes.push(byte[0]);
                if byte[0] == b'\n' {
                    break;
                }
                if bytes.len() > MAX_INVITATION_URI_BYTES + 2 {
                    return Err(anyhow!(
                        "invitation input exceeds {MAX_INVITATION_URI_BYTES} bytes"
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
        return Err(anyhow!("invitation input is empty"));
    }
    if bytes.len() > MAX_INVITATION_URI_BYTES {
        return Err(anyhow!("invitation input exceeds {MAX_INVITATION_URI_BYTES} bytes"));
    }
    if bytes.iter().any(|byte| matches!(byte, b'\r' | b'\n')) {
        return Err(anyhow!("invitation input must contain exactly one URI"));
    }
    if std::str::from_utf8(&bytes).is_err() {
        return Err(anyhow!("invitation input is not valid UTF-8"));
    }

    let bytes = std::mem::take(&mut *bytes);
    // SAFETY: the complete byte slice was validated as UTF-8 immediately above.
    Ok(Zeroizing::new(unsafe { String::from_utf8_unchecked(bytes) }))
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

fn run_install_self(args: &[String]) -> anyhow::Result<()> {
    let destination = flag_value(args, "--destination")
        .map(expand_home)
        .transpose()?
        .ok_or_else(|| anyhow!("install-self needs --destination"))?;
    let source = std::env::current_exe()?;
    let parent = destination.parent().ok_or_else(|| anyhow!("destination has no parent"))?;
    fs::create_dir_all(parent)?;
    let temporary = parent.join(format!(".cmux-tui-install-{}", std::process::id()));
    fs::copy(&source, &temporary)
        .with_context(|| format!("could not copy {}", source.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&temporary, fs::Permissions::from_mode(0o755))?;
    }
    fs::rename(&temporary, &destination)?;
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
}

fn parse_remote_stop_args(args: &[String]) -> anyhow::Result<RemoteStopArgs> {
    let mut session = "main".to_string();
    let mut state_dir = None;
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
            option if option.starts_with("--") => {
                return Err(anyhow!("unknown option {option:?} for remote-stop"));
            }
            _ => return Err(anyhow!("remote-stop accepts no positional arguments")),
        }
    }
    Ok(RemoteStopArgs { session, state_dir })
}

fn run_remote_stop(args: &[String]) -> anyhow::Result<()> {
    let parsed = parse_remote_stop_args(args)?;
    let (_, default_link, default_admin) =
        daemon_paths(&parsed.session, parsed.state_dir.as_deref())?;
    let runtime = match load_runtime_info(&parsed.session, parsed.state_dir.as_deref()) {
        Ok(runtime) => runtime,
        Err(_)
            if UnixStream::connect(&default_link).is_err()
                && UnixStream::connect(&default_admin).is_err() =>
        {
            return Ok(());
        }
        Err(error) => {
            return Err(
                error.context("refusing to stop a live daemon without valid lifecycle metadata")
            );
        }
    };
    if !runtime.replaceable_sidecar {
        return Err(anyhow!(
            "refusing to upgrade an embedded daemon because stopping it would terminate its workspaces; stop and restart it explicitly"
        ));
    }
    let runtime_file = runtime.state_dir.join("runtime.json");
    let link = runtime.link_socket;
    let admin = runtime.admin_socket;
    let response = tokio_runtime()?.block_on(call_admin(&admin, &AdminRequest::Shutdown))?;
    if !response.ok {
        return Err(anyhow!(response.error.unwrap_or_else(|| "daemon shutdown failed".into())));
    }
    let deadline = Instant::now() + Duration::from_secs(20);
    while Instant::now() < deadline {
        if UnixStream::connect(&link).is_err() && !runtime_file.exists() {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(50));
    }
    Err(anyhow!("remote daemon did not stop within 20 seconds"))
}

fn run_remote_sidecar(args: &[String]) -> anyhow::Result<()> {
    let session = flag_value(args, "--session").unwrap_or_else(|| "main".into());
    let mux_socket = flag_value(args, "--mux-socket")
        .map(PathBuf::from)
        .ok_or_else(|| anyhow!("remote-sidecar needs --mux-socket"))?;
    let mut mux_monitor = open_mux_monitor(&mux_socket)?;
    let state_dir = flag_value(args, "--state-dir").map(PathBuf::from);
    let link_socket = flag_value(args, "--link-socket").map(PathBuf::from);
    let (session_state, _, _) = daemon_paths(&session, state_dir.as_deref())?;
    let runtime = start_daemon_runtime(
        mux_socket.clone(),
        DaemonRuntimeOptions {
            session,
            state_dir,
            link_socket,
            admin_socket: None,
            direct_websocket: None,
            allow_insecure_non_loopback: false,
            relays: Vec::new(),
            iroh: false,
            advertised_routes: Vec::new(),
            resume_lease: cmux_remote::daemon::DEFAULT_RESUME_LEASE,
            replaceable_sidecar: true,
        },
    )?;
    let runtime_info = runtime.info().clone();
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

    let lifecycle = match lock_daemon_start(&session_state) {
        Ok(_guard) => {
            let shutdown = runtime.shutdown();
            let cleanup = cleanup_stale_sidecar_artifacts(
                &runtime_info.state_dir,
                &runtime_info.link_socket,
                &runtime_info.admin_socket,
            );
            combine_sidecar_results(shutdown, cleanup)
        }
        Err(lock_error) => {
            let shutdown = runtime.shutdown();
            combine_sidecar_results(shutdown, Err(lock_error))
        }
    };
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

    let executable = std::env::current_exe()?;
    let log_path = session_state.join("daemon.log");
    let mux_socket = mux_socket_override
        .map(Path::to_path_buf)
        .or_else(|| std::env::var_os("CMUX_MUX_SOCKET").map(PathBuf::from))
        .unwrap_or_else(|| cmux_tui_core::server::default_socket_path(session));
    if UnixStream::connect(&mux_socket).is_err() {
        let log = OpenOptions::new().create(true).append(true).open(&log_path)?;
        let mut mux_owner = Command::new(&executable);
        mux_owner
            .args(["--headless", "--session", session, "--socket"])
            .arg(&mux_socket)
            .stdin(Stdio::null())
            .stdout(Stdio::from(log.try_clone()?))
            .stderr(Stdio::from(log));
        configure_detached_process(&mut mux_owner);
        let mut child = mux_owner.spawn().context("could not start remote mux owner")?;
        let deadline = Instant::now() + Duration::from_secs(20);
        while Instant::now() < deadline {
            if UnixStream::connect(&mux_socket).is_ok() {
                break;
            }
            if let Some(status) = child.try_wait()? {
                return Err(anyhow!(
                    "remote mux owner exited {status}; inspect {}",
                    log_path.display()
                ));
            }
            thread::sleep(Duration::from_millis(50));
        }
        if UnixStream::connect(&mux_socket).is_err() {
            return Err(anyhow!("remote mux owner did not create {}", mux_socket.display()));
        }
    }

    let log = OpenOptions::new().create(true).append(true).open(&log_path)?;
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
    let deadline = Instant::now() + Duration::from_secs(20);
    while Instant::now() < deadline {
        if UnixStream::connect(link).is_ok() {
            return Ok(());
        }
        if let Some(status) = child.try_wait()? {
            return Err(anyhow!("remote daemon exited {status}; inspect {}", log_path.display()));
        }
        thread::sleep(Duration::from_millis(50));
    }
    Err(anyhow!("remote daemon did not create {}", link.display()))
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

fn lock_daemon_start(session_state: &Path) -> anyhow::Result<fs::File> {
    fs::create_dir_all(session_state)?;
    let lock_path = session_state.join("start.lock");
    let lock =
        OpenOptions::new().read(true).write(true).create(true).truncate(false).open(lock_path)?;
    let locked = unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) };
    if locked != 0 {
        return Err(io::Error::last_os_error().into());
    }
    Ok(lock)
}

fn cleanup_stale_sidecar_artifacts(
    state_dir: &Path,
    link_socket: &Path,
    admin_socket: &Path,
) -> anyhow::Result<()> {
    // A replacement started outside the bootstrap lock owns these paths. Do
    // not unlink its sockets or metadata.
    if UnixStream::connect(link_socket).is_ok() {
        return Ok(());
    }
    remove_regular_file_if_present(&state_dir.join("runtime.json"))?;
    remove_stale_socket_if_present(link_socket)?;
    remove_stale_socket_if_present(admin_socket)
}

fn remove_regular_file_if_present(path: &Path) -> anyhow::Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_file() => fs::remove_file(path)?,
        Ok(_) => return Err(anyhow!("refusing to remove non-file path {}", path.display())),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
    }
    Ok(())
}

fn remove_stale_socket_if_present(path: &Path) -> anyhow::Result<()> {
    use std::os::unix::fs::FileTypeExt;

    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_socket() => {
            if UnixStream::connect(path).is_err() {
                fs::remove_file(path)?;
            }
        }
        Ok(_) => return Err(anyhow!("refusing to remove non-socket path {}", path.display())),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
    }
    Ok(())
}

fn combine_sidecar_results(
    shutdown: anyhow::Result<()>,
    cleanup: anyhow::Result<()>,
) -> anyhow::Result<()> {
    match (shutdown, cleanup) {
        (Ok(()), Ok(())) => Ok(()),
        (Err(error), Ok(())) | (Ok(()), Err(error)) => Err(error),
        (Err(shutdown), Err(cleanup)) => Err(anyhow!(
            "remote sidecar shutdown failed: {shutdown:#}; cleanup failed: {cleanup:#}"
        )),
    }
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
    use super::*;

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
                None,
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
    fn parse_lane_policy_and_relay_flags() {
        let args = [
            "wss://host/v1/link",
            "--lanes",
            "isolated",
            "--relay-slot",
            "slot",
            "--relay-ticket",
            "ticket",
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

        for args in [
            vec!["--invite", "first", "--invite", "second"],
            vec!["--invite-file", "first", "--invite-file", "second"],
            vec!["--invite", "inline", "--invite-file", "file"],
            vec!["--invite-file", "file", "--invite", "inline"],
        ] {
            let args = args.into_iter().map(str::to_string).collect::<Vec<_>>();
            assert!(parse_connect_flags(&args).is_err(), "unexpectedly accepted {args:?}");
        }
    }

    #[test]
    fn positional_and_option_invitations_are_rejected_before_loading_or_connecting() {
        let flags = ConnectFlags {
            route: Some("cmux://enroll/positional-secret".into()),
            invitation: Some(InvitationArg::File("missing-option-secret".into())),
            ..ConnectFlags::default()
        };
        let error = start_connected(flags).err().expect("duplicate invitation should fail");
        assert!(error.to_string().contains("both positionally"));
        assert!(!error.to_string().contains("positional-secret"));
        assert!(!error.to_string().contains("option-secret"));
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
    fn sidecar_cleanup_removes_dead_runtime_artifacts() {
        let directory = tempfile::tempdir().unwrap();
        let state = directory.path().join("state");
        fs::create_dir_all(&state).unwrap();
        let link = state.join("link.sock");
        let admin = state.join("admin.sock");
        drop(std::os::unix::net::UnixListener::bind(&link).unwrap());
        drop(std::os::unix::net::UnixListener::bind(&admin).unwrap());
        fs::write(state.join("runtime.json"), b"{}").unwrap();

        cleanup_stale_sidecar_artifacts(&state, &link, &admin).unwrap();

        assert!(!state.join("runtime.json").exists());
        assert!(!link.exists());
        assert!(!admin.exists());
    }

    #[test]
    fn sidecar_cleanup_preserves_a_live_replacement() {
        let directory = tempfile::tempdir().unwrap();
        let state = directory.path().join("state");
        fs::create_dir_all(&state).unwrap();
        let link = state.join("link.sock");
        let admin = state.join("admin.sock");
        let _listener = std::os::unix::net::UnixListener::bind(&link).unwrap();
        fs::write(state.join("runtime.json"), b"{}").unwrap();

        cleanup_stale_sidecar_artifacts(&state, &link, &admin).unwrap();

        assert!(state.join("runtime.json").exists());
        assert!(link.exists());
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
    fn relay_credentials_support_global_and_route_scoped_forms() {
        let (global, routes) = client_relay_options(
            vec![],
            vec!["slot".into()],
            vec![ClientRelayCredentialArg::Ticket("ticket".into())],
        )
        .unwrap();
        assert_eq!(global.unwrap().slot, "slot");
        assert!(routes.is_empty());

        let (global, routes) = client_relay_options(
            vec!["relay+wss://native.example".into(), "relay+do://worker.example".into()],
            vec!["native-slot".into(), "do-slot".into()],
            vec![
                ClientRelayCredentialArg::Command { program: "native-ticket".into(), args: vec![] },
                ClientRelayCredentialArg::File("do-ticket".into()),
            ],
        )
        .unwrap();
        assert!(global.is_none());
        assert_eq!(routes["relay+wss://native.example"].slot, "native-slot");
        assert_eq!(routes["relay+do://worker.example"].slot, "do-slot");

        assert!(
            client_relay_options(
                vec!["relay+wss://native.example".into()],
                vec!["slot".into(), "extra".into()],
                vec![
                    ClientRelayCredentialArg::Ticket("ticket".into()),
                    ClientRelayCredentialArg::Ticket("extra".into()),
                ],
            )
            .is_err()
        );
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

        for args in [
            vec!["--session"],
            vec!["--session", "dev", "--session", "other"],
            vec!["--state-dir"],
            vec!["--unknown"],
            vec!["unexpected"],
        ] {
            let args = args.into_iter().map(str::to_string).collect::<Vec<_>>();
            assert!(parse_remote_stop_args(&args).is_err(), "unexpectedly accepted {args:?}");
        }
    }

    #[test]
    fn relay_invitation_access_reads_owner_supplied_ticket_file() {
        let directory = tempfile::tempdir().unwrap();
        let ticket = directory.path().join("ticket");
        fs::write(&ticket, "short-lived-ticket\n").unwrap();
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

    #[test]
    fn relay_invitation_access_supports_native_and_durable_object_fallbacks() {
        let args = [
            "create",
            "--relay-route",
            "relay+wss://relay.example",
            "--relay-slot",
            "native-slot",
            "--relay-ticket",
            "native-ticket",
            "--relay-route",
            "relay+do://worker.example",
            "--relay-slot",
            "do-slot",
            "--relay-ticket",
            "do-ticket",
        ]
        .map(str::to_string);

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
