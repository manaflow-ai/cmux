//! A frontend's shell starts through login(1) on macOS, as Terminal.app,
//! Ghostty (classic cmux) and Rex start theirs.
//!
//! login(1) writes "Last login: ..." as soon as it runs, about 40 ms after
//! the spawn. Without it the first text of a new terminal is the prompt,
//! which waits for the user's startup files (90 ms on a fleet Mac with
//! oh-my-zsh, 200-260 ms on a typical laptop), so the new pane stayed blank
//! for that long. login(1) also records the session in utmpx and makes the
//! shell a login shell (`.zprofile` runs), as in those terminals.
//!
//! The daemon decides which launches get it: a terminal whose argv is the
//! frontend's shell (`terminal-frontend-shell-integration-v1`, or the
//! frontend's `shell_args`). It marks their env with [`MARKER`]. The terminal
//! host that spawns the PTY child removes the marker and runs [`wrap`] of the
//! argv; a daemon-local PTY only removes it (its close ends the direct child
//! alone). The recorded launch argv stays the shell's, so relaunch records,
//! `process-info`, the journal and the frontend see the same command as
//! before.
//!
//! As in those terminals, login(1) is the PTY child: it exits 0 whatever the
//! shell returns, so a wrapped shell's exit status is not reported, and it
//! runs setuid root, so process lookups go through the process table
//! (`platform::KinfoProc`). A launch whose `HOME` is not the account's home
//! (an isolated test or tool home) is not wrapped: login(1) would reset it.
//! Reopened and respawned shells start as before.
//!
//! The daemon started with `CMUX_TUI_NO_LOGIN_SHELL=1` marks nothing.

/// The env key that asks the spawner for a login(1) start. Never reaches the shell.
pub(crate) const MARKER: &str = "CMUX_TUI_LOGIN_SHELL";

/// Daemon env: `1` turns the login(1) start off.
const DISABLE: &str = "CMUX_TUI_NO_LOGIN_SHELL";

/// The script bash runs under login(1): the shell keeps its own `SHELL`
/// (login(1) sets the account's) and starts as a login shell (`-zsh`).
/// `$0` and `$@` are the shell's argv, so no argument is quoted into it.
#[cfg(target_os = "macos")]
const SCRIPT: &str = "export SHELL=\"$0\"; exec -l \"$0\" \"$@\"";

/// Marks `env` for a login(1) start of `argv`, the frontend's shell
/// (macOS only).
pub(crate) fn mark(env: &mut Vec<(String, String)>, argv: Option<&[String]>) {
    if !cfg!(target_os = "macos")
        || std::env::var_os(DISABLE).is_some_and(|value| value == "1")
        || !argv.is_some_and(crate::workspace_registry::relaunch_store::is_interactive_shell)
    {
        return;
    }
    env.retain(|(key, _)| key != MARKER);
    env.push((MARKER.to_owned(), "1".to_owned()));
}

/// Whether `key` is the marker: a spawner never passes it to the child.
pub(crate) fn is_marker(key: &str) -> bool {
    key == MARKER
}

/// The argv the spawner runs for `argv` with launch env `env`: the login(1)
/// start when `env` is marked and `argv` is an interactive shell, else None
/// (run `argv` itself).
pub(crate) fn wrap(argv: &[String], env: &[(String, String)]) -> Option<Vec<String>> {
    if !env.iter().any(|(key, value)| is_marker(key) && value == "1") {
        return None;
    }
    if !crate::workspace_registry::relaunch_store::is_interactive_shell(argv) {
        return None;
    }
    // The launch's HOME: its env's last value, else this process's.
    let home = env
        .iter()
        .rev()
        .find(|(key, _)| key == "HOME")
        .map(|(_, value)| value.clone())
        .or_else(|| std::env::var("HOME").ok());
    login_argv(argv, home.as_deref())
}

#[cfg(target_os = "macos")]
fn login_argv(argv: &[String], launch_home: Option<&str>) -> Option<Vec<String>> {
    const LOGIN: &str = "/usr/bin/login";
    if !std::path::Path::new(LOGIN).is_file() {
        return None;
    }
    let (user, home) = account()?;
    // login(1) sets HOME to the account's home even with -p.
    if launch_home
        .is_some_and(|launch_home| std::path::Path::new(launch_home) != std::path::Path::new(&home))
    {
        return None;
    }
    let mut wrapped = vec![LOGIN.to_owned()];
    // login(1) up to macOS 14.3 looked for .hushlogin in the working
    // directory, which `-l` leaves alone; Ghostty passes -q for it too.
    if std::path::Path::new(&home).join(".hushlogin").exists() {
        wrapped.push("-q".to_owned());
    }
    // -f: no password (a user starting a session as themselves); -l: keep the
    // working directory (bash's `exec -l` makes the login shell instead);
    // -p: keep the environment.
    let login = ["-flp", &user, "/bin/bash", "--noprofile", "--norc", "-c", SCRIPT];
    wrapped.extend(login.map(String::from));
    wrapped.extend(argv.iter().cloned());
    Some(wrapped)
}

#[cfg(not(target_os = "macos"))]
fn login_argv(_argv: &[String], _launch_home: Option<&str>) -> Option<Vec<String>> {
    None
}

/// This process's account name and home directory.
#[cfg(target_os = "macos")]
fn account() -> Option<(String, String)> {
    let mut buffer = vec![0 as libc::c_char; 4096];
    let mut entry = std::mem::MaybeUninit::<libc::passwd>::uninit();
    let mut result = std::ptr::null_mut();
    // SAFETY: getpwuid_r writes into `entry` and `buffer` only, and `result`
    // points at `entry` (or is null) when it returns.
    let status = unsafe {
        libc::getpwuid_r(
            libc::getuid(),
            entry.as_mut_ptr(),
            buffer.as_mut_ptr(),
            buffer.len(),
            &mut result,
        )
    };
    if status != 0 || result.is_null() {
        return None;
    }
    // SAFETY: getpwuid_r filled `entry`; its strings live in `buffer`.
    let entry = unsafe { entry.assume_init() };
    let text = |pointer: *const libc::c_char| {
        // SAFETY: a non-null passwd field is a NUL-terminated string in `buffer`.
        (!pointer.is_null())
            .then(|| unsafe { std::ffi::CStr::from_ptr(pointer) }.to_str().ok().map(str::to_owned))
            .flatten()
            .filter(|value| !value.is_empty())
    };
    Some((text(entry.pw_name)?, text(entry.pw_dir)?))
}
