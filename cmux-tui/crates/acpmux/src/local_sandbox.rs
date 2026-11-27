//! A local chat's Claude Code in the macOS Seatbelt sandbox, on by default
//! (hq RFD "Sandboxing and lockdown for Cloud, AutoCloud and the app"; Leo,
//! 2026-11-25: "what about if someone wants to lock down a vm? lock down
//! their app?").
//!
//! acpmux starts a local chat's Claude Code (`HarnessKind::ClaudeStdio`) as
//! `sandbox-exec -p <sandbox/local-agent.sb> -D CWD=… … claude …`. The profile
//! is looser than a remote chain's (`hub/remote_sandbox.rs`): it keeps today's
//! flows (git, builds, dev servers on loopback, the Keychain login) and stops
//! the prompt-injection path: reading a credential (`~/.ssh`, `~/.aws`, cloud
//! and registry tokens, browser cookies), writing outside the chat's folders
//! and the toolchains' state, and sending anything off the Mac except on ports
//! 443, 80 and 22 (and Claude Code's own API port).
//!
//! The chat's folders are its cwd, every `--add-dir` (Session Info's added
//! folders: `set_directories` restarts the agent, so the profile follows), and
//! the git folder a worktree or a subfolder of a repository commits into.
//!
//! Off when:
//! - `sessions.sandbox` is false in the cmux settings file. A file that cannot be
//!   read keeps it on (fail closed). MDM or the team policy can force it on
//!   (`_acpmux/chat_settings` `sandboxManaged`), never off.
//! - `/usr/bin/sandbox-exec` is missing: the agent runs as before, logged once.
//! - Claude Code's own Bash sandbox is on (its settings' `sandbox.enabled`):
//!   macOS refuses a nested `sandbox_apply`, so every Bash call would fail; the
//!   person's own sandbox stays, logged once.
//! - Not macOS. Linux confines remote chains with bwrap (`linux_sandbox/`); a
//!   local chat there is the machine's own (a Cloud VM is the boundary).
//!
//! Codex is not wrapped yet: in its asking modes (acpmux's narrower policies,
//! `hub/policy_mode.rs`) Codex runs each command in its own Seatbelt sandbox,
//! which cannot start inside this one. Its full-access mode can switch to them
//! live, so the wrap needs the bridge to hand Codex's confinement to this
//! profile first (the RFD's next step).
#![cfg_attr(not(target_os = "macos"), allow(dead_code))]

use serde_json::Value;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};

/// The checked-in Seatbelt profile.
pub(crate) const PROFILE: &str = include_str!("../sandbox/local-agent.sb");

/// The cmux setting (Settings > Agents > Agent Sessions).
pub(crate) const SETTING: &str = "sessions.sandbox";

pub(crate) const SANDBOX_EXEC: &str = "/usr/bin/sandbox-exec";

/// Whether MDM or the team policy forces the sandbox on (`_acpmux/chat_settings`).
static MANAGED_ON: AtomicBool = AtomicBool::new(false);

/// The app's push: `Some(true)` forces it on; anything else forces nothing (only tightens).
pub(crate) fn apply_managed_push(forced: Option<bool>) {
    MANAGED_ON.store(forced == Some(true), Ordering::Relaxed);
}

/// The settings file's answer: on unless it sets `sessions.sandbox` to false. Unreadable: on.
pub(crate) fn file_wants(settings: &crate::user_settings::Settings) -> bool {
    match settings {
        crate::user_settings::Settings::Missing | crate::user_settings::Settings::Unreadable(_) => {
            true
        }
        crate::user_settings::Settings::Parsed(doc) => {
            !matches!(crate::user_settings::value(doc, SETTING), Some(Value::Bool(false)))
        }
    }
}

/// Whether a new local chat's Claude Code runs in the sandbox.
pub(crate) fn enabled() -> bool {
    enabled_by(MANAGED_ON.load(Ordering::Relaxed), file_wants(&crate::user_settings::read()))
}

pub(crate) fn enabled_by(managed_on: bool, file_wants: bool) -> bool {
    managed_on || file_wants
}

/// The folders and ports the profile is given.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Bound {
    pub(crate) cwd: PathBuf,
    pub(crate) home: PathBuf,
    pub(crate) agent_home: PathBuf,
    pub(crate) acpmux_home: PathBuf,
    pub(crate) session_tmp: PathBuf,
    /// The chat's other folders (`--add-dir`) and the git folders its folders commit into.
    pub(crate) folders: Vec<PathBuf>,
    /// Claude Code's own API port when it is not one the profile already opens.
    pub(crate) api_port: Option<u16>,
}

/// A path as Seatbelt matches it: canonical (macOS's `/tmp` is `/private/tmp`), else as given.
fn canonical(path: &Path) -> PathBuf {
    std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
}

/// A literal path as a regex: Seatbelt's regex is POSIX extended.
pub(crate) fn regex_escape(path: &Path) -> String {
    let mut out = String::new();
    for c in path.to_string_lossy().chars() {
        if "\\.^$|?*+()[]{}".contains(c) {
            out.push('\\');
        }
        out.push(c);
    }
    out
}

impl Bound {
    /// `sandbox-exec` arguments up to the command: the profile and its parameters.
    pub(crate) fn sandbox_args(&self) -> Vec<String> {
        let mut profile = PROFILE.to_owned();
        let folders: String =
            (0..self.folders.len()).map(|i| format!("  (subpath (param \"DIR{i}\"))\n")).collect();
        profile = profile.replacen(";; @FOLDERS@\n", &folders, 1);
        if let Some(port) = self.api_port {
            profile.push_str(&format!("(allow network-outbound (remote ip \"*:{port}\"))\n"));
        }
        let mut out = vec!["-p".to_owned(), profile];
        let mut param = |k: String, v: String| {
            out.push("-D".into());
            out.push(format!("{k}={v}"));
        };
        let show = |p: &Path| p.to_string_lossy().into_owned();
        param("CWD".into(), show(&self.cwd));
        param("HOME".into(), show(&self.home));
        param("AGENT_HOME".into(), show(&self.agent_home));
        param("HOME_RE".into(), regex_escape(&self.home));
        param("AGENT_HOME_RE".into(), regex_escape(&self.agent_home));
        param("ACPMUX_HOME".into(), show(&self.acpmux_home));
        param("SESSION_TMP".into(), show(&self.session_tmp));
        for (i, dir) in self.folders.iter().enumerate() {
            param(format!("DIR{i}"), show(dir));
        }
        out
    }
}

/// The `--add-dir` folders of a Claude Code command line.
pub(crate) fn added_dirs(args: &[String]) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut words = args.iter();
    while let Some(word) = words.next() {
        if word == "--" {
            break;
        }
        if word == "--add-dir" {
            // `--add-dir A B …`: every word up to the next flag.
            let rest = words.clone().take_while(|w| !w.starts_with('-'));
            out.extend(rest.map(PathBuf::from));
        } else if let Some(v) = word.strip_prefix("--add-dir=") {
            out.push(PathBuf::from(v));
        }
    }
    out
}

/// The git folders a commit in `folder` writes: the repository's `.git` above it, and for a
/// worktree (a `.git` file) its own git folder and the common one.
pub(crate) fn git_dirs(folder: &Path) -> Vec<PathBuf> {
    let Some(dot_git) = folder.ancestors().map(|d| d.join(".git")).find(|p| p.exists()) else {
        return Vec::new();
    };
    if dot_git.is_dir() {
        return vec![dot_git];
    }
    let Ok(text) = std::fs::read_to_string(&dot_git) else { return Vec::new() };
    let Some(gitdir) = text.lines().find_map(|l| l.strip_prefix("gitdir:")) else {
        return Vec::new();
    };
    let base = dot_git.parent().unwrap_or(Path::new("/"));
    let gitdir = base.join(gitdir.trim());
    let mut out = vec![gitdir.clone()];
    if let Ok(common) = std::fs::read_to_string(gitdir.join("commondir")) {
        out.push(gitdir.join(common.trim()));
    }
    out
}

/// Whether Claude Code's own Bash sandbox is on for this launch. Claude applies the highest
/// precedence setting for this one key: managed settings, the last `--settings` value, project
/// local settings, project settings, then the configured Claude home (or `~/.claude`).
pub(crate) fn claude_sandbox_on(
    args: &[String],
    cwd: &Path,
    agent_home: &Path,
    claude_config_dir: Option<&Path>,
) -> bool {
    let value = |text: &str| {
        serde_json::from_str::<Value>(text)
            .ok()
            .and_then(|v| v.pointer("/sandbox/enabled").and_then(Value::as_bool))
    };
    let file = |path: &Path| std::fs::read_to_string(path).ok().and_then(|text| value(&text));
    let settings_value = |setting: &str| {
        if setting.trim_start().starts_with('{') {
            value(setting)
        } else {
            file(&cwd.join(setting))
        }
    };

    let mut last_settings = None;
    let mut words = args.iter();
    while let Some(word) = words.next() {
        if word == "--settings" {
            last_settings = words.next().map(String::as_str).map(str::to_owned);
        } else if let Some(setting) = word.strip_prefix("--settings=") {
            last_settings = Some(setting.to_owned());
        }
    }

    [
        "/Library/Application Support/ClaudeCode/managed-settings.json",
        "/etc/claude-code/managed-settings.json",
    ]
    .iter()
    .map(Path::new)
    .find_map(file)
    .or_else(|| last_settings.as_deref().and_then(settings_value))
    .or_else(|| file(&cwd.join(".claude/settings.local.json")))
    .or_else(|| file(&cwd.join(".claude/settings.json")))
    .or_else(|| {
        let config_dir =
            claude_config_dir.map(Path::to_path_buf).unwrap_or_else(|| agent_home.join(".claude"));
        file(&config_dir.join("settings.json"))
    })
    .unwrap_or(false)
}

/// The port of an `ANTHROPIC_BASE_URL` that the profile does not already open (443, 80, 22 or
/// any loopback port).
pub(crate) fn extra_api_port(url: &str) -> Option<u16> {
    let rest = url.strip_prefix("http://").or_else(|| url.strip_prefix("https://"))?;
    let authority = rest.split(['/', '?', '#']).next()?;
    let authority = authority.rsplit('@').next()?;
    let (host, port) = match authority.rsplit_once(':') {
        Some((h, p)) if !h.ends_with(']') || authority.starts_with('[') => {
            (h, p.parse::<u16>().ok()?)
        }
        _ => return None,
    };
    let host = host.trim_start_matches('[').trim_end_matches(']');
    let loopback =
        host == "localhost" || host.parse::<std::net::IpAddr>().is_ok_and(|ip| ip.is_loopback());
    (!loopback && ![443, 80, 22].contains(&port)).then_some(port)
}

static MISSING_LOGGED: AtomicBool = AtomicBool::new(false);
static CLAUDE_OWN_LOGGED: AtomicBool = AtomicBool::new(false);

/// `sandbox-exec` and its arguments up to the program for a local Claude Code launch, or `None`
/// when it runs as before (module docs). `env` is the profile's resolved env (its `HOME`,
/// `ANTHROPIC_BASE_URL`).
pub(crate) fn prefix(
    args: &[String],
    cwd: &Path,
    env: &BTreeMap<String, String>,
) -> Option<(&'static str, Vec<String>)> {
    if !cfg!(target_os = "macos") || !enabled() {
        return None;
    }
    let exec = Path::new(SANDBOX_EXEC);
    if !exec.exists() {
        if !MISSING_LOGGED.swap(true, Ordering::Relaxed) {
            tracing::warn!("{SANDBOX_EXEC} is missing: local agents run without the sandbox");
        }
        return None;
    }
    let bound = bound(args, cwd, env)?;
    let claude_config_dir =
        env.get("CLAUDE_CONFIG_DIR").filter(|dir| !dir.is_empty()).map(Path::new);
    if claude_sandbox_on(args, &bound.cwd, &bound.agent_home, claude_config_dir) {
        if !CLAUDE_OWN_LOGGED.swap(true, Ordering::Relaxed) {
            tracing::info!(
                "Claude Code's own sandbox is on: its chats keep it (Seatbelt does not nest)"
            );
        }
        return None;
    }
    Some((SANDBOX_EXEC, bound.sandbox_args()))
}

/// The profile's folders for a launch. `None` when the folder is the home or above it: the
/// profile would allow writes to all of it, so such a chat runs as before.
pub(crate) fn bound(args: &[String], cwd: &Path, env: &BTreeMap<String, String>) -> Option<Bound> {
    let home = canonical(&dirs::home_dir()?);
    let agent_home = env.get("HOME").filter(|h| !h.is_empty()).map(|h| canonical(Path::new(h)));
    let agent_home = agent_home.unwrap_or_else(|| home.clone());
    let cwd = canonical(cwd);
    if home.starts_with(&cwd) || agent_home.starts_with(&cwd) {
        return None;
    }
    let mut folders: Vec<PathBuf> = Vec::new();
    let added: Vec<PathBuf> = added_dirs(args).iter().map(|d| canonical(&cwd.join(d))).collect();
    for dir in std::iter::once(cwd.clone()).chain(added.iter().cloned()) {
        for d in std::iter::once(dir.clone()).chain(git_dirs(&dir)) {
            let d = canonical(&d);
            // An added folder that is the home or above it is left out, not the whole home.
            if d != cwd && !home.starts_with(&d) && !folders.contains(&d) {
                folders.push(d);
            }
        }
    }
    let url = env
        .get("ANTHROPIC_BASE_URL")
        .cloned()
        .or_else(|| std::env::var("ANTHROPIC_BASE_URL").ok())
        .or_else(|| crate::hub::remote_sandbox::user_settings_endpoint(&agent_home));
    Some(Bound {
        cwd,
        home,
        agent_home,
        acpmux_home: canonical(&crate::config::home()),
        session_tmp: canonical(&crate::agent::session_tmp::per_user_base()),
        folders,
        api_port: url.as_deref().and_then(extra_api_port),
    })
}

#[cfg(test)]
#[path = "local_sandbox_tests.rs"]
mod tests;
