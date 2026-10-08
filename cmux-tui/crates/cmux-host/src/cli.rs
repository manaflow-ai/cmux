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
//! - `cloud daemon-info | probe-activity`: bake and smoke evidence for the
//!   Cloud agent role (the daemon block bind sends; the activity stream).
//!
//! Exit codes follow `cmux server`: 0 ok, 1 internal, 2 usage, 3 not
//! found, 4 rejected (unsupported platform).

use std::path::PathBuf;
use std::time::Duration;

use cmux_server_core::layout::Layout;
use cmux_server_core::platform::InstallMode;

use crate::config::{Config, Paths, STATUS_FILE};
use crate::proc_roles::RolePaths;
use crate::status;

const USAGE: &str = "usage: cmux host run [--roles-only] [--mode user|system] | status [--json] [--root DIR] | roles [--json] | logs <role> [--bytes N] | cloud daemon-info|probe-activity [--root DIR] | team-ssh apply|principals <user>|session-open|reap|sync [--root DIR] | team-enroll --team T --epoch E --nonce N | --commit …";

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
        "team-ssh" => crate::team_ssh::cli::run(rest),
        "team-enroll" => crate::team_ssh::enroll::run(rest),
        "--help" | "-h" | "help" => {
            println!("{USAGE}");
            code(0)
        }
        other => usage(&format!("unknown verb {other}")),
    }
}

/// `run`: the roles-only loop (macOS, or `--roles-only`), else the Linux
/// bind agent. `mode` is the units' `--mode`.
fn run_verb(mode: Option<InstallMode>, rest: &[String], self_argv: Vec<String>) -> u8 {
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
        for role in status["roles"].as_array().into_iter().flatten() {
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
    let cloud = crate::cloud::role::CloudRole::new(cfg.paths.clone());
    let platform = match crate::linux::LinuxPlatform::new(cfg) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("cmux host: setup failed: {e}");
            return code(1);
        }
    };
    let roles: Vec<Box<dyn cmux_server_core::role::Role>> =
        vec![Box::new(crate::proc_roles::ProcessRoles::new(work_user)), Box::new(cloud)];
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
    let (paths, rest) = match root_arg(args) {
        Ok(v) => v,
        Err(e) => return usage(&e),
    };
    let timeout = Duration::from_secs(10);
    let answer = match rest.as_slice() {
        [verb] if verb == "daemon-info" => crate::cloud::role::print_daemon_info(&paths, timeout),
        [verb] if verb == "probe-activity" => crate::cloud::role::probe_activity(&paths, timeout),
        _ => return usage("cloud takes daemon-info or probe-activity"),
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

#[cfg(not(target_os = "linux"))]
fn cloud_verb(_args: &[String]) -> u8 {
    eprintln!("cmux host cloud: Linux only");
    code(4)
}

#[cfg(not(target_os = "linux"))]
fn rekey_verb(_args: &[String]) -> u8 {
    eprintln!("cmux host rekey: Linux only");
    code(4)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(v: &[&str]) -> Vec<String> {
        v.iter().map(|x| (*x).to_owned()).collect()
    }

    #[test]
    fn run_flags_parse() {
        let cfg = parse_run(
            &s(&[
                "--root",
                "/tmp/r",
                "--metadata",
                "127.0.0.1:9",
                "--daemon-user",
                "u",
                "--no-announce",
                "--rearm-delay-ms",
                "5",
            ]),
            vec![],
        )
        .unwrap();
        assert_eq!(cfg.paths.root(), std::path::Path::new("/tmp/r"));
        assert_eq!(cfg.metadata_addr.port(), 9);
        assert_eq!(cfg.daemon.user.as_deref(), Some("u"));
        assert!(!cfg.announce);
        assert_eq!(cfg.rearm_delay, Duration::from_millis(5));
        assert!(parse_run(&s(&["--bogus"]), vec![]).is_err());
        assert!(parse_run(&s(&["--root"]), vec![]).is_err());
    }

    /// The units run `cmux host run --mode <user|system>` (launchd today;
    /// systemd and Windows later). `--mode` is accepted on both the
    /// roles-only path and the Linux bind agent path, anywhere in the args,
    /// once; it overrides CMUX_SERVER_MODE.
    #[test]
    fn run_accepts_the_units_mode_argument() {
        assert_eq!(split_mode(&s(&[])), Ok((None, s(&[]))));
        assert_eq!(split_mode(&s(&["--mode", "user"])), Ok((Some(InstallMode::User), s(&[]))));
        assert_eq!(
            split_mode(&s(&["--roles-only", "--mode", "system"])),
            Ok((Some(InstallMode::System), s(&["--roles-only"])))
        );
        assert_eq!(
            split_mode(&s(&["--root", "/r", "--mode", "user", "--no-announce"])),
            Ok((Some(InstallMode::User), s(&["--root", "/r", "--no-announce"])))
        );
        assert!(split_mode(&s(&["--mode"])).is_err());
        assert!(split_mode(&s(&["--mode", "root"])).is_err());
        assert!(split_mode(&s(&["--mode", "user", "--mode", "user"])).is_err());
        // The launchd agent's exact argv (cmux-server-core) parses here.
        for mode in [InstallMode::User, InstallMode::System] {
            let argv = cmux_server_core::units::host_run_argv_with_mode("cmux", mode);
            assert_eq!(argv[1..3], ["host", "run"]);
            assert_eq!(split_mode(&argv[3..]), Ok((Some(mode), s(&[]))));
        }
    }

    /// The units pass --mode now; CMUX_SERVER_MODE still works for one
    /// release (an old unit) and logs a deprecation line; --mode wins.
    #[test]
    fn the_mode_environment_variable_is_a_deprecated_fallback() {
        assert_eq!(env_mode_deprecation(Some(InstallMode::User), Some("system")), None);
        assert_eq!(env_mode_deprecation(None, None), None);
        let line = env_mode_deprecation(None, Some("system")).unwrap();
        assert!(line.contains("CMUX_SERVER_MODE") && line.contains("--mode"), "{line}");
    }

    #[test]
    fn status_without_agent_is_not_found() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().display().to_string();
        assert_eq!(status_verb(&s(&["--json", "--root", &root])), 3);
        assert_eq!(run(&s(&["nope"]), vec![]), 2);
    }
}
