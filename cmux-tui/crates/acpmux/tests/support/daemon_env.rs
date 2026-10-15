//! The one way a test starts the real `acpmux` binary (cx-s8wux).
//!
//! A test process has the host's whole environment. On a fleet host its PATH
//! holds real agent CLIs (codex, claude, gemini, opencode) with real
//! accounts: a daemon started with that environment discovers them and runs
//! live model probes, prewarms, sign-in checks and CLI auto-updates
//! (cx-w014j: a host codex ran a test's fake login shell). Every `acpmux`
//! process a test starts gets this environment instead:
//!
//! - nothing from the host (`env_clear`);
//! - `PATH`: a private directory with links to the named host tools
//!   (`python3` always, for the stand-in agents and fake shells), then the
//!   system directories. No real agent CLI can be found on it;
//! - `HOME`: `<scratch>/home` (not made here), under the scratch directory
//!   the test passes. Never the scratch directory itself: tests use that as
//!   the daemon's home or a chat's folder, and the daemon refuses to start an
//!   agent in the user's home folder unless a person picks it;
//! - `TMPDIR`: the test process's temp directory (macOS: the per-user one);
//! - `ACPMUX_AGENT_LAUNCH=deny`: the daemon starts no agent at all
//!   (cx-9ettq). A test that drives a stand-in agent (fake_agent.py,
//!   fake_claude.py) opts out with [`Agents::StandIn`]; it keeps the bare
//!   PATH, so only its stand-in can start.
//!
//! A test sets anything else it needs with `.env(...)` after this.
//! `tests/hermetic_daemon_guard.rs` refuses a test file that names the
//! binary (`CARGO_BIN_EXE_acpmux`) anywhere but here.
#![allow(dead_code)]

use std::path::{Path, PathBuf};
use std::process::Command;

/// The binary under test. Only for values (a path a daemon passes on, an
/// agent host launcher); start a process with [`acpmux`] or [`command`].
pub fn bin() -> &'static Path {
    Path::new(env!("CARGO_BIN_EXE_acpmux"))
}

/// Whether the daemon may start agent processes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Agents {
    /// `ACPMUX_AGENT_LAUNCH=deny`: no agent, probe, prewarm or sign-in check.
    Deny,
    /// Launches allowed, for a test's own stand-in agent. PATH stays bare.
    StandIn,
}

/// `acpmux` with the hermetic environment, agent launches denied.
pub fn acpmux(scratch: &Path) -> Command {
    command(scratch, Agents::Deny, &[])
}

/// `acpmux` with the hermetic environment, for a test whose daemon starts a
/// stand-in agent.
pub fn acpmux_with_stand_in_agents(scratch: &Path) -> Command {
    command(scratch, Agents::StandIn, &[])
}

/// `acpmux` with the hermetic environment; `tools` are host tools (by name,
/// found on the test's PATH) to put on the daemon's PATH besides `python3`.
pub fn command(scratch: &Path, agents: Agents, tools: &[&str]) -> Command {
    let mut cmd = Command::new(bin());
    apply(&mut cmd, scratch, agents, tools);
    cmd
}

/// The same environment for an async command.
pub fn tokio_command(scratch: &Path, agents: Agents) -> tokio::process::Command {
    let mut cmd = tokio::process::Command::new(bin());
    cmd.env_clear().envs(vars(scratch, agents, &[]));
    cmd
}

/// Clears `cmd`'s environment and sets the hermetic one.
pub fn apply<'c>(
    cmd: &'c mut Command,
    scratch: &Path,
    agents: Agents,
    tools: &[&str],
) -> &'c mut Command {
    cmd.env_clear().envs(vars(scratch, agents, tools))
}

/// The hermetic environment as pairs (for an agent host's `SpawnSpec.env`).
pub fn vars(scratch: &Path, agents: Agents, tools: &[&str]) -> Vec<(String, String)> {
    let mut env = platform_vars(&home(scratch), tools);
    if agents == Agents::Deny {
        env.push(("ACPMUX_AGENT_LAUNCH".into(), "deny".into()));
    }
    env
}

/// The `HOME` the hermetic environment gives: `<scratch>/home`.
pub fn home(scratch: &Path) -> PathBuf {
    scratch.join("home")
}

#[cfg(unix)]
fn platform_vars(home: &Path, tools: &[&str]) -> Vec<(String, String)> {
    vec![
        ("PATH".into(), bare_path(tools)),
        ("HOME".into(), home.display().to_string()),
        ("TMPDIR".into(), std::env::temp_dir().display().to_string()),
    ]
}

/// Windows: only what a process needs to start (the system directories and
/// the temp directory), the scratch profile as home. No tool links: Windows
/// tests start no stand-in agent.
#[cfg(windows)]
fn platform_vars(home: &Path, tools: &[&str]) -> Vec<(String, String)> {
    assert!(tools.is_empty(), "no host tools on Windows");
    let mut env = Vec::new();
    for key in ["SystemRoot", "SystemDrive", "windir", "TEMP", "TMP"] {
        if let Ok(value) = std::env::var(key) {
            env.push((key.to_owned(), value));
        }
    }
    let root = std::env::var("SystemRoot").unwrap_or_else(|_| r"C:\Windows".into());
    env.push(("PATH".into(), format!(r"{root}\System32;{root}")));
    env.push(("USERPROFILE".into(), home.display().to_string()));
    env.push(("HOME".into(), home.display().to_string()));
    env
}

/// `<dir>:/usr/bin:/bin:/usr/sbin:/sbin`, where `<dir>` (one per process and
/// tool set, made once) links `python3` and `tools` from the test's PATH.
#[cfg(unix)]
pub fn bare_path(tools: &[&str]) -> String {
    let mut names = vec!["python3"];
    names.extend(tools.iter().copied().filter(|t| *t != "python3"));
    let dir =
        std::env::temp_dir().join(format!("amx-bin-{}-{}", std::process::id(), names.join("-")));
    std::fs::create_dir_all(&dir).unwrap();
    for name in &names {
        let link = dir.join(name);
        if link.exists() {
            continue;
        }
        let target = host_tool(name);
        // Tests in one process race here: a link another test made is fine.
        match std::os::unix::fs::symlink(&target, &link) {
            Err(e) if e.kind() != std::io::ErrorKind::AlreadyExists => {
                panic!("link {} to {}: {e}", target.display(), link.display())
            }
            _ => {}
        }
    }
    format!("{}:/usr/bin:/bin:/usr/sbin:/sbin", dir.display())
}

/// `name` on the test process's own PATH.
#[cfg(unix)]
fn host_tool(name: &str) -> PathBuf {
    std::env::var_os("PATH")
        .iter()
        .flat_map(std::env::split_paths)
        .map(|d| d.join(name))
        .find(|p| p.is_file())
        .unwrap_or_else(|| panic!("{name} on the test's PATH"))
}
