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

use std::collections::{BTreeSet, VecDeque};
use std::io::Write;
use std::path::PathBuf;

use anyhow::{Result, anyhow, bail};
use comeup_client::UnixClient;
use comeup_protocol::{
    ClientAuth, ClientMsg, Command, Delta, Focus, ServerMsg, Viewport, VisibleTerminal,
};
use tokio::io::{AsyncBufReadExt, BufReader};

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse(std::env::args().skip(1))?;
    let auth = client_auth();
    let mut client = UnixClient::connect_with_auth(
        &args.socket,
        Viewport {
            cols: args.cols,
            rows: args.rows,
        },
        auth,
    )
    .await?;

    let mut focus = client.snapshot().focus;
    let size = client
        .snapshot()
        .terminals
        .iter()
        .find(|terminal| terminal.id == focus.terminal_id)
        .map_or(
            Viewport {
                cols: args.cols,
                rows: args.rows,
            },
            |terminal| terminal.size,
        );
    println!(
        "COMEUP_TUI_READY client={} terminal={} size={}x{}",
        client.client_id(),
        focus.terminal_id,
        size.cols,
        size.rows
    );
    flush_stdout();

    let mut stdin = BufReader::new(tokio::io::stdin()).lines();
    let mut next_command_id = 1_u64;
    let mut next_input_seq = 1_u64;
    let mut pending_focus_command_ids = BTreeSet::new();
    let mut queued_focus_lines = VecDeque::<String>::new();

    loop {
        if pending_focus_command_ids.is_empty()
            && let Some(line) = queued_focus_lines.pop_front()
        {
            let should_quit = handle_command_line(
                &mut client,
                &line,
                &mut focus,
                &mut next_command_id,
                &mut next_input_seq,
            )
            .await?
            .apply(&mut pending_focus_command_ids);
            if should_quit {
                break;
            }
            continue;
        }

        tokio::select! {
            biased;
            msg = client.recv() => {
                let Some(msg) = msg? else {
                    break;
                };
                if let Some(command_id) = handle_server_msg(msg, &mut focus) {
                    pending_focus_command_ids.remove(&command_id);
                }
            }
            line = stdin.next_line() => {
                let Some(line) = line? else {
                    break;
                };
                if !pending_focus_command_ids.is_empty() && command_needs_current_focus(&line) {
                    queued_focus_lines.push_back(line);
                    continue;
                }
                if handle_command_line(
                    &mut client,
                    &line,
                    &mut focus,
                    &mut next_command_id,
                    &mut next_input_seq,
                ).await?
                .apply(&mut pending_focus_command_ids) {
                    break;
                }
            }
        }
    }

    Ok(())
}

async fn handle_command_line(
    client: &mut UnixClient,
    line: &str,
    focus: &mut Focus,
    next_command_id: &mut u64,
    next_input_seq: &mut u64,
) -> Result<CommandLineOutcome> {
    let line = line.trim_end_matches(['\r', '\n']);
    if line == "quit" {
        client.send(&ClientMsg::Detach).await?;
        return Ok(CommandLineOutcome::Quit);
    }
    if let Some(title) = line.strip_prefix("new-workspace ") {
        let id = *next_command_id;
        *next_command_id = next_command_id.saturating_add(1);
        client
            .send(&ClientMsg::Command {
                id,
                command: Command::CreateWorkspace {
                    title: title.to_string(),
                },
            })
            .await?;
        return Ok(CommandLineOutcome::WaitForCommandAck(id));
    }
    if let Some(payload) = line.strip_prefix("send ") {
        let input_seq = *next_input_seq;
        *next_input_seq = next_input_seq.saturating_add(1);
        client
            .send(&ClientMsg::TerminalInput {
                terminal_id: focus.terminal_id,
                input_seq,
                data: format!("{payload}\n").into_bytes(),
            })
            .await?;
        return Ok(CommandLineOutcome::Continue);
    }
    if let Some(rest) = line.strip_prefix("visible ") {
        let (cols, rows) = parse_size(rest)?;
        client
            .send(&ClientMsg::VisibleTerminals {
                terminals: vec![VisibleTerminal {
                    client_id: client.client_id(),
                    terminal_id: focus.terminal_id,
                    cols,
                    rows,
                    visible: true,
                }],
            })
            .await?;
        return Ok(CommandLineOutcome::Continue);
    }
    if let Some(id) = line.strip_prefix("ping ") {
        let ping_id = id.parse::<u64>()?;
        client
            .send(&ClientMsg::Ping {
                ping_id,
                client_sent_monotonic_ns: 0,
            })
            .await?;
        return Ok(CommandLineOutcome::Continue);
    }
    bail!("unknown cmx command: {line}");
}

enum CommandLineOutcome {
    Continue,
    Quit,
    WaitForCommandAck(u64),
}

impl CommandLineOutcome {
    fn apply(self, pending_focus_command_ids: &mut BTreeSet<u64>) -> bool {
        match self {
            Self::Continue => false,
            Self::Quit => true,
            Self::WaitForCommandAck(id) => {
                pending_focus_command_ids.insert(id);
                false
            }
        }
    }
}

fn command_needs_current_focus(line: &str) -> bool {
    let line = line.trim_start();
    line.starts_with("send ") || line.starts_with("visible ")
}

fn handle_server_msg(msg: ServerMsg, focus: &mut Focus) -> Option<u64> {
    match msg {
        ServerMsg::Welcome { .. } => {}
        ServerMsg::Delta { delta } => match delta {
            Delta::WorkspaceUpsert { workspace, .. } => {
                println!("WORKSPACE id={} title={}", workspace.id, workspace.title);
            }
            Delta::TerminalUpsert { terminal, .. } => {
                println!(
                    "SIZE terminal={} {}x{}",
                    terminal.id, terminal.size.cols, terminal.size.rows
                );
            }
            Delta::FocusChanged {
                focus: new_focus, ..
            } => {
                *focus = new_focus;
                println!("FOCUS terminal={}", focus.terminal_id);
            }
            Delta::SpaceUpsert { space, .. } => {
                println!("SPACE id={} title={}", space.id, space.title);
            }
            Delta::PaneUpsert { pane, .. } => {
                println!("PANE id={} active={}", pane.id, pane.active_terminal_id);
            }
        },
        ServerMsg::TerminalOutput { terminal_id, data } => {
            let text = String::from_utf8_lossy(&data)
                .replace('\r', "\\r")
                .replace('\n', "\\n");
            println!("OUTPUT terminal={terminal_id} {text}");
        }
        ServerMsg::CommandAck { id, seq } => {
            println!("ACK id={id} seq={seq}");
            flush_stdout();
            return Some(id);
        }
        ServerMsg::Pong { ping_id, .. } => {
            println!("PONG id={ping_id}");
        }
        ServerMsg::Bye => {
            println!("BYE");
        }
        ServerMsg::Error { message } => {
            println!("ERROR {message}");
        }
    }
    flush_stdout();
    None
}

fn parse_size(rest: &str) -> Result<(u16, u16)> {
    let mut parts = rest.split_whitespace();
    let cols = parts
        .next()
        .ok_or_else(|| anyhow!("missing cols"))?
        .parse::<u16>()?;
    let rows = parts
        .next()
        .ok_or_else(|| anyhow!("missing rows"))?
        .parse::<u16>()?;
    if cols == 0 || rows == 0 {
        bail!("terminal dimensions must be greater than 0");
    }
    Ok((cols, rows))
}

fn flush_stdout() {
    let _ = std::io::stdout().flush();
}

struct Args {
    socket: PathBuf,
    cols: u16,
    rows: u16,
}

impl Args {
    fn parse(args: impl IntoIterator<Item = String>) -> Result<Self> {
        let mut socket = None;
        let mut cols = 80;
        let mut rows = 24;
        let mut iter = args.into_iter();
        while let Some(arg) = iter.next() {
            match arg.as_str() {
                "--socket" => socket = iter.next().map(PathBuf::from),
                "--cols" => {
                    cols = iter
                        .next()
                        .ok_or_else(|| anyhow!("--cols requires a value"))?
                        .parse::<u16>()?;
                }
                "--rows" => {
                    rows = iter
                        .next()
                        .ok_or_else(|| anyhow!("--rows requires a value"))?
                        .parse::<u16>()?;
                }
                "-h" | "--help" => {
                    println!("usage: cmx --socket PATH [--cols N] [--rows N]");
                    std::process::exit(0);
                }
                _ => bail!("unknown argument: {arg}"),
            }
        }
        if cols == 0 {
            bail!("--cols must be greater than 0");
        }
        if rows == 0 {
            bail!("--rows must be greater than 0");
        }

        Ok(Self {
            socket: socket.ok_or_else(|| anyhow!("--socket is required"))?,
            cols,
            rows,
        })
    }
}

fn client_auth() -> Option<ClientAuth> {
    std::env::var("COMEUP_AUTH_TOKEN")
        .ok()
        .filter(|token| !token.is_empty())
        .map(|token| ClientAuth::Bearer { token })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn args_reject_zero_dimensions() {
        assert!(
            Args::parse([
                "--socket".to_string(),
                "/tmp/comeup.sock".to_string(),
                "--cols".to_string(),
                "0".to_string(),
            ])
            .is_err()
        );
        assert!(
            Args::parse([
                "--socket".to_string(),
                "/tmp/comeup.sock".to_string(),
                "--rows".to_string(),
                "0".to_string(),
            ])
            .is_err()
        );
    }
}
