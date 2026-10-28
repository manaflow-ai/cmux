//! `cmux link`: the per-user process that owns this machine's overlay
//! endpoint (plans/cmux-next/transport.md 3 and 12a). Slice 1: direct paths
//! to paired peers only, no relay.

mod access_cli;
mod agent_cli;
mod cloud;
mod cloud_fs;
mod control;
mod dial;
mod dial_cli;
mod enrollment;
mod ensure;
mod sync_cli;
// Wired into `serve` when Cloud hosts run the link (needs the TeamDO peer
// map and a token format); tested now.
#[cfg_attr(not(test), allow(dead_code))]
mod host_inbound;
mod inbound;
// Tests build it everywhere so the plist checks run on Linux CI too.
#[cfg(any(target_os = "macos", test))]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod launchd;
mod lines;
pub(crate) mod machine_gate;
pub(crate) mod machine_update;
mod mesh;
mod mesh_cloud;
mod paired_streams;
mod process_exit;
mod state;

#[cfg(test)]
mod e2e_tests;
#[cfg(test)]
mod outgoing_revocation_tests;
#[cfg(test)]
mod revocation_tests;
#[cfg(test)]
mod tests;

use std::collections::HashMap;
use std::net::{IpAddr, Ipv6Addr, SocketAddr};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{Context as _, anyhow, bail};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use cmux_link::LINK_PORT;
use cmux_link::overlay_addr::overlay_address;
use cmux_link::owner_session::OwnerSession;
use cmux_link::pairing::{PairingRecord, Pairings};
use cmux_link::registration::{self, Registration};
use cmux_wg::{InterfaceAddress, WgMesh, WgMeshConfig};
use serde_json::json;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

use self::control::{Peers, serve_local, serve_overlay};
use self::dial::Overlay as _;
use self::mesh::MeshOverlay;
use self::state::{LINK_MTU, LinkConfig, LinkState};
use crate::localization::catalog;

/// The data behind `mutex`, also after a panic in another holder. The link's
/// maps (peers, Cloud records, gateways) are consistent after every single
/// step, so a poisoned lock is safe to keep using; the link never panics on it.
fn locked<T>(mutex: &std::sync::Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// Start the session daemon's remote entry next to `session_socket` when
/// `enabled` (`--link-entry`): only the link may connect, and its gate
/// ([`link_entry_gate`]) admits only the seven `fs-v1` ops. On a Cloud host
/// this also installs the daemon's file owner (`cloud_fs`); elsewhere the
/// admitted fs ops answer `fs.unavailable`. Every host also learns how it
/// guards chats moved in (`agent-transfer-v1`).
pub(crate) fn start_link_entry(
    enabled: bool,
    mux: &Arc<cmux_tui_core::Mux>,
    session_socket: &Path,
) -> anyhow::Result<Option<cmux_tui_core::server::RemoteEntryServer>> {
    use cmux_tui_core::server::{LinkVerifier, serve_remote_entry};
    cloud_fs::install_if_cloud_host();
    mux.set_agent_transfer_host(cloud_fs::agent_transfer_host());
    // What a stamp's `check` means is fixed here, at daemon start, from the
    // config `main` took from the environment (G4); a real verifier is
    // refused until G1 and G2 hold. The mode is logged once (G3).
    let choice = cmux_link::token::daemon_verifier_choice();
    let checks = cmux_link::token::StampChecks::at_daemon_start(choice.config);
    eprintln!("{}", cmux_link::token::mode_log_line(choice, &checks));
    if !enabled {
        return Ok(None);
    }
    let checks = checks?;
    let verifier: LinkVerifier = Arc::new(|stream: &std::os::unix::net::UnixStream| {
        cmux_link::caller::verify(stream).map_err(std::io::Error::from)
    });
    let path = cmux_link::entry_path::remote_entry_socket_path(session_socket);
    Ok(Some(serve_remote_entry(mux.clone(), &path, verifier, link_entry_gate(), checks)?))
}

/// The gate of the remote entry: exactly the seven `fs-v1` ops, every
/// other frame denied (`remote_denied`).
fn link_entry_gate() -> Arc<dyn cmux_tui_core::server::RemoteGate> {
    Arc::new(cmux_tui_core::server::FsGate)
}

/// `cmux link ...` from `main`: the exit code, with any error on stderr.
pub(crate) fn run(args: &[String]) -> i32 {
    // `dial` has its own exit codes and always one JSON line on stderr.
    if args.first().map(String::as_str) == Some("dial") {
        return dial_cli::run(&args[1..]);
    }
    // `sync` answers one JSON line on stdout and has its own exit codes too.
    if args.first().map(String::as_str) == Some("sync") {
        return sync_cli::run(&args[1..]);
    }
    // So do `agent` and `access`.
    if args.first().map(String::as_str) == Some("agent") {
        return agent_cli::run(&args[1..]);
    }
    if args.first().map(String::as_str) == Some("access") {
        return access_cli::run(&args[1..]);
    }
    if args.first().map(String::as_str) == Some("machine") {
        return machine_update::run(&args[1..]);
    }
    // Asked-for help is a success on stdout, like every other scope.
    if matches!(args.first().map(String::as_str), Some("-h" | "--help" | "help")) {
        print!("{}", help_text());
        return 0;
    }
    match run_link(args) {
        Ok(()) => 0,
        Err(error) => {
            eprintln!("{error}");
            1
        }
    }
}

fn help_text() -> String {
    format!("{}\n{}", catalog().remote_client.link_help, enrollment::help())
}

/// The link's runtime: it carries remote sessions the person waits on.
fn tokio_runtime() -> anyhow::Result<tokio::runtime::Runtime> {
    Ok(cmux_threads::tokio::builder(
        "cmux-link",
        cmux_threads::ThreadQos::UserInitiated,
        cmux_threads::tokio::Flavor::MultiThread,
    )
    .build()?)
}

/// `cmux link <action> ...`.
fn run_link(args: &[String]) -> anyhow::Result<()> {
    let help = || anyhow!(help_text());
    let Some(action) = args.first().map(String::as_str) else { return Err(help()) };
    let rest = &args[1..];
    match action {
        "init" => {
            run_init(&flags(rest, &["--state-dir", "--install", "--port", "--server-identity"])?)
        }
        "show" => run_show(&flags(rest, &["--state-dir"])?),
        "peer" => run_peer(rest),
        "serve" => run_serve(&flags(
            rest,
            &["--state-dir", "--session-socket", "--server-config", "--ready-fd"],
        )?),
        "ensure" => {
            // `--handoff` is the one flag without a value.
            let handoff = rest.iter().any(|arg| arg == "--handoff");
            let rest: Vec<String> =
                rest.iter().filter(|arg| *arg != "--handoff").cloned().collect();
            ensure::run_ensure(
                &flags(
                    &rest,
                    &["--state-dir", "--install", "--port", "--session-socket", "--server-config"],
                )?,
                handoff,
            )
        }
        "stop" => ensure::run_stop(&flags(rest, &["--state-dir"])?),
        "archive" => ensure::run_archive(&flags(rest, &["--state-dir"])?),
        "status" => ensure::run_status(&flags(rest, &["--state-dir"])?),
        #[cfg(target_os = "macos")]
        "install-agent" => run_install_agent(&flags(rest, &["--state-dir", "--session-socket"])?),
        #[cfg(target_os = "macos")]
        "uninstall-agent" => {
            flags(rest, &[])?;
            launchd::uninstall()?;
            print_json(&json!({"ok": true}));
            Ok(())
        }
        "-h" | "--help" | "help" => Err(help()),
        other => Err(anyhow!(catalog().remote_client.unknown_action("link", other))),
    }
}

type Flags = HashMap<&'static str, String>;

/// `--name value` pairs, each named in `allowed`, each at most once.
fn flags(args: &[String], allowed: &[&'static str]) -> anyhow::Result<Flags> {
    let mut values = Flags::new();
    let mut index = 0;
    while index < args.len() {
        let argument = args[index].as_str();
        let Some(name) = allowed.iter().copied().find(|name| *name == argument) else {
            return Err(anyhow!(catalog().remote_client.unknown_option(argument)));
        };
        let value = args
            .get(index + 1)
            .ok_or_else(|| anyhow!(catalog().remote_client.option_needs_value(name)))?;
        if values.insert(name, value.clone()).is_some() {
            return Err(anyhow!(catalog().remote_client.option_once(name)));
        }
        index += 2;
    }
    Ok(values)
}

fn required<'a>(flags: &'a Flags, name: &str) -> anyhow::Result<&'a str> {
    flags
        .get(name)
        .map(String::as_str)
        .ok_or_else(|| anyhow!(catalog().remote_client.option_needs_value(name)))
}

fn state(flags: &Flags) -> anyhow::Result<LinkState> {
    Ok(LinkState::open(flags.get("--state-dir").map(PathBuf::from))?)
}

fn print_json(value: &serde_json::Value) {
    println!("{value}");
}

fn run_init(flags: &Flags) -> anyhow::Result<()> {
    let port = match flags.get("--port") {
        Some(port) => port
            .parse()
            .map_err(|_| anyhow!(catalog().remote_client.invalid_option_value("--port", "PORT")))?,
        None => state::DEFAULT_PORT,
    };
    // Resolve an enrollment before opening (and creating) link state. It never
    // creates or changes a server identity, and never copies its private key.
    let (install, server_identity) = match flags.get("--server-identity") {
        Some(path) => {
            let path = PathBuf::from(path);
            let identity = cmux_server::pairing::EnrolledIdentity::load(&path)?;
            let install = identity.paired().install.clone();
            if flags.get("--install").is_some_and(|wanted| wanted != &install) {
                bail!("server_link.identity_conflict");
            }
            (install, Some(cmux_blocking::fs::canonicalize(path)?))
        }
        None => (required(flags, "--install")?.to_string(), None),
    };
    let state = state(flags)?;
    let _ensure_lock = server_identity.as_ref().map(|_| ensure::ensure_lock(&state)).transpose()?;
    // `serve` holds this lock for its lifetime: init cannot rewrite its config.
    let _lock = server_identity.as_ref().map(|_| serve_lock(&state)).transpose()?;
    state.init(&LinkConfig { install, port, server_identity })?;
    run_show_state(&state)
}

fn run_show(flags: &Flags) -> anyhow::Result<()> {
    run_show_state(&state(flags)?)
}

fn run_show_state(state: &LinkState) -> anyhow::Result<()> {
    print_json(&show_json(state)?);
    Ok(())
}

/// `cmux link show`: the install, key and state, the live link's socket,
/// and the pairing file the app watches for peer changes (`peers_file`).
fn show_json(state: &LinkState) -> anyhow::Result<serde_json::Value> {
    let config = state.config()?;
    let public_key = state::public_key(&*state.private_key()?);
    let live = ensure::live(state);
    if config.server_identity.is_some()
        && let Some(live) = &live
        && !ensure::query_status(&live.socket)
            .map(|status| ensure::matches_enrollment(state, &status))
            .transpose()?
            .unwrap_or(false)
    {
        bail!("server_link.identity_mismatch");
    }
    Ok(json!({
        "install": config.install,
        "public_key": STANDARD.encode(public_key),
        "overlay_address": overlay_address(&config.install).to_string(),
        "port": config.port,
        "running": live.is_some(),
        "socket": live.map(|registration| registration.socket),
        "peers_file": state.peers_path(),
        "identity_source": if config.server_identity.is_some() { "server_pairing" } else { "local" },
    }))
}

fn run_peer(args: &[String]) -> anyhow::Result<()> {
    let Some(action) = args.first().map(String::as_str) else {
        return Err(anyhow!(help_text()));
    };
    let rest = &args[1..];
    match action {
        "add" => {
            let flags = flags(
                rest,
                &["--state-dir", "--install", "--user", "--team", "--public-key", "--endpoint"],
            )?;
            let endpoint = match flags.get("--endpoint") {
                Some(text) => Some(text.parse::<SocketAddr>().map_err(|_| {
                    anyhow!(catalog().remote_client.invalid_option_value("--endpoint", "IP:PORT"))
                })?),
                None => None,
            };
            let record = PairingRecord {
                install: required(&flags, "--install")?.to_string(),
                user: required(&flags, "--user")?.to_string(),
                team: required(&flags, "--team")?.to_string(),
                public_key: required(&flags, "--public-key")?.to_string(),
                endpoint,
            };
            change_peers(&flags, |pairings| pairings.upsert(record).map(|()| true))
        }
        "remove" => {
            let flags = flags(rest, &["--state-dir", "--install"])?;
            let install = required(&flags, "--install")?.to_string();
            change_peers(&flags, |pairings| Ok(pairings.remove(&install)))
        }
        "list" => {
            let flags = flags(rest, &["--state-dir"])?;
            let state = state(&flags)?;
            print_json(&serde_json::to_value(Pairings::load(&state.peers_path())?)?);
            Ok(())
        }
        other => Err(anyhow!(catalog().remote_client.unknown_action("link peer", other))),
    }
}

/// Apply `change` to the pairing file, then ask a running link to reload.
fn change_peers(
    flags: &Flags,
    change: impl FnOnce(&mut Pairings) -> std::io::Result<bool>,
) -> anyhow::Result<()> {
    let state = state(flags)?;
    let mut pairings = Pairings::load(&state.peers_path())?;
    let changed = change(&mut pairings)?;
    pairings.save(&state.peers_path())?;
    let reloaded = match ensure::live(&state) {
        Some(live) => cmux_threads::tokio::block_on(&tokio_runtime()?, reload(&live.socket)),
        None => false,
    };
    print_json(&json!({"ok": true, "changed": changed, "reloaded": reloaded}));
    Ok(())
}

async fn reload(socket: &Path) -> bool {
    let Ok(mut stream) = tokio::net::UnixStream::connect(socket).await else { return false };
    if stream.write_all(b"{\"op\":\"link.reload\"}\n").await.is_err() {
        return false;
    }
    let mut reply = String::new();
    let _ = BufReader::new(stream).read_line(&mut reply).await;
    reply.trim() == "{\"ok\":true}"
}

fn run_serve(flags: &Flags) -> anyhow::Result<()> {
    let state = state(flags)?;
    #[cfg(target_os = "macos")]
    if let Some(note) = launchd::upgrade_installed_role() {
        eprintln!("cmux link: {note}");
    }
    let session_socket = flags.get("--session-socket").map(PathBuf::from);
    // `server.json` is read once: the owner session is parsed from, and
    // `link.status` hashes, the same bytes.
    let config_path = server_config_path(flags);
    let config_bytes = read_server_config(config_path.as_deref())?;
    let owner = owner_session(config_path.as_deref(), config_bytes.as_deref())?;
    let ready = match flags.get("--ready-fd") {
        Some(fd) => Some(ensure::ReadyPipe::take(fd)?),
        None => None,
    };
    // One link per state directory, for its whole life, taken before the
    // UDP bind: a second `serve` of the same state directory stops here.
    let _lock = serve_lock(&state)?;
    let served = ensure::Served::of(flags, config_path, config_bytes.as_deref());
    cmux_threads::tokio::block_on(
        &tokio_runtime()?,
        serve(state, session_socket, owner, ready, served),
    )
}

/// `<state>/link.lock`, held by a running `serve` (never blocks).
fn serve_lock(state: &LinkState) -> anyhow::Result<std::fs::File> {
    let path = state.dir().join("link.lock");
    let file = state::open_lock(&path)?;
    // SAFETY: flock on a descriptor this process owns.
    if unsafe { libc::flock(std::os::fd::AsRawFd::as_raw_fd(&file), libc::LOCK_EX | libc::LOCK_NB) }
        != 0
    {
        let error = std::io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::EWOULDBLOCK) {
            return Err(anyhow!("a cmux link already runs for {}", state.dir().display()));
        }
        return Err(error).context("lock the link state directory");
    }
    Ok(file)
}

/// The `server.json` a link reads its owner session from: `--server-config
/// PATH`, else the user-mode `~/.config/cmux/server.json`; none without HOME.
pub(super) fn server_config_path(flags: &Flags) -> Option<PathBuf> {
    match flags.get("--server-config") {
        Some(path) => Some(PathBuf::from(path)),
        // Shortcut: duplicates the user-mode layout of cmux-server-core; use
        // its layout code when the next Cargo WINDOW allows the dependency
        // (bead cx-uu3).
        None => std::env::var_os("HOME")
            .map(|home| PathBuf::from(home).join(".config/cmux/server.json")),
    }
}

/// The bytes of `server.json` at `path`; none when there is no path or no file.
pub(super) fn read_server_config(path: Option<&Path>) -> anyhow::Result<Option<Vec<u8>>> {
    let Some(path) = path else { return Ok(None) };
    match cmux_blocking::fs::read(path) {
        Ok(bytes) => Ok(Some(bytes)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error).with_context(|| format!("read {}", path.display())),
    }
}

/// The owner session block of `server.json` (`--server-config PATH`, else
/// the user-mode `~/.config/cmux/server.json`) from its `bytes`; none when
/// absent. An invalid block stops the link instead of serving with a guess.
fn owner_session(
    path: Option<&Path>,
    bytes: Option<&[u8]>,
) -> anyhow::Result<Option<Arc<OwnerSession>>> {
    let Some(bytes) = bytes else { return Ok(None) };
    let where_ = || {
        format!(
            "read owner_session in {}",
            path.map(Path::display).map(|p| p.to_string()).unwrap_or_default()
        )
    };
    let text = std::str::from_utf8(bytes).with_context(where_)?;
    let owner = OwnerSession::parse(text).with_context(where_)?;
    Ok(owner.map(Arc::new))
}

async fn serve(
    state: LinkState,
    session_socket: Option<PathBuf>,
    owner: Option<Arc<OwnerSession>>,
    ready: Option<ensure::ReadyPipe>,
    served: ensure::Served,
) -> anyhow::Result<()> {
    let (state, config, private_key) = crate::blocking::off_worker(move || {
        let config = state.config().context("run `cmux link init --install ID` first")?;
        let private_key = state.private_key()?;
        anyhow::Ok((state, config, private_key))
    })
    .await?;
    let public_key = state::public_key(&private_key);
    let socket =
        tokio::net::UdpSocket::bind(SocketAddr::from((Ipv6Addr::UNSPECIFIED, config.port)))
            .await
            .with_context(|| format!("bind UDP port {}", config.port))?;
    let own = overlay_address(&config.install);
    let mesh = WgMesh::start(
        WgMeshConfig {
            private_key: private_key.clone(),
            addresses: vec![InterfaceAddress { address: IpAddr::V6(own), prefix: 128 }],
            mtu: LINK_MTU,
        },
        socket,
    )?;
    let overlay = Arc::new(MeshOverlay::new(mesh, private_key));
    // Cloud host ids resolve through the host credential relay, which is
    // not served yet: Cloud dials report `unreachable` until it ships.
    let resolver = Arc::new(cloud::CloudResolver::new(cloud::RelaySource));
    let peers_path = state.peers_path();
    let peers = Arc::new(crate::blocking::off_worker(move || Peers::load(peers_path)).await?);
    overlay.sync_peers(&peers.snapshot()).await?;
    let listener = overlay.listen(LINK_PORT).await?;
    let socket_path = state.socket_path();
    let local = {
        let socket_path = socket_path.clone();
        crate::blocking::off_worker(move || bind_local(&socket_path)).await?
    };
    let pid = std::process::id();
    let udp = overlay.local_addr()?.to_string();
    let status: Arc<str> =
        ensure::status_line(&state, &config, &socket_path, pid, &udp, &served, &public_key)
            .to_string()
            .into();
    let registration_dir = state.registration_dir();
    let registration = Registration::new(socket_path.clone(), pid);
    crate::blocking::off_worker(move || registration::write(&registration_dir, &registration))
        .await?;
    let ready_line = json!({
        "event": "link-ready",
        "socket": socket_path,
        "pid": pid,
        "overlay_address": own.to_string(),
        "udp": udp,
        "relay_available": cmux_link::dial::RELAY_AVAILABLE,
    });
    print_json(&ready_line);
    if let Some(ready) = ready {
        ready.send(&ready_line);
    }
    let result = tokio::select! {
        served = serve_local(local, overlay.clone(), peers.clone(), resolver, status) => served.map_err(anyhow::Error::from),
        () = serve_overlay(listener, peers.clone(), session_socket, owner) => Ok(()),
        signal = shutdown_signal() => signal,
    };
    let registration_dir = state.registration_dir();
    let _ = crate::blocking::off_worker(move || {
        registration::remove_if_owned(&registration_dir, pid);
        cmux_blocking::fs::remove_file(&socket_path)
    })
    .await;
    result
}

/// Bind the local socket at mode 0600 in a 0700 directory, replacing a
/// stale socket but never a live one.
fn bind_local(path: &Path) -> anyhow::Result<tokio::net::UnixListener> {
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    if let Some(parent) = path.parent() {
        crate::blocking::fs::create_dir_with(
            std::fs::DirBuilder::new().recursive(true).mode(0o700),
            parent,
        )?;
        // Never bind in a folder another user or a symlink put there.
        state::check_socket_dir(parent)?;
    }
    if cmux_blocking::fs::metadata(path).is_ok() {
        if std::os::unix::net::UnixStream::connect(path).is_ok() {
            return Err(anyhow!("a cmux link already listens on {}", path.display()));
        }
        cmux_blocking::fs::remove_file(path)?;
    }
    cmux_unix_socket::check_path(path)?;
    let listener = tokio::net::UnixListener::bind(path)?;
    crate::blocking::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    Ok(listener)
}

async fn shutdown_signal() -> anyhow::Result<()> {
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    tokio::select! {
        _ = terminate.recv() => Ok(()),
        interrupted = tokio::signal::ctrl_c() => interrupted.map_err(anyhow::Error::from),
    }
}

#[cfg(target_os = "macos")]
fn run_install_agent(flags: &Flags) -> anyhow::Result<()> {
    let state = state(flags)?;
    state.config().context("run `cmux link init --install ID` first")?;
    let mut arguments = vec![
        "link".to_string(),
        "serve".to_string(),
        "--state-dir".to_string(),
        state.dir().to_string_lossy().into_owned(),
    ];
    if let Some(session) = flags.get("--session-socket") {
        arguments.extend(["--session-socket".to_string(), session.clone()]);
    }
    let program = std::env::current_exe()?;
    let path = launchd::install(&program, &arguments)?;
    print_json(&json!({"ok": true, "plist": path, "label": launchd::LABEL}));
    Ok(())
}
