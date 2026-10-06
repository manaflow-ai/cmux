//! `optchat-chief`: the OptChat Chief host, its MCP memory tools and its
//! `agents` verbs. See README.md.

use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use optchat_chief::cli::Flags;
use optchat_chief::paths::{Paths, mux_home};

const USAGE: &str = "optchat-chief host --daemon-socket PATH [--mux-home DIR]   run the Chief host (one per MUX_HOME)
optchat-chief mcp [--socket PATH | --mux-home DIR]           stdio MCP server with zoom and date
optchat-chief zoom ID N | date ID [--socket PATH | --mux-home DIR]  the memory tools as commands (harnesses without MCP)
optchat-chief agents spawn --name N --cwd DIR [--harness H] [--policy P] \"task\"
optchat-chief agents list | prompt NAME \"text\" | allow NAME [OPTION_ID] | deny NAME
optchat-chief browse [--mux-home DIR] [--out FILE]          the whole memory as one HTML page
optchat-chief import [--mux-home DIR] FILE                  append JSON lines {\"text\", \"kind\"?, \"date\"?} (host stopped)
optchat-chief import-claude-code dry-run|write [--projects DIR] [--mux-home DIR] [--append-after-live]
                                                           Claude Code transcripts (default ~/.claude/projects) as messages;
                                                           dry-run prints counts only, write appends them (host stopped)
Env: CMUX_DAEMON_SOCKET, MUX_HOME (~/.cmux/mux), MUX_AGENT_TOKEN_FILE,
     OPTCHAT_CHIEF_HARNESS / MUX_HARNESS (claude-sr), OPTCHAT_COMPACTOR_HARNESS (the Chief's),
     MUX_POLICY (approve-all), OPTCHAT_CHIEF_MODEL, ACPMUX_SOCKET / ACPMUX_HOME / ACPMUX_BIN,
     CMUX_SOCKET_PATH, CMUX_MCP_COMMAND, OPTCHAT_ANTHROPIC_BASE_URL (compactor; the team subrouter)";

fn main() {
    let started_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64);
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    // A boolean flag: taken out before parsing, which would read the next
    // argument as its value.
    let append_after_live = args.iter().any(|a| a == "--append-after-live");
    args.retain(|a| a != "--append-after-live");
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
        Some(tool @ ("zoom" | "date")) => {
            let socket = flags
                .value("socket")
                .map(PathBuf::from)
                .unwrap_or_else(|| Paths::new(&home(&flags)).tools_socket);
            let args: Vec<&str> = flags.words.iter().skip(1).map(String::as_str).collect();
            let call = match (tool, args.as_slice()) {
                ("zoom", [id, n]) => optchat_chief::tools::Call::parse(
                    "zoom",
                    &serde_json::json!({"id": id, "n": n}),
                ),
                ("date", [id]) => {
                    optchat_chief::tools::Call::parse("date", &serde_json::json!({"id": id}))
                }
                _ => Err(format!(
                    "usage: optchat-chief {tool} {}",
                    if tool == "zoom" { "ID N" } else { "ID" }
                )),
            };
            match call.and_then(|c| optchat_chief::tools::ask(&socket, c)) {
                Ok(text) => {
                    println!("{text}");
                    0
                }
                Err(e) => {
                    eprintln!("optchat-chief {tool}: {e}");
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
        Some("browse") => {
            let paths = Paths::new(&home(&flags));
            let page = optchat_chief::tools::ask_browse(&paths.tools_socket).or_else(|_| {
                let chat = optchat_chief::browse::open_offline(&paths.chat)?;
                let page = optchat_chief::browse::html(&chat);
                chat.shutdown();
                Ok::<_, String>(page)
            });
            let out = flags
                .value("out")
                .map(PathBuf::from)
                .unwrap_or_else(|| paths.root.join("memory.html"));
            match page.and_then(|p| std::fs::write(&out, p).map_err(|e| e.to_string())) {
                Ok(()) => {
                    println!("{}", out.display());
                    0
                }
                Err(e) => {
                    eprintln!("optchat-chief browse: {e}");
                    1
                }
            }
        }
        Some("import") => {
            let paths = Paths::new(&home(&flags));
            let result = flags
                .words
                .get(1)
                .ok_or_else(|| USAGE.to_owned())
                .and_then(|file| std::fs::read_to_string(file).map_err(|e| format!("{file}: {e}")))
                .and_then(|text| optchat_chief::browse::parse_import(&text))
                .and_then(|items| optchat_chief::browse::import(&paths.chat, &items));
            match result {
                Ok(n) => {
                    println!("imported {n} messages");
                    0
                }
                Err(e) => {
                    eprintln!("optchat-chief import: {e}");
                    1
                }
            }
        }
        Some("import-claude-code") => {
            let paths = Paths::new(&home(&flags));
            let projects = flags
                .values
                .get("projects")
                .map(PathBuf::from)
                .unwrap_or_else(|| {
                    let user_home = std::env::var_os("HOME")
                        .map(PathBuf::from)
                        .unwrap_or_default();
                    optchat_chief::claude_import::default_projects_dir(
                        &user_home,
                        std::env::var("CLAUDE_CONFIG_DIR").ok(),
                    )
                });
            let mode = flags.words.get(1).map(String::as_str);
            let converted = match mode {
                Some("dry-run" | "write") => {
                    optchat_chief::claude_import::convert_projects(&projects)
                        .map_err(|e| format!("{}: {e}", projects.display()))
                }
                _ => Err(USAGE.to_owned()),
            };
            match converted.and_then(|(items, stats)| {
                println!("{}: {stats}", projects.display());
                if mode == Some("write") {
                    optchat_chief::claude_import::import_history(
                        &paths.chat,
                        &items,
                        append_after_live,
                    )
                    .map(Some)
                } else {
                    match optchat_chief::claude_import::existing_messages(&paths.chat) {
                        Ok(n) => {
                            if let Some(warning) = optchat_chief::claude_import::order_warning(n) {
                                println!("warning: {warning}");
                            }
                        }
                        Err(e) => println!("warning: cannot count the memory's messages: {e}"),
                    }
                    Ok(None)
                }
            }) {
                Ok(Some(n)) => {
                    println!("imported {n} messages");
                    0
                }
                Ok(None) => {
                    println!("dry run: nothing written");
                    0
                }
                Err(e) => {
                    eprintln!("optchat-chief import-claude-code: {e}");
                    1
                }
            }
        }
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

fn home(flags: &Flags) -> PathBuf {
    flags
        .value("mux-home")
        .map(PathBuf::from)
        .unwrap_or_else(mux_home)
}
