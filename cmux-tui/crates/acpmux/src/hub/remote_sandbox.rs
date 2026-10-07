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
//!
//! Refused as well, before any process starts: a platform without Seatbelt
//! (every one but macOS), a session folder that is the home directory or
//! above it (the profile would allow writes there), and a profile argv that
//! already passes `--settings`, `--dangerously-skip-permissions` or
//! `--allow-dangerously-skip-permissions`.

use super::*;

/// The checked-in Seatbelt profile.
pub(super) const PROFILE: &str = include_str!("../../sandbox/remote-chain.sb");

/// The identity of what a remote chain runs under: the profile and the env
/// policy (bump `ENV_POLICY` when the child env rules change).
pub(super) fn profile_id() -> String {
    const ENV_POLICY: &str = "env-v1: credential by env, CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1";
    crate::sha256::sha256_hex(format!("{PROFILE}\n{ENV_POLICY}").as_bytes())
}

/// The system `sandbox-exec`.
pub(super) const SANDBOX_EXEC: &str = "/usr/bin/sandbox-exec";

/// A remote chain's inline `--settings`: Claude's own Bash sandbox off (it
/// cannot nest in the profile), and every acting tool asks.
pub(super) fn claude_settings() -> String {
    json!({
        "sandbox": {"enabled": false, "autoAllowBashIfSandboxed": false},
        // Ask rules come before allow rules in every settings source, so the
        // user's own allow rules never skip the question in a remote chain.
        "permissions": {"disableBypassPermissionsMode": "disable", "ask": ASK_TOOLS},
    })
    .to_string()
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

/// The credential a remote chain's Claude Code gets by env, when it has
/// none there yet (profile or login env): the OAuth access token from the
/// keychain item Claude Code keeps ("Claude Code-credentials"), read by
/// acpmux outside the sandbox. None: it already has one, or none is found
/// (Claude then reports that it is not logged in).
///
/// The read is bounded (a keychain dialog never holds the spawn), and a
/// token that expires within 10 minutes is refused with the fix: the
/// sandboxed Claude cannot refresh it.
async fn claude_credential(
    profile: &HarnessProfile,
) -> Result<Option<(&'static str, String)>, String> {
    if CREDENTIAL_ENV
        .iter()
        .any(|k| profile.env.contains_key(*k) || crate::chats::login_var(k).is_some())
    {
        return Ok(None);
    }
    if !cfg!(target_os = "macos") {
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
    /// Claude Code's own API route port (`ANTHROPIC_BASE_URL`), and whether
    /// its host is a loopback one.
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
    pub(super) fn for_session(
        cwd: &Path,
        session_id: &str,
        api_url: Option<&str>,
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
            api_port: api_url.and_then(api_port),
        })
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
    args.push(claude_settings());
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
    /// credential (the keychain is closed to the sandbox) and
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
        let (program, args) =
            self.sandboxed_claude_plan(session, profile, plan.program, plan.args).await?;
        let mut profile = profile.clone();
        profile.env.insert("CLAUDE_CODE_SUBPROCESS_ENV_SCRUB".into(), "1".into());
        let credential = claude_credential(&profile).await.map_err(|why| {
            RpcError::new(-32000, format!("remote chain refused: {why}"))
                .with_data(json!({"reason": "remote.credential_expiring"}))
        })?;
        if let Some((key, value)) = credential {
            profile.env.insert(key.into(), value);
        }
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
        // The route Claude reaches its API by: the profile's env, else this
        // process's.
        let api_url = profile
            .env
            .get("ANTHROPIC_BASE_URL")
            .cloned()
            .or_else(|| crate::chats::login_var("ANTHROPIC_BASE_URL"));
        let result = async {
            let bound = Bound::for_session(&session.meta().cwd, &session.id, api_url.as_deref())?;
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

#[cfg(test)]
mod tests {
    use super::*;

    fn bound() -> Bound {
        Bound {
            cwd: "/w".into(),
            tmp: "/t".into(),
            home: "/h".into(),
            claude_tmp_project: "/private/tmp/claude-501/-w".into(),
            claude_project: "/h/.claude/projects/-w".into(),
            api_port: None,
        }
    }

    fn profile(argv: &[&str]) -> HarnessProfile {
        serde_json::from_value(json!({"argv": argv, "kind": "claude-stdio"})).unwrap()
    }

    #[test]
    fn the_plan_runs_claude_inside_the_profile_with_its_own_settings() {
        let (program, args) = wrap(
            Path::new(SANDBOX_EXEC),
            &bound(),
            &profile(&["claude"]),
            "claude".into(),
            vec!["-p".into()],
        )
        .unwrap();
        assert_eq!(program, SANDBOX_EXEC);
        assert_eq!(args[0], "-p");
        assert_eq!(args[1], PROFILE);
        assert_eq!(
            &args[2..12],
            [
                "-D",
                "CWD=/w",
                "-D",
                "TMPDIR=/t",
                "-D",
                "HOME=/h",
                "-D",
                "CLAUDE_TMP_PROJECT=/private/tmp/claude-501/-w",
                "-D",
                "CLAUDE_PROJECT=/h/.claude/projects/-w"
            ]
        );
        assert_eq!(args[12], "/usr/bin/env");
        let unset: Vec<&str> = args[13..21].iter().map(String::as_str).collect();
        assert_eq!(
            unset,
            [
                "-u",
                "CLAUDE_CONFIG_DIR",
                "-u",
                "NODE_OPTIONS",
                "-u",
                "DYLD_INSERT_LIBRARIES",
                "-u",
                "DYLD_LIBRARY_PATH"
            ]
        );
        assert_eq!(&args[21..24], ["TMPDIR=/t", "claude", "-p"]);
        assert_eq!(args[24], "--settings");
        let settings: Value = serde_json::from_str(&args[25]).unwrap();
        assert_eq!(settings["sandbox"]["enabled"], json!(false));
        assert_eq!(settings["sandbox"]["autoAllowBashIfSandboxed"], json!(false));
        assert_eq!(settings["permissions"]["disableBypassPermissionsMode"], json!("disable"));
        let ask = settings["permissions"]["ask"].as_array().unwrap();
        assert!(ask.contains(&json!("Bash")) && ask.contains(&json!("Agent")), "{settings}");
        assert_eq!(&args[26..], ["--strict-mcp-config", "--mcp-config", r#"{"mcpServers":{}}"#]);
    }

    #[test]
    fn a_profile_that_shapes_settings_tools_or_permissions_is_refused() {
        for bad in [
            "--settings",
            "--settings={}",
            "--dangerously-skip-permissions",
            "--permission-mode",
            "--mcp-config",
            "--add-dir",
            "--allowedTools",
            "--continue",
            "--resume",
        ] {
            let r = wrap(
                Path::new(SANDBOX_EXEC),
                &bound(),
                &profile(&["claude", bad]),
                "claude".into(),
                vec![],
            );
            assert!(r.is_err(), "{bad}");
        }
        let mut p = profile(&["claude"]);
        p.env.insert("CLAUDE_CONFIG_DIR".into(), "/x".into());
        assert!(wrap(Path::new(SANDBOX_EXEC), &bound(), &p, "claude".into(), vec![]).is_err());
    }

    #[test]
    fn only_a_project_folder_is_a_remote_chain_folder() {
        let (home, tmp) = (Path::new("/Users/me"), Path::new("/private/var/folders/x/T"));
        let path = [PathBuf::from("/Users/me/tools/bin"), PathBuf::from("/Users/me/w/sub/bin")];
        let ok = |p: &str| refused_folder(Path::new(p), home, tmp, &path).is_none();
        assert!(ok("/Users/me/fun/proj"));
        assert!(ok("/Users/me/proj/.worktrees/a"));
        assert!(ok("/private/var/folders/x/T/scratch"));
        for bad in [
            "/Users/me",
            "/Users/me/.ssh",
            "/Users/me/.local/bin",
            "/Users/me/.config",
            "/Users/me/Library/LaunchAgents",
            "/private/var/folders/x/T",
            "/private/var/folders/x/T/acpmux-remote-abc",
            "/Users/me/bin",
            "/Users/me/go/bin",
            "/Users/me/Applications",
            "/Users/me/tools/bin",
            "/Users/me/tools",
            "/Users/me/w",
            "/opt/homebrew",
            "/Applications",
            "/",
        ] {
            assert!(!ok(bad), "{bad}");
        }
    }

    #[test]
    fn the_api_route_opens_its_port_and_loopback_only_for_a_loopback_host() {
        assert_eq!(api_port("http://127.0.0.1:31415"), Some((31415, true)));
        assert_eq!(api_port("http://localhost:8080/v1"), Some((8080, true)));
        assert_eq!(api_port("http://[::1]:9000"), Some((9000, true)));
        assert_eq!(api_port("https://localhost"), Some((443, true)));
        assert_eq!(api_port("http://cmux-lawrences-mac-mini:31415"), Some((31415, false)));
        assert_eq!(api_port("https://api.anthropic.com"), Some((443, false)));
        assert_eq!(api_port("http://127.0.0.1.evil.com:80"), Some((80, false)));
        assert_eq!(api_port("not a url"), None);
        // Another host's port opens before the loopback deny (so loopback
        // stays shut on it); a loopback route opens loopback after it.
        let deny = "(deny network-outbound (remote ip \"localhost:*\"))";
        let mut b = bound();
        b.api_port = Some((31415, false));
        let p = b.sandbox_args()[1].clone();
        let open = p.find("(allow network-outbound (remote ip \"*:31415\"))").expect("port rule");
        assert!(open < p.find(deny).unwrap(), "{p}");
        assert!(!p.contains("localhost:31415"), "{p}");
        b.api_port = Some((31415, true));
        let p = b.sandbox_args()[1].clone();
        assert!(
            p.find("(allow network-outbound (remote ip \"localhost:31415\"))").unwrap()
                > p.find(deny).unwrap()
        );
        assert!(!p.contains("*:31415"), "{p}");
        assert!(!bound().sandbox_args()[1].contains("31415"));
    }

    #[tokio::test]
    async fn a_profile_with_its_own_credential_never_reads_the_keychain() {
        let mut p = profile(&["claude"]);
        p.env.insert("ANTHROPIC_API_KEY".into(), "k".into());
        assert_eq!(claude_credential(&p).await, Ok(None));
    }

    #[test]
    fn claude_names_its_scratch_folder_like_this() {
        assert_eq!(
            claude_project_name(Path::new("/private/var/folders/bn/94_rl/T/tmp.nefi/work")),
            "-private-var-folders-bn-94-rl-T-tmp-nefi-work"
        );
    }

    #[test]
    fn the_profile_names_the_bounds_the_canary_checks() {
        for needle in [
            "(deny file-write* (subpath \"/\"))",
            "(deny network-outbound (remote ip \"localhost:*\"))",
            "(deny network-outbound)",
            "(deny job-creation)",
            "(deny lsopen)",
            "(deny appleevent-send)",
            "(deny file-link)",
            "(deny file-mount)",
            "(deny user-preference-write)",
            "(global-name \"com.apple.SecurityServer\")",
            "(global-name \"com.apple.lsd.modifydb\")",
            "(deny file-write* (regex #\"/HEAD$\"))",
            ";; @API_PORT@",
            "(param \"CWD\")",
            "(param \"TMPDIR\")",
        ] {
            assert!(PROFILE.contains(needle), "{needle}");
        }
    }
}
