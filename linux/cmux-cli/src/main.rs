//! cmux CLI — command-line client for the cmux socket API.

use clap::{Parser, Subcommand};
use serde_json::Value;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicU64, Ordering};

static REQUEST_ID: AtomicU64 = AtomicU64::new(1);

/// Determine the default socket path, matching the server's validation logic.
///
/// Validates that `XDG_RUNTIME_DIR` is owned by the current user and not
/// group/world-writable before using it. Falls back to `/tmp/cmux.sock`.
fn default_socket_path() -> String {
    if let Ok(dir) = std::env::var("XDG_RUNTIME_DIR") {
        let path = std::path::Path::new(&dir);
        if path.is_absolute() {
            if let Ok(meta) = std::fs::metadata(path) {
                use std::os::unix::fs::MetadataExt;
                let my_uid = unsafe { libc::getuid() };
                if meta.is_dir() && meta.uid() == my_uid && (meta.mode() & 0o777) == 0o700 {
                    return format!("{}/cmux.sock", dir);
                }
            }
        }
    }
    format!("/tmp/cmux-{}.sock", unsafe { libc::getuid() })
}

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
        /// Don't wrap around at the end
        #[arg(long)]
        no_wrap: bool,
    },
    /// Select the previous workspace
    Previous {
        /// Don't wrap around at the end
        #[arg(long)]
        no_wrap: bool,
    },
    /// Select the last workspace
    Last,
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
            WorkspaceCommands::Select { index } => (
                "workspace.select",
                serde_json::json!({"index": index}),
            ),
            WorkspaceCommands::Next { no_wrap } => (
                "workspace.next",
                serde_json::json!({"wrap": !no_wrap}),
            ),
            WorkspaceCommands::Previous { no_wrap } => (
                "workspace.previous",
                serde_json::json!({"wrap": !no_wrap}),
            ),
            WorkspaceCommands::Last => ("workspace.last", serde_json::json!({})),
            WorkspaceCommands::Close { index } => (
                "workspace.close",
                serde_json::json!({"index": index}),
            ),
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
                (
                    "surface.send_input",
                    serde_json::json!({
                        "input": unescaped,
                        "surface": surface,
                    }),
                )
            }
        },

        Commands::Pane(pane) => match pane {
            PaneCommands::New { orientation } => (
                "pane.new",
                serde_json::json!({"orientation": orientation}),
            ),
        },

        Commands::Notify { title, body } => (
            "notification.create",
            serde_json::json!({
                "title": title,
                "body": body,
            }),
        ),
    };

    let response = send_request(&cli.socket, method, params)?;

    if cli.json {
        println!("{}", serde_json::to_string_pretty(&response)?);
    } else {
        format_response(method, &response);
    }

    // Exit with error code if the response indicates failure
    if response.get("ok").and_then(|v| v.as_bool()) == Some(false) {
        std::process::exit(1);
    }

    Ok(())
}

/// Send a v2 request to the cmux socket and return the response.
fn send_request(socket_path: &str, method: &str, params: Value) -> anyhow::Result<Value> {
    let stream = UnixStream::connect(socket_path)
        .map_err(|e| anyhow::anyhow!("Cannot connect to cmux at {}: {}", socket_path, e))?;

    // Set read/write timeouts to prevent hanging indefinitely
    let timeout = std::time::Duration::from_secs(10);
    stream.set_read_timeout(Some(timeout))?;
    stream.set_write_timeout(Some(timeout))?;

    let mut writer = std::io::BufWriter::new(&stream);
    let id = REQUEST_ID.fetch_add(1, Ordering::Relaxed);
    let request = serde_json::json!({
        "id": id,
        "method": method,
        "params": params,
    });

    let request_json = serde_json::to_string(&request)?;
    writer.write_all(request_json.as_bytes())?;
    writer.write_all(b"\n")?;
    writer.flush()?;

    // Bounded read: limit total bytes to prevent OOM from malformed responses
    const MAX_RESPONSE_LEN: usize = 1024 * 1024;
    let limited = (&stream).take(MAX_RESPONSE_LEN as u64 + 1);
    let mut reader = BufReader::new(limited);
    let mut line = String::new();
    let bytes = reader.read_line(&mut line)?;
    if bytes == 0 {
        return Err(anyhow::anyhow!("cmux closed socket without a response"));
    }
    if line.len() > MAX_RESPONSE_LEN {
        return Err(anyhow::anyhow!(
            "cmux response exceeded {} bytes",
            MAX_RESPONSE_LEN
        ));
    }

    let response: Value = serde_json::from_str(line.trim())?;
    Ok(response)
}

/// Pretty-print a response for human consumption.
fn format_response(method: &str, response: &Value) {
    let ok = response.get("ok").and_then(|v| v.as_bool()).unwrap_or(false);

    if !ok {
        if let Some(error) = response.get("error") {
            let code = error.get("code").and_then(|v| v.as_str()).unwrap_or("unknown");
            let msg = error.get("message").and_then(|v| v.as_str()).unwrap_or("");
            eprintln!("Error [{}]: {}", code, msg);
        }
        return;
    }

    let result = response.get("result");

    match method {
        "system.ping" => println!("pong"),

        "workspace.list" => {
            if let Some(workspaces) = result.and_then(|r| r.get("workspaces")).and_then(|w| w.as_array())
            {
                for ws in workspaces {
                    let index = ws.get("index").and_then(|v| v.as_u64()).unwrap_or(0);
                    let title = ws.get("title").and_then(|v| v.as_str()).unwrap_or("?");
                    let selected = ws.get("selected").and_then(|v| v.as_bool()).unwrap_or(false);
                    let panels = ws.get("panel_count").and_then(|v| v.as_u64()).unwrap_or(0);
                    let marker = if selected { "*" } else { " " };
                    println!("{}{} {} ({} panels)", marker, index, title, panels);
                }
            }
        }

        "system.capabilities" => {
            if let Some(methods) = result.and_then(|r| r.get("methods")).and_then(|m| m.as_array())
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
