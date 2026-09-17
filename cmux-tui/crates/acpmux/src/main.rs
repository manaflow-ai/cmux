use acpmux::client::Client;
use acpmux::config::{Config, home};
use acpmux::daemon::{DaemonOptions, connect};
use acpmux::rpc::{Message, method};
use acpmux::transcript::{Item, Transcript};
use anyhow::{Result, anyhow};
use clap::{Args, Parser, Subcommand};
use serde_json::{Value, json};
use std::io::{Read, Write};
use std::path::PathBuf;
use std::sync::Arc;

#[derive(Parser)]
#[command(name = "acpmux", version, about = "tmux for ACP agents", long_about = None)]
struct Cli {
    /// Print raw JSON instead of text.
    #[arg(long, global = true)]
    json: bool,
    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand)]
enum Command {
    /// Create a session and optionally send a first prompt.
    #[command(alias = "new-session")]
    New(NewArgs),
    /// Send a prompt and stream the reply until the turn ends.
    #[command(alias = "prompt", alias = "send-keys")]
    Send {
        session: String,
        /// Prompt text. Reads stdin when omitted or "-".
        prompt: Vec<String>,
        /// Interrupt the running turn with this message when the agent supports steering.
        #[arg(long)]
        steer: bool,
        /// Return as soon as the prompt is queued.
        #[arg(long)]
        no_wait: bool,
        /// Do not stream; print only the final assistant text.
        #[arg(long, short)]
        quiet: bool,
    },
    /// List sessions on every host.
    #[command(alias = "list", alias = "list-sessions")]
    Ls,
    /// Open the TUI on a session, or on the session list.
    #[command(alias = "a")]
    Attach {
        session: Option<String>,
        /// Plain text stream instead of the TUI.
        #[arg(long)]
        plain: bool,
    },
    /// Print the dashboard URL and open it in the browser.
    Web {
        /// Only print the URL.
        #[arg(long)]
        no_open: bool,
    },
    /// Remote daemons: add, ls, rm.
    #[command(subcommand, alias = "peer", alias = "hosts")]
    Host(PeerCmd),
    /// Everything else about one session: info, cancel, stop, rename, fork, set, allow, deny, export, import, tail.
    #[command(subcommand, alias = "s")]
    Session(SessionCmd),
    /// The daemon: run, status, shutdown, config, agents.
    #[command(subcommand, alias = "d")]
    Daemon(DaemonCmd),
    // Old spellings, kept working but hidden from help.
    #[command(hide = true)]
    Tail { session: String, #[arg(long, default_value_t = 50)] last: u64, #[arg(long, short)] follow: bool },
    #[command(hide = true)]
    Info { session: String },
    #[command(hide = true)]
    Cancel { session: String },
    #[command(hide = true, alias = "kill-session")]
    Kill { session: String, #[arg(long)] purge: bool },
    #[command(hide = true, alias = "rename-session")]
    Rename { session: String, new_name: String },
    #[command(hide = true)]
    Fork { session: String, #[arg(long, short)] name: Option<String>, #[arg(long)] cwd: Option<PathBuf> },
    #[command(hide = true)]
    Set { session: String, assignment: String },
    #[command(hide = true)]
    Allow { session: String, option: Option<String> },
    #[command(hide = true)]
    Deny { session: String },
    #[command(hide = true)]
    Export { session: String, #[arg(long)] dest: Option<PathBuf> },
    #[command(hide = true)]
    Import { path: PathBuf, #[arg(long, short)] name: Option<String> },
    #[command(hide = true)]
    Agents,
    #[command(hide = true)]
    Status,
    #[command(hide = true, alias = "kill-server")]
    Shutdown,
    #[command(hide = true)]
    Config,
    #[command(subcommand, hide = true)]
    Peer(PeerCmd),
    #[command(hide = true)]
    DaemonRun {
        /// Also serve WebSocket clients, e.g. 127.0.0.1:47811
        #[arg(long)]
        listen: Option<String>,
        /// Bearer token WebSocket clients must present.
        #[arg(long)]
        token: Option<String>,
        /// Keep everything in memory. Nothing survives restart.
        #[arg(long)]
        memory: bool,
        /// Log level filter, e.g. debug or acpmux=trace
        #[arg(long, default_value = "info")]
        log: String,
    },
}

#[derive(Subcommand)]
enum SessionCmd {
    /// Show session details.
    Info { session: String },
    /// Cancel the running turn.
    Cancel { session: String },
    /// Stop the agent process. The session stays resumable.
    #[command(alias = "kill")]
    Stop { session: String, /// Also delete the log.
        #[arg(long)] purge: bool },
    /// Rename a session.
    Rename { session: String, new_name: String },
    /// Fork a session into a new one that shares the history so far.
    Fork { session: String, #[arg(long, short)] name: Option<String>, #[arg(long)] cwd: Option<PathBuf> },
    /// Change mode, model, a config option, or the permission policy: key=value.
    Set { session: String, assignment: String },
    /// Answer a pending permission request.
    Allow { session: String, option: Option<String> },
    /// Reject a pending permission request.
    Deny { session: String },
    /// Export a session bundle.
    Export { session: String, #[arg(long)] dest: Option<PathBuf> },
    /// Import a session bundle directory.
    Import { path: PathBuf, #[arg(long, short)] name: Option<String> },
    /// Print the last raw events as JSON lines; -f keeps following.
    Tail { session: String, #[arg(long, default_value_t = 50)] last: u64, #[arg(long, short)] follow: bool },
}

#[derive(Subcommand)]
enum DaemonCmd {
    /// Run the daemon in the foreground.
    Run {
        /// Also serve WebSocket clients, e.g. 127.0.0.1:47811
        #[arg(long)]
        listen: Option<String>,
        /// Bearer token WebSocket clients must present.
        #[arg(long)]
        token: Option<String>,
        /// Keep everything in memory. Nothing survives restart.
        #[arg(long)]
        memory: bool,
        /// Log level filter, e.g. debug or acpmux=trace
        #[arg(long, default_value = "info")]
        log: String,
    },
    /// Daemon status, hosts, and the web URL.
    Status,
    /// Stop the daemon and every agent process.
    #[command(alias = "kill-server")]
    Shutdown,
    /// Print the config path and contents.
    Config,
    /// Show configured agents.
    Agents,
}

#[derive(Subcommand)]
enum PeerCmd {
    /// Add a peer. URL is ws://host:port, wss://…, or ssh://host (tunnel
    /// opened by acpmux; token read from the remote config). Sessions appear
    /// as NAME/session.
    Add {
        name: String,
        url: String,
        #[arg(long)]
        token: Option<String>,
    },
    /// List peers and their connection state.
    Ls,
    /// Remove a peer.
    Rm { name: String },
}

#[derive(Args)]
struct NewArgs {
    /// Agent profile name (codex, claude, ...). Defaults to the configured default.
    #[arg(long, short)]
    agent: Option<String>,
    /// Session name. Generated when omitted.
    #[arg(long, short)]
    name: Option<String>,
    #[arg(long)]
    cwd: Option<PathBuf>,
    /// Permission policy: ask, approve-all, approve-reads, deny-all.
    #[arg(long)]
    policy: Option<String>,
    /// Optional first prompt.
    prompt: Vec<String>,
    /// Do not open the TUI after creating.
    #[arg(long, short)]
    detach: bool,
}

#[tokio::main]
async fn main() -> Result<()> {
    // `acpmux daemon` with nothing after it means `daemon run`.
    let mut argv: Vec<std::ffi::OsString> = std::env::args_os().collect();
    if argv.len() == 2 && argv[1] == "daemon" {
        argv.push("run".into());
    }
    let cli = Cli::parse_from(argv);
    let command = cli.command.map(flatten);
    match command {
        None => {
            let client = connect(true).await?;
            acpmux::tui::run(client, None).await
        }
        Some(Command::DaemonRun { listen, token, memory, log }) => {
            tracing_subscriber::fmt()
                .with_env_filter(tracing_subscriber::EnvFilter::try_new(&log).unwrap_or_else(|_| "info".into()))
                .with_target(false)
                .init();
            acpmux::daemon::run(DaemonOptions { ws_listen: listen, ws_token: token, memory }).await
        }
        Some(cmd) => run_client(cmd, cli.json).await,
    }
}

/// Map the grouped spellings onto the flat handlers.
fn flatten(c: Command) -> Command {
    match c {
        Command::Session(sc) => match sc {
            SessionCmd::Info { session } => Command::Info { session },
            SessionCmd::Cancel { session } => Command::Cancel { session },
            SessionCmd::Stop { session, purge } => Command::Kill { session, purge },
            SessionCmd::Rename { session, new_name } => Command::Rename { session, new_name },
            SessionCmd::Fork { session, name, cwd } => Command::Fork { session, name, cwd },
            SessionCmd::Set { session, assignment } => Command::Set { session, assignment },
            SessionCmd::Allow { session, option } => Command::Allow { session, option },
            SessionCmd::Deny { session } => Command::Deny { session },
            SessionCmd::Export { session, dest } => Command::Export { session, dest },
            SessionCmd::Import { path, name } => Command::Import { path, name },
            SessionCmd::Tail { session, last, follow } => Command::Tail { session, last, follow },
        },
        Command::Daemon(dc) => match dc {
            DaemonCmd::Run { listen, token, memory, log } => Command::DaemonRun { listen, token, memory, log },
            DaemonCmd::Status => Command::Status,
            DaemonCmd::Shutdown => Command::Shutdown,
            DaemonCmd::Config => Command::Config,
            DaemonCmd::Agents => Command::Agents,
        },
        Command::Host(pc) => Command::Peer(pc),
        other => other,
    }
}

fn arg_or_stdin(words: &[String]) -> Result<String> {
    let joined = words.join(" ");
    if !joined.is_empty() && joined != "-" {
        return Ok(joined);
    }
    let mut s = String::new();
    std::io::stdin().read_to_string(&mut s)?;
    let s = s.trim_end().to_owned();
    if s.is_empty() {
        return Err(anyhow!("empty prompt"));
    }
    Ok(s)
}

fn print_json(v: &Value) {
    println!("{}", serde_json::to_string_pretty(v).unwrap_or_default());
}

fn short(s: &str, n: usize) -> String {
    let s: String = s.split_whitespace().collect::<Vec<_>>().join(" ");
    if s.chars().count() > n {
        format!("{}…", s.chars().take(n.saturating_sub(1)).collect::<String>())
    } else {
        s
    }
}

fn age(ms: u64) -> String {
    let now = acpmux::store::now_ms();
    let d = now.saturating_sub(ms) / 1000;
    if d < 60 {
        format!("{d}s")
    } else if d < 3600 {
        format!("{}m", d / 60)
    } else if d < 86_400 {
        format!("{}h", d / 3600)
    } else {
        format!("{}d", d / 86_400)
    }
}

async fn run_client(cmd: Command, json_out: bool) -> Result<()> {
    match cmd {
        Command::Ls => {
            let client = connect(true).await?;
            let v = client.request(method::MUX_SESSIONS, json!({})).await?;
            if json_out {
                print_json(&v);
                return Ok(());
            }
            let sessions = v.get("sessions").and_then(Value::as_array).cloned().unwrap_or_default();
            if sessions.is_empty() {
                println!("no sessions (create one: acpmux new -a codex -n my-task)");
                return Ok(());
            }
            println!("{:<24} {:<8} {:<13} {:>5} {:<6} {}", "NAME", "AGENT", "STATUS", "TURNS", "AGE", "LAST");
            for s in sessions {
                let g = |k: &str| s.get(k).and_then(Value::as_str).unwrap_or("").to_owned();
                let mut status = g("status");
                if s.get("pendingPermissions").and_then(Value::as_u64).unwrap_or(0) > 0 {
                    status = "waiting!".into();
                }
                println!(
                    "{:<24} {:<8} {:<13} {:>5} {:<6} {}",
                    short(&g("name"), 24),
                    short(&g("agent"), 8),
                    status,
                    s.get("turnCount").and_then(Value::as_u64).unwrap_or(0),
                    age(s.get("updatedAt").and_then(Value::as_u64).unwrap_or(0)),
                    short(&s.get("lastPrompt").and_then(Value::as_str).unwrap_or(""), 50)
                );
            }
            Ok(())
        }
        Command::New(args) => {
            let client = connect(true).await?;
            if let Some(n) = &args.name {
                acpmux::session_name::validate(n).map_err(|e| anyhow!(e))?;
            }
            let cwd = args.cwd.unwrap_or(std::env::current_dir()?);
            let mut meta = json!({});
            if let Some(a) = &args.agent {
                meta["agent"] = json!(a);
            }
            if let Some(n) = &args.name {
                meta["name"] = json!(n);
            }
            if let Some(p) = &args.policy {
                meta["policy"] = json!(p);
            }
            let v = client
                .request(method::SESSION_NEW, json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": meta}}))
                .await?;
            let id = v.get("sessionId").and_then(Value::as_str).unwrap_or("").to_owned();
            let name = v.pointer("/_meta/acpmux/name").and_then(Value::as_str).unwrap_or(&id).to_owned();
            if json_out {
                print_json(&v);
            } else {
                println!("created {name} ({})", &id[..8.min(id.len())]);
            }
            if !args.prompt.is_empty() {
                let text = args.prompt.join(" ");
                if args.detach {
                    let c = client.clone();
                    let id2 = id.clone();
                    tokio::spawn(async move {
                        let _ = c.request(method::SESSION_PROMPT, json!({"sessionId": id2, "prompt": [{"type": "text", "text": text}]})).await;
                    });
                    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
                    return Ok(());
                }
                return stream_prompt(client, &id, &text, false, false, json_out).await;
            }
            if args.detach || json_out {
                return Ok(());
            }
            acpmux::tui::run(client, Some(id)).await
        }
        Command::Send { session, prompt, steer, no_wait, quiet } => {
            let client = connect(true).await?;
            let text = arg_or_stdin(&prompt)?;
            let id = resolve_id(&client, &session).await?;
            if no_wait {
                let c = client.clone();
                let id2 = id.clone();
                tokio::spawn(async move {
                    let _ = c.request(method::SESSION_PROMPT, json!({"sessionId": id2, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": {"steer": steer}}})).await;
                });
                tokio::time::sleep(std::time::Duration::from_millis(200)).await;
                println!("queued");
                return Ok(());
            }
            stream_prompt(client, &id, &text, steer, quiet, json_out).await
        }
        Command::Attach { session, plain } => {
            let client = connect(true).await?;
            let id = match &session {
                Some(s) => Some(resolve_id(&client, s).await?),
                None => None,
            };
            if plain {
                let id = id.ok_or_else(|| anyhow!("--plain needs a session"))?;
                return plain_attach(client, &id).await;
            }
            acpmux::tui::run(client, id).await
        }
        Command::Tail { session, last, follow } => {
            let client = connect(true).await?;
            let id = resolve_id(&client, &session).await?;
            let mut notes = client.notifications().await.unwrap();
            let v = client.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": last})).await?;
            for e in v.get("events").and_then(Value::as_array).cloned().unwrap_or_default() {
                println!("{e}");
            }
            if !follow {
                return Ok(());
            }
            let stdout = std::io::stdout();
            while let Some(m) = notes.recv().await {
                if let Message::Notification { method: m, params } = m {
                    let p = params.unwrap_or(Value::Null);
                    let sid = p.get("sessionId").and_then(Value::as_str).unwrap_or("");
                    if sid != id {
                        continue;
                    }
                    let mut lock = stdout.lock();
                    let _ = writeln!(lock, "{}", json!({"method": m, "params": p}));
                }
            }
            Ok(())
        }
        Command::Info { session } => {
            let client = connect(true).await?;
            let id = resolve_id(&client, &session).await?;
            let v = client.request(method::MUX_INFO, json!({"sessionId": id})).await?;
            if json_out {
                print_json(&v);
                return Ok(());
            }
            let g = |k: &str| v.get(k).map(|x| match x { Value::String(s) => s.clone(), Value::Null => "-".into(), o => o.to_string() }).unwrap_or_default();
            println!("name:      {}", g("name"));
            println!("id:        {}", g("sessionId"));
            println!("agent:     {}  (agent session {})", g("agent"), g("agentSessionId"));
            println!("cwd:       {}", g("cwd"));
            println!("status:    {}", g("status"));
            println!("mode:      {}", g("currentModeId"));
            println!("model:     {}", g("model"));
            println!("policy:    {}", g("policy"));
            println!("turns:     {}   events: {}   last seq: {}", g("turnCount"), g("eventCount"), g("lastSeq"));
            if let Some(modes) = v.pointer("/modes/availableModes").and_then(Value::as_array) {
                let names: Vec<String> = modes.iter().filter_map(|m| m.get("id").and_then(Value::as_str).map(str::to_owned)).collect();
                println!("modes:     {}", names.join(", "));
            }
            if let Some(opts) = v.get("configOptions").and_then(Value::as_array) {
                for o in opts {
                    let id = o.get("id").and_then(Value::as_str).unwrap_or("?");
                    let cur = o.get("currentValue").map(|x| x.to_string()).unwrap_or_default();
                    let choices: Vec<String> = o
                        .get("options")
                        .and_then(Value::as_array)
                        .map(|a| a.iter().filter_map(|c| c.get("value").and_then(Value::as_str).map(str::to_owned)).collect())
                        .unwrap_or_default();
                    println!("config:    {id} = {cur}   [{}]", choices.join(", "));
                }
            }
            if let Some(p) = v.get("pending").and_then(Value::as_array) {
                for perm in p {
                    println!("PENDING:   {} ({})", perm.pointer("/request/toolCall/title").and_then(Value::as_str).unwrap_or("permission"), perm.get("permissionId").and_then(Value::as_str).unwrap_or(""));
                }
            }
            Ok(())
        }
        Command::Cancel { session } => {
            let client = connect(true).await?;
            let id = resolve_id(&client, &session).await?;
            client.notify(method::SESSION_CANCEL, json!({"sessionId": id})).await?;
            tokio::time::sleep(std::time::Duration::from_millis(150)).await;
            println!("cancel sent");
            Ok(())
        }
        Command::Kill { session, purge } => {
            let client = connect(true).await?;
            let id = resolve_id(&client, &session).await?;
            let v = client.request(method::MUX_KILL, json!({"sessionId": id, "purge": purge})).await?;
            if json_out { print_json(&v) } else { println!("{}", if purge { "purged" } else { "closed" }) }
            Ok(())
        }
        Command::Rename { session, new_name } => {
            let client = connect(true).await?;
            let id = resolve_id(&client, &session).await?;
            let v = client.request(method::MUX_RENAME, json!({"sessionId": id, "newName": new_name})).await?;
            if json_out { print_json(&v) } else { println!("renamed") }
            Ok(())
        }
        Command::Fork { session, name, cwd } => {
            let client = connect(true).await?;
            let id = resolve_id(&client, &session).await?;
            let mut p = json!({"sessionId": id, "mcpServers": [], "_meta": {"acpmux": {}}});
            if let Some(c) = cwd { p["cwd"] = json!(c); }
            if let Some(n) = name { p["_meta"]["acpmux"]["name"] = json!(n); }
            let v = client.request(method::SESSION_FORK, p).await?;
            if json_out { print_json(&v) } else {
                println!("forked into {}", v.pointer("/_meta/acpmux/name").and_then(Value::as_str).unwrap_or("?"));
            }
            Ok(())
        }
        Command::Set { session, assignment } => {
            let client = connect(true).await?;
            let id = resolve_id(&client, &session).await?;
            let (k, val) = assignment.split_once('=').ok_or_else(|| anyhow!("use key=value"))?;
            let v = match k {
                "mode" => client.request(method::SESSION_SET_MODE, json!({"sessionId": id, "modeId": val})).await?,
                "model" => client.request(method::SESSION_SET_MODEL, json!({"sessionId": id, "modelId": val})).await?,
                "policy" => client.request(method::MUX_SET_POLICY, json!({"sessionId": id, "policy": val})).await?,
                other => {
                    let value = match val { "true" => json!(true), "false" => json!(false), s => json!(s) };
                    client.request(method::SESSION_SET_CONFIG_OPTION, json!({"sessionId": id, "configId": other, "value": value})).await?
                }
            };
            if json_out { print_json(&v) } else { println!("ok") }
            Ok(())
        }
        Command::Allow { session, option } => answer_permission(&session, option, true).await,
        Command::Deny { session } => answer_permission(&session, None, false).await,
        Command::Export { session, dest } => {
            let client = connect(true).await?;
            let id = resolve_id(&client, &session).await?;
            let mut p = json!({"sessionId": id});
            if let Some(d) = dest { p["dest"] = json!(std::path::absolute(d)?); }
            let v = client.request(method::MUX_EXPORT, p).await?;
            if json_out { print_json(&v) } else { println!("{}", v.get("path").and_then(Value::as_str).unwrap_or("")) }
            Ok(())
        }
        Command::Import { path, name } => {
            let client = connect(true).await?;
            let mut p = json!({"path": std::path::absolute(path)?});
            if let Some(n) = name { p["name"] = json!(n); }
            let v = client.request(method::MUX_IMPORT, p).await?;
            if json_out { print_json(&v) } else { println!("imported as {}", v.get("name").and_then(Value::as_str).unwrap_or("?")) }
            Ok(())
        }
        Command::Agents => {
            let client = connect(true).await?;
            let v = client.request(method::MUX_AGENTS, json!({})).await?;
            if json_out { print_json(&v); return Ok(()); }
            let default = v.get("defaultAgent").and_then(Value::as_str).unwrap_or("");
            if let Some(agents) = v.get("agents").and_then(Value::as_object) {
                if agents.is_empty() {
                    println!("no agents configured. Edit {}", Config::path().display());
                }
                for (name, prof) in agents {
                    let argv: Vec<String> = prof.get("argv").and_then(Value::as_array).map(|a| a.iter().filter_map(|s| s.as_str().map(str::to_owned)).collect()).unwrap_or_default();
                    println!("{}{:<10} {}", if name == default { "*" } else { " " }, name, argv.join(" "));
                }
            }
            Ok(())
        }
        Command::Status => {
            match connect(false).await {
                Ok(client) => {
                    let v = client.request(method::MUX_STATUS, json!({})).await?;
                    if json_out { print_json(&v); return Ok(()); }
                    println!("acpmux {} pid {} up {}", v.get("version").and_then(Value::as_str).unwrap_or(""), v.get("pid").and_then(Value::as_u64).unwrap_or(0), age(v.get("startedAt").and_then(Value::as_u64).unwrap_or(0)));
                    println!("socket:   {}", v.get("socket").and_then(Value::as_str).unwrap_or(""));
                    println!("home:     {}", v.get("home").and_then(Value::as_str).unwrap_or(""));
                    println!("store:    {}", v.pointer("/store/mode").and_then(Value::as_str).unwrap_or(""));
                    println!("sessions: {} ({} live agents)", v.get("sessions").and_then(Value::as_u64).unwrap_or(0), v.get("liveAgents").and_then(Value::as_u64).unwrap_or(0));
                    println!("policy:   {}", v.get("permissionPolicy").and_then(Value::as_str).unwrap_or(""));
                    println!("web:      {}", v.get("webUrl").and_then(Value::as_str).unwrap_or("-"));
                    for p in v.get("peers").and_then(Value::as_array).cloned().unwrap_or_default() {
                        println!(
                            "peer:     {} {} ({} sessions) {}",
                            p.get("name").and_then(Value::as_str).unwrap_or(""),
                            if p.get("connected").and_then(Value::as_bool).unwrap_or(false) { "connected" } else { "offline" },
                            p.get("sessions").and_then(Value::as_u64).unwrap_or(0),
                            p.get("url").and_then(Value::as_str).unwrap_or("")
                        );
                    }
                }
                Err(e) => {
                    if json_out { print_json(&json!({"running": false, "error": e.to_string()})) } else { println!("daemon not running ({e})") }
                }
            }
            Ok(())
        }
        Command::Shutdown => {
            let client = connect(false).await?;
            let _ = client.request(method::MUX_SHUTDOWN, json!({})).await;
            println!("shutdown requested");
            Ok(())
        }
        Command::Config => {
            let path = Config::path();
            println!("# {}", path.display());
            match std::fs::read_to_string(&path) {
                Ok(s) => println!("{s}"),
                Err(_) => {
                    let cfg = Config::load()?;
                    println!("# (not written yet; effective defaults below)");
                    println!("{}", serde_json::to_string_pretty(&cfg)?);
                }
            }
            println!("# home: {}", home().display());
            Ok(())
        }
        Command::Web { no_open } => {
            let client = connect(true).await?;
            let v = client.request(method::MUX_STATUS, json!({})).await?;
            let url = v.get("webUrl").and_then(Value::as_str).ok_or_else(|| anyhow!("daemon has no web listener"))?.to_owned();
            println!("{url}");
            if !no_open {
                let _ = std::process::Command::new(if cfg!(target_os = "macos") { "open" } else { "xdg-open" }).arg(&url).spawn();
            }
            Ok(())
        }
        Command::Peer(cmd) => {
            let client = connect(true).await?;
            let v = match cmd {
                PeerCmd::Add { name, url, token } => {
                    let mut p = json!({"name": name, "url": url});
                    if let Some(t) = token { p["token"] = json!(t); }
                    client.request("_acpmux/peer_add", p).await?;
                    // Give the connect loop a moment so the listing shows the real state.
                    tokio::time::sleep(std::time::Duration::from_millis(1500)).await;
                    client.request("_acpmux/peers", json!({})).await?
                }
                PeerCmd::Ls => client.request("_acpmux/peers", json!({})).await?,
                PeerCmd::Rm { name } => client.request("_acpmux/peer_remove", json!({"name": name})).await?,
            };
            if json_out { print_json(&v); return Ok(()); }
            let peers = v.get("peers").and_then(Value::as_array).cloned().unwrap_or_default();
            if peers.is_empty() {
                println!("no peers (add one: acpmux peer add sandbox-a ws://host:47811 --token T)");
            }
            for p in peers {
                let connected = p.get("connected").and_then(Value::as_bool).unwrap_or(false);
                println!(
                    "{:<16} {:<10} {:>3} sessions  {}{}",
                    p.get("name").and_then(Value::as_str).unwrap_or(""),
                    if connected { "connected" } else { "offline" },
                    p.get("sessions").and_then(Value::as_u64).unwrap_or(0),
                    p.get("url").and_then(Value::as_str).unwrap_or(""),
                    p.get("error").and_then(Value::as_str).map(|e| format!("  ({e})")).unwrap_or_default(),
                );
            }
            Ok(())
        }
        Command::DaemonRun { .. } | Command::Session(_) | Command::Daemon(_) | Command::Host(_) => unreachable!(),
    }
}

async fn resolve_id(client: &Client, key: &str) -> Result<String> {
    let v = client.request(method::MUX_INFO, json!({"sessionId": key})).await?;
    Ok(v.get("sessionId").and_then(Value::as_str).unwrap_or(key).to_owned())
}

async fn answer_permission(session: &str, option: Option<String>, allow: bool) -> Result<()> {
    let client = connect(true).await?;
    let id = resolve_id(&client, session).await?;
    let info = client.request(method::MUX_INFO, json!({"sessionId": id})).await?;
    let pending = info.get("pending").and_then(Value::as_array).cloned().unwrap_or_default();
    let Some(first) = pending.first() else {
        return Err(anyhow!("no pending permission"));
    };
    let pid = first.get("permissionId").and_then(Value::as_str).unwrap_or("").to_owned();
    let options = first.pointer("/request/options").and_then(Value::as_array).cloned().unwrap_or_default();
    let pick = |kinds: &[&str]| {
        kinds.iter().find_map(|k| {
            options
                .iter()
                .find(|o| o.get("kind").and_then(Value::as_str) == Some(k))
                .and_then(|o| o.get("optionId").and_then(Value::as_str).map(str::to_owned))
        })
    };
    let option_id = match (option, allow) {
        (Some(o), _) => Some(o),
        (None, true) => pick(&["allow_once", "allow_always"]),
        (None, false) => pick(&["reject_once", "reject_always"]),
    };
    client
        .request(method::MUX_PERMISSION_RESPOND, json!({"sessionId": id, "permissionId": pid, "optionId": option_id}))
        .await?;
    println!("{}", if allow { "allowed" } else { "denied" });
    Ok(())
}

/// Send a prompt and print the reply as it streams.
async fn stream_prompt(client: Arc<Client>, id: &str, text: &str, steer: bool, quiet: bool, json_out: bool) -> Result<()> {
    let mut notes = client.notifications().await.ok_or_else(|| anyhow!("notifications already taken"))?;
    client.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 0})).await?;
    let c = client.clone();
    let id2 = id.to_owned();
    let text2 = text.to_owned();
    let turn = tokio::spawn(async move {
        c.request(
            method::SESSION_PROMPT,
            json!({"sessionId": id2, "prompt": [{"type": "text", "text": text2}], "_meta": {"acpmux": {"steer": steer}}}),
        )
        .await
    });
    let mut t = Transcript::default();
    let mut printed_assistant = 0usize;
    let mut last_tool = String::new();
    let stdout = std::io::stdout();
    let mut turn = turn;
    let result = loop {
        tokio::select! {
            r = &mut turn => break r?,
            n = notes.recv() => {
                let Some(m) = n else { return Err(anyhow!("daemon connection closed")) };
                let Message::Notification { method: m, params } = m else { continue };
                let p = params.unwrap_or(Value::Null);
                if p.get("sessionId").and_then(Value::as_str) != Some(id) { continue; }
                if json_out {
                    println!("{}", json!({"method": m, "params": p}));
                    continue;
                }
                match m.as_str() {
                    method::SESSION_UPDATE => {
                        t.apply_update(&p);
                        if quiet { continue; }
                        let mut out = stdout.lock();
                        if let Some(Item::Assistant { text }) = t.items.last() {
                            if text.len() > printed_assistant {
                                let _ = write!(out, "{}", &text[printed_assistant..]);
                                let _ = out.flush();
                                printed_assistant = text.len();
                            }
                        } else {
                            printed_assistant = 0;
                        }
                        if let Some(Item::Tool { title, status, kind, .. }) = t.items.last() {
                            let line = format!("[{kind} {status}] {title}");
                            if line != last_tool {
                                let _ = writeln!(out, "\n\x1b[2m{line}\x1b[0m");
                                last_tool = line;
                            }
                        }
                    }
                    method::MUX_PERMISSION_PENDING => {
                        let title = p.pointer("/request/toolCall/title").and_then(Value::as_str).unwrap_or("permission");
                        eprintln!("\n\x1b[33mpermission needed:\x1b[0m {title}  (answer with: acpmux allow {id} | acpmux deny {id})");
                    }
                    _ => {}
                }
            }
        }
    };
    match result {
        Ok(v) => {
            if quiet {
                if let Some(Item::Assistant { text }) = t.items.iter().rev().find(|i| matches!(i, Item::Assistant { .. })) {
                    println!("{text}");
                }
            } else if json_out {
                print_json(&v);
            } else {
                let stop = v.get("stopReason").and_then(Value::as_str).unwrap_or("end_turn");
                if stop != "end_turn" {
                    eprintln!("\n\x1b[2m[{stop}]\x1b[0m");
                } else {
                    println!();
                }
            }
            Ok(())
        }
        Err(e) => Err(e),
    }
}

/// Plain streaming attach: prints everything that happens in the session.
async fn plain_attach(client: Arc<Client>, id: &str) -> Result<()> {
    let mut notes = client.notifications().await.ok_or_else(|| anyhow!("notifications already taken"))?;
    let v = client.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 200})).await?;
    let mut t = Transcript::default();
    for e in v.get("events").and_then(Value::as_array).cloned().unwrap_or_default() {
        t.apply_event(&e);
    }
    for item in &t.items {
        print_item(item);
    }
    let mut printed = t.items.len();
    let mut assistant_len = 0usize;
    while let Some(m) = notes.recv().await {
        let Message::Notification { method: m, params } = m else { continue };
        let p = params.unwrap_or(Value::Null);
        if p.get("sessionId").and_then(Value::as_str) != Some(id) {
            continue;
        }
        match m.as_str() {
            method::SESSION_UPDATE => t.apply_update(&p),
            method::MUX_EVENT => t.apply_event(&p),
            _ => continue,
        }
        // Print new whole items, and stream the trailing assistant item.
        while printed < t.items.len().saturating_sub(1) {
            print_item(&t.items[printed]);
            printed += 1;
            assistant_len = 0;
        }
        if let Some(last) = t.items.last() {
            if printed == t.items.len() - 1 {
                match last {
                    Item::Assistant { text } => {
                        if assistant_len == 0 {
                            print!("\x1b[1massistant:\x1b[0m ");
                        }
                        if text.len() > assistant_len {
                            print!("{}", &text[assistant_len..]);
                            let _ = std::io::stdout().flush();
                            assistant_len = text.len();
                        }
                    }
                    Item::Thought { .. } => {}
                    other => {
                        print_item(other);
                        printed += 1;
                        assistant_len = 0;
                    }
                }
            }
        }
    }
    Ok(())
}

fn print_item(item: &Item) {
    match item {
        Item::User { text, steer, queued } => println!("\x1b[36muser{}:\x1b[0m {text}", if *steer { " (steer)" } else if *queued { " (queued)" } else { "" }),
        Item::Assistant { text } => println!("\x1b[1massistant:\x1b[0m {text}"),
        Item::Thought { text } => println!("\x1b[2mthought: {}\x1b[0m", short(text, 200)),
        Item::Tool { title, kind, status, .. } => println!("\x1b[2m[{kind} {status}] {title}\x1b[0m"),
        Item::Plan { entries } => {
            println!("\x1b[35mplan:\x1b[0m");
            for (s, c) in entries {
                println!("  [{s}] {c}");
            }
        }
        Item::Permission { title, decided, .. } => match decided {
            Some(d) => println!("\x1b[33mpermission {title}: {d}\x1b[0m"),
            None => println!("\x1b[33mpermission needed: {title}\x1b[0m"),
        },
        Item::Status { text } => println!("\x1b[2m-- {text}\x1b[0m"),
        Item::TurnEnd { stop } => println!("\x1b[2m-- turn end ({stop})\x1b[0m"),
        Item::Error { text } => println!("\x1b[31merror: {text}\x1b[0m"),
        Item::Stderr { text } => println!("\x1b[2mstderr: {text}\x1b[0m"),
    }
}
