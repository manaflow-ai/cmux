use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use chrono::SecondsFormat;
use clap::{Args, Parser, Subcommand, ValueEnum};
use cmux_sandbox::models::{
    CreateSandboxRequest, EnvVar, ExecRequest, ExecResponse, NotificationLogEntry, SandboxSummary,
};
use cmux_sandbox::{
    build_default_env_vars, cache_access_token, clear_cached_access_token,
    delete_stack_refresh_token, extract_api_key_from_output, get_cached_access_token,
    get_stack_refresh_token, store_claude_token, store_stack_refresh_token,
    sync_files::{
        prebuild_sync_files_tar, upload_prebuilt_sync_files, upload_sync_files, SYNC_FILES,
    },
    AcpProvider, DEFAULT_HTTP_PORT, DEFAULT_IMAGE, DMUX_DEFAULT_CONTAINER, DMUX_DEFAULT_HTTP_PORT,
    DMUX_DEFAULT_IMAGE,
};
use crossterm::terminal::{disable_raw_mode, enable_raw_mode};
use futures::{SinkExt, StreamExt};
use ignore::WalkBuilder;
use reqwest::Client;
use serde::Serialize;
use sha2::{Digest, Sha256};
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

    /// Internal helper to proxy SSH through direct TCP to Morph (used as SSH ProxyCommand)
    #[command(name = "_ssh-proxy", hide = true)]
    SshProxy {
        /// Sandbox ID (morphvm_xxx or task-run ID)
        id: String,
        /// Team slug or ID
        #[arg(long, short = 't', env = "CMUX_TEAM")]
        team: Option<String>,
        /// API base URL (for staging/self-hosted environments)
        #[arg(long, short = 'u', env = "CMUX_BASE_URL")]
        base_url: Option<String>,
    },

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

    /// Run esctest2 terminal escape sequence tests
    #[command(alias = "et")]
    Esctest(EsctestArgs),

    /// Check Docker setup and download sandbox image if needed
    Onboard,

    /// SSH into a sandbox (real SSH, not WebSocket attach)
    Ssh(SshArgs),

    /// Execute a command on a sandbox via SSH (non-interactive)
    #[command(name = "ssh-exec")]
    SshExec(SshExecArgs),

    /// Generate SSH config for easy sandbox access (e.g., `ssh sandbox-0`)
    SshConfig,

    /// Manage SSH keys for sandbox access
    #[command(subcommand)]
    SshKeys(SshKeysCommand),

    /// Manage cloud VMs (create, list, etc.)
    #[command(subcommand)]
    Vm(VmCommand),
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
    /// Login via browser
    Login,
    /// Logout and clear stored credentials
    Logout,
    /// Show current authentication state
    Status,
    /// Print the current access token (for debugging)
    Token,
}

#[derive(Subcommand, Debug)]
enum SshKeysCommand {
    /// List registered SSH keys
    #[command(alias = "ls")]
    List,
    /// Add an SSH key
    Add(SshKeysAddArgs),
    /// Remove an SSH key by fingerprint or ID
    #[command(alias = "rm")]
    Remove {
        /// Fingerprint (SHA256:...) or key ID to remove
        fingerprint_or_id: String,
    },
}

#[derive(Subcommand, Debug)]
enum VmCommand {
    /// Create a new cloud VM
    Create(VmCreateArgs),
    /// List running VMs
    #[command(alias = "ls")]
    List(VmListArgs),
}

#[derive(Args, Debug)]
struct VmCreateArgs {
    /// Team slug or ID (required)
    #[arg(long, short = 't', env = "CMUX_TEAM")]
    team: String,
    /// Time-to-live in seconds before VM auto-pauses (default: 30 minutes)
    #[arg(long, default_value_t = 1800)]
    ttl: u64,
    /// Snapshot preset to use (e.g., "4vcpu_16gb_48gb", "8vcpu_32gb_48gb")
    #[arg(long)]
    preset: Option<String>,
    /// GitHub repositories to clone (format: owner/repo)
    #[arg(long = "repo", short = 'r')]
    repos: Vec<String>,
    /// Output format (json or text)
    #[arg(long, default_value = "text")]
    output: String,
}

#[derive(Args, Debug)]
struct VmListArgs {
    /// Team slug or ID
    #[arg(long, short = 't', env = "CMUX_TEAM")]
    team: Option<String>,
    /// Output format (json or text)
    #[arg(long, default_value = "text")]
    output: String,
}

#[derive(Args, Debug)]
struct SshKeysAddArgs {
    /// Path to the SSH public key file (default: auto-detect ~/.ssh/id_*.pub)
    #[arg(value_name = "PATH")]
    path: Option<PathBuf>,

    /// Import keys from connected GitHub account
    #[arg(long)]
    from_github: bool,

    /// Name for the key (default: hostname)
    #[arg(long, short)]
    name: Option<String>,
}

#[derive(Args, Debug)]
struct SshArgs {
    /// Sandbox ID or index (can be morphvm_xxx or task-run ID)
    id: String,
    /// Team slug or ID (required for remote SSH connections)
    #[arg(long, short = 't', env = "CMUX_TEAM")]
    team: Option<String>,
    /// Additional SSH arguments (e.g., -L 8080:localhost:8080 for port forwarding)
    #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
    ssh_args: Vec<String>,
}

#[derive(Args, Debug)]
struct SshExecArgs {
    /// Sandbox ID or index (can be morphvm_xxx or task-run ID)
    id: String,
    /// Team slug or ID (required for remote SSH connections)
    #[arg(long, short = 't', env = "CMUX_TEAM")]
    team: Option<String>,
    /// Command to execute on the sandbox
    #[arg(trailing_var_arg = true, required = true)]
    command: Vec<String>,
}

#[derive(Args, Debug)]
struct EsctestArgs {
    /// Regex pattern to filter tests (e.g., 'DA', 'CUP', 'SGR')
    #[arg(default_value = ".*")]
    pattern: String,

    /// Stop on first test failure
    #[arg(long)]
    stop_on_failure: bool,

    /// Timeout in seconds for the entire test run
    #[arg(short, long, default_value_t = 120)]
    timeout: u32,

    /// Maximum VT level to test (1-5)
    #[arg(long, default_value_t = 4)]
    max_vt_level: u8,

    /// List available test names matching pattern
    #[arg(long)]
    list: bool,
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

            // OPTIMIZATION: Pre-build the sync files tar while waiting for sandbox creation
            // This overlaps CPU work (tar creation) with network I/O (sandbox creation)
            let sync_tar_handle = tokio::task::spawn_blocking(prebuild_sync_files_tar);

            // OPTIMIZATION: Start building the workspace tar archive BEFORE sandbox creation
            // The stream_directory function spawns a blocking task that starts immediately
            let workspace_body = stream_directory(args.path.clone());

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

            // OPTIMIZATION: Start uploads in background, attach to shell IMMEDIATELY
            // User gets a shell while files are still uploading in the background
            let sandbox_id_for_upload = summary.id.to_string();
            let base_url_for_upload = cli.base_url.clone();
            let client_for_upload = client.clone();
            let path_display = args.path.display().to_string();

            eprintln!("Uploading {} in background...", path_display);

            // Spawn workspace upload task - starts immediately to drain the stream
            let upload_url = format!(
                "{}/sandboxes/{}/files",
                base_url_for_upload.trim_end_matches('/'),
                sandbox_id_for_upload
            );
            let client_for_workspace = client_for_upload.clone();
            let workspace_upload_handle = tokio::spawn(async move {
                let response = client_for_workspace
                    .post(&upload_url)
                    .body(workspace_body)
                    .send()
                    .await;
                match response {
                    Ok(resp) if resp.status().is_success() => {
                        eprintln!("\r\x1b[K\x1b[32m✓\x1b[0m Files uploaded.");
                    }
                    Ok(resp) => {
                        eprintln!(
                            "\r\x1b[K\x1b[31m✗\x1b[0m Failed to upload files: {}",
                            resp.status()
                        );
                    }
                    Err(e) => {
                        eprintln!("\r\x1b[K\x1b[31m✗\x1b[0m Failed to upload files: {}", e);
                    }
                }
            });

            // Spawn auth upload task - waits for tar to be ready first
            let auth_upload_handle = tokio::spawn(async move {
                let sync_tar_result = match sync_tar_handle.await {
                    Ok(result) => result,
                    Err(e) => {
                        eprintln!(
                            "\r\x1b[K\x1b[33m!\x1b[0m Warning: Failed to build auth files tar: {}",
                            e
                        );
                        return;
                    }
                };
                let tar_data = match sync_tar_result {
                    Ok(Some(data)) => data,
                    Ok(None) => return, // No files to sync
                    Err(e) => {
                        eprintln!(
                            "\r\x1b[K\x1b[33m!\x1b[0m Warning: Failed to build auth files tar: {}",
                            e
                        );
                        return;
                    }
                };
                if let Err(e) = upload_prebuilt_sync_files(
                    &client_for_upload,
                    &base_url_for_upload,
                    &sandbox_id_for_upload,
                    tar_data,
                    false,
                )
                .await
                {
                    eprintln!(
                        "\r\x1b[K\x1b[33m!\x1b[0m Warning: Failed to upload auth files: {}",
                        e
                    );
                }
            });

            save_last_sandbox(&summary.id.to_string());
            if should_attach() {
                // Run SSH session, but ensure uploads complete even if SSH exits quickly
                let ssh_result = handle_ssh(&cli.base_url, &summary.id.to_string()).await;
                // Wait for background uploads to complete before exiting
                // (otherwise the runtime shuts down and cancels the background tasks)
                let _ = tokio::join!(workspace_upload_handle, auth_upload_handle);
                ssh_result?;
            } else {
                // In non-interactive mode, wait for uploads to complete before exiting
                let _ = tokio::join!(workspace_upload_handle, auth_upload_handle);
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
        Command::SshProxy { id, team, base_url } => {
            let api_url = base_url.as_deref().unwrap_or(&cli.base_url);
            handle_ssh_proxy(&id, team.as_deref(), api_url).await?;
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
            AuthCommand::Login => {
                handle_auth_login().await?;
            }
            AuthCommand::Logout => {
                handle_auth_logout()?;
            }
            AuthCommand::Status => {
                handle_auth_status().await?;
            }
            AuthCommand::Token => {
                handle_auth_token().await?;
            }
        },
        Command::SetupClaude => {
            handle_setup_claude().await?;
        }
        Command::Esctest(args) => {
            handle_esctest(&client, &cli.base_url, args).await?;
        }
        Command::Onboard => {
            handle_onboard().await?;
        }
        Command::Ssh(args) => {
            handle_real_ssh(&client, &cli.base_url, &args).await?;
        }
        Command::SshExec(args) => {
            handle_ssh_exec(&client, &cli.base_url, &args).await?;
        }
        Command::SshConfig => {
            handle_ssh_config(&client, &cli.base_url).await?;
        }
        Command::SshKeys(cmd) => match cmd {
            SshKeysCommand::List => {
                handle_ssh_keys_list().await?;
            }
            SshKeysCommand::Add(args) => {
                handle_ssh_keys_add(args).await?;
            }
            SshKeysCommand::Remove { fingerprint_or_id } => {
                handle_ssh_keys_remove(&fingerprint_or_id).await?;
            }
        },
        Command::Vm(cmd) => match cmd {
            VmCommand::Create(args) => {
                handle_vm_create(args).await?;
            }
            VmCommand::List(args) => {
                handle_vm_list(args).await?;
            }
        },
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
                    // OPTIMIZATION: Pre-build the sync files tar while waiting for sandbox creation
                    let sync_tar_handle = tokio::task::spawn_blocking(prebuild_sync_files_tar);

                    // OPTIMIZATION: Start building the workspace tar archive BEFORE sandbox creation
                    let workspace_body = stream_directory(args.path.clone());

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

                    // OPTIMIZATION: Start uploads in background, attach to shell IMMEDIATELY
                    let sandbox_id_for_upload = summary.id.to_string();
                    let base_url_for_upload = cli.base_url.clone();
                    let client_for_upload = client.clone();
                    let path_display = args.path.display().to_string();

                    eprintln!("Uploading {} in background...", path_display);

                    // Spawn workspace upload task - starts immediately to drain the stream
                    let upload_url = format!(
                        "{}/sandboxes/{}/files",
                        base_url_for_upload.trim_end_matches('/'),
                        sandbox_id_for_upload
                    );
                    let client_for_workspace = client_for_upload.clone();
                    let workspace_upload_handle = tokio::spawn(async move {
                        let response = client_for_workspace
                            .post(&upload_url)
                            .body(workspace_body)
                            .send()
                            .await;
                        match response {
                            Ok(resp) if resp.status().is_success() => {
                                eprintln!("\r\x1b[K\x1b[32m✓\x1b[0m Files uploaded.");
                            }
                            Ok(resp) => {
                                eprintln!(
                                    "\r\x1b[K\x1b[31m✗\x1b[0m Failed to upload files: {}",
                                    resp.status()
                                );
                            }
                            Err(e) => {
                                eprintln!("\r\x1b[K\x1b[31m✗\x1b[0m Failed to upload files: {}", e);
                            }
                        }
                    });

                    // Spawn auth upload task - waits for tar to be ready first
                    let auth_upload_handle = tokio::spawn(async move {
                        let sync_tar_result = match sync_tar_handle.await {
                            Ok(result) => result,
                            Err(e) => {
                                eprintln!(
                                    "\r\x1b[K\x1b[33m!\x1b[0m Warning: Failed to build auth files tar: {}",
                                    e
                                );
                                return;
                            }
                        };
                        let tar_data = match sync_tar_result {
                            Ok(Some(data)) => data,
                            Ok(None) => return, // No files to sync
                            Err(e) => {
                                eprintln!(
                                    "\r\x1b[K\x1b[33m!\x1b[0m Warning: Failed to build auth files tar: {}",
                                    e
                                );
                                return;
                            }
                        };
                        if let Err(e) = upload_prebuilt_sync_files(
                            &client_for_upload,
                            &base_url_for_upload,
                            &sandbox_id_for_upload,
                            tar_data,
                            false,
                        )
                        .await
                        {
                            eprintln!(
                                "\r\x1b[K\x1b[33m!\x1b[0m Warning: Failed to upload auth files: {}",
                                e
                            );
                        }
                    });

                    save_last_sandbox(&summary.id.to_string());
                    if should_attach() {
                        // Run SSH session, but ensure uploads complete even if SSH exits quickly
                        let ssh_result = handle_ssh(&cli.base_url, &summary.id.to_string()).await;
                        // Wait for background uploads to complete before exiting
                        // (otherwise the runtime shuts down and cancels the background tasks)
                        let _ = tokio::join!(workspace_upload_handle, auth_upload_handle);
                        ssh_result?;
                    } else {
                        // In non-interactive mode, wait for uploads to complete before exiting
                        let _ = tokio::join!(workspace_upload_handle, auth_upload_handle);
                        eprintln!(
                            "Skipping interactive shell attach (non-interactive environment detected)."
                        );
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

// =============================================================================
// CLI Authentication
// =============================================================================

/// CMUX API base URL (for cmux-specific endpoints like /api/sandboxes)
/// Debug builds use localhost, release builds use production
fn get_cmux_api_url() -> String {
    std::env::var("CMUX_API_URL").unwrap_or_else(|_| {
        #[cfg(debug_assertions)]
        {
            // Dev server (apps/www runs on port 9779)
            "http://localhost:9779".to_string()
        }
        #[cfg(not(debug_assertions))]
        {
            // Production
            "https://cmux.sh".to_string()
        }
    })
}

/// Auth provider API base URL (for authentication endpoints)
fn get_auth_api_url() -> String {
    std::env::var("AUTH_API_URL").unwrap_or_else(|_| "https://api.stack-auth.com".to_string())
}

/// Auth project ID - dev for debug builds, prod for release builds
fn get_auth_project_id() -> String {
    std::env::var("STACK_PROJECT_ID").unwrap_or_else(|_| {
        #[cfg(debug_assertions)]
        {
            // Dev Stack Auth project
            "1467bed0-8522-45ee-a8d8-055de324118c".to_string()
        }
        #[cfg(not(debug_assertions))]
        {
            // Prod Stack Auth project
            "8a877114-b905-47c5-8b64-3a2d90679577".to_string()
        }
    })
}

/// Auth publishable client key - dev for debug builds, prod for release builds
fn get_auth_publishable_key() -> String {
    std::env::var("STACK_PUBLISHABLE_CLIENT_KEY").unwrap_or_else(|_| {
        #[cfg(debug_assertions)]
        {
            // Dev Stack Auth key
            "pck_pt4nwry6sdskews2pxk4g2fbe861ak2zvaf3mqendspa0".to_string()
        }
        #[cfg(not(debug_assertions))]
        {
            // Prod Stack Auth key
            "pck_8761mjjmyqc84e1e8ga3rn0k1nkggmggwa3pyzzgntv70".to_string()
        }
    })
}

/// CLI auth initiation response
#[derive(serde::Deserialize, Debug)]
struct CliAuthInitResponse {
    polling_code: String,
    login_code: String,
}

/// CLI auth poll response
#[derive(serde::Deserialize, Debug)]
struct CliAuthPollResponse {
    status: String,
    #[serde(default)]
    refresh_token: Option<String>,
}

/// Token refresh response
#[derive(serde::Deserialize, Debug)]
struct TokenRefreshResponse {
    access_token: String,
}

/// User info from Stack Auth
#[derive(serde::Deserialize, Debug)]
struct StackUserInfo {
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    display_name: Option<String>,
    #[serde(default)]
    primary_email: Option<String>,
}

/// SSH connection info from the cmux API
#[derive(serde::Deserialize, Debug)]
struct SandboxSshInfo {
    #[serde(rename = "morphInstanceId")]
    morph_instance_id: String,
    host: String,
    port: u16,
    user: String,
}

/// Stack Auth team info
#[derive(serde::Deserialize, Debug)]
#[allow(dead_code)]
struct StackTeam {
    id: String,
    #[serde(default, rename = "displayName")]
    display_name: Option<String>,
    #[serde(default, rename = "clientMetadata")]
    client_metadata: Option<serde_json::Value>,
}

/// Stack Auth teams list response
#[derive(serde::Deserialize, Debug)]
struct StackTeamsResponse {
    items: Vec<StackTeam>,
}

/// Custom error type for session expiry
#[derive(Debug)]
struct SessionExpiredError;

impl std::fmt::Display for SessionExpiredError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "Session expired or revoked. Please run 'cmux auth login' to re-authenticate."
        )
    }
}

impl std::error::Error for SessionExpiredError {}

/// Get an access token using the stored refresh token.
/// Uses caching to avoid unnecessary refresh calls (access tokens are valid for ~10 minutes).
/// Implements retry logic with exponential backoff for network resilience.
async fn get_access_token(client: &Client) -> anyhow::Result<String> {
    // Buffer time: refresh if token expires in less than 60 seconds
    const MIN_VALIDITY_SECS: i64 = 60;

    // Check cache first
    if let Some(cached_token) = get_cached_access_token(MIN_VALIDITY_SECS) {
        return Ok(cached_token);
    }

    // Need to refresh - get the refresh token
    let refresh_token = get_stack_refresh_token()
        .ok_or_else(|| anyhow::anyhow!("Not logged in. Run 'cmux auth login' first."))?;

    // Refresh the access token with retries
    let access_token = refresh_access_token_with_retry(client, &refresh_token).await?;

    // Cache the new token
    cache_access_token(&access_token);

    Ok(access_token)
}

/// Refresh access token with retry logic and proper error handling
async fn refresh_access_token_with_retry(
    client: &Client,
    refresh_token: &str,
) -> anyhow::Result<String> {
    let api_url = get_auth_api_url();
    let project_id = get_auth_project_id();
    let publishable_key = get_auth_publishable_key();
    let refresh_url = format!("{}/api/v1/auth/sessions/current/refresh", api_url);

    const MAX_RETRIES: u32 = 3;
    const INITIAL_DELAY_MS: u64 = 500;

    let mut last_error: Option<anyhow::Error> = None;

    for attempt in 0..MAX_RETRIES {
        if attempt > 0 {
            // Exponential backoff: 500ms, 1000ms, 2000ms
            let delay = INITIAL_DELAY_MS * (1 << (attempt - 1));
            tokio::time::sleep(Duration::from_millis(delay)).await;
        }

        let result = client
            .post(&refresh_url)
            .header("x-stack-project-id", &project_id)
            .header("x-stack-publishable-client-key", &publishable_key)
            .header("x-stack-access-type", "client")
            .header("x-stack-refresh-token", refresh_token)
            .send()
            .await;

        match result {
            Ok(response) => {
                let status = response.status();

                if status.is_success() {
                    let token_response: TokenRefreshResponse = response.json().await?;
                    return Ok(token_response.access_token);
                }

                let body = response.text().await.unwrap_or_default();

                // Check for session expired error - don't retry these
                if status == reqwest::StatusCode::UNAUTHORIZED
                    && body.contains("REFRESH_TOKEN_NOT_FOUND_OR_EXPIRED")
                {
                    // Clear any cached tokens and stored refresh token
                    clear_cached_access_token();
                    let _ = delete_stack_refresh_token();
                    return Err(SessionExpiredError.into());
                }

                // Server errors (5xx) are retryable
                if status.is_server_error() {
                    last_error = Some(anyhow::anyhow!(
                        "Server error refreshing token: {} - {}",
                        status,
                        body
                    ));
                    continue;
                }

                // Client errors (4xx other than 401 session expired) are not retryable
                return Err(anyhow::anyhow!(
                    "Failed to refresh token: {} - {}. Try 'cmux auth login' to re-authenticate.",
                    status,
                    body
                ));
            }
            Err(e) => {
                // Network errors are retryable
                if e.is_timeout() || e.is_connect() || e.is_request() {
                    last_error = Some(anyhow::anyhow!("Network error: {}", e));
                    continue;
                }
                // Other errors are not retryable
                return Err(e.into());
            }
        }
    }

    // All retries exhausted
    Err(last_error.unwrap_or_else(|| anyhow::anyhow!("Failed to refresh token after retries")))
}

/// Get the user's teams from Stack Auth
async fn get_user_teams(client: &Client, access_token: &str) -> anyhow::Result<Vec<StackTeam>> {
    let api_url = get_auth_api_url();
    let project_id = get_auth_project_id();
    let publishable_key = get_auth_publishable_key();

    let teams_url = format!("{}/api/v1/users/me/teams", api_url);
    let response = client
        .get(&teams_url)
        .header("x-stack-project-id", &project_id)
        .header("x-stack-publishable-client-key", &publishable_key)
        .header("x-stack-access-type", "client")
        .header("Authorization", format!("Bearer {}", access_token))
        .send()
        .await?;

    if !response.status().is_success() {
        let status = response.status();
        let text = response.text().await.unwrap_or_default();
        return Err(anyhow::anyhow!(
            "Failed to get teams: {} - {}",
            status,
            text
        ));
    }

    let teams_response: StackTeamsResponse = response.json().await?;
    Ok(teams_response.items)
}

/// Get SSH connection info for a sandbox from the cmux API
async fn get_sandbox_ssh_info(
    client: &Client,
    access_token: &str,
    sandbox_id: &str,
    team_slug_or_id: &str,
    base_url: &str,
) -> anyhow::Result<SandboxSshInfo> {
    let api_url = base_url;

    // URL-encode the query parameters
    let query: String = url::form_urlencoded::Serializer::new(String::new())
        .append_pair("teamSlugOrId", team_slug_or_id)
        .finish();
    let ssh_url = format!("{}/api/sandboxes/{}/ssh?{}", api_url, sandbox_id, query);

    let response = client
        .get(&ssh_url)
        .header("Authorization", format!("Bearer {}", access_token))
        .send()
        .await?;

    if !response.status().is_success() {
        let status = response.status();
        let text = response.text().await.unwrap_or_default();
        return Err(anyhow::anyhow!(
            "Failed to get SSH info: {} - {}",
            status,
            text
        ));
    }

    let ssh_info: SandboxSshInfo = response.json().await?;
    Ok(ssh_info)
}

/// Resolve the team to use - from explicit flag, env var, or first available team
async fn resolve_team(
    client: &Client,
    access_token: &str,
    explicit_team: Option<&str>,
) -> anyhow::Result<String> {
    // If explicitly provided, use that
    if let Some(team) = explicit_team {
        return Ok(team.to_string());
    }

    // Try to get the user's teams and use the first one
    let teams = get_user_teams(client, access_token).await?;

    if teams.is_empty() {
        return Err(anyhow::anyhow!(
            "No teams found. Create a team at https://cmux.sh or specify --team."
        ));
    }

    // Prefer teams with a slug in metadata
    for team in &teams {
        if let Some(metadata) = &team.client_metadata {
            if let Some(slug) = metadata.get("slug").and_then(|v| v.as_str()) {
                return Ok(slug.to_string());
            }
        }
    }

    // Fall back to the first team's ID
    Ok(teams[0].id.clone())
}

/// Handle `cmux auth login` - browser-based Stack Auth flow
async fn handle_auth_login() -> anyhow::Result<()> {
    let api_url = get_auth_api_url();
    let project_id = get_auth_project_id();
    let publishable_key = get_auth_publishable_key();

    // Check if already logged in
    if get_stack_refresh_token().is_some() {
        eprintln!("\x1b[33mYou are already logged in.\x1b[0m");
        eprintln!("Run 'cmux auth logout' first if you want to re-authenticate.");
        return Ok(());
    }

    eprintln!("Starting authentication...");

    let client = Client::builder().timeout(Duration::from_secs(30)).build()?;

    // Step 1: Initiate CLI auth flow
    let init_url = format!("{}/api/v1/auth/cli", api_url);
    let init_body = serde_json::json!({
        "expires_in_millis": 600000  // 10 minutes
    });

    let response = client
        .post(&init_url)
        .header("x-stack-project-id", &project_id)
        .header("x-stack-publishable-client-key", &publishable_key)
        .header("x-stack-access-type", "client")
        .header("Content-Type", "application/json")
        .json(&init_body)
        .send()
        .await?;

    if !response.status().is_success() {
        let status = response.status();
        let text = response.text().await.unwrap_or_default();
        return Err(anyhow::anyhow!(
            "Failed to initiate auth: {} - {}",
            status,
            text
        ));
    }

    let init_response: CliAuthInitResponse = response.json().await?;

    // Step 2: Open browser (use cmux.sh for browser URL, not auth API)
    let cmux_url = get_cmux_api_url();
    let auth_url = format!(
        "{}/handler/cli-auth-confirm?login_code={}",
        cmux_url, init_response.login_code
    );

    eprintln!("\nOpening browser to complete authentication...");
    eprintln!("If browser doesn't open, visit:\n  {}\n", auth_url);

    if let Err(e) = open::that(&auth_url) {
        eprintln!("Failed to open browser: {}", e);
        eprintln!("Please open the URL manually.");
    }

    // Step 3: Poll for completion
    eprintln!("Waiting for authentication... (press Ctrl+C to cancel)");

    let poll_url = format!("{}/api/v1/auth/cli/poll", api_url);
    let mut attempts = 0;
    let max_attempts = 120; // 10 minutes at 5 second intervals

    loop {
        attempts += 1;
        if attempts > max_attempts {
            return Err(anyhow::anyhow!("Authentication timed out"));
        }

        tokio::time::sleep(Duration::from_secs(5)).await;

        let poll_body = serde_json::json!({
            "polling_code": init_response.polling_code
        });

        let response = client
            .post(&poll_url)
            .header("x-stack-project-id", &project_id)
            .header("x-stack-publishable-client-key", &publishable_key)
            .header("x-stack-access-type", "client")
            .header("Content-Type", "application/json")
            .json(&poll_body)
            .send()
            .await;

        let response = match response {
            Ok(r) => r,
            Err(e) => {
                eprintln!("Poll request failed: {}. Retrying...", e);
                continue;
            }
        };

        if !response.status().is_success() {
            // Keep polling on non-success (could be pending)
            continue;
        }

        let poll_response: CliAuthPollResponse = match response.json().await {
            Ok(r) => r,
            Err(_) => continue,
        };

        match poll_response.status.as_str() {
            "success" => {
                if let Some(refresh_token) = poll_response.refresh_token {
                    // Store the refresh token
                    store_stack_refresh_token(&refresh_token)
                        .map_err(|e| anyhow::anyhow!("Failed to store token: {}", e))?;

                    eprintln!("\n\x1b[32m✓ Authentication successful!\x1b[0m");
                    eprintln!("  Refresh token stored securely.");

                    // Try to get user info
                    if let Ok(user_info) = get_user_info(&client, &refresh_token).await {
                        if let Some(email) = user_info.primary_email {
                            eprintln!("  Logged in as: {}", email);
                        } else if let Some(name) = user_info.display_name {
                            eprintln!("  Logged in as: {}", name);
                        }
                    }

                    return Ok(());
                } else {
                    return Err(anyhow::anyhow!(
                        "Authentication succeeded but no refresh token returned"
                    ));
                }
            }
            "expired" => {
                return Err(anyhow::anyhow!("Authentication expired. Please try again."));
            }
            _ => {
                // Still pending, continue polling
                eprint!(".");
            }
        }
    }
}

/// Get user info using a refresh token
async fn get_user_info(client: &Client, refresh_token: &str) -> anyhow::Result<StackUserInfo> {
    let api_url = get_auth_api_url();
    let project_id = get_auth_project_id();
    let publishable_key = get_auth_publishable_key();

    // First get an access token
    let refresh_url = format!("{}/api/v1/auth/sessions/current/refresh", api_url);
    let response = client
        .post(&refresh_url)
        .header("x-stack-project-id", &project_id)
        .header("x-stack-publishable-client-key", &publishable_key)
        .header("x-stack-access-type", "client")
        .header("x-stack-refresh-token", refresh_token)
        .send()
        .await?;

    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        return Err(anyhow::anyhow!(
            "Failed to refresh token: {} - {}",
            status,
            body
        ));
    }

    let token_response: TokenRefreshResponse = response.json().await?;

    // Now get user info
    let user_url = format!("{}/api/v1/users/me", api_url);
    let response = client
        .get(&user_url)
        .header("x-stack-project-id", &project_id)
        .header("x-stack-publishable-client-key", &publishable_key)
        .header("x-stack-access-type", "client")
        .header("x-stack-access-token", &token_response.access_token)
        .send()
        .await?;

    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        return Err(anyhow::anyhow!(
            "Failed to get user info: {} - {}",
            status,
            body
        ));
    }

    let user_info: StackUserInfo = response.json().await?;
    Ok(user_info)
}

/// Handle `cmux auth logout` - clear stored credentials
fn handle_auth_logout() -> anyhow::Result<()> {
    let had_token = get_stack_refresh_token().is_some();

    // Clear both refresh token and cached access token
    delete_stack_refresh_token().map_err(|e| anyhow::anyhow!("Failed to delete token: {}", e))?;
    clear_cached_access_token();

    if had_token {
        eprintln!("\x1b[32m✓ Logged out successfully.\x1b[0m");
    } else {
        eprintln!("No credentials found. Already logged out.");
    }

    Ok(())
}

/// Handle `cmux auth status` - show current auth state and files
async fn handle_auth_status() -> anyhow::Result<()> {
    // Show auth status
    println!("\x1b[1mAuthentication Status:\x1b[0m");

    if let Some(refresh_token) = get_stack_refresh_token() {
        let client = Client::builder().timeout(Duration::from_secs(10)).build()?;

        match get_user_info(&client, &refresh_token).await {
            Ok(user_info) => {
                println!("  Status: \x1b[32mLogged in\x1b[0m");
                if let Some(email) = user_info.primary_email {
                    println!("  Email: {}", email);
                }
                if let Some(name) = user_info.display_name {
                    println!("  Name: {}", name);
                }
                if let Some(id) = user_info.id {
                    println!("  User ID: {}", id);
                }
            }
            Err(e) => {
                println!("  Status: \x1b[33mSession expired or invalid\x1b[0m");
                println!("  Error: {}", e);
                println!("  Try 'cmux auth login' to re-authenticate.");
            }
        }
    } else {
        println!("  Status: \x1b[90mNot logged in\x1b[0m");
        println!("  Run 'cmux auth login' to authenticate.");
    }

    // Show auth files status
    println!("\n\x1b[1mAuthentication Files:\x1b[0m");
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
    let home_path = PathBuf::from(home);

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

    Ok(())
}

/// Handle `cmux auth token` - print current access token
async fn handle_auth_token() -> anyhow::Result<()> {
    let refresh_token = get_stack_refresh_token()
        .ok_or_else(|| anyhow::anyhow!("Not logged in. Run 'cmux auth login' first."))?;

    let api_url = get_auth_api_url();
    let project_id = get_auth_project_id();
    let publishable_key = get_auth_publishable_key();

    let client = Client::builder().timeout(Duration::from_secs(10)).build()?;

    let refresh_url = format!("{}/api/v1/auth/sessions/current/refresh", api_url);
    let response = client
        .post(&refresh_url)
        .header("x-stack-project-id", &project_id)
        .header("x-stack-publishable-client-key", &publishable_key)
        .header("x-stack-access-type", "client")
        .header("x-stack-refresh-token", &refresh_token)
        .send()
        .await?;

    if !response.status().is_success() {
        let status = response.status();
        let text = response.text().await.unwrap_or_default();
        return Err(anyhow::anyhow!(
            "Failed to refresh token: {} - {}. Try 'cmux auth login' to re-authenticate.",
            status,
            text
        ));
    }

    let token_response: TokenRefreshResponse = response.json().await?;

    // Print just the token (useful for piping)
    println!("{}", token_response.access_token);

    Ok(())
}

// =============================================================================
// SSH Keys Management
// =============================================================================

/// Response type for SSH key listing
#[derive(serde::Deserialize, Debug)]
struct SshKeyInfo {
    id: String,
    name: String,
    fingerprint: String,
    source: String,
    #[serde(rename = "createdAt")]
    created_at: i64,
}

/// Response type for SSH key creation
#[derive(serde::Deserialize, Debug)]
struct CreateSshKeyResponse {
    id: String,
    fingerprint: String,
}

/// Response type for GitHub import
#[derive(serde::Deserialize, Debug)]
struct ImportGithubKeysResponse {
    imported: u32,
    keys: Vec<CreateSshKeyResponse>,
}

/// Compute SSH key fingerprint from a public key string.
/// Format: 'SHA256:base64...'
fn compute_ssh_fingerprint(public_key: &str) -> anyhow::Result<String> {
    // SSH public key format: "type base64-blob comment"
    let parts: Vec<&str> = public_key.split_whitespace().collect();
    if parts.len() < 2 {
        return Err(anyhow::anyhow!("Invalid SSH public key format"));
    }

    let key_type = parts[0];
    let key_blob = parts[1];

    // Validate key type
    let valid_types = [
        "ssh-rsa",
        "ssh-dss",
        "ssh-ed25519",
        "ecdsa-sha2-nistp256",
        "ecdsa-sha2-nistp384",
        "ecdsa-sha2-nistp521",
        "sk-ssh-ed25519@openssh.com",
        "sk-ecdsa-sha2-nistp256@openssh.com",
    ];

    if !valid_types.contains(&key_type) {
        return Err(anyhow::anyhow!("Unsupported SSH key type: {}", key_type));
    }

    // Decode base64 blob and compute SHA256 hash
    let binary_data = BASE64
        .decode(key_blob)
        .map_err(|_| anyhow::anyhow!("Invalid base64 in SSH public key"))?;

    let mut hasher = Sha256::new();
    hasher.update(&binary_data);
    let hash = hasher.finalize();

    // Convert to base64 without padding (matches ssh-keygen output)
    let base64_hash = BASE64.encode(hash);
    let base64_hash = base64_hash.trim_end_matches('=');

    Ok(format!("SHA256:{}", base64_hash))
}

/// Find an SSH public key file in the default locations
fn find_ssh_public_key() -> Option<PathBuf> {
    let home = std::env::var("HOME").ok()?;
    let ssh_dir = PathBuf::from(home).join(".ssh");

    // Check common key types in order of preference
    let key_files = ["id_ed25519.pub", "id_rsa.pub", "id_ecdsa.pub"];

    for key_file in key_files {
        let path = ssh_dir.join(key_file);
        if path.exists() {
            return Some(path);
        }
    }

    None
}

/// Get the hostname for default key name
fn get_hostname() -> String {
    std::env::var("HOSTNAME")
        .or_else(|_| std::env::var("HOST"))
        .or_else(|_| {
            std::process::Command::new("hostname")
                .output()
                .ok()
                .and_then(|output| {
                    if output.status.success() {
                        String::from_utf8(output.stdout)
                            .ok()
                            .map(|s| s.trim().to_string())
                    } else {
                        None
                    }
                })
                .ok_or(std::env::VarError::NotPresent)
        })
        .unwrap_or_else(|_| "my-laptop".to_string())
}

/// Format a timestamp as a human-readable relative time
fn format_relative_time(timestamp_ms: i64) -> String {
    let now = chrono::Utc::now().timestamp_millis();
    let diff_secs = (now - timestamp_ms) / 1000;

    if diff_secs < 60 {
        "just now".to_string()
    } else if diff_secs < 3600 {
        let mins = diff_secs / 60;
        format!("{} minute{} ago", mins, if mins == 1 { "" } else { "s" })
    } else if diff_secs < 86400 {
        let hours = diff_secs / 3600;
        format!("{} hour{} ago", hours, if hours == 1 { "" } else { "s" })
    } else {
        let days = diff_secs / 86400;
        format!("{} day{} ago", days, if days == 1 { "" } else { "s" })
    }
}

/// Handle `cmux ssh-keys list` - list registered SSH keys
async fn handle_ssh_keys_list() -> anyhow::Result<()> {
    let client = Client::builder().timeout(Duration::from_secs(30)).build()?;
    let access_token = get_access_token(&client).await?;
    let api_url = get_cmux_api_url();

    let url = format!("{}/api/user/ssh-keys", api_url);
    let response = client
        .get(&url)
        .header("Authorization", format!("Bearer {}", access_token))
        .send()
        .await?;

    if !response.status().is_success() {
        let status = response.status();
        let text = response.text().await.unwrap_or_default();
        return Err(anyhow::anyhow!(
            "Failed to list SSH keys: {} - {}",
            status,
            text
        ));
    }

    let keys: Vec<SshKeyInfo> = response.json().await?;

    if keys.is_empty() {
        println!("No SSH keys registered.");
        println!("\nAdd a key with: cmux ssh-keys add");
        return Ok(());
    }

    // Print header
    println!(
        "{:<20} {:<45} {:<10} CREATED",
        "NAME", "FINGERPRINT", "SOURCE"
    );
    println!("{}", "-".repeat(90));

    // Print keys
    for key in keys {
        // Truncate fingerprint for display
        let fingerprint_display = if key.fingerprint.len() > 43 {
            format!("{}...", &key.fingerprint[..40])
        } else {
            key.fingerprint.clone()
        };

        println!(
            "{:<20} {:<45} {:<10} {}",
            truncate_string(&key.name, 18),
            fingerprint_display,
            key.source,
            format_relative_time(key.created_at)
        );
    }

    Ok(())
}

/// Truncate a string to fit in a column
fn truncate_string(s: &str, max_len: usize) -> String {
    if s.len() <= max_len {
        s.to_string()
    } else {
        format!("{}...", &s[..max_len.saturating_sub(3)])
    }
}

/// Handle `cmux ssh-keys add` - add an SSH key
async fn handle_ssh_keys_add(args: SshKeysAddArgs) -> anyhow::Result<()> {
    // Handle --from-github flag
    if args.from_github {
        return handle_ssh_keys_import_github().await;
    }

    // Get the public key file path
    let key_path = match args.path {
        Some(path) => {
            if !path.exists() {
                return Err(anyhow::anyhow!(
                    "SSH public key file not found: {}",
                    path.display()
                ));
            }
            path
        }
        None => find_ssh_public_key().ok_or_else(|| {
            anyhow::anyhow!(
                "No SSH public key found.\n\
                     \n\
                     Looked in ~/.ssh/ for: id_ed25519.pub, id_rsa.pub, id_ecdsa.pub\n\
                     \n\
                     Generate a new key with: ssh-keygen -t ed25519\n\
                     Or specify a path: cmux ssh-keys add /path/to/key.pub"
            )
        })?,
    };

    eprintln!("Found SSH public key at {}", key_path.display());

    // Read the public key
    let public_key = std::fs::read_to_string(&key_path)
        .map_err(|e| anyhow::anyhow!("Failed to read SSH key: {}", e))?;
    let public_key = public_key.trim();

    // Compute fingerprint
    let fingerprint = compute_ssh_fingerprint(public_key)?;
    eprintln!("Fingerprint: {}", fingerprint);

    // Get key name
    let key_name = if let Some(name) = args.name {
        name
    } else {
        let default_name = get_hostname();
        eprintln!();

        // Use dialoguer for interactive prompt
        use dialoguer::Input;
        let name: String = Input::new()
            .with_prompt("Key name")
            .default(default_name)
            .interact_text()?;
        name
    };

    // Get access token and make API request
    let client = Client::builder().timeout(Duration::from_secs(30)).build()?;
    let access_token = get_access_token(&client).await?;
    let api_url = get_cmux_api_url();

    let url = format!("{}/api/user/ssh-keys", api_url);
    let body = serde_json::json!({
        "publicKey": public_key,
        "name": key_name
    });

    let response = client
        .post(&url)
        .header("Authorization", format!("Bearer {}", access_token))
        .header("Content-Type", "application/json")
        .json(&body)
        .send()
        .await?;

    let status = response.status();
    if !status.is_success() {
        let text = response.text().await.unwrap_or_default();
        if status.as_u16() == 409 {
            return Err(anyhow::anyhow!(
                "SSH key with this fingerprint already exists"
            ));
        }
        return Err(anyhow::anyhow!(
            "Failed to add SSH key: {} - {}",
            status,
            text
        ));
    }

    let result: CreateSshKeyResponse = response.json().await?;

    eprintln!("\n\x1b[32m✓ SSH key registered successfully\x1b[0m");
    eprintln!("  ID: {}", result.id);
    eprintln!("  Fingerprint: {}", result.fingerprint);

    Ok(())
}

/// Handle `cmux ssh-keys add --from-github` - import keys from GitHub
async fn handle_ssh_keys_import_github() -> anyhow::Result<()> {
    eprintln!("Importing SSH keys from connected GitHub account...");

    let client = Client::builder().timeout(Duration::from_secs(30)).build()?;
    let access_token = get_access_token(&client).await?;
    let api_url = get_cmux_api_url();

    let url = format!("{}/api/user/ssh-keys/import-github", api_url);
    let response = client
        .post(&url)
        .header("Authorization", format!("Bearer {}", access_token))
        .send()
        .await?;

    let status = response.status();
    if !status.is_success() {
        let text = response.text().await.unwrap_or_default();
        if status.as_u16() == 400 && text.contains("not connected") {
            return Err(anyhow::anyhow!(
                "GitHub account not connected.\n\
                 \n\
                 Please connect your GitHub account at https://cmux.sh/settings"
            ));
        }
        return Err(anyhow::anyhow!(
            "Failed to import GitHub keys: {} - {}",
            status,
            text
        ));
    }

    let result: ImportGithubKeysResponse = response.json().await?;

    if result.imported == 0 {
        eprintln!("\x1b[33mNo new keys to import.\x1b[0m");
        eprintln!("Either you have no SSH keys on GitHub or they're already registered.");
    } else {
        eprintln!(
            "\n\x1b[32m✓ Imported {} SSH key{} from GitHub\x1b[0m",
            result.imported,
            if result.imported == 1 { "" } else { "s" }
        );
        for key in &result.keys {
            eprintln!("  • {}", key.fingerprint);
        }
    }

    Ok(())
}

/// Handle `cmux ssh-keys remove` - remove an SSH key
async fn handle_ssh_keys_remove(fingerprint_or_id: &str) -> anyhow::Result<()> {
    let client = Client::builder().timeout(Duration::from_secs(30)).build()?;
    let access_token = get_access_token(&client).await?;
    let api_url = get_cmux_api_url();

    // First, list keys to find the one to delete
    let list_url = format!("{}/api/user/ssh-keys", api_url);
    let list_response = client
        .get(&list_url)
        .header("Authorization", format!("Bearer {}", access_token))
        .send()
        .await?;

    if !list_response.status().is_success() {
        let status = list_response.status();
        let text = list_response.text().await.unwrap_or_default();
        return Err(anyhow::anyhow!(
            "Failed to list SSH keys: {} - {}",
            status,
            text
        ));
    }

    let keys: Vec<SshKeyInfo> = list_response.json().await?;

    // Find the key by fingerprint or ID
    let key_to_delete = keys.iter().find(|k| {
        k.id == fingerprint_or_id
            || k.fingerprint == fingerprint_or_id
            || k.fingerprint.ends_with(fingerprint_or_id)
    });

    let key = match key_to_delete {
        Some(k) => k,
        None => {
            return Err(anyhow::anyhow!(
                "SSH key not found: {}\n\
                 \n\
                 Use 'cmux ssh-keys list' to see registered keys.",
                fingerprint_or_id
            ));
        }
    };

    // Delete the key
    let delete_url = format!("{}/api/user/ssh-keys/{}", api_url, key.id);
    let delete_response = client
        .delete(&delete_url)
        .header("Authorization", format!("Bearer {}", access_token))
        .send()
        .await?;

    if !delete_response.status().is_success() {
        let status = delete_response.status();
        let text = delete_response.text().await.unwrap_or_default();
        return Err(anyhow::anyhow!(
            "Failed to delete SSH key: {} - {}",
            status,
            text
        ));
    }

    eprintln!("\x1b[32m✓ SSH key removed: {}\x1b[0m", key.name);
    eprintln!("  Fingerprint: {}", key.fingerprint);

    Ok(())
}

/// Response from the setup-instance endpoint
#[derive(serde::Deserialize, Debug)]
#[serde(rename_all = "camelCase")]
struct SetupInstanceResponse {
    instance_id: String,
    vscode_url: String,
    cloned_repos: Vec<String>,
    removed_repos: Vec<String>,
}

/// Handle `cmux vm create` - create a new cloud VM
async fn handle_vm_create(args: VmCreateArgs) -> anyhow::Result<()> {
    let client = Client::builder()
        .timeout(Duration::from_secs(120))
        .build()?;
    let access_token = get_access_token(&client).await?;
    let api_url = get_cmux_api_url();

    // Build the request body
    let mut body = serde_json::json!({
        "ttlSeconds": args.ttl,
        "teamSlugOrId": args.team,
    });

    if let Some(preset) = &args.preset {
        body["presetId"] = serde_json::json!(preset);
    }

    if !args.repos.is_empty() {
        body["repos"] = serde_json::json!(args.repos);
    }

    eprintln!("Creating cloud VM...");

    let url = format!("{}/api/morph/setup-instance", api_url);
    let response = client
        .post(&url)
        .header("Authorization", format!("Bearer {}", access_token))
        .json(&body)
        .send()
        .await?;

    if !response.status().is_success() {
        let status = response.status();
        let text = response.text().await.unwrap_or_default();
        return Err(anyhow::anyhow!(
            "Failed to create VM: {} - {} (url: {})",
            status,
            text,
            url
        ));
    }

    let result: SetupInstanceResponse = response.json().await?;

    if args.output == "json" {
        println!(
            "{}",
            serde_json::to_string_pretty(&serde_json::json!({
                "instanceId": result.instance_id,
                "vscodeUrl": result.vscode_url,
                "clonedRepos": result.cloned_repos,
                "removedRepos": result.removed_repos,
            }))?
        );
    } else {
        eprintln!("\x1b[32m✓ VM created successfully!\x1b[0m");
        eprintln!();
        eprintln!("  Instance ID: {}", result.instance_id);
        eprintln!("  VS Code URL: {}", result.vscode_url);
        if !result.cloned_repos.is_empty() {
            eprintln!("  Cloned repos: {}", result.cloned_repos.join(", "));
        }
        eprintln!();
        eprintln!("Connect via SSH:");
        eprintln!("  cmux ssh {}", result.instance_id);
    }

    Ok(())
}

/// Handle `cmux vm list` - list running VMs
async fn handle_vm_list(args: VmListArgs) -> anyhow::Result<()> {
    let client = Client::builder().timeout(Duration::from_secs(30)).build()?;
    let access_token = get_access_token(&client).await?;
    let api_url = get_cmux_api_url();

    // Build query params
    let mut url = format!("{}/api/morph/instances", api_url);
    if let Some(team) = &args.team {
        url = format!("{}?teamId={}", url, team);
    }

    let response = client
        .get(&url)
        .header("Authorization", format!("Bearer {}", access_token))
        .send()
        .await?;

    if !response.status().is_success() {
        let status = response.status();
        let text = response.text().await.unwrap_or_default();
        return Err(anyhow::anyhow!(
            "Failed to list VMs: {} - {} (url: {})",
            status,
            text,
            url
        ));
    }

    let instances: serde_json::Value = response.json().await?;

    if args.output == "json" {
        println!("{}", serde_json::to_string_pretty(&instances)?);
    } else {
        let empty_vec = vec![];
        let instances_arr = instances.as_array().unwrap_or(&empty_vec);
        if instances_arr.is_empty() {
            println!("No running VMs found.");
            println!("\nCreate a VM with: cmux vm create");
            return Ok(());
        }

        // Print header
        println!("{:<20} {:<12} {:<40}", "INSTANCE ID", "STATUS", "CREATED");
        println!("{}", "-".repeat(75));

        for instance in instances_arr {
            let id = instance["id"].as_str().unwrap_or("unknown");
            let status = instance["status"].as_str().unwrap_or("unknown");
            let created = instance["createdAt"].as_str().unwrap_or("unknown");
            println!("{:<20} {:<12} {:<40}", id, status, created);
        }
    }

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

async fn handle_onboard() -> anyhow::Result<()> {
    let is_debug = is_dmux();
    let image_name = if is_debug {
        DMUX_DEFAULT_IMAGE
    } else {
        DEFAULT_IMAGE
    };
    let binary_name = if is_debug { "dmux" } else { "cmux" };

    println!("\x1b[1m{} Onboarding\x1b[0m\n", binary_name);

    // Step 1: Check Docker is installed and running
    print!("Checking Docker... ");
    let docker_check = tokio::process::Command::new("docker")
        .args(["info"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .await;

    match docker_check {
        Ok(status) if status.success() => {
            println!("\x1b[32m✓ Docker is running\x1b[0m");
        }
        Ok(_) => {
            println!("\x1b[31m✗ Docker is not running\x1b[0m");
            eprintln!("\nPlease start Docker Desktop or the Docker daemon and try again.");
            return Err(anyhow::anyhow!("Docker is not running"));
        }
        Err(_) => {
            println!("\x1b[31m✗ Docker not found\x1b[0m");
            eprintln!("\nPlease install Docker: https://docs.docker.com/get-docker/");
            return Err(anyhow::anyhow!("Docker is not installed"));
        }
    }

    // Step 2: Check if sandbox image exists locally
    print!("Checking for sandbox image '{}'... ", image_name);
    let image_check = tokio::process::Command::new("docker")
        .args(["images", "-q", image_name])
        .output()
        .await?;

    let image_exists = !image_check.stdout.is_empty();

    if image_exists {
        println!("\x1b[32m✓ Found\x1b[0m");
        println!("\n\x1b[32m✓ Onboarding complete!\x1b[0m");
        println!("\nYou can now start the sandbox server with:");
        println!("\n  \x1b[36m{} start\x1b[0m\n", binary_name);
        return Ok(());
    }

    println!("\x1b[33m✗ Not found\x1b[0m");

    // Step 3: Prompt user to pull/build the image
    if is_debug {
        // For dmux, we build locally since it's dev mode
        println!("\n\x1b[33mNote:\x1b[0m dmux uses a locally-built image for development.");
        println!("To build the image, run from the cmux2 root directory:");
        println!("\n  \x1b[36m./scripts/dev.sh --force-docker-build\x1b[0m\n");
        println!("Or build just the sandbox image:");
        println!("\n  \x1b[36mcd packages/sandbox && ./scripts/reload.sh\x1b[0m\n");
    } else {
        // For cmux, offer to pull from GHCR
        println!("\nThe sandbox image needs to be downloaded (~2GB).");
        print!("Would you like to download it now? [Y/n] ");
        use std::io::Write;
        std::io::stdout().flush()?;

        let mut input = String::new();
        std::io::stdin().read_line(&mut input)?;
        let input = input.trim().to_lowercase();

        if input.is_empty() || input == "y" || input == "yes" {
            println!("\nPulling sandbox image from ghcr.io...\n");

            let pull_status = tokio::process::Command::new("docker")
                .args(["pull", image_name])
                .status()
                .await?;

            if pull_status.success() {
                println!("\n\x1b[32m✓ Image downloaded successfully!\x1b[0m");
                println!("\n\x1b[32m✓ Onboarding complete!\x1b[0m");
                println!("\nYou can now start the sandbox server with:");
                println!("\n  \x1b[36m{} start\x1b[0m\n", binary_name);
            } else {
                eprintln!("\n\x1b[31m✗ Failed to pull image\x1b[0m");
                eprintln!("\nPlease check your network connection and try again.");
                eprintln!("If the image is not yet published, you may need to build it locally:");
                eprintln!("\n  \x1b[36mcd packages/sandbox && ./scripts/reload.sh\x1b[0m\n");
                return Err(anyhow::anyhow!("Failed to pull Docker image"));
            }
        } else {
            println!("\nSkipping image download. You can download it later with:");
            println!("\n  \x1b[36mdocker pull {}\x1b[0m\n", image_name);
        }
    }

    Ok(())
}

/// Handle real SSH to a sandbox (via direct TCP to Morph)
async fn handle_real_ssh(client: &Client, base_url: &str, args: &SshArgs) -> anyhow::Result<()> {
    let binary_name = if is_dmux() { "dmux" } else { "cmux" };

    // Get access token and resolve team
    eprintln!("Authenticating...");
    let access_token = get_access_token(client).await?;
    let team = resolve_team(client, &access_token, args.team.as_deref()).await?;

    // Verify we can get SSH info for this sandbox (validates sandbox exists and is accessible)
    eprintln!("Resolving sandbox {}...", args.id);
    let ssh_info = get_sandbox_ssh_info(client, &access_token, &args.id, &team, base_url).await?;
    eprintln!(
        "Connecting to {} ({}:{})...",
        ssh_info.morph_instance_id, ssh_info.host, ssh_info.port
    );

    // Build SSH command with ProxyCommand using our _ssh-proxy
    // Pass the team and base_url to the proxy command so it can authenticate
    let mut ssh_args = vec![
        "-o".to_string(),
        "StrictHostKeyChecking=no".to_string(),
        "-o".to_string(),
        "UserKnownHostsFile=/dev/null".to_string(),
        "-o".to_string(),
        "LogLevel=ERROR".to_string(),
        "-o".to_string(),
        format!(
            "ProxyCommand={} _ssh-proxy {} --team {} --base-url {}",
            binary_name, args.id, team, base_url
        ),
    ];

    // The hostname (doesn't matter since we use ProxyCommand, but SSH requires one)
    // Must come before any remote command
    ssh_args.push(format!(
        "{}@sandbox-{}",
        ssh_info.user, ssh_info.morph_instance_id
    ));

    // Add any extra SSH args from user (typically remote commands to execute)
    for arg in &args.ssh_args {
        ssh_args.push(arg.clone());
    }

    // Execute native SSH with ProxyCommand
    // Use exec on Unix to replace process and fully inherit terminal for passphrase prompts
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        let err = std::process::Command::new("ssh").args(&ssh_args).exec();
        // exec only returns on error
        Err(anyhow::anyhow!("Failed to exec ssh: {}", err))
    }

    #[cfg(not(unix))]
    {
        let status = std::process::Command::new("ssh").args(&ssh_args).status()?;
        if !status.success() {
            return Err(anyhow::anyhow!("SSH connection failed"));
        }
        Ok(())
    }
}

/// Execute a command on a sandbox via SSH (non-interactive)
///
/// This is designed for scripting and automation. Unlike `ssh`, this command:
/// - Does not allocate a PTY by default
/// - Suppresses connection status messages
/// - Properly propagates the exit code of the remote command
async fn handle_ssh_exec(
    client: &Client,
    base_url: &str,
    args: &SshExecArgs,
) -> anyhow::Result<()> {
    let binary_name = if is_dmux() { "dmux" } else { "cmux" };

    // Get access token and resolve team
    let access_token = get_access_token(client).await?;
    let team = resolve_team(client, &access_token, args.team.as_deref()).await?;

    // Verify we can get SSH info for this sandbox
    let ssh_info = get_sandbox_ssh_info(client, &access_token, &args.id, &team, base_url).await?;

    // Build SSH command with ProxyCommand using our _ssh-proxy
    // Use -T to disable pseudo-terminal allocation (non-interactive)
    // Use -o BatchMode=yes to prevent password prompts
    let mut ssh_args = vec![
        "-T".to_string(), // Disable pseudo-terminal allocation
        "-o".to_string(),
        "BatchMode=yes".to_string(),
        "-o".to_string(),
        "StrictHostKeyChecking=no".to_string(),
        "-o".to_string(),
        "UserKnownHostsFile=/dev/null".to_string(),
        "-o".to_string(),
        "LogLevel=ERROR".to_string(),
        "-o".to_string(),
        format!(
            "ProxyCommand={} _ssh-proxy {} --team {} --base-url {}",
            binary_name, args.id, team, base_url
        ),
    ];

    // The hostname (doesn't matter since we use ProxyCommand, but SSH requires one)
    ssh_args.push(format!(
        "{}@sandbox-{}",
        ssh_info.user, ssh_info.morph_instance_id
    ));

    // Add the command to execute
    // Join command parts into a single string for remote execution
    let remote_cmd = args.command.join(" ");
    ssh_args.push(remote_cmd);

    // Execute SSH and capture exit code
    let status = std::process::Command::new("ssh").args(&ssh_args).status()?;

    if !status.success() {
        std::process::exit(status.code().unwrap_or(1));
    }

    Ok(())
}

/// Generate SSH config for easy sandbox access
async fn handle_ssh_config(_client: &Client, _base_url: &str) -> anyhow::Result<()> {
    let binary_name = if is_dmux() { "dmux" } else { "cmux" };

    println!("# SSH config for {} sandboxes", binary_name);
    println!("# Add this to ~/.ssh/config");
    println!();
    println!("# NOTE: Set CMUX_TEAM environment variable or the proxy will use your default team");
    println!("# Example: export CMUX_TEAM=my-team");
    println!();

    // Generate a wildcard config for sandbox-* pattern using _ssh-proxy
    println!("# Wildcard config for all sandboxes (works from macOS shell)");
    println!("Host sandbox-*");
    println!("    User root");
    println!("    StrictHostKeyChecking no");
    println!("    UserKnownHostsFile /dev/null");
    println!("    LogLevel ERROR");
    println!(
        "    ProxyCommand {} _ssh-proxy $(echo %n | sed 's/sandbox-//')",
        binary_name
    );
    println!();

    eprintln!();
    eprintln!("Usage examples:");
    eprintln!("  ssh sandbox-morphvm_xxx                   # SSH using Morph instance ID");
    eprintln!("  ssh sandbox-morphvm_xxx -L 8080:localhost:8080  # With port forwarding");
    eprintln!("  scp sandbox-morphvm_xxx:/workspace/file ./      # Copy files");
    eprintln!("  rsync -avz sandbox-morphvm_xxx:/workspace/ ./   # Rsync with sandbox");
    eprintln!();
    eprintln!("Or use '{}' directly:", binary_name);
    eprintln!(
        "  {} ssh <sandbox-id>                         # Direct SSH (uses default team)",
        binary_name
    );
    eprintln!(
        "  {} ssh <sandbox-id> --team my-team          # With explicit team",
        binary_name
    );
    eprintln!(
        "  {} ssh <sandbox-id> -L 8080:localhost:8080  # With port forwarding",
        binary_name
    );

    Ok(())
}

/// Internal SSH proxy command - bridges stdin/stdout to direct TCP to Morph SSH gateway
/// This is used as SSH ProxyCommand to route SSH through the Morph gateway
async fn handle_ssh_proxy(id: &str, team: Option<&str>, base_url: &str) -> anyhow::Result<()> {
    // Create a client for API calls
    let client = Client::builder().timeout(Duration::from_secs(30)).build()?;

    // Get access token and resolve team
    let access_token = get_access_token(&client).await?;
    let team = resolve_team(&client, &access_token, team).await?;

    // Get SSH connection info from the API
    let ssh_info = get_sandbox_ssh_info(&client, &access_token, id, &team, base_url).await?;

    // The Morph SSH gateway expects connections with the instance ID as the username
    // Format: ssh -p 22222 morphvm_xxx@ssh.cloud.morph.so
    // But since we're acting as a ProxyCommand, we just open the TCP connection
    // and the SSH client will handle the protocol
    let address = format!("{}:{}", ssh_info.host, ssh_info.port);

    // Connect to Morph SSH gateway
    let mut stream = tokio::net::TcpStream::connect(&address)
        .await
        .map_err(|e| anyhow::anyhow!("Failed to connect to SSH gateway {}: {}", address, e))?;

    let (mut read_half, mut write_half) = stream.split();
    let mut stdin = tokio::io::stdin();
    let mut stdout = tokio::io::stdout();

    // Bridge stdin/stdout to TCP socket
    let stdin_to_tcp = async {
        let mut buf = [0u8; 8192];
        loop {
            match stdin.read(&mut buf).await {
                Ok(0) => break,
                Ok(n) => {
                    if write_half.write_all(&buf[..n]).await.is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    };

    let tcp_to_stdout = async {
        let mut buf = [0u8; 8192];
        loop {
            match read_half.read(&mut buf).await {
                Ok(0) => break,
                Ok(n) => {
                    if stdout.write_all(&buf[..n]).await.is_err() {
                        break;
                    }
                    if stdout.flush().await.is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    };

    tokio::select! {
        _ = stdin_to_tcp => {}
        _ = tcp_to_stdout => {}
    }

    Ok(())
}

const ESCTEST2_REPO: &str = "https://github.com/ThomasDickey/esctest2.git";
const ESCTEST2_PATH: &str = "/workspace/tools/esctest2";

async fn handle_esctest(client: &Client, base_url: &str, args: EsctestArgs) -> anyhow::Result<()> {
    // Always create a new sandbox for esctest
    eprintln!("Creating new sandbox for esctest...");
    let body = CreateSandboxRequest {
        name: Some("esctest".into()),
        workspace: None,
        tab_id: Some(Uuid::new_v4().to_string()),
        read_only_paths: vec![],
        tmpfs: vec![],
        env: build_default_env_vars(),
    };
    let url = format!("{}/sandboxes", base_url.trim_end_matches('/'));
    let response = client.post(url).json(&body).send().await?;
    let summary: SandboxSummary = parse_response(response).await?;
    let target_id = summary.id.to_string();
    eprintln!("Created sandbox {}", target_id);

    // Install esctest2
    eprintln!("Installing esctest2 in sandbox...");
    setup_esctest2(client, base_url, &target_id).await?;
    eprintln!("\x1b[32m✓ esctest2 installed\x1b[0m\n");

    // Handle --list flag
    if args.list {
        let list_cmd = format!(
            "cd {}/esctest && grep -h 'def test_' tests/*.py | sed 's/.*def //' | sed 's/(self).*//' | grep -E '{}' | sort",
            ESCTEST2_PATH, args.pattern
        );
        let result = exec_in_sandbox(
            client,
            base_url,
            &target_id,
            &["/bin/sh", "-c", &list_cmd],
            None,
        )
        .await?;
        println!("{}", result.stdout);
        return Ok(());
    }

    // Run tests
    eprintln!(
        "Running esctest2 (pattern='{}', timeout={}s)...\n",
        args.pattern, args.timeout
    );

    run_esctest_noninteractive(client, base_url, &target_id, &args).await?;

    Ok(())
}

async fn setup_esctest2(client: &Client, base_url: &str, sandbox_id: &str) -> anyhow::Result<()> {
    // Create tools directory if needed
    let _ = exec_in_sandbox(
        client,
        base_url,
        sandbox_id,
        &["mkdir", "-p", "/workspace/tools"],
        None,
    )
    .await?;

    // Clone esctest2
    let clone_result = exec_in_sandbox(
        client,
        base_url,
        sandbox_id,
        &["git", "clone", "--depth", "1", ESCTEST2_REPO, ESCTEST2_PATH],
        None,
    )
    .await?;

    if clone_result.exit_code != 0 && !clone_result.stderr.contains("already exists") {
        return Err(anyhow::anyhow!(
            "Failed to clone esctest2: {}",
            clone_result.stderr
        ));
    }

    Ok(())
}

async fn exec_in_sandbox(
    client: &Client,
    base_url: &str,
    sandbox_id: &str,
    command: &[&str],
    workdir: Option<String>,
) -> anyhow::Result<ExecResponse> {
    let body = ExecRequest {
        command: command.iter().map(|s| s.to_string()).collect(),
        workdir,
        env: vec![],
    };
    let url = format!(
        "{}/sandboxes/{}/exec",
        base_url.trim_end_matches('/'),
        sandbox_id
    );
    let response = client.post(url).json(&body).send().await?;
    parse_response(response).await
}

async fn run_esctest_via_attach(
    base_url: &str,
    sandbox_id: &str,
    args: &EsctestArgs,
) -> anyhow::Result<String> {
    // Connect via WebSocket to test through the VirtualTerminal
    let ws_url = base_url
        .replace("http://", "ws://")
        .replace("https://", "wss://")
        .trim_end_matches('/')
        .to_string();
    let url = format!("{}/sandboxes/{}/attach?cols=80&rows=25", ws_url, sandbox_id);

    let (ws_stream, _) = connect_async(&url).await?;
    let (mut write, mut read) = ws_stream.split();

    // Build the esctest2 command
    let mut stop_flag = String::new();
    if args.stop_on_failure {
        stop_flag = " --stop-on-failure".to_string();
    }

    // Use a newline after the marker to distinguish it from command echo
    let esctest_cmd = format!(
        "cd {}/esctest && python3 esctest.py --expected-terminal=xterm --max-vt-level={} --timeout=2 --include='{}'{} --logfile=/tmp/esctest2.log 2>&1; echo; echo '___ESCTEST_DONE___'\n",
        ESCTEST2_PATH, args.max_vt_level, args.pattern, stop_flag
    );

    // Wait for shell prompt (look for "sandbox" in output)
    let mut init_output = String::new();
    let init_start = std::time::Instant::now();
    while init_start.elapsed() < Duration::from_secs(10) {
        tokio::select! {
            msg = read.next() => {
                match msg {
                    Some(Ok(Message::Binary(data))) => {
                        let text = String::from_utf8_lossy(&data);
                        init_output.push_str(&text);
                        if init_output.contains("sandbox") {
                            break;
                        }
                    }
                    Some(Ok(Message::Text(text))) => {
                        init_output.push_str(&text);
                        if init_output.contains("sandbox") {
                            break;
                        }
                    }
                    _ => {}
                }
            }
            _ = tokio::time::sleep(Duration::from_millis(100)) => {}
        }
    }

    // Give shell a moment to fully initialize
    tokio::time::sleep(Duration::from_millis(200)).await;

    // Send the command
    write
        .send(Message::Binary(esctest_cmd.into_bytes()))
        .await?;

    let mut output = String::new();
    let start = std::time::Instant::now();
    let timeout_duration = Duration::from_secs(args.timeout as u64);

    // Read output until done marker or timeout
    loop {
        if start.elapsed() > timeout_duration {
            eprintln!("\n\x1b[31mTest timed out after {}s\x1b[0m", args.timeout);
            break;
        }

        tokio::select! {
            msg = read.next() => {
                match msg {
                    Some(Ok(Message::Binary(data))) => {
                        let text = String::from_utf8_lossy(&data);
                        output.push_str(&text);
                        print!("{}", text);
                        use std::io::Write;
                        std::io::stdout().flush().ok();
                        // Look for marker at start of line (after newline)
                        if output.contains("\n___ESCTEST_DONE___") || output.contains("\r___ESCTEST_DONE___") {
                            break;
                        }
                    }
                    Some(Ok(Message::Text(text))) => {
                        output.push_str(&text);
                        print!("{}", text);
                        use std::io::Write;
                        std::io::stdout().flush().ok();
                        // Look for marker at start of line (after newline)
                        if output.contains("\n___ESCTEST_DONE___") || output.contains("\r___ESCTEST_DONE___") {
                            break;
                        }
                    }
                    Some(Ok(Message::Close(_))) | Some(Err(_)) | None => break,
                    _ => {}
                }
            }
            _ = tokio::time::sleep(Duration::from_millis(100)) => {}
        }
    }

    // Send exit to close the connection cleanly
    let _ = write.send(Message::Binary(b"exit\n".to_vec())).await;

    Ok(output)
}

async fn run_esctest_noninteractive(
    _client: &Client,
    base_url: &str,
    sandbox_id: &str,
    args: &EsctestArgs,
) -> anyhow::Result<()> {
    // Run esctest through WebSocket attach to test the VirtualTerminal
    let output = run_esctest_via_attach(base_url, sandbox_id, args).await?;

    // Parse test results from output (e.g., "*** 5 tests passed, 0 known bugs, 3 TESTS FAILED ***")
    let has_failures = output.contains("FAILED");

    // Simple parsing without regex
    let passed_match = output
        .find(" tests passed")
        .or_else(|| output.find(" test passed"))
        .and_then(|pos| {
            let before = &output[..pos];
            before
                .rfind(char::is_whitespace)
                .map(|start| &before[start + 1..])
                .or(Some(before))
                .and_then(|s| s.trim().parse::<u32>().ok())
        })
        .unwrap_or(0);

    let failed_match = output
        .find(" TESTS FAILED")
        .or_else(|| output.find(" TEST FAILED"))
        .and_then(|pos| {
            let before = &output[..pos];
            before
                .rfind(char::is_whitespace)
                .map(|start| &before[start + 1..])
                .or(Some(before))
                .and_then(|s| s.trim().parse::<u32>().ok())
        })
        .unwrap_or(0);

    // Report result
    if has_failures || failed_match > 0 {
        eprintln!(
            "\n\x1b[31m✗ {} passed, {} failed\x1b[0m",
            passed_match, failed_match
        );
    } else if passed_match > 0 {
        eprintln!("\n\x1b[32m✓ {} tests passed\x1b[0m", passed_match);
    } else if output.contains("Timeout") {
        eprintln!("\n\x1b[31mTests failed (timeout)\x1b[0m");
    } else {
        eprintln!("\n\x1b[32m✓ Tests completed\x1b[0m");
    }

    eprintln!("\x1b[90mLogs: /tmp/esctest2.log (in sandbox)\x1b[0m");

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
