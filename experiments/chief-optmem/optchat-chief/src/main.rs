//! `optchat-chief`: the OptChat Chief host, its MCP memory tools and its
//! `agents` verbs. See README.md.

use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use optchat_chief::cli::Flags;
use optchat_chief::paths::{Paths, mux_home};

const USAGE: &str = "optchat-chief host --daemon-socket PATH [--mux-home DIR]   run the Chief host (one per MUX_HOME)
optchat-chief mcp [--socket PATH | --mux-home DIR]           stdio MCP server with zoom and date
optchat-chief agents spawn --name N --cwd DIR [--harness H] [--policy P] \"task\"
optchat-chief agents list | prompt NAME \"text\" | allow NAME [OPTION_ID] | deny NAME
Env: CMUX_DAEMON_SOCKET, MUX_HOME (~/.cmux/mux), MUX_AGENT_TOKEN_FILE, MUX_HARNESS (claude-sr),
     MUX_POLICY (approve-all), OPTCHAT_CHIEF_MODEL, ACPMUX_SOCKET / ACPMUX_HOME / ACPMUX_BIN,
     CMUX_SOCKET_PATH, CMUX_MCP_COMMAND, OPTCHAT_ANTHROPIC_BASE_URL (compactor; the team subrouter)";

fn main() {
    let started_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64);
    let args: Vec<String> = std::env::args().skip(1).collect();
    let flags = Flags::parse(&args);
    let code = match flags.words.first().map(String::as_str) {
        Some("host") => optchat_chief::host::run(&flags, started_ms),
        Some("mcp") => {
            let socket = flags.value("socket").map(PathBuf::from).unwrap_or_else(|| {
                let home = flags
                    .value("mux-home")
                    .map(PathBuf::from)
                    .unwrap_or_else(mux_home);
                Paths::new(&home).tools_socket
            });
            match optchat_chief::mcp::run(&socket) {
                Ok(()) => 0,
                Err(e) => {
                    eprintln!("optchat-chief mcp: {e}");
                    1
                }
            }
        }
        Some("agents") => match optchat_chief::agents::run(&flags) {
            Ok(out) => {
                println!("{out}");
                0
            }
            Err(e) => {
                eprintln!("chief agents: {e}");
                1
            }
        },
        Some("help") | Some("--help") => {
            println!("{USAGE}");
            0
        }
        _ => {
            eprintln!("{USAGE}");
            2
        }
    };
    std::process::exit(code);
}
