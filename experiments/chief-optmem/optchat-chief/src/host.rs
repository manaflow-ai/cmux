//! `optchat-chief host --daemon-socket PATH --mux-home DIR`: the brain host
//! the app starts when `CMUX_NEXT_MUX_HOST` names this executable. A second
//! launch for the same home exits 0 (the app launches it on every Home open).

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::mpsc::channel;
use std::time::Duration;

use optchat_host::{Config, OptChat, Report};

use crate::acpmux::Acpmux;
use crate::acpmux::Preset;
use crate::brain::{Brain, Input, Settings, parent_tag};
use crate::cli::{Flags, env};
use crate::daemon::{self, LinkConfig};
use crate::lock::{HostLock, LockError};
use crate::log::log;
use crate::paths::{Paths, mux_home};
use crate::session_dir::{self, SessionSetup};
use crate::state::StateFile;

/// Env passed through to the turn's tools, as mux/host passes it.
const PASSTHROUGH: [&str; 5] = [
    "CMUX_SOCKET_PATH",
    "ACPMUX_SOCKET",
    "ACPMUX_HOME",
    "ACPMUX_BIN",
    "CMUX_MCP_COMMAND",
];

/// A turn longer than this is stopped (minutes; `OPTCHAT_CHIEF_TURN_LIMIT_MIN`,
/// 0 for none). Long enough for a big refactor, short enough that a hung
/// harness does not silence the Chief for a day.
const DEFAULT_TURN_LIMIT_MIN: u64 = 180;

/// Runs the host; returns the exit code.
pub fn run(flags: &Flags, started_ms: u64) -> i32 {
    let Some(daemon_socket) = flags
        .value("daemon-socket")
        .map(str::to_owned)
        .or_else(|| env("CMUX_DAEMON_SOCKET"))
    else {
        eprintln!("optchat-chief host: needs --daemon-socket PATH (or CMUX_DAEMON_SOCKET)");
        return 2;
    };
    let home = flags
        .value("mux-home")
        .map(PathBuf::from)
        .unwrap_or_else(mux_home);
    let token_file = env("MUX_AGENT_TOKEN_FILE").map(PathBuf::from);
    if daemon::read_token(token_file.as_deref()).is_none() {
        // Without the token the owner stamps the host as the user and refuses
        // every agent_mux write; the app starts the host with MUX_AGENT_TOKEN_FILE.
        eprintln!(
            "optchat-chief host: MUX_AGENT_TOKEN_FILE is missing or empty; start the host from cmux"
        );
        return 2;
    }
    let paths = Paths::new(&home);
    if let Err(e) = paths.create() {
        log(format!("creating {}: {e}", paths.root.display()));
        return 1;
    }
    let _lock = match HostLock::take(&paths.host_lock, started_ms) {
        Ok(lock) => lock,
        Err(LockError::Held) => {
            log(format!("already running for {}", home.display()));
            return 0;
        }
        Err(e @ LockError::Older(_)) => {
            log(format!("{e}; not starting"));
            return 0;
        }
        Err(LockError::Io(e)) => {
            log(format!("taking {}: {e}", paths.host_lock.display()));
            return 1;
        }
    };
    match start(&paths, &home, &daemon_socket, token_file) {
        Ok(fatal) => {
            log(format!("stopping: {fatal}"));
            1
        }
        Err(e) => {
            log(e);
            1
        }
    }
}

fn start(
    paths: &Paths,
    home: &std::path::Path,
    daemon_socket: &str,
    token_file: Option<PathBuf>,
) -> Result<String, String> {
    let exe = std::env::current_exe()
        .and_then(|p| p.canonicalize())
        .map_err(|e| format!("finding this executable: {e}"))?;
    let acpmux_socket = crate::acpmux_daemon::socket_path();
    let mut session_env = BTreeMap::new();
    session_env.insert("MUX_HOME".to_owned(), home.display().to_string());
    session_env.insert("CMUX_DAEMON_SOCKET".to_owned(), daemon_socket.to_owned());
    session_env.insert(
        "ACPMUX_SOCKET".to_owned(),
        acpmux_socket.display().to_string(),
    );
    for key in PASSTHROUGH {
        if let Some(value) = env(key) {
            session_env.insert(key.to_owned(), value);
        }
    }
    session_env.insert(
        "PATH".to_owned(),
        env("PATH").unwrap_or_else(|| "/usr/bin:/bin".into()),
    );
    let setup = SessionSetup {
        exe: exe.display().to_string(),
        cmux_mcp: env("CMUX_MCP_COMMAND"),
        env: session_env,
    };
    session_dir::write(paths, &setup).map_err(|e| format!("writing the session directory: {e}"))?;

    let config = Config {
        agent: crate::prompt::AGENT.to_owned(),
        reporter: Arc::new(|r: &Report| log(format!("memory: {r}"))),
        ..Config::default()
    };
    log(format!("compactor {} at {}", config.model, config.base_url));
    let chat = Arc::new(
        OptChat::open(&paths.chat, config).map_err(|e| format!("opening the memory: {e}"))?,
    );
    crate::tools::serve(&paths.tools_socket, chat.clone())
        .map_err(|e| format!("serving the memory tools: {e}"))?;
    let status = chat.status();
    // Section 10: on start, print the view, so the log shows what the agent sees.
    log(format!(
        "pid {}, MUX_HOME {}, daemon {daemon_socket}, acpmux {}; memory: {} messages, {} view lines ({} unbuilt)\n{}",
        std::process::id(),
        home.display(),
        acpmux_socket.display(),
        status.messages,
        status.view_lines,
        status.unbuilt,
        chat.render_view().text
    ));

    let (tx, rx) = channel();
    let harness = env("MUX_HARNESS").unwrap_or_else(|| "claude-sr".into());
    // Turn sessions get their own Claude Code configuration (section 7: a
    // fresh call with nothing carried over). OPTCHAT_CHIEF_ISOLATE=0 turns it
    // off, for a harness that needs the user's configuration to sign in.
    let preset = (env("OPTCHAT_CHIEF_ISOLATE").as_deref() != Some("0")).then(|| Preset {
        name: format!("optchat-chief-{}", crate::paths::home_id(home)),
        harness: harness.clone(),
        env: session_dir::isolation_env(paths),
    });
    let agents = Acpmux::new(acpmux_socket, preset);
    let turn_limit = env("OPTCHAT_CHIEF_TURN_LIMIT_MIN")
        .and_then(|m| m.parse::<u64>().ok())
        .unwrap_or(DEFAULT_TURN_LIMIT_MIN);
    let settings = Settings {
        session_dir: paths.session.clone(),
        harness,
        policy: env("MUX_POLICY").unwrap_or_else(|| "approve-all".into()),
        model: env("OPTCHAT_CHIEF_MODEL"),
        parent: parent_tag(home),
        agent_gap: Duration::from_millis(cmux_chief::rules::AGENT_GAP_RETRY_MS),
        turn_limit: (turn_limit > 0).then(|| Duration::from_secs(turn_limit * 60)),
    };
    let brain_log: crate::brain::Log = Arc::new(|line: &str| log(line));
    let brain = Brain::new(
        chat.clone(),
        agents.clone(),
        settings,
        StateFile::new(&paths.state),
        tx.clone(),
        brain_log.clone(),
    );
    let daemon_tx = tx.clone();
    daemon::spawn_link(
        LinkConfig {
            socket: daemon_socket.into(),
            token_file,
            display_name: daemon::full_name(),
        },
        Arc::new(move |event| {
            let _ = daemon_tx.send(Input::from(event));
        }),
        brain_log.clone(),
    );
    agents.spawn_link(
        Arc::new(move |event| {
            let _ = tx.send(Input::from(event));
        }),
        brain_log,
    );
    let fatal = brain.run(rx);
    chat.shutdown();
    Ok(fatal)
}
