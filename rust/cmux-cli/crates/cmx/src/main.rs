#![cfg_attr(
    not(test),
    deny(
        clippy::expect_used,
        clippy::panic,
        clippy::todo,
        clippy::unimplemented,
        clippy::unwrap_used
    )
)]

//! `cmx` — the cmux-cli entry point.
//!
//! Two subcommands for M3:
//! - `cmx server` runs the PTY host server (Unix socket).
//! - `cmx attach` (or bare `cmx`) connects as a Grid-mode client.
//!
use std::path::PathBuf;
use std::process::{Command as ProcessCommand, Stdio};

use anyhow::Result;
use clap::{Parser, Subcommand};
use cmux_cli_core::probe;

#[derive(Parser, Debug)]
#[command(name = "cmx", version, about = "cmux-cli terminal multiplexer")]
struct Cli {
    /// Unix socket path. Defaults to $XDG_RUNTIME_DIR/cmux-cli/server.sock
    /// (or /tmp/cmux-cli-$UID/server.sock when $XDG_RUNTIME_DIR is unset).
    #[arg(long, global = true, env = "CMX_SOCKET_PATH")]
    socket: Option<PathBuf>,

    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand, Debug)]
enum Command {
    /// Run the cmx server in the foreground.
    Server {
        /// Bind a WebSocket listener on this address, e.g. 127.0.0.1:8787.
        #[arg(long, env = "CMX_WS_BIND")]
        ws_bind: Option<std::net::SocketAddr>,
        /// Bearer token required of WebSocket clients. Without this,
        /// the WS listener accepts any connection; don't expose it.
        #[arg(long, env = "CMX_AUTH_TOKEN")]
        auth_token: Option<String>,
    },
    /// Attach to the cmx server, starting it first if needed.
    #[command(alias = "reattach")]
    Attach,
    /// Check whether the server is reachable (handshake + detach).
    Ping,
    /// Print the client protocol version.
    Version,
    /// List every workspace in the running server.
    ListWorkspaces {
        /// Emit JSON instead of a human-readable table.
        #[arg(long)]
        json: bool,
    },
    /// List every space in the active workspace.
    ListSpaces {
        /// Emit JSON instead of a human-readable table.
        #[arg(long)]
        json: bool,
    },
    /// List every terminal in the focused pane. Compatibility aliases:
    /// `list-tabs`, `list-panes`.
    #[command(alias = "list-panes", alias = "list-terminals")]
    ListTabs {
        /// Emit JSON instead of a human-readable table.
        #[arg(long)]
        json: bool,
    },
    /// Create a new terminal in the focused pane and switch to it.
    #[command(alias = "new-terminal")]
    NewTab,
    /// Create a new space in the active workspace and switch to it.
    NewSpace {
        /// Optional title. Defaults to an auto-generated name.
        #[arg(long)]
        title: Option<String>,
    },
    /// Create a new workspace and switch to it.
    NewWorkspace {
        /// Optional title. Defaults to an auto-generated name.
        #[arg(long)]
        title: Option<String>,
    },
    /// Cycle to the next workspace.
    NextWorkspace,
    /// Cycle to the previous workspace.
    PrevWorkspace,
    /// Cycle to the next space in the active workspace.
    NextSpace,
    /// Cycle to the previous space in the active workspace.
    PrevSpace,
    /// Cycle to the next terminal in the focused pane.
    #[command(alias = "next-terminal")]
    NextTab,
    /// Cycle to the previous terminal in the focused pane.
    #[command(alias = "prev-terminal")]
    PrevTab,
    /// Select the terminal at the given 0-based index in the focused pane.
    SelectTab { index: usize },
    /// Select the space at the given 0-based index in the active workspace.
    SelectSpace { index: usize },
    /// Select the workspace at the given 0-based index.
    SelectWorkspace { index: usize },
    /// Close the active terminal (sends Ctrl-D to its PTY).
    #[command(alias = "close-terminal")]
    CloseTab,
    /// Close the active space.
    CloseSpace,
    /// Close the active workspace.
    CloseWorkspace,
    /// Inject text into the active terminal's PTY as if it had been typed.
    /// Use `--no-newline` to skip the trailing newline added by default.
    Send {
        text: String,
        #[arg(long)]
        no_newline: bool,
    },
    /// Send a named key (or space-separated sequence) into the active
    /// terminal's PTY. Accepts `Enter`, `Esc`, `Tab`, `Backspace`, `Space`,
    /// `Up`/`Down`/`Left`/`Right`, `Home`/`End`, `PageUp`/`PageDown`,
    /// `F1`..`F12`, `C-x` for Ctrl-x, `M-x` or `Alt-x` for
    /// meta-prefixed, or a single printable char. Examples:
    /// `cmx send-key C-c`, `cmx send-key Enter`, `cmx send-key M-x`.
    /// tmux-compat alias: `send-keys`.
    #[command(alias = "send-keys")]
    SendKey { keys: Vec<String> },
    /// Rename the currently-active terminal.
    #[command(alias = "rename-terminal")]
    RenameTab { title: String },
    /// Rename the currently-active space.
    RenameSpace { title: String },
    /// Rename the currently-active workspace.
    RenameWorkspace { title: String },
    /// Rename cmx objects with a tmux-like two-word form.
    Rename {
        #[command(subcommand)]
        target: RenameTarget,
    },
    /// Shut down the running server. tmux-compat alias: `kill-server`.
    #[command(alias = "kill-server")]
    CloseServer,
    /// Flag a terminal as having notable activity. Bumps the bell
    /// counter and lights up the `•` indicator on the terminal pill so
    /// background activity is visible without switching. Optional
    /// `--tab N` targets a specific index; defaults to the active
    /// terminal.
    Notify {
        /// Optional message. Reserved for a future notification
        /// hook; currently only transported.
        #[arg(default_value = "")]
        message: String,
        #[arg(long)]
        tab: Option<usize>,
    },
    /// Split the active panel side-by-side. tmux-compat alias:
    /// `split-horizontal`.
    #[command(alias = "split-horizontal")]
    Split {
        /// Use stacked (vertical) arrangement instead of side-by-side.
        #[arg(long)]
        vertical: bool,
    },
    /// Flatten all panels into one panel.
    Unsplit,
    /// Toggle pane zoom: active leaf fills the pane area while
    /// zoomed; split layout restored on toggle off. No-op outside
    /// split mode. Matches tmux `C-b z`.
    ToggleZoom,
    /// Move focus to the nearest panel in the given direction. Out
    /// of split mode, focus commands cycle tabs.
    FocusPane {
        /// `left`, `right`, `up`, or `down`.
        direction: String,
    },
    /// Resize the nearest split ancestor of the active panel.
    /// `left`/`up` shrinks the first child, `right`/`down` grows it.
    /// Default step is 5% of the split area (50 permille).
    ResizePane {
        direction: String,
        /// Percent of the pane to move (default 5).
        #[arg(long, default_value_t = 5)]
        amount: u16,
    },
    /// Show a transient message in the status bar for ~2 seconds.
    DisplayMessage { text: String },
    /// Toggle whether the active workspace is pinned. Pinned
    /// workspaces respawn their shell when the last tab exits, so
    /// the workspace survives `exit` / `C-d`.
    TogglePin,
    /// Set the active workspace's color tint. Accepts `#RRGGBB`
    /// or bare `RRGGBB`. Pass no argument (or `none`) to clear.
    SetWorkspaceColor {
        /// Hex color. Omit or pass `none` to clear.
        #[arg(default_value = "")]
        color: String,
    },
    /// Print a workspace-oriented tree of the running server.
    Tree {
        #[arg(long)]
        json: bool,
    },
    /// Reorder terminals within the focused pane. Moves the terminal at
    /// `from` to index `to`; other terminals shift to make room.
    MoveTab { from: usize, to: usize },
    /// Capture the active terminal's visible screen text. `--lines N`
    /// returns only the last N rows. tmux-compat alias: `capture-pane`.
    #[command(alias = "capture-pane")]
    ReadScreen {
        #[arg(long)]
        lines: Option<usize>,
        /// Emit JSON instead of the raw text.
        #[arg(long)]
        json: bool,
    },
    /// Print the workspace + tab id the caller is running inside, from
    /// the `CMX_WORKSPACE_ID` / `CMX_TAB_ID` env vars injected at PTY
    /// spawn. Useful for agent scripts.
    Identify {
        #[arg(long)]
        json: bool,
    },
    /// Print every supported subcommand (for agent capability discovery).
    Capabilities {
        #[arg(long)]
        json: bool,
    },
}

#[derive(Subcommand, Debug)]
enum RenameTarget {
    /// Rename the currently-active terminal.
    #[command(alias = "terminal")]
    Tab { title: String },
    /// Rename the currently-active space.
    Space { title: String },
    /// Rename the currently-active workspace.
    Workspace { title: String },
}

fn main() -> ! {
    let args = normalized_cli_args(std::env::args());
    let cli = Cli::parse_from(args);
    let socket = cli.socket.unwrap_or_else(default_socket_path);
    probe::log_event(
        "cmx",
        "main_start",
        &[
            (
                "command",
                cli.command
                    .as_ref()
                    .map(command_label)
                    .unwrap_or("attach")
                    .to_string(),
            ),
            ("socket", socket.display().to_string()),
            (
                "cwd",
                std::env::current_dir().map_or_else(|_| "-".into(), |p| p.display().to_string()),
            ),
            ("term", std::env::var("TERM").unwrap_or_default()),
            (
                "term_program",
                std::env::var("TERM_PROGRAM").unwrap_or_default(),
            ),
            ("colorterm", std::env::var("COLORTERM").unwrap_or_default()),
        ],
    );

    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => {
            eprintln!("cmx: failed to build runtime: {e}");
            std::process::exit(1);
        }
    };

    let result: Result<()> = runtime.block_on(async move {
        match cli.command.unwrap_or(Command::Attach) {
            Command::Server {
                ws_bind,
                auth_token,
            } => {
                let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/bash".into());
                cmux_cli_server::run(cmux_cli_server::ServerOptions {
                    socket_path: socket,
                    shell,
                    cwd: std::env::current_dir().ok(),
                    initial_viewport: (80, 24),
                    snapshot_path: Some(default_snapshot_path()),
                    settings_path: Some(default_settings_path()),
                    ws_bind,
                    auth_token,
                })
                .await
            }
            Command::Attach => {
                reattach(socket).await
            }
            Command::Version => {
                println!(
                    "cmx {} (protocol v{})",
                    env!("CARGO_PKG_VERSION"),
                    cmux_cli_protocol::PROTOCOL_VERSION,
                );
                Ok(())
            }
            Command::Ping => query_and_print(socket, cmux_cli_protocol::Command::ListTabs, |_| {
                println!("ok");
                Ok(())
            })
            .await,
            Command::ListWorkspaces { json } => {
                query_and_print(
                    socket,
                    cmux_cli_protocol::Command::ListWorkspaces,
                    move |data| {
                        if let Some(cmux_cli_protocol::CommandData::WorkspaceList {
                            workspaces,
                            active,
                        }) = data
                        {
                            if json {
                                let out = serde_json::json!({
                                    "active": active,
                                    "workspaces": workspaces.iter().map(|w| serde_json::json!({
                                        "id": w.id,
                                        "title": w.title,
                                        "space_count": w.space_count,
                                        "terminal_count": w.terminal_count,
                                    })).collect::<Vec<_>>(),
                                });
                                println!("{}", serde_json::to_string_pretty(&out)?);
                            } else {
                                for (i, w) in workspaces.iter().enumerate() {
                                    let marker = if i == active { "*" } else { " " };
                                    println!(
                                        "{marker} {i} {:<24} ({} spaces, {} terminals)  [id={}]",
                                        w.title, w.space_count, w.terminal_count, w.id
                                    );
                                }
                            }
                        }
                        Ok(())
                    },
                )
                .await
            }
            Command::ListSpaces { json } => {
                query_and_print(
                    socket,
                    cmux_cli_protocol::Command::ListSpaces,
                    move |data| {
                        if let Some(cmux_cli_protocol::CommandData::SpaceList { spaces, active }) =
                            data
                        {
                            if json {
                                let out = serde_json::json!({
                                    "active": active,
                                    "spaces": spaces.iter().map(|s| serde_json::json!({
                                        "id": s.id,
                                        "title": s.title,
                                        "pane_count": s.pane_count,
                                        "terminal_count": s.terminal_count,
                                    })).collect::<Vec<_>>(),
                                });
                                println!("{}", serde_json::to_string_pretty(&out)?);
                            } else {
                                for (i, s) in spaces.iter().enumerate() {
                                    let marker = if i == active { "*" } else { " " };
                                    println!(
                                        "{marker} {i} {:<24} ({} panes, {} terminals)  [id={}]",
                                        s.title, s.pane_count, s.terminal_count, s.id
                                    );
                                }
                            }
                        }
                        Ok(())
                    },
                )
                .await
            }
            Command::ListTabs { json } => {
                query_and_print(
                    socket,
                    cmux_cli_protocol::Command::ListTabs,
                    move |data| {
                        if let Some(cmux_cli_protocol::CommandData::TabList { tabs, active }) =
                            data
                        {
                            if json {
                                let out = serde_json::json!({
                                    "active": active,
                                    "tabs": tabs.iter().map(|t| serde_json::json!({
                                        "id": t.id,
                                        "title": t.title,
                                        "has_activity": t.has_activity,
                                        "bell_count": t.bell_count,
                                    })).collect::<Vec<_>>(),
                                });
                                println!("{}", serde_json::to_string_pretty(&out)?);
                            } else {
                                for (i, t) in tabs.iter().enumerate() {
                                    let active_marker = if i == active { "*" } else { " " };
                                    let activity_marker =
                                        if t.has_activity { "•" } else { " " };
                                    println!(
                                        "{active_marker}{activity_marker} {i} {:<24}  [id={} bells={}]",
                                        t.title, t.id, t.bell_count
                                    );
                                }
                            }
                        }
                        Ok(())
                    },
                )
                .await
            }
            Command::NewTab => {
                fire_and_forget(socket, cmux_cli_protocol::Command::NewTab).await
            }
            Command::NewSpace { title } => {
                fire_and_forget(socket, cmux_cli_protocol::Command::NewSpace { title }).await
            }
            Command::NewWorkspace { title } => {
                fire_and_forget(
                    socket,
                    cmux_cli_protocol::Command::NewWorkspace { title, cwd: None },
                )
                .await
            }
            Command::NextWorkspace => {
                fire_and_forget(socket, cmux_cli_protocol::Command::NextWorkspace).await
            }
            Command::PrevWorkspace => {
                fire_and_forget(socket, cmux_cli_protocol::Command::PrevWorkspace).await
            }
            Command::NextSpace => {
                fire_and_forget(socket, cmux_cli_protocol::Command::NextSpace).await
            }
            Command::PrevSpace => {
                fire_and_forget(socket, cmux_cli_protocol::Command::PrevSpace).await
            }
            Command::NextTab => {
                fire_and_forget(socket, cmux_cli_protocol::Command::NextTab).await
            }
            Command::PrevTab => {
                fire_and_forget(socket, cmux_cli_protocol::Command::PrevTab).await
            }
            Command::SelectTab { index } => {
                fire_and_forget(socket, cmux_cli_protocol::Command::SelectTab { index }).await
            }
            Command::SelectSpace { index } => {
                fire_and_forget(socket, cmux_cli_protocol::Command::SelectSpace { index }).await
            }
            Command::SelectWorkspace { index } => {
                fire_and_forget(
                    socket,
                    cmux_cli_protocol::Command::SelectWorkspace { index },
                )
                .await
            }
            Command::CloseTab => {
                fire_and_forget(socket, cmux_cli_protocol::Command::CloseTab).await
            }
            Command::CloseSpace => {
                fire_and_forget(socket, cmux_cli_protocol::Command::CloseSpace).await
            }
            Command::CloseWorkspace => {
                fire_and_forget(socket, cmux_cli_protocol::Command::CloseWorkspace).await
            }
            Command::Send { text, no_newline } => {
                let data = if no_newline {
                    text
                } else {
                    format!("{text}\n")
                };
                fire_and_forget(socket, cmux_cli_protocol::Command::SendInput { data }).await
            }
            Command::SendKey { keys } => {
                let mut bytes = Vec::new();
                for k in &keys {
                    match parse_named_key(k) {
                        Some(mut b) => bytes.append(&mut b),
                        None => {
                            eprintln!("cmx: unknown key {k:?}");
                            std::process::exit(2);
                        }
                    }
                }
                fire_and_forget(socket, cmux_cli_protocol::Command::SendKey { data: bytes }).await
            }
            Command::RenameTab { title } => {
                fire_and_forget(socket, cmux_cli_protocol::Command::RenameTab { title }).await
            }
            Command::RenameSpace { title } => {
                fire_and_forget(socket, cmux_cli_protocol::Command::RenameSpace { title }).await
            }
            Command::RenameWorkspace { title } => {
                fire_and_forget(
                    socket,
                    cmux_cli_protocol::Command::RenameWorkspace { title },
                )
                .await
            }
            Command::Rename { target } => match target {
                RenameTarget::Tab { title } => {
                    fire_and_forget(socket, cmux_cli_protocol::Command::RenameTab { title }).await
                }
                RenameTarget::Space { title } => {
                    fire_and_forget(socket, cmux_cli_protocol::Command::RenameSpace { title }).await
                }
                RenameTarget::Workspace { title } => {
                    fire_and_forget(
                        socket,
                        cmux_cli_protocol::Command::RenameWorkspace { title },
                    )
                    .await
                }
            },
            Command::CloseServer => {
                // The reply may not arrive — the server is already
                // tearing down. Treat transport errors as success.
                let _ = cmux_cli_client::run_query(
                    socket,
                    cmux_cli_protocol::Command::KillServer,
                )
                .await;
                Ok(())
            }
            Command::Notify { message, tab } => {
                let message = if message.is_empty() {
                    None
                } else {
                    Some(message)
                };
                fire_and_forget(
                    socket,
                    cmux_cli_protocol::Command::Notify { message, tab },
                )
                .await
            }
            Command::Split { vertical } => {
                let cmd = if vertical {
                    cmux_cli_protocol::Command::SplitVertical
                } else {
                    cmux_cli_protocol::Command::SplitHorizontal
                };
                fire_and_forget(socket, cmd).await
            }
            Command::Unsplit => {
                fire_and_forget(socket, cmux_cli_protocol::Command::Unsplit).await
            }
            Command::ToggleZoom => {
                fire_and_forget(socket, cmux_cli_protocol::Command::ToggleZoom).await
            }
            Command::FocusPane { direction } => {
                let cmd = match direction.to_ascii_lowercase().as_str() {
                    "left" => cmux_cli_protocol::Command::FocusLeft,
                    "right" => cmux_cli_protocol::Command::FocusRight,
                    "up" => cmux_cli_protocol::Command::FocusUp,
                    "down" => cmux_cli_protocol::Command::FocusDown,
                    other => {
                        eprintln!("cmx: unknown direction {other:?} (want left|right|up|down)");
                        std::process::exit(2);
                    }
                };
                fire_and_forget(socket, cmd).await
            }
            Command::ResizePane { direction, amount } => {
                // `amount` is percent; the protocol wants permille
                // (so 5% → 50). Positive direction grows the first
                // leaf; negative shrinks it.
                let permille_step = (amount as i16) * 10;
                let delta: i16 = match direction.to_ascii_lowercase().as_str() {
                    "left" | "up" => -permille_step,
                    "right" | "down" => permille_step,
                    other => {
                        eprintln!("cmx: unknown direction {other:?} (want left|right|up|down)");
                        std::process::exit(2);
                    }
                };
                fire_and_forget(
                    socket,
                    cmux_cli_protocol::Command::ResizePane { delta },
                )
                .await
            }
            Command::DisplayMessage { text } => {
                fire_and_forget(
                    socket,
                    cmux_cli_protocol::Command::DisplayMessage { text },
                )
                .await
            }
            Command::TogglePin => {
                fire_and_forget(socket, cmux_cli_protocol::Command::TogglePin).await
            }
            Command::MoveTab { from, to } => {
                fire_and_forget(
                    socket,
                    cmux_cli_protocol::Command::MoveTab { from, to },
                )
                .await
            }
            Command::SetWorkspaceColor { color } => {
                let color_opt = match color.trim().to_ascii_lowercase().as_str() {
                    "" | "none" | "clear" | "off" => None,
                    _ => Some(color),
                };
                fire_and_forget(
                    socket,
                    cmux_cli_protocol::Command::SetWorkspaceColor { color: color_opt },
                )
                .await
            }
            Command::Tree { json } => {
                // Tree is purely client-side composition: ask for
                // workspaces, then for each fire a separate select
                // + list-tabs round-trip? Heavy. Simpler for now:
                // fetch the workspace list + active tab list only.
                // Per-workspace tab lists would need per-workspace
                // SelectWorkspace round-trips; skip for now.
                let ws_reply = cmux_cli_client::run_query(
                    socket.clone(),
                    cmux_cli_protocol::Command::ListWorkspaces,
                )
                .await?;
                let ws_data = match ws_reply {
                    cmux_cli_protocol::CommandResult::Ok {
                        data: Some(cmux_cli_protocol::CommandData::WorkspaceList {
                            workspaces,
                            active,
                        }),
                    } => (workspaces, active),
                    other => {
                        return Err(anyhow::anyhow!("ListWorkspaces failed: {other:?}"));
                    }
                };
                let tabs_reply = cmux_cli_client::run_query(
                    socket,
                    cmux_cli_protocol::Command::ListTabs,
                )
                .await?;
                let tabs_data = match tabs_reply {
                    cmux_cli_protocol::CommandResult::Ok {
                        data: Some(cmux_cli_protocol::CommandData::TabList { tabs, active }),
                    } => (tabs, active),
                    other => {
                        return Err(anyhow::anyhow!("ListTabs failed: {other:?}"));
                    }
                };
                if json {
                    let out = serde_json::json!({
                        "active_workspace": ws_data.1,
                        "workspaces": ws_data.0.iter().enumerate().map(|(i, w)| {
                            serde_json::json!({
                                "id": w.id,
                                "title": w.title,
                                "space_count": w.space_count,
                                "terminal_count": w.terminal_count,
                                "pinned": w.pinned,
                                "color": w.color,
                                "active": i == ws_data.1,
                                "tabs": if i == ws_data.1 {
                                    // `TabInfo` derives Serialize with only
                                    // trivially-serialisable fields, so this
                                    // branch is effectively infallible —
                                    // fall back to Null on the impossible
                                    // error path rather than panicking.
                                    serde_json::to_value(&tabs_data.0)
                                        .unwrap_or(serde_json::Value::Null)
                                } else {
                                    serde_json::Value::Null
                                },
                                "active_tab": if i == ws_data.1 {
                                    serde_json::Value::from(tabs_data.1)
                                } else {
                                    serde_json::Value::Null
                                },
                            })
                        }).collect::<Vec<_>>(),
                    });
                    println!("{}", serde_json::to_string_pretty(&out)?);
                } else {
                    for (i, w) in ws_data.0.iter().enumerate() {
                        let active_mark = if i == ws_data.1 { "*" } else { " " };
                        let pin_mark = if w.pinned { "📌" } else { "  " };
                        let color_mark = w
                            .color
                            .as_deref()
                            .map(|c| format!(" {c}"))
                            .unwrap_or_default();
                        println!(
                            "{active_mark} {} {}{color_mark}  ({} spaces, {} terminals)  [id={}]",
                            pin_mark, w.title, w.space_count, w.terminal_count, w.id
                        );
                        if i == ws_data.1 {
                            for (j, t) in tabs_data.0.iter().enumerate() {
                                let tab_mark = if j == tabs_data.1 { "*" } else { " " };
                                let activity = if t.has_activity { "•" } else { " " };
                                println!(
                                    "      {tab_mark}{activity} {} {}  [id={} bells={}]",
                                    j, t.title, t.id, t.bell_count
                                );
                            }
                        }
                    }
                }
                Ok(())
            }
            Command::ReadScreen { lines, json } => {
                query_and_print(
                    socket,
                    cmux_cli_protocol::Command::ReadScreen { lines },
                    move |data| {
                        if let Some(cmux_cli_protocol::CommandData::ScreenText {
                            text,
                            cols,
                            rows,
                        }) = data
                        {
                            if json {
                                let out = serde_json::json!({
                                    "cols": cols,
                                    "rows": rows,
                                    "text": text,
                                });
                                println!("{}", serde_json::to_string_pretty(&out)?);
                            } else {
                                print!("{text}");
                                if !text.ends_with('\n') {
                                    println!();
                                }
                            }
                        }
                        Ok(())
                    },
                )
                .await
            }
            Command::Identify { json } => {
                let ws = std::env::var("CMX_WORKSPACE_ID")
                    .or_else(|_| std::env::var("CMUX_WORKSPACE_ID"))
                    .ok();
                let tab = std::env::var("CMX_TAB_ID")
                    .or_else(|_| std::env::var("CMUX_TAB_ID"))
                    .ok();
                if json {
                    let out = serde_json::json!({
                        "workspace_id": ws,
                        "tab_id": tab,
                    });
                    println!("{}", serde_json::to_string_pretty(&out)?);
                } else {
                    match (ws, tab) {
                        (Some(w), Some(t)) => println!("workspace={w} tab={t}"),
                        _ => {
                            eprintln!(
                                "cmx identify: not running inside a cmx tab (no CMX_WORKSPACE_ID/CMX_TAB_ID)"
                            );
                            std::process::exit(2);
                        }
                    }
                }
                Ok(())
            }
            Command::Capabilities { json } => {
                let caps: &[&str] = &[
                    "attach",
                    "reattach",
                    "server",
                    "ping",
                    "version",
                    "identify",
                    "capabilities",
                    "list-workspaces",
                    "list-spaces",
                    "list-tabs",
                    "list-terminals",
                    "list-panes",
                    "new-tab",
                    "new-terminal",
                    "new-space",
                    "new-workspace",
                    "next-tab",
                    "next-terminal",
                    "next-space",
                    "prev-tab",
                    "prev-terminal",
                    "prev-space",
                    "next-workspace",
                    "prev-workspace",
                    "select-tab",
                    "select-space",
                    "select-workspace",
                    "close-tab",
                    "close-terminal",
                    "close-space",
                    "close-workspace",
                    "close-server",
                    "kill-server",
                    "notify",
                    "split",
                    "unsplit",
                    "toggle-zoom",
                    "focus-pane",
                    "resize-pane",
                    "display-message",
                    "toggle-pin",
                    "set-workspace-color",
                    "tree",
                    "move-tab",
                    "send",
                    "send-key",
                    "send-keys",
                    "read-screen",
                    "capture-pane",
                    "rename",
                    "rename-tab",
                    "rename-terminal",
                    "rename-space",
                    "rename-workspace",
                    "rename tab",
                    "rename terminal",
                    "rename space",
                    "rename workspace",
                ];
                if json {
                    println!("{}", serde_json::to_string_pretty(&caps)?);
                } else {
                    for c in caps {
                        println!("{c}");
                    }
                }
                Ok(())
            }
        }
    });

    // The client holds a blocking task reading crossterm events that cannot be
    // cancelled cleanly (crossterm has no interruptible read). Rather than
    // block the runtime's Drop waiting for it, exit explicitly once the main
    // future has returned. `result` is surfaced via the exit code.
    match result {
        Ok(()) => std::process::exit(0),
        Err(e) => {
            eprintln!("cmx: {e:#}");
            std::process::exit(1);
        }
    }
}

fn normalized_cli_args(args: impl IntoIterator<Item = String>) -> Vec<String> {
    args.into_iter()
        .enumerate()
        .map(|(idx, arg)| {
            if idx == 0 {
                arg
            } else {
                normalize_cli_token(arg)
            }
        })
        .collect()
}

fn normalize_cli_token(arg: String) -> String {
    let normalized = normalize_unicode_dashes(&arg);
    if normalized == arg {
        return arg;
    }
    if normalized.starts_with('-') || KNOWN_CLI_TOKENS.contains(&normalized.as_str()) {
        normalized
    } else {
        arg
    }
}

fn normalize_unicode_dashes(value: &str) -> String {
    value
        .chars()
        .map(|ch| match ch {
            '\u{2010}' | '\u{2011}' | '\u{2012}' | '\u{2013}' | '\u{2014}' | '\u{2212}' => '-',
            other => other,
        })
        .collect()
}

const KNOWN_CLI_TOKENS: &[&str] = &[
    "attach",
    "reattach",
    "server",
    "ping",
    "version",
    "identify",
    "capabilities",
    "list-workspaces",
    "list-spaces",
    "list-tabs",
    "list-terminals",
    "list-panes",
    "new-tab",
    "new-terminal",
    "new-space",
    "new-workspace",
    "next-tab",
    "next-terminal",
    "next-space",
    "prev-tab",
    "prev-terminal",
    "prev-space",
    "next-workspace",
    "prev-workspace",
    "select-tab",
    "select-space",
    "select-workspace",
    "close-tab",
    "close-terminal",
    "close-space",
    "close-workspace",
    "close-server",
    "kill-server",
    "notify",
    "split",
    "unsplit",
    "toggle-zoom",
    "focus-pane",
    "resize-pane",
    "display-message",
    "toggle-pin",
    "set-workspace-color",
    "tree",
    "move-tab",
    "send",
    "send-key",
    "send-keys",
    "read-screen",
    "capture-pane",
    "rename",
    "rename-tab",
    "rename-terminal",
    "rename-space",
    "rename-workspace",
    "tab",
    "terminal",
    "space",
    "workspace",
];

/// Translate a human-friendly key name into the raw bytes a terminal
/// would emit when the key is pressed. Used by `cmx send-key` for
/// agent scripts that need to synthesize keystrokes. Returns None if
/// the name is unrecognised. Recognised forms:
/// - single printable char (`a`, `/`, `!`) → that byte
/// - `C-x` / `Ctrl-x` / `Ctrl+x` → Ctrl-x byte
/// - `M-x` / `Alt-x` / `Alt+x` → ESC + bytes for x
/// - named: `Enter`/`Return`/`RET`, `Esc`/`Escape`, `Tab`, `Backspace`/`BS`,
///   `Space`/`SPC`, `Delete`/`Del`, `Insert`/`Ins`, `Up`/`Down`/`Left`/`Right`,
///   `Home`, `End`, `PageUp`/`PgUp`, `PageDown`/`PgDn`, `F1`..`F12`
fn parse_named_key(name: &str) -> Option<Vec<u8>> {
    let s = name.trim();
    if s.is_empty() {
        return None;
    }
    // Alt / Meta / M- prefixes stack with the rest.
    for prefix in ["M-", "Alt-", "Alt+", "Meta-", "Meta+"] {
        if let Some(rest) = s.strip_prefix(prefix) {
            let mut bytes = vec![0x1b];
            bytes.extend_from_slice(&parse_named_key(rest)?);
            return Some(bytes);
        }
    }
    // Ctrl variants.
    for prefix in ["C-", "Ctrl-", "Ctrl+"] {
        if let Some(rest) = s.strip_prefix(prefix) {
            return parse_ctrl_key(rest);
        }
    }
    let upper = s.to_ascii_uppercase();
    match upper.as_str() {
        "ENTER" | "RETURN" | "RET" => return Some(vec![b'\r']),
        "ESC" | "ESCAPE" => return Some(vec![0x1b]),
        "TAB" => return Some(vec![b'\t']),
        "BACKSPACE" | "BS" => return Some(vec![0x7f]),
        "SPACE" | "SPC" => return Some(vec![b' ']),
        "DELETE" | "DEL" => return Some(b"\x1b[3~".to_vec()),
        "INSERT" | "INS" => return Some(b"\x1b[2~".to_vec()),
        "UP" => return Some(b"\x1b[A".to_vec()),
        "DOWN" => return Some(b"\x1b[B".to_vec()),
        "RIGHT" => return Some(b"\x1b[C".to_vec()),
        "LEFT" => return Some(b"\x1b[D".to_vec()),
        "HOME" => return Some(b"\x1b[H".to_vec()),
        "END" => return Some(b"\x1b[F".to_vec()),
        "PAGEUP" | "PGUP" => return Some(b"\x1b[5~".to_vec()),
        "PAGEDOWN" | "PGDN" => return Some(b"\x1b[6~".to_vec()),
        _ => {}
    }
    if let Some(rest) = upper.strip_prefix('F')
        && let Ok(n) = rest.parse::<u8>()
    {
        return match n {
            1 => Some(b"\x1bOP".to_vec()),
            2 => Some(b"\x1bOQ".to_vec()),
            3 => Some(b"\x1bOR".to_vec()),
            4 => Some(b"\x1bOS".to_vec()),
            5 => Some(b"\x1b[15~".to_vec()),
            6 => Some(b"\x1b[17~".to_vec()),
            7 => Some(b"\x1b[18~".to_vec()),
            8 => Some(b"\x1b[19~".to_vec()),
            9 => Some(b"\x1b[20~".to_vec()),
            10 => Some(b"\x1b[21~".to_vec()),
            11 => Some(b"\x1b[23~".to_vec()),
            12 => Some(b"\x1b[24~".to_vec()),
            _ => None,
        };
    }
    // Single char (printable ASCII or a multi-byte UTF-8 grapheme).
    let mut chars = s.chars();
    let first = chars.next()?;
    if chars.next().is_some() {
        return None;
    }
    let mut buf = [0u8; 4];
    Some(first.encode_utf8(&mut buf).as_bytes().to_vec())
}

fn parse_ctrl_key(s: &str) -> Option<Vec<u8>> {
    if s.len() != 1 {
        if s.eq_ignore_ascii_case("space") {
            return Some(vec![0x00]);
        }
        if s.eq_ignore_ascii_case("backslash") {
            return Some(vec![0x1c]);
        }
        return None;
    }
    let ch = s.chars().next()?;
    if ch.is_ascii() {
        let upper = ch.to_ascii_uppercase();
        if upper.is_ascii_uppercase() {
            return Some(vec![(upper as u8) - b'A' + 1]);
        }
        return match upper {
            '[' => Some(vec![0x1b]),
            '\\' => Some(vec![0x1c]),
            ']' => Some(vec![0x1d]),
            ' ' => Some(vec![0x00]),
            '@' => Some(vec![0x00]),
            _ => None,
        };
    }
    None
}

async fn reattach(socket: PathBuf) -> Result<()> {
    let start_ms = probe::mono_ms();
    probe::log_event(
        "cmx",
        "reattach_start",
        &[("socket", socket.display().to_string())],
    );
    let reachable_start = probe::mono_ms();
    let reachable = server_reachable(&socket).await;
    probe::log_event(
        "cmx",
        "reattach_reachable_check",
        &[
            ("reachable", reachable.to_string()),
            (
                "elapsed_ms",
                probe::mono_ms().saturating_sub(reachable_start).to_string(),
            ),
        ],
    );
    if !reachable {
        start_server_background(&socket)?;
        wait_for_server(&socket).await?;
    }
    probe::log_event(
        "cmx",
        "reattach_attach_begin",
        &[(
            "elapsed_ms",
            probe::mono_ms().saturating_sub(start_ms).to_string(),
        )],
    );
    let opts = cmux_cli_client::AttachOptions {
        socket_path: socket,
    };
    cmux_cli_client::attach(opts).await
}

async fn server_reachable(socket: &std::path::Path) -> bool {
    cmux_cli_client::run_query(socket.to_path_buf(), cmux_cli_protocol::Command::ListTabs)
        .await
        .is_ok()
}

fn start_server_background(socket: &std::path::Path) -> Result<()> {
    if let Some(parent) = socket.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let exe = std::env::current_exe()?;
    probe::log_event(
        "cmx",
        "server_spawn_start",
        &[
            ("exe", exe.display().to_string()),
            ("socket", socket.display().to_string()),
        ],
    );
    let child = ProcessCommand::new(exe)
        .arg("--socket")
        .arg(socket)
        .arg("server")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()?;
    probe::log_event(
        "cmx",
        "server_spawn_done",
        &[("child_pid", child.id().to_string())],
    );
    Ok(())
}

async fn wait_for_server(socket: &std::path::Path) -> Result<()> {
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(5);
    let start_ms = probe::mono_ms();
    let mut attempts: u64 = 0;
    while tokio::time::Instant::now() < deadline {
        attempts = attempts.saturating_add(1);
        if server_reachable(socket).await {
            probe::log_event(
                "cmx",
                "server_wait_ready",
                &[
                    ("attempts", attempts.to_string()),
                    (
                        "elapsed_ms",
                        probe::mono_ms().saturating_sub(start_ms).to_string(),
                    ),
                ],
            );
            return Ok(());
        }
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
    probe::log_event(
        "cmx",
        "server_wait_timeout",
        &[
            ("attempts", attempts.to_string()),
            (
                "elapsed_ms",
                probe::mono_ms().saturating_sub(start_ms).to_string(),
            ),
        ],
    );
    Err(anyhow::anyhow!(
        "server did not become reachable at {}",
        socket.display()
    ))
}

async fn query_and_print<F>(
    socket: PathBuf,
    command: cmux_cli_protocol::Command,
    on_ok: F,
) -> Result<()>
where
    F: FnOnce(Option<cmux_cli_protocol::CommandData>) -> Result<()>,
{
    let reply = cmux_cli_client::run_query(socket, command).await?;
    match reply {
        cmux_cli_protocol::CommandResult::Ok { data } => on_ok(data),
        cmux_cli_protocol::CommandResult::Err { message } => {
            Err(anyhow::anyhow!("command failed: {message}"))
        }
    }
}

async fn fire_and_forget(socket: PathBuf, command: cmux_cli_protocol::Command) -> Result<()> {
    let reply = cmux_cli_client::run_query(socket, command).await?;
    match reply {
        cmux_cli_protocol::CommandResult::Ok { .. } => Ok(()),
        cmux_cli_protocol::CommandResult::Err { message } => {
            Err(anyhow::anyhow!("command failed: {message}"))
        }
    }
}

fn default_socket_path() -> PathBuf {
    if let Ok(dir) = std::env::var("XDG_RUNTIME_DIR") {
        return PathBuf::from(dir).join("cmux-cli").join("server.sock");
    }
    // SAFETY: getuid(2) is always safe and cannot fail.
    let uid = unsafe { libc::getuid() };
    PathBuf::from(format!("/tmp/cmux-cli-{uid}")).join("server.sock")
}

fn default_snapshot_path() -> PathBuf {
    if let Ok(dir) = std::env::var("XDG_STATE_HOME") {
        return PathBuf::from(dir).join("cmux-cli").join("snapshot.json");
    }
    if let Ok(home) = std::env::var("HOME") {
        return PathBuf::from(home)
            .join(".local")
            .join("state")
            .join("cmux-cli")
            .join("snapshot.json");
    }
    PathBuf::from("/tmp/cmux-cli-snapshot.json")
}

fn default_settings_path() -> PathBuf {
    if let Ok(dir) = std::env::var("XDG_CONFIG_HOME") {
        return PathBuf::from(dir).join("cmux-cli").join("settings.json");
    }
    if let Ok(home) = std::env::var("HOME") {
        return PathBuf::from(home)
            .join(".config")
            .join("cmux-cli")
            .join("settings.json");
    }
    PathBuf::from("/tmp/cmux-cli-settings.json")
}

fn command_label(command: &Command) -> &'static str {
    match command {
        Command::Server { .. } => "server",
        Command::Attach => "attach",
        Command::Ping => "ping",
        Command::Version => "version",
        Command::ListWorkspaces { .. } => "list-workspaces",
        Command::ListSpaces { .. } => "list-spaces",
        Command::ListTabs { .. } => "list-tabs",
        Command::NewTab => "new-tab",
        Command::NewSpace { .. } => "new-space",
        Command::NewWorkspace { .. } => "new-workspace",
        Command::NextWorkspace => "next-workspace",
        Command::PrevWorkspace => "prev-workspace",
        Command::NextSpace => "next-space",
        Command::PrevSpace => "prev-space",
        Command::NextTab => "next-tab",
        Command::PrevTab => "prev-tab",
        Command::SelectTab { .. } => "select-tab",
        Command::SelectSpace { .. } => "select-space",
        Command::SelectWorkspace { .. } => "select-workspace",
        Command::CloseTab => "close-tab",
        Command::CloseSpace => "close-space",
        Command::CloseWorkspace => "close-workspace",
        Command::Send { .. } => "send",
        Command::SendKey { .. } => "send-key",
        Command::RenameTab { .. } => "rename-tab",
        Command::RenameSpace { .. } => "rename-space",
        Command::RenameWorkspace { .. } => "rename-workspace",
        Command::Rename { .. } => "rename",
        Command::CloseServer => "close-server",
        Command::Notify { .. } => "notify",
        Command::Split { .. } => "split",
        Command::Unsplit => "unsplit",
        Command::ToggleZoom => "toggle-zoom",
        Command::FocusPane { .. } => "focus-pane",
        Command::ResizePane { .. } => "resize-pane",
        Command::DisplayMessage { .. } => "display-message",
        Command::TogglePin => "toggle-pin",
        Command::SetWorkspaceColor { .. } => "set-workspace-color",
        Command::Tree { .. } => "tree",
        Command::MoveTab { .. } => "move-tab",
        Command::ReadScreen { .. } => "read-screen",
        Command::Identify { .. } => "identify",
        Command::Capabilities { .. } => "capabilities",
    }
}

#[cfg(test)]
mod key_parser_tests {
    use super::parse_named_key;

    #[test]
    fn ctrl_letters_map_to_control_bytes() {
        assert_eq!(parse_named_key("C-a"), Some(vec![0x01]));
        assert_eq!(parse_named_key("C-c"), Some(vec![0x03]));
        assert_eq!(parse_named_key("C-z"), Some(vec![0x1a]));
        assert_eq!(parse_named_key("Ctrl-d"), Some(vec![0x04]));
        assert_eq!(parse_named_key("Ctrl+X"), Some(vec![0x18]));
    }

    #[test]
    fn alt_prefix_stacks_an_escape() {
        assert_eq!(parse_named_key("M-x"), Some(vec![0x1b, b'x']));
        assert_eq!(parse_named_key("Alt-Left"), Some(b"\x1b\x1b[D".to_vec()));
        // Alt+Ctrl-c = ESC then 0x03.
        assert_eq!(parse_named_key("M-C-c"), Some(vec![0x1b, 0x03]));
    }

    #[test]
    fn named_specials() {
        assert_eq!(parse_named_key("Enter"), Some(vec![b'\r']));
        assert_eq!(parse_named_key("Esc"), Some(vec![0x1b]));
        assert_eq!(parse_named_key("Tab"), Some(vec![b'\t']));
        assert_eq!(parse_named_key("Backspace"), Some(vec![0x7f]));
        assert_eq!(parse_named_key("Space"), Some(vec![b' ']));
        assert_eq!(parse_named_key("Up"), Some(b"\x1b[A".to_vec()));
        assert_eq!(parse_named_key("F5"), Some(b"\x1b[15~".to_vec()));
        assert_eq!(parse_named_key("PageDown"), Some(b"\x1b[6~".to_vec()));
    }

    #[test]
    fn single_printable_char_passes_through() {
        assert_eq!(parse_named_key("a"), Some(vec![b'a']));
        assert_eq!(parse_named_key("/"), Some(vec![b'/']));
        assert_eq!(parse_named_key("あ"), Some("あ".as_bytes().to_vec()));
    }

    #[test]
    fn unknown_keys_return_none() {
        assert_eq!(parse_named_key("NotAKey"), None);
        assert_eq!(parse_named_key(""), None);
    }
}
