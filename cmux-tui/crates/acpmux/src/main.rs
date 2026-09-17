use acpmux::daemon::{DaemonOptions, connect};
use anyhow::Result;
use clap::{Args, Parser, Subcommand};
use std::path::PathBuf;

mod cli;
use cli::run::run_client;

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
    /// Create a session and optionally send a first prompt. `run` is the
    /// same with --quiet: it prints only the final reply.
    #[command(alias = "new-session", alias = "run")]
    New(NewArgs),
    /// Block until a session resolves: its turn ends or it needs a permission
    /// answer. Returns on the first one unless --all. Exit 0 when a turn
    /// ended, 2 when a permission is waiting, 3 on timeout.
    #[command(alias = "wait-for")]
    Wait {
        /// Session names or ids. Every running session on every host when omitted.
        sessions: Vec<String>,
        /// Give up after this many seconds.
        #[arg(long)]
        timeout: Option<u64>,
        /// Wait for every named session, not just the first to resolve.
        #[arg(long)]
        all: bool,
        #[arg(long, hide = true)]
        any: bool,
        /// Also print each finished session's last reply.
        #[arg(long, short)]
        print: bool,
    },
    /// Print the last reply of a session (plain text).
    #[command(alias = "reply")]
    Last {
        session: String,
        /// How many replies, newest last.
        #[arg(long, short = 'n', default_value_t = 1)]
        count: usize,
    },
    /// List pending permission requests across sessions, with the option ids to answer them.
    Pending,
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
    Ls {
        /// Only sessions in this state: running, ready, idle, closed, waiting.
        #[arg(long)]
        status: Option<String>,
        /// Only sessions with a pending permission request.
        #[arg(long)]
        pending: bool,
    },
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
    /// Permission policy: ask, approve-reads, approve-edits, approve-all, deny-all.
    #[arg(long)]
    policy: Option<String>,
    /// Model for the new session (see `acpmux ls` pickers for ids).
    #[arg(long, short)]
    model: Option<String>,
    /// Thinking effort: default, low, medium, high, xhigh, max (Codex adds ultra).
    #[arg(long, short)]
    effort: Option<String>,
    /// Optional first prompt.
    prompt: Vec<String>,
    /// Do not open the TUI after creating.
    #[arg(long, short)]
    detach: bool,
    /// With a prompt: print only the final reply (implied by `acpmux run`).
    #[arg(long, short)]
    quiet: bool,
}

#[tokio::main]
async fn main() -> Result<()> {
    // `acpmux daemon` with nothing after it means `daemon run`.
    let mut argv: Vec<std::ffi::OsString> = std::env::args_os().collect();
    if argv.len() == 2 && argv[1] == "daemon" {
        argv.push("run".into());
    }
    let run_alias = argv.get(1).map(|a| a == "run").unwrap_or(false);
    let cli = Cli::parse_from(argv);
    let command = cli.command.map(flatten).map(|c| match c {
        Command::New(mut a) if run_alias => {
            a.quiet = true;
            a.detach = true;
            Command::New(a)
        }
        other => other,
    });
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

