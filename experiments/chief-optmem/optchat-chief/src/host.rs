//! `optchat-chief host --daemon-socket PATH --mux-home DIR`: the brain host
//! the app starts when `CMUX_NEXT_MUX_HOST` names this executable. A second
//! launch for the same home exits 0 (the app launches it on every Home open).

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::mpsc::channel;
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use optchat_host::{AnthropicModel, CompactModel, Config, OptChat, Report, SystemClock};

use crate::acpmux::{Acpmux, AgentEvent, AgentPort, Family, Preset};
use crate::brain::{Brain, Engine, Input, Settings, parent_tag};
use crate::cli::{Flags, env};
use crate::compactor::{
    AcpmuxCompactor, CODEX_CACHE_KEY_ENV, CompactRoute, Slots, codex_cache_key, compact_route,
    compactor_presets, compactor_spec, probe_models,
};
use crate::daemon::{self, LinkConfig};
use crate::lock::{HostLock, LockError};
use crate::log::log;
use crate::native::{HttpModel, Native, NativeConfig};
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

/// The native engine's model and effort (`OPTCHAT_CHIEF_MODEL`,
/// `OPTCHAT_CHIEF_EFFORT`): the Chief is long-horizon agentic work, which
/// repays more effort than Claude Opus 5.5's default (medium).
const NATIVE_MODEL: &str = "claude-opus-5-5";
const NATIVE_EFFORT: &str = "high";
/// Longest one bash command of the native engine may run.
const BASH_TIMEOUT: Duration = Duration::from_secs(600);

/// The commit this binary was built from (`OPTCHAT_BUILD_COMMIT` at build
/// time), so host.log shows which code a dogfood run is.
const BUILD: &str = match option_env!("OPTCHAT_BUILD_COMMIT") {
    Some(commit) => commit,
    None => "unknown",
};

/// The turn harness and the compactor harness: `OPTCHAT_CHIEF_HARNESS`, else
/// `MUX_HARNESS`, else claude-sr; the compactor's `OPTCHAT_COMPACTOR_HARNESS`.
pub fn harness_choice(
    chief: Option<&str>,
    mux: Option<&str>,
    compactor: Option<&str>,
) -> (String, String) {
    let turn = chief.or(mux).unwrap_or(DEFAULT_HARNESS).to_owned();
    let compactor = compactor.map_or_else(|| turn.clone(), str::to_owned);
    (turn, compactor)
}

/// The default harness: acpmux's own Claude Code adapter (`claude_stdio`)
/// launched through `sr claude proxy`, the team subrouter's account pool.
pub const DEFAULT_HARNESS: &str = "claude-sr";

/// The turn sessions' acpmux preset, or None when a turn needs none: on
/// a Claude harness it carries each turn's system prompt (the cached
/// layout); on codex the Chief's turn `prompt_cache_key` (an env the cmux
/// codex fork reads; upstream codex ignores it); with `isolate`, the turn
/// sessions' own Claude Code configuration (`session_dir::isolation_env`).
pub fn turn_preset(
    paths: &Paths,
    home: &std::path::Path,
    harness: &str,
    family: Family,
    isolate: bool,
    system_text: &str,
) -> Option<Preset> {
    let mut env = if isolate {
        session_dir::isolation_env(paths)
    } else {
        BTreeMap::new()
    };
    let _ = (CODEX_CACHE_KEY_ENV, codex_cache_key(home, "turn"));
    (isolate || family == Family::Claude).then(|| Preset {
        name: format!("optchat-chief-{}", crate::paths::home_id(home)),
        harness: harness.to_owned(),
        env,
        args: Vec::new(),
        system_prompt: (family == Family::Claude).then(|| system_text.to_owned()),
    })
}

/// The families of the turn and the compactor harness, from acpmux's own
/// harness metadata (`_acpmux/harnesses`).
pub fn harness_families(
    answer: &serde_json::Value,
    harness: &str,
    compactor_harness: &str,
) -> Result<(Family, Family), String> {
    Ok((
        crate::acpmux::harness_family(answer, harness)?,
        crate::acpmux::harness_family(answer, compactor_harness)?,
    ))
}

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
    let instructions = crate::prompt::user_instructions(&paths.instructions);
    // One setting picks the harness of turns and compactor alike.
    let (harness, compactor_harness) = harness_choice(
        env("OPTCHAT_CHIEF_HARNESS").as_deref(),
        env("MUX_HARNESS").as_deref(),
        env("OPTCHAT_COMPACTOR_HARNESS").as_deref(),
    );
    let engine_choice = env("OPTCHAT_CHIEF_ENGINE");
    let config = Config {
        agent: crate::prompt::AGENT.to_owned(),
        reporter: Arc::new(|r: &Report| log(format!("memory: {r}"))),
        ..Config::default()
    };
    let route = compact_route(env("OPTCHAT_COMPACTOR").as_deref(), &config)?;
    // The harness family decides each session's layout and isolation; acpmux
    // says what a harness is (its declared family, else its kind and
    // command), never its name. Only the native engine with the API
    // compactor runs without acpmux.
    let (family, compactor_family) =
        if engine_choice.as_deref() == Some("native") && route == CompactRoute::Api {
            (Family::Other, Family::Other)
        } else {
            let answer = crate::acpmux::query_harnesses(&acpmux_socket, &|line: &str| log(line))
                .map_err(|e| format!("reading acpmux's harnesses: {e}"))?;
            harness_families(&answer, &harness, &compactor_harness)?
        };
    let claude = family == Family::Claude;
    // A Claude Code harness reads the optchat MCP server from the session
    // directory; acpmux gives any other harness no MCP server, so its memory
    // tools are the launcher's commands.
    let tools = if claude {
        crate::prompt::Tools::Mcp
    } else {
        crate::prompt::Tools::Cli(paths.bin.join("chief").display().to_string())
    };
    let system_text = crate::prompt::system_text(instructions.as_deref(), &tools);
    let setup = SessionSetup {
        exe: exe.display().to_string(),
        cmux_mcp: env("CMUX_MCP_COMMAND"),
        env: session_env,
        instructions: instructions.clone(),
        tools,
    };
    session_dir::write(paths, &setup).map_err(|e| format!("writing the session directory: {e}"))?;

    let (base_url, api_key) = (config.base_url.clone(), config.api_key.clone());

    // acpmux first: the compactor's acpmux route needs the connection before
    // the memory opens and starts building nodes. Its events wait in the
    // channel until the brain runs.
    let (tx, rx) = channel();
    // Turn sessions get their own Claude Code configuration (section 7: a
    // fresh call with nothing carried over). OPTCHAT_CHIEF_ISOLATE=0 turns it
    // off, for a harness that needs the user's configuration to sign in. On
    // a Claude harness the preset also carries each turn's system prompt
    // (the cached layout), with or without the isolation.
    let isolate = env("OPTCHAT_CHIEF_ISOLATE").as_deref() != Some("0");
    let preset = turn_preset(paths, home, &harness, family, isolate, &system_text);
    let turn_preset_name = format!("optchat-chief-{}", crate::paths::home_id(home));
    // Compactor sessions require their own presets and configuration, which
    // OPTCHAT_CHIEF_ISOLATE never turns off: without them, every node would
    // run the user's hooks, MCP servers and auto-memory on the chat's text.
    let mut required = Vec::new();
    if route == CompactRoute::Acpmux {
        crate::compactor::prepare_config(&paths.compactor_config)
            .map_err(|e| format!("creating {}: {e}", paths.compactor_config.display()))?;
        if compactor_family == Family::Codex {
            crate::compactor::prepare_codex_homes(paths, &crate::compactor::user_codex_home())?;
        }
        required.extend(compactor_presets(
            paths,
            home,
            &compactor_harness,
            compactor_family,
        ));
    }
    let agents = Acpmux::new(acpmux_socket.clone(), preset, required);
    let first_link = Arc::new((Mutex::new(false), Condvar::new()));
    {
        let tx = tx.clone();
        let first_link = first_link.clone();
        let link_log: crate::brain::Log = Arc::new(|line: &str| log(line));
        agents.spawn_link(
            Arc::new(move |event| {
                if matches!(event, AgentEvent::Up(_) | AgentEvent::Down) {
                    *first_link.0.lock().expect("link") = true;
                    first_link.1.notify_all();
                }
                let _ = tx.send(Input::from(event));
            }),
            link_log,
        );
    }

    let (model, fallback, route_text): (
        Arc<dyn CompactModel>,
        Option<Arc<dyn CompactModel>>,
        String,
    ) = match route {
        CompactRoute::Api => (
            Arc::new(AnthropicModel::new(&config)),
            config
                .fallback_model
                .as_deref()
                .map(|m| Arc::new(AnthropicModel::with_model(&config, m)) as Arc<dyn CompactModel>),
            format!(
                "{} over the Messages API at {}",
                config.model, config.base_url
            ),
        ),
        CompactRoute::Acpmux => {
            // The Claude models are Claude-only: another harness builds with
            // its own default model unless OPTCHAT_COMPACTOR_MODEL names one,
            // and has no refusal fallback model.
            let compactor_claude = compactor_family == Family::Claude;
            let compactor_model = env("OPTCHAT_COMPACTOR_MODEL")
                .or_else(|| compactor_claude.then(|| config.model.clone()));
            let compactor_effort = env("OPTCHAT_COMPACTOR_EFFORT");
            let port: Arc<dyn AgentPort> = agents.clone();
            // One gate: at most JOBS compactor sessions across both models.
            let slots = Slots::new(optchat_core::JOBS);
            let compactor_log: crate::compactor::Log = Arc::new(|line: &str| log(line));
            let build = |model: Option<&str>| {
                let spec = crate::compactor::CompactorSpec {
                    effort: compactor_effort.clone(),
                    ..compactor_spec(paths, home, &compactor_harness, compactor_family, model)
                };
                Arc::new(
                    AcpmuxCompactor::new(port.clone(), spec, slots.clone())
                        .with_log(compactor_log.clone()),
                ) as Arc<dyn CompactModel>
            };
            let text = format!(
                "{} in deny-all {compactor_harness} sessions through acpmux",
                compactor_model
                    .as_deref()
                    .unwrap_or("the harness's default model")
            );
            let fallback = config
                .fallback_model
                .as_deref()
                .filter(|_| compactor_claude)
                .map(|m| build(Some(m)));
            (build(compactor_model.as_deref()), fallback, text)
        }
    };
    log(format!(
        "optchat-chief {} (build {BUILD}); compactor: {route_text}",
        env!("CARGO_PKG_VERSION"),
    ));
    if route == CompactRoute::Acpmux {
        // Bounded: acpmux_daemon::ensure gives a starting daemon 30 s.
        let (lock, cv) = &*first_link;
        let linked = lock.lock().expect("link");
        let _ = cv
            .wait_timeout_while(linked, Duration::from_secs(40), |done| !*done)
            .expect("link");
    }
    let system = config.prompt.text(&config.agent);
    let chat = Arc::new(
        OptChat::open_with_fallback(
            &paths.chat,
            config,
            model.clone(),
            fallback.clone(),
            Arc::new(SystemClock),
        )
        .map_err(|e| format!("opening the memory: {e}"))?,
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

    // The default stays acpmux: the team subrouter answers raw Messages API
    // calls for Claude models with 429 (it serves Claude Code clients), so
    // the native engine needs an endpoint that takes API calls
    // (OPTCHAT_ANTHROPIC_BASE_URL plus a key). Checked live on 2026-10-04.
    let engine = match engine_choice.as_deref() {
        Some("native") => {
            let native_config = NativeConfig {
                model: env("OPTCHAT_CHIEF_MODEL").unwrap_or_else(|| NATIVE_MODEL.into()),
                effort: Some(env("OPTCHAT_CHIEF_EFFORT").unwrap_or_else(|| NATIVE_EFFORT.into())),
                max_tokens: 64_000,
                server_fallback: env("OPTCHAT_CHIEF_SERVER_FALLBACK").as_deref() == Some("1"),
                system: crate::prompt::claude_md(instructions.as_deref()),
                cwd: paths.session.clone(),
                env: native_env(&setup, paths),
                bash_timeout: BASH_TIMEOUT,
                pwd_file: paths.root.join("bash.pwd"),
            };
            log(format!(
                "turns: native engine, {} at effort {} via {}",
                native_config.model,
                native_config.effort.as_deref().unwrap_or("default"),
                base_url
            ));
            let model = HttpModel::new(&base_url, api_key, native_config.server_fallback);
            Engine::Native(Arc::new(Native::new(
                native_config,
                Arc::new(model),
                optchat_host::RETRY,
            )))
        }
        None | Some("acpmux") => {
            log(format!(
                "turns: {harness} sessions through acpmux ({}); no Messages API",
                match family {
                    Family::Claude => "cached layout: the turn preset's system prompt holds the view head, one cache marker".to_owned(),
                    Family::Codex => format!(
                        "automatic prefix caching: instructions in AGENTS.md, view first, messages last, prompt_cache_key {}",
                        codex_cache_key(home, "turn")
                    ),
                    Family::Other => "automatic prefix caching: instructions in AGENTS.md, view first, messages last".to_owned(),
                }
            ));
            Engine::Acpmux
        }
        Some(other) => {
            return Err(format!(
                "OPTCHAT_CHIEF_ENGINE={other}: use native or acpmux"
            ));
        }
    };
    let turn_limit = env("OPTCHAT_CHIEF_TURN_LIMIT_MIN")
        .and_then(|m| m.parse::<u64>().ok())
        .unwrap_or(DEFAULT_TURN_LIMIT_MIN);
    let settings = Settings {
        session_dir: paths.session.clone(),
        harness,
        policy: env("MUX_POLICY").unwrap_or_else(|| "approve-all".into()),
        model: env("OPTCHAT_CHIEF_MODEL"),
        parent: parent_tag(home),
        turn_prefix: format!("optchat-{}", crate::paths::home_id(home)),
        agent_gap: Duration::from_millis(cmux_chief::rules::AGENT_GAP_RETRY_MS),
        turn_limit: (turn_limit > 0).then(|| Duration::from_secs(turn_limit * 60)),
        engine,
        turn_preset: claude.then_some(turn_preset_name),
        chief_id: crate::paths::home_id(home),
        system_text,
    };
    let brain_log: crate::brain::Log = Arc::new(|line: &str| log(line));
    // Section 10: persist after each turn.
    let persister = crate::persist::Persister::start(paths.chat.clone(), brain_log.clone())
        .map_err(|e| format!("starting the persister: {e}"))?;
    let brain = Brain::new(
        chat.clone(),
        agents.clone(),
        settings,
        StateFile::new(&paths.state),
        tx.clone(),
        brain_log.clone(),
    )
    .on_turn_end(Arc::new(move |key: &str| persister.turn_ended(key)));
    spawn_probe(model, fallback, system, route, tx.clone());
    daemon::spawn_link(
        LinkConfig {
            socket: daemon_socket.into(),
            token_file,
            display_name: daemon::full_name(),
        },
        Arc::new(move |event| {
            let _ = tx.send(Input::from(event));
        }),
        brain_log,
    );
    let fatal = brain.run(rx);
    chat.shutdown();
    Ok(fatal)
}

/// Builds one tiny node through the compactor's route, with its main and
/// its fallback model, in the background: when either cannot (acpmux down,
/// the harness not signed in, a 429, an unserved fallback model, a
/// compactor session that offers tools), host.log gets one line and the
/// Chief conversation one notice, instead of every turn waiting on settle
/// with nothing said.
fn spawn_probe(
    model: Arc<dyn CompactModel>,
    fallback: Option<Arc<dyn CompactModel>>,
    system: String,
    route: CompactRoute,
    tx: std::sync::mpsc::Sender<Input>,
) {
    let spawned = std::thread::Builder::new()
        .name("optchat-compact-probe".into())
        .spawn(move || {
            let started = std::time::Instant::now();
            match probe_models(&*model, fallback.as_deref(), &system) {
                Ok(line) => log(format!(
                    "compactor probe ({}{}) built a node in {} ms: {line}",
                    route.name(),
                    if fallback.is_some() { ", fallback too" } else { "" },
                    started.elapsed().as_millis()
                )),
                Err(e) => {
                    let remedy = match route {
                        CompactRoute::Acpmux => {
                            "Check that acpmux runs and that its claude-sr harness signs in, or set \
                             OPTCHAT_ANTHROPIC_BASE_URL and OPTCHAT_ANTHROPIC_API_KEY for an endpoint \
                             that takes Messages API calls."
                        }
                        CompactRoute::Api => {
                            "Check OPTCHAT_ANTHROPIC_BASE_URL and OPTCHAT_ANTHROPIC_API_KEY, or set \
                             OPTCHAT_COMPACTOR=acpmux to build summaries in acpmux sessions."
                        }
                    };
                    let text = format!(
                        "The memory compactor cannot build summaries ({} route: {e}). Messages \
                         that need a summary wait, and so does every reply, until it can. {remedy}",
                        route.name()
                    );
                    let key = format!("notice:optchat:compactor:{}", now_ms());
                    let _ = tx.send(Input::Notice { key, text });
                }
            }
        });
    if let Err(e) = spawned {
        log(format!("starting the compactor probe: {e}"));
    }
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64)
}

/// The native bash tool's env: the turn session's, with the `chief`
/// launcher first on PATH (as `session_dir::settings_json` gives Claude Code).
fn native_env(setup: &SessionSetup, paths: &Paths) -> BTreeMap<String, String> {
    let mut env = setup.env.clone();
    let path = env
        .get("PATH")
        .cloned()
        .unwrap_or_else(|| "/usr/bin:/bin".into());
    env.insert("PATH".into(), format!("{}:{path}", paths.bin.display()));
    env
}
