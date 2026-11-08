//! `cmux host …` verbs, also the standalone `cmux-host` binary.
//!
//! - `run`: the bind agent and supervisor (the frozen unit command
//!   `cmux host run`) on a Linux VM; elsewhere, and with `--roles-only`,
//!   only the process role loop (server.md 5.1).
//! - `status [--json]`: the agent's published state.
//! - `roles [--json]`: process role health (`<state>/roles/status.json`).
//! - `logs <role> [--bytes N]`: the end of a process role's log.
//! - `rekey <instance-id>`: internal; the off-critical-path identity job
//!   the agent starts after a bind.
//! - `update status|check|guard`: the Cloud machine's self-update
//!   (`updater`); the `updater` role runs it by itself.
//! - `cloud daemon-info | probe-activity`: bake and smoke evidence for the
//!   Cloud agent role (the daemon block bind sends; the activity stream).
//!
//! Exit codes follow `cmux server`: 0 ok, 1 internal, 2 usage, 3 not
//! found, 4 rejected (unsupported platform).

use crate::json::JsonField;
use std::path::PathBuf;
use std::time::Duration;

use cmux_server_core::layout::Layout;
use cmux_server_core::platform::InstallMode;

use crate::config::{Config, Paths, STATUS_FILE};
use crate::proc_roles::RolePaths;
use crate::status;

const USAGE: &str = "usage: cmux host run [--roles-only] [--mode user|system] | status [--json] [--root DIR] | roles [--json] | logs <role> [--bytes N] | cloud daemon-info|probe-activity|clone-mark [--root DIR] | cloud identity | cloud carrier-ticket | update status|check|guard --to N | team-ssh apply|accounts-apply|principals <user>|session-open|reap|sync [--root DIR] | team restricted-shell|whoami | team-enroll --team T --epoch E --nonce N | --commit …";

fn code(n: u8) -> u8 {
    n
}

/// Options of `run` that only tests and diagnostics change.
fn parse_run(args: &[String], self_argv: Vec<String>) -> Result<Config, String> {
    let mut cfg = Config::production();
    cfg.self_argv = self_argv;
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        let mut value = || it.next().cloned().ok_or_else(|| format!("{arg} needs a value"));
        match arg.as_str() {
            "--root" => cfg.paths = Paths::new(value()?),
            "--metadata" => {
                cfg.metadata_addr = value()?.parse().map_err(|e| format!("--metadata: {e}"))?;
            }
            "--metadata-attempts" => {
                cfg.metadata_attempts =
                    value()?.parse().map_err(|e| format!("--metadata-attempts: {e}"))?;
            }
            "--daemon-user" => cfg.daemon.user = Some(value()?),
            "--daemon-home" => cfg.daemon.home = Some(PathBuf::from(value()?)),
            "--daemon-bin" => cfg.daemon.bin = Some(PathBuf::from(value()?)),
            "--action-log" => cfg.action_log = Some(PathBuf::from(value()?)),
            "--rearm-delay-ms" => {
                let ms: u64 = value()?.parse().map_err(|e| format!("--rearm-delay-ms: {e}"))?;
                cfg.rearm_delay = Duration::from_millis(ms);
            }
            "--no-announce" => cfg.announce = false,
            "--announce-interval-seconds" => {
                let secs: u64 =
                    value()?.parse().map_err(|e| format!("--announce-interval-seconds: {e}"))?;
                cfg.announce_interval = Duration::from_secs(secs);
            }
            other => return Err(format!("unknown argument {other}")),
        }
    }
    Ok(cfg)
}

fn root_arg(args: &[String]) -> Result<(Paths, Vec<String>), String> {
    let mut paths = Paths::new("/");
    let mut rest = Vec::new();
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        if arg == "--root" {
            paths = Paths::new(it.next().ok_or("--root needs a value")?);
        } else {
            rest.push(arg.clone());
        }
    }
    Ok((paths, rest))
}

fn status_verb(args: &[String]) -> u8 {
    let (paths, rest) = match root_arg(args) {
        Ok(v) => v,
        Err(e) => return usage(&e),
    };
    let json = match rest.as_slice() {
        [] => false,
        [flag] if flag == "--json" => true,
        _ => return usage("status takes --json and --root only"),
    };
    match status::read(&paths.at(STATUS_FILE), pid_alive) {
        Some(status) => {
            println!("{}", if json { status.to_json() } else { status.summary() });
            code(0)
        }
        None => {
            if json {
                println!(
                    "{{\"error\":\"not_found\",\"message\":\"cmux host is not running on this machine\"}}"
                );
            } else {
                eprintln!("cmux host is not running on this machine");
            }
            code(3)
        }
    }
}

#[cfg(unix)]
fn pid_alive(pid: u32) -> bool {
    // SAFETY: signal 0 only checks that the pid exists.
    let rc = unsafe { libc::kill(pid as libc::pid_t, 0) };
    rc == 0 || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

#[cfg(not(unix))]
fn pid_alive(_pid: u32) -> bool {
    true
}

fn usage(msg: &str) -> u8 {
    eprintln!("cmux host: {msg}\n{USAGE}");
    code(2)
}

/// Entry for `cmux host <args>` (and `cmux-host <args>`). `self_argv` is
/// how to run this binary's `host` verbs again (`[cmux, host]` from the
/// main binary; empty means the current executable).
pub fn run(args: &[String], self_argv: Vec<String>) -> u8 {
    let Some((verb, rest)) = args.split_first() else { return usage("missing verb") };
    match verb.as_str() {
        "run" => {
            let (mode, rest) = match split_mode(rest) {
                Ok(split) => split,
                Err(e) => return usage(&e),
            };
            run_verb(mode, &rest, self_argv)
        }
        "status" => status_verb(rest),
        "roles" => roles_verb(rest),
        "logs" => logs_verb(rest),
        "rekey" => rekey_verb(rest),
        "cloud" => cloud_verb(rest),
        "update" => update_verb(rest),
        "team-ssh" => crate::team_ssh::cli::run(rest),
        "team" => crate::team_ssh::team_cli::run(rest),
        "team-enroll" => crate::team_ssh::enroll::run(rest),
        "--help" | "-h" | "help" => {
            println!("{USAGE}");
            code(0)
        }
        other => usage(&format!("unknown verb {other}")),
    }
}

/// `run` flags that did something once and are now ignored, so a unit an older image wrote keeps
/// starting after self-update replaces the binary (the updater never rewrites the unit).
/// `--native-receiver` started the Native receiver, which the carrier replaced.
const RETIRED_RUN_FLAGS: &[&str] = &["--native-receiver"];

/// `rest` without the retired flags, and the retired flags it had (each once).
fn drop_retired_run_flags(rest: &[String]) -> (Vec<String>, Vec<&'static str>) {
    let mut kept = Vec::new();
    let mut retired = Vec::new();
    for arg in rest {
        match RETIRED_RUN_FLAGS.iter().find(|flag| **flag == arg.as_str()) {
            Some(flag) if !retired.contains(flag) => retired.push(*flag),
            Some(_) => {}
            None => kept.push(arg.clone()),
        }
    }
    (kept, retired)
}

/// `run`: the roles-only loop (macOS, or `--roles-only`), else the Linux
/// bind agent. `mode` is the units' `--mode`.
fn run_verb(mode: Option<InstallMode>, rest: &[String], self_argv: Vec<String>) -> u8 {
    let (rest, retired) = drop_retired_run_flags(rest);
    for flag in retired {
        eprintln!("cmux host run: {flag} is retired and ignored");
    }
    let rest = rest.as_slice();
    if cfg!(not(target_os = "linux")) || rest.iter().any(|a| a == "--roles-only") {
        if rest.iter().any(|a| a != "--roles-only") {
            return usage("run --roles-only takes only --mode");
        }
        return match install_layout(mode) {
            Ok((layout, _)) => crate::run_roles::run_roles(&layout),
            Err(e) => {
                eprintln!("cmux host run: {e}");
                code(1)
            }
        };
    }
    match parse_run(rest, self_argv) {
        Ok(mut cfg) => {
            cfg.server_mode = mode;
            run_agent(cfg)
        }
        Err(e) => usage(&e),
    }
}

/// Takes `--mode <user|system>` (at most once, anywhere) out of `args`.
fn split_mode(args: &[String]) -> Result<(Option<InstallMode>, Vec<String>), String> {
    let mut mode = None;
    let mut rest = Vec::new();
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        if arg != "--mode" {
            rest.push(arg.clone());
            continue;
        }
        let value = match it.next().map(String::as_str) {
            Some("user") => InstallMode::User,
            Some("system") => InstallMode::System,
            Some(other) => return Err(format!("--mode {other:?}: use user or system")),
            None => return Err("--mode needs user or system".to_owned()),
        };
        if mode.replace(value).is_some() {
            return Err("--mode may be given once".to_owned());
        }
    }
    Ok((mode, rest))
}

/// The deprecation line for a mode taken from CMUX_SERVER_MODE (an old
/// unit); `None` when --mode was given or the variable is unset.
fn env_mode_deprecation(flag: Option<InstallMode>, env: Option<&str>) -> Option<String> {
    match (flag, env) {
        (None, Some(value)) => Some(format!(
            "cmux host: CMUX_SERVER_MODE={value} is deprecated and goes away next release; \
             the service unit passes --mode (run `cmux server install` to rewrite it)"
        )),
        _ => None,
    }
}

/// The install layout roles receive: the units' `--mode`, else
/// CMUX_SERVER_MODE, else system as root.
fn install_layout(mode: Option<InstallMode>) -> Result<(Layout, InstallMode), String> {
    if let Some(line) =
        env_mode_deprecation(mode, std::env::var("CMUX_SERVER_MODE").ok().as_deref())
    {
        eprintln!("{line}");
    }
    let mode = mode.unwrap_or_else(|| cmux_server::host::resolve_mode(false));
    cmux_server::host::layout_for(mode, &cmux_server::host::layout_env())
        .map(|layout| (layout, mode))
        .map_err(|e| e.to_string())
}

fn roles_verb(args: &[String]) -> u8 {
    let json = match args {
        [] => false,
        [flag] if flag == "--json" => true,
        _ => return usage("roles takes --json only"),
    };
    let layout = match install_layout(None) {
        Ok((layout, _)) => layout,
        Err(e) => return usage(&e),
    };
    let path = crate::proc_roles::status_path(&RolePaths::from_layout(&layout));
    let Some(status) = crate::proc_roles::read_status(&path) else {
        eprintln!("cmux host: no process role status yet ({})", path.display());
        return code(3);
    };
    if json {
        println!("{status}");
    } else {
        for role in status.field("roles").as_array().into_iter().flatten() {
            let field = |key: &str| role[key].as_str().unwrap_or("").to_owned();
            let error = field("last_error");
            println!("{}\t{}\t{}", field("name"), field("state"), error);
        }
    }
    code(0)
}

fn logs_verb(args: &[String]) -> u8 {
    let (name, bytes) = match args {
        [name] => (name, 64 * 1024),
        [name, flag, n] if flag == "--bytes" => match n.parse::<u64>() {
            Ok(n) => (name, n),
            Err(_) => return usage("--bytes takes a number"),
        },
        _ => return usage("logs takes <role> [--bytes N]"),
    };
    if !cmux_server_core::role_spec::valid_name(name) {
        return usage("invalid role name");
    }
    let layout = match install_layout(None) {
        Ok((layout, _)) => layout,
        Err(e) => return usage(&e),
    };
    match crate::proc_roles::tail(&RolePaths::from_layout(&layout).log_dir(), name, bytes) {
        Ok(out) => {
            use std::io::Write;
            let _ = std::io::stdout().write_all(&out);
            code(0)
        }
        Err(e) => {
            eprintln!("cmux host logs: {e}");
            code(1)
        }
    }
}

#[cfg(target_os = "linux")]
fn run_agent(mut cfg: Config) -> u8 {
    use crate::agent::{ActionLog, Agent};
    // Without a layout the agent still binds and supervises; roles only
    // report the error.
    let install = install_layout(cfg.server_mode);
    if let Ok((layout, _)) = &install {
        cfg.server_config = Some(PathBuf::from(layout.config_file.as_str()));
    }
    // TODO(lane 10): ChannelChanged has no source yet; the control-plane
    // push lands with the updater role.
    let log = match ActionLog::new(cfg.action_log.as_deref()) {
        Ok(log) => log,
        Err(e) => return usage(&format!("action log: {e}")),
    };
    // Under root, process roles run as the session host's work user.
    let work_user =
        cfg.daemon.user.clone().unwrap_or_else(|| crate::daemon_spec::WORK_USER.to_owned());
    let work_user = crate::linux::spawn::lookup_user(&work_user).map(|u| {
        crate::proc_roles::privilege::WorkUser {
            name: u.name,
            uid: u.uid,
            gid: u.gid,
            home: u.home,
        }
    });
    // The Cloud agent role binds a cmux Cloud machine; it does nothing until
    // the driver writes bind.json (or bound.json exists from a past bind).
    // Creating the channel opens descriptors only. LinuxPlatform must block
    // supervisor signals before the Cloud worker starts any thread.
    // SAFETY: geteuid has no preconditions.
    let bootstrap = if unsafe { libc::geteuid() } == 0 {
        match cmux_link::root_bootstrap::Host::new() {
            Ok(host) => Some(std::sync::Arc::new(host)),
            Err(error) => {
                eprintln!("cmux host: optional root lifetime channel unavailable: {error}");
                None
            }
        }
    } else {
        None
    };
    // This is cmux-host.service starting: a restart of it that an updater, the
    // operator's `cmux host update check` or the guard queued is done, so the
    // Cloud role's binds may go out again (updater/gate.rs). Before any role
    // starts, so before the first bind.
    if cfg.paths.is_system_root() {
        let now_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX));
        if let Err(e) = crate::updater::gate::Gate::new(&cfg.paths).service_started(now_ms) {
            eprintln!("cmux host: the restart gate failed at start ({e}); binds wait for it");
        }
    }
    let cloud = crate::cloud::role::CloudRole::new(cfg.paths.clone())
        .with_root_bootstrap(bootstrap.clone());
    // The updater is last: it starts once every other role runs, and it
    // stops first.
    let updater = crate::updater::role::UpdaterRole::new(cfg.paths.clone());
    let platform = match crate::linux::LinuxPlatform::new(cfg) {
        Ok(p) => p.with_root_bootstrap(bootstrap),
        Err(e) => {
            eprintln!("cmux host: setup failed: {e}");
            return code(1);
        }
    };
    let roles: Vec<Box<dyn cmux_server_core::role::Role>> = vec![
        Box::new(crate::proc_roles::ProcessRoles::new(work_user)),
        Box::new(cloud),
        Box::new(updater),
    ];
    match Agent::new(platform, roles, install, log).run() {
        Ok(()) => code(0),
        Err(e) => {
            eprintln!("cmux host: {e}");
            code(1)
        }
    }
}

#[cfg(not(target_os = "linux"))]
fn run_agent(_cfg: Config) -> u8 {
    eprintln!("cmux host run: this platform has no bind agent yet (Linux only)");
    code(4)
}

#[cfg(target_os = "linux")]
fn rekey_verb(args: &[String]) -> u8 {
    let (paths, rest) = match root_arg(args) {
        Ok(v) => v,
        Err(e) => return usage(&e),
    };
    let [id] = rest.as_slice() else { return usage("rekey takes one instance id") };
    let Some(id) = crate::metadata::valid_instance_id(id) else {
        return usage("invalid instance id");
    };
    match crate::linux::identity::rekey(&paths, &id) {
        Ok(()) => code(0),
        Err(e) => {
            eprintln!("cmux host rekey: {e}");
            code(1)
        }
    }
}

#[cfg(target_os = "linux")]
fn cloud_verb(args: &[String]) -> u8 {
    // Identity authority has no --root or environment override.
    if args == ["identity"] {
        return match crate::identity::query() {
            Ok(identity) => match serde_json::to_string(&identity) {
                Ok(text) => {
                    println!("{text}");
                    code(0)
                }
                Err(_) => code(1),
            },
            Err(e) => {
                eprintln!("cmux host cloud identity: {e}");
                code(1)
            }
        };
    }
    // The session host's relay ticket command (`carrier_entry.rs`): the
    // ticket alone on stdout, for the daemon to read.
    if args == ["carrier-ticket"] {
        return carrier_ticket();
    }
    let (paths, rest) = match root_arg(args) {
        Ok(v) => v,
        Err(e) => return usage(&e),
    };
    let timeout = Duration::from_secs(10);
    let answer = match rest.as_slice() {
        [verb] if verb == "daemon-info" => crate::cloud::role::print_daemon_info(&paths, timeout),
        [verb] if verb == "probe-activity" => crate::cloud::role::probe_activity(&paths, timeout),
        [verb] if verb == "clone-mark" => clone_mark(&paths),
        _ => {
            return usage(
                "cloud takes daemon-info, probe-activity, clone-mark, or identity or carrier-ticket (both without --root)",
            );
        }
    };
    match answer {
        Ok(value) => {
            println!("{value}");
            code(0)
        }
        Err(e) => {
            eprintln!("cmux host cloud: {e}");
            code(1)
        }
    }
}

/// `cloud clone-mark` (`cloud/clone_mark.rs`): writes acpmux's clone marker, for the work user,
/// when the pending bind is for a machine other than the one this disk was bound as.
#[cfg(target_os = "linux")]
fn clone_mark(paths: &Paths) -> Result<serde_json::Value, String> {
    use crate::cloud::client::Store;
    use crate::cloud::clone_mark::{copied, marker, marker_text};
    let mut store = crate::cloud::role::FileStore::new(paths.clone());
    let Some(copied) = copied(&store) else { return Ok(serde_json::json!({"marked": false})) };
    let user = crate::linux::spawn::lookup_user(crate::daemon_spec::WORK_USER)
        .ok_or("no work user on this machine")?;
    let marker = marker();
    let path = paths.at(&marker);
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        std::os::unix::fs::lchown(dir, Some(user.uid), Some(user.gid))
            .map_err(|e| format!("{}: {e}", dir.display()))?;
    }
    store.write(&marker, &marker_text(&copied), 0o600)?;
    std::os::unix::fs::lchown(&path, Some(user.uid), Some(user.gid))
        .map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(serde_json::json!({"marked": true, "from": copied.from, "to": copied.to}))
}

/// `cloud carrier-ticket`: ask the Cloud agent for this machine's relay
/// Register ticket and print it. A refusal goes to stderr without a ticket.
#[cfg(target_os = "linux")]
fn carrier_ticket() -> u8 {
    use crate::cloud::carrier_ticket::{REQUEST_KEY, ticket_of};
    let line = serde_json::json!({ REQUEST_KEY: {} }).to_string();
    // The ticket's own socket and thread (`cloud/carrier_server.rs`); a
    // cmux-host from before it has only the agent socket.
    let wait = Duration::from_secs(30);
    let reply =
        match std::os::unix::net::UnixStream::connect(crate::cloud::carrier_server::CARRIER_SOCKET)
        {
            Ok(stream) => crate::github_cli::reply_on(stream, &line, wait),
            Err(_) => crate::github_cli::agent_reply(
                std::path::Path::new(crate::cloud::wire::AGENT_SOCKET),
                &line,
                wait,
            ),
        };
    match reply.map_err(|e| e.to_string()).and_then(|reply| ticket_of(&reply)) {
        Ok(ticket) => {
            println!("{ticket}");
            code(0)
        }
        Err(why) => {
            eprintln!("cmux host cloud carrier-ticket: {why}");
            code(1)
        }
    }
}

#[cfg(not(target_os = "linux"))]
fn cloud_verb(_args: &[String]) -> u8 {
    eprintln!("cmux host cloud: Linux only");
    code(4)
}

#[cfg(target_os = "linux")]
fn update_verb(args: &[String]) -> u8 {
    crate::updater::role::verb(args)
}

#[cfg(not(target_os = "linux"))]
fn update_verb(_args: &[String]) -> u8 {
    eprintln!("cmux host update: Linux only");
    code(4)
}

#[cfg(not(target_os = "linux"))]
fn rekey_verb(_args: &[String]) -> u8 {
    eprintln!("cmux host rekey: Linux only");
    code(4)
}

#[cfg(test)]
#[path = "cli_tests.rs"]
mod tests;
