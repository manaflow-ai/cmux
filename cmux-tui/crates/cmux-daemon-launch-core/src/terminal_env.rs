//! The environment the app hands the daemon and its terminals.
//!
//! `terminal-env-v1` persists a terminal's `env` with its creation receipt in
//! the daemon's state directory, and the daemon passes its own environment
//! to every PTY. So neither gets the full login environment, which can hold
//! tokens and keys: only what a correct shell needs before its rc files run.

use crate::Env;
use crate::fs::Fs;
use crate::shell_integration::{BundledCli, Integration};

/// Identity and terminal-session variables that never leak from the
/// capturing shell or the app into the daemon and its shells.
pub const EXCLUDED_KEYS: [&str; 24] = [
    "_",
    "PWD",
    "OLDPWD",
    "SHLVL",
    "TERM",
    "TERM_PROGRAM",
    "TERM_PROGRAM_VERSION",
    "TERM_SESSION_ID",
    "COLORTERM",
    "XPC_SERVICE_NAME",
    "XPC_FLAGS",
    "__CFBundleIdentifier",
    "CMUX_TUI_SOCKET",
    "CMUX_MUX_SOCKET",
    "CMUX_TUI_SESSION",
    "CMUX_SOCKET_PATH",
    "CMUX_SOCKET",
    "CMUX_SOCKET_ENABLE",
    "CMUX_BUNDLE_ID",
    "CMUX_WORKSPACE_ID",
    "CMUX_SURFACE_ID",
    "CMUX_PANE_ID",
    "CMUX_TAB_ID",
    "CMUX_PANEL_ID",
];
/// Also excluded (kept apart so the table above stays one family).
const EXCLUDED_DAEMON: &str = "CMUXD_UNIX_PATH";

/// Exact keys taken from the login environment.
pub const ALLOWED_KEYS: [&str; 9] = [
    "PATH",
    "MANPATH",
    "INFOPATH",
    "LANG",
    "SHELL",
    "TERMINFO_DIRS",
    "HOMEBREW_PREFIX",
    "HOMEBREW_CELLAR",
    "HOMEBREW_REPOSITORY",
];
/// Key prefixes taken from the login environment.
pub const ALLOWED_PREFIXES: [&str; 3] = ["LC_", "XDG_", "CMUX_"];
/// Process identity the daemon itself needs, from the app process only.
pub const DAEMON_IDENTITY_KEYS: [&str; 5] = ["HOME", "USER", "LOGNAME", "TMPDIR", "SSH_AUTH_SOCK"];
/// Name parts that mark a credential.
const CREDENTIAL_PARTS: [&str; 9] = [
    "PASSWORD",
    "PASSWD",
    "PASS",
    "TOKEN",
    "SECRET",
    "CREDENTIAL",
    "CREDENTIALS",
    "APIKEY",
    "PRIVATE",
];

/// Whether `key` names a credential: one of its `_`-separated parts is a
/// credential word, or it ends in `_KEY`. A key allowed by prefix (`CMUX_`)
/// can still hold a secret (`CMUX_SOCKET_PASSWORD`).
pub fn is_credential(key: &str) -> bool {
    let upper = key.to_uppercase();
    let parts: Vec<&str> = upper.split('_').filter(|p| !p.is_empty()).collect();
    parts.iter().any(|p| CREDENTIAL_PARTS.contains(p)) || parts.last() == Some(&"KEY")
}

pub fn is_excluded(key: &str) -> bool {
    EXCLUDED_KEYS.contains(&key) || key == EXCLUDED_DAEMON
}

pub fn is_allowed(key: &str) -> bool {
    if is_excluded(key) || is_credential(key) {
        return false;
    }
    ALLOWED_KEYS.contains(&key) || ALLOWED_PREFIXES.iter().any(|p| key.starts_with(p))
}

/// An app launch knob (`CMUX_NEXT_*`), never forwarded to a terminal or the
/// daemon from the login or the app environment (the app passes the ones the
/// daemon needs as overrides).
pub fn is_launch_knob(key: &str) -> bool {
    key.starts_with("CMUX_NEXT_")
}

/// The allowlisted subset of `env`.
pub fn filter(env: &Env) -> Env {
    env.iter().filter(|(k, _)| is_allowed(k)).map(|(k, v)| (k.clone(), v.clone())).collect()
}

/// Per-terminal `env`: the allowlisted login environment (or the app's when
/// capture failed), plus the app's own `CMUX_*` keys. No `CMUX_NEXT_*` launch
/// knob reaches it from either side (`CMUX_NEXT_TUI_BIN`, the Cloud launch
/// flags): they configure the app process only, so a cmux-next started from
/// a terminal never inherits them. Without a capture, the common tool
/// prefixes go first on `PATH`.
pub fn terminal(login: Option<&Env>, base: &Env) -> Env {
    let mut env = filter(login.unwrap_or(base));
    env.retain(|key, _| !is_launch_knob(key));
    for (key, value) in base {
        if key.starts_with("CMUX_")
            && !is_launch_knob(key)
            && is_allowed(key)
            && !env.contains_key(key)
        {
            env.insert(key.clone(), value.clone());
        }
    }
    if login.is_none()
        && let Some(path) = env.get("PATH").filter(|p| !p.contains("/opt/homebrew/bin")).cloned()
    {
        env.insert("PATH".into(), format!("/opt/homebrew/bin:/usr/local/bin:{path}"));
    }
    env
}

/// The daemon process's environment: [`terminal`] plus the app's identity
/// keys, plus `overrides`.
pub fn daemon(login: Option<&Env>, base: &Env, overrides: &Env) -> Env {
    let mut env = terminal(login, base);
    for key in DAEMON_IDENTITY_KEYS {
        if let Some(value) = base.get(key) {
            env.insert(key.into(), value.clone());
        }
    }
    env.extend(overrides.iter().map(|(k, v)| (k.clone(), v.clone())));
    env
}

/// Whether `xterm-ghostty` is in a terminfo directory ncurses searches.
pub fn has_installed_ghostty_terminfo(home: &str, fs: &Fs) -> bool {
    let roots = [
        format!("{home}/.terminfo"),
        "/usr/share/terminfo".into(),
        "/usr/lib/terminfo".into(),
        "/etc/terminfo".into(),
        "/lib/terminfo".into(),
        "/opt/homebrew/share/terminfo".into(),
        "/usr/local/share/terminfo".into(),
    ];
    roots.iter().any(|root| {
        fs.exists(&format!("{root}/78/xterm-ghostty"))
            || fs.exists(&format!("{root}/x/xterm-ghostty"))
    })
}

/// A new terminal's `TERM`: `xterm-256color`, the entry every ssh target has;
/// `xterm-ghostty` only when the user opted in (`terminal.term`) and it is
/// installed here, since ssh carries `TERM` to hosts that lack it.
pub fn term(prefers_ghostty_term: bool, home: &str, fs: &Fs) -> &'static str {
    if prefers_ghostty_term && has_installed_ghostty_terminfo(home, fs) {
        "xterm-ghostty"
    } else {
        "xterm-256color"
    }
}

/// The terminal identity the app hands its terminals: `TERM` ([`term`]),
/// `COLORTERM=truecolor`, `TERM_PROGRAM=cmux`, and `GHOSTTY_RESOURCES_DIR`.
/// No `TERM_PROGRAM_VERSION`: the daemon sets cmux's own on every terminal
/// child (`cmux_pty::TERMINAL_IDENTITY`), and a Ghostty version here would
/// turn off Codex's and Claude's copy-on-select fallback (cmux#22585).
pub fn ghostty(
    resources_directory: Option<&str>,
    prefers_ghostty_term: bool,
    home: &str,
    fs: &Fs,
) -> Env {
    let mut env = Env::new();
    env.insert("TERM".into(), term(prefers_ghostty_term, home, fs).into());
    env.insert("COLORTERM".into(), "truecolor".into());
    env.insert("TERM_PROGRAM".into(), "cmux".into());
    if let Some(dir) = resources_directory.filter(|d| !d.is_empty()) {
        env.insert("GHOSTTY_RESOURCES_DIR".into(), dir.into());
    }
    env
}

/// One new terminal's `env`: the login environment filtered ([`terminal`]),
/// the app's `overrides`, `TERM`, then Ghostty's shell integration and the
/// bundled `cmux` layer.
///
/// `overrides` is the terminal environment the app chose, applied as given
/// (the Swift provider did the same). It carries the app's socket and
/// identity keys and, after the Cloud bootstrap, `CMUX_NEXT_CLOUD_RUNTIME`
/// and `CMUX_NEXT_CLOUD_ENV`: the `cmux` CLI in that terminal reads them to
/// use the app's Cloud backend (`cmux-tui/src/cloud_environment.rs`). Only
/// the inherited knobs (login shell, app process) are dropped, in [`terminal`].
#[allow(clippy::too_many_arguments)] // the provider's inputs, one per source; a struct would only rename them
pub fn spawn(
    login: Option<&Env>,
    base: &Env,
    overrides: &Env,
    term_value: &str,
    integration: Option<&Integration>,
    cli: Option<&BundledCli>,
    home: &str,
    fs: &Fs,
) -> Env {
    let mut env = terminal(login, base);
    env.extend(overrides.iter().map(|(k, v)| (k.clone(), v.clone())));
    env.insert("TERM".into(), term_value.into());
    if let Some(integration) = integration {
        env = integration.apply(&env, None, home, fs);
    }
    if let Some(cli) = cli {
        env = cli.apply(&env, fs);
    }
    env
}
