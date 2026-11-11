//! `acpmux harness install ID`: put a coding agent's CLI on this machine through its vendor's own
//! installer, when the person asked for it (the first-run Install button, or this command). Nothing
//! here runs on its own: an agent is installed only by an explicit call.
//!
//! - `claude`: Claude Code's official native installer (`https://claude.ai/install.sh`, the one
//!   `machine-join.sh` runs on a joined machine), which puts `claude` in `~/.local/bin`.
//! - `codex`: cmux's managed Codex runtime (`managed_codex`: the pinned official release, its
//!   SHA-256 checked), on macOS.
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
];

const CLAUDE_INSTALLER: &str = "https://claude.ai/install.sh";
/// Claude's installer downloads a native build: bounded so a stalled download fails with a reason.
const CLAUDE_INSTALL_LIMIT: Duration = Duration::from_secs(600);

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

/// The refusal code of a `session/new` whose harness is a coding agent this machine does not have
/// (`data.code`, as the pane reads a refusal's code): the pane answers it with one line and Install
/// (or the agent this machine does have), never the resolver's list of profiles.
pub const NOT_INSTALLED: &str = "harness.not_installed";

/// Coding agents acpmux finds by name on PATH (`config/discover.rs`), with the name a person
/// knows them by. A chat asked of one that is not here is "not installed", not "unknown".
const KNOWN: &[(&str, &str)] = &[
    ("claude", "Claude Code"),
    ("codex", "Codex"),
    ("gemini", "Gemini CLI"),
    ("opencode", "OpenCode"),
    ("cursor", "Cursor"),
    ("grok", "Grok"),
    ("hermes", "Hermes"),
    ("pi", "Pi"),
    ("omp", "Oh My Pi"),
    ("prime", "Prime Agent"),
    ("deepseek", "DeepSeek"),
];

/// The agent a new chat starts on when this machine has no coding agent at all: Claude Code, the
/// first one `default_harness.rs` prefers.
pub const FIRST_CHOICE: &str = "claude";

/// The coding agents a chat could start on here instead: ACP and Claude Code profiles that run
/// (not unavailable), never a terminal, the Chief, UniiChat or the model router's hidden profile.
/// Claude Code and Codex first, then by name.
pub fn installed_alternatives(cfg: &crate::config::Config) -> Vec<String> {
    use crate::config::{CHIEF_FAMILY, CMUX_ROUTER_PROFILE, HarnessKind, UNIICHAT_PROFILE};
    let mut out: Vec<String> = cfg
        .harnesses
        .iter()
        .filter(|(name, profile)| {
            let family = crate::config::derive_family(name, profile);
            profile.kind != HarnessKind::Terminal
                && family != CHIEF_FAMILY
                && family != UNIICHAT_PROFILE
                && name.as_str() != CMUX_ROUTER_PROFILE
                && !cfg.unavailable.contains_key(name.as_str())
        })
        .map(|(name, _)| name.clone())
        .collect();
    let rank = |name: &str| match name {
        "claude" => 0,
        "codex" => 1,
        _ => 2,
    };
    out.sort_by(|a, b| rank(a).cmp(&rank(b)).then_with(|| a.cmp(b)));
    out
}

/// `session/new`'s refusal for `head` when it names a coding agent this machine does not have
/// (no profile and no family of that name), else None. `data.code` is [`NOT_INSTALLED`];
/// `data.details` names the agent, whether `acpmux harness install` installs it, and the agents
/// installed here a chat could start on instead.
pub fn not_installed(cfg: &crate::config::Config, head: &str) -> Option<crate::rpc::RpcError> {
    let (id, name) = KNOWN.iter().find(|(id, _)| *id == head)?;
    if cfg.harnesses.contains_key(*id) || cfg.families().contains_key(*id) {
        return None;
    }
    Some(not_installed_error(id, name, installed_alternatives(cfg)))
}

fn not_installed_error(id: &str, name: &str, installed: Vec<String>) -> crate::rpc::RpcError {
    crate::rpc::RpcError::invalid_params(format!("{name} is not installed on this machine"))
        .with_data(json!({
            "code": NOT_INSTALLED,
            "errorKind": NOT_INSTALLED,
            "details": {
                "harness": id,
                "name": name,
                "installable": agent(id).is_ok(),
                "installed": installed,
            },
        }))
}

/// A new chat with no agent named on a machine whose config names no default and that has no
/// coding agent: Claude Code is not installed (the agent it would have started on).
pub fn none_installed(cfg: &crate::config::Config) -> crate::rpc::RpcError {
    not_installed_error(FIRST_CHOICE, "Claude Code", installed_alternatives(cfg))
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
        // agent() admits only AGENTS, so no other id gets here.
        other => bail!("acpmux harness install has no installer for `{other}`"),
    };
    Ok(result)
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

fn which_on_path(program: &str) -> Option<PathBuf> {
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
    let client = reqwest::Client::builder().https_only(true).build()?;
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
    bail!("Claude Code's installer is a shell script for macOS and Linux")
}

#[cfg(unix)]
async fn run_installer(script: &str) -> Result<()> {
    use tokio::io::AsyncWriteExt as _;
    let mut child = tokio::process::Command::new("/bin/bash")
        .arg("-s")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .process_group(0)
        .kill_on_drop(true)
        .spawn()?;
    let group = child.id();
    let mut stdin = child.stdin.take().ok_or_else(|| anyhow!("no stdin for bash"))?;
    let script = script.to_owned();
    let run = async move {
        stdin.write_all(script.as_bytes()).await?;
        drop(stdin);
        anyhow::Ok(child.wait_with_output().await?)
    };
    let out = match tokio::time::timeout(CLAUDE_INSTALL_LIMIT, run).await {
        Ok(out) => out?,
        Err(_) => {
            if let Some(group) = group {
                // SAFETY: killpg signals only the group this function started (process_group(0)).
                unsafe { libc::killpg(group as i32, libc::SIGKILL) };
            }
            bail!("the installer did not finish in {} s", CLAUDE_INSTALL_LIMIT.as_secs())
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

    fn profile(
        kind: crate::config::HarnessKind,
        family: Option<&str>,
    ) -> crate::config::HarnessProfile {
        crate::config::HarnessProfile {
            kind,
            argv: vec!["/bin/true".into()],
            env: Default::default(),
            description: None,
            fallback: None,
            family: family.map(str::to_owned),
            models: vec![],
            model: None,
            effort: None,
            policy: None,
        }
    }

    /// A fresh Mac (only the built-in Chief and UniiChat): a chat asked of Claude Code, or of
    /// nothing, is refused as not installed, typed, with nothing to start on instead; with Codex
    /// here it names Codex. An agent that is here, or an unknown name, is not this refusal.
    #[test]
    fn a_missing_coding_agent_is_refused_typed_with_the_installed_ones() {
        use crate::config::HarnessKind;
        let mut cfg = crate::config::Config::default();
        cfg.harnesses.insert("chief".into(), profile(HarnessKind::Acp, Some("chief")));
        cfg.harnesses.insert("unii".into(), profile(HarnessKind::Acp, Some("unii")));
        let err = not_installed(&cfg, "claude").expect("claude is missing");
        let data = err.data.clone().unwrap();
        assert_eq!(data["code"], NOT_INSTALLED);
        assert_eq!(data["details"]["harness"], "claude");
        assert_eq!(data["details"]["name"], "Claude Code");
        assert_eq!(data["details"]["installable"], true);
        assert_eq!(data["details"]["installed"], json!([]));
        assert_eq!(err.message, "Claude Code is not installed on this machine");
        assert_eq!(none_installed(&cfg).data.unwrap()["details"]["harness"], "claude");

        cfg.harnesses.insert("codex".into(), profile(HarnessKind::Acp, None));
        cfg.harnesses.insert("muse-terminal".into(), profile(HarnessKind::Terminal, None));
        let data = not_installed(&cfg, "claude").unwrap().data.unwrap();
        assert_eq!(data["details"]["installed"], json!(["codex"]));
        assert!(not_installed(&cfg, "codex").is_none(), "codex is here");
        assert!(
            not_installed(&cfg, "no-such-agent").is_none(),
            "an unknown name keeps its own error"
        );
        // Gemini CLI is known but not one `acpmux harness install` installs.
        let gemini = not_installed(&cfg, "gemini").unwrap().data.unwrap();
        assert_eq!(gemini["details"]["installable"], false);
        // An unavailable Codex is no alternative.
        cfg.unavailable.insert("codex".into(), "launcher failed".into());
        assert_eq!(
            not_installed(&cfg, "claude").unwrap().data.unwrap()["details"]["installed"],
            json!([])
        );
    }

    #[test]
    fn only_the_known_agents_install() {
        assert_eq!(agent("claude").unwrap().0, "Claude Code");
        assert_eq!(agent("codex").unwrap().0, "Codex");
        let err = agent("gemini").unwrap_err().to_string();
        assert!(err.contains("installs claude, codex"), "{err}");
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

    #[tokio::test]
    async fn an_unknown_agent_runs_nothing() {
        let mut steps = 0;
        assert!(install("aider", |_, _, _| steps += 1).await.is_err());
        assert_eq!(steps, 0);
    }
}
