//! Part of `Hub`; see `hub/mod.rs`. A remote chain's Claude Code runs in
//! the macOS Seatbelt sandbox (decisions.md REMOTE-SANDBOX, D-R).
//!
//! A remote-origin session (created over the WebSocket listener: a remote
//! device or a peer) that runs Claude Code spawns it as
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
//! same profile and the same parameters run a shell that tries to write a
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
//! Refused as well, before any process starts: a platform without Seatbelt
//! (every one but macOS), a session folder that is the home directory or
//! above it (the profile would allow writes there), and a profile argv that
//! already passes `--settings`, `--dangerously-skip-permissions` or
//! `--allow-dangerously-skip-permissions`.

use super::*;

/// The checked-in Seatbelt profile.
pub(crate) const PROFILE: &str = include_str!("../../sandbox/remote-chain.sb");

/// The identity of what a remote chain runs under: the profile and the env
/// policy (bump `ENV_POLICY` when the child env rules change).
pub(super) fn profile_id() -> String {
    const ENV_POLICY: &str = "env-v5: explicit cleared host projection, fixed remote allowlist, nested-parent credential and endpoint excluded, credential by explicit profile/login env, CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1, endpoint pinned by --settings env, user settings skipped for a profile's own endpoint";
    crate::sha256::sha256_hex(format!("{PROFILE}\n{ENV_POLICY}").as_bytes())
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
        v["env"] = json!({"ANTHROPIC_BASE_URL": url});
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

impl Bound {
    /// The bound for a session folder, its own temporary folder created
    /// (named for `session_id`); refused off macOS and for a folder that is
    /// not a project folder (`refused_folder`).
    #[cfg(unix)]
    pub(super) fn for_session(
        cwd: &Path,
        session_id: &str,
        endpoint: Option<Endpoint>,
    ) -> Result<Self, String> {
        if !cfg!(target_os = "macos") {
            return Err(
                "a remote chain runs Claude Code only inside the macOS Seatbelt sandbox, and this platform has none".into(),
            );
        }
        let canon =
            |p: &Path| std::fs::canonicalize(p).map_err(|e| format!("{}: {e}", p.display()));
        let home = canon(&dirs::home_dir().ok_or("no home directory")?)?;
        let shared_tmp = canon(&std::env::temp_dir())?;
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
        let root = PathBuf::from(format!("/private/tmp/claude-{uid}"));
        let claude_tmp_project = root.join(&name);
        own_dir(&root, uid)?;
        own_dir(&claude_tmp_project, uid)?;
        let claude_project = home.join(".claude/projects").join(&name);
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
    /// Off macOS a remote chain is refused (as the Unix build says on Linux).
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

/// The remote chain's Claude command line: its own settings and no MCP
/// servers, then the whole command inside `exec` with the profile and this
/// spawn's `TMPDIR`. Refuses a profile argv or env that already shapes them.
pub(super) fn wrap(
    exec: &Path,
    bound: &Bound,
    profile: &HarnessProfile,
    program: String,
    mut args: Vec<String>,
) -> Result<(String, Vec<String>), String> {
    let refused = |a: &String| {
        REFUSED_ARGS.iter().any(|r| a.as_str() == *r || a.starts_with(&format!("{r}=")))
    };
    if let Some(bad) = profile.argv.iter().find(|a| refused(a)) {
        return Err(format!("a remote chain never runs Claude Code with {bad}"));
    }
    if let Some(bad) = REFUSED_ENV.iter().find(|k| profile.env.contains_key(**k)) {
        return Err(format!("a remote chain never runs Claude Code with {bad} set"));
    }
    args.push("--settings".into());
    args.push(claude_settings(bound.endpoint.as_ref().map(|e| e.url.as_str())));
    if bound.endpoint.as_ref().is_some_and(|e| e.own) {
        args.push("--setting-sources".into());
        args.push("project,local".into());
    }
    args.push("--strict-mcp-config".into());
    args.push("--mcp-config".into());
    args.push(r#"{"mcpServers":{}}"#.into());
    let mut out = bound.sandbox_args();
    // The login environment the child gets may carry them too.
    out.push("/usr/bin/env".into());
    for k in REFUSED_ENV {
        out.push("-u".into());
        out.push((*k).into());
    }
    out.push(format!("TMPDIR={}", bound.tmp.display()));
    // Claude Code keeps its own temporary files (the Bash tool's working
    // directory file `claude-<id>-cwd`, task output) under CLAUDE_CODE_TMPDIR,
    // else the shared /tmp, which the profile never lets it write: every Bash
    // command then failed with "operation not permitted: /tmp/claude-…-cwd".
    out.push(format!("CLAUDE_CODE_TMPDIR={}", bound.tmp.display()));
    out.push(program);
    out.extend(args);
    Ok((exec.to_string_lossy().into_owned(), out))
}

/// The canary's shell: $1 a file outside the allowed folders, $2 a 127.0.0.1
/// port, $3 the temporary folder, $4 a ::1 port (0: none).
const CANARY: &str = r#": > "$1" 2>/dev/null; o=$?
(exec 3<>"/dev/tcp/127.0.0.1/$2") 2>/dev/null; l=$?
[ "$l" -ne 0 ] && { (exec 3<>"/dev/tcp/::1/$4") 2>/dev/null; [ $? -eq 0 ] && l=0; }
t=$(mktemp "$3/acpmux-canary.XXXXXX" 2>/dev/null) && rm -f "$t"; i=$?
echo "acpmux-canary outside=$o loopback=$l tmp=$i""#;

/// Run the canary under `exec` with the profile and `bound`; Ok only when
/// the sandbox held: the outside write failed and left no file, the loopback
/// connection failed and never arrived, and the temporary write worked.
pub(super) async fn canary(exec: &Path, bound: &Bound) -> Result<(), String> {
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
    let outside = bound.home.join(format!(".acpmux-sandbox-canary-{}", uuid::Uuid::now_v7()));
    let mut cmd = tokio::process::Command::new(exec);
    cmd.args(bound.sandbox_args())
        .args(["/bin/bash", "-c", CANARY, "acpmux-canary"])
        .arg(&outside)
        .arg(port.to_string())
        .arg(&bound.tmp)
        .arg(port6.to_string())
        .current_dir(&bound.cwd)
        .stdin(std::process::Stdio::null())
        .kill_on_drop(true);
    let run = tokio::time::timeout(std::time::Duration::from_secs(20), cmd.output()).await;
    let landed = std::fs::symlink_metadata(&outside).is_ok();
    if landed {
        let _ = std::fs::remove_file(&outside);
    }
    let arrived =
        listener.accept().is_ok() || listener6.as_ref().is_some_and(|l| l.accept().is_ok());
    let out = match run {
        Ok(Ok(out)) => out,
        Ok(Err(e)) => {
            return Err(format!("the sandbox canary did not start ({}): {e}", exec.display()));
        }
        Err(_) => return Err("the sandbox canary did not finish in 20 s".into()),
    };
    let text = String::from_utf8_lossy(&out.stdout);
    let field = |k: &str| {
        text.lines()
            .find_map(|l| l.strip_prefix("acpmux-canary "))
            .and_then(|l| l.split_whitespace().find_map(|w| w.strip_prefix(&format!("{k}="))))
            .and_then(|v| v.parse::<i32>().ok())
    };
    let (o, l, t) = (field("outside"), field("loopback"), field("tmp"));
    let held = matches!(o, Some(c) if c != 0)
        && matches!(l, Some(c) if c != 0)
        && t == Some(0)
        && !landed
        && !arrived;
    if held {
        return Ok(());
    }
    Err(format!(
        "the sandbox canary shows no sandbox (outside write {}, loopback connect {}, temp write {}, file landed {landed}, connection arrived {arrived}; status {}, stderr {:?})",
        o.map_or("unknown".into(), |c| if c == 0 { "allowed".to_owned() } else { "denied".into() }),
        l.map_or("unknown".into(), |c| if c == 0 { "allowed".to_owned() } else { "denied".into() }),
        t.map_or("unknown".into(), |c| if c == 0 { "allowed".to_owned() } else { "denied".into() }),
        out.status,
        String::from_utf8_lossy(&out.stderr).chars().take(300).collect::<String>(),
    ))
}

impl Hub {
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

    /// `plan` for this spawn: a remote chain's (remote-origin) Claude Code
    /// runs inside the Seatbelt sandbox, canary-checked at this spawn; any
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
        // inner program is frozen before either a VM or Seatbelt runs it.
        plan.program = super::resolve::remote_executable(&plan.program)?;
        super::resolve::refuse_remote_cwd_executable(&plan.program, &session.meta().cwd)?;
        // A dedicated agent VM (`vmHost`, off macOS): the VM is the sandbox.
        // Bypass mode stays off (above); the session's permission policy
        // answers Claude's prompts.
        let vm_host = self.config.read().await.vm_host;
        if vm_host_unsandboxed(vm_host, cfg!(target_os = "macos")) {
            self.append(session, "mux", "remote_sandbox", json!({"vmHost": true}));
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
        let result = async {
            let bound = Bound::for_session(&session.meta().cwd, &session.id, endpoint)?;
            let plan = wrap(&exec, &bound, profile, program, args)?;
            canary(&exec, &bound).await?;
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

/// Whether a remote chain's Claude Code runs without the Seatbelt sandbox:
/// only on a `vmHost` machine that is not a Mac (a dedicated agent VM, where
/// the VM boundary is the sandbox). A Mac always sandboxes.
pub(crate) fn vm_host_unsandboxed(vm_host: bool, macos: bool) -> bool {
    vm_host && !macos
}

/// Whether a new session with no asked policy runs approve-all: only on a
/// `vmHost` machine that is not a Mac, and only for the owner's peer daemon
/// (`Origin::Peer`, proven by the peer token over ssh); a Web client never.
pub fn vm_host_peer_approves(vm_host: bool, macos: bool, from_peer: bool) -> bool {
    vm_host_unsandboxed(vm_host, macos) && from_peer
}

#[cfg(test)]
mod vm_host_tests {
    use super::{vm_host_peer_approves, vm_host_unsandboxed};

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

    #[test]
    fn only_the_owner_peer_on_a_vm_host_gets_approve_all() {
        assert!(vm_host_peer_approves(true, false, true));
        assert!(!vm_host_peer_approves(true, false, false), "a Web client still asks");
        assert!(!vm_host_peer_approves(true, true, true), "never on a Mac");
        assert!(!vm_host_peer_approves(false, false, true), "off by default");
    }

    #[test]
    fn only_a_vm_host_off_macos_runs_remote_claude_unsandboxed() {
        assert!(vm_host_unsandboxed(true, false));
        assert!(!vm_host_unsandboxed(true, true), "a Mac always sandboxes");
        assert!(!vm_host_unsandboxed(false, false), "off by default");
        assert!(!vm_host_unsandboxed(false, true));
    }
}

#[cfg(test)]
mod endpoint_tests {
    use super::*;

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
}
