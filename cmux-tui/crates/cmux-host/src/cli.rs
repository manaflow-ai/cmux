//! `cmux host …` verbs, also the standalone `cmux-host` binary.
//!
//! - `run`: the bind agent and supervisor (the frozen unit command
//!   `cmux host run`). Linux only.
//! - `status [--json]`: the agent's published state.
//! - `rekey <instance-id>`: internal; the off-critical-path identity job
//!   the agent starts after a bind.
//!
//! Exit codes follow `cmux server`: 0 ok, 1 internal, 2 usage, 3 not
//! found, 4 rejected (unsupported platform).

use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Duration;

use crate::config::{Config, Paths, STATUS_FILE};
use crate::status;

const USAGE: &str = "usage: cmux host run | status [--json] [--root DIR]";

fn code(n: u8) -> ExitCode {
    ExitCode::from(n)
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

fn status_verb(args: &[String]) -> ExitCode {
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

fn usage(msg: &str) -> ExitCode {
    eprintln!("cmux host: {msg}\n{USAGE}");
    code(2)
}

/// Entry for `cmux host <args>` (and `cmux-host <args>`). `self_argv` is
/// how to run this binary's `host` verbs again (`[cmux, host]` from the
/// main binary; empty means the current executable).
pub fn run(args: &[String], self_argv: Vec<String>) -> ExitCode {
    let Some((verb, rest)) = args.split_first() else { return usage("missing verb") };
    match verb.as_str() {
        "run" => match parse_run(rest, self_argv) {
            Ok(cfg) => run_agent(cfg),
            Err(e) => usage(&e),
        },
        "status" => status_verb(rest),
        "rekey" => rekey_verb(rest),
        "--help" | "-h" | "help" => {
            println!("{USAGE}");
            code(0)
        }
        other => usage(&format!("unknown verb {other}")),
    }
}

#[cfg(target_os = "linux")]
fn run_agent(mut cfg: Config) -> ExitCode {
    use crate::agent::{ActionLog, Agent};
    // The install layout roles receive (CMUX_SERVER_MODE, else system as
    // root). Without one the agent still binds and supervises; roles only
    // report the error.
    let mode = cmux_server::host::resolve_mode(false);
    let install = cmux_server::host::layout_for(mode, &cmux_server::host::layout_env())
        .map(|layout| (layout, mode))
        .map_err(|e| e.to_string());
    if let Ok((layout, _)) = &install {
        cfg.server_config = Some(PathBuf::from(layout.config_file.as_str()));
    }
    // TODO(lane 10): ChannelChanged has no source yet; the control-plane
    // push lands with the updater role.
    let log = match ActionLog::new(cfg.action_log.as_deref()) {
        Ok(log) => log,
        Err(e) => return usage(&format!("action log: {e}")),
    };
    let platform = match crate::linux::LinuxPlatform::new(cfg) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("cmux host: setup failed: {e}");
            return code(1);
        }
    };
    match Agent::new(platform, Vec::new(), install, log).run() {
        Ok(()) => code(0),
        Err(e) => {
            eprintln!("cmux host: {e}");
            code(1)
        }
    }
}

#[cfg(not(target_os = "linux"))]
fn run_agent(_cfg: Config) -> ExitCode {
    eprintln!("cmux host run: this platform has no bind agent yet (Linux only)");
    code(4)
}

#[cfg(target_os = "linux")]
fn rekey_verb(args: &[String]) -> ExitCode {
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
fn rekey_verb(_args: &[String]) -> ExitCode {
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
        let dbg = |c: ExitCode| format!("{c:?}");
        assert_eq!(dbg(status_verb(&s(&["--json", "--root", &root]))), dbg(code(3)));
        assert_eq!(dbg(run(&s(&["nope"]), vec![])), dbg(code(2)));
    }
}
