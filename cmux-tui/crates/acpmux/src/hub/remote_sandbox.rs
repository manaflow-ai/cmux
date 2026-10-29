//! Part of `Hub`; see `hub/mod.rs`. A remote chain's Claude Code runs in
//! the macOS Seatbelt sandbox, or on Linux in bwrap with seccomp, the
//! user-notify supervisor and the proxy (decisions.md REMOTE-SANDBOX, D-R).
//! Linux parses the same `sandbox/remote-chain.sb` policy and requires both
//! the bwrap probe and a successful canary at each spawn.
//!
//! A remote-origin session (created over the WebSocket listener: a remote
//! device or a peer) that runs Claude Code on macOS spawns it as
//! `sandbox-exec -p <profile> -D CWD=… -D TMPDIR=… -D HOME=… claude …`. The
//! profile is `sandbox/remote-chain.sb`, checked into this crate: writes only
//! in the session folder, the temporary folders and Claude Code's own state,
//! never in a persistence path (git hooks and config, `.claude/`,
//! `.mcp.json`, `.envrc`, `.vscode/`), no loopback network and no Unix
//! socket except the system resolver. Claude's Bash tool and every other
//! child inherit it and cannot leave it.
//!
//! It is the only sandbox. Claude Code's own Bash sandbox cannot start
//! inside it (macOS refuses a nested `sandbox_apply` under any profile that
//! denies something), so the inline `--settings` turn it off (a user setting
//! that enables it would make every command fail) and set
//! `autoAllowBashIfSandboxed: false`, disable bypass mode, and add an ask
//! rule for every tool that acts, which wins over the user's own allow rules.
//!
//! The spawn canary: before every such spawn, the same `sandbox-exec`, the
//! same profile and the same parameters (the keeper on Linux) run a shell that tries to write a
//! file outside the allowed folders and to connect to a loopback port acpmux
//! listens on, and that must be able to write in the temporary folder. A
//! write that lands, a connection that arrives, or a canary that does not
//! report refuses the spawn: no remote chain runs without the sandbox.
//!
//! Claude Code's own API route stays open when it is on this machine
//! (`ANTHROPIC_BASE_URL` on a loopback host): that one port, nothing else.
//! The route is the one Claude really uses (`Endpoint`): the profile's own
//! (its env, or its route: the `cmux` harness reaches the cmux model router
//! through the local relay), else the user's Claude settings (`env` in
//! `~/.claude/settings.json`, which Claude applies over its process env),
//! else the login environment's. The inline `--settings` pins it (a project
//! file cannot move it), and a profile's own route skips the user settings
//! source (`--setting-sources project,local`), whose env would otherwise
//! replace the route's endpoint and key. `sr claude proxy` (`claude-sr`)
//! starts its own proxy, which the sandbox never allows: a remote chain runs
//! Claude Code straight to the subrouter server that proxy would use, as
//! acpmux does when that launcher cannot run (`config/launchers.rs`).
//!
//! Refused as well, before any process starts: a platform without either
//! supported sandbox, a session folder that is the home directory or
//! above it (the profile would allow writes there), and a profile argv that
//! already passes `--settings`, `--dangerously-skip-permissions` or
//! `--allow-dangerously-skip-permissions`.

use super::*;
use cmux_json::JsonSet as _;
#[cfg(target_os = "linux")]
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
#[cfg(target_os = "linux")]
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};

/// The checked-in Seatbelt profile.
pub(crate) const PROFILE: &str = include_str!("../../sandbox/remote-chain.sb");
const LINUX_PROFILE_NOTE: &str = ";; Linux enforces this same parsed policy through bwrap, seccomp, the\n;; user-notify supervisor and the proxy, with a canary at every spawn.\n";

/// The identity of what a remote chain runs under: the profile and the env
/// policy (bump `ENV_POLICY` when the child env rules change).
pub(super) fn profile_id() -> String {
    platform_profile_id(cfg!(target_os = "linux"))
}

fn platform_profile_id(linux: bool) -> String {
    const ENV_POLICY: &str = "env-v5: explicit cleared host projection, fixed remote allowlist, nested-parent credential and endpoint excluded, credential by explicit profile/login env, CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1, endpoint pinned by --settings env, user settings skipped for a profile's own endpoint";
    // Preserve the established macOS adoption identity across this Linux-only note.
    let profile = if linux { PROFILE.to_owned() } else { PROFILE.replace(LINUX_PROFILE_NOTE, "") };
    let identity = format!("{profile}\n{ENV_POLICY}");
    #[cfg(target_os = "linux")]
    let identity = if linux {
        // Hash the implemented policy and protocol, including the bwrap argv shape.
        let sources = linux_identity_sources();
        let source_text = sources.iter().map(|(_, source)| *source).collect::<Vec<_>>().join("\n");
        format!("{identity}\nlinux-keeper-v1; loader-env-v2\n{source_text}")
    } else {
        identity
    };
    let _ = linux;
    crate::sha256::sha256_hex(identity.as_bytes())
}

#[cfg(target_os = "linux")]
fn linux_identity_sources() -> Vec<(&'static str, &'static str)> {
    vec![
        ("bwrap.rs", include_str!("../linux_sandbox/bwrap.rs")),
        ("bwrap/aliases.rs", include_str!("../linux_sandbox/bwrap/aliases.rs")),
        ("bwrap/home.rs", include_str!("../linux_sandbox/bwrap/home.rs")),
        ("keeper.rs", include_str!("../linux_sandbox/keeper.rs")),
        ("init.rs", include_str!("../linux_sandbox/init.rs")),
        ("seccomp.rs", include_str!("../linux_sandbox/seccomp.rs")),
        ("proxy.rs", include_str!("../linux_sandbox/proxy.rs")),
        ("supervisor.rs", include_str!("../linux_sandbox/supervisor.rs")),
        ("supervisor/mutations.rs", include_str!("../linux_sandbox/supervisor/mutations.rs")),
        ("supervisor/locking.rs", include_str!("../linux_sandbox/supervisor/locking.rs")),
        ("lookup.rs", include_str!("../linux_sandbox/lookup.rs")),
        ("rules.rs", include_str!("../linux_sandbox/rules.rs")),
    ]
}

/// glibc sysdeps/generic/unsecvars.h (including legacy MALLOC_CHECK_) plus
/// every LD_* control: none may reach an unsandboxed Linux exec.
#[cfg(target_os = "linux")]
pub(crate) fn loader_env_key(key: &str) -> bool {
    key.starts_with("LD_")
        || matches!(
            key,
            "GCONV_PATH"
                | "GETCONF_DIR"
                | "GLIBC_TUNABLES"
                | "HOSTALIASES"
                | "LOCALDOMAIN"
                | "LOCPATH"
                | "MALLOC_ARENA_MAX"
                | "MALLOC_ARENA_TEST"
                | "MALLOC_CHECK_"
                | "MALLOC_TCACHE_COUNT"
                | "MALLOC_TCACHE_MAX"
                | "MALLOC_TCACHE_UNSORTED_LIMIT"
                | "MALLOC_PERTURB_"
                | "MALLOC_TOP_PAD_"
                | "MALLOC_TRACE"
                | "MALLOC_MMAP_MAX_"
                | "MALLOC_MMAP_THRESHOLD_"
                | "MALLOC_TRIM_THRESHOLD_"
                | "NIS_PATH"
                | "NLSPATH"
                | "RESOLV_HOST_CONF"
                | "RES_OPTIONS"
                | "TMPDIR"
                | "TZDIR"
        )
}

/// Finite scan of inherited and explicitly merged keys; never mutates the daemon env.
#[cfg(target_os = "linux")]
pub(crate) fn scrub_loader_env(command: &mut tokio::process::Command) {
    let keys: Vec<_> = std::env::vars_os()
        .map(|(k, _)| k)
        .chain(command.as_std().get_envs().map(|(k, _)| k.to_owned()))
        .filter(|k| crate::linux_sandbox::keeper::loader_env_key(&k.to_string_lossy()))
        .collect();
    for key in keys {
        command.env_remove(key);
    }
}

/// The system `sandbox-exec`.
pub(super) const SANDBOX_EXEC: &str = "/usr/bin/sandbox-exec";

/// A remote chain's inline `--settings`: Claude's own Bash sandbox off (it
/// cannot nest in the profile), every acting tool asks, and the API route
/// the sandbox opens (`endpoint`) is the one Claude uses: flag settings
/// come after the user, project and local ones, so none of them moves it.
pub(super) fn claude_settings(endpoint: Option<&str>) -> String {
    let mut v = json!({
        "sandbox": {"enabled": false, "autoAllowBashIfSandboxed": false},
        // Ask rules come before allow rules in every settings source, so the
        // user's own allow rules never skip the question in a remote chain.
        "permissions": {"disableBypassPermissionsMode": "disable", "ask": ASK_TOOLS},
    });
    if let Some(url) = endpoint {
        v.set("env", json!({"ANTHROPIC_BASE_URL": url}));
    }
    v.to_string()
}

/// Where a remote chain's Claude Code reaches its API.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Endpoint {
    pub(super) url: String,
    /// The profile names it (its env or its route): the user settings
    /// source is skipped, so its env neither moves the route nor replaces
    /// the route's credential.
    pub(super) own: bool,
}

/// The route Claude Code uses, in its own order: the profile's (or its
/// route's) `ANTHROPIC_BASE_URL`, which acpmux makes win; else the user's
/// Claude settings `env` (applied over the process env); else the login
/// environment's.
pub(super) fn endpoint(
    profile: Option<&str>,
    user_settings: Option<&str>,
    login: Option<&str>,
) -> Option<Endpoint> {
    let set = |v: Option<&str>| v.map(str::trim).filter(|v| !v.is_empty()).map(str::to_owned);
    if let Some(url) = set(profile) {
        return Some(Endpoint { url, own: true });
    }
    set(user_settings).or_else(|| set(login)).map(|url| Endpoint { url, own: false })
}

/// `env.ANTHROPIC_BASE_URL` of the user's Claude settings file
/// (`<home>/.claude/settings.json`; a remote chain never runs with another
/// `CLAUDE_CONFIG_DIR`, `REFUSED_ENV`).
pub(super) fn user_settings_endpoint(home: &Path) -> Option<String> {
    let text = std::fs::read_to_string(home.join(".claude").join("settings.json")).ok()?;
    let v: Value = serde_json::from_str(&text).ok()?;
    v.pointer("/env/ANTHROPIC_BASE_URL").and_then(Value::as_str).map(str::to_owned)
}

/// `sr claude proxy` for a remote chain: Claude Code itself (`claude`, the
/// first word of acpmux's own Claude profile) on the subrouter server
/// `route`, as `config/launchers.rs` routes it when the launcher cannot run.
/// The proxy `sr` would start needs a loopback listener, which the sandbox
/// refuses. `args` are the plan's, after `claude proxy`; a profile with any
/// other `sr` word is refused.
pub(super) fn subrouter_plan(
    profile: &HarnessProfile,
    args: Vec<String>,
    claude: Option<String>,
    route: Option<String>,
) -> Result<(String, Vec<String>, HarnessProfile), String> {
    if profile.argv.len() != 3 {
        return Err("a remote chain runs `sr claude proxy` only without other sr options".into());
    }
    let route = route.ok_or(
        "`sr claude proxy` starts its own proxy, which a remote chain may not, and no subrouter server is configured (SUBROUTER_URL or sr's default server)",
    )?;
    let claude = claude.ok_or(
        "`sr claude proxy` needs acpmux's own Claude Code profile (`claude`) for a remote chain",
    )?;
    let args = args.into_iter().skip(2).collect();
    let mut profile = profile.clone();
    profile.argv = vec![claude.clone()];
    profile.env.insert("ANTHROPIC_BASE_URL".into(), route);
    // The server picks the pooled account and ignores the client token.
    profile.env.insert("ANTHROPIC_AUTH_TOKEN".into(), "subrouter".into());
    profile.env.insert("ANTHROPIC_CUSTOM_HEADERS".into(), "X-Subrouter-Agent: claude".into());
    Ok((claude, args, profile))
}

/// Claude Code tools that act (run, write, fetch, delegate): in a remote
/// chain each use asks, whatever allow rules the user's settings hold.
const ASK_TOOLS: &[&str] = &[
    "Bash",
    "BashOutput",
    "KillShell",
    "Edit",
    "MultiEdit",
    "Write",
    "NotebookEdit",
    "WebFetch",
    "WebSearch",
    "Task",
    "Agent",
    "Skill",
    "SlashCommand",
];

/// Env names that give Claude Code its credential without the keychain.
const CREDENTIAL_ENV: &[&str] =
    &["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"];

/// The cmux setting that lets a remote chain's Claude Code use this Mac's
/// Claude login from the keychain. Default off: a remote party never causes
/// a keychain read unless the person turned it on.
pub(crate) const KEYCHAIN_LOGIN_SETTING: &str = "agents.remoteChains.claudeKeychainLogin";

/// Whether the settings file holds `true` for `KEYCHAIN_LOGIN_SETTING`, read
/// now. No file, no key, any other value or a file that cannot be read: off.
fn keychain_login_allowed() -> bool {
    let crate::user_settings::Settings::Parsed(doc) = crate::user_settings::read() else {
        return false;
    };
    crate::user_settings::value(&doc, KEYCHAIN_LOGIN_SETTING) == Some(Value::Bool(true))
}

/// The credential a remote chain's Claude Code gets by env, when it has
/// none there yet (profile or login env): the OAuth access token from the
/// keychain item Claude Code keeps ("Claude Code-credentials"), read by
/// acpmux outside the sandbox, only while the cmux setting
/// `KEYCHAIN_LOGIN_SETTING` is on. None: it already has one, the setting is
/// off, or none is found (Claude then reports that it is not logged in).
///
/// The read is bounded (a keychain dialog never holds the spawn), and a
/// token that expires within 10 minutes is refused with the fix: the
/// sandboxed Claude cannot refresh it.
async fn claude_credential(
    profile: &HarnessProfile,
) -> Result<Option<(&'static str, String)>, String> {
    if CREDENTIAL_ENV.iter().any(|k| profile.env.contains_key(*k)) {
        return Ok(None);
    }
    for &key in CREDENTIAL_ENV {
        if let Some(value) = remote_login_value(key) {
            return Ok(Some((key, value)));
        }
    }
    if !cfg!(target_os = "macos") || !keychain_login_allowed() {
        #[cfg(target_os = "linux")]
        if keychain_login_allowed()
            && let Some(token) =
                linux_credential_file(&dirs::home_dir().ok_or("no home directory")?)?
        {
            return Ok(Some(("CLAUDE_CODE_OAUTH_TOKEN", token)));
        }
        return Ok(None);
    }
    let read = tokio::process::Command::new("/usr/bin/security")
        .args(["find-generic-password", "-s", "Claude Code-credentials", "-w"])
        .stdin(std::process::Stdio::null())
        .kill_on_drop(true)
        .output();
    let Ok(Ok(out)) = tokio::time::timeout(std::time::Duration::from_secs(5), read).await else {
        return Ok(None);
    };
    if !out.status.success() {
        return Ok(None);
    }
    let Ok(item) = serde_json::from_slice::<Value>(&out.stdout) else { return Ok(None) };
    let Some(token) = item.pointer("/claudeAiOauth/accessToken").and_then(Value::as_str) else {
        return Ok(None);
    };
    let expires = item.pointer("/claudeAiOauth/expiresAt").and_then(Value::as_u64);
    if expires.is_some_and(|ms| ms < now_ms() + 10 * 60 * 1000) {
        return Err("Claude's login on this Mac expires within 10 minutes (or has expired), and a remote chain cannot refresh it; open Claude Code on the Mac to refresh it, or put a long-lived token (`claude setup-token`) in the harness profile env".into());
    }
    Ok((!token.is_empty()).then(|| ("CLAUDE_CODE_OAUTH_TOKEN", token.to_owned())))
}

/// A daemon started inside Claude/Chief carries that parent turn's token in
/// its process environment. A remote child may use the person's imported
/// login credential, never the parent agent's turn-scoped credential.
fn remote_login_value(key: &str) -> Option<String> {
    select_remote_login_credential(
        std::env::var_os("CLAUDECODE").is_some(),
        std::env::var(key).ok(),
        crate::login_env::var(key),
    )
}

fn select_remote_login_credential(
    nested: bool,
    process: Option<String>,
    login: Option<String>,
) -> Option<String> {
    let nonempty = |value: Option<String>| value.filter(|value| !value.is_empty());
    if nested { nonempty(login) } else { nonempty(process).or_else(|| nonempty(login)) }
}

/// Claude Code flags a profile's own argv may not carry for a remote chain:
/// its settings, MCP servers, tools, folders and permission mode are
/// acpmux's own, and nothing may skip the permission prompt.
const REFUSED_ARGS: &[&str] = &[
    "--settings",
    "--setting-sources",
    "--dangerously-skip-permissions",
    "--allow-dangerously-skip-permissions",
    "--permission-mode",
    "--mcp-config",
    "--strict-mcp-config",
    "--plugin-dir",
    "--agents",
    "--allowed-tools",
    "--allowedTools",
    "--disallowed-tools",
    "--disallowedTools",
    "--tools",
    "--add-dir",
    "--continue",
    "-c",
    "--resume",
    "-r",
    "--session-id",
    "--fork-session",
    "--system-prompt",
    "--system-prompt-file",
    "--append-system-prompt",
];

/// Profile env a remote chain never spawns with: another Claude config
/// folder, or code loaded into the Claude process.
const REFUSED_ENV: &[&str] =
    &["CLAUDE_CONFIG_DIR", "NODE_OPTIONS", "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH"];

/// The folders the profile is given, each canonical.
#[derive(Debug, Clone)]
pub(super) struct Bound {
    pub(super) cwd: PathBuf,
    /// This spawn's own temporary folder (also `TMPDIR` in its env).
    pub(super) tmp: PathBuf,
    pub(super) home: PathBuf,
    /// Claude Code's scratch folder for this session folder
    /// (`/private/tmp/claude-<uid>/<name>`, made before the spawn) and its
    /// transcript folder (`~/.claude/projects/<name>`).
    pub(super) claude_tmp_project: PathBuf,
    pub(super) claude_project: PathBuf,
    /// Claude Code's own API route (`Endpoint`).
    pub(super) endpoint: Option<Endpoint>,
    /// Its port, and whether its host is a loopback one.
    pub(super) api_port: Option<(u16, bool)>,
}

/// The port of an `ANTHROPIC_BASE_URL`, and whether its host is loopback.
pub(super) fn api_port(url: &str) -> Option<(u16, bool)> {
    let rest = url.strip_prefix("http://").or_else(|| url.strip_prefix("https://"))?;
    let authority = rest.split(['/', '?', '#']).next()?;
    let authority = authority.rsplit_once('@').map_or(authority, |(_, a)| a);
    let (host, port) = match authority.strip_prefix('[') {
        Some(v6) => {
            let (host, tail) = v6.split_once(']')?;
            (host, tail.strip_prefix(':'))
        }
        None => match authority.rsplit_once(':') {
            Some((h, p)) => (h, Some(p)),
            None => (authority, None),
        },
    };
    if host.is_empty() {
        return None;
    }
    let port = match port {
        Some(p) => p.parse().ok().filter(|p| *p != 0)?,
        None if url.starts_with("https://") => 443,
        None => 80,
    };
    Some((port, matches!(host, "127.0.0.1" | "::1" | "localhost")))
}

/// Claude Code's name for a session folder under its scratch root: every
/// character that is not an ASCII letter or digit becomes `-`.
fn claude_project_name(cwd: &Path) -> String {
    cwd.to_string_lossy().chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '-' }).collect()
}

/// Why a remote chain may not run in `cwd`, or None. The whole folder is
/// writable to it, so it must be a project folder: below the home directory
/// (not in `~/Library`, `~/Applications`, `~/bin`, `~/go`, a top-level dot
/// folder such as `~/.ssh`, or a folder on `PATH`), or in the temporary
/// folder (not another remote chain's own temporary folder).
fn refused_folder(cwd: &Path, home: &Path, tmp: &Path, path_dirs: &[PathBuf]) -> Option<String> {
    let shown = cwd.display();
    if path_dirs.iter().any(|d| cwd.starts_with(d) || d.starts_with(cwd)) {
        return Some(format!("{shown} is or holds a folder on PATH"));
    }
    if let Ok(rest) = cwd.strip_prefix(home) {
        let first = rest.components().next().map(|c| c.as_os_str().to_string_lossy().into_owned());
        return match first {
            None => Some(format!("{shown} is the home directory")),
            Some(f)
                if matches!(f.as_str(), "Library" | "Applications" | "bin" | "go")
                    || f.starts_with('.') =>
            {
                Some(format!("{shown} holds settings or programs, not a project"))
            }
            Some(_) => None,
        };
    }
    if let Ok(rest) = cwd.strip_prefix(tmp) {
        let first = rest.components().next().map(|c| c.as_os_str().to_string_lossy().into_owned());
        return match first {
            None => Some(format!("{shown} is the temporary folder itself")),
            Some(f) if f.starts_with("acpmux-remote-") => {
                Some(format!("{shown} is a remote chain's own temporary folder"))
            }
            Some(_) => None,
        };
    }
    Some(format!("{shown} is outside the home directory"))
}

/// Make `dir` (mode 0700) or accept it only as a real folder (no symlink)
/// that `uid` owns.
#[cfg(unix)]
fn own_dir(dir: &Path, uid: u32) -> Result<(), String> {
    use std::os::unix::fs::{DirBuilderExt, MetadataExt};
    match std::fs::symlink_metadata(dir) {
        Ok(m) if m.is_dir() && m.uid() == uid => Ok(()),
        Ok(_) => Err(format!("{} is not a folder this user owns", dir.display())),
        Err(_) => std::fs::DirBuilder::new()
            .mode(0o700)
            .create(dir)
            .map_err(|e| format!("{}: {e}", dir.display())),
    }
}

#[cfg(target_os = "linux")]
mod accounts;

/// Ok when no one but `uid` can write `path` or any folder above it up to
/// `boundary` (a sticky `boundary` such as `/tmp` excepted when
/// `sticky_boundary`). Group write counts only on `uid`'s own folder whose
/// group is `uid`'s user-private group (Ubuntu's default umask 002).
#[cfg(target_os = "linux")]
fn linux_secure_path(
    path: &Path,
    boundary: &Path,
    uid: u32,
    sticky_boundary: bool,
) -> Result<(), String> {
    linux_secure_path_with(path, boundary, uid, sticky_boundary, &accounts::System)
}

#[cfg(target_os = "linux")]
fn linux_secure_path_with(
    path: &Path,
    boundary: &Path,
    uid: u32,
    sticky_boundary: bool,
    accounts: &dyn accounts::Accounts,
) -> Result<(), String> {
    let mut reached = false;
    for ancestor in path.ancestors() {
        let metadata = std::fs::symlink_metadata(ancestor)
            .map_err(|e| format!("{}: {e}", ancestor.display()))?;
        let sticky_exception =
            sticky_boundary && ancestor == boundary && metadata.mode() & 0o1000 != 0;
        if metadata.mode() & 0o022 != 0 && !sticky_exception {
            if metadata.uid() != uid {
                return Err(format!("{} is writable by another user", ancestor.display()));
            }
            if metadata.mode() & 0o002 != 0 {
                return Err(format!("{} is world-writable", ancestor.display()));
            }
            accounts::private_group(uid, metadata.gid(), accounts)
                .map_err(|why| format!("{} is group-writable and {why}", ancestor.display()))?;
            // With an ACL the group bits are its mask, which can let named
            // users or groups write.
            accounts::no_extended_acl(ancestor)
                .map_err(|why| format!("{} is group-writable and {why}", ancestor.display()))?;
        }
        if ancestor == boundary {
            reached = true;
            break;
        }
    }
    reached.then_some(()).ok_or_else(|| format!("{} is outside its trusted root", path.display()))
}

impl Bound {
    /// The bound for a session folder, its own temporary folder created
    /// (named for `session_id`); refused off macOS/Linux and for a folder that is
    /// not a project folder (`refused_folder`).
    #[cfg(unix)]
    pub(super) fn for_session(
        cwd: &Path,
        session_id: &str,
        endpoint: Option<Endpoint>,
    ) -> Result<Self, String> {
        let linux = cfg!(target_os = "linux");
        if !cfg!(target_os = "macos") && !linux {
            return Err(
                "a remote chain runs Claude Code only inside the macOS Seatbelt sandbox, and this platform has none".into(),
            );
        }
        let canon =
            |p: &Path| std::fs::canonicalize(p).map_err(|e| format!("{}: {e}", p.display()));
        let home = canon(&dirs::home_dir().ok_or("no home directory")?)?;
        let shared_tmp = canon(&std::env::temp_dir())?;
        #[cfg(target_os = "linux")]
        if linux {
            crate::linux_sandbox::bwrap::probe(Path::new("/usr/bin/bwrap"))
                .map_err(|e| format!("bwrap unavailable: {e}"))?;
        }
        let cwd = canon(cwd)?;
        let path_dirs: Vec<PathBuf> = crate::chats::login_var("PATH")
            .unwrap_or_default()
            .split(':')
            .filter(|d| d.starts_with('/'))
            // A folder that does not exist yet counts by its text.
            .map(|d| std::fs::canonicalize(d).unwrap_or_else(|_| PathBuf::from(d)))
            .collect();
        if let Some(why) = refused_folder(&cwd, &home, &shared_tmp, &path_dirs) {
            return Err(format!("a remote chain does not run here: {why}"));
        }
        let safe: String =
            session_id.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '-').collect();
        if safe.is_empty() {
            return Err("a remote chain needs a session id".into());
        }
        let tmp = shared_tmp.join(format!("acpmux-remote-{safe}"));
        {
            use std::os::unix::fs::DirBuilderExt;
            let mut b = std::fs::DirBuilder::new();
            b.recursive(true).mode(0o700);
            b.create(&tmp).map_err(|e| format!("{}: {e}", tmp.display()))?;
        }
        let tmp = canon(&tmp)?;
        // SAFETY: getuid has no preconditions and cannot fail.
        let uid = unsafe { libc::getuid() };
        let name = claude_project_name(&cwd);
        // Made here, so the profile never lets the sandbox make (or rename)
        // the shared scratch root.
        let root = if linux {
            PathBuf::from(format!("/tmp/claude-{uid}"))
        } else {
            PathBuf::from(format!("/private/tmp/claude-{uid}"))
        };
        let claude_tmp_project = root.join(&name);
        own_dir(&root, uid)?;
        own_dir(&claude_tmp_project, uid)?;
        let claude_project = home.join(".claude/projects").join(&name);
        #[cfg(target_os = "linux")]
        if linux {
            let projects = home.join(".claude/projects");
            own_dir(&home.join(".claude"), uid)?;
            own_dir(&projects, uid)?;
            own_dir(&claude_project, uid)?;
            own_dir(&claude_project.join("memory"), uid)?;
            let cwd_boundary = if cwd.starts_with(&home) { &home } else { &shared_tmp };
            linux_secure_path(&cwd, cwd_boundary, uid, cwd_boundary == &shared_tmp)?;
            linux_secure_path(&tmp, &shared_tmp, uid, true)?;
            linux_secure_path(&claude_tmp_project, &shared_tmp, uid, true)?;
            linux_secure_path(&claude_project, &home, uid, false)?;
        }
        Ok(Bound {
            cwd,
            tmp,
            home,
            claude_tmp_project,
            claude_project,
            api_port: endpoint.as_ref().and_then(|e| api_port(&e.url)),
            endpoint,
        })
    }
    /// Platforms without either supported sandbox refuse remote chains.
    #[cfg(not(unix))]
    pub(super) fn for_session(
        _cwd: &Path,
        _session_id: &str,
        _endpoint: Option<Endpoint>,
    ) -> Result<Self, String> {
        Err("a remote chain runs Claude Code only inside the macOS Seatbelt sandbox, and this platform has none".into())
    }

    /// `sandbox-exec` arguments up to the command: the profile and its
    /// parameters.
    pub(super) fn sandbox_args(&self) -> Vec<String> {
        // Claude's own API port: open for other hosts before the loopback
        // deny (so loopback stays shut on it), or on loopback after it when
        // the route is a loopback one.
        let mut profile = PROFILE.to_owned();
        match self.api_port {
            Some((port, false)) => {
                profile = profile.replacen(
                    ";; @API_PORT@",
                    &format!("(allow network-outbound (remote ip \"*:{port}\"))\n;; @API_PORT@"),
                    1,
                );
            }
            Some((port, true)) => profile.push_str(&format!(
                "\n;; Claude Code's own API route on this machine.\n(allow network-outbound (remote ip \"localhost:{port}\"))\n"
            )),
            None => {}
        }
        let mut out = vec!["-p".to_owned(), profile];
        for (k, v) in [
            ("CWD", &self.cwd),
            ("TMPDIR", &self.tmp),
            ("HOME", &self.home),
            ("CLAUDE_TMP_PROJECT", &self.claude_tmp_project),
            ("CLAUDE_PROJECT", &self.claude_project),
        ] {
            out.push("-D".into());
            out.push(format!("{k}={}", v.display()));
        }
        out
    }
}

#[cfg(target_os = "linux")]
fn linux_credential_file(home: &Path) -> Result<Option<String>, String> {
    use std::io::Read;
    let path = home.join(".claude/.credentials.json");
    let file = match std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(&path)
    {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(format!("cannot open {}: {error}", path.display())),
    };
    let metadata = file.metadata().map_err(|e| format!("cannot stat {}: {e}", path.display()))?;
    if !metadata.is_file() {
        return Err(format!("{} is not a regular file", path.display()));
    }
    if metadata.len() > 1024 * 1024 {
        return Err(format!("{} exceeds the 1 MiB credential limit", path.display()));
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.take(1024 * 1024 + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| format!("cannot read {}: {e}", path.display()))?;
    if bytes.len() > 1024 * 1024 {
        return Err(format!("{} exceeds the 1 MiB credential limit", path.display()));
    }
    let value: Value =
        serde_json::from_slice(&bytes).map_err(|e| format!("invalid Claude credentials: {e}"))?;
    let token = value
        .pointer("/claudeAiOauth/accessToken")
        .and_then(Value::as_str)
        .filter(|v| !v.is_empty());
    let Some(token) = token else { return Ok(None) };
    if value
        .pointer("/claudeAiOauth/expiresAt")
        .and_then(Value::as_u64)
        .is_some_and(|ms| ms < now_ms() + 10 * 60 * 1000)
    {
        return Err("Claude's Linux login expires within 10 minutes (or has expired), and a remote chain cannot refresh it; run `claude setup-token` or refresh Claude Code".into());
    }
    Ok(Some(token.to_owned()))
}

/// A remote chain's Claude command line at the VM boundary
/// (`vm_boundary.rs`): everything the sandboxed one gets except the platform
/// sandbox. Its own settings (every acting tool asks, the API route pinned),
/// no MCP servers, the refused argv and env refused, and `REFUSED_ENV` unset.
fn boundary_plan(
    profile: &HarnessProfile,
    plan: crate::claude_stdio::SpawnPlan,
) -> Result<crate::claude_stdio::SpawnPlan, String> {
    let user_settings = dirs::home_dir().and_then(|home| user_settings_endpoint(&home));
    let endpoint = endpoint(
        profile.env.get("ANTHROPIC_BASE_URL").map(String::as_str),
        user_settings.as_deref(),
        remote_login_value("ANTHROPIC_BASE_URL").as_deref(),
    );
    let args = claude_args(endpoint.as_ref(), profile, plan.args)?;
    let mut out = Vec::with_capacity(args.len() + 2 * REFUSED_ENV.len() + 1);
    for k in REFUSED_ENV {
        out.push("-u".into());
        out.push((*k).into());
    }
    out.push(plan.program);
    out.extend(args);
    Ok(crate::claude_stdio::SpawnPlan { program: "/usr/bin/env".into(), args: out })
}

/// The remote chain's Claude command line: its own settings and no MCP
/// servers, then the whole command inside `exec` with the profile and this
/// spawn's `TMPDIR`. Refuses a profile argv or env that already shapes them.
pub(super) fn wrap(
    exec: &Path,
    bound: &Bound,
    profile: &HarnessProfile,
    program: String,
    args: Vec<String>,
) -> Result<(String, Vec<String>), String> {
    let args = claude_args(bound.endpoint.as_ref(), profile, args)?;
    let mut out = bound.sandbox_args();
    out.push("/usr/bin/env".into());
    for k in REFUSED_ENV {
        out.push("-u".into());
        out.push((*k).into());
    }
    out.push(format!("TMPDIR={}", bound.tmp.display()));
    out.push(format!("CLAUDE_CODE_TMPDIR={}", bound.tmp.display()));
    out.push(program);
    out.extend(args);
    Ok((exec.to_string_lossy().into_owned(), out))
}

fn claude_args(
    endpoint: Option<&Endpoint>,
    profile: &HarnessProfile,
    mut args: Vec<String>,
) -> Result<Vec<String>, String> {
    let refused = |a: &String| {
        REFUSED_ARGS.iter().any(|r| a.as_str() == *r || a.starts_with(&format!("{r}=")))
    };
    if let Some(bad) = profile.argv.iter().find(|a| refused(a)) {
        return Err(format!("a remote chain never runs Claude Code with {bad}"));
    }
    #[cfg(target_os = "linux")]
    if let Some(bad) = profile.env.keys().find(|k| k.as_str() != "TMPDIR" && loader_env_key(k)) {
        return Err(format!("a remote chain never runs Claude Code with {bad} set"));
    }
    if let Some(bad) = REFUSED_ENV.iter().find(|k| profile.env.contains_key(**k)) {
        return Err(format!("a remote chain never runs Claude Code with {bad} set"));
    }
    args.push("--settings".into());
    args.push(claude_settings(endpoint.map(|e| e.url.as_str())));
    if endpoint.is_some_and(|e| e.own) {
        args.push("--setting-sources".into());
        args.push("project,local".into());
    }
    args.push("--strict-mcp-config".into());
    args.push("--mcp-config".into());
    args.push(r#"{"mcpServers":{}}"#.into());
    Ok(args)
}

#[cfg(target_os = "linux")]
fn linux_keeper_args(
    bound: &Bound,
    program: String,
    args: Vec<String>,
) -> Result<(String, Vec<String>), String> {
    let exe = std::fs::canonicalize(std::env::current_exe().map_err(|e| e.to_string())?)
        .map_err(|e| format!("cannot resolve acpmux executable: {e}"))?;
    linux_keeper_args_with_exe(bound, program, args, &exe)
}

#[cfg(target_os = "linux")]
fn linux_keeper_args_with_exe(
    bound: &Bound,
    program: String,
    args: Vec<String>,
    exe: &Path,
) -> Result<(String, Vec<String>), String> {
    let mut out: Vec<String> =
        crate::daemon::daemon_prefix().iter().map(|s| s.to_string_lossy().into_owned()).collect();
    out.push("__remote-sandbox-keeper".into());
    for (key, value) in [
        ("--cwd", &bound.cwd),
        ("--tmpdir", &bound.tmp),
        ("--home", &bound.home),
        ("--claude-tmp-project", &bound.claude_tmp_project),
        ("--claude-project", &bound.claude_project),
    ] {
        out.push(key.into());
        out.push(value.to_string_lossy().into_owned());
    }
    out.extend(["--proxy-port".into(), "8118".into()]);
    if let Some((port, true)) = bound.api_port {
        let host = bound
            .endpoint
            .as_ref()
            .and_then(|e| e.url.split("//").nth(1))
            .and_then(|authority| authority.split(['/', '?', '#']).next())
            .unwrap_or_default();
        if host.starts_with('[') || host == "::1" {
            return Err("IPv6 loopback API routes are unavailable until the keeper handshake carries the family".into());
        }
        out.extend(["--api-port".into(), port.to_string(), "--api-loopback-v4".into()]);
    }
    out.push("--".into());
    out.push("/usr/bin/env".into());
    for key in REFUSED_ENV {
        out.extend(["-u".into(), (*key).into()]);
    }
    out.extend([
        format!("TMPDIR={}", bound.tmp.display()),
        format!("CLAUDE_CODE_TMPDIR={}", bound.tmp.display()),
        program,
    ]);
    out.extend(args);
    Ok((exe.to_string_lossy().into_owned(), out))
}

#[cfg(target_os = "linux")]
fn linux_wrap(
    bound: &Bound,
    profile: &HarnessProfile,
    program: String,
    args: Vec<String>,
) -> Result<(String, Vec<String>), String> {
    linux_keeper_args(bound, program, claude_args(bound.endpoint.as_ref(), profile, args)?)
}

/// The canary's shell: $1 a file outside the allowed folders, $2 a 127.0.0.1
/// port, $3 the temporary folder, $4 a ::1 port (0: none),
/// $5 the private persistence probe dir, $6 a Unix socket, $7 the pinned
/// acpmux path, remaining arguments its multicall prefix. The probe operations
/// are finite; the caller bounds the whole process with a 20-second deadline.
const CANARY: &str = r#": > "$1" 2>/dev/null; o=$?
(exec 3<>"/dev/tcp/127.0.0.1/$2") 2>/dev/null; l=$?
[ "$l" -ne 0 ] && { (exec 3<>"/dev/tcp/::1/$4") 2>/dev/null; [ $? -eq 0 ] && l=0; }
t=$(mktemp "$3/acpmux-canary.XXXXXX" 2>/dev/null) && rm -f "$t"; i=$?
g=unknown; c=unknown; rg=unknown; rc=unknown; w=unknown
if [ -n "$5" ]; then
  printf x > "$5/.git/hooks/pre-commit" 2>/dev/null; g=$?
  printf x > "$5/CLAUDE.md" 2>/dev/null; c=$?
  printf x > "$5/source-git" && printf x > "$5/source-claude"; w=$?
  if [ "$w" -eq 0 ]; then
  if rr=$("$7" "${@:8}" __remote-sandbox-canary-rename "$5/source-git" "$5/.git/hooks/pre-commit"); then
    case "$rr" in rename=0) rg=0;; rename=1) rg=1;; esac
  fi
  if rr=$("$7" "${@:8}" __remote-sandbox-canary-rename "$5/source-claude" "$5/CLAUDE.md"); then
    case "$rr" in rename=0) rc=0;; rename=1) rc=1;; esac
  fi
  fi
fi
persistence="$5"
u=unknown
if [ -n "$6" ]; then
  socket=$6; helper=$7; shift 7
  if probe=$("$helper" "$@" __remote-sandbox-canary-unix "$socket"); then
    case "$probe" in unix=0) u=0;; unix=1) u=1;; esac
  fi
fi
if [ -n "$persistence" ]; then
  echo "acpmux-canary outside=$o loopback=$l tmp=$i git=$g claude=$c rename_git=$rg rename_claude=$rc cwd=$w unix=$u"
else
  echo "acpmux-canary outside=$o loopback=$l tmp=$i"
fi"#;

struct PersistenceProbe {
    path: PathBuf,
    #[cfg(target_os = "linux")]
    fd: OwnedFd,
}

#[cfg(target_os = "linux")]
fn probe_entry_absent(dir: RawFd, name: &str) -> bool {
    let Ok(name) = std::ffi::CString::new(name) else { return false };
    let mut stat = unsafe { std::mem::zeroed::<libc::stat>() };
    let rc =
        unsafe { libc::fstatat(dir, name.as_ptr(), &mut stat, libc::AT_SYMLINK_NOFOLLOW as _) };
    rc < 0 && std::io::Error::last_os_error().raw_os_error() == Some(libc::ENOENT)
}

#[cfg(target_os = "linux")]
fn probe_paths_are_absent(probe: &PersistenceProbe) -> bool {
    let hooks = std::ffi::CString::new(".git/hooks").unwrap();
    let hooks_fd = unsafe {
        libc::openat(
            probe.fd.as_raw_fd(),
            hooks.as_ptr(),
            libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if hooks_fd < 0 {
        return false;
    }
    let hooks = unsafe { OwnedFd::from_raw_fd(hooks_fd) };
    probe_entry_absent(hooks.as_raw_fd(), "pre-commit")
        && probe_entry_absent(probe.fd.as_raw_fd(), "CLAUDE.md")
}

#[cfg(target_os = "linux")]
/// The fixed two-name loop ends after bounded O_NONBLOCK reads from the pinned directory.
fn probe_sources_intact(probe: &PersistenceProbe) -> bool {
    for name in ["source-git", "source-claude"] {
        let Ok(name) = std::ffi::CString::new(name) else { return false };
        let raw = unsafe {
            libc::openat(
                probe.fd.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC,
            )
        };
        if raw < 0 {
            return false;
        }
        let fd = unsafe { OwnedFd::from_raw_fd(raw) };
        let mut stat = unsafe { std::mem::zeroed::<libc::stat>() };
        if unsafe { libc::fstat(fd.as_raw_fd(), &mut stat) } != 0
            || stat.st_mode & libc::S_IFMT != libc::S_IFREG
        {
            return false;
        }
        let mut byte = [0_u8; 2];
        let read = unsafe { libc::read(fd.as_raw_fd(), byte.as_mut_ptr().cast(), byte.len() as _) };
        if read != 1 || byte[0] != b'x' {
            return false;
        }
    }
    true
}

fn canary_persistence_probe(cwd: &Path, linux: bool) -> Result<Option<PersistenceProbe>, String> {
    if !linux {
        return Ok(None);
    }
    let probe = cwd.join(format!(".acpmux-canary-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(probe.join(".git/hooks"))
        .map_err(|e| format!("canary setup persistence probe: {e}"))?;
    #[cfg(not(target_os = "linux"))]
    {
        let _ = probe;
        Ok(None)
    }
    #[cfg(target_os = "linux")]
    let text = std::ffi::CString::new(probe.as_os_str().as_encoded_bytes())
        .map_err(|_| "canary probe path contains NUL")?;
    #[cfg(target_os = "linux")]
    let raw = unsafe {
        libc::open(text.as_ptr(), libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
    };
    #[cfg(target_os = "linux")]
    if raw < 0 {
        return Err(format!("canary pin probe: {}", std::io::Error::last_os_error()));
    }
    #[cfg(target_os = "linux")]
    Ok(Some(PersistenceProbe { path: probe, fd: unsafe { OwnedFd::from_raw_fd(raw) } }))
}

type CanaryFields = [Option<i32>; 9];

/// Field/report scans end at the finite captured output; duplicate keys refuse.
fn parse_canary_report(text: &str) -> Result<CanaryFields, String> {
    let mut reports = text.lines().filter_map(|line| line.strip_prefix("acpmux-canary "));
    let line = reports.next().ok_or("canary did not report a result")?;
    if reports.next().is_some() {
        return Err("canary reported more than one result".into());
    }
    let mut values = std::collections::BTreeMap::new();
    for word in line.split_whitespace() {
        let (key, value) = word.split_once('=').ok_or("malformed canary field")?;
        if values.insert(key, value).is_some() {
            return Err("canary repeated a field".into());
        }
    }
    Ok([
        "outside",
        "loopback",
        "tmp",
        "unix",
        "git",
        "claude",
        "rename_git",
        "rename_claude",
        "cwd",
    ]
    .map(|key| values.get(key).and_then(|value| value.parse().ok())))
}

fn canary_verdict(
    success: bool,
    fields: CanaryFields,
    linux: bool,
    probe_paths_absent: bool,
) -> bool {
    let [o, l, t, u, g, c, rg, rc, w] = fields;
    canary_report_held(success, (o, l, t, u), linux)
        && probe_paths_absent
        && (!linux
            || (g == Some(1) && c == Some(1) && rg == Some(1) && rc == Some(1) && w == Some(0)))
}

/// Run the canary under `exec` with the profile and `bound`; Ok only when
/// the sandbox held: outside writes, persistence write-opens and renames failed, loopback
/// connections never arrived, and the temporary write worked.
pub(super) async fn canary(exec: &Path, bound: &Bound, linux: bool) -> Result<(), String> {
    let listener =
        std::net::TcpListener::bind("127.0.0.1:0").map_err(|e| format!("listen: {e}"))?;
    listener.set_nonblocking(true).map_err(|e| format!("listen: {e}"))?;
    let port = listener.local_addr().map_err(|e| format!("listen: {e}"))?.port();
    // ::1 too, where the host has IPv6 loopback.
    let listener6 = std::net::TcpListener::bind("[::1]:0").ok();
    if let Some(l) = &listener6 {
        l.set_nonblocking(true).map_err(|e| format!("listen: {e}"))?;
    }
    let port6 = listener6.as_ref().and_then(|l| l.local_addr().ok()).map_or(0, |a| a.port());
    let persistence_probe = canary_persistence_probe(&bound.cwd, linux)?;
    let outside = bound.home.join(format!(".acpmux-sandbox-canary-{}", uuid::Uuid::now_v7()));
    #[cfg(unix)]
    let socket_path = bound
        .tmp
        .parent()
        .unwrap_or(Path::new("/tmp"))
        .join(format!("acpmux-sandbox-canary-{}.sock", uuid::Uuid::now_v7()));
    #[cfg(unix)]
    let unix_listener = if linux {
        Some(
            std::os::unix::net::UnixListener::bind(&socket_path)
                .map_err(|e| format!("listen unix: {e}"))?,
        )
    } else {
        None
    };
    #[cfg(unix)]
    if let Some(listener) = &unix_listener {
        listener.set_nonblocking(true).map_err(|e| e.to_string())?;
    }
    #[cfg(unix)]
    let socket_arg = if linux { socket_path.to_string_lossy().into_owned() } else { String::new() };
    #[cfg(not(unix))]
    let socket_arg = String::new();
    let persistence_arg = persistence_probe
        .as_ref()
        .filter(|_| linux)
        .map_or_else(String::new, |probe| probe.path.to_string_lossy().into_owned());
    let canary_args = ["/bin/bash", "-c", CANARY, "acpmux-canary"]
        .into_iter()
        .map(str::to_owned)
        .chain([
            outside.to_string_lossy().into_owned(),
            port.to_string(),
            bound.tmp.to_string_lossy().into_owned(),
            port6.to_string(),
            persistence_arg,
        ])
        .chain([socket_arg, exec.to_string_lossy().into_owned()])
        .chain(crate::daemon::daemon_prefix().iter().map(|s| s.to_string_lossy().into_owned()))
        .collect::<Vec<_>>();
    #[cfg(target_os = "linux")]
    let (program, args): (String, Vec<String>) = if linux {
        linux_keeper_args_with_exe(
            bound,
            "/bin/bash".into(),
            canary_args.into_iter().skip(1).collect(),
            exec,
        )?
    } else {
        (
            exec.to_string_lossy().into_owned(),
            bound.sandbox_args().into_iter().chain(canary_args).collect(),
        )
    };
    #[cfg(not(target_os = "linux"))]
    let (program, args): (String, Vec<String>) = (
        exec.to_string_lossy().into_owned(),
        bound.sandbox_args().into_iter().chain(canary_args).collect(),
    );
    let mut cmd = tokio::process::Command::new(program);
    cmd.args(args).current_dir(&bound.cwd).stdin(std::process::Stdio::null()).kill_on_drop(true);
    #[cfg(target_os = "linux")]
    if linux {
        scrub_loader_env(&mut cmd);
    }
    cmd.env("PATH", "/usr/bin:/bin");
    #[cfg(target_os = "linux")]
    let absent_before = persistence_probe.as_ref().is_none_or(probe_paths_are_absent);
    #[cfg(not(target_os = "linux"))]
    let absent_before = true;
    let run = tokio::time::timeout(std::time::Duration::from_secs(20), cmd.output()).await;
    let landed = std::fs::symlink_metadata(&outside).is_ok();
    if landed {
        let _ = std::fs::remove_file(&outside);
    }
    #[cfg(target_os = "linux")]
    let probe_paths_absent =
        absent_before && persistence_probe.as_ref().is_none_or(probe_paths_are_absent);
    #[cfg(not(target_os = "linux"))]
    let probe_paths_absent = absent_before;
    // A denied rename must leave the ordinary source in place too. This finite
    // pair check proves the successful cwd writes independently of the report.
    #[cfg(target_os = "linux")]
    let sources_intact = persistence_probe.as_ref().is_none_or(probe_sources_intact);
    #[cfg(not(target_os = "linux"))]
    let sources_intact = true;
    if let Some(probe) = &persistence_probe {
        let _ = std::fs::remove_dir_all(&probe.path);
    }
    #[cfg(unix)]
    let _ = std::fs::remove_file(&socket_path);
    let arrived =
        listener.accept().is_ok() || listener6.as_ref().is_some_and(|l| l.accept().is_ok());
    #[cfg(unix)]
    let arrived_unix = unix_listener.as_ref().is_some_and(|l| l.accept().is_ok());
    #[cfg(not(unix))]
    let arrived_unix = false;
    let out = match run {
        Ok(Ok(out)) => out,
        Ok(Err(e)) => {
            return Err(format!("the sandbox canary did not start ({}): {e}", exec.display()));
        }
        Err(_) => return Err("the sandbox canary did not finish in 20 s".into()),
    };
    let text = String::from_utf8_lossy(&out.stdout);
    let fields = parse_canary_report(&text).unwrap_or([None; 9]);
    let [o, l, t, u, _, _, _, _, _] = fields;
    let held = canary_verdict(out.status.success(), fields, linux, probe_paths_absent)
        && sources_intact
        && !landed
        && !arrived
        && (!linux || !arrived_unix);
    if held {
        return Ok(());
    }
    Err(format!(
        "the sandbox canary shows no sandbox (outside write {}, loopback connect {}, temp write {}, unix connect {}, persistence {fields:?}, sources intact {sources_intact}, file landed {landed}, connection arrived {arrived}/{arrived_unix}; status {}, stderr {:?})",
        o.map_or("unknown".into(), |c| if c == 0 { "allowed".to_owned() } else { "denied".into() }),
        l.map_or("unknown".into(), |c| if c == 0 { "allowed".to_owned() } else { "denied".into() }),
        t.map_or("unknown".into(), |c| if c == 0 { "allowed".to_owned() } else { "denied".into() }),
        u.map_or("unknown".into(), |c| if c == 0 { "allowed".to_owned() } else { "denied".into() }),
        out.status,
        String::from_utf8_lossy(&out.stderr).chars().take(1200).collect::<String>(),
    ))
}

fn canary_report_held(
    success: bool,
    (o, l, t, u): (Option<i32>, Option<i32>, Option<i32>, Option<i32>),
    linux: bool,
) -> bool {
    success
        && matches!(o, Some(c) if c != 0)
        && matches!(l, Some(c) if c != 0)
        && t == Some(0)
        && (!linux || matches!(u, Some(c) if c != 0))
}

impl Hub {
    /// Integration-test fault injection: select an unavailable bwrap for probing only.
    /// It never changes the executable the keeper pins and runs.
    #[doc(hidden)]
    #[cfg(target_os = "linux")]
    pub fn set_linux_bwrap_probe_for_tests(&self, path: PathBuf) {
        *self.linux_bwrap_probe.lock().unwrap_or_else(|e| e.into_inner()) = Some(path);
    }

    /// Integration-test availability probe; production also probes before spawning.
    #[doc(hidden)]
    #[cfg(target_os = "linux")]
    pub fn linux_sandbox_probe_for_tests() -> Result<(), String> {
        crate::linux_sandbox::bwrap::probe(Path::new("/usr/bin/bwrap")).map_err(|e| e.to_string())
    }

    /// Whether `session` is a remote chain's Claude Code session (remote
    /// origin, a claude-stdio profile): one that runs in the sandbox. A
    /// profile that cannot be read now counts as one (fail closed).
    pub(super) fn remote_claude(&self, session: &Session) -> bool {
        let m = session.meta();
        m.remote_origin
            && self.config.try_read().map_or(true, |cfg| {
                super::resolve::session_profile(&cfg, &m.harness, &m.cwd, true)
                    .map_or(true, |p| p.kind == crate::config::HarnessKind::ClaudeStdio)
            })
    }

    /// The `sandbox-exec` remote chains spawn under (`SANDBOX_EXEC`). An
    /// embedder (tests) may point it elsewhere: the canary proves whatever
    /// it runs, so a stand-in that does not sandbox is refused.
    #[doc(hidden)]
    pub fn set_remote_sandbox_exec(&self, path: PathBuf) {
        *self.remote_sandbox_exec.lock().unwrap_or_else(|e| e.into_inner()) = path;
    }

    /// Integration-test hook: accepts the separately built acpmux test binary.
    /// Never used by production spawns, which pin current_exe through the keeper.
    /// Enables no spawn policy and does not replace the production executable.
    #[doc(hidden)]
    pub async fn linux_sandbox_canary_for_tests(
        &self,
        cwd: PathBuf,
        exec: PathBuf,
    ) -> Result<(), String> {
        #[cfg(target_os = "linux")]
        {
            let bound = Bound::for_session(&cwd, "integration-canary", None)?;
            return canary(&exec, &bound, true).await;
        }
        #[cfg(not(target_os = "linux"))]
        {
            let _ = (cwd, exec);
            Err("Linux sandbox canary is unavailable on this platform".into())
        }
    }

    /// `plan` for this spawn: a remote chain's (remote-origin) Claude Code
    /// runs inside the platform sandbox, canary-checked at this spawn; any
    /// other session's plan is unchanged.
    ///
    /// The profile it returns carries the remote chain's env: Claude's own
    /// credential (the keychain is closed to the sandbox; read only with the
    /// setting `KEYCHAIN_LOGIN_SETTING` on) and
    /// `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB`, so Claude's Bash and other
    /// children never inherit that credential. Env, never argv: argv is
    /// visible to every process of the user.
    pub(super) async fn remote_chain_plan<'p>(
        &self,
        session: &Session,
        profile: &'p HarnessProfile,
        plan: crate::claude_stdio::SpawnPlan,
    ) -> Result<(crate::claude_stdio::SpawnPlan, std::borrow::Cow<'p, HarnessProfile>), RpcError>
    {
        if !session.meta().remote_origin {
            return Ok((plan, std::borrow::Cow::Borrowed(profile)));
        }
        let refused = |why: String| {
            RpcError::new(-32000, format!("remote chain refused: {why}"))
                .with_data(json!({"reason": "remote.sandbox_refused"}))
        };
        let (plan, mut profile) = if crate::config::is_subrouter_proxy(&profile.argv) {
            let claude = self
                .config
                .read()
                .await
                .harnesses
                .get("claude")
                .filter(|c| c.kind == crate::config::HarnessKind::ClaudeStdio)
                .and_then(|c| c.argv.first().cloned());
            let route = {
                let servers = dirs::home_dir()
                    .map(|home| home.join(".subrouter/codex/servers.json"))
                    .unwrap_or_default();
                let env = std::env::var("SUBROUTER_URL")
                    .ok()
                    .or_else(|| crate::login_env::var("SUBROUTER_URL"));
                crate::config::subrouter_route(env.as_deref(), &servers)
            };
            let (program, args, routed) =
                subrouter_plan(profile, plan.args, claude, route).map_err(refused)?;
            (crate::claude_stdio::SpawnPlan { program, args }, routed)
        } else {
            (plan, profile.clone())
        };
        // A remote chain never runs without the permission prompt: no switch
        // to bypassPermissions (its settings disable the mode as well).
        let mut plan = plan;
        plan.args.retain(|a| a != crate::claude_stdio::ALLOW_BYPASS_FLAG);
        // A chat moved here in full access (a transfer keeps its mode)
        // starts in Claude's asking default instead.
        if let Some(i) = plan.args.iter().position(|a| a == "--permission-mode")
            && plan.args.get(i + 1).is_some_and(|m| m == "bypassPermissions")
        {
            plan.args[i + 1] = "default".into();
        }
        let credential = claude_credential(&profile).await.map_err(|why| {
            RpcError::new(-32000, format!("remote chain refused: {why}"))
                .with_data(json!({"reason": "remote.credential_expiring"}))
        })?;
        if let Some((key, value)) = credential {
            profile.env.insert(key.into(), value);
        }
        // Whatever supplied the plan (including `sr claude proxy`), the
        // inner program is frozen before the sandbox runs it.
        plan.program = super::resolve::remote_executable(&plan.program)?;
        super::resolve::refuse_remote_cwd_executable(&plan.program, &session.meta().cwd)?;
        // Every host sandboxes, a Cloud VM included: nothing on the machine (its
        // `/etc/cmux/vm-kind`, `/srv/team`, config.json's `vmHost`) skips the probe
        // and canary below, since the agent can write all of them (`vm_host.rs`).
        // Only the caller's own opt-out for this session does (`vm_boundary.rs`).
        // Bypass mode stays off (above); the session's policy answers Claude's prompts.
        if self.vm_boundary_unsandboxed(&session.meta()).await {
            let plan = boundary_plan(&profile, plan).map_err(|why| {
                self.append(session, "mux", "remote_sandbox", json!({"refused": why}));
                refused(why)
            })?;
            profile.env.insert("CLAUDE_CODE_SUBPROCESS_ENV_SCRUB".into(), "1".into());
            self.append(session, "mux", "remote_sandbox", json!({"vmBoundary": true}));
            // Unsandboxed on purpose: Web control stays refused (`remote_floor.rs`), as for
            // any agent no canary proved (`hosts.rs` reads it back the same way).
            session.floor.unsandboxed.store(true, Ordering::SeqCst);
            return Ok((plan, std::borrow::Cow::Owned(profile)));
        }
        let (program, args) =
            self.sandboxed_claude_plan(session, &profile, plan.program, plan.args).await?;
        profile.env.insert("CLAUDE_CODE_SUBPROCESS_ENV_SCRUB".into(), "1".into());
        Ok((crate::claude_stdio::SpawnPlan { program, args }, std::borrow::Cow::Owned(profile)))
    }

    /// A remote chain's Claude spawn plan inside the sandbox, after the
    /// canary passed; the refusal is recorded on the session.
    pub(super) async fn sandboxed_claude_plan(
        &self,
        session: &Session,
        profile: &HarnessProfile,
        program: String,
        args: Vec<String>,
    ) -> Result<(String, Vec<String>), RpcError> {
        let exec = self.remote_sandbox_exec.lock().unwrap_or_else(|e| e.into_inner()).clone();
        // The route Claude reaches its API by (`endpoint`).
        let user_settings = dirs::home_dir().and_then(|home| user_settings_endpoint(&home));
        let endpoint = endpoint(
            profile.env.get("ANTHROPIC_BASE_URL").map(String::as_str),
            user_settings.as_deref(),
            remote_login_value("ANTHROPIC_BASE_URL").as_deref(),
        );
        let linux = cfg!(target_os = "linux");
        let result = async {
            #[cfg(target_os = "linux")]
            if let Some(path) =
                self.linux_bwrap_probe.lock().unwrap_or_else(|e| e.into_inner()).clone()
            {
                crate::linux_sandbox::bwrap::probe(&path)
                    .map_err(|e| format!("bwrap unavailable: {e}"))?;
            }
            let bound = Bound::for_session(&session.meta().cwd, &session.id, endpoint)?;
            let plan = if linux {
                #[cfg(target_os = "linux")]
                {
                    linux_wrap(&bound, profile, program, args)?
                }
                #[cfg(not(target_os = "linux"))]
                {
                    return Err("the Linux sandbox is unavailable on this platform".into());
                }
            } else {
                wrap(&exec, &bound, profile, program, args)?
            };
            #[cfg(target_os = "linux")]
            let canary_exec = if linux {
                // Never use the configurable sandbox-exec test hook on Linux.
                std::env::current_exe()
                    .and_then(std::fs::canonicalize)
                    .map_err(|e| e.to_string())?
            } else {
                exec.clone()
            };
            #[cfg(not(target_os = "linux"))]
            let canary_exec = exec.clone();
            canary(&canary_exec, &bound, linux).await?;
            Ok::<_, String>(plan)
        }
        .await;
        match result {
            Ok(plan) => {
                // The profile identity: an adopted host counts as sandboxed
                // only under this very profile and env policy (`hosts.rs`).
                self.append(
                    session,
                    "mux",
                    "remote_sandbox",
                    json!({"canary": "passed", "profile": profile_id()}),
                );
                // A fresh, sandboxed agent: the adopted mark ends with it.
                session.floor.unsandboxed.store(false, Ordering::SeqCst);
                Ok(plan)
            }
            Err(why) => {
                tracing::warn!(session = %session.id, "remote chain sandbox refused: {why}");
                self.append(session, "mux", "remote_sandbox", json!({"refused": why}));
                Err(RpcError::new(-32000, format!("remote chain refused: {why}"))
                    .with_data(json!({"reason": "remote.sandbox_refused"})))
            }
        }
    }
}

#[cfg(test)]
mod vm_host_tests {
    #[test]
    fn a_nested_agent_parent_credential_never_becomes_remote_login() {
        assert_eq!(
            super::select_remote_login_credential(
                true,
                Some("synthetic-parent-token".into()),
                Some("synthetic-login-token".into()),
            ),
            Some("synthetic-login-token".into())
        );
        assert_eq!(
            super::select_remote_login_credential(
                true,
                Some("synthetic-parent-token".into()),
                None,
            ),
            None
        );
        assert_eq!(
            super::select_remote_login_credential(
                true,
                Some("http://synthetic-parent.invalid".into()),
                Some("http://synthetic-login.invalid".into()),
            ),
            Some("http://synthetic-login.invalid".into())
        );
    }
}

#[cfg(test)]
mod endpoint_tests {
    use super::*;

    #[cfg(target_os = "linux")]
    const LOADER_KEYS: &str = "GCONV_PATH GETCONF_DIR GLIBC_TUNABLES HOSTALIASES LD_AUDIT LD_DEBUG LD_DEBUG_OUTPUT LD_DYNAMIC_WEAK LD_HWCAP_MASK LD_LIBRARY_PATH LD_ORIGIN_PATH LD_PRELOAD LD_PROFILE LD_SHOW_AUXV LD_USE_LOAD_BIAS LD_UNKNOWN LOCALDOMAIN LOCPATH MALLOC_ARENA_MAX MALLOC_ARENA_TEST MALLOC_CHECK_ MALLOC_MMAP_MAX_ MALLOC_MMAP_THRESHOLD_ MALLOC_PERTURB_ MALLOC_TCACHE_COUNT MALLOC_TCACHE_MAX MALLOC_TCACHE_UNSORTED_LIMIT MALLOC_TOP_PAD_ MALLOC_TRACE MALLOC_TRIM_THRESHOLD_ NIS_PATH NLSPATH RESOLV_HOST_CONF RES_OPTIONS TMPDIR TZDIR";

    #[test]
    fn macos_profile_identity_stays_at_base() {
        assert_eq!(
            platform_profile_id(false),
            "dfe0fa2509e4121cda90d0e4fb84e961ba886c72a73385954dcbb48774058054"
        );
    }

    #[test]
    fn macos_canary_report_format_is_unchanged() {
        let fields = parse_canary_report("acpmux-canary outside=1 loopback=1 tmp=0\n").unwrap();
        assert!(canary_verdict(true, fields, false, true));
    }

    #[test]
    fn canary_requires_success_and_every_field() {
        let fields = (Some(1), Some(1), Some(0), Some(1));
        assert!(canary_report_held(true, fields, true));
        assert!(!canary_report_held(false, fields, true));
        for fields in [
            (None, Some(1), Some(0), Some(1)),
            (Some(1), None, Some(0), Some(1)),
            (Some(1), Some(1), None, Some(1)),
            (Some(1), Some(1), Some(0), None),
        ] {
            assert!(!canary_report_held(true, fields, true));
        }
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn linux_refuses_loader_profile_env() {
        for key in LOADER_KEYS.split_whitespace() {
            let p = profile(&["claude"], &[(key, "injected")]);
            assert_eq!(
                claude_args(bound(None).endpoint.as_ref(), &p, vec![]).is_err(),
                key != "TMPDIR",
                "{key}"
            );
            assert!(loader_env_key(key), "{key} must be scrubbed");
        }
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn linux_profile_tmpdir_is_replaced_inside_the_sandbox() {
        let bound = bound(None);
        let p = profile(&["claude"], &[("TMPDIR", "/injected")]);
        let (_, args) = linux_wrap(&bound, &p, "claude".into(), vec![]).unwrap();
        assert!(args.contains(&format!("TMPDIR={}", bound.tmp.display())));
        assert!(!args.iter().any(|a| a.contains("/injected")));
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn linux_canary_attempts_both_persistence_renames() {
        let root = std::env::temp_dir().join(format!("canary-renames-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(root.join("bin")).unwrap();
        let probe = canary_persistence_probe(&root, true).unwrap().unwrap();
        let log = root.join("renames");
        let mv = root.join("bin/mv");
        crate::test_exec::write_executable(
            &mv,
            "#!/bin/sh\nprintf '%s\\n' \"$@\" >> \"$RENAME_LOG\"\nexit 1\n",
        );
        let helper = root.join("bin/helper");
        crate::test_exec::write_executable(
            &helper,
            "#!/bin/sh\ncase \"$1\" in __remote-sandbox-canary-rename) echo rename=0;; *) echo unix=unknown;; esac\n",
        );
        let out = std::process::Command::new("/bin/bash")
            .args(["-c", CANARY, "canary", "/nonexistent/outside", "0"])
            .arg(&root)
            .arg("0")
            .arg(&probe.path)
            .args(["/nonexistent/socket", helper.to_str().unwrap()])
            .env("PATH", format!("{}:/usr/bin:/bin", root.join("bin").display()))
            .env("RENAME_LOG", &log)
            .output()
            .unwrap();
        let attempts = std::fs::read_to_string(log).unwrap_or_default();
        let _ = std::fs::remove_dir_all(&root);
        assert!(out.status.success());
        assert!(attempts.is_empty(), "canary used project-controlled mv: {attempts}");
        let report = String::from_utf8_lossy(&out.stdout);
        assert!(report.contains("rename_git=0") && report.contains("rename_claude=0"), "{report}");
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn linux_canary_checks_write_open_persistence_paths() {
        assert!(CANARY.contains(".git/hooks/pre-commit"));
        assert!(CANARY.contains("CLAUDE.md"));
        assert!(CANARY.contains("printf"));
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn canary_missing_unix_helper_is_unknown() {
        let out = std::process::Command::new("/bin/bash")
            .args([
                "-c",
                CANARY,
                "canary",
                "/nonexistent/outside",
                "0",
                "/nonexistent/tmp",
                "0",
                "/nonexistent/socket",
                "/nonexistent/acpmux",
            ])
            .output()
            .unwrap();
        assert!(String::from_utf8_lossy(&out.stdout).contains("unix=unknown"));
    }

    #[test]
    fn mac_canary_setup_does_not_touch_a_worktree_git_file() {
        let root =
            std::env::temp_dir().join(format!("acpmux-canary-setup-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join(".git"), b"gitdir: elsewhere").unwrap();
        let result = canary_persistence_probe(&root, false).unwrap();
        assert!(result.is_none());
        assert!(root.join(".git").is_file());
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn canary_rejects_a_denied_report_when_probe_file_landed() {
        let fields =
            [Some(1), Some(1), Some(0), Some(1), Some(1), Some(1), Some(1), Some(1), Some(0)];
        assert!(!canary_verdict(true, fields, true, false));
    }

    #[test]
    fn linux_canary_requires_rename_results_and_ordinary_writes() {
        let fields =
            [Some(1), Some(1), Some(0), Some(1), Some(1), Some(1), Some(1), Some(1), Some(0)];
        assert!(canary_verdict(true, fields, true, true));
        for index in [6, 7, 8] {
            let mut missing = fields;
            missing[index] = None;
            assert!(!canary_verdict(true, missing, true, true));
            missing[index] = Some(if index == 8 { 1 } else { 0 });
            assert!(!canary_verdict(true, missing, true, true));
        }
        assert!(parse_canary_report("acpmux-canary outside=1 outside=0").is_err());
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn canary_renames_are_helper_pinned_not_path_commands() {
        assert!(!CANARY.contains("mv -T"));
        assert!(CANARY.contains("__remote-sandbox-canary-rename"));
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn probe_source_symlink_is_rejected_without_reading_target() {
        let root = std::env::temp_dir().join(format!("probe-fd-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&root).unwrap();
        let probe = canary_persistence_probe(&root, true).unwrap().unwrap();
        std::os::unix::fs::symlink("/dev/zero", probe.path.join("source-git")).unwrap();
        std::fs::write(probe.path.join("source-claude"), b"x").unwrap();
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let _ = tx.send(probe_sources_intact(&probe));
        });
        let result = rx.recv_timeout(std::time::Duration::from_millis(100));
        assert_eq!(result.ok(), Some(false), "probe check did not reject quickly");
        let root2 = std::env::temp_dir().join(format!("probe-fifo-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&root2).unwrap();
        let probe = canary_persistence_probe(&root2, true).unwrap().unwrap();
        let fifo = probe.path.join("source-git");
        let _ = std::fs::remove_file(&fifo);
        unsafe {
            libc::mkfifo(
                std::ffi::CString::new(fifo.as_os_str().as_encoded_bytes()).unwrap().as_ptr(),
                0o600 as _,
            )
        };
        std::fs::write(probe.path.join("source-claude"), b"x").unwrap();
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let _ = tx.send(probe_sources_intact(&probe));
        });
        let result = rx.recv_timeout(std::time::Duration::from_millis(100));
        let _ = std::fs::remove_dir_all(root);
        let _ = std::fs::remove_dir_all(root2);
        assert_eq!(result.ok(), Some(false), "probe check did not reject quickly");
    }

    #[test]
    fn canary_rejects_duplicate_report_lines() {
        let report = "acpmux-canary outside=1 loopback=1 tmp=0 unix=1\nacpmux-canary outside=1 loopback=1 tmp=0 unix=1\n";
        assert!(parse_canary_report(report).is_err());
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn linux_identity_covers_every_enforcement_source() {
        let names: Vec<_> = linux_identity_sources().into_iter().map(|(name, _)| name).collect();
        for name in [
            "supervisor.rs",
            "supervisor/locking.rs",
            "lookup.rs",
            "rules.rs",
            "bwrap/home.rs",
            "bwrap/aliases.rs",
            "supervisor/mutations.rs",
        ] {
            assert!(names.contains(&name), "missing {name} from Linux profile identity");
        }
    }

    fn profile(argv: &[&str], env: &[(&str, &str)]) -> HarnessProfile {
        serde_json::from_value(json!({
            "argv": argv,
            "kind": "claude-stdio",
            "env": env.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect::<std::collections::BTreeMap<_, _>>(),
        }))
        .unwrap()
    }

    fn bound(endpoint: Option<Endpoint>) -> Bound {
        Bound {
            cwd: "/Users/p/proj".into(),
            tmp: "/private/tmp/acpmux-remote-x".into(),
            home: "/Users/p".into(),
            claude_tmp_project: "/private/tmp/claude-501/x".into(),
            claude_project: "/Users/p/.claude/projects/x".into(),
            api_port: endpoint.as_ref().and_then(|e| api_port(&e.url)),
            endpoint,
        }
    }

    /// Claude's own order: the profile (or its route) wins, then the user's
    /// Claude settings env (it replaces the process env), then the login env.
    #[test]
    fn the_endpoint_is_the_one_claude_uses() {
        let relay = "http://127.0.0.1:41234";
        let sub = "http://100.89.225.106:31415";
        assert_eq!(
            endpoint(Some(relay), Some(sub), Some("http://x:1")),
            Some(Endpoint { url: relay.into(), own: true })
        );
        assert_eq!(
            endpoint(None, Some(sub), Some("http://x:1")),
            Some(Endpoint { url: sub.into(), own: false })
        );
        assert_eq!(
            endpoint(Some(" "), None, Some("http://x:1")),
            Some(Endpoint { url: "http://x:1".into(), own: false })
        );
        assert_eq!(endpoint(None, None, None), None);
    }

    #[test]
    fn the_user_settings_endpoint_is_read_from_claudes_settings_file() {
        let home = std::env::temp_dir().join(format!("acpmux-ep-{}", std::process::id()));
        std::fs::create_dir_all(home.join(".claude")).unwrap();
        assert_eq!(user_settings_endpoint(&home), None);
        std::fs::write(
            home.join(".claude/settings.json"),
            r#"{"env": {"ANTHROPIC_BASE_URL": "http://h:31415", "ANTHROPIC_AUTH_TOKEN": "t"}}"#,
        )
        .unwrap();
        assert_eq!(user_settings_endpoint(&home).as_deref(), Some("http://h:31415"));
        let _ = std::fs::remove_dir_all(&home);
    }

    /// A profile's own loopback route (the `cmux` harness through the local
    /// relay): exactly that loopback port opens, the inline settings pin it,
    /// and the user settings source (whose env would replace the route's
    /// endpoint and key) is skipped.
    #[test]
    fn a_profiles_loopback_route_opens_only_its_port_and_wins_over_user_settings() {
        let b = bound(Some(Endpoint { url: "http://127.0.0.1:41234".into(), own: true }));
        let args = b.sandbox_args();
        let sb = &args[1];
        assert!(sb.contains("(allow network-outbound (remote ip \"localhost:41234\"))"), "{sb}");
        let deny = sb.find("(deny network-outbound (remote ip \"localhost:*\"))").unwrap();
        let allow = sb.find("(remote ip \"localhost:41234\")").unwrap();
        assert!(allow > deny, "the loopback port must open after the loopback deny");
        assert_eq!(sb.matches("localhost:4").count(), 1, "one loopback port only");
        let p = profile(&["/bin/claude"], &[]);
        let (_, out) =
            wrap(Path::new("/usr/bin/sandbox-exec"), &b, &p, "/bin/claude".into(), vec![]).unwrap();
        let at = out.iter().position(|a| a == "--settings").unwrap();
        let settings: Value = serde_json::from_str(&out[at + 1]).unwrap();
        assert_eq!(settings["env"]["ANTHROPIC_BASE_URL"], "http://127.0.0.1:41234");
        let sources = out.iter().position(|a| a == "--setting-sources").expect("--setting-sources");
        assert_eq!(out[sources + 1], "project,local");
    }

    /// The user's own route (their Claude settings): pinned, opened, and the
    /// user settings stay (they hold its credential).
    #[test]
    fn the_users_own_route_keeps_the_user_settings() {
        let b = bound(Some(Endpoint { url: "http://100.89.225.106:31415".into(), own: false }));
        let sb = &b.sandbox_args()[1];
        assert!(sb.contains("(allow network-outbound (remote ip \"*:31415\"))"), "{sb}");
        let p = profile(&["/bin/claude"], &[]);
        let (_, out) =
            wrap(Path::new("/usr/bin/sandbox-exec"), &b, &p, "/bin/claude".into(), vec![]).unwrap();
        assert!(!out.iter().any(|a| a == "--setting-sources"), "{out:?}");
        let at = out.iter().position(|a| a == "--settings").unwrap();
        let settings: Value = serde_json::from_str(&out[at + 1]).unwrap();
        assert_eq!(settings["env"]["ANTHROPIC_BASE_URL"], "http://100.89.225.106:31415");
        // No route at all: no env pin, no port.
        let none = bound(None);
        assert!(!none.sandbox_args()[1].contains("Claude Code's own API route"));
        assert_eq!(serde_json::from_str::<Value>(&claude_settings(None)).unwrap().get("env"), None);
    }

    /// Claude Code's own temporary files go to this spawn's temporary folder,
    /// the one the profile lets it write, never the shared /tmp.
    #[test]
    fn claude_codes_temporary_folder_is_the_spawns_own() {
        let (_, out) = wrap(
            Path::new("/usr/bin/sandbox-exec"),
            &bound(None),
            &profile(&["claude"], &[]),
            "claude".into(),
            vec![],
        )
        .unwrap();
        let env_at = out.iter().position(|a| a == "/usr/bin/env").unwrap();
        let program_at = out.iter().position(|a| a == "claude").unwrap();
        let env = &out[env_at..program_at];
        assert!(env.contains(&"TMPDIR=/private/tmp/acpmux-remote-x".to_string()), "{env:?}");
        assert!(
            env.contains(&"CLAUDE_CODE_TMPDIR=/private/tmp/acpmux-remote-x".to_string()),
            "{env:?}"
        );
    }

    /// `sr claude proxy` cannot start its proxy in the sandbox: Claude Code
    /// runs straight to the subrouter server instead, or the chain is refused.
    #[test]
    fn sr_claude_proxy_runs_claude_on_the_subrouter_server() {
        let sr = profile(&["/u/.local/bin/sr", "claude", "proxy"], &[]);
        let args = vec!["claude".into(), "proxy".into(), "-p".into(), "--verbose".into()];
        let (program, out, routed) = subrouter_plan(
            &sr,
            args.clone(),
            Some("/u/.local/bin/claude".into()),
            Some("http://100.89.225.106:31415".into()),
        )
        .unwrap();
        assert_eq!(program, "/u/.local/bin/claude");
        assert_eq!(out, vec!["-p".to_string(), "--verbose".into()]);
        assert_eq!(routed.argv, vec!["/u/.local/bin/claude".to_string()]);
        assert_eq!(routed.env["ANTHROPIC_BASE_URL"], "http://100.89.225.106:31415");
        assert_eq!(routed.env["ANTHROPIC_AUTH_TOKEN"], "subrouter");
        assert!(subrouter_plan(&sr, args.clone(), Some("c".into()), None).is_err());
        assert!(subrouter_plan(&sr, args.clone(), None, Some("http://r:1".into())).is_err());
        let extra = profile(&["/u/sr", "claude", "proxy", "--account"], &[]);
        assert!(subrouter_plan(&extra, args, Some("c".into()), Some("http://r:1".into())).is_err());
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn linux_wrap_uses_keeper_and_fixed_proxy_shape() {
        let bound = bound(Some(Endpoint { url: "http://127.0.0.1:41234".into(), own: true }));
        let (_, args) =
            linux_wrap(&bound, &profile(&["claude"], &[]), "/bin/claude".into(), vec![]).unwrap();
        let text = args.join(" ");
        assert!(text.contains("__remote-sandbox-keeper"));
        assert!(text.contains("--proxy-port 8118"));
        assert!(text.contains("--api-port 41234 --api-loopback-v4"));
        assert!(text.contains("-- /usr/bin/env -u CLAUDE_CONFIG_DIR"));
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn linux_credentials_are_bounded_and_parsed_from_home() {
        let home = std::env::temp_dir().join(format!("acpmux-linux-cred-{}", std::process::id()));
        std::fs::create_dir_all(home.join(".claude")).unwrap();
        std::fs::write(
            home.join(".claude/.credentials.json"),
            r#"{"claudeAiOauth":{"accessToken":"linux-token","expiresAt":4102444800000}}"#,
        )
        .unwrap();
        assert_eq!(linux_credential_file(&home).unwrap().as_deref(), Some("linux-token"));
        let _ = std::fs::remove_dir_all(home);
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn linux_default_checks_the_real_sandbox_preconditions() {
        let error = Bound::for_session(Path::new("/"), "wire-default", None).unwrap_err();
        assert!(!error.contains("platform has none"), "{error}");
    }

    /// A fresh `root/project` tree with `root` at `mode`, removed on drop.
    #[cfg(target_os = "linux")]
    struct ModeTree {
        root: PathBuf,
        child: PathBuf,
        gid: u32,
    }

    #[cfg(target_os = "linux")]
    impl ModeTree {
        fn new(tag: &str, mode: u32) -> Self {
            use std::os::unix::fs::PermissionsExt;
            let root = std::env::temp_dir()
                .join(format!("acpmux-linux-safe-{tag}-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&root);
            let child = root.join("project");
            std::fs::create_dir_all(&child).unwrap();
            std::fs::set_permissions(&child, std::fs::Permissions::from_mode(0o700)).unwrap();
            std::fs::set_permissions(&root, std::fs::Permissions::from_mode(mode)).unwrap();
            let gid = std::fs::metadata(&root).unwrap().gid();
            ModeTree { root, child, gid }
        }
        fn check(&self, accounts: &dyn accounts::Accounts) -> Result<(), String> {
            // SAFETY: getuid has no preconditions and cannot fail.
            let uid = unsafe { libc::getuid() };
            linux_secure_path_with(&self.child, &self.root, uid, false, accounts)
        }
        fn private(&self) -> accounts::tests::Fake {
            // SAFETY: getuid has no preconditions and cannot fail.
            accounts::tests::Fake::private(unsafe { libc::getuid() }, self.gid)
        }
    }

    #[cfg(target_os = "linux")]
    impl Drop for ModeTree {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn linux_group_writable_ancestor_in_a_private_group_is_allowed() {
        let tree = ModeTree::new("private", 0o775);
        assert_eq!(tree.check(&tree.private()), Ok(()));
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn linux_group_writable_ancestor_in_a_shared_group_is_refused() {
        let tree = ModeTree::new("shared", 0o775);
        let mut shared = tree.private();
        shared.group.as_mut().unwrap().members = vec!["bob".into()];
        let error = tree.check(&shared).unwrap_err();
        assert!(error.contains("is group-writable and its group leo"), "{error}");
        assert!(error.contains("bob"), "{error}");
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn linux_group_writable_ancestor_in_a_non_primary_group_is_refused() {
        let tree = ModeTree::new("other", 0o775);
        let mut other = tree.private();
        other.user.as_mut().unwrap().gid = tree.gid.wrapping_add(1);
        other.group.as_mut().unwrap().name = "developers".into();
        let error = tree.check(&other).unwrap_err();
        assert!(error.contains("its group developers"), "{error}");
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn linux_world_writable_ancestor_is_refused_even_in_a_private_group() {
        let tree = ModeTree::new("world", 0o777);
        let error = tree.check(&tree.private()).unwrap_err();
        assert!(error.ends_with("is world-writable"), "{error}");
        let tree = ModeTree::new("world-only", 0o757);
        assert!(tree.check(&tree.private()).unwrap_err().ends_with("is world-writable"));
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn linux_group_writable_ancestor_with_an_acl_is_refused() {
        // A named user (nobody, 65534) and then a named group with write: the
        // mode still reads 0775, but the ACL lets them write.
        for named in [2u16, 8] {
            let tree = ModeTree::new(&format!("acl-{named}"), 0o775);
            let Some(()) = accounts::tests::set_acl(&tree.root, named, 65534) else {
                eprintln!("skipped: this filesystem has no POSIX ACLs");
                return;
            };
            assert_eq!(std::fs::metadata(&tree.root).unwrap().mode() & 0o777, 0o775);
            let error = tree.check(&tree.private()).unwrap_err();
            assert!(error.contains("has an access control list"), "{error}");
        }
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn linux_group_writable_ancestor_whose_group_lookup_fails_is_refused() {
        let tree = ModeTree::new("lookup", 0o775);
        let mut failing = tree.private();
        failing.group = None;
        let error = tree.check(&failing).unwrap_err();
        assert!(error.contains("cannot be checked"), "{error}");
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn linux_probe_failure_has_a_sandbox_refusal_reason() {
        let error = crate::linux_sandbox::bwrap::probe(Path::new("/definitely/missing/bwrap"))
            .unwrap_err()
            .to_string();
        assert!(
            error.contains("bwrap not installed") || error.contains("probe did not start"),
            "{error}"
        );
    }
}
