//! Script-facing help and harness reload output, without starting a daemon.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use serde_json::Value;
use std::path::PathBuf;
use std::process::Output;

struct Scratch(PathBuf);

impl Scratch {
    fn new(tag: &str) -> Self {
        let root = std::env::temp_dir().join(format!("amx-help-{tag}-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        Self(root)
    }

    fn run(&self, args: &[&str]) -> Output {
        daemon_env::acpmux(&self.0)
            .args(args)
            .env("ACPMUX_HOME", self.0.join("state"))
            .env("ACPMUX_SOCKET", self.0.join("daemon.sock"))
            .env("ACPMUX_LOGIN_ENV", "0")
            .current_dir(&self.0)
            .output()
            .unwrap()
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn root_help_describes_briefs_defaults_and_host_management() {
    let scratch = Scratch::new("root");
    let out = scratch.run(&["--help"]);
    assert!(out.status.success());
    let help = String::from_utf8(out.stdout).unwrap();
    for name in ["briefs", "defaults"] {
        let line = help.lines().find(|line| line.trim_start().starts_with(name)).unwrap();
        assert!(line.split_whitespace().count() > 1, "{name} has no description: {help}");
    }
    let host = help.lines().find(|line| line.trim_start().starts_with("host ")).unwrap();
    assert!(host.contains("status") && host.contains("setup"), "{host}");
    assert!(!host.contains("Remote daemons: add, ls, rm."), "{host}");
}

#[test]
fn daemon_help_exposes_restart_and_defaults_owns_its_examples() {
    let scratch = Scratch::new("nested");
    let daemon = scratch.run(&["daemon", "--help"]);
    assert!(daemon.status.success());
    let help = String::from_utf8(daemon.stdout).unwrap();
    assert!(help.lines().any(|line| line.trim_start().starts_with("restart ")), "{help}");
    let defaults = scratch.run(&["defaults", "--help"]);
    assert!(defaults.status.success());
    let help = String::from_utf8(defaults.stdout).unwrap();
    assert!(help.contains("defaults claude"), "{help}");
    let preset = scratch.run(&["preset", "--help"]);
    assert!(preset.status.success());
    let help = String::from_utf8(preset.stdout).unwrap();
    assert!(!help.contains("defaults claude"), "{help}");
}

#[test]
fn harness_reload_json_reports_no_daemon_without_starting_one() {
    let scratch = Scratch::new("reload");
    let out = scratch.run(&["harness", "reload", "--json"]);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let value: Value = serde_json::from_slice(&out.stdout)
        .unwrap_or_else(|e| panic!("{e}: {}", String::from_utf8_lossy(&out.stdout)));
    assert_eq!(value["daemonReloaded"], false);
    assert!(!scratch.0.join("daemon.sock").exists());
    assert!(!scratch.0.join("state/daemon.lock").exists());
}
