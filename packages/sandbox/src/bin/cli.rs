use chrono::SecondsFormat;
use clap::{Args, Parser, Subcommand, ValueEnum};
use cmux_sandbox::models::{
    CreateSandboxRequest, EnvVar, ExecRequest, ExecResponse, NotificationLogEntry, SandboxSummary,
};
use cmux_sandbox::{
    build_default_env_vars, extract_api_key_from_output, store_claude_token,
    sync_files::{upload_sync_files, SYNC_FILES},
    AcpProvider, DEFAULT_HTTP_PORT, DMUX_DEFAULT_CONTAINER, DMUX_DEFAULT_HTTP_PORT,
    DMUX_DEFAULT_IMAGE,
};
use crossterm::terminal::{disable_raw_mode, enable_raw_mode};
use futures::{SinkExt, StreamExt};
use ignore::WalkBuilder;
use reqwest::Client;
use serde::Serialize;
use std::io::IsTerminal;
use std::path::{Path, PathBuf};
use std::process::Command as ProcessCommand;
use std::sync::Arc;
use std::time::Duration;
use tar::Builder;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::sync::oneshot;
use tokio_tungstenite::{connect_async, tungstenite::protocol::Message};
use uuid::Uuid;

#[cfg(unix)]
use tokio::signal::unix::{signal, SignalKind};

// Proxy imports
use rcgen::{BasicConstraints, CertificateParams, DnType, IsCa, SanType};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use rustls::ServerConfig;
use tokio_rustls::TlsAcceptor;

#[derive(Parser, Debug)]
#[command(name = "cmux", version, about = "cmux sandbox controller")]
struct Cli {
    /// Base URL for the sandbox daemon (http or https)
    #[arg(long, env = "CMUX_SANDBOX_URL", default_value_t = default_base_url())]
    base_url: String,

    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand, Debug)]
enum Command {
    #[command(subcommand, alias = "s", alias = "sandbox")]
    Sandboxes(SandboxCommand),
    /// Create a new sandbox and attach to it immediately
    New(NewArgs),
    /// Fetch the OpenAPI document from the server
    Openapi,

    /// List known sandboxes (alias for 'sandboxes list')
    Ls,

    /// Attach to a shell in the sandbox (SSH-like)
    #[command(alias = "a")]
    Attach {
        /// Sandbox ID or index (optional, defaults to last connected)
        id: Option<String>,
    },

    /// Execute a command inside a sandbox
    Exec(ExecArgs),

    /// Start a proxy server for the sandbox
    #[command(alias = "p")]
    Proxy {
        /// Sandbox ID or index
        id: String,
        /// Port to listen on (0 for random)
        #[arg(long, default_value_t = 0)]
        port: u16,
    },

    /// Open a browser connected to the sandbox
    #[command(alias = "b")]
    Browser {
        /// Sandbox ID or index
        id: String,
    },

    /// Internal helper to proxy stdin/stdout to a TCP address
    #[command(name = "_internal-proxy", hide = true)]
    InternalProxy { address: String },

    /// Start the sandbox server container
    Start(StartArgs),
    /// Stop the sandbox server container
    Stop,
    /// Restart the sandbox server container
    Restart(StartArgs),
    /// Show status of the sandbox server
    Status,
    /// List recorded notifications
    #[command(alias = "notifs")]
    Notifications(NotificationsArgs),

    /// Start interactive ACP chat client
    Chat(ChatArgs),

    /// Manage authentication files
    Auth(AuthArgs),

    /// Setup Claude API token by running `claude setup-token` and storing in keyring
    SetupClaude,
}

#[derive(Args, Debug)]
struct NotificationsArgs {
    /// Output notifications as JSON
    #[arg(long)]
    json: bool,
}

#[derive(Args, Debug)]
struct ChatArgs {
    /// Run in demo mode with fake conversation data for visual testing
    #[arg(long)]
    demo: bool,

    /// ACP provider to use (codex, opencode, claude, gemini). Defaults to last used provider.
    #[arg(long, short = 'a', value_enum)]
    acp: Option<AcpProvider>,
}

#[derive(Args, Debug)]
struct AuthArgs {
    #[command(subcommand)]
    command: AuthCommand,
}

#[derive(Subcommand, Debug)]
enum AuthCommand {
    /// List detected authentication files on the host
    Status,
}

const ENV_CMUX_NO_ATTACH: &str = "CMUX_NO_ATTACH";
const ENV_CMUX_FORCE_ATTACH: &str = "CMUX_FORCE_ATTACH";

#[derive(Subcommand, Debug)]
enum SandboxCommand {
    /// List known sandboxes
    #[command(alias = "ls")]
    List,
    /// Create a new sandbox
    Create(CreateArgs),
    /// Create a new sandbox and attach to it immediately
    New(NewArgs),
    /// Inspect a sandbox
    Show { id: String },
    /// Execute a command inside a sandbox
    Exec(ExecArgs),
    /// Attach to a shell in the sandbox (SSH-like)
    Ssh { id: String },
    /// Tear down a sandbox
    Delete { id: String },
}

#[derive(Copy, Clone, Debug, ValueEnum)]
enum DockerMode {
    Dind,
    Dood,
}

impl DockerMode {
    fn as_str(&self) -> &'static str {
        match self {
            DockerMode::Dind => "dind",
            DockerMode::Dood => "dood",
        }
    }
}

#[derive(Args, Debug, Clone)]
struct StartArgs {
    /// Docker mode to run inside the sandbox container (dind or dood)
    #[arg(long, value_enum, env = "CMUX_DOCKER_MODE")]
    docker: Option<DockerMode>,
    /// Path to the Docker socket (used for dood mode)
    #[arg(long, env = "CMUX_DOCKER_SOCKET")]
    docker_socket: Option<String>,
}

#[derive(Args, Debug)]
struct CreateArgs {
    #[arg(long)]
    name: Option<String>,
    /// Optional positional name for convenience: `cmux sandboxes create myname`
    #[arg(value_name = "NAME")]
    positional_name: Option<String>,
    #[arg(long)]
    workspace: Option<PathBuf>,
    #[arg(long, value_parser = parse_env)]
    env: Vec<EnvVar>,
    #[arg(long = "read-only", value_name = "PATH")]
    read_only_paths: Vec<PathBuf>,
    #[arg(long, value_name = "PATH")]
    tmpfs: Vec<String>,
}

#[derive(Args, Debug)]
struct ExecArgs {
    id: String,
    #[arg(trailing_var_arg = true, required = true)]
    command: Vec<String>,
    #[arg(long)]
    workdir: Option<String>,
    #[arg(short = 'e', long = "env", value_parser = parse_env)]
    env: Vec<EnvVar>,
}

#[derive(Args, Debug)]
struct NewArgs {
    /// Path to the project directory to upload (defaults to current directory)
    #[arg(default_value = ".")]
    path: PathBuf,
}

/// Check if we're running as "dmux" (debug/dev binary)
fn is_dmux() -> bool {
    std::env::args()
        .next()
        .and_then(|arg0| {
            std::path::Path::new(&arg0)
                .file_name()
                .map(|name| name.to_string_lossy().starts_with("dmux"))
        })
        .unwrap_or(false)
}

fn default_base_url() -> String {
    let port = if is_dmux() {
        DMUX_DEFAULT_HTTP_PORT
    } else {
        DEFAULT_HTTP_PORT
    };
    format!("http://127.0.0.1:{port}")
}

fn parse_env(raw: &str) -> Result<EnvVar, String> {
    let parts: Vec<&str> = raw.splitn(2, '=').collect();
    if parts.len() != 2 {
        return Err("env should look like KEY=value".to_string());
    }

    Ok(EnvVar {
        key: parts[0].to_string(),
        value: parts[1].to_string(),
    })
}

fn get_config_dir() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
    PathBuf::from(home).join(".cmux")
}

fn get_last_sandbox() -> Option<String> {
    let path = get_config_dir().join("last_sandbox");
    if path.exists() {
        std::fs::read_to_string(path)
            .ok()
            .map(|s| s.trim().to_string())
    } else {
        None
    }
}

fn save_last_sandbox(id: &str) {
    let dir = get_config_dir();
    if !dir.exists() {
        let _ = std::fs::create_dir_all(&dir);
    }
    let path = dir.join("last_sandbox");
    let _ = std::fs::write(path, id);
}

#[tokio::main]
async fn main() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    if let Err(e) = run().await {
        eprintln!("Error: {e:?}");
        std::process::exit(1);
    }
    std::process::exit(0);
}

/// Check if the sandbox server is reachable and provide helpful error if not
async fn check_server_reachable(client: &Client, base_url: &str) -> anyhow::Result<()> {
    let url = format!("{}/sandboxes", base_url.trim_end_matches('/'));
    match client
        .get(&url)
        .timeout(Duration::from_secs(2))
        .send()
        .await
    {
        Ok(_) => Ok(()),
        Err(e) => {
            let is_connection_error = e.is_connect();
            if is_connection_error {
                eprintln!(
                    "\n\x1b[31mError: Cannot connect to sandbox server at {}\x1b[0m",
                    base_url
                );
                eprintln!("\nThe sandbox server is not running. Start it with:");
                eprintln!("\n  \x1b[36mcmux start\x1b[0m\n");
                eprintln!("Or check the server status with:");
                eprintln!("\n  \x1b[36mcmux status\x1b[0m\n");
                std::process::exit(1);
            }
            Err(e.into())
        }
    }
}

async fn run() -> anyhow::Result<()> {
    let cli = Cli::parse();
    if std::env::var("CMUX_DEBUG").is_ok() {
        eprintln!("cmux base url: {}", cli.base_url);
    }
    let client = Client::builder()
        .timeout(Duration::from_secs(300))
        .no_proxy()
        .http2_keep_alive_interval(Duration::from_secs(30))
        .build()?;

    // If no command provided, launch the multiplexer TUI
    let command = match cli.command {
        Some(cmd) => cmd,
        None => {
            check_server_reachable(&client, &cli.base_url).await?;
            // Pass current working directory so the mux can upload it to the new sandbox
            let workspace_path = std::env::current_dir().ok();
            cmux_sandbox::run_mux_tui(cli.base_url, workspace_path)
                .await
                .map_err(|e| anyhow::anyhow!(e))?;
            return Ok(());
        }
    };

    match command {
        Command::Openapi => {
            check_server_reachable(&client, &cli.base_url).await?;
            let url = format!("{}/openapi.json", cli.base_url.trim_end_matches('/'));
            let response = client.get(url).send().await?;
            let value: serde_json::Value = parse_response(response).await?;
            print_json(&value)?;
        }
        Command::New(args) => {
            check_server_reachable(&client, &cli.base_url).await?;
            let body = CreateSandboxRequest {
                name: Some("interactive".into()),
                workspace: None,
                tab_id: Some(Uuid::new_v4().to_string()),
                read_only_paths: vec![],
                tmpfs: vec![],
                env: build_default_env_vars(),
            };
            let url = format!("{}/sandboxes", cli.base_url.trim_end_matches('/'));
            let response = client.post(url).json(&body).send().await?;
            let summary: SandboxSummary = parse_response(response).await?;
            eprintln!("Created sandbox {}", summary.id);

            // Upload directory
            eprintln!("Uploading directory: {}", args.path.display());
            let body = stream_directory(args.path.clone());
            let url = format!(
                "{}/sandboxes/{}/files",
                cli.base_url.trim_end_matches('/'),
                summary.id
            );
            let response = client.post(url).body(body).send().await?;
            if !response.status().is_success() {
                eprintln!("Failed to upload files: {}", response.status());
            } else {
                eprintln!("Files uploaded.");
            }

            // Upload auth files
            if let Err(e) =
                upload_sync_files(&client, &cli.base_url, &summary.id.to_string(), true).await
            {
                eprintln!("Warning: Failed to upload auth files: {}", e);
            }

            save_last_sandbox(&summary.id.to_string());
            if should_attach() {
                handle_ssh(&cli.base_url, &summary.id.to_string()).await?;
            } else {
                eprintln!(
                    "Skipping interactive shell attach (non-interactive environment detected)."
                );
            }
        }
        Command::Ls => {
            check_server_reachable(&client, &cli.base_url).await?;
            let url = format!("{}/sandboxes", cli.base_url.trim_end_matches('/'));
            let response = client.get(url).send().await?;
            let sandboxes: Vec<SandboxSummary> = parse_response(response).await?;
            print_json(&sandboxes)?;
        }
        Command::Attach { id } => {
            let target_id = if let Some(id) = id {
                id
            } else {
                get_last_sandbox().ok_or_else(|| {
                    anyhow::anyhow!("No sandbox ID provided and no previous sandbox found")
                })?
            };
            save_last_sandbox(&target_id);
            handle_ssh(&cli.base_url, &target_id).await?;
        }
        Command::Exec(args) => {
            handle_exec_request(&client, &cli.base_url, args).await?;
        }
        Command::InternalProxy { address } => {
            let mut stream = tokio::net::TcpStream::connect(address).await?;
            let (mut ri, mut wi) = stream.split();
            let mut stdin = tokio::io::stdin();
            let mut stdout = tokio::io::stdout();

            let _ = tokio::join!(
                tokio::io::copy(&mut stdin, &mut wi),
                tokio::io::copy(&mut ri, &mut stdout)
            );
        }
        Command::Proxy { id, port } => {
            handle_proxy(cli.base_url, id, port).await?;
        }
        Command::Browser { id } => {
            handle_browser(cli.base_url, id).await?;
        }
        Command::Start(args) => {
            handle_server_start(&args).await?;
        }
        Command::Stop => {
            handle_server_stop().await?;
        }
        Command::Restart(args) => {
            handle_server_stop().await?;
            handle_server_start(&args).await?;
        }
        Command::Status => {
            handle_server_status(&cli.base_url).await?;
        }
        Command::Notifications(args) => {
            check_server_reachable(&client, &cli.base_url).await?;
            let url = format!("{}/notifications", cli.base_url.trim_end_matches('/'));
            let response = client.get(url).send().await?;
            let notifications: Vec<NotificationLogEntry> = parse_response(response).await?;
            if args.json {
                print_json(&notifications)?;
            } else {
                print_notifications(&notifications);
            }
        }
        Command::Chat(args) => {
            if args.demo {
                cmux_sandbox::run_demo_tui()
                    .await
                    .map_err(|e| anyhow::anyhow!(e))?;
            } else {
                check_server_reachable(&client, &cli.base_url).await?;
                // Use explicitly provided ACP provider, or fall back to last used, or default
                let provider = args
                    .acp
                    .or_else(cmux_sandbox::load_last_provider)
                    .unwrap_or_default();
                eprintln!("Using ACP provider: {}", provider.display_name());

                let body = CreateSandboxRequest {
                    name: Some("interactive".into()),
                    workspace: None,
                    tab_id: Some(Uuid::new_v4().to_string()),
                    read_only_paths: vec![],
                    tmpfs: vec![],
                    env: build_default_env_vars(),
                };
                let url = format!("{}/sandboxes", cli.base_url.trim_end_matches('/'));
                let response = client.post(url).json(&body).send().await?;
                let summary: SandboxSummary = parse_response(response).await?;
                eprintln!("Created sandbox {}", summary.id);
                let sandbox_id = summary.id.to_string();

                let current_dir = std::env::current_dir()?;
                let (workspace_status_tx, workspace_status_rx) =
                    tokio::sync::mpsc::unbounded_channel();

                let _ = workspace_status_tx.send(cmux_sandbox::WorkspaceSyncStatus::InProgress);

                let sync_base_url = cli.base_url.clone();
                let sync_client = client.clone();
                let sync_id = sandbox_id.clone();
                let sync_dir = current_dir.clone();
                let sync_status_tx = workspace_status_tx.clone();

                tokio::spawn(async move {
                    let workspace_result = upload_workspace_directory(
                        &sync_client,
                        &sync_base_url,
                        &sync_id,
                        sync_dir,
                    )
                    .await;

                    if let Err(e) = workspace_result {
                        let _ = sync_status_tx.send(cmux_sandbox::WorkspaceSyncStatus::Failed(
                            format!("Workspace upload failed: {e}"),
                        ));
                        return;
                    }

                    let auth_result =
                        upload_sync_files(&sync_client, &sync_base_url, &sync_id, false).await;

                    if let Err(e) = auth_result {
                        let _ = sync_status_tx.send(cmux_sandbox::WorkspaceSyncStatus::Failed(
                            format!("Auth files upload failed: {e}"),
                        ));
                        return;
                    }

                    let _ = sync_status_tx.send(cmux_sandbox::WorkspaceSyncStatus::Completed);
                });

                save_last_sandbox(&sandbox_id);
                cmux_sandbox::run_chat_tui_with_workspace_status(
                    cli.base_url,
                    sandbox_id,
                    provider,
                    Some(workspace_status_rx),
                )
                .await
                .map_err(|e| anyhow::anyhow!(e))?;
            }
        }
        Command::Auth(args) => match args.command {
            AuthCommand::Status => {
                let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
                let home_path = PathBuf::from(home);
                println!(
                    "Checking for authentication files in {}:",
                    home_path.display()
                );
                println!("{:<25} {:<50} {:<10}", "NAME", "PATH", "STATUS");
                println!("{}", "-".repeat(85));

                for def in SYNC_FILES {
                    let path = home_path.join(def.host_path);
                    let status = if path.exists() {
                        "\x1b[32mFound\x1b[0m"
                    } else {
                        "\x1b[90mMissing\x1b[0m"
                    };
                    println!("{:<25} {:<50} {}", def.name, def.host_path, status);
                }
            }
        },
        Command::SetupClaude => {
            handle_setup_claude().await?;
        }
        Command::Sandboxes(cmd) => {
            match cmd {
                SandboxCommand::List => {
                    let url = format!("{}/sandboxes", cli.base_url.trim_end_matches('/'));
                    let response = client.get(url).send().await?;
                    let sandboxes: Vec<SandboxSummary> = parse_response(response).await?;
                    print_json(&sandboxes)?;
                }
                SandboxCommand::Create(args) => {
                    let resolved_name = args.name.or(args.positional_name);
                    let body = CreateSandboxRequest {
                        name: resolved_name,
                        workspace: args.workspace.map(|p| p.to_string_lossy().to_string()),
                        tab_id: Some(Uuid::new_v4().to_string()),
                        read_only_paths: args
                            .read_only_paths
                            .iter()
                            .map(|p| p.to_string_lossy().to_string())
                            .collect(),
                        tmpfs: args.tmpfs,
                        env: args.env,
                    };

                    let url = format!("{}/sandboxes", cli.base_url.trim_end_matches('/'));
                    let response = client.post(url).json(&body).send().await?;
                    let summary: SandboxSummary = parse_response(response).await?;
                    print_json(&summary)?;

                    if let Err(error) =
                        upload_sync_files(&client, &cli.base_url, &summary.id.to_string(), true)
                            .await
                    {
                        eprintln!("Warning: Failed to upload auth files: {}", error);
                    }
                }
                SandboxCommand::New(args) => {
                    let body = CreateSandboxRequest {
                        name: Some("interactive".into()),
                        workspace: None,
                        tab_id: Some(Uuid::new_v4().to_string()),
                        read_only_paths: vec![],
                        tmpfs: vec![],
                        env: build_default_env_vars(),
                    };
                    let url = format!("{}/sandboxes", cli.base_url.trim_end_matches('/'));
                    let response = client.post(url).json(&body).send().await?;
                    let summary: SandboxSummary = parse_response(response).await?;
                    eprintln!("Created sandbox {}", summary.id);

                    // Upload directory
                    eprintln!("Uploading directory: {}", args.path.display());
                    let body = stream_directory(args.path.clone());
                    let url = format!(
                        "{}/sandboxes/{}/files",
                        cli.base_url.trim_end_matches('/'),
                        summary.id
                    );
                    let response = client.post(url).body(body).send().await?;
                    if !response.status().is_success() {
                        eprintln!("Failed to upload files: {}", response.status());
                    } else {
                        eprintln!("Files uploaded.");
                    }

                    // Upload auth files
                    if let Err(e) =
                        upload_sync_files(&client, &cli.base_url, &summary.id.to_string(), true)
                            .await
                    {
                        eprintln!("Warning: Failed to upload auth files: {}", e);
                    }

                    save_last_sandbox(&summary.id.to_string());
                    if should_attach() {
                        handle_ssh(&cli.base_url, &summary.id.to_string()).await?;
                    } else {
                        eprintln!("Skipping interactive shell attach (non-interactive environment detected).");
                    }
                }
                SandboxCommand::Show { id } => {
                    let url = format!("{}/sandboxes/{id}", cli.base_url.trim_end_matches('/'));
                    let response = client.get(url).send().await?;
                    let summary: SandboxSummary = parse_response(response).await?;
                    print_json(&summary)?;
                }
                SandboxCommand::Exec(args) => {
                    handle_exec_request(&client, &cli.base_url, args).await?;
                }
                SandboxCommand::Ssh { id } => {
                    save_last_sandbox(&id);
                    handle_ssh(&cli.base_url, &id).await?;
                }
                SandboxCommand::Delete { id } => {
                    let url = format!("{}/sandboxes/{id}", cli.base_url.trim_end_matches('/'));
                    let response = client.delete(url).send().await?;
                    let summary: SandboxSummary = parse_response(response).await?;
                    print_json(&summary)?;
                }
            }
        }
    }

    Ok(())
}

struct RawModeGuard;

impl RawModeGuard {
    fn new() -> anyhow::Result<Self> {
        enable_raw_mode()?;
        Ok(Self)
    }
}

impl Drop for RawModeGuard {
    fn drop(&mut self) {
        let _ = disable_raw_mode();
    }
}

async fn handle_ssh(base_url: &str, id: &str) -> anyhow::Result<()> {
    let (cols, rows) = crossterm::terminal::size().unwrap_or((80, 24));
    let ws_url = base_url
        .replace("http://", "ws://")
        .replace("https://", "wss://")
        .trim_end_matches('/')
        .to_string();
    let url = format!(
        "{}/sandboxes/{}/attach?cols={}&rows={}",
        ws_url, id, cols, rows
    );

    let (ws_stream, _) = connect_async(url).await?;
    eprintln!("Connected to sandbox shell. Press Ctrl+D to exit.");

    let _guard = RawModeGuard::new()?;

    let (mut write, mut read) = ws_stream.split();
    let mut stdin = tokio::io::stdin();
    let mut stdout = tokio::io::stdout();
    let mut buf = [0u8; 1024];

    #[cfg(unix)]
    let mut sigwinch = signal(SignalKind::window_change())?;

    loop {
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {
                break;
            }
            _ = async {
                #[cfg(unix)]
                return sigwinch.recv().await;
                #[cfg(not(unix))]
                std::future::pending::<Option<()>>().await
            } => {
                if let Ok((cols, rows)) = crossterm::terminal::size() {
                    let msg = format!("resize:{}:{}", rows, cols);
                    write.send(Message::Text(msg)).await?;
                }
            }
            msg = read.next() => {
                match msg {
                    Some(Ok(Message::Binary(data))) => {
                        stdout.write_all(&data).await?;
                        stdout.flush().await?;
                    }
                    Some(Ok(Message::Text(text))) => {
                        stdout.write_all(text.as_bytes()).await?;
                        stdout.flush().await?;
                    }
                    Some(Ok(Message::Close(_))) | Some(Err(_)) | None => {
                        break;
                    }
                    _ => {}
                }
            }
            res = stdin.read(&mut buf) => {
                match res {
                    Ok(0) => break,
                    Ok(n) => {
                        write.send(Message::Binary(buf[..n].to_vec())).await?;
                    }
                    Err(_) => break,
                }
            }
        }
    }

    // Guard dropped here, disabling raw mode
    eprintln!();
    Ok(())
}

async fn parse_response<T>(response: reqwest::Response) -> anyhow::Result<T>
where
    T: for<'de> serde::Deserialize<'de>,
{
    let status = response.status();
    if !status.is_success() {
        let text = response
            .text()
            .await
            .unwrap_or_else(|_| String::from("unknown error"));
        return Err(anyhow::anyhow!("request failed: {status} - {text}"));
    }

    Ok(response.json::<T>().await?)
}

struct ChunkedWriter {
    sender: tokio::sync::mpsc::Sender<Result<Vec<u8>, std::io::Error>>,
}

impl std::io::Write for ChunkedWriter {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let data = buf.to_vec();
        // We use blocking_send because this runs in a spawn_blocking task
        match self.sender.blocking_send(Ok(data)) {
            Ok(_) => Ok(buf.len()),
            Err(_) => Err(std::io::Error::new(
                std::io::ErrorKind::BrokenPipe,
                "Channel closed",
            )),
        }
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

fn stream_directory(path: PathBuf) -> reqwest::Body {
    let (tx, rx) = tokio::sync::mpsc::channel::<Result<Vec<u8>, std::io::Error>>(10);

    tokio::task::spawn_blocking(move || {
        let writer = ChunkedWriter { sender: tx.clone() };
        let mut tar = Builder::new(writer);
        tar.follow_symlinks(false);

        let root = match path.canonicalize() {
            Ok(p) => p,
            Err(e) => {
                let _ = tx.blocking_send(Err(std::io::Error::other(e)));
                return;
            }
        };

        let append_result = if let Some(paths) = git_list_files(&root) {
            append_paths(&root, paths, &mut tar).and_then(|_| append_git_dir(&root, &mut tar))
        } else {
            append_walked_paths(&root, &mut tar)
        };

        if let Err(e) = append_result {
            let _ = tx.blocking_send(Err(e));
            return;
        }

        if let Err(e) = tar.finish() {
            let _ = tx.blocking_send(Err(e));
        }
    });

    reqwest::Body::wrap_stream(futures::stream::unfold(rx, |mut rx| async move {
        rx.recv().await.map(|msg| (msg, rx))
    }))
}

fn append_paths(
    root: &Path,
    paths: Vec<PathBuf>,
    tar: &mut Builder<ChunkedWriter>,
) -> std::io::Result<()> {
    for relative_path in paths {
        append_path(root, &relative_path, tar)?;
    }
    Ok(())
}

fn append_path(
    root: &Path,
    relative_path: &Path,
    tar: &mut Builder<ChunkedWriter>,
) -> std::io::Result<()> {
    let entry_path = root.join(relative_path);
    let metadata = std::fs::symlink_metadata(&entry_path)?;
    let file_type = metadata.file_type();

    if file_type.is_dir() {
        tar.append_dir(relative_path, entry_path)?;
    } else {
        tar.append_path_with_name(entry_path, relative_path)?;
    }

    Ok(())
}

fn append_walked_paths(root: &Path, tar: &mut Builder<ChunkedWriter>) -> std::io::Result<()> {
    let walker = WalkBuilder::new(root)
        .hidden(false)
        .git_ignore(true)
        .build();

    for result in walker {
        let entry = match result {
            Ok(entry) => entry,
            Err(err) => return Err(std::io::Error::other(err)),
        };
        let entry_path = entry.path();

        if entry_path == root {
            continue;
        }

        let relative_path = entry_path
            .strip_prefix(root)
            .map_err(std::io::Error::other)?;

        append_path(root, relative_path, tar)?;
    }

    Ok(())
}

fn git_list_files(root: &Path) -> Option<Vec<PathBuf>> {
    let is_repo = ProcessCommand::new("git")
        .arg("-C")
        .arg(root)
        .args(["rev-parse", "--is-inside-work-tree"])
        .output()
        .ok()
        .filter(|output| output.status.success())
        .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_string())
        .map(|output| output == "true")
        .unwrap_or(false);

    if !is_repo {
        return None;
    }

    let output = ProcessCommand::new("git")
        .arg("-C")
        .arg(root)
        .args([
            "ls-files",
            "-z",
            "--cached",
            "--others",
            "--exclude-standard",
            "--",
            ".",
        ])
        .output()
        .ok()?;

    if !output.status.success() {
        return None;
    }

    let mut paths = Vec::new();
    for raw in output.stdout.split(|b| *b == 0) {
        if raw.is_empty() {
            continue;
        }

        let path_str = String::from_utf8(raw.to_vec()).ok()?;
        paths.push(PathBuf::from(path_str));
    }

    Some(paths)
}

fn append_git_dir(root: &Path, tar: &mut Builder<ChunkedWriter>) -> std::io::Result<()> {
    let git_dir = root.join(".git");
    if !git_dir.exists() {
        return Ok(());
    }

    let walker = WalkBuilder::new(&git_dir)
        .hidden(false)
        .git_ignore(false)
        .build();

    for result in walker {
        let entry = match result {
            Ok(entry) => entry,
            Err(err) => return Err(std::io::Error::other(err)),
        };

        let entry_path = entry.path();
        if entry_path == git_dir {
            continue;
        }

        let relative_path = entry_path
            .strip_prefix(root)
            .map_err(std::io::Error::other)?;

        append_path(root, relative_path, tar)?;
    }

    Ok(())
}

fn should_attach() -> bool {
    if std::env::var(ENV_CMUX_NO_ATTACH).is_ok() {
        return false;
    }

    let stdin_tty = std::io::stdin().is_terminal();
    let stdout_tty = std::io::stdout().is_terminal();
    let stderr_tty = std::io::stderr().is_terminal();

    if std::env::var(ENV_CMUX_FORCE_ATTACH).is_ok() {
        return stdin_tty && stdout_tty && stderr_tty;
    }

    stdin_tty && stdout_tty && stderr_tty
}

fn print_notifications(entries: &[NotificationLogEntry]) {
    if entries.is_empty() {
        println!("No notifications recorded.");
        return;
    }

    println!(
        "{:<25} {:<7} {:<36} {:<36} {:<36} MESSAGE",
        "TIME", "LEVEL", "SANDBOX", "TAB", "PANE"
    );

    for entry in entries {
        let timestamp = entry.received_at.to_rfc3339_opts(SecondsFormat::Secs, true);
        let level = format!("{:?}", entry.level);
        let sandbox = entry.sandbox_id.as_deref().unwrap_or("-");
        let tab = entry.tab_id.as_deref().unwrap_or("-");
        let pane = entry.pane_id.as_deref().unwrap_or("-");
        let message = entry.message.replace('\n', " ");

        println!(
            "{:<25} {:<7} {:<36} {:<36} {:<36} {}",
            timestamp, level, sandbox, tab, pane, message
        );
    }
}

fn print_json<T: Serialize>(value: &T) -> anyhow::Result<()> {
    let rendered = serde_json::to_string_pretty(value)?;
    println!("{rendered}");
    Ok(())
}

async fn handle_proxy(base_url: String, id: String, port: u16) -> anyhow::Result<()> {
    let ca = Arc::new(generate_ca()?);
    let listener = TcpListener::bind(format!("127.0.0.1:{}", port)).await?;
    let local_addr = listener.local_addr()?;
    eprintln!("Proxy listening on http://{}", local_addr);

    loop {
        let (socket, _) = listener.accept().await?;
        let base_url = base_url.clone();
        let id = id.clone();
        let ca = ca.clone();

        tokio::spawn(async move {
            if let Err(_e) = handle_connection(socket, base_url, id, ca).await {
                // Ignore
            }
        });
    }
}

struct BrowserProxy {
    port: u16,
    shutdown_tx: Option<oneshot::Sender<()>>,
    task: tokio::task::JoinHandle<anyhow::Result<()>>,
}

impl BrowserProxy {
    fn port(&self) -> u16 {
        self.port
    }

    async fn start(
        base_url: String,
        id: String,
        ca: Arc<rcgen::Certificate>,
    ) -> anyhow::Result<Self> {
        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let port = listener.local_addr()?.port();
        let (shutdown_tx, mut shutdown_rx) = oneshot::channel();
        let task = tokio::spawn(async move {
            loop {
                tokio::select! {
                    _ = &mut shutdown_rx => {
                        break;
                    }
                    accept_result = listener.accept() => {
                        match accept_result {
                            Ok((socket, _)) => {
                                let base_url = base_url.clone();
                                let id = id.clone();
                                let ca = ca.clone();
                                tokio::spawn(async move {
                                    if let Err(err) = handle_connection(socket, base_url, id, ca).await {
                                        eprintln!("Proxy connection error: {err:?}");
                                    }
                                });
                            }
                            Err(err) => {
                                return Err(anyhow::anyhow!("Proxy accept error: {err}"));
                            }
                        }
                    }
                }
            }
            Ok(())
        });

        Ok(Self {
            port,
            shutdown_tx: Some(shutdown_tx),
            task,
        })
    }

    async fn shutdown(mut self) -> anyhow::Result<()> {
        if let Some(tx) = self.shutdown_tx.take() {
            let _ = tx.send(());
        }
        match self.task.await {
            Ok(result) => result,
            Err(err) => Err(anyhow::anyhow!("Proxy task join error: {err}")),
        }
    }
}

async fn handle_browser(base_url: String, id: String) -> anyhow::Result<()> {
    let proxy = BrowserProxy::start(base_url, id, Arc::new(generate_ca()?)).await?;
    let port = proxy.port();
    eprintln!("Proxy started on port {}", port);

    // Launch Chrome
    #[cfg(target_os = "macos")]
    let chrome_bin = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
    #[cfg(target_os = "linux")]
    let chrome_bin = "google-chrome";
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    let chrome_bin = "chrome";

    let user_data = std::env::temp_dir().join("cmux-chrome-profile");
    let _ = std::fs::create_dir_all(&user_data);

    eprintln!("Launching Chrome...");
    let mut child = match tokio::process::Command::new(chrome_bin)
        .arg(format!(
            "--proxy-server=http=127.0.0.1:{};https=127.0.0.1:{}",
            port, port
        ))
        .arg("--proxy-bypass-list=<-loopback>")
        .arg("--ignore-certificate-errors")
        .arg(format!("--user-data-dir={}", user_data.display()))
        .arg("--no-first-run")
        .arg("http://localhost:8000")
        .kill_on_drop(true)
        .spawn()
    {
        Ok(child) => child,
        Err(err) => {
            let _ = proxy.shutdown().await;
            return Err(err.into());
        }
    };

    let wait_result = child.wait().await;
    let shutdown_result = proxy.shutdown().await;
    if let Err(err) = wait_result {
        return Err(err.into());
    }
    shutdown_result?;
    Ok(())
}

fn generate_ca() -> anyhow::Result<rcgen::Certificate> {
    let mut params = CertificateParams::default();
    params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    params
        .distinguished_name
        .push(DnType::CommonName, "cmux-sandbox-ca");
    Ok(rcgen::Certificate::from_params(params)?)
}

async fn handle_server_start(opts: &StartArgs) -> anyhow::Result<()> {
    let (default_container, default_port, default_image, volume_prefix) = if is_dmux() {
        (
            DMUX_DEFAULT_CONTAINER,
            DMUX_DEFAULT_HTTP_PORT.to_string(),
            DMUX_DEFAULT_IMAGE,
            "dmux",
        )
    } else {
        (
            "cmux-sandbox-dev-run",
            DEFAULT_HTTP_PORT.to_string(),
            "cmux-sandbox-dev",
            "cmux",
        )
    };
    let container_name =
        std::env::var("CONTAINER_NAME").unwrap_or_else(|_| default_container.into());
    let port = std::env::var("CMUX_SANDBOX_PORT").unwrap_or(default_port);
    let image_name = std::env::var("IMAGE_NAME").unwrap_or_else(|_| default_image.into());
    let docker_mode = opts.docker.unwrap_or(DockerMode::Dind);
    let docker_socket = opts
        .docker_socket
        .clone()
        .unwrap_or_else(|| "/var/run/docker.sock".to_string());

    // Check if container is already running
    let output = tokio::process::Command::new("docker")
        .args([
            "ps",
            "--filter",
            &format!("name=^/{}$", container_name),
            "--format",
            "{{.Names}}",
        ])
        .output()
        .await?;

    let output_str = String::from_utf8_lossy(&output.stdout);
    if output_str.trim() == container_name {
        eprintln!("Server container '{}' is already running.", container_name);
        return Ok(());
    }

    eprintln!(
        "Starting server container '{}' on port {} (docker mode: {})...",
        container_name,
        port,
        docker_mode.as_str()
    );

    // Force remove existing stopped container if any
    let _ = tokio::process::Command::new("docker")
        .args(["rm", "-f", &container_name])
        .output()
        .await;

    let docker_volume = format!("{}-sandbox-docker:/var/lib/docker", volume_prefix);
    let data_volume = format!("{}-sandbox-data:/var/lib/cmux/sandboxes", volume_prefix);
    let port_mapping = format!("{}:{}", port, port);
    let port_env = format!("CMUX_SANDBOX_PORT={}", port);
    let docker_mode_env = format!("CMUX_DOCKER_MODE={}", docker_mode.as_str());
    let docker_socket_env = format!("CMUX_DOCKER_SOCKET={}", docker_socket);

    // Build docker args (owned Strings so we can push dynamic values safely)
    let mut docker_args: Vec<String> = vec![
        "run".into(),
        "--privileged".into(),
        "-d".into(),
        "--name".into(),
        container_name.clone(),
        "--cgroupns=host".into(),
        "--tmpfs".into(),
        "/run".into(),
        "--tmpfs".into(),
        "/run/lock".into(),
        "-v".into(),
        "/sys/fs/cgroup:/sys/fs/cgroup:rw".into(),
        "--dns".into(),
        "1.1.1.1".into(),
        "--dns".into(),
        "8.8.8.8".into(),
        "-e".into(),
        port_env.clone(),
        "-e".into(),
        docker_mode_env.clone(),
        "-e".into(),
        docker_socket_env.clone(),
        "-p".into(),
        port_mapping.clone(),
        "-v".into(),
        docker_volume.clone(),
        "-v".into(),
        data_volume.clone(),
    ];

    // Add SSH agent forwarding if SSH_AUTH_SOCK is set and socket exists
    // Works with: macOS launchd agent, Docker Desktop, OrbStack
    let ssh_volume = std::env::var("SSH_AUTH_SOCK")
        .ok()
        .filter(|path| std::path::Path::new(path).exists())
        .map(|path| format!("{}:/ssh-agent.sock", path));
    if let Some(ref volume) = ssh_volume {
        eprintln!("SSH agent forwarding enabled");
        docker_args.push("-v".into());
        docker_args.push(volume.clone());
        docker_args.push("-e".into());
        docker_args.push("SSH_AUTH_SOCK=/ssh-agent.sock".into());
    }

    if let DockerMode::Dood = docker_mode {
        if !std::path::Path::new(&docker_socket).exists() {
            return Err(anyhow::anyhow!(
                "docker socket '{}' not found on host; mount it or choose --docker dind",
                docker_socket
            ));
        }
        docker_args.push("-v".into());
        docker_args.push(format!("{0}:{0}", docker_socket));
    }

    docker_args.push("--entrypoint".into());
    docker_args.push("/usr/local/bin/bootstrap-dind.sh".into());
    docker_args.push(image_name.clone());
    docker_args.push("/usr/local/bin/cmux-sandboxd".into());
    docker_args.push("--bind".into());
    docker_args.push("0.0.0.0".into());
    docker_args.push("--port".into());
    docker_args.push(port.clone());
    docker_args.push("--data-dir".into());
    docker_args.push("/var/lib/cmux/sandboxes".into());

    let status = tokio::process::Command::new("docker")
        .args(&docker_args)
        .status()
        .await?;

    if !status.success() {
        return Err(anyhow::anyhow!("Failed to start container"));
    }

    eprintln!("Waiting for server to be ready...");
    for _ in 0..30 {
        if reqwest::get(format!("http://127.0.0.1:{}/healthz", port))
            .await
            .is_ok()
        {
            eprintln!("Server is up!");
            return Ok(());
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }

    Err(anyhow::anyhow!("Server failed to start within 15s"))
}

async fn handle_server_stop() -> anyhow::Result<()> {
    let default_container = if is_dmux() {
        DMUX_DEFAULT_CONTAINER
    } else {
        "cmux-sandbox-dev-run"
    };
    let container_name =
        std::env::var("CONTAINER_NAME").unwrap_or_else(|_| default_container.into());
    eprintln!("Stopping server container '{}'...", container_name);
    let status = tokio::process::Command::new("docker")
        .args(["rm", "-f", &container_name])
        .status()
        .await?;

    if status.success() {
        eprintln!("Server stopped.");
    } else {
        eprintln!("Failed to stop server (maybe it wasn't running?)");
    }
    Ok(())
}

async fn handle_server_status(base_url: &str) -> anyhow::Result<()> {
    let default_container = if is_dmux() {
        DMUX_DEFAULT_CONTAINER
    } else {
        "cmux-sandbox-dev-run"
    };
    let container_name =
        std::env::var("CONTAINER_NAME").unwrap_or_else(|_| default_container.into());

    println!("cmux CLI version: {}", env!("CARGO_PKG_VERSION"));
    println!("Server URL: {}", base_url);
    println!("----------------------------------------");

    // 1. Check Docker Container
    let output = tokio::process::Command::new("docker")
        .args(["inspect", "--format", "{{.State.Status}}", &container_name])
        .output()
        .await;

    let container_status = match output {
        Ok(o) if o.status.success() => {
            let s = String::from_utf8_lossy(&o.stdout).trim().to_string();
            if s == "running" {
                format!("✅ Running ({})", container_name)
            } else {
                format!("⚠️  State: {} ({})", s, container_name)
            }
        }
        _ => format!("❌ Not found / Stopped ({})", container_name),
    };
    println!("Container: {}", container_status);

    // 2. Check Server Health
    let client = Client::builder().timeout(Duration::from_secs(2)).build()?;
    let health_url = format!("{}/healthz", base_url.trim_end_matches('/'));
    let server_health = match client.get(&health_url).send().await {
        Ok(resp) if resp.status().is_success() => "✅ Healthy".to_string(),
        Ok(resp) => format!("⚠️  Unhealthy (Status: {})", resp.status()),
        Err(e) => format!("❌ Unreachable ({})", e),
    };
    println!("Server:    {}", server_health);

    // 3. Check Sandboxes (only if server is healthy)
    if server_health.contains("✅") {
        let sandboxes_url = format!("{}/sandboxes", base_url.trim_end_matches('/'));
        match client.get(&sandboxes_url).send().await {
            Ok(resp) => {
                if let Ok(sandboxes) = resp.json::<Vec<SandboxSummary>>().await {
                    println!("Sandboxes: {} active", sandboxes.len());
                    for s in sandboxes {
                        println!("  - [{}] {} ({:?})", s.id, s.name, s.status);
                    }
                } else {
                    println!("Sandboxes: ❓ Failed to parse response");
                }
            }
            Err(_) => println!("Sandboxes: ❓ Failed to fetch"),
        }
    } else {
        println!("Sandboxes: (server unreachable)");
    }

    Ok(())
}

async fn handle_connection(
    mut socket: tokio::net::TcpStream,
    base_url: String,
    id: String,
    ca: Arc<rcgen::Certificate>,
) -> anyhow::Result<()> {
    let mut buf = [0u8; 4096];
    let n = socket.peek(&mut buf).await?;
    if n == 0 {
        return Ok(());
    }

    let header = String::from_utf8_lossy(&buf[..n]);

    if header.starts_with("CONNECT ") {
        let line = header.lines().next().unwrap_or("");
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() < 2 {
            return Ok(());
        }
        let target = parts[1];
        let port = target
            .split(':')
            .nth(1)
            .unwrap_or("80")
            .parse::<u16>()
            .unwrap_or(80);

        let mut trash = [0u8; 4096];
        let mut total_read = 0;
        loop {
            let n_read = socket.read(&mut trash[total_read..]).await?;
            if n_read == 0 {
                return Ok(());
            }
            total_read += n_read;
            if trash[..total_read].windows(4).any(|w| w == b"\r\n\r\n") {
                break;
            }
            if total_read >= trash.len() {
                break;
            }
        }

        socket
            .write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            .await?;

        let mut peek_buf = [0u8; 1];
        let n = socket.peek(&mut peek_buf).await?;
        if n > 0 && peek_buf[0] == 0x16 {
            let target_host = target.split(':').next().unwrap_or("localhost");

            let mut params = CertificateParams::new(vec![target_host.to_string()]);
            params
                .distinguished_name
                .push(DnType::CommonName, target_host);
            params.subject_alt_names = vec![SanType::DnsName(target_host.to_string())];

            let cert = rcgen::Certificate::from_params(params)?;
            let cert_der = cert.serialize_der_with_signer(&ca)?;
            let key_der = cert.serialize_private_key_der();

            let certs = vec![CertificateDer::from(cert_der)];
            let key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key_der));

            let server_config = ServerConfig::builder()
                .with_no_client_auth()
                .with_single_cert(certs, key)?;

            let acceptor = TlsAcceptor::from(Arc::new(server_config));
            let tls_stream = acceptor.accept(socket).await?;

            connect_and_tunnel(tls_stream, base_url, id, port, None).await?;
        } else {
            connect_and_tunnel(socket, base_url, id, port, None).await?;
        }
    } else if header.starts_with("GET ")
        || header.starts_with("POST ")
        || header.starts_with("PUT ")
        || header.starts_with("DELETE ")
        || header.starts_with("HEAD ")
        || header.starts_with("OPTIONS ")
        || header.starts_with("PATCH ")
    {
        // Read headers fully
        let mut header_buf = Vec::new();
        let mut buffer = [0u8; 1];
        let mut state = 0; // 0: normal, 1: \r, 2: \r\n, 3: \r\n\r

        loop {
            if socket.read_exact(&mut buffer).await.is_err() {
                break;
            }
            header_buf.push(buffer[0]);
            let b = buffer[0];
            if state == 0 && b == b'\r' {
                state = 1;
            } else if state == 1 && b == b'\n' {
                state = 2;
            } else if state == 2 && b == b'\r' {
                state = 3;
            } else if state == 3 && b == b'\n' {
                break;
            }
            // Found \r\n\r\n
            else if b != b'\r' {
                state = 0;
            } // Reset if char is not part of sequence
        }

        let header_str = String::from_utf8_lossy(&header_buf);
        let lines: Vec<&str> = header_str.lines().collect();

        if !lines.is_empty() {
            let request_line = lines[0];
            let parts: Vec<&str> = request_line.split_whitespace().collect();
            if parts.len() >= 2 {
                let url = parts[1];
                if let Some(host_start) = url.strip_prefix("http://") {
                    let path_start = host_start.find('/').unwrap_or(host_start.len());
                    let host_port = &host_start[..path_start];
                    let path = if path_start == host_start.len() {
                        "/"
                    } else {
                        &host_start[path_start..]
                    };
                    let port = host_port
                        .split(':')
                        .nth(1)
                        .unwrap_or("80")
                        .parse::<u16>()
                        .unwrap_or(80);

                    let method = parts[0];
                    let version = if parts.len() > 2 {
                        parts[2]
                    } else {
                        "HTTP/1.1"
                    };

                    let new_req_line = format!("{} {} {}", method, path, version);

                    // Rebuild headers with Connection: close
                    let mut new_headers = String::new();
                    new_headers.push_str(&new_req_line);
                    new_headers.push_str("\r\n");

                    for line in lines.iter().skip(1) {
                        if line.to_lowercase().starts_with("connection:")
                            || line.to_lowercase().starts_with("proxy-connection:")
                        {
                            continue;
                        }
                        if line.trim().is_empty() {
                            continue;
                        }
                        new_headers.push_str(line);
                        new_headers.push_str("\r\n");
                    }
                    new_headers.push_str("Connection: close\r\n\r\n");

                    connect_and_tunnel(socket, base_url, id, port, Some(new_headers.into_bytes()))
                        .await?;
                }
            }
        }
    }

    Ok(())
}

async fn connect_and_tunnel<S>(
    socket: S,
    base_url: String,
    id: String,
    port: u16,
    initial_data: Option<Vec<u8>>,
) -> anyhow::Result<()>
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    let ws_url = base_url
        .replace("http://", "ws://")
        .replace("https://", "wss://")
        .trim_end_matches('/')
        .to_string();
    let url = format!("{}/sandboxes/{}/proxy?port={}", ws_url, id, port);

    let (ws_stream, _) = connect_async(url).await?;
    let (mut ws_write, mut ws_read) = ws_stream.split();
    let (mut sock_read, mut sock_write) = tokio::io::split(socket);

    if let Some(data) = initial_data {
        ws_write.send(Message::Binary(data)).await?;
    }

    let mut buf = [0u8; 8192];

    loop {
        tokio::select! {
             res = sock_read.read(&mut buf) => {
                 match res {
                     Ok(0) => break,
                     Ok(n) => {
                         ws_write.send(Message::Binary(buf[..n].to_vec())).await?;
                     }
                     Err(_) => break,
                 }
             }
             msg = ws_read.next() => {
                 match msg {
                     Some(Ok(Message::Binary(data))) => {
                         sock_write.write_all(&data).await?;
                     }
                      Some(Ok(Message::Text(data))) => {
                         sock_write.write_all(data.as_bytes()).await?;
                     }
                     Some(Ok(Message::Close(_))) | None => break,
                     _ => {}
                 }
             }
        }
    }
    Ok(())
}

async fn upload_workspace_directory(
    client: &Client,
    base_url: &str,
    id: &str,
    path: PathBuf,
) -> anyhow::Result<()> {
    let body = stream_directory(path);
    let url = format!("{}/sandboxes/{}/files", base_url.trim_end_matches('/'), id);
    let response = client.post(url).body(body).send().await?;
    if !response.status().is_success() {
        return Err(anyhow::anyhow!(
            "Failed to upload files: {}",
            response.status()
        ));
    }
    Ok(())
}

async fn handle_exec_request(
    client: &Client,
    base_url: &str,
    args: ExecArgs,
) -> anyhow::Result<()> {
    let command = if args.command.len() == 1 && args.command[0].contains(' ') {
        vec!["/bin/sh".into(), "-c".into(), args.command[0].clone()]
    } else {
        args.command
    };
    let body = ExecRequest {
        command,
        workdir: args.workdir,
        env: args.env,
    };
    let url = format!(
        "{}/sandboxes/{}/exec",
        base_url.trim_end_matches('/'),
        args.id
    );
    let response = client.post(url).json(&body).send().await?;
    let result: ExecResponse = parse_response(response).await?;
    print_json(&result)?;
    Ok(())
}

async fn handle_setup_claude() -> anyhow::Result<()> {
    eprintln!("Running 'claude setup-token'...");
    eprintln!("Please follow the prompts to authenticate with Claude.\n");

    // Run claude setup-token and capture output
    // We need to run it interactively so the user can input their token
    let child = tokio::process::Command::new("claude")
        .arg("setup-token")
        .stdin(std::process::Stdio::inherit())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()?;

    let output = child.wait_with_output().await?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);

    // Print output for user visibility
    if !stdout.is_empty() {
        print!("{}", stdout);
    }
    if !stderr.is_empty() {
        eprint!("{}", stderr);
    }

    if !output.status.success() {
        return Err(anyhow::anyhow!(
            "'claude setup-token' failed with exit code: {:?}",
            output.status.code()
        ));
    }

    // Try to extract the token from stdout or stderr
    let combined_output = format!("{}\n{}", stdout, stderr);
    if let Some(token) = extract_api_key_from_output(&combined_output) {
        eprintln!("\nOAuth token detected, storing in keychain...");
        store_claude_token(&token).map_err(|e| anyhow::anyhow!("Failed to store token: {}", e))?;
        eprintln!("\x1b[32m✓ Claude OAuth token stored in macOS Keychain\x1b[0m");
        eprintln!("  Service: cmux, Account: CLAUDE_CODE_OAUTH_TOKEN");
        eprintln!("  The token will be automatically injected into sandbox environments.");
    } else {
        eprintln!("\n\x1b[33mNote: No OAuth token detected in output.\x1b[0m");
        eprintln!("You can manually add with: security add-generic-password -s cmux -a CLAUDE_CODE_OAUTH_TOKEN -w <token> -A");
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_env_value() {
        let env = parse_env("KEY=value").unwrap();
        assert_eq!(env.key, "KEY");
        assert_eq!(env.value, "value");
    }

    #[test]
    fn rejects_invalid_env_value() {
        assert!(parse_env("INVALID").is_err());
    }

    #[test]
    fn exec_single_string_is_wrapped_in_shell() {
        let args = ExecArgs {
            id: "nil".to_string(),
            command: vec!["echo 123".into()],
            workdir: None,
            env: Vec::new(),
        };
        let built = ExecRequest {
            command: if args.command.len() == 1 && args.command[0].contains(' ') {
                vec!["/bin/sh".into(), "-c".into(), args.command[0].clone()]
            } else {
                args.command
            },
            workdir: args.workdir.clone(),
            env: args.env.clone(),
        };
        assert_eq!(built.command, vec!["/bin/sh", "-c", "echo 123"]);
    }

    #[tokio::test]
    async fn browser_proxy_shuts_down_after_browser_closes() {
        let proxy = BrowserProxy::start(
            "http://127.0.0.1:12345".to_string(),
            "test-id".to_string(),
            Arc::new(generate_ca().unwrap()),
        )
        .await
        .expect("proxy should start");

        let port = proxy.port();
        proxy.shutdown().await.expect("proxy should stop");

        let bind_attempt = tokio::time::timeout(
            std::time::Duration::from_secs(1),
            tokio::net::TcpListener::bind(("127.0.0.1", port)),
        )
        .await
        .expect("bind attempt timed out");

        bind_attempt.expect("proxy should release the port");
    }
}
