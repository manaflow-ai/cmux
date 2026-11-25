//! `acpmux harness install ID`: put a coding agent's CLI on this machine through its vendor's own
//! installer, when the person asked for it (the first-run Install button, or this command). Nothing
//! here runs on its own: an agent is installed only by an explicit call.
//!
//! - `claude`: Claude Code's official native installer (`https://claude.ai/install.sh`, the one
//!   `machine-join.sh` runs on a joined machine), which puts `claude` in `~/.local/bin`.
//! - `codex`: cmux's managed Codex runtime (`managed_codex`: the pinned official release, its
//!   SHA-256 checked), on macOS and Linux.
//! - `opencode`: `npm install -g opencode-ai` where npm is, else OpenCode's official installer
//!   (`https://opencode.ai/install`, into `~/.opencode/bin`). Microsoft Foundry runs on it, and
//!   uses the official installer when it is also installing the Azure CLI with Homebrew.
//!
//! Each step is one JSON line on stdout with `--json` (`{"step", "state", "detail"}`), so a caller
//! can draw progress; the last line is the result (`{"id", "installed", "path", "version"}`), or the
//! command fails with what went wrong and the vendor's install page to try instead.

use anyhow::{Result, anyhow, bail};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::time::Duration;

/// The agents this command installs, with the page a person can install them from by hand.
pub const AGENTS: &[(&str, &str, &str)] = &[
    ("claude", "Claude Code", "https://docs.anthropic.com/en/docs/claude-code/setup"),
    ("codex", "Codex", "https://developers.openai.com/codex/cli"),
    ("opencode", "OpenCode", "https://opencode.ai/docs/"),
];

const CLAUDE_INSTALLER: &str = "https://claude.ai/install.sh";
const OPENCODE_INSTALLER: &str = "https://opencode.ai/install";
const OPENCODE_NPM_PACKAGE: &str = "opencode-ai";
/// An installer downloads a native build: bounded so a stalled download fails with a reason.
const INSTALL_LIMIT: Duration = Duration::from_secs(600);

/// `ID`'s display name and install page, or the error that names the ids this command installs.
pub fn agent(id: &str) -> Result<(&'static str, &'static str)> {
    AGENTS
        .iter()
        .find(|(known, _, _)| *known == id)
        .map(|(_, name, page)| (*name, *page))
        .ok_or_else(|| {
            let ids = AGENTS.iter().map(|(id, _, _)| *id).collect::<Vec<_>>().join(", ");
            anyhow!("acpmux harness install installs {ids}; `{id}` is not one of them")
        })
}

/// Runs `ID`'s installer, reporting each step through `step`, and answers the result line.
pub async fn install(id: &str, mut step: impl FnMut(&str, &str, &str)) -> Result<Value> {
    let (name, page) = agent(id)?;
    let fail = |what: String| anyhow!("{name} did not install: {what}. Install it from {page}");
    let result = match id {
        "claude" => {
            if let Some(path) = claude_path() {
                step(
                    "check",
                    "done",
                    &format!("{name} is already installed at {}", path.display()),
                );
                return Ok(result_line(id, &path));
            }
            step("download", "running", CLAUDE_INSTALLER);
            let script = fetch(CLAUDE_INSTALLER).await.map_err(|e| fail(format!("{e:#}")))?;
            step("download", "done", &format!("{} bytes", script.len()));
            step("install", "running", "the official installer");
            run_installer(&script).await.map_err(|e| fail(format!("{e:#}")))?;
            let path = claude_path()
                .ok_or_else(|| fail("the installer finished but no claude was found".into()))?;
            step("install", "done", &path.display().to_string());
            result_line(id, &path)
        }
        "codex" => {
            step("download", "running", "the pinned official Codex release");
            let ready =
                crate::managed_codex::install().await.map_err(|e| fail(format!("{e:#}")))?;
            step("install", "done", ready.get("path").and_then(Value::as_str).unwrap_or_default());
            result_line(id, &crate::managed_codex::managed_path())
        }
        "opencode" => {
            if let Some(path) = opencode_path() {
                step(
                    "check",
                    "done",
                    &format!("{name} is already installed at {}", path.display()),
                );
                return Ok(result_line(id, &path));
            }
            if let Some(npm) = crate::config::which("npm") {
                step("install", "running", &format!("npm install -g {OPENCODE_NPM_PACKAGE}"));
                run_tool(&npm, &["install", "-g", OPENCODE_NPM_PACKAGE])
                    .await
                    .map_err(|e| fail(format!("{e:#}")))?;
                let path = opencode_path().ok_or_else(|| {
                    fail("the installer finished but no opencode was found".into())
                })?;
                step("install", "done", &path.display().to_string());
                result_line(id, &path)
            } else {
                return install_opencode_official(step).await;
            }
        }
        // agent() admits only AGENTS, so no other id gets here.
        other => bail!("acpmux harness install has no installer for `{other}`"),
    };
    Ok(result)
}

/// OpenCode through its official installer (`~/.opencode/bin`), not `npm install -g`. Foundry uses
/// this when the Azure CLI is being installed with Homebrew at the same time: both would otherwise
/// write `/opt/homebrew`.
pub(crate) async fn install_opencode_official(
    mut step: impl FnMut(&str, &str, &str),
) -> Result<Value> {
    let (name, page) = agent("opencode")?;
    let fail = |what: String| anyhow!("{name} did not install: {what}. Install it from {page}");
    if let Some(path) = opencode_path() {
        step("check", "done", &format!("{name} is already installed at {}", path.display()));
        return Ok(result_line("opencode", &path));
    }
    step("download", "running", OPENCODE_INSTALLER);
    let script = fetch(OPENCODE_INSTALLER).await.map_err(|e| fail(format!("{e:#}")))?;
    step("download", "done", &format!("{} bytes", script.len()));
    step("install", "running", "the official installer");
    run_installer(&script).await.map_err(|e| fail(format!("{e:#}")))?;
    let path = opencode_path()
        .ok_or_else(|| fail("the installer finished but no opencode was found".into()))?;
    step("install", "done", &path.display().to_string());
    Ok(result_line("opencode", &path))
}

fn result_line(id: &str, path: &Path) -> Value {
    let version = crate::harness_health::probe::installed_version(&path.display().to_string()).ok();
    json!({"id": id, "installed": true, "path": path, "version": version})
}

/// `claude` on PATH, else the native installer's `~/.local/bin/claude` (`machine-join.sh`'s `find_claude`).
fn claude_path() -> Option<PathBuf> {
    which_on_path("claude").or_else(|| {
        let local = dirs::home_dir()?.join(".local/bin/claude");
        is_executable(&local).then_some(local)
    })
}

/// `opencode` on the login PATH, else OpenCode's installer's `~/.opencode/bin/opencode`.
pub(crate) fn opencode_path() -> Option<PathBuf> {
    crate::config::which("opencode").map(PathBuf::from)
}

pub(crate) fn which_on_path(program: &str) -> Option<PathBuf> {
    std::env::var_os("PATH")
        .into_iter()
        .flat_map(|paths| std::env::split_paths(&paths).collect::<Vec<_>>())
        .map(|dir| dir.join(program))
        .find(|path| is_executable(path))
}

/// A file someone may run: a stale or non-executable `claude` is no installed CLI.
#[cfg(unix)]
pub(crate) fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt as _;
    path.metadata().is_ok_and(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
}

#[cfg(not(unix))]
pub(crate) fn is_executable(path: &Path) -> bool {
    path.is_file()
}

async fn fetch(url: &str) -> Result<String> {
    // The workspace builds reqwest with `rustls-no-provider` (as `managed_codex::install`).
    let _ = rustls::crypto::ring::default_provider().install_default();
    // HTTPS only, redirects included: the body runs as bash, so no hop may be plaintext.
    let client = crate::happy_dial::http_client().https_only(true).build()?;
    let text = client.get(url).send().await?.error_for_status()?.text().await?;
    if !text.starts_with("#!") {
        bail!("{url} did not answer with an installer script")
    }
    Ok(text)
}

/// The installer script on bash's stdin, with no terminal: its own output is kept for the error.
/// It runs in a process group of its own, and the limit covers the whole run: past it, the
/// group (bash and anything the installer started) is killed, so nothing outlives the command.
#[cfg(not(unix))]
async fn run_installer(_script: &str) -> Result<()> {
    bail!("the installer is a shell script for macOS and Linux")
}

#[cfg(unix)]
async fn run_installer(script: &str) -> Result<()> {
    let mut bash = tokio::process::Command::new("/bin/bash");
    bash.arg("-s");
    run_bounded(bash, Some(script)).await
}

#[cfg(not(unix))]
pub(crate) async fn run_tool(_program: &str, _args: &[&str]) -> Result<()> {
    bail!("acpmux runs installers on macOS and Linux")
}

/// `PROGRAM ARGS` (`npm install -g`, `brew install`) with the login PATH, bounded and in its own
/// process group as [`run_installer`].
#[cfg(unix)]
pub(crate) async fn run_tool(program: &str, args: &[&str]) -> Result<()> {
    let mut cmd = tokio::process::Command::new(program);
    cmd.args(args);
    // npm runs under `#!/usr/bin/env node`: node is on the login PATH, not the daemon's own.
    if let Some(path) = crate::login_env::path() {
        cmd.env("PATH", path);
    }
    run_bounded(cmd, None).await
}

#[cfg(unix)]
async fn run_bounded(mut cmd: tokio::process::Command, input: Option<&str>) -> Result<()> {
    use std::process::Stdio;
    use tokio::io::AsyncWriteExt as _;
    let stdin = if input.is_some() { Stdio::piped() } else { Stdio::null() };
    let mut child = cmd
        .stdin(stdin)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0)
        .kill_on_drop(true)
        .spawn()?;
    let group = child.id();
    let stdin = child.stdin.take();
    let input = input.map(str::to_owned);
    let run = async move {
        if let (Some(mut stdin), Some(input)) = (stdin, input) {
            stdin.write_all(input.as_bytes()).await?;
        }
        anyhow::Ok(child.wait_with_output().await?)
    };
    let out = match tokio::time::timeout(INSTALL_LIMIT, run).await {
        Ok(out) => out?,
        Err(_) => {
            if let Some(group) = group {
                // SAFETY: killpg signals only the group this function started (process_group(0)).
                unsafe { libc::killpg(group as i32, libc::SIGKILL) };
            }
            bail!("the installer did not finish in {} s", INSTALL_LIMIT.as_secs())
        }
    };
    if !out.status.success() {
        bail!("the installer exited with {}: {}", out.status, last_line(&out.stderr, &out.stdout))
    }
    Ok(())
}

/// The installer's last non-empty line: from stderr, else stdout (an installer may report its
/// failure on either).
fn last_line(stderr: &[u8], stdout: &[u8]) -> String {
    [stderr, stdout]
        .iter()
        .find_map(|pipe| {
            let text = String::from_utf8_lossy(pipe);
            text.lines().rev().map(str::trim).find(|line| !line.is_empty()).map(str::to_owned)
        })
        .unwrap_or_else(|| "no output".to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_known_agents_install() {
        assert_eq!(agent("claude").unwrap().0, "Claude Code");
        assert_eq!(agent("codex").unwrap().0, "Codex");
        assert_eq!(agent("opencode").unwrap().0, "OpenCode");
        let err = agent("gemini").unwrap_err().to_string();
        assert!(err.contains("installs claude, codex, opencode"), "{err}");
    }

    #[cfg(unix)]
    #[test]
    fn only_an_executable_file_counts_as_installed() {
        use std::os::unix::fs::PermissionsExt as _;
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("claude");
        std::fs::write(&file, "#!/bin/sh\n").unwrap();
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(!is_executable(&file));
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert!(is_executable(&file));
        assert!(!is_executable(dir.path()));
    }

    #[test]
    fn a_failure_names_the_last_line_of_stderr_else_stdout() {
        assert_eq!(last_line(b"warn\nboom\n\n", b"ok"), "boom");
        assert_eq!(last_line(b"  \n", b"step 1\nerror: offline\n"), "error: offline");
        assert_eq!(last_line(b"", b""), "no output");
    }

    /// Microsoft Foundry runs on OpenCode, and connecting it installs OpenCode through npm where
    /// npm is: the package goes in globally, and a failed install says npm's own last line.
    #[cfg(unix)]
    #[tokio::test]
    async fn npm_installs_opencode_globally_and_a_failure_names_npms_last_line() {
        use std::os::unix::fs::PermissionsExt as _;
        let dir = tempfile::tempdir().unwrap();
        let args = dir.path().join("args");
        let ok = dir.path().join("npm-ok");
        std::fs::write(&ok, format!("#!/bin/sh\necho \"$@\" > '{}'\n", args.display())).unwrap();
        let bad = dir.path().join("npm-bad");
        std::fs::write(&bad, "#!/bin/sh\necho 'npm ERR! network offline' >&2\nexit 1\n").unwrap();
        for file in [&ok, &bad] {
            std::fs::set_permissions(file, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        run_tool(ok.to_str().unwrap(), &["install", "-g", OPENCODE_NPM_PACKAGE]).await.unwrap();
        assert_eq!(std::fs::read_to_string(&args).unwrap().trim(), "install -g opencode-ai");
        let err = run_tool(bad.to_str().unwrap(), &["install", "-g", OPENCODE_NPM_PACKAGE])
            .await
            .unwrap_err();
        assert!(err.to_string().contains("npm ERR! network offline"), "{err:#}");
    }

    #[tokio::test]
    async fn an_unknown_agent_runs_nothing() {
        let mut steps = 0;
        assert!(install("aider", |_, _, _| steps += 1).await.is_err());
        assert_eq!(steps, 0);
    }
}
