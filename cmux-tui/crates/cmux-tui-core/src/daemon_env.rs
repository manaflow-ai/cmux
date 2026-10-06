//! Environment keys that the daemon owns in every terminal it spawns.
//!
//! A terminal-creating command may carry a caller `env` (for example the
//! app's login-shell environment). That env is merged over the daemon's own
//! environment, but a caller must never replace a value that the daemon owns:
//! with its own `CMUX_TUI_SOCKET`, `CMUX_TUI_TERMINAL_ID` or `CMUX_TUI_HOOK` a
//! terminal could talk to the daemon as another terminal or run another hook
//! helper. Every spawn path that merges a caller env uses [`merge_caller_env`],
//! so the daemon value always wins for each key in [`DAEMON_OWNED_ENV_KEYS`].
//!
//! The Ghostty shell-integration keys ([`INTEGRATION_OWNED_ENV_KEYS`]) belong
//! to whoever integrates the shell. When the daemon integrates the default
//! shell itself, it drops caller values for them
//! ([`strip_integration_owned`]). When the caller gave the program (a
//! frontend that resolved Ghostty's integration itself under
//! `terminal-frontend-shell-integration-v1`), the caller's values stay: they
//! give the caller no power beyond the argv, `ZDOTDIR` and `ENV` it already
//! chooses.
//!
//! `PATH` is not owned: a caller may supply it. The daemon keeps its
//! `claude` shim directory first on it ([`keep_shim_first_on_path`]).
//!
//! Warnings name the dropped key only; a caller value is never logged.

/// Keys the daemon always owns. A caller value for one of them is dropped.
pub const DAEMON_OWNED_ENV_KEYS: [&str; 12] = [
    "CMUX_TUI_SOCKET",
    "CMUX_BROWSER_HOST_SOCKET",
    "CMUX_MUX_SOCKET",
    "CMUX_TUI_HOOK",
    "CMUX_TUI_TERMINAL_ID",
    "CMUX_TUI_SESSION_ID",
    "CMUX_SIDEBAR",
    "CMUX_TUI_AGENT_BROWSER_PROVIDER",
    "AGENT_BROWSER_PROVIDER",
    "AGENT_BROWSER_PLUGINS",
    "AGENT_BROWSER_SESSION",
    "CMUX_TUI_CLAUDE_WRAPPER_ACTIVE",
];

/// Ghostty shell-integration keys. The daemon owns them only when it
/// integrates the default shell itself.
pub const INTEGRATION_OWNED_ENV_KEYS: [&str; 5] = [
    "GHOSTTY_ZSH_ZDOTDIR",
    "GHOSTTY_BASH_ENV",
    "GHOSTTY_BASH_INJECT",
    "GHOSTTY_BASH_UNEXPORT_HISTFILE",
    "GHOSTTY_SHELL_INTEGRATION_XDG_DIR",
];

/// The daemon's socket keys for every terminal it creates: `CMUX_TUI_SOCKET`
/// and `CMUX_MUX_SOCKET` (the daemon socket), and `CMUX_BROWSER_HOST_SOCKET`
/// when the daemon runs a browser host (`browser_host::terminal_env`).
pub fn add_daemon_socket_env(socket_path: &std::path::Path, options: &mut crate::SurfaceOptions) {
    let socket = socket_path.display().to_string();
    options.extra_env.push(("CMUX_TUI_SOCKET".into(), socket.clone()));
    options.extra_env.push(("CMUX_MUX_SOCKET".into(), socket));
    let has_host = crate::browser_host::host_binary_exists();
    options.extra_env.extend(crate::browser_host::terminal_env(socket_path, has_host));
}

/// Whether two environment keys name the same variable. Windows env keys
/// ignore case (the child gets one value for `Path` and `PATH`), so a caller
/// key that differs only in case must still match a daemon-owned key.
pub fn same_env_key(left: &str, right: &str) -> bool {
    if cfg!(windows) { left.eq_ignore_ascii_case(right) } else { left == right }
}

/// Whether the daemon always owns `key`.
pub fn is_daemon_owned(key: &str) -> bool {
    DAEMON_OWNED_ENV_KEYS.iter().any(|owned| same_env_key(owned, key))
}

/// Set `key` to `value` in `env`, replacing every earlier entry for `key`.
pub fn set_env(env: &mut Vec<(String, String)>, key: &str, value: &str) {
    env.retain(|(name, _)| !same_env_key(name, key));
    env.push((key.to_string(), value.to_string()));
}

/// Merge the caller's `env` over the daemon's `env`. A caller value for a
/// daemon-owned key is dropped, so the daemon value (or its absence) stays.
/// Every other caller key replaces the daemon's entry. Returns the names of
/// the dropped keys, without their values.
pub(crate) fn merge_caller_env(
    env: &mut Vec<(String, String)>,
    caller: &[(String, String)],
) -> Vec<String> {
    let mut dropped = Vec::new();
    for (key, value) in caller {
        if is_daemon_owned(key) {
            if !dropped.contains(key) {
                dropped.push(key.clone());
            }
            continue;
        }
        set_env(env, key, value);
    }
    dropped
}

/// Remove the integration-owned keys from `env` before the daemon integrates
/// the default shell. Returns the names of the removed keys.
pub(crate) fn strip_integration_owned(env: &mut Vec<(String, String)>) -> Vec<String> {
    let mut dropped = Vec::new();
    env.retain(|(key, _)| {
        let owned = INTEGRATION_OWNED_ENV_KEYS.iter().any(|owned| same_env_key(owned, key));
        if owned && !dropped.contains(key) {
            dropped.push(key.clone());
        }
        !owned
    });
    dropped
}

/// Put `shim_dir` first on the `PATH` in `env`, followed by the other
/// entries in their order, with no second copy of `shim_dir`. Does nothing
/// without a shim directory or a `PATH` entry.
pub(crate) fn keep_shim_first_on_path(env: &mut Vec<(String, String)>, shim_dir: Option<&str>) {
    let Some(shim_dir) = shim_dir.filter(|dir| !dir.is_empty()) else { return };
    let Some(path) =
        env.iter().rev().find(|(key, _)| same_env_key(key, "PATH")).map(|(_, value)| value.clone())
    else {
        return;
    };
    set_env(env, "PATH", &path_with_dir_first(&path, shim_dir));
}

fn path_with_dir_first(path: &str, dir: &str) -> String {
    let rest = path.split(PATH_SEPARATOR).filter(|entry| *entry != dir);
    let mut entries = vec![dir];
    if !path.is_empty() {
        entries.extend(rest);
    }
    entries.join(PATH_SEPARATOR)
}

const PATH_SEPARATOR: &str = if cfg!(windows) { ";" } else { ":" };

/// The warning for a dropped caller key. It names the key only: a caller
/// value can hold a secret and is never logged.
pub(crate) fn dropped_key_warning(key: &str) -> String {
    format!("cmux-tui: warning: dropped caller env key {key}: the daemon owns this key")
}

/// Log a warning line for each dropped key.
pub(crate) fn warn_dropped(keys: &[String]) {
    for key in keys {
        eprintln!("{}", dropped_key_warning(key));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pairs(entries: &[(&str, &str)]) -> Vec<(String, String)> {
        entries.iter().map(|(key, value)| ((*key).into(), (*value).into())).collect()
    }

    #[test]
    fn dropped_key_warning_names_the_key_and_never_the_value() {
        let mut env = pairs(&[("CMUX_TUI_SOCKET", "/daemon.sock")]);
        let caller = pairs(&[("CMUX_TUI_SOCKET", "caller-secret-value"), ("LANG", "C")]);
        let dropped = merge_caller_env(&mut env, &caller);
        assert_eq!(dropped, vec!["CMUX_TUI_SOCKET".to_string()]);
        let lines = dropped.iter().map(|key| dropped_key_warning(key)).collect::<Vec<_>>();
        assert_eq!(lines.len(), 1);
        assert!(lines[0].contains("CMUX_TUI_SOCKET"), "{}", lines[0]);
        assert!(!lines[0].contains("caller-secret-value"), "{}", lines[0]);
        assert!(!lines[0].contains("/daemon.sock"), "{}", lines[0]);
    }

    /// A caller value for a key the daemon does not own replaces the
    /// daemon's entry, and only one entry stays for the key.
    #[test]
    fn a_caller_value_for_an_unowned_key_replaces_the_daemon_value() {
        let mut env = pairs(&[("LANG", "C"), ("CMUX_TUI_HOOK", "/daemon/hook")]);
        let dropped = merge_caller_env(
            &mut env,
            &pairs(&[("LANG", "en_US.UTF-8"), ("CMUX_TUI_HOOK", "/caller/hook")]),
        );
        assert_eq!(dropped, vec!["CMUX_TUI_HOOK".to_string()]);
        assert_eq!(env, pairs(&[("CMUX_TUI_HOOK", "/daemon/hook"), ("LANG", "en_US.UTF-8")]));
    }

    /// Every integration-owned key is removed, and other keys stay.
    #[test]
    fn strip_integration_owned_removes_only_the_integration_keys() {
        let mut env = INTEGRATION_OWNED_ENV_KEYS
            .iter()
            .map(|key| ((*key).to_string(), "caller".to_string()))
            .collect::<Vec<_>>();
        env.push(("HOME".into(), "/home/me".into()));
        let mut removed = strip_integration_owned(&mut env);
        removed.sort();
        let mut expected = INTEGRATION_OWNED_ENV_KEYS.map(String::from).to_vec();
        expected.sort();
        assert_eq!(removed, expected);
        assert_eq!(env, pairs(&[("HOME", "/home/me")]));
    }

    /// Windows env keys ignore case, so a lowercase caller key is the same
    /// variable there and is dropped; elsewhere it is a different variable.
    #[test]
    fn a_daemon_owned_key_in_another_case_follows_the_platform_rule() {
        let mut env = pairs(&[("CMUX_TUI_SOCKET", "/daemon.sock")]);
        let dropped = merge_caller_env(&mut env, &pairs(&[("cmux_tui_socket", "/caller.sock")]));
        if cfg!(windows) {
            assert_eq!(dropped, vec!["cmux_tui_socket".to_string()]);
            assert_eq!(env, pairs(&[("CMUX_TUI_SOCKET", "/daemon.sock")]));
        } else {
            assert!(dropped.is_empty());
            assert_eq!(
                env,
                pairs(&[("CMUX_TUI_SOCKET", "/daemon.sock"), ("cmux_tui_socket", "/caller.sock")])
            );
        }
    }

    #[test]
    fn the_shim_stays_first_on_a_caller_path_without_a_second_copy() {
        let mut env = pairs(&[("PATH", "/shim:/usr/bin")]);
        merge_caller_env(&mut env, &pairs(&[("PATH", "/opt/caller/bin:/shim:/usr/bin")]));
        keep_shim_first_on_path(&mut env, Some("/shim"));
        assert_eq!(env, pairs(&[("PATH", "/shim:/opt/caller/bin:/usr/bin")]));
    }
}
