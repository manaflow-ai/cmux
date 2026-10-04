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

const USAGE: &str = "usage: cmux host run [--roles-only] | status [--json] [--root DIR] | roles [--json] | logs <role> [--bytes N]";

fn code(n: u8) -> u8 {
    n
}

/// Options of `run` that only tests and diagnostics change.
fn parse_run(args: &[String], self_argv: Vec<String>) -> Result<Config, String> {
    let mut cfg = Config::production();
    cfg.self_argv = self_argv;
    if let Ok(bind) = std::env::var("CMUX_TUI_REMOTE_WS_BIND")
        && !bind.is_empty()
    {
        cfg.remote_ws_bind = bind;
    }
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
        "run" if cfg!(not(target_os = "linux")) || rest.iter().any(|a| a == "--roles-only") => {
            if rest.iter().any(|a| a != "--roles-only") {
                return usage("run --roles-only takes no other flags");
            }
            match install_layout() {
                Ok((layout, _)) => crate::run_roles::run_roles(&layout),
                Err(e) => {
                    eprintln!("cmux host run: {e}");
                    code(1)
                }
            }
        }
        "run" => match parse_run(rest, self_argv) {
            Ok(cfg) => run_agent(cfg),
            Err(e) => usage(&e),
        },
        "status" => status_verb(rest),
        "roles" => roles_verb(rest),
        "logs" => logs_verb(rest),
        "rekey" => rekey_verb(rest),
        "--help" | "-h" | "help" => {
            println!("{USAGE}");
            code(0)
        }
        other => usage(&format!("unknown verb {other}")),
    }
}

/// The install layout roles receive (CMUX_SERVER_MODE, else system as root).
fn install_layout() -> Result<(Layout, InstallMode), String> {
    let mode = cmux_server::host::resolve_mode(false);
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
    let layout = match install_layout() {
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
    let layout = match install_layout() {
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
    let install = install_layout();
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
    let work_user = cfg.daemon.user.clone().unwrap_or_else(|| crate::daemon_spec::WORK_USER.to_owned());
    let work_user = crate::linux::spawn::lookup_user(&work_user).map(|u| {
        crate::proc_roles::privilege::WorkUser { name: u.name, uid: u.uid, gid: u.gid, home: u.home }
    });
    let platform = match crate::linux::LinuxPlatform::new(cfg) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("cmux host: setup failed: {e}");
            return code(1);
        }
    };
    let roles: Vec<Box<dyn cmux_server_core::role::Role>> =
        vec![Box::new(crate::proc_roles::ProcessRoles::new(work_user))];
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

    #[test]
    fn status_without_agent_is_not_found() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().display().to_string();
        assert_eq!(status_verb(&s(&["--json", "--root", &root])), 3);
        assert_eq!(run(&s(&["nope"]), vec![]), 2);
    }
}
