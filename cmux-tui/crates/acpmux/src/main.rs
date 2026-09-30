// Same structural lint allowance as the library crate root (src/lib.rs).
#![allow(clippy::too_many_arguments)]

use acpmux::daemon::{DaemonOptions, connect};
use anyhow::Result;
use clap::{Args, Parser, Subcommand};
use std::path::PathBuf;

mod cli;
use cli::run::run_client;

#[derive(Parser)]
#[command(name = "acpmux", version = concat!(env!("CARGO_PKG_VERSION"), " (", env!("ACPMUX_BUILD"), ")"), about = "tmux for coding-agent harnesses: Claude Code, Codex, OpenCode, pi, Gemini", long_about = None, after_help = "Agents: `acpmux guide` (also --guide, --skill) prints the full guide for driving acpmux from a script or another agent.")]
struct Cli {
    /// Print raw JSON instead of text.
    #[arg(long, global = true)]
    json: bool,
    /// Blank read-tool payloads in event output, keeping the message shape.
    #[arg(long, global = true)]
    suppress_reads: bool,
    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand)]
enum Command {
    /// Create a session and optionally send a first prompt. `run` is the
    /// same with --quiet: it prints only the final reply.
    #[command(alias = "new-session", alias = "run", alias = "exec")]
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
        /// States to wait for: ready, permission, closed, done, running. Default: ready or permission.
        #[arg(long = "until", value_delimiter = ',')]
        until: Vec<String>,
        /// Resolve when the transcript contains this text.
        #[arg(long = "match", conflicts_with = "regex")]
        match_text: Option<String>,
        /// Resolve when a transcript line matches this regular expression.
        #[arg(long)]
        regex: Option<String>,
        /// Send a terminal notification (OSC 9/99) when it resolves.
        #[arg(long)]
        notify: bool,
    },
    /// Get a session by name, or create it: idempotent for scripts.
    Ensure {
        name: String,
        /// HARNESS[/MODEL]: a family or profile, optionally with a model (`claude/opus`, `opencode/zai/glm-5.1`).
        #[arg(long, short)]
        model: Option<String>,
        /// A preset from `acpmux preset`: harness plus model, effort, policy, env.
        #[arg(long, short)]
        preset: Option<String>,
        /// Create on this peer when missing.
        #[arg(long)]
        host: Option<String>,
        #[arg(long)]
        cwd: Option<PathBuf>,
        #[arg(long)]
        policy: Option<String>,
        #[arg(long, short)]
        effort: Option<String>,
    },
    /// One turn per turn: prompt preview, status, tools, tokens, wall time.
    History {
        session: String,
        #[arg(long, short = 'n', default_value_t = 20)]
        limit: usize,
    },
    /// Run one prompt on several harnesses, one after another, and compare.
    Compare {
        /// HARNESS[/MODEL] per run: -m claude -m codex/gpt-5.5 …
        #[arg(long = "model", short = 'm', required = true)]
        harnesses: Vec<String>,
        /// The prompt.
        prompt: Vec<String>,
        #[arg(long)]
        cwd: Option<PathBuf>,
        #[arg(long)]
        policy: Option<String>,
        #[arg(long)]
        timeout: Option<u64>,
    },
    /// Print the agent guide: how a script or another agent drives acpmux. Also `guide`, `--guide`, `--skill`.
    #[command(alias = "guide")]
    Skill,
    /// Show or set session defaults per model family or alias: `defaults`, `defaults claude`,
    /// `defaults claude model=claude-opus-5 effort=high policy=approve-edits prefer=claude-sr,claude`,
    /// `defaults deepseek prefer=opencode,pi models.opencode=opencode-go/deepseek-v4-pro models.pi=openrouter/deepseek/deepseek-v4`.
    /// A name that is not a family or profile is an alias: `-u deepseek` then works. `key=` clears one key; `--clear` removes the entry.
    /// Show or set presets: `preset`, `preset deepseek harness=opencode model=opencode-go/deepseek-v4-pro effort=low`,
    /// `preset omx harness=codex 'env.CODEX_HOME=${cwd}/.codex'`. `key=` clears one key; `--clear` removes the preset.
    #[command(alias = "presets")]
    Preset {
        name: Option<String>,
        /// key=value pairs: harness, model, effort, policy, description, env.KEY
        pairs: Vec<String>,
        #[arg(long)]
        clear: bool,
    },
    Defaults {
        family: Option<String>,
        /// key=value pairs: model, effort, policy, prefer (comma list), env.KEY
        pairs: Vec<String>,
        #[arg(long)]
        clear: bool,
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
        /// Cancel the turn cooperatively after this many seconds and exit 3.
        #[arg(long)]
        timeout: Option<u64>,
        /// What to do when the turn asks for a permission: wait (default), deny, or fail (exit 5).
        #[arg(long, default_value = "wait")]
        on_permission: String,
        /// Report prompt_stalled (exit 1) when nothing happens for this many seconds after sending; 0 disables.
        #[arg(long, default_value_t = 30)]
        stall: u64,
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
        /// Only sessions carrying this tag (key or key=value).
        #[arg(long)]
        tag: Option<String>,
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
    #[command(subcommand, alias = "hosts")]
    Host(PeerCmd),
    /// Everything else about one session: info, cancel, stop, rename, fork, set, allow, deny, export, import, tail.
    #[command(subcommand, alias = "s")]
    Session(SessionCmd),
    /// The daemon: run, status, shutdown, config, harnesses, reload, models, schema.
    #[command(subcommand, alias = "d")]
    Daemon(DaemonCmd),
    // Old spellings, kept working but hidden from help.
    #[command(hide = true)]
    Tail {
        session: String,
        #[arg(long, default_value_t = 50)]
        last: u64,
        #[arg(long, short)]
        follow: bool,
        #[arg(long)]
        since: Option<String>,
    },
    #[command(hide = true)]
    TagCmd { session: String, assignments: Vec<String>, remove: Vec<String>, ttl: Option<u64> },
    #[command(hide = true)]
    RulesCmd { session: String, rules: Option<String>, clear: bool },
    #[command(hide = true)]
    Schema,
    #[command(hide = true)]
    Models {
        #[arg(long)]
        refresh: bool,
    },
    #[command(hide = true)]
    Info { session: String },
    #[command(hide = true)]
    Cancel { session: String },
    #[command(hide = true, alias = "kill-session")]
    Kill {
        session: String,
        #[arg(long)]
        purge: bool,
    },
    #[command(hide = true, alias = "rename-session")]
    Rename { session: String, new_name: String },
    #[command(hide = true)]
    Fork {
        session: String,
        #[arg(long, short)]
        name: Option<String>,
        #[arg(long)]
        cwd: Option<PathBuf>,
    },
    #[command(hide = true)]
    Set { session: String, assignment: String },
    #[command(hide = true)]
    Allow { session: String, option: Option<String> },
    #[command(hide = true)]
    Deny { session: String },
    #[command(hide = true)]
    Export {
        session: String,
        #[arg(long)]
        dest: Option<PathBuf>,
    },
    #[command(hide = true)]
    Import {
        path: PathBuf,
        #[arg(long, short)]
        name: Option<String>,
    },
    #[command(hide = true)]
    Harnesses,
    #[command(hide = true)]
    Reload,
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
        /// Write one JSON line ({"ready":true,"pid","socket","listen","webUrl"}) to this
        /// inherited file descriptor once the socket and listen address are bound.
        #[arg(long)]
        ready_fd: Option<i32>,
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
    Stop {
        session: String,
        /// Also delete the log.
        #[arg(long)]
        purge: bool,
    },
    /// Rename a session.
    Rename { session: String, new_name: String },
    /// Fork a session into a new one that shares the history so far.
    Fork {
        session: String,
        #[arg(long, short)]
        name: Option<String>,
        #[arg(long)]
        cwd: Option<PathBuf>,
    },
    /// Change mode, model, a config option, or the permission policy: key=value.
    Set { session: String, assignment: String },
    /// Answer a pending permission request.
    Allow { session: String, option: Option<String> },
    /// Reject a pending permission request.
    Deny { session: String },
    /// Export a session bundle.
    Export {
        session: String,
        #[arg(long)]
        dest: Option<PathBuf>,
    },
    /// Import a session bundle directory.
    Import {
        path: PathBuf,
        #[arg(long, short)]
        name: Option<String>,
    },
    /// Print the last raw events as JSON lines; -f keeps following.
    Tail {
        session: String,
        #[arg(long, default_value_t = 50)]
        last: u64,
        #[arg(long, short)]
        follow: bool,
        /// Start after this cursor (`<sessionId>:<seq>` or a seq). A cursor past the log is an error.
        #[arg(long)]
        since: Option<String>,
    },
    /// Label a session: key=value pairs, `--remove key`, `--ttl seconds`.
    Tag {
        session: String,
        assignments: Vec<String>,
        #[arg(long)]
        remove: Vec<String>,
        #[arg(long)]
        ttl: Option<u64>,
    },
    /// Per-tool permission rules above the policy: a JSON object, `@file`, or `--clear`; omit to show.
    Rules {
        session: String,
        rules: Option<String>,
        #[arg(long)]
        clear: bool,
    },
    /// One line per turn.
    History {
        session: String,
        #[arg(long, short = 'n', default_value_t = 20)]
        limit: usize,
    },
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
        /// Write one JSON line ({"ready":true,"pid","socket","listen","webUrl"}) to this
        /// inherited file descriptor once the socket and listen address are bound.
        #[arg(long)]
        ready_fd: Option<i32>,
    },
    /// Daemon status, hosts, and the web URL.
    Status,
    /// Stop the daemon and every agent process.
    #[command(alias = "kill-server")]
    Shutdown,
    /// Print the config path and contents.
    Config,
    /// Show configured harnesses with their family and defaults.
    Harnesses,
    /// Reload catalog configuration without stopping sessions.
    Reload,
    /// Print the RPC schema (methods, notifications, types, exit codes) as JSON.
    Schema,
    /// Every model id each harness declares or reports (`provider/model` for OpenCode and pi).
    Models {
        /// Forget the reported catalogs and probe every harness again now.
        #[arg(long)]
        refresh: bool,
    },
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
    /// Install this binary and a daemon on a machine over ssh, then add it as a peer.
    Setup {
        /// ssh target, e.g. cmux-lawrence or user@host
        host: String,
        /// Peer name (default: the host's first label).
        #[arg(long)]
        name: Option<String>,
        /// Port the remote daemon listens on (loopback; tunnelled over ssh).
        #[arg(long, default_value_t = 47811)]
        port: u16,
    },
    /// Copy this binary to an ssh peer (or every one with --all) and restart its daemon.
    Update {
        name: Option<String>,
        #[arg(long)]
        all: bool,
    },
}

#[derive(Args)]
struct NewArgs {
    /// A preset from `acpmux preset`: harness plus model, effort, policy, env. `-m` and `-e` still win.
    #[arg(long, short)]
    preset: Option<String>,
    /// Create the session on this peer (see `acpmux host ls`). `--cwd` is then a remote path.
    #[arg(long)]
    host: Option<String>,
    /// Session name. Generated when omitted.
    #[arg(long, short)]
    name: Option<String>,
    #[arg(long)]
    cwd: Option<PathBuf>,
    /// Permission policy: ask, approve-reads, approve-edits, approve-all, deny-all.
    #[arg(long)]
    policy: Option<String>,
    /// HARNESS[/MODEL]: a family or profile name (`claude`, `codex`, `omp`), optionally with a model
    /// (`claude/opus`, `codex/gpt-5.5`, `opencode/zai/glm-5.1`). Omitted: the default harness and its defaults.
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
    /// Delete the session after the reply (implied by `acpmux exec`).
    #[arg(long)]
    ephemeral: bool,
    /// Cancel the turn cooperatively after this many seconds and exit 3.
    #[arg(long)]
    timeout: Option<u64>,
    /// When the turn asks for a permission: wait (default), deny, or fail (exit 5).
    #[arg(long, default_value = "wait")]
    on_permission: String,
    /// Retry the turn on an agent-internal error, only when it produced nothing yet.
    #[arg(long, default_value_t = 0)]
    retries: u32,
    /// Report prompt_stalled (exit 1) when nothing happens for this many seconds; 0 disables.
    #[arg(long, default_value_t = 30)]
    stall: u64,
}

fn main() -> Result<()> {
    // A launcher can hand us a blocked signal mask (an app thread that
    // blocks SIGTERM, SIGCHLD, ...). exec keeps the mask, and threads
    // inherit it, so SIGTERM would stay pending forever and child exits
    // would never be seen. Clear it before the runtime starts its threads.
    #[cfg(unix)]
    unsafe {
        let mut empty: libc::sigset_t = std::mem::zeroed();
        libc::sigemptyset(&mut empty);
        libc::pthread_sigmask(libc::SIG_SETMASK, &empty, std::ptr::null_mut());
    }
    tokio::runtime::Builder::new_multi_thread().enable_all().build()?.block_on(async_main())
}

async fn async_main() -> Result<()> {
    // `acpmux ls | head` must end quietly, not panic on a closed pipe.
    #[cfg(unix)]
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_DFL);
    }
    // `acpmux daemon` with nothing after it means `daemon run`.
    let mut argv: Vec<std::ffi::OsString> = std::env::args_os().collect();
    if argv.len() == 2 && argv[1] == "daemon" {
        argv.push("run".into());
    }
    if argv.get(1).map(|a| a == "--skill" || a == "--guide").unwrap_or(false) {
        argv[1] = "skill".into();
    }
    let run_alias = argv.get(1).map(|a| a == "run" || a == "exec").unwrap_or(false);
    let exec_alias = argv.get(1).map(|a| a == "exec").unwrap_or(false);
    let cli = Cli::parse_from(argv);
    let command = cli.command.map(flatten).map(|c| match c {
        Command::New(mut a) if run_alias => {
            a.quiet = true;
            a.detach = true;
            if exec_alias {
                a.ephemeral = true;
            }
            Command::New(a)
        }
        other => other,
    });
    match command {
        None => {
            let client = connect(true).await?;
            acpmux::tui::run(client, None).await
        }
        Some(Command::DaemonRun { listen, token, memory, log, ready_fd }) => {
            tracing_subscriber::fmt()
                .with_env_filter(
                    tracing_subscriber::EnvFilter::try_new(&log).unwrap_or_else(|_| "info".into()),
                )
                .with_target(false)
                .init();
            acpmux::daemon::run(DaemonOptions {
                ws_listen: listen,
                ws_token: token,
                memory,
                ready_fd,
            })
            .await?;
            // The daemon has stopped its agents and synced its store. Exit
            // now rather than wait for the runtime to drain blocking tasks
            // (a launcher `--version` check can take 20 s).
            std::process::exit(0)
        }
        Some(Command::Skill) => {
            use std::io::Write;
            let _ = std::io::stdout().write_all(cli::orchestrate::guide().as_bytes());
            Ok(())
        }
        Some(cmd) => {
            let json_out = cli.json;
            match run_client(cmd, json_out, cli.suppress_reads).await {
                Ok(()) => Ok(()),
                Err(e) => cli::errors::exit_with(&e, json_out),
            }
        }
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
            SessionCmd::Tail { session, last, follow, since } => {
                Command::Tail { session, last, follow, since }
            }
            SessionCmd::Tag { session, assignments, remove, ttl } => {
                Command::TagCmd { session, assignments, remove, ttl }
            }
            SessionCmd::Rules { session, rules, clear } => {
                Command::RulesCmd { session, rules, clear }
            }
            SessionCmd::History { session, limit } => Command::History { session, limit },
        },
        Command::Daemon(dc) => match dc {
            DaemonCmd::Run { listen, token, memory, log, ready_fd } => {
                Command::DaemonRun { listen, token, memory, log, ready_fd }
            }
            DaemonCmd::Status => Command::Status,
            DaemonCmd::Shutdown => Command::Shutdown,
            DaemonCmd::Config => Command::Config,
            DaemonCmd::Harnesses => Command::Harnesses,
            DaemonCmd::Reload => Command::Reload,
            DaemonCmd::Schema => Command::Schema,
            DaemonCmd::Models { refresh } => Command::Models { refresh },
        },
        Command::Host(pc) => Command::Peer(pc),
        other => other,
    }
}
