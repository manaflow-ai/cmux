use std::path::Path;
use std::process::Command as ProcessCommand;
use std::time::Duration;

use anyhow::{anyhow, Context};
use clap::{Parser, Subcommand};
use cmux_sandbox::models::{
    BridgeRequest, BridgeResponse, NotificationLevel, NotificationRequest, OpenUrlRequest,
};
use cmux_sandbox::DEFAULT_HTTP_PORT;
use reqwest::Client;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

#[cfg(unix)]
use std::os::unix::fs::FileTypeExt;

#[derive(Parser, Debug)]
#[command(name = "cmux-bridge", about = "Internal helper for sandboxes")]
struct Cli {
    /// Base URL for the cmux sandbox daemon
    #[arg(
        long,
        env = "CMUX_SANDBOX_URL",
        default_value_t = default_base_url()
    )]
    base_url: String,

    /// Path to the Unix socket for bridge requests (open-url, gh, etc.)
    #[arg(
        long,
        env = "CMUX_BRIDGE_SOCKET",
        default_value = "/run/cmux/bridge.sock"
    )]
    socket: String,

    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand, Debug)]
enum Command {
    /// Open a URL on the host machine.
    #[command(alias = "open")]
    OpenUrl { url: String },
    /// Send a notification to the host UI.
    Notify {
        message: String,
        #[arg(long, value_enum, default_value_t = NotificationLevel::Info)]
        level: NotificationLevel,
    },
    /// Proxy a gh CLI command to the host machine.
    /// Used for git credential helpers and other gh commands that need host auth.
    Gh {
        /// Arguments to pass to the gh command
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        args: Vec<String>,
    },
}

#[tokio::main]
async fn main() {
    let args = prepare_args();
    let cli = Cli::parse_from(args);

    let command = match &cli.command {
        Some(cmd) => cmd,
        None => {
            eprintln!("No command provided. Run with --help for usage.");
            std::process::exit(2);
        }
    };

    let sandbox_id = normalized_env_var("CMUX_SANDBOX_ID");
    let tab_id = normalized_env_var("CMUX_TAB_ID");
    let pane_id = normalized_env_var("CMUX_PANE_ID");

    let result = match command {
        Command::OpenUrl { url } => handle_open_url(&cli, url.clone(), sandbox_id, tab_id).await,
        Command::Notify { message, level } => {
            handle_notify(&cli, message.clone(), *level, sandbox_id, tab_id, pane_id).await
        }
        Command::Gh { args } => handle_gh(&cli, args.clone(), sandbox_id, tab_id).await,
    };

    if let Err(error) = result {
        eprintln!("cmux-bridge error: {error}");
        std::process::exit(1);
    }
}

fn default_base_url() -> String {
    format!("http://127.0.0.1:{}", DEFAULT_HTTP_PORT)
}

fn prepare_args() -> Vec<String> {
    let mut args: Vec<String> = std::env::args().collect();
    if let Some(exe_name) = args
        .first()
        .and_then(|raw| Path::new(raw).file_stem())
        .and_then(|stem| stem.to_str())
    {
        if exe_name == "open-url" || exe_name == "xdg-open" {
            args.insert(1, "open-url".to_string());
        } else if exe_name == "gh" {
            // When invoked as `gh`, inject the `gh` subcommand
            args.insert(1, "gh".to_string());
        }
    }
    args
}

fn normalized_env_var(key: &str) -> Option<String> {
    std::env::var(key)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

fn candidate_base_urls(base: &str) -> Vec<String> {
    let mut urls = Vec::new();
    let trimmed = base.trim_end_matches('/').to_string();
    if !trimmed.is_empty() {
        urls.push(trimmed);
    }

    let port = std::env::var("CMUX_SANDBOX_PORT")
        .ok()
        .and_then(|raw| raw.parse::<u16>().ok())
        .unwrap_or(DEFAULT_HTTP_PORT);

    for host in [
        "localhost",
        "10.0.0.1",
        "172.17.0.1",
        "host.docker.internal",
    ] {
        let candidate = format!("http://{host}:{port}");
        if !urls.contains(&candidate) {
            urls.push(candidate);
        }
    }

    if let Some(gateway) = detect_gateway() {
        let candidate = format!("http://{gateway}:{port}");
        if !urls.contains(&candidate) {
            urls.push(candidate);
        }
    }

    urls
}

fn detect_gateway() -> Option<String> {
    let output = ProcessCommand::new("ip").arg("route").output().ok()?;
    if !output.status.success() {
        return None;
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    for line in stdout.lines() {
        let mut parts = line.split_whitespace();
        if parts.next()? != "default" {
            continue;
        }
        let gateway = parts.nth(1)?;
        return Some(gateway.to_string());
    }

    None
}

#[cfg(unix)]
fn socket_available(path: &str) -> bool {
    std::fs::metadata(path)
        .map(|meta| meta.file_type().is_socket())
        .unwrap_or(false)
}

#[cfg(not(unix))]
fn socket_available(_path: &str) -> bool {
    false
}

async fn send_bridge_request(
    path: &str,
    request: &BridgeRequest,
) -> anyhow::Result<BridgeResponse> {
    let mut stream = UnixStream::connect(path)
        .await
        .with_context(|| format!("failed to connect to socket {path}"))?;
    let payload = serde_json::to_string(request)?;
    stream.write_all(payload.as_bytes()).await?;
    stream.write_all(b"\n").await?;
    stream.flush().await?;

    let mut reader = BufReader::new(stream);
    let mut response_line = String::new();
    reader.read_line(&mut response_line).await?;

    let response: BridgeResponse =
        serde_json::from_str(response_line.trim()).context("failed to parse bridge response")?;

    Ok(response)
}

fn build_http_client() -> anyhow::Result<Client> {
    Client::builder()
        .timeout(Duration::from_secs(5))
        .build()
        .context("failed to build HTTP client")
}

async fn send_open_via_http(
    client: &Client,
    bases: &[String],
    request: &OpenUrlRequest,
) -> anyhow::Result<()> {
    let mut last_error: Option<anyhow::Error> = None;

    for (index, base) in bases.iter().enumerate() {
        let is_last = index + 1 == bases.len();
        let trimmed = base.trim_end_matches('/');
        let post = client
            .post(format!("{trimmed}/open-url"))
            .json(request)
            .send()
            .await;

        match post {
            Ok(resp) if resp.status().is_success() => return Ok(()),
            Ok(resp) if is_last => {
                last_error = Some(anyhow!("{} -> {}", trimmed, resp.status()));
            }
            Ok(_) => {}
            Err(error) if is_last => last_error = Some(anyhow!(error)),
            Err(_) => {}
        }

        // Try GET fallback for compatibility
        let encoded =
            url::form_urlencoded::byte_serialize(request.url.as_bytes()).collect::<String>();
        let get = client
            .get(format!("{trimmed}/open-url?url={encoded}"))
            .send()
            .await;
        match get {
            Ok(resp) if resp.status().is_success() => return Ok(()),
            Ok(resp) if is_last => {
                last_error = Some(anyhow!("GET {} -> {}", trimmed, resp.status()));
            }
            Ok(_) => {}
            Err(error) if is_last => last_error = Some(anyhow!(error)),
            Err(_) => {}
        }
    }

    Err(last_error.unwrap_or_else(|| anyhow!("failed to open URL via HTTP")))
}

async fn send_notification_via_http(
    client: &Client,
    bases: &[String],
    request: &NotificationRequest,
) -> anyhow::Result<()> {
    let mut last_error: Option<anyhow::Error> = None;

    for (index, base) in bases.iter().enumerate() {
        let is_last = index + 1 == bases.len();
        let trimmed = base.trim_end_matches('/');
        let response = client
            .post(format!("{trimmed}/notifications"))
            .json(request)
            .send()
            .await;

        match response {
            Ok(resp) if resp.status().is_success() => return Ok(()),
            Ok(resp) if is_last => {
                last_error = Some(anyhow!("{} -> {}", trimmed, resp.status()));
            }
            Ok(_) => {}
            Err(error) if is_last => last_error = Some(anyhow!(error)),
            Err(_) => {}
        }
    }

    Err(last_error.unwrap_or_else(|| anyhow!("failed to send notification")))
}

async fn handle_open_url(
    cli: &Cli,
    url: String,
    sandbox_id: Option<String>,
    tab_id: Option<String>,
) -> anyhow::Result<()> {
    if !url.starts_with("http://") && !url.starts_with("https://") {
        return Err(anyhow!("URL must start with http:// or https://"));
    }

    let request = BridgeRequest::OpenUrl {
        url: url.clone(),
        sandbox_id,
        tab_id,
    };

    let mut socket_error = None;

    if socket_available(&cli.socket) {
        match send_bridge_request(&cli.socket, &request).await {
            Ok(BridgeResponse::Ok) => return Ok(()),
            Ok(BridgeResponse::Error { message }) => {
                socket_error = Some(anyhow!("socket error: {message}"));
            }
            Ok(_) => {
                socket_error = Some(anyhow!("unexpected response type"));
            }
            Err(error) => socket_error = Some(error),
        }
    }

    // HTTP fallback using the old OpenUrlRequest format
    let http_request = OpenUrlRequest {
        url,
        sandbox_id: None,
        tab_id: None,
    };

    let client = build_http_client()?;
    let bases = candidate_base_urls(&cli.base_url);
    match send_open_via_http(&client, &bases, &http_request).await {
        Ok(()) => Ok(()),
        Err(http_error) => {
            if let Some(socket_error) = socket_error {
                Err(anyhow!(
                    "{http_error}; socket fallback failed: {socket_error}"
                ))
            } else {
                Err(http_error)
            }
        }
    }
}

async fn handle_notify(
    cli: &Cli,
    message: String,
    level: NotificationLevel,
    sandbox_id: Option<String>,
    tab_id: Option<String>,
    pane_id: Option<String>,
) -> anyhow::Result<()> {
    let request = BridgeRequest::Notify {
        message: message.clone(),
        level,
        sandbox_id: sandbox_id.clone(),
        tab_id: tab_id.clone(),
        pane_id: pane_id.clone(),
    };

    let mut socket_error = None;

    // Try Unix socket first
    if socket_available(&cli.socket) {
        match send_bridge_request(&cli.socket, &request).await {
            Ok(BridgeResponse::Ok) => return Ok(()),
            Ok(BridgeResponse::Error { message }) => {
                socket_error = Some(anyhow!("socket error: {message}"));
            }
            Ok(_) => {
                socket_error = Some(anyhow!("unexpected response type"));
            }
            Err(error) => socket_error = Some(error),
        }
    }

    // HTTP fallback
    let http_request = NotificationRequest {
        message,
        level,
        sandbox_id,
        tab_id,
        pane_id,
    };

    let client = build_http_client()?;
    let bases = candidate_base_urls(&cli.base_url);
    match send_notification_via_http(&client, &bases, &http_request).await {
        Ok(()) => Ok(()),
        Err(http_error) => {
            if let Some(socket_error) = socket_error {
                Err(anyhow!(
                    "{http_error}; socket fallback failed: {socket_error}"
                ))
            } else {
                Err(http_error)
            }
        }
    }
}

async fn handle_gh(
    cli: &Cli,
    args: Vec<String>,
    sandbox_id: Option<String>,
    tab_id: Option<String>,
) -> anyhow::Result<()> {
    use std::io::{self, IsTerminal, Read};

    // Read stdin if available (non-blocking check)
    let stdin_data = if !io::stdin().is_terminal() {
        let mut buffer = String::new();
        io::stdin().read_to_string(&mut buffer)?;
        if buffer.is_empty() {
            None
        } else {
            Some(buffer)
        }
    } else {
        None
    };

    let request = BridgeRequest::Gh {
        request_id: String::new(), // Server will generate if empty
        args,
        stdin: stdin_data,
        sandbox_id,
        tab_id,
    };

    // Try Unix socket - no HTTP fallback for gh (security)
    if !socket_available(&cli.socket) {
        return Err(anyhow!("bridge socket not available at {}", cli.socket));
    }

    let response = send_bridge_request(&cli.socket, &request).await?;

    match response {
        BridgeResponse::Gh {
            exit_code,
            stdout,
            stderr,
            ..
        } => {
            if !stdout.is_empty() {
                print!("{}", stdout);
            }
            if !stderr.is_empty() {
                eprint!("{}", stderr);
            }
            if exit_code != 0 {
                std::process::exit(exit_code);
            }
            Ok(())
        }
        BridgeResponse::Error { message } => Err(anyhow!("gh request failed: {}", message)),
        BridgeResponse::Ok => Err(anyhow!("unexpected response type for gh request")),
    }
}
