//! cmux CLI — command-line client for the cmux socket API.

use clap::{Parser, Subcommand};
use serde_json::Value;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicU64, Ordering};

const SOCKET_PATH: &str = "/tmp/cmux.sock";

static REQUEST_ID: AtomicU64 = AtomicU64::new(1);

#[derive(Parser)]
#[command(name = "cmux", about = "cmux terminal multiplexer CLI")]
struct Cli {
    #[command(subcommand)]
    command: Commands,

    /// Socket path override
    #[arg(long, default_value = SOCKET_PATH, global = true)]
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
        #[arg(long, default_value = "true")]
        wrap: bool,
    },
    /// Select the previous workspace
    Previous {
        #[arg(long, default_value = "true")]
        wrap: bool,
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
            WorkspaceCommands::Next { wrap } => (
                "workspace.next",
                serde_json::json!({"wrap": wrap}),
            ),
            WorkspaceCommands::Previous { wrap } => (
                "workspace.previous",
                serde_json::json!({"wrap": wrap}),
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
    let mut stream = UnixStream::connect(socket_path)
        .map_err(|e| anyhow::anyhow!("Cannot connect to cmux at {}: {}", socket_path, e))?;

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

    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    reader.read_line(&mut line)?;

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
                    let selected = ws.get("is_selected").and_then(|v| v.as_bool()).unwrap_or(false);
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
