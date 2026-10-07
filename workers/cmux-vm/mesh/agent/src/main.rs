use std::fs::OpenOptions;
use std::io::{self, Write};
use std::net::SocketAddrV4;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::{Duration, Instant};

use clap::{Parser, Subcommand};
use serde_json::json;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use cmux_mesh_agent::api::{self, ApiError, EnrollAuth, Enrollment, SignedRead};
use cmux_mesh_agent::config::{self, AgentConfig};
use cmux_mesh_agent::install::{self, Purpose};
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
    /// Make a P-256 install key in a new 0600 file; print its public key.
    InstallKeygen {
        #[arg(long)]
        out: PathBuf,
    },
    /// Register the public key with a mesh and save the returned tunnel config.
    Enroll {
        #[arg(long)]
        key_file: PathBuf,
        /// The install key that signs the enrollment.
        #[arg(long)]
        install_key: PathBuf,
        #[arg(long)]
        mesh: String,
        #[arg(long)]
        name: String,
        #[arg(long)]
        out: PathBuf,
        /// One-time enroll code (mec_…); default $CMUX_MESH_ENROLL_CODE. With a
        /// code no API key is needed or sent.
        #[arg(long)]
        code: Option<String>,
        /// API base URL; default $CMUX_VM_API_URL.
        #[arg(long)]
        api: Option<String>,
    },
    /// Make a new WireGuard key, register it, and update the config.
    Rotate {
        #[arg(long)]
        config: PathBuf,
        /// The current key; kept as it is.
        #[arg(long)]
        key_file: PathBuf,
        /// The install key the device enrolled with.
        #[arg(long)]
        install_key: PathBuf,
        /// Where the new key goes; must not exist.
        #[arg(long)]
        new_key_file: PathBuf,
        /// API base URL; default $CMUX_VM_API_URL.
        #[arg(long)]
        api: Option<String>,
    },
    /// Print this device's peer map. With $CMUX_VM_API_KEY it uses the key;
    /// without one it signs the request with --install-key.
    Peers {
        #[arg(long)]
        config: PathBuf,
        /// The install key the device enrolled with; signs the request when
        /// no API key is set.
        #[arg(long)]
        install_key: Option<PathBuf>,
        #[arg(long)]
        api: Option<String>,
    },
    /// Print this device's tunnel config (never a private key). With
    /// $CMUX_VM_API_KEY it uses the key; without one it signs with --install-key.
    Tunnel {
        #[arg(long)]
        config: PathBuf,
        /// The install key the device enrolled with; signs the request when
        /// no API key is set.
        #[arg(long)]
        install_key: Option<PathBuf>,
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
    /// The install key; signs the peer-map read for vm_ ids when no API key is set.
    #[arg(long)]
    install_key: Option<PathBuf>,
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
        Command::InstallKeygen { out: path } => {
            let public = install::install_keygen(&path)
                .map_err(|error| Fail::new("KeyFile", format!("{}: {error}", path.display())))?;
            writeln!(out, "{public}")?;
            Ok(true)
        }
        Command::Enroll { key_file, install_key, mesh, name, out: config_path, code, api } => {
            if config_path.exists() {
                return Err(Fail::new(
                    "ConfigExists",
                    format!("{} exists; refusing to overwrite", config_path.display()),
                ));
            }
            api::check_id(&mesh, "mesh_")?;
            api::check_device_name(&name)?;
            let code = code
                .or_else(|| std::env::var("CMUX_MESH_ENROLL_CODE").ok())
                .map(|code| code.trim().to_string());
            if let Some(code) = &code {
                api::check_enroll_code(code)?;
            }
            let wg_public_key = read_key(&key_file)?.public_key_base64();
            let install = read_install_key(&install_key)?;
            let base = api::api_base(api.as_deref())?;
            let token;
            let auth = match code.as_deref() {
                Some(code) => EnrollAuth::Code(code),
                None => {
                    token = api::api_key()?;
                    EnrollAuth::ApiKey(&token)
                }
            };
            let install_public_key = install.public_key_base64();
            let proof = install::prove(&install, Purpose::Enroll, &mesh, &wg_public_key, &name)?;
            drop(install);
            let enrollment = Enrollment {
                name: &name,
                wg_public_key: &wg_public_key,
                install_public_key: &install_public_key,
                proof: &proof,
            };
            let body = api::enroll_device(&base, auth, &mesh, &enrollment)?;
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
        Command::Rotate { config: config_path, key_file, install_key, new_key_file, api } => {
            // Before any request: never overwrite a key, not even a dangling link.
            if new_key_file.symlink_metadata().is_ok() {
                return Err(Fail::new(
                    "KeyExists",
                    format!("{} exists; refusing to overwrite", new_key_file.display()),
                ));
            }
            let saved_text = std::fs::read_to_string(&config_path).map_err(|error| {
                Fail::new("Config", format!("read {}: {error}", config_path.display()))
            })?;
            let saved = config::parse_agent_config(&saved_text)?;
            api::check_id(&saved.device_id, "dev_")?;
            let current_public = read_key(&key_file)?.public_key_base64();
            if let Some(enrolled) = &saved.wg_public_key
                && enrolled.trim() != current_public
            {
                return Err(Fail::new(
                    "KeyMismatch",
                    "the key file is not the key this device enrolled",
                ));
            }
            let install = read_install_key(&install_key)?;
            let base = api::api_base(api.as_deref())?;
            // Without an API key the install-key signature is the credential (M3).
            let token = api::optional_api_key();
            // The new key is on disk before the request: if the server
            // switches and the response is lost, the key is not.
            let new_key = key::PrivateKey::generate()?;
            key::write_new_key_file(&new_key_file, &new_key).map_err(|error| {
                Fail::new("KeyFile", format!("{}: {error}", new_key_file.display()))
            })?;
            let new_public = new_key.public_key_base64();
            drop(new_key);
            let proof =
                install::prove(&install, Purpose::RotateKey, &saved.device_id, &new_public, "")?;
            drop(install);
            let sent_at = ops::wall_ms();
            let body =
                api::rotate_key(&base, token.as_deref(), &saved.device_id, &new_public, &proof)?;
            let responded_at = ops::wall_ms();
            let updated = config::rotated_config(&saved_text, &body, &new_public)?;
            replace_private_file(&config_path, updated.as_bytes())?;
            let rotated = config::parse_agent_config(&updated)?;
            writeln!(
                out,
                "{}",
                json!({
                    "deviceId": rotated.device_id,
                    "sentAtMs": sent_at,
                    "respondedAtMs": responded_at,
                    "serverPublicKey": STANDARD.encode(rotated.tunnel.server_public_key),
                    "wgPublicKey": new_public,
                })
            )?;
            Ok(true)
        }
        Command::Peers { config: config_path, install_key, api } => {
            let saved = config::load(&config_path)?;
            let body = fetch_peers(&saved, api.as_deref(), install_key.as_deref())?;
            let map = api::parse_peers(&body)?;
            writeln!(out, "{}", serde_json::to_string(&map).map_err(|e| Fail::new("Json", e))?)?;
            Ok(true)
        }
        Command::Tunnel { config: config_path, install_key, api } => {
            let saved = config::load(&config_path)?;
            let body = match credential(install_key.as_deref())? {
                Credential::ApiKey(token) => {
                    let base = api::api_base(api.as_deref())?;
                    api::fetch_tunnel(&base, &token, &saved.tunnel.id)?
                }
                Credential::Install(path) => {
                    signed_read(&saved, api.as_deref(), path, SignedRead::Tunnel)?
                }
            };
            // Parse before printing: the answer must be a tunnel config.
            let tunnel = config::parse_tunnel(&body)?;
            if tunnel.device_id != saved.device_id {
                return Err(Fail::new(
                    "InvalidResponse",
                    "the tunnel config is for another device",
                ));
            }
            writeln!(out, "{}", body.trim())?;
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
            let destination =
                resolve(&peer, &saved, session.api.as_deref(), session.install_key.as_deref())?;
            let options = PingOptions {
                count,
                timeout: Duration::from_millis(timeout_ms),
                interval: Duration::from_millis(interval_ms),
            };
            Ok(ops::ping(&mut tunnel, destination, options, &mut out)? > 0)
        }
        Command::Tcp { session, peer, port, send, timeout_ms } => {
            let (mut tunnel, saved) = open_session(&session)?;
            let destination =
                resolve(&peer, &saved, session.api.as_deref(), session.install_key.as_deref())?;
            let remote = SocketAddrV4::new(destination, port);
            let timeout = Duration::from_millis(timeout_ms);
            Ok(ops::tcp(&mut tunnel, remote, send.as_deref(), timeout, &mut out)?)
        }
        Command::Probe { session, peer, port, interval_ms, duration_s, attempt_timeout_ms } => {
            let (mut tunnel, saved) = open_session(&session)?;
            let destination =
                resolve(&peer, &saved, session.api.as_deref(), session.install_key.as_deref())?;
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

fn read_install_key(path: &Path) -> Result<install::InstallKey, Fail> {
    install::read_install_key_file(path)
        .map_err(|error| Fail::new("InstallKeyFile", format!("{}: {error}", path.display())))
}

/// Replace `path` atomically: write a 0600 temp file next to it, sync, and
/// rename over it.
fn replace_private_file(path: &Path, contents: &[u8]) -> Result<(), Fail> {
    let fail = |error: io::Error| Fail::new("ConfigWrite", format!("{}: {error}", path.display()));
    let file_name = path
        .file_name()
        .ok_or_else(|| Fail::new("ConfigWrite", format!("{}: not a file", path.display())))?;
    let directory = match path.parent() {
        Some(parent) if !parent.as_os_str().is_empty() => parent,
        _ => Path::new("."),
    };
    let temp =
        directory.join(format!(".{}.{}.tmp", file_name.to_string_lossy(), std::process::id()));
    let written = (|| {
        let mut file = OpenOptions::new().write(true).create_new(true).mode(0o600).open(&temp)?;
        file.write_all(contents)?;
        file.write_all(b"\n")?;
        file.sync_all()?;
        std::fs::rename(&temp, path)?;
        std::fs::File::open(directory)?.sync_all()
    })();
    if written.is_err() {
        let _ = std::fs::remove_file(&temp);
    }
    written.map_err(fail)
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

/// How a device authenticates a request about itself: `$CMUX_VM_API_KEY`
/// when set, else its install-key signature (M3).
enum Credential<'a> {
    ApiKey(String),
    Install(&'a Path),
}

fn credential(install_key: Option<&Path>) -> Result<Credential<'_>, Fail> {
    if let Some(token) = api::optional_api_key() {
        return Ok(Credential::ApiKey(token));
    }
    install_key.map(Credential::Install).ok_or_else(|| {
        Fail::new(
            "MissingCredential",
            "set CMUX_VM_API_KEY, or pass --install-key to sign the request with the device's install key",
        )
    })
}

/// A device-signed read: sign `read` for this device with the install key
/// and post it with no Authorization header.
fn signed_read(
    saved: &AgentConfig,
    api_flag: Option<&str>,
    install_key: &Path,
    read: SignedRead,
) -> Result<String, Fail> {
    api::check_id(&saved.device_id, "dev_")?;
    let install = read_install_key(install_key)?;
    let base = api::api_base(api_flag)?;
    let purpose = match read {
        SignedRead::Peers => Purpose::Peers,
        SignedRead::Tunnel => Purpose::Tunnel,
    };
    let proof = install::prove(&install, purpose, &saved.device_id, "", "")?;
    drop(install);
    Ok(api::signed_read(&base, read, &saved.device_id, &proof)?)
}

fn fetch_peers(
    saved: &AgentConfig,
    api_flag: Option<&str>,
    install_key: Option<&Path>,
) -> Result<String, Fail> {
    match credential(install_key)? {
        Credential::ApiKey(token) => {
            let base = api::api_base(api_flag)?;
            Ok(api::fetch_peers(&base, &token, &saved.device_id)?)
        }
        Credential::Install(path) => signed_read(saved, api_flag, path, SignedRead::Peers),
    }
}

fn resolve(
    peer: &str,
    saved: &AgentConfig,
    api_flag: Option<&str>,
    install_key: Option<&Path>,
) -> Result<std::net::Ipv4Addr, Fail> {
    if let Ok(address) = peer.parse() {
        return Ok(address);
    }
    let map = api::parse_peers(&fetch_peers(saved, api_flag, install_key)?)?;
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
