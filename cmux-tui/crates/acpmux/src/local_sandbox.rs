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
//!   read keeps it on (fail closed). The managed-preference source (MDM on macOS)
//!   can force it on; `_acpmux/chat_settings` reports that state but is
//!   not trusted as an enforcement input.
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
    let managed = cmux_config::managed::default_reader(|name| std::env::var(name).ok()).read();
    let managed_on = managed.forced.get(SETTING) == Some(&Value::Bool(true));
    enabled_by(managed_on, file_wants(&crate::user_settings::read()))
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
    /// The cmux settings files that decide whether later chats are sandboxed.
    pub(crate) cmux_config: PathBuf,
    pub(crate) cmux_legacy_config: PathBuf,
    pub(crate) cmux_agent_config: PathBuf,
    pub(crate) cmux_agent_legacy_config: PathBuf,
    pub(crate) cmux_config_real: PathBuf,
    pub(crate) gh_config_dir: PathBuf,
    pub(crate) xdg_gh_config_dir: PathBuf,
    /// The chat's other folders (`--add-dir`) and the git folders its folders commit into.
    pub(crate) folders: Vec<PathBuf>,
    /// Settings files and drop-in directories that decide confinement on a later launch.
    pub(crate) policy_files: Vec<PathBuf>,
    /// Claude Code's own API port when it is not one the profile already opens.
    pub(crate) api_port: Option<u16>,
}

/// Resolve existing ancestors too: a credential or policy file may not exist at launch.
fn canonical(path: &Path) -> PathBuf {
    for ancestor in path.ancestors() {
        let Ok(mut resolved) = std::fs::canonicalize(ancestor) else { continue };
        let Ok(tail) = path.strip_prefix(ancestor) else { continue };
        for component in tail.components() {
            match component {
                std::path::Component::ParentDir => {
                    resolved.pop();
                }
                std::path::Component::CurDir => {}
                other => resolved.push(other.as_os_str()),
            }
        }
        return resolved;
    }
    path.to_path_buf()
}

/// Make a settings override absolute before passing it to Seatbelt. An override can name a
/// missing file, so canonicalization alone is insufficient for the policy to protect it.
fn absolute(base: &Path, path: PathBuf) -> PathBuf {
    if path.is_absolute() { path } else { base.join(path) }
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
        for i in 0..self.policy_files.len() {
            profile.push_str(&format!("(deny file-write* (subpath (param \"POLICY_FILE{i}\")))\n"));
        }
        // A protected file must not be replaceable by renaming or symlinking a parent.
        let policy_parents: std::collections::BTreeSet<_> =
            self.policy_files.iter().flat_map(|path| path.ancestors().skip(1)).collect();
        for i in 0..policy_parents.len() {
            profile.push_str(&format!("(deny file-write-unlink file-write-create (literal (param \"POLICY_PARENT{i}\")))\n"));
        }
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
        param("CMUX_CONFIG".into(), show(&self.cmux_config));
        param("CMUX_CONFIG_REAL".into(), show(&self.cmux_config_real));
        param("CMUX_LEGACY_CONFIG".into(), show(&self.cmux_legacy_config));
        param("CMUX_AGENT_CONFIG".into(), show(&self.cmux_agent_config));
        param("CMUX_AGENT_LEGACY_CONFIG".into(), show(&self.cmux_agent_legacy_config));
        param("GH_CONFIG_DIR".into(), show(&self.gh_config_dir));
        param("XDG_GH_CONFIG_DIR".into(), show(&self.xdg_gh_config_dir));
        for (i, path) in self.policy_files.iter().enumerate() {
            param(format!("POLICY_FILE{i}"), show(path));
        }
        for (i, path) in policy_parents.iter().enumerate() {
            param(format!("POLICY_PARENT{i}"), show(path));
        }
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
        let Ok(dot_git) = std::fs::canonicalize(dot_git) else { return Vec::new() };
        return dot_git
            .file_name()
            .is_some_and(|name| name == ".git")
            .then_some(vec![dot_git])
            .unwrap_or_default();
    }
    let Ok(text) = std::fs::read_to_string(&dot_git) else { return Vec::new() };
    let Some(gitdir) = text.lines().find_map(|l| l.strip_prefix("gitdir:")) else {
        return Vec::new();
    };
    let base = dot_git.parent().unwrap_or(Path::new("/"));
    let Ok(gitdir) = std::fs::canonicalize(base.join(gitdir.trim())) else {
        return Vec::new();
    };
    if !gitdir.is_dir() {
        return Vec::new();
    }
    let Some(common_root) = gitdir
        .ancestors()
        .find(|path| path.file_name().is_some_and(|name| name == ".git") && path.is_dir())
    else {
        return Vec::new();
    };
    let Ok(common_root) = std::fs::canonicalize(common_root) else { return Vec::new() };
    if !gitdir.starts_with(&common_root) {
        return Vec::new();
    }
    let mut out = vec![gitdir.clone()];
    if let Ok(common) = std::fs::read_to_string(gitdir.join("commondir")) {
        if let Ok(common) = std::fs::canonicalize(gitdir.join(common.trim()))
            && common.is_dir()
            && common.starts_with(&common_root)
        {
            out.push(common);
        }
    }
    out
}

/// Paths from the child's effective environment; an explicit config directory replaces HOME.
fn claude_files(
    cwd: &Path,
    env: &BTreeMap<String, String>,
) -> crate::agent_tools::project_mcp::Claude {
    // Inspect the config home the child actually uses, not both the daemon's and child's homes.
    let mut config_env = env.clone();
    let config_home = env
        .get("CLAUDE_CONFIG_DIR")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .or_else(|| {
            env.get("HOME")
                .filter(|value| !value.is_empty())
                .map(|home| Path::new(home).join(".claude"))
        })
        .or_else(|| dirs::home_dir().map(|home| home.join(".claude")));
    if let Some(home) = config_home {
        config_env
            .insert("CLAUDE_CONFIG_DIR".into(), absolute(cwd, home).to_string_lossy().into_owned());
    }
    crate::agent_tools::project_mcp::Claude::of(&config_env, cwd)
}

fn source_enabled(args: &[String], source: &str) -> bool {
    let mut setting_sources = None;
    let mut words = args.iter().take_while(|arg| arg.as_str() != "--");
    while let Some(word) = words.next() {
        if word == "--setting-sources" {
            setting_sources = words.next().cloned();
        } else if let Some(sources) = word.strip_prefix("--setting-sources=") {
            setting_sources = Some(sources.to_owned());
        }
    }
    setting_sources
        .as_deref()
        .map_or(true, |sources| sources.split(',').any(|candidate| candidate.trim() == source))
}

/// Settings env overrides process env. Managed providers must agree before granting an
/// additional network port; malformed or conflicting settings grant no extra access.
fn api_endpoint(args: &[String], cwd: &Path, env: &BTreeMap<String, String>) -> Option<String> {
    fn endpoint(value: &Value) -> Result<Option<String>, ()> {
        let object = value.as_object().ok_or(())?;
        let Some(env) = object.get("env") else { return Ok(None) };
        let env = env.as_object().ok_or(())?;
        env.get("ANTHROPIC_BASE_URL")
            .map(|value| value.as_str().map(str::to_owned).ok_or(()))
            .transpose()
    }
    let file = |path: &Path| -> Result<Option<String>, ()> {
        let bytes = match std::fs::read(path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(_) => return Err(()),
        };
        let value: Value = serde_json::from_slice(&bytes)
            .or_else(|_| plist::from_bytes(&bytes))
            .map_err(|_| ())?;
        endpoint(&value)
    };
    let claude = claude_files(cwd, env);
    let mut managed = None;
    for path in &claude.managed {
        if let Some(value) = file(path).ok()? {
            if managed.as_ref().is_some_and(|prior| prior != &value) {
                return None;
            }
            managed = Some(value);
        }
    }
    if managed.is_some() {
        return managed;
    }
    if let Some(flag) = crate::claude_cloud_auth::flag_settings(args, cwd).ok()?
        && let Some(value) = endpoint(&Value::Object(flag)).ok()?
    {
        return Some(value);
    }
    let project = cwd.join(".claude/settings.json");
    let local = cwd.join(".claude/settings.local.json");
    for (source, path) in [("local", &local), ("project", &project)] {
        if source_enabled(args, source)
            && let Some(value) = file(path).ok()?
        {
            return Some(value);
        }
    }
    if source_enabled(args, "user") {
        for path in claude
            .settings
            .iter()
            .filter(|path| !claude.managed.contains(path) && *path != &project && *path != &local)
        {
            if let Some(value) = file(path).ok()? {
                return Some(value);
            }
        }
    }
    env.get("ANTHROPIC_BASE_URL").cloned()
}

/// All decision sources remain immutable, even sources excluded for this launch: a later
/// launch may enable them. Include both the named path and its resolved target.
fn policy_files(args: &[String], cwd: &Path, env: &BTreeMap<String, String>) -> Vec<PathBuf> {
    let claude = claude_files(cwd, env);
    let mut files = claude.settings;
    // Protect future drop-ins as well as the files discovered for this launch. The managed
    // root comes from the same resolver that discovers Claude's managed policy sources.
    if let Some(managed_dir) = claude.managed_mcp.parent() {
        files.push(managed_dir.join("managed-settings.d"));
    }
    let mut words = args.iter().take_while(|arg| arg.as_str() != "--");
    let mut flag = None;
    while let Some(word) = words.next() {
        if word == "--settings" {
            flag = words.next().map(String::as_str).or(flag);
        } else if let Some(value) = word.strip_prefix("--settings=") {
            flag = Some(value);
        }
    }
    if let Some(file) = flag.filter(|value| !value.trim_start().starts_with('{')) {
        files.push(absolute(cwd, PathBuf::from(file)));
    }
    files
        .into_iter()
        .flat_map(|path| [path.clone(), canonical(&path)])
        .collect::<std::collections::BTreeSet<_>>()
        .into_iter()
        .collect()
}

/// Whether Claude Code's own Bash sandbox is on for this launch. Claude applies the highest
/// precedence setting for this key. Managed settings, the last `--settings` value, project-local
/// settings, project settings, then user settings are checked in that order. `--setting-sources`
/// removes user/project/local sources, never managed policy. Conflicting managed providers or
/// any unreadable/invalid source retain the outer sandbox rather than guessing Claude's result.
pub(crate) fn claude_sandbox_on(
    args: &[String],
    cwd: &Path,
    env: &BTreeMap<String, String>,
) -> bool {
    let sandbox_value = |value: &Value| -> Result<Option<bool>, ()> {
        if !value.is_object() {
            return Err(());
        }
        match value.get("sandbox") {
            None => Ok(None),
            Some(sandbox) if sandbox.is_object() => match sandbox.get("enabled") {
                None => Ok(None),
                Some(Value::Bool(enabled)) => Ok(Some(*enabled)),
                Some(_) => Err(()),
            },
            Some(_) => Err(()),
        }
    };
    let from_bytes = |bytes: &[u8]| {
        if let Ok(value) = serde_json::from_slice::<Value>(bytes) {
            return sandbox_value(&value);
        }
        let Ok(value) = plist::Value::from_reader(std::io::Cursor::new(bytes)) else {
            return Err(());
        };
        let dict = value.as_dictionary().ok_or(())?;
        match dict.get("sandbox.enabled").or_else(|| dict.get("sandbox")) {
            None => Ok(None),
            Some(value) => {
                if let Some(value) = value.as_boolean() {
                    return Ok(Some(value));
                }
                let sandbox = value.as_dictionary().ok_or(())?;
                match sandbox.get("enabled") {
                    None => Ok(None),
                    Some(value) => value.as_boolean().map(Some).ok_or(()),
                }
            }
        }
    };
    let file = |path: &Path| match std::fs::read(path) {
        Ok(bytes) => from_bytes(&bytes),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(_) => Err(()),
    };
    let has_settings_flag = args
        .iter()
        .take_while(|arg| arg.as_str() != "--")
        .any(|arg| arg == "--settings" || arg.starts_with("--settings="));

    let source_enabled = |source| source_enabled(args, source);

    let claude = claude_files(cwd, env);
    // Managed policy cannot be removed by --setting-sources. These paths aggregate independent
    // policy providers; on conflicting values or unreadable policy retain the outer boundary.
    let managed_values: Result<Vec<_>, _> = claude.managed.iter().map(|path| file(path)).collect();
    let managed = managed_values.map(|values| {
        if values.contains(&Some(false)) {
            Some(false)
        } else if values.contains(&Some(true)) {
            Some(true)
        } else {
            None
        }
    });
    let flag = if has_settings_flag {
        match crate::claude_cloud_auth::flag_settings(args, cwd) {
            Ok(Some(settings)) => sandbox_value(&Value::Object(settings)),
            Ok(None) => Ok(None),
            Err(_) => Err(()),
        }
    } else {
        Ok(None)
    };
    let project = cwd.join(".claude/settings.json");
    let local = cwd.join(".claude/settings.local.json");
    let mut files = Vec::new();
    if source_enabled("local") {
        files.push(file(&local));
    }
    if source_enabled("project") {
        files.push(file(&project));
    }
    if source_enabled("user") {
        files.push(
            claude
                .settings
                .iter()
                .filter(|path| {
                    !claude.managed.iter().any(|managed| managed == *path)
                        && *path != &project
                        && *path != &local
                })
                .map(|path| file(path))
                .find(|value| !matches!(value, Ok(None)))
                .unwrap_or(Ok(None)),
        );
    }
    choose_sandbox_setting(managed, flag, files)
}

/// Claude applies the managed value over the launch's last `--settings`, then over file sources.
/// An unreadable explicit settings value keeps the outer sandbox on (fail closed).
fn choose_sandbox_setting(
    managed: Result<Option<bool>, ()>,
    flag: Result<Option<bool>, ()>,
    files: impl IntoIterator<Item = Result<Option<bool>, ()>>,
) -> bool {
    // Invalid sources are not evidence that Claude will sandbox the launch. Do not fall through
    // to another source's true value, even if the invalid source contains no recognizable key.
    let values: Result<Vec<_>, _> =
        std::iter::once(managed).chain(std::iter::once(flag)).chain(files).collect();
    values.ok().and_then(|values| values.into_iter().flatten().next()).unwrap_or(false)
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
static BOUND_SKIPPED_LOGGED: AtomicBool = AtomicBool::new(false);

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
    let Some(bound) = bound(args, cwd, env) else {
        if !BOUND_SKIPPED_LOGGED.swap(true, Ordering::Relaxed) {
            tracing::warn!(
                "local agent sandbox skipped: home/config paths unavailable or chat folder contains a home directory"
            );
        }
        return None;
    };
    if claude_sandbox_on(args, &bound.cwd, env) {
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
    let cwd = canonical(cwd);
    let agent_home = env
        .get("HOME")
        .filter(|h| !h.is_empty())
        .map(|h| canonical(&absolute(&cwd, PathBuf::from(h))));
    let agent_home = agent_home.unwrap_or_else(|| home.clone());
    if home.starts_with(&cwd) || agent_home.starts_with(&cwd) {
        return None;
    }
    let mut folders: Vec<PathBuf> = Vec::new();
    let added: Vec<PathBuf> = added_dirs(args).iter().map(|d| canonical(&cwd.join(d))).collect();
    for dir in std::iter::once(cwd.clone()).chain(added.iter().cloned()) {
        for d in std::iter::once(dir.clone()).chain(git_dirs(&dir)) {
            let d = canonical(&d);
            // An added folder that is the home or above it is left out, not the whole home.
            if d != cwd
                && !home.starts_with(&d)
                && !agent_home.starts_with(&d)
                && !folders.contains(&d)
            {
                folders.push(d);
            }
        }
    }
    let url = api_endpoint(args, &cwd, env);
    let config_dir = Path::new(".config");
    let cmux_legacy_config = home
        .join(config_dir)
        .join(cmux_config::location::LEGACY_DIR)
        .join(cmux_config::location::NEXT_FILE_NAME);
    let cmux_agent_config = agent_home
        .join(config_dir)
        .join(cmux_config::NEXT_DIR)
        .join(cmux_config::location::NEXT_FILE_NAME);
    let cmux_agent_legacy_config = agent_home
        .join(config_dir)
        .join(cmux_config::location::LEGACY_DIR)
        .join(cmux_config::location::NEXT_FILE_NAME);
    // The daemon reads this override relative to its own cwd, unlike child GH/Claude paths.
    let cmux_config = std::path::absolute(crate::user_settings::resolved_path()).ok()?;
    let cmux_config_real = canonical(&cmux_config);
    let gh_config_dir = env
        .get("GH_CONFIG_DIR")
        .filter(|p| !p.is_empty())
        .map(|p| canonical(&absolute(&cwd, PathBuf::from(p))))
        .unwrap_or_else(|| agent_home.join(".config/gh"));
    let xdg_gh_config_dir = env
        .get("XDG_CONFIG_HOME")
        .filter(|p| !p.is_empty())
        .map(|p| canonical(&absolute(&cwd, PathBuf::from(p).join("gh"))))
        .unwrap_or_else(|| agent_home.join(".config/gh"));
    let mut policy_files = policy_files(args, &cwd, env);
    policy_files.extend([
        cmux_config.clone(),
        cmux_config_real.clone(),
        cmux_legacy_config.clone(),
        cmux_agent_config.clone(),
        cmux_agent_legacy_config.clone(),
    ]);
    // Defaults can cross symlinks too (for example an agent home's .config).
    // Keep both the spelling the reader uses and every resolved policy target.
    policy_files.extend(policy_files.clone().iter().map(|path| canonical(path)));
    policy_files.sort();
    policy_files.dedup();
    Some(Bound {
        cwd,
        home,
        agent_home,
        acpmux_home: canonical(&crate::config::home()),
        session_tmp: canonical(&crate::agent::session_tmp::per_user_base()),
        cmux_config,
        cmux_legacy_config,
        cmux_agent_config,
        cmux_agent_legacy_config,
        cmux_config_real,
        gh_config_dir,
        xdg_gh_config_dir,
        folders,
        policy_files,
        api_port: url.as_deref().and_then(extra_api_port),
    })
}

#[cfg(test)]
#[path = "local_sandbox_tests.rs"]
mod tests;
