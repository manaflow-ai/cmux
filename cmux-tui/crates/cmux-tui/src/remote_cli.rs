//! User-facing remote daemon, connection, enrollment, and SSH bootstrap CLI.

use std::collections::BTreeMap;
use std::ffi::OsString;
use std::fs::{self, OpenOptions};
use std::io::{self, BufRead, Read};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{Context, anyhow};
use base64::Engine;
use cmux_remote::admin::{AdminRequest, AdminResponse, call_admin};
use cmux_remote::bridge::LocalPortForward;
use cmux_remote::client::WorkspaceClient;
use cmux_remote::connection::ReconnectPolicy;
use cmux_remote::crypto::ClientAuthMode;
use cmux_remote::identity::{
    ClientIdentityStore, EnrollmentInvitation, EnrollmentRelayAccess, KnownDaemon, KnownDaemonAuth,
    default_state_dir,
};
use cmux_remote::provider::{
    ROUTING_DIRECT_ADDRS, ROUTING_NODE_ID, ROUTING_RELAY_URL, RelayCredentialSource, SshProvider,
    SshProviderConfig,
};
use cmux_remote::ssh_bootstrap::{
    DISTRIBUTION_VERSION, NPM_BOOTSTRAP_VERSION, SshBootstrapConfig, SshBootstrapper,
};
use cmux_remote_protocol::{
    LanePolicy, REMOTE_PROTOCOL_VERSION, RoutePolicy, SessionId, WorkspaceRequest,
    WorkspaceResponse,
};
use serde_json::Value;
use url::Url;
use zeroize::Zeroizing;

use crate::remote_runtime::{
    ClientRuntimeOptions, DaemonRuntimeOptions, RelayClientOptions, daemon_paths,
    load_runtime_info, start_client_runtime, start_daemon_runtime,
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
  --invite URI  --daemon FINGERPRINT  --device-name NAME  --session NAME
  --state-dir PATH  --local-socket PATH  --headless

TRANSPORT:
  --lanes auto|single|isolated  --connect-timeout-seconds N
  For one relay, --relay-slot SLOT with one of --relay-ticket TICKET,
    --relay-ticket-file PATH, or --relay-ticket-command PROGRAM.
  For fallbacks, repeat up to four --relay-route ROUTE, --relay-slot SLOT,
    and credential-source groups in occurrence order.
  --relay-ticket-command-arg ARG  --iroh-relay URL  --iroh-address ADDR
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
  --session NAME  --lanes single|auto|isolated  --headless
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
        Some("known-daemons") => "USAGE: cmux-tui known-daemons [--state-dir PATH] [--json]\n",
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
    invitation: Option<String>,
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
    headless: bool,
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
            "--invite" => flags.invitation = Some(value("--invite")?),
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
            "--headless" => flags.headless = true,
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
                    "cmux-tui connect <route|invitation> [--invite URI] [--daemon FINGERPRINT] \
                     [--lanes auto|single|isolated] [--relay-slot SLOT --relay-ticket TICKET]"
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
    Ok(flags)
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
    let connected = start_connected(flags)?;
    if headless {
        println!("{}", connected.runtime.info().local_socket.display());
        while !crate::shutdown_requested() && !connected.runtime.is_finished() {
            thread::sleep(Duration::from_millis(100));
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
    let invitation = if let Some(encoded) = flags.invitation.take() {
        Some(EnrollmentInvitation::from_uri(&encoded)?)
    } else if flags.route.as_deref().is_some_and(|route| route.starts_with("cmux://enroll/")) {
        Some(EnrollmentInvitation::from_uri(flags.route.take().as_deref().unwrap())?)
    } else {
        None
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
    let explicit_route = flags.route.take();
    let (route_strings, auth, expected_daemon, known, carrier_auth) = if let Some(invitation) =
        &invitation
    {
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
        let endpoint = Url::parse(&route).with_context(|| format!("invalid route {route:?}"))?;
        if matches!(endpoint.scheme(), "ssh" | "unix") {
            (vec![route], ClientAuthMode::Carrier, None, None, true)
        } else {
            let known = async_runtime.block_on(select_known_daemon(
                &store,
                flags.daemon.as_deref(),
                Some(&route),
            ))?;
            if known.auth == KnownDaemonAuth::Carrier {
                return Err(anyhow!(
                    "daemon {} is known only through a trusted SSH or Unix carrier; use that carrier route or enroll this device for network access",
                    known.fingerprint
                ));
            }
            let key = async_runtime
                .block_on(store.daemon_key(&known.fingerprint))?
                .ok_or_else(|| anyhow!("known daemon key disappeared"))?;
            (vec![route], ClientAuthMode::Enrolled, Some(key), Some(known), false)
        }
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

    let mut endpoints = Vec::new();
    for route in &route_strings {
        let mut endpoint = Url::parse(route).with_context(|| format!("invalid route {route:?}"))?;
        extract_iroh_routing(&mut endpoint, &mut flags.routing)?;
        if !endpoints.iter().any(|candidate: &Url| candidate == &endpoint) {
            endpoints.push(endpoint);
        }
    }
    promote_reachable_unix_routes(&mut endpoints);
    let (relay, mut relay_routes) = client_relay_options(
        std::mem::take(&mut flags.relay_routes),
        std::mem::take(&mut flags.relay_slots),
        std::mem::take(&mut flags.relay_credentials),
    )?;
    if let Some(invitation) = &invitation {
        let mut invitation_routes = BTreeMap::new();
        for access in &invitation.relay_access {
            let route = Url::parse(&access.route)
                .with_context(|| format!("invalid invitation relay route {:?}", access.route))?
                .to_string();
            let options = RelayClientOptions {
                slot: access.slot.clone(),
                credentials: RelayCredentialSource::static_ticket(access.ticket.clone())?,
            };
            if invitation_routes.insert(route.clone(), options).is_some() {
                return Err(anyhow!("invitation repeats relay bootstrap route {route:?}"));
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
    for route in relay_routes.keys() {
        if !endpoints.iter().any(|endpoint| endpoint.as_str() == route) {
            return Err(anyhow!(
                "relay credential route {route:?} is not one of this connection's route candidates"
            ));
        }
    }
    let ssh = SshProviderConfig {
        ssh_binary: flags.ssh_binary.clone(),
        remote_binary: flags.remote_binary.clone(),
        remote_session: flags.ssh_session.clone(),
        remote_state_dir: flags.remote_state_dir.clone(),
        extra_args: flags.ssh_args.clone(),
        maximum_frame_bytes: crate::remote_runtime::MAX_CARRIER_FRAME_BYTES,
    };
    SshProvider::new(ssh.clone())?;
    let bootstrap_timeout = remaining_startup_timeout(startup_started, total_startup_timeout)?;
    async_runtime.block_on(bootstrap_initial_ssh_route(&endpoints, &flags, bootstrap_timeout))?;

    let session = SessionId(*uuid::Uuid::new_v4().as_bytes());
    let startup_timeout = remaining_startup_timeout(startup_started, total_startup_timeout)?;
    let runtime = start_client_runtime(ClientRuntimeOptions {
        endpoints,
        routing: flags.routing,
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
        relay,
        relay_routes,
        ssh,
    })?;

    if let Some(invitation) = &invitation {
        async_runtime.block_on(store.pin_daemon(
            invitation.daemon_name.clone(),
            invitation_daemon_key(invitation)?,
            route_strings,
        ))?;
    } else if carrier_auth {
        let name = route_strings[0].clone();
        async_runtime.block_on(store.pin_carrier_daemon(
            name,
            runtime.info().daemon_public_key,
            route_strings,
        ))?;
    } else if let Some(known) = known
        && expected_daemon != Some(runtime.info().daemon_public_key)
    {
        return Err(anyhow!("daemon key changed for {}", known.name));
    }

    let connected_route = runtime.info().route.clone();
    Ok(ConnectedRuntime { runtime, route: connected_route })
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
        let endpoint = Url::parse(&route)
            .with_context(|| format!("invalid relay credential route {route:?}"))?;
        if !matches!(endpoint.scheme(), "relay+ws" | "relay+wss" | "relay+https" | "relay+do") {
            return Err(anyhow!("relay credential route {route:?} is not a relay route"));
        }
        let route = endpoint.to_string();
        let options =
            RelayClientOptions { slot, credentials: client_relay_credential(credential)? };
        if by_route.insert(route.clone(), options).is_some() {
            return Err(anyhow!("relay credential route {route:?} is repeated"));
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

fn promote_reachable_unix_routes(routes: &mut [Url]) {
    routes.sort_by_key(|route| match (route.scheme(), reachable_unix_route(route)) {
        ("unix", true) => 0,
        ("unix", false) => 2,
        _ => 1,
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
        let workspace = match client
            .request(WorkspaceRequest::OpenWorkspace { root: workspace_root })
            .await?
        {
            WorkspaceResponse::Workspace { id, .. } => id,
            response => return Err(anyhow!("unexpected open-workspace response: {response:?}")),
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
            response => return Err(anyhow!("unexpected create-route response: {response:?}")),
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
        let stdin = io::stdin();
        for line in stdin.lock().lines() {
            let line = line?;
            if line.trim().is_empty() {
                continue;
            }
            let request: WorkspaceRequest = serde_json::from_str(&line)
                .with_context(|| format!("invalid WorkspaceRequest: {line}"))?;
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

async fn bootstrap_initial_ssh_route(
    endpoints: &[Url],
    flags: &ConnectFlags,
    timeout: Duration,
) -> anyhow::Result<()> {
    let Some(endpoint) = endpoints.first().filter(|endpoint| endpoint.scheme() == "ssh") else {
        return if flags.upgrade {
            Err(anyhow!("--upgrade requires SSH to be the initial route"))
        } else {
            Ok(())
        };
    };
    let (destination, port) = ssh_bootstrap_destination(endpoint)?;
    let mut bootstrap = SshBootstrapConfig::defaults(destination);
    bootstrap.ssh_binary = flags.ssh_binary.clone();
    bootstrap.port = port;
    bootstrap.remote_binary = flags.remote_binary.clone();
    bootstrap.extra_args = flags.ssh_args.clone();
    bootstrap.auto_install = flags.auto_install;
    bootstrap.timeout = timeout;
    let bootstrap = SshBootstrapper::new(bootstrap)?;
    tokio::select! {
        result = tokio::time::timeout(timeout, async {
            if flags.upgrade {
                bootstrap.install_verified().await?;
            } else {
                bootstrap.ensure_installed().await?;
            }
            if flags.upgrade {
                bootstrap
                    .stop_daemon(&flags.ssh_session, flags.remote_state_dir.as_deref())
                    .await?;
            }
            Ok::<(), cmux_remote::ssh_bootstrap::BootstrapError>(())
        }) => {
            result.map_err(|_| anyhow!("SSH bootstrap timed out after {}s", timeout.as_secs()))??;
            Ok(())
        }
        () = wait_for_shutdown_request() => Err(anyhow!("SSH bootstrap interrupted")),
    }
}

async fn wait_for_shutdown_request() {
    while !crate::shutdown_requested() {
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

fn ssh_bootstrap_destination(endpoint: &Url) -> anyhow::Result<(String, Option<u16>)> {
    if endpoint.password().is_some() {
        return Err(anyhow!("passwords are not allowed in SSH URLs; use SSH authentication"));
    }
    if !matches!(endpoint.path(), "" | "/")
        || endpoint.query().is_some()
        || endpoint.fragment().is_some()
    {
        return Err(anyhow!("SSH routes cannot contain a path, query, or fragment"));
    }
    let host = match endpoint.host().ok_or_else(|| anyhow!("SSH endpoint is missing a host"))? {
        url::Host::Domain(host) => host.to_string(),
        url::Host::Ipv4(host) => host.to_string(),
        url::Host::Ipv6(host) => host.to_string(),
    };
    let username = endpoint.username();
    let destination = if username.is_empty() { host } else { format!("{username}@{host}") };
    Ok((destination, endpoint.port()))
}

fn ssh_url(destination: &str) -> anyhow::Result<String> {
    if destination.starts_with('-') || destination.bytes().any(|byte| byte.is_ascii_whitespace()) {
        return Err(anyhow!("invalid SSH destination"));
    }
    let url = format!("ssh://{destination}");
    Url::parse(&url).context("invalid SSH destination")?;
    Ok(url)
}

fn run_enroll(args: &[String]) -> anyhow::Result<()> {
    let action = args.first().map(String::as_str).unwrap_or("status");
    if action == "connect" {
        return run_connect(&args[1..], None);
    }
    let session = flag_value(args, "--session").unwrap_or_else(|| "main".into());
    let state_dir = flag_value(args, "--state-dir").map(PathBuf::from);
    let admin_socket = flag_value(args, "--admin-socket").map(PathBuf::from).unwrap_or_else(|| {
        load_runtime_info(&session, state_dir.as_deref())
            .map(|runtime| runtime.admin_socket)
            .or_else(|_| daemon_paths(&session, state_dir.as_deref()).map(|(_, _, admin)| admin))
            .unwrap_or_else(|_| PathBuf::from("/nonexistent"))
    });
    let request = match action {
        "status" => AdminRequest::Status,
        "create" => AdminRequest::CreateInvitation {
            ttl_seconds: flag_value(args, "--ttl")
                .map(|value| value.parse())
                .transpose()
                .context("--ttl must be seconds")?
                .unwrap_or(300),
            route_hints: repeated_flag_values(args, "--advertise"),
            relay_access: invitation_relay_access(args)?,
        },
        "pending" => AdminRequest::Pending,
        "approve" => AdminRequest::Approve { invitation_id: required_positional(args, 1)? },
        "deny" => AdminRequest::Deny { invitation_id: required_positional(args, 1)? },
        "devices" => AdminRequest::Devices,
        "connections" => AdminRequest::Connections,
        "revoke" => AdminRequest::Revoke { device_id: required_positional(args, 1)? },
        "disconnect" => AdminRequest::Disconnect {
            device_id: required_positional(args, 1)?,
            session_id: required_positional(args, 2)?,
        },
        other => return Err(anyhow!("unknown enroll action {other:?}")),
    };
    let response = tokio_runtime()?.block_on(call_admin(&admin_socket, &request))?;
    print_admin_response(action, response, args.iter().any(|argument| argument == "--json"))
}

fn run_known_daemons(args: &[String]) -> anyhow::Result<()> {
    let client_root = flag_value(args, "--state-dir")
        .map(PathBuf::from)
        .or_else(default_state_dir)
        .ok_or_else(|| anyhow!("cannot determine remote state directory; use --state-dir"))?
        .join("client");
    let store = ClientIdentityStore::load_or_create(client_root)?;
    let daemons = tokio_runtime()?.block_on(store.known_daemons());
    if args.iter().any(|argument| argument == "--json") {
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

fn invitation_relay_access(args: &[String]) -> anyhow::Result<Vec<EnrollmentRelayAccess>> {
    let routes = repeated_flag_values(args, "--relay-route");
    let slots = repeated_flag_values(args, "--relay-slot");
    let ticket_sources = args
        .windows(2)
        .filter_map(|pair| match pair[0].as_str() {
            "--relay-ticket" => Some((false, pair[1].clone())),
            "--relay-ticket-file" => Some((true, pair[1].clone())),
            _ => None,
        })
        .collect::<Vec<_>>();
    if routes.is_empty() && slots.is_empty() && ticket_sources.is_empty() {
        return Ok(Vec::new());
    }
    if routes.len() != slots.len() || routes.len() != ticket_sources.len() {
        return Err(anyhow!(
            "each invitation relay needs one --relay-route, one --relay-slot, and one --relay-ticket or --relay-ticket-file"
        ));
    }
    if routes.len() > 2 {
        return Err(anyhow!("an invitation supports at most two relay bootstrap routes"));
    }

    routes
        .into_iter()
        .zip(slots)
        .zip(ticket_sources)
        .map(|((route, slot), (is_file, source))| {
            let ticket =
                if is_file { read_invitation_ticket_file(Path::new(&source))? } else { source };
            Ok(EnrollmentRelayAccess { route, slot, ticket })
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

fn run_remote_stop(args: &[String]) -> anyhow::Result<()> {
    let session = flag_value(args, "--session").unwrap_or_else(|| "main".into());
    let state_dir = flag_value(args, "--state-dir").map(PathBuf::from);
    let (_, default_link, default_admin) = daemon_paths(&session, state_dir.as_deref())?;
    let runtime = match load_runtime_info(&session, state_dir.as_deref()) {
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
    use tokio::io::{AsyncWriteExt, copy};

    let stream = tokio::net::UnixStream::connect(link).await?;
    let (mut socket_read, mut socket_write) = stream.into_split();
    let mut stdin = tokio::io::stdin();
    let mut stdout = tokio::io::stdout();
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
    let matching = daemons
        .iter()
        .filter(|daemon| {
            route.is_some_and(|route| daemon.route_hints.iter().any(|hint| hint == route))
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

fn invitation_daemon_key(invitation: &EnrollmentInvitation) -> anyhow::Result<[u8; 32]> {
    let bytes =
        base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(&invitation.daemon_public_key)?;
    bytes.try_into().map_err(|bytes: Vec<u8>| anyhow!("daemon key has {} bytes", bytes.len()))
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
            other => return Err(anyhow!("unknown Iroh route parameter {other:?}")),
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

fn repeated_flag_values(args: &[String], flag: &str) -> Vec<String> {
    args.windows(2).filter(|pair| pair[0] == flag).map(|pair| pair[1].clone()).collect()
}

fn required_positional(args: &[String], skip: usize) -> anyhow::Result<String> {
    let mut index = 1;
    let mut position = 0;
    while index < args.len() {
        if args[index] == "--json" {
            index += 1;
        } else if args[index].starts_with('-') {
            index += 2;
        } else {
            position += 1;
            if position == skip {
                return Ok(args[index].clone());
            }
            index += 1;
        }
    }
    Err(anyhow!("missing identifier"))
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
    fn ssh_can_distinguish_transport_default_from_an_explicit_lane_policy() {
        let default = parse_connect_flags(&["host".into()]).unwrap();
        assert!(!default.lanes_explicit);
        let explicit =
            parse_connect_flags(&["host".into(), "--lanes".into(), "isolated".into()]).unwrap();
        assert!(explicit.lanes_explicit);
    }

    #[test]
    fn ssh_bootstrap_normalizes_ipv6_and_preserves_port() {
        let endpoint = Url::parse("ssh://alice@[2001:db8::1]:2222").unwrap();
        assert_eq!(
            ssh_bootstrap_destination(&endpoint).unwrap(),
            ("alice@2001:db8::1".into(), Some(2222))
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn connection_timeout_bounds_initial_ssh_bootstrap() {
        use std::os::unix::fs::PermissionsExt;

        let directory = tempfile::tempdir().unwrap();
        let script = directory.path().join("ssh");
        fs::write(&script, "#!/bin/sh\nexec /bin/sleep 30\n").unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();
        let flags = ConnectFlags {
            ssh_binary: script.to_string_lossy().into_owned(),
            remote_binary: "~/.local/bin/cmux-tui".into(),
            auto_install: true,
            ..ConnectFlags::default()
        };
        let endpoints = [Url::parse("ssh://example.com").unwrap()];

        let error = bootstrap_initial_ssh_route(&endpoints, &flags, Duration::from_millis(100))
            .await
            .unwrap_err();
        assert!(error.to_string().contains("timed out"));
    }

    #[test]
    fn help_detection_does_not_consume_ssh_argument_values() {
        assert!(!remote_help_requested(&["host".into(), "--ssh-arg".into(), "-h".into()]));
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
        let mut routes = vec![missing.clone(), websocket.clone(), local.clone()];

        promote_reachable_unix_routes(&mut routes);

        assert_eq!(routes, [local, websocket, missing]);
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
        assert_eq!(required_positional(&args, 1).unwrap(), "device-id");
        assert_eq!(required_positional(&args, 2).unwrap(), "0123456789abcdef0123456789abcdef");
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
        let access = invitation_relay_access(&args).unwrap();
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

        let access = invitation_relay_access(&args).unwrap();
        assert_eq!(access.len(), 2);
        assert_eq!(access[0].slot, "native-slot");
        assert_eq!(access[1].slot, "do-slot");
    }

    #[test]
    fn relay_invitation_access_rejects_incomplete_groups() {
        let args = ["create", "--relay-route", "relay+do://worker.example"].map(str::to_string);
        assert!(invitation_relay_access(&args).is_err());
    }
}
