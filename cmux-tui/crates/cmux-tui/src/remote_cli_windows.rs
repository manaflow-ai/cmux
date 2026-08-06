//! Native Windows remote command entrypoints.

use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{Context, anyhow};
use cmux_remote::daemon::{InboundLink, RemoteDaemon};
use cmux_remote::identity::{AuthDatabase, default_state_dir};
use cmux_remote::provider::LengthDelimitedLink;
use cmux_remote::services::DaemonServices;
use cmux_remote::session::SessionLimits;
use cmux_remote::ssh_bootstrap::BUILD_IDENTITY;
use cmux_remote::workspace::WorkspaceService;
use cmux_remote_protocol::REMOTE_PROTOCOL_VERSION;
use cmux_tui_core::{Mux, SurfaceOptions};

const MAX_CARRIER_FRAME_BYTES: usize = 65_535;
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

pub fn is_remote_invocation(args: &[String]) -> bool {
    args.first().is_some_and(|argument| REMOTE_COMMANDS.contains(&argument.as_str()))
}

pub fn run(args: &[String], _: &str) -> i32 {
    match run_inner(args) {
        Ok(()) => 0,
        Err(error) => {
            eprintln!("cmux-tui: {error:#}");
            1
        }
    }
}

fn run_inner(args: &[String]) -> anyhow::Result<()> {
    match args.first().map(String::as_str) {
        Some("remote-probe") => run_probe(&args[1..]),
        Some("remote-link") => run_remote_link(&args[1..]),
        Some(command) => Err(anyhow!("{command} is not implemented on Windows yet")),
        None => Err(anyhow!("missing remote command")),
    }
}

fn run_probe(args: &[String]) -> anyhow::Result<()> {
    if args.iter().any(|argument| !matches!(argument.as_str(), "--json" | "-h" | "--help")) {
        return Err(anyhow!("remote-probe accepts only --json"));
    }
    let value = serde_json::json!({
        "app": "cmux-tui",
        "version": env!("CARGO_PKG_VERSION"),
        "distribution_version": option_env!("CMUX_TUI_DISTRIBUTION_VERSION")
            .unwrap_or(env!("CARGO_PKG_VERSION")),
        "npm_bootstrap_version": option_env!("CMUX_TUI_NPM_BOOTSTRAP_VERSION"),
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

struct RemoteLinkOptions {
    session: String,
    state_root: Option<PathBuf>,
}

fn parse_remote_link(args: &[String]) -> anyhow::Result<RemoteLinkOptions> {
    let mut session = "main".to_string();
    let mut state_root = None;
    let mut stdio = false;
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--stdio" => {
                if stdio {
                    return Err(anyhow!("remote-link received --stdio more than once"));
                }
                stdio = true;
                index += 1;
            }
            "--session" | "--state-dir" => {
                let option = args[index].as_str();
                let value = args
                    .get(index + 1)
                    .ok_or_else(|| anyhow!("remote-link {option} needs a value"))?;
                if option == "--session" {
                    session = value.clone();
                } else {
                    state_root = Some(PathBuf::from(value));
                }
                index += 2;
            }
            option => return Err(anyhow!("unknown remote-link option {option:?}")),
        }
    }
    if !stdio {
        return Err(anyhow!("remote-link currently requires --stdio"));
    }
    if session.is_empty()
        || !session.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"_.-".contains(&byte))
    {
        return Err(anyhow!("remote-link session is not path-safe"));
    }
    Ok(RemoteLinkOptions { session, state_root })
}

fn run_remote_link(args: &[String]) -> anyhow::Result<()> {
    let options = parse_remote_link(args)?;
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .thread_name("cmux-remote-windows")
        .enable_all()
        .build()
        .context("could not start the Windows remote runtime")?
        .block_on(serve_remote_link(options))
}

async fn serve_remote_link(options: RemoteLinkOptions) -> anyhow::Result<()> {
    let root = options.state_root.or_else(default_state_dir).ok_or_else(|| {
        anyhow!("cannot determine Windows remote state directory; LOCALAPPDATA is unset")
    })?;
    let state_dir = root.join("sessions").join(&options.session);
    let auth = AuthDatabase::load_or_create(&state_dir, windows_daemon_name(), true)
        .context("could not open Windows remote identity")?;

    let mut surface_options = SurfaceOptions::default();
    let workspace_state = state_dir.join("workspaces");
    surface_options.terminal_host_root = Some(state_dir.join("terminal-host"));
    let mux = Mux::open_persistent(options.session.clone(), surface_options, &workspace_state)
        .context("could not open Windows mux")?;
    let mux_socket = state_dir.join("mux.sock");
    cmux_tui_core::server::serve(mux.clone(), Some(mux_socket.clone()))
        .context("could not start Windows mux control socket")?;
    let mux_owner = MuxOwner { mux, socket: mux_socket.clone() };

    let (daemon, mut accepted) = RemoteDaemon::new(auth, SessionLimits::default());
    let link = LengthDelimitedLink::new(
        "ssh-stdio",
        MAX_CARRIER_FRAME_BYTES,
        tokio::io::stdin(),
        tokio::io::stdout(),
    );
    let inbound = InboundLink::ssh_stdio(Box::new(link), windows_ssh_principal())
        .ok_or_else(|| anyhow!("cannot determine the authenticated Windows SSH principal"))?;
    daemon.accept(inbound).await.context("Windows SSH carrier was rejected")?;
    let client = accepted
        .recv()
        .await
        .ok_or_else(|| anyhow!("Windows remote connection closed before service startup"))?;
    let services = DaemonServices::new(WorkspaceService::new(), Some(mux_socket));
    let local = tokio::task::LocalSet::new();
    let result = local.run_until(services.serve_client(client)).await;
    drop(mux_owner);
    result.context("Windows remote services stopped")
}

struct MuxOwner {
    mux: Arc<Mux>,
    socket: PathBuf,
}

impl Drop for MuxOwner {
    fn drop(&mut self) {
        self.mux.shutdown();
        cmux_tui_core::server::cleanup(&self.socket);
    }
}

fn windows_ssh_principal() -> String {
    let user = std::env::var("USERNAME").unwrap_or_else(|_| "windows-user".into());
    let machine = std::env::var("COMPUTERNAME").unwrap_or_else(|_| "windows-host".into());
    format!("{user}@{machine}")
}

fn windows_daemon_name() -> String {
    std::env::var("COMPUTERNAME").unwrap_or_else(|_| "Windows".into())
}
