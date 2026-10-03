//! The login shell's environment, imported in the background after the
//! daemon binds its socket.
//!
//! launchd starts the daemon with a bare environment: no `ANTHROPIC_*`, no
//! tool PATH, none of the exports in `.zshenv`/`.zprofile`. Agents then
//! behave differently from the same command in an ssh shell ("Not logged
//! in"). The daemon reads the login shell's environment once and applies it
//! to every process it spawns. The daemon's own process environment is never
//! changed, because the runtime is already multi-threaded when the import
//! finishes.

use std::ffi::OsString;
use std::sync::OnceLock;

#[derive(Debug, Default)]
struct Imported {
    /// Variables the daemon's own environment lacks.
    vars: Vec<(String, String)>,
    /// Login PATH first, then the daemon's PATH entries it did not list.
    path: Option<String>,
}

static IMPORTED: OnceLock<Imported> = OnceLock::new();

/// Whether this daemon should import the login environment: when started by
/// launchd (`XPC_SERVICE_NAME` set) or with `ACPMUX_LOGIN_ENV=1`.
/// `ACPMUX_LOGIN_ENV=0` turns it off.
pub fn requested() -> bool {
    match std::env::var("ACPMUX_LOGIN_ENV").as_deref() {
        Ok("0") => false,
        Ok("1") => true,
        _ => std::env::var_os("XPC_SERVICE_NAME").is_some(),
    }
}

/// `pending`, `imported`, or `not_requested` (for `_acpmux/status`).
pub fn state(requested: bool) -> &'static str {
    match (IMPORTED.get(), requested) {
        (Some(_), _) => "imported",
        (None, true) => "pending",
        (None, false) => "not_requested",
    }
}

/// Run the login shell once (bounded) and remember its environment.
/// Returns true when anything was imported.
pub async fn import() -> bool {
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".into());
    let run = tokio::process::Command::new(&shell)
        .args(["-lic", "command env -0"])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .env("ACPMUX_LOGIN_ENV", "0")
        .kill_on_drop(true)
        .output();
    let out = match tokio::time::timeout(std::time::Duration::from_secs(15), run).await {
        Ok(Ok(o)) => o,
        Ok(Err(e)) => {
            tracing::warn!("login shell env: {shell}: {e}");
            let _ = IMPORTED.set(Imported::default());
            return false;
        }
        Err(_) => {
            tracing::warn!("login shell env: {shell} did not finish in 15s");
            let _ = IMPORTED.set(Imported::default());
            return false;
        }
    };
    let (vars, login_path) = parse_env0(&String::from_utf8_lossy(&out.stdout));
    let vars: Vec<(String, String)> =
        vars.into_iter().filter(|(k, _)| std::env::var_os(k).is_none()).collect();
    let path = login_path.map(|lp| {
        let current = std::env::var("PATH").unwrap_or_default();
        let mut merged: Vec<String> =
            lp.split(':').filter(|p| !p.is_empty()).map(str::to_owned).collect();
        for p in current.split(':') {
            if !p.is_empty() && !merged.iter().any(|m| m == p) {
                merged.push(p.to_owned());
            }
        }
        merged.join(":")
    });
    let changed = !vars.is_empty() || path.as_deref() != std::env::var("PATH").ok().as_deref();
    tracing::info!(shell = %shell, added = vars.len(), "imported login shell environment");
    let _ = IMPORTED.set(Imported { vars, path });
    changed
}

/// The PATH spawned processes see.
pub fn path() -> Option<OsString> {
    if let Some(p) = IMPORTED.get().and_then(|i| i.path.clone()) {
        return Some(p.into());
    }
    std::env::var_os("PATH")
}

/// Keys the import adds on top of the daemon's environment.
pub fn imported_keys() -> Vec<String> {
    IMPORTED.get().map(|i| i.vars.iter().map(|(k, _)| k.clone()).collect()).unwrap_or_default()
}

fn pairs() -> Vec<(String, String)> {
    let Some(i) = IMPORTED.get() else { return Vec::new() };
    let mut out = i.vars.clone();
    if let Some(p) = &i.path {
        out.push(("PATH".into(), p.clone()));
    }
    out
}

/// Apply the imported environment to a command (before any `env_remove`).
pub fn apply_std(cmd: &mut std::process::Command) {
    cmd.envs(pairs());
}

/// Same, for tokio's process builder.
pub fn apply_tokio(cmd: &mut tokio::process::Command) {
    cmd.envs(pairs());
}

/// Parse `env -0` output: (variables worth importing, the login PATH).
/// Shell-private and per-process variables are dropped; anything an rc
/// file printed before `env` ran is discarded up to the last newline.
pub(crate) fn parse_env0(text: &str) -> (Vec<(String, String)>, Option<String>) {
    let skip = [
        "PWD",
        "OLDPWD",
        "SHLVL",
        "_",
        "TERM",
        "TERM_SESSION_ID",
        "TTY",
        "LOGNAME",
        "HOME",
        "USER",
        "SHELL",
        "TMPDIR",
        "SSH_AUTH_SOCK",
        "ACPMUX_LOGIN_ENV",
    ];
    let mut vars = Vec::new();
    let mut login_path = None;
    for chunk in text.split('\0') {
        let Some(eq) = chunk.find('=') else { continue };
        let start = chunk[..eq].rfind('\n').map(|i| i + 1).unwrap_or(0);
        let key = &chunk[start..eq];
        let value = &chunk[eq + 1..];
        if key.is_empty()
            || !key.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
            || key.starts_with("XPC_")
            || skip.contains(&key)
        {
            continue;
        }
        if key == "PATH" {
            login_path = Some(value.to_owned());
        } else {
            vars.push((key.to_owned(), value.to_owned()));
        }
    }
    (vars, login_path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_env0_and_drops_noise() {
        let text = "fnm: using node 22\nANTHROPIC_BASE_URL=http://x\0PATH=/a:/b\0PWD=/tmp\0XPC_SERVICE_NAME=svc\0BAD KEY=1\0MULTI=a\nb\0";
        let (vars, path) = parse_env0(text);
        assert_eq!(path.as_deref(), Some("/a:/b"));
        assert_eq!(
            vars,
            vec![
                ("ANTHROPIC_BASE_URL".to_owned(), "http://x".to_owned()),
                ("MULTI".to_owned(), "a\nb".to_owned())
            ]
        );
    }
}
