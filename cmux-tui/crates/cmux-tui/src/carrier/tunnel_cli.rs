//! `cmux carrier tunnel`: the Cloud provider mesh tunnel ([`super::tunnel`])
//! as a process, for the app and the probe runner.
//!
//! ```text
//! cmux carrier tunnel --machine-id machine_… --name NAME --socket PATH
//!     [--platform URL] [--vm-api URL] [--cloud-token-file PATH] [--team team_…]
//! ```
//!
//! - Keys come on stdin's first line, never argv, the environment or a file:
//!   `{"wg_private_key":"<std base64, 32 bytes>","install_key":"<PKCS#8 base64url>"}`,
//!   the join record's WireGuard key and the device's ES256 install key. The
//!   caller (the app, which keeps both in the Keychain, or the probe runner)
//!   owns them; this process only holds them while it runs.
//! - `--platform` (else `CMUX_PLATFORM_URL`) is cmux-platform's origin, where
//!   attach lives; the person's credential is `--cloud-token-file` or
//!   `CMUX_CLOUD_ACCESS_TOKEN`, the team `--team` or `CMUX_CLOUD_TEAM`.
//!   `--vm-api` (else `CMUX_VM_API_URL`, else the VM API of the deployment
//!   whose platform origin that is) is where the device reads its tunnel.
//! - stdout gets `{"event":"tunnel-starting","socket":…}` first, then one
//!   JSON line per status: `{"event":"tunnel-ready",
//!   "socket":…,"device_id":…,"address_v4":…}` (then `cmux wg dial --hub
//!   <socket> %h %p` reaches the mesh), `tunnel-retrying`, and a last
//!   `tunnel-unavailable` (`"reason":"no mesh"`), `tunnel-failed` or
//!   `tunnel-stopped`. A second supervisor on the same socket prints
//!   `tunnel-held` with the socket and exits 0: the first one serves it.
//! - Runs until SIGTERM or SIGINT, or a final status. Exit codes: 0 stopped
//!   or held (and `--help`/`-h`, which print the usage), 1 failed, 3
//!   unavailable, 64 bad usage.

use std::io::{BufRead as _, Read as _, Write as _};
use std::path::PathBuf;
use std::sync::Arc;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use cmux_server_core::install_key::{InstallKey, SystemRandom};
use serde_json::{Value, json};
use zeroize::Zeroizing;

use super::answer::{Credential, HttpSource};
use super::tunnel::{self, TunnelIdentity, TunnelPlan, TunnelStatus};
use tokio::signal::unix::{SignalKind, signal};

const PLATFORM_ENV: &str = "CMUX_PLATFORM_URL";
const VM_API_ENV: &str = "CMUX_VM_API_URL";
const USAGE: &str = "usage: cmux carrier tunnel --machine-id machine_… --name NAME --socket PATH [--platform URL] [--vm-api URL] [--cloud-token-file PATH] [--team team_…] (keys on stdin)";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TunnelArgs {
    pub machine_id: String,
    pub name: String,
    pub socket: PathBuf,
    pub platform: Option<String>,
    pub vm_api: Option<String>,
    pub token_file: Option<PathBuf>,
    pub team: Option<String>,
}

/// A `machine_` id: what attach takes, never a `cmm_` credential.
fn valid_machine_id(id: &str) -> bool {
    id.strip_prefix("machine_").is_some_and(|rest| {
        !rest.is_empty()
            && id.len() <= 256
            && rest.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    })
}

/// The device name the VM API accepts (`MeshDeviceEnrollment.name`).
fn valid_name(name: &str) -> bool {
    let bytes = name.as_bytes();
    !bytes.is_empty()
        && bytes.len() <= 63
        && bytes.first().is_some_and(u8::is_ascii_alphanumeric)
        && bytes.iter().all(|b| b.is_ascii_alphanumeric() || b"._ -".contains(b))
}

/// `tunnel` and its flags, each once.
pub(crate) fn parse(args: &[String]) -> Option<TunnelArgs> {
    let (verb, rest) = args.split_first()?;
    if verb != "tunnel" {
        return None;
    }
    let (mut machine, mut name, mut socket, mut platform, mut vm_api, mut token, mut team) =
        (None, None, None, None, None, None, None);
    let mut words = rest.iter();
    while let Some(flag) = words.next() {
        let value = words.next()?.clone();
        let slot = match flag.as_str() {
            "--machine-id" => &mut machine,
            "--name" => &mut name,
            "--socket" => &mut socket,
            "--platform" => &mut platform,
            "--vm-api" => &mut vm_api,
            "--cloud-token-file" => &mut token,
            "--team" => &mut team,
            _ => return None,
        };
        if slot.replace(value).is_some() {
            return None;
        }
    }
    let socket = PathBuf::from(socket?);
    if !socket.is_absolute() || !cmux_unix_socket::fits(&socket) {
        return None;
    }
    if team.as_deref().is_some_and(|t| !super::contract::valid_team(t)) {
        return None;
    }
    Some(TunnelArgs {
        machine_id: machine.filter(|m| valid_machine_id(m))?,
        name: name.filter(|n| valid_name(n))?,
        socket,
        platform,
        vm_api,
        token_file: token.map(PathBuf::from),
        team,
    })
}

/// The keys line: the WireGuard private key and the install key.
pub(crate) fn parse_keys(line: &[u8]) -> Result<(Zeroizing<[u8; 32]>, InstallKey), &'static str> {
    const BAD: &str = "stdin's first line is not {\"wg_private_key\",\"install_key\"}";
    let value: Value = serde_json::from_slice(line).map_err(|_| BAD)?;
    let wg = value.get("wg_private_key").and_then(Value::as_str).ok_or(BAD)?;
    let wg = Zeroizing::new(STANDARD.decode(wg).map_err(|_| BAD)?);
    let wg: Zeroizing<[u8; 32]> = Zeroizing::new(wg.as_slice().try_into().map_err(|_| BAD)?);
    if wg.iter().all(|b| *b == 0) {
        return Err(BAD);
    }
    let install = value.get("install_key").and_then(Value::as_str).ok_or(BAD)?;
    let install =
        InstallKey::from_pkcs8_base64url(install, &SystemRandom::new()).map_err(|_| BAD)?;
    Ok((wg, install))
}

/// The VM API of the deployment whose platform origin is `platform`.
fn vm_api_of(platform: &str) -> Option<&'static str> {
    use cmux_cloud_environment as env;
    let platform = platform.trim_end_matches('/');
    [env::PRODUCTION_DEPLOYMENT, env::STAGING_DEPLOYMENT, env::DEVELOPMENT_DEPLOYMENT]
        .into_iter()
        .find(|d| d.platform_origin == platform)
        .map(|d| d.vm_origin)
}

/// The supervisor's timing; `CMUX_CARRIER_TUNNEL_REFRESH_MS` (1 ms to 1 h)
/// shortens the refresh for tests, as `CMUX_CARRIER_SERVE_IDLE_MS` does for
/// serve.
fn timing() -> tunnel::TunnelTiming {
    let mut timing = tunnel::TunnelTiming::default();
    if let Some(ms) = std::env::var("CMUX_CARRIER_TUNNEL_REFRESH_MS")
        .ok()
        .and_then(|text| text.trim().parse::<u64>().ok())
        .filter(|ms| (1..=3_600_000).contains(ms))
    {
        timing.refresh_every = std::time::Duration::from_millis(ms);
    }
    timing
}

/// The JSON line for a status.
pub(crate) fn status_line(status: &TunnelStatus) -> Value {
    match status {
        TunnelStatus::Starting => json!({"event": "tunnel-starting"}),
        TunnelStatus::Ready { socket, tunnel_id, device_id, mesh_id, address_v4 } => json!({
            "event": "tunnel-ready",
            "socket": socket.display().to_string(),
            "tunnel_id": tunnel_id,
            "device_id": device_id,
            "mesh_id": mesh_id,
            "address_v4": address_v4,
        }),
        TunnelStatus::Retrying(why) => json!({"event": "tunnel-retrying", "detail": why}),
        TunnelStatus::Unavailable(why) => json!({"event": "tunnel-unavailable", "reason": why}),
        TunnelStatus::Failed(why) => json!({"event": "tunnel-failed", "detail": why}),
        TunnelStatus::Stopped => json!({"event": "tunnel-stopped"}),
    }
}

fn emit(line: &Value) {
    let mut out = std::io::stdout().lock();
    let _ = writeln!(out, "{line}");
    let _ = out.flush();
}

fn usage(detail: &str) -> i32 {
    emit(&json!({"event": "tunnel-failed", "detail": detail}));
    64
}

/// `cmux carrier tunnel …`: the exit code.
pub(crate) fn run(args: &[String]) -> i32 {
    // `--help` / `-h` alone: the usage on stdout, exit 0 (64 is for misuse).
    if matches!(args, [verb, flag] if verb == "tunnel" && (flag == "--help" || flag == "-h")) {
        let mut out = std::io::stdout().lock();
        let _ = writeln!(out, "{USAGE}");
        let _ = out.flush();
        return 0;
    }
    let Some(args) = parse(args) else { return usage(USAGE) };
    // Before any hub exists: a SIGCHLD ignored by whoever started us would
    // let the kernel reap the hub and free its pid while we still signal it.
    if !tunnel::reap_own_children() {
        emit(&json!({"event": "tunnel-failed", "detail": "cannot reset SIGCHLD"}));
        return 1;
    }
    let team = match super::with_team_env_value(args.team.clone()) {
        Some(team) => team,
        None => return usage("CMUX_CLOUD_TEAM is not team_ and 20 lowercase hex digits"),
    };
    let mut line = Zeroizing::new(Vec::new());
    let limit = (super::contract::MAX_STDIN_LINE + 1) as u64;
    if std::io::stdin().lock().take(limit).read_until(b'\n', &mut line).unwrap_or(0) == 0 {
        return usage("give the keys on stdin's first line");
    }
    let (wg_private, install) =
        match parse_keys(line.strip_suffix(b"\n").unwrap_or(line.as_slice())) {
            Ok(keys) => keys,
            Err(why) => return usage(why),
        };
    let platform = args
        .platform
        .clone()
        .or_else(|| std::env::var(PLATFORM_ENV).ok())
        .filter(|p| !p.trim().is_empty());
    let Some(platform) = platform else {
        return usage(&format!("name cmux-platform with --platform URL or {PLATFORM_ENV}"));
    };
    let platform = match crate::cli::secure_cloud_origin(platform.trim()) {
        Ok(origin) => origin,
        Err(why) => return usage(&why),
    };
    let vm_api = args
        .vm_api
        .clone()
        .or_else(|| std::env::var(VM_API_ENV).ok())
        .filter(|v| !v.trim().is_empty())
        .or_else(|| vm_api_of(&platform).map(str::to_owned));
    let Some(vm_api) = vm_api else {
        return usage(&format!("name the VM API with --vm-api URL or {VM_API_ENV}"));
    };
    let vm_api = match crate::cli::secure_cloud_origin(vm_api.trim()) {
        Ok(origin) => origin,
        Err(why) => return usage(&why),
    };
    let credential = match (&args.token_file, std::env::var(super::TOKEN_ENV).ok()) {
        (Some(path), _) => Credential::File(path.clone()),
        (None, Some(value)) => Credential::Value(Zeroizing::new(value)),
        (None, None) => {
            return usage(&format!(
                "give the cmux credential with --cloud-token-file PATH or {}",
                super::TOKEN_ENV
            ));
        }
    };
    let source = match HttpSource::new(platform, credential, team) {
        Ok(source) => Arc::new(source),
        Err(why) => return usage(&why),
    };
    let exe = match std::env::current_exe() {
        Ok(exe) => exe,
        Err(_) => return usage("this cmux binary's path is unknown"),
    };
    let launcher = match tunnel::ProcessHubLauncher::new(exe) {
        Ok(launcher) => Arc::new(launcher),
        Err(why) => return usage(&why),
    };
    let install = Arc::new(install);
    let (machine_id, name) = (args.machine_id.clone(), args.name.clone());
    let identity: tunnel::IdentitySource = Arc::new(move || {
        Ok(TunnelIdentity {
            machine_id: machine_id.clone(),
            name: name.clone(),
            wg_private: wg_private.clone(),
            install: Arc::clone(&install),
        })
    });
    let plan = TunnelPlan {
        identity,
        platform: source,
        vm_api,
        socket: args.socket,
        launcher,
        timing: timing(),
        jitter: super::jitter,
    };
    let runtime = match tokio::runtime::Builder::new_multi_thread().enable_all().build() {
        Ok(runtime) => runtime,
        Err(_) => return usage("no async runtime"),
    };
    runtime.block_on(async move {
        // Tokio's own signal streams, in place before anything starts: the
        // carrier verbs run before `main` installs its shutdown handlers, so
        // its shutdown waiter has nothing to wait on here (as `carrier serve`).
        let (Ok(mut terminate), Ok(mut interrupt)) =
            (signal(SignalKind::terminate()), signal(SignalKind::interrupt()))
        else {
            emit(&json!({"event": "tunnel-failed", "detail": "no signal handlers"}));
            return 1;
        };
        let handle = match tunnel::start(plan) {
            Ok(handle) => handle,
            Err(tunnel::StartError::Held { socket }) => {
                emit(&json!({"event": "tunnel-held", "socket": socket.display().to_string()}));
                return 0;
            }
            Err(error) => {
                emit(&json!({"event": "tunnel-failed", "detail": error.to_string()}));
                return 1;
            }
        };
        emit(&json!({"event": "tunnel-starting", "socket": handle.socket().display().to_string()}));
        let mut status = handle.status();
        let last = loop {
            tokio::select! {
                changed = status.changed() => {
                    let now = status.borrow_and_update().clone();
                    if changed.is_err() || now.is_final() {
                        break handle.finished().await;
                    }
                    emit(&status_line(&now));
                }
                _ = terminate.recv() => break handle.stop().await,
                _ = interrupt.recv() => break handle.stop().await,
            }
        };
        emit(&status_line(&last));
        match last {
            TunnelStatus::Failed(_) => 1,
            TunnelStatus::Unavailable(_) => 3,
            _ => 0,
        }
    })
}
