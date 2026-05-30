//! cmux CLI — command-line client for the cmux socket API.

use clap::{Parser, Subcommand};
use serde_json::Value;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::fs::MetadataExt;
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicU64, Ordering};

const IO_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);
const MAX_RESPONSE_LEN: usize = 1024 * 1024;

static REQUEST_ID: AtomicU64 = AtomicU64::new(1);

#[derive(Parser)]
#[command(name = "cmux", about = "cmux terminal multiplexer CLI")]
struct Cli {
    #[command(subcommand)]
    command: Commands,

    /// Socket path override
    #[arg(long, default_value_t = default_socket_path(), global = true)]
    socket: String,

    /// Output raw JSON
    #[arg(long, global = true)]
    json: bool,
}

#[derive(Subcommand)]
enum Commands {
    /// Ping the cmux server
    Ping,

    /// Workspace management
    #[command(subcommand)]
    Workspace(WorkspaceCommands),

    /// Surface (terminal) operations
    #[command(subcommand)]
    Surface(SurfaceCommands),

    /// Pane operations
    #[command(subcommand)]
    Pane(PaneCommands),

    /// Send a notification
    Notify {
        /// Notification title
        #[arg(long)]
        title: String,
        /// Notification body
        #[arg(long, default_value = "")]
        body: String,
        /// Target workspace UUID
        #[arg(long)]
        workspace: Option<String>,
        /// Target surface/panel UUID
        #[arg(long)]
        surface: Option<String>,
        /// Suppress desktop notification
        #[arg(long)]
        no_desktop: bool,
    },

    /// List available API methods
    Capabilities,
}

#[derive(Subcommand)]
enum WorkspaceCommands {
    /// List all workspaces
    List,
    /// Create a new workspace
    New {
        /// Working directory
        #[arg(long)]
        directory: Option<String>,
        /// Workspace title
        #[arg(long)]
        title: Option<String>,
    },
    /// Select a workspace by index (0-based)
    Select {
        /// Workspace index
        index: usize,
    },
    /// Select the next workspace
    Next {
        /// Wrap around when reaching the end (default: true)
        #[arg(long, default_value_t = true, action = clap::ArgAction::Set)]
        wrap: bool,
    },
    /// Select the previous workspace
    Previous {
        /// Wrap around when reaching the start (default: true)
        #[arg(long, default_value_t = true, action = clap::ArgAction::Set)]
        wrap: bool,
    },
    /// Select the last workspace
    Last,
    /// Jump to the newest unread workspace
    LatestUnread,
    /// Close a workspace
    Close {
        /// Workspace index (closes selected if not specified)
        index: Option<usize>,
    },
    /// Set status metadata
    SetStatus {
        /// Status key
        #[arg(long)]
        key: String,
        /// Status value
        #[arg(long)]
        value: String,
        /// Optional icon
        #[arg(long)]
        icon: Option<String>,
        /// Optional color
        #[arg(long)]
        color: Option<String>,
    },
}

#[derive(Subcommand)]
enum SurfaceCommands {
    /// Send text input to a terminal
    SendText {
        /// Text to send (supports \n for newline)
        text: String,
        /// Surface handle
        #[arg(long)]
        surface: Option<String>,
    },
}

#[derive(Subcommand)]
enum PaneCommands {
    /// Create a new split pane
    New {
        /// Split orientation: horizontal or vertical
        #[arg(long, default_value = "horizontal")]
        orientation: String,
    },
}

fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();

    let (method, params) = match &cli.command {
        Commands::Ping => ("system.ping", serde_json::json!({})),
        Commands::Capabilities => ("system.capabilities", serde_json::json!({})),

        Commands::Workspace(ws) => match ws {
            WorkspaceCommands::List => ("workspace.list", serde_json::json!({})),
            WorkspaceCommands::New { directory, title } => (
                "workspace.new",
                serde_json::json!({
                    "directory": directory,
                    "title": title,
                }),
            ),
            WorkspaceCommands::Select { index } => {
                ("workspace.select", serde_json::json!({"index": index}))
            }
            WorkspaceCommands::Next { wrap } => {
                ("workspace.next", serde_json::json!({"wrap": wrap}))
            }
            WorkspaceCommands::Previous { wrap } => {
                ("workspace.previous", serde_json::json!({"wrap": wrap}))
            }
            WorkspaceCommands::Last => ("workspace.last", serde_json::json!({})),
            WorkspaceCommands::LatestUnread => ("workspace.latest_unread", serde_json::json!({})),
            WorkspaceCommands::Close { index } => {
                let mut params = serde_json::json!({});
                if let Some(idx) = index {
                    params["index"] = serde_json::json!(idx);
                }
                ("workspace.close", params)
            }
            WorkspaceCommands::SetStatus {
                key,
                value,
                icon,
                color,
            } => (
                "workspace.set_status",
                serde_json::json!({
                    "key": key,
                    "value": value,
                    "icon": icon,
                    "color": color,
                }),
            ),
        },

        Commands::Surface(surf) => match surf {
            SurfaceCommands::SendText { text, surface } => {
                // Unescape \n sequences
                let unescaped = text.replace("\\n", "\n");
                let mut params = serde_json::Map::new();
                params.insert("input".to_string(), Value::String(unescaped));
                if let Some(surface) = surface {
                    params.insert("surface".to_string(), Value::String(surface.to_string()));
                }
                ("surface.send_input", Value::Object(params))
            }
        },

        Commands::Pane(pane) => match pane {
            PaneCommands::New { orientation } => {
                ("pane.new", serde_json::json!({"orientation": orientation}))
            }
        },

        Commands::Notify {
            title,
            body,
            workspace,
            surface,
            no_desktop,
        } => {
            let mut params = serde_json::Map::new();
            params.insert("title".to_string(), Value::String(title.to_string()));
            params.insert("body".to_string(), Value::String(body.to_string()));
            if let Some(workspace) = workspace {
                params.insert("workspace".to_string(), Value::String(workspace.to_string()));
            }
            if let Some(surface) = surface {
                params.insert("surface".to_string(), Value::String(surface.to_string()));
            }
            params.insert("send_desktop".to_string(), Value::Bool(!no_desktop));
            ("notification.create", Value::Object(params))
        }
    };

    let response = send_request(&cli.socket, method, params)?;

    if cli.json {
        println!("{}", serde_json::to_string_pretty(&response)?);
    } else {
        format_response(method, &response);
    }

    // Exit with error code if the response indicates failure
    if response.get("ok").and_then(|v| v.as_bool()) != Some(true) {
        std::process::exit(1);
    }

    Ok(())
}

/// Send a v2 request to the cmux socket and return the response.
fn send_request(socket_path: &str, method: &str, params: Value) -> anyhow::Result<Value> {
    let mut stream = UnixStream::connect(socket_path)
        .map_err(|e| anyhow::anyhow!("Cannot connect to cmux at {}: {}", socket_path, e))?;
    stream.set_read_timeout(Some(IO_TIMEOUT))?;
    stream.set_write_timeout(Some(IO_TIMEOUT))?;

    let id = REQUEST_ID.fetch_add(1, Ordering::Relaxed);
    let request = serde_json::json!({
        "id": id,
        "method": method,
        "params": params,
    });

    let request_json = serde_json::to_string(&request)?;
    stream.write_all(request_json.as_bytes())?;
    stream.write_all(b"\n")?;
    stream.flush()?;

    let limited = (&stream).take((MAX_RESPONSE_LEN + 1) as u64);
    let mut reader = BufReader::new(limited);
    let mut line = String::new();
    let bytes_read = reader.read_line(&mut line)?;
    if bytes_read == 0 {
        anyhow::bail!("cmux closed socket without a response");
    }
    if line.len() > MAX_RESPONSE_LEN {
        anyhow::bail!("cmux response exceeded {} bytes", MAX_RESPONSE_LEN);
    }

    let response: Value = serde_json::from_str(line.trim())?;
    Ok(response)
}

fn default_socket_path() -> String {
    if let Ok(dir) = std::env::var("XDG_RUNTIME_DIR") {
        let path = std::path::Path::new(&dir);
        if path.is_absolute() {
            if let Ok(meta) = std::fs::metadata(path) {
                let my_uid = unsafe { libc::getuid() };
                if meta.is_dir() && meta.uid() == my_uid && (meta.mode() & 0o777) == 0o700 {
                    return format!("{}/cmux.sock", dir);
                }
            }
        }
    }

    format!("/tmp/cmux-{}.sock", unsafe { libc::getuid() })
}

/// Pretty-print a response for human consumption.
fn format_response(method: &str, response: &Value) {
    let ok = response
        .get("ok")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);

    if !ok {
        if let Some(error) = response.get("error") {
            let code = error
                .get("code")
                .and_then(|v| v.as_str())
                .unwrap_or("unknown");
            let msg = error.get("message").and_then(|v| v.as_str()).unwrap_or("");
            eprintln!("Error [{}]: {}", code, msg);
        }
        return;
    }

    let result = response.get("result");

    match method {
        "system.ping" => println!("pong"),

        "workspace.list" => {
            if let Some(workspaces) = result
                .and_then(|r| r.get("workspaces"))
                .and_then(|w| w.as_array())
            {
                for ws in workspaces {
                    let index = ws.get("index").and_then(|v| v.as_u64()).unwrap_or(0);
                    let title = ws.get("title").and_then(|v| v.as_str()).unwrap_or("?");
                    let selected = ws
                        .get("selected")
                        .or_else(|| ws.get("is_selected"))
                        .and_then(|v| v.as_bool())
                        .unwrap_or(false);
                    let panels = ws.get("panel_count").and_then(|v| v.as_u64()).unwrap_or(0);
                    let marker = if selected { "*" } else { " " };
                    println!("{}{} {} ({} panels)", marker, index, title, panels);
                }
            }
        }

        "system.capabilities" => {
            if let Some(methods) = result
                .and_then(|r| r.get("methods"))
                .and_then(|m| m.as_array())
            {
                for m in methods {
                    if let Some(s) = m.as_str() {
                        println!("  {}", s);
                    }
                }
            }
        }

        _ => {
            // Generic: print the result JSON
            if let Some(r) = result {
                println!("{}", serde_json::to_string_pretty(r).unwrap_or_default());
            } else {
                println!("OK");
            }
        }
    }
}
