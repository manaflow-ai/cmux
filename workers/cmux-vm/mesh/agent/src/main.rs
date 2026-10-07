use std::fs::OpenOptions;
use std::io::{self, Write};
use std::net::SocketAddrV4;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::{Duration, Instant};

use clap::{Parser, Subcommand};
use serde_json::json;

use cmux_mesh_agent::api::{self, ApiError};
use cmux_mesh_agent::config::{self, AgentConfig};
use cmux_mesh_agent::key;
use cmux_mesh_agent::ops::{self, PingOptions, ProbeOptions};
use cmux_mesh_agent::tunnel::{self, Tunnel, TunnelParams};

#[derive(Parser)]
#[command(name = "cmux-mesh-agent", version, about = "cmux mesh device agent (experiment)")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Make an X25519 key in a new 0600 file; print the public key.
    Keygen {
        #[arg(long)]
        key_file: PathBuf,
    },
    /// Register the public key with a mesh and save the returned tunnel config.
    Enroll {
        #[arg(long)]
        key_file: PathBuf,
        #[arg(long)]
        mesh: String,
        #[arg(long)]
        name: String,
        #[arg(long)]
        out: PathBuf,
        /// API base URL; default $CMUX_VM_API_URL.
        #[arg(long)]
        api: Option<String>,
    },
    /// Print this device's peer map.
    Peers {
        #[arg(long)]
        config: PathBuf,
        #[arg(long)]
        api: Option<String>,
    },
    /// Bring the tunnel up, report the handshake, and hold it for --hold-s.
    Up {
        #[command(flatten)]
        session: SessionArgs,
        #[arg(long, default_value_t = 0)]
        hold_s: u64,
    },
    /// ICMP echo through the tunnel.
    Ping {
        #[command(flatten)]
        session: SessionArgs,
        peer: String,
        #[arg(short = 'c', default_value_t = 4)]
        count: u16,
        #[arg(long, default_value_t = 1000)]
        timeout_ms: u64,
        #[arg(long, default_value_t = 1000)]
        interval_ms: u64,
    },
    /// TCP connect through the tunnel, optionally exchange one line.
    Tcp {
        #[command(flatten)]
        session: SessionArgs,
        peer: String,
        port: u16,
        #[arg(long)]
        send: Option<String>,
        #[arg(long, default_value_t = 3000)]
        timeout_ms: u64,
    },
    /// A TCP connect attempt every interval; one JSON line per attempt.
    Probe {
        #[command(flatten)]
        session: SessionArgs,
        peer: String,
        port: u16,
        #[arg(long, default_value_t = 50)]
        interval_ms: u64,
        #[arg(long)]
        duration_s: u64,
        #[arg(long, default_value_t = 300)]
        attempt_timeout_ms: u64,
    },
}

#[derive(clap::Args)]
struct SessionArgs {
    #[arg(long)]
    config: PathBuf,
    #[arg(long)]
    key_file: PathBuf,
    /// API base URL for resolving vm_ ids; default $CMUX_VM_API_URL.
    #[arg(long)]
    api: Option<String>,
    /// How long to wait for the first WireGuard handshake.
    #[arg(long, default_value_t = 25_000)]
    handshake_timeout_ms: u64,
}

/// A failure printed as one JSON line on stderr.
struct Fail {
    tag: String,
    message: String,
    status: Option<u16>,
}

impl Fail {
    fn new(tag: &str, message: impl ToString) -> Self {
        Self { tag: tag.into(), message: message.to_string(), status: None }
    }
}

impl From<ApiError> for Fail {
    fn from(error: ApiError) -> Self {
        Self { tag: error.tag, message: error.message, status: error.status }
    }
}

impl From<tunnel::TunnelError> for Fail {
    fn from(error: tunnel::TunnelError) -> Self {
        Self::new("Tunnel", error)
    }
}

impl From<io::Error> for Fail {
    fn from(error: io::Error) -> Self {
        Self::new("Io", error)
    }
}

impl From<config::ConfigError> for Fail {
    fn from(error: config::ConfigError) -> Self {
        Self::new("Config", error)
    }
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    match run(cli.command) {
        Ok(true) => ExitCode::SUCCESS,
        Ok(false) => ExitCode::FAILURE,
        Err(fail) => {
            let mut value = json!({ "error": fail.tag, "message": fail.message });
            if let Some(status) = fail.status {
                value["status"] = json!(status);
            }
            eprintln!("{value}");
            ExitCode::FAILURE
        }
    }
}

fn run(command: Command) -> Result<bool, Fail> {
    let stdout = io::stdout();
    let mut out = stdout.lock();
    match command {
        Command::Keygen { key_file } => {
            let public = key::keygen(&key_file).map_err(|error| {
                Fail::new("KeyFile", format!("{}: {error}", key_file.display()))
            })?;
            writeln!(out, "{public}")?;
            Ok(true)
        }
        Command::Enroll { key_file, mesh, name, out: config_path, api } => {
            if config_path.exists() {
                return Err(Fail::new(
                    "ConfigExists",
                    format!("{} exists; refusing to overwrite", config_path.display()),
                ));
            }
            api::check_id(&mesh, "mesh_")?;
            let private = read_key(&key_file)?;
            let base = api::api_base(api.as_deref())?;
            let token = api::api_key()?;
            let body =
                api::enroll_device(&base, &token, &mesh, &name, &private.public_key_base64())?;
            drop(private);
            write_new_private_file(&config_path, body.as_bytes())?;
            let saved = config::parse_agent_config(&body)?;
            writeln!(
                out,
                "{}",
                json!({
                    "deviceId": saved.device_id,
                    "meshId": saved.mesh_id,
                    "tunnelId": saved.tunnel.id,
                    "config": config_path.display().to_string(),
                })
            )?;
            Ok(true)
        }
        Command::Peers { config: config_path, api } => {
            let saved = config::load(&config_path)?;
            let body = fetch_peers(&saved, api.as_deref())?;
            let map = api::parse_peers(&body)?;
            writeln!(out, "{}", serde_json::to_string(&map).map_err(|e| Fail::new("Json", e))?)?;
            Ok(true)
        }
        Command::Up { session, hold_s } => {
            let (mut tunnel, _) = open_session(&session)?;
            let until = Instant::now() + Duration::from_secs(hold_s);
            tunnel.poll_until(until)?;
            Ok(true)
        }
        Command::Ping { session, peer, count, timeout_ms, interval_ms } => {
            let (mut tunnel, saved) = open_session(&session)?;
            let destination = resolve(&peer, &saved, session.api.as_deref())?;
            let options = PingOptions {
                count,
                timeout: Duration::from_millis(timeout_ms),
                interval: Duration::from_millis(interval_ms),
            };
            Ok(ops::ping(&mut tunnel, destination, options, &mut out)? > 0)
        }
        Command::Tcp { session, peer, port, send, timeout_ms } => {
            let (mut tunnel, saved) = open_session(&session)?;
            let destination = resolve(&peer, &saved, session.api.as_deref())?;
            let remote = SocketAddrV4::new(destination, port);
            let timeout = Duration::from_millis(timeout_ms);
            Ok(ops::tcp(&mut tunnel, remote, send.as_deref(), timeout, &mut out)?)
        }
        Command::Probe { session, peer, port, interval_ms, duration_s, attempt_timeout_ms } => {
            let (mut tunnel, saved) = open_session(&session)?;
            let destination = resolve(&peer, &saved, session.api.as_deref())?;
            let options = ProbeOptions {
                interval: Duration::from_millis(interval_ms.max(1)),
                duration: Duration::from_secs(duration_s),
                attempt_timeout: Duration::from_millis(attempt_timeout_ms),
            };
            ops::probe(&mut tunnel, SocketAddrV4::new(destination, port), options, &mut out)?;
            Ok(true)
        }
    }
}

fn read_key(path: &Path) -> Result<key::PrivateKey, Fail> {
    key::read_key_file(path)
        .map_err(|error| Fail::new("KeyFile", format!("{}: {error}", path.display())))
}

fn write_new_private_file(path: &Path, contents: &[u8]) -> Result<(), Fail> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .map_err(|error| Fail::new("ConfigWrite", format!("{}: {error}", path.display())))?;
    file.write_all(contents)?;
    file.write_all(b"\n")?;
    file.sync_all()?;
    Ok(())
}

fn fetch_peers(saved: &AgentConfig, api_flag: Option<&str>) -> Result<String, Fail> {
    let base = api::api_base(api_flag)?;
    let token = api::api_key()?;
    Ok(api::fetch_peers(&base, &token, &saved.device_id)?)
}

fn resolve(
    peer: &str,
    saved: &AgentConfig,
    api_flag: Option<&str>,
) -> Result<std::net::Ipv4Addr, Fail> {
    if let Ok(address) = peer.parse() {
        return Ok(address);
    }
    let map = api::parse_peers(&fetch_peers(saved, api_flag)?)?;
    Ok(api::resolve_peer(peer, Some(&map))?)
}

/// Load the config and key, bring the tunnel up, and log the handshake time
/// to stderr as `{"event":"handshake","ms":…}`.
fn open_session(args: &SessionArgs) -> Result<(Tunnel, AgentConfig), Fail> {
    let saved = config::load(&args.config)?;
    let private = read_key(&args.key_file)?;
    if let Some(enrolled) = &saved.wg_public_key
        && enrolled.trim() != private.public_key_base64()
    {
        return Err(Fail::new("KeyMismatch", "the key file is not the key this device enrolled"));
    }
    let tunnel_config = &saved.tunnel;
    let endpoint =
        tunnel::resolve_endpoint(&tunnel_config.endpoint_host, tunnel_config.endpoint_port)
            .map_err(|error| {
                Fail::new("Resolve", format!("{}: {error}", tunnel_config.endpoint_host))
            })?;
    let mut tunnel = Tunnel::new(TunnelParams {
        private_key: private.secret(),
        peer_public_key: tunnel_config.server_public_key,
        endpoint: Some(endpoint),
        bind: tunnel::bind_for(endpoint),
        address: tunnel_config.interface_address,
        allowed_ips: tunnel_config.allowed_ips.clone(),
        mtu: tunnel_config.mtu,
        persistent_keepalive: Some(tunnel_config.persistent_keepalive_seconds),
    })?;
    drop(private);
    let timeout = Duration::from_millis(args.handshake_timeout_ms);
    match tunnel.handshake(timeout) {
        Ok(took) => {
            eprintln!(
                "{}",
                json!({ "event": "handshake", "ms": took.as_millis() as u64, "endpoint": endpoint.to_string() })
            );
            Ok((tunnel, saved))
        }
        Err(error) => {
            eprintln!(
                "{}",
                json!({ "event": "handshake", "error": "timeout", "ms": timeout.as_millis() as u64, "endpoint": endpoint.to_string() })
            );
            Err(error.into())
        }
    }
}
