//! The session host's exact command line and environment, pure.
//!
//! Must stay equal to `cmuxTuiDaemonCommand()` in
//! `web/services/vms/drivers/cmuxTuiDaemon.ts` and to `start_daemon` in
//! `cmux-devbox-boot`: the driver's probes read `/proc/<pid>/cmdline`,
//! `comm` and `environ` of this process, and a Cloud machine upgrades the
//! session host in place under whatever supervisor started it
//! (docs/cloud-guest-upgrades.md). The shell version `exec`s the binary
//! after `setpriv`, so the session host is the supervisor's direct child;
//! the agent spawns it the same way without a shell.

use std::path::{Path, PathBuf};

/// The session name every Cloud machine uses.
pub const SESSION: &str = "cloud";
/// `CMUX_TUI_DEFAULT_REMOTE_WS_BIND`.
pub const DEFAULT_REMOTE_WS_BIND: &str = "0.0.0.0:1337";
/// argv[1] of a terminal host process (cmux-tui `__terminal-host`).
pub const TERMINAL_HOST_ARG: &str = "__terminal-host";
/// The work user of the image (`DEVBOX_WORK_USER`).
pub const WORK_USER: &str = "cmux";
pub const WORK_HOME: &str = "/home/cmux";
pub const ROOT_HOME: &str = "/root";
/// The first argv elements after the binary that identify the session host.
const IDENTITY_ARGS: [&str; 4] = ["server", "start", "--session", SESSION];

/// Which home and user the session host runs as (`daemon-layout` marker).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LayoutKind {
    /// The image's work user with passwordless sudo.
    User,
    /// A machine from an image baked before the work user existed.
    Root,
}

impl LayoutKind {
    pub fn as_str(self) -> &'static str {
        match self {
            LayoutKind::User => "user",
            LayoutKind::Root => "root",
        }
    }
}

/// The selected layout with resolved ids.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DaemonLayout {
    pub kind: LayoutKind,
    pub user: String,
    pub uid: u32,
    pub gid: u32,
    /// Supplementary groups (`setpriv --init-groups`).
    pub groups: Vec<u32>,
    pub home: PathBuf,
    pub bin: PathBuf,
}

/// The binary path for a daemon home (`cmuxTuiBinaryPath`).
pub fn binary_path(home: &Path) -> PathBuf {
    home.join(".cmux/bin/cmux-tui")
}

/// Everything needed to spawn the session host.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DaemonSpec {
    pub program: PathBuf,
    pub args: Vec<String>,
    pub cwd: PathBuf,
    /// Set on top of the agent's own environment, in this order.
    pub set_env: Vec<(String, String)>,
    /// Removed from the inherited environment.
    pub remove_env: Vec<&'static str>,
    pub uid: u32,
    pub gid: u32,
    pub groups: Vec<u32>,
}

/// `$(cat /etc/cmux/ghostty-version 2>/dev/null)`: the file with trailing
/// newlines removed; empty when absent.
pub fn ghostty_version(file: Option<&str>) -> String {
    file.map(|s| s.trim_end_matches('\n').to_owned()).unwrap_or_default()
}

/// The spec for `layout`. `template_bound_file` is `/run/cmux/bound`
/// (under the agent's root).
pub fn daemon_spec(
    layout: &DaemonLayout,
    ghostty_version: &str,
    remote_ws_bind: &str,
    template_bound_file: &Path,
) -> DaemonSpec {
    let mut set_env: Vec<(String, String)> = vec![
        // Warm template terminal (cmux-devbox-boot exports these; the
        // session host strips them from its own environment at start).
        ("CMUX_TUI_ADOPT_TEMPLATE_TERMINAL".into(), "1".into()),
        ("CMUX_TUI_TEMPLATE_BOUND_FILE".into(), template_bound_file.display().to_string()),
        ("CMUX_TUI_TEMPLATE_WORKSPACE_NAME".into(), "Cloud".into()),
        ("HOME".into(), layout.home.display().to_string()),
    ];
    if layout.kind == LayoutKind::User {
        set_env.push(("USER".into(), layout.user.clone()));
        set_env.push(("LOGNAME".into(), layout.user.clone()));
        set_env.push(("SHELL".into(), "/bin/bash".into()));
    }
    // CMUX_TUI_DAEMON_TERMINAL_ENV.
    set_env.push(("TERM".into(), "xterm-256color".into()));
    set_env.push(("TERM_PROGRAM".into(), "ghostty".into()));
    set_env.push(("TERM_PROGRAM_VERSION".into(), ghostty_version.to_owned()));
    let mut args: Vec<String> = IDENTITY_ARGS.iter().map(|s| (*s).to_owned()).collect();
    args.extend([
        "--remote-ws".to_owned(),
        remote_ws_bind.to_owned(),
        "--remote-ws-insecure-bind".to_owned(),
        "--remote-ws-trusted-carrier".to_owned(),
    ]);
    DaemonSpec {
        program: layout.bin.clone(),
        args,
        cwd: layout.home.clone(),
        set_env,
        remove_env: vec!["NOTIFY_SOCKET", "LISTEN_FDS", "LISTEN_PID", "LISTEN_FDNAMES"],
        uid: layout.uid,
        gid: layout.gid,
        groups: layout.groups.clone(),
    }
}

/// `argv` is a session host started from `bin`: an element equal to `bin`
/// at index 0 (the binary itself) or 1 (an interpreter running it),
/// followed by exactly `server start --session cloud`. Element-wise, never
/// a substring match of the joined command line.
pub fn is_session_host_argv(argv: &[String], bin: &Path) -> bool {
    let Some(bin) = bin.to_str() else { return false };
    (0..=1).any(|i| {
        argv.get(i).is_some_and(|a| a == bin)
            && argv.len() >= i + 1 + IDENTITY_ARGS.len()
            && argv[i + 1..i + 1 + IDENTITY_ARGS.len()]
                .iter()
                .zip(IDENTITY_ARGS)
                .all(|(a, b)| a == b)
    })
}

/// `argv` is a terminal host process: a `cmux-tui` binary (any build,
/// any path: hosts outlive in-place upgrades) with `__terminal-host` as
/// its first argument.
pub fn is_terminal_host_argv(argv: &[String]) -> bool {
    let binary = argv.first().and_then(|a| Path::new(a).file_name()).and_then(|n| n.to_str());
    binary == Some("cmux-tui") && argv.get(1).is_some_and(|a| a == TERMINAL_HOST_ARG)
}

/// Splits `/proc/<pid>/cmdline`.
pub fn split_cmdline(raw: &[u8]) -> Vec<String> {
    raw.split(|b| *b == 0)
        .filter(|part| !part.is_empty())
        .map(|part| String::from_utf8_lossy(part).into_owned())
        .collect()
}

/// `host_pid` of a terminal host record (`TerminalHostRecord`).
pub fn record_host_pid(json: &str) -> Option<u32> {
    let value: serde_json::Value = serde_json::from_str(json).ok()?;
    let pid = value.get("host_pid")?.as_u64()?;
    u32::try_from(pid).ok().filter(|pid| *pid > 1)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn layout(kind: LayoutKind) -> DaemonLayout {
        let (user, home) = match kind {
            LayoutKind::User => (WORK_USER, WORK_HOME),
            LayoutKind::Root => ("root", ROOT_HOME),
        };
        DaemonLayout {
            kind,
            user: user.to_owned(),
            uid: 1000,
            gid: 1000,
            groups: vec![1000, 27],
            home: PathBuf::from(home),
            bin: binary_path(Path::new(home)),
        }
    }

    #[test]
    fn user_layout_matches_the_shell_command() {
        let spec = daemon_spec(
            &layout(LayoutKind::User),
            "1.2.3",
            "[::]:1337",
            Path::new("/run/cmux/bound"),
        );
        assert_eq!(spec.program, PathBuf::from("/home/cmux/.cmux/bin/cmux-tui"));
        assert_eq!(
            spec.args,
            [
                "server",
                "start",
                "--session",
                "cloud",
                "--remote-ws",
                "[::]:1337",
                "--remote-ws-insecure-bind",
                "--remote-ws-trusted-carrier"
            ]
        );
        assert_eq!(spec.cwd, PathBuf::from("/home/cmux"));
        let env: Vec<String> = spec.set_env.iter().map(|(k, v)| format!("{k}={v}")).collect();
        assert_eq!(
            env,
            [
                "CMUX_TUI_ADOPT_TEMPLATE_TERMINAL=1",
                "CMUX_TUI_TEMPLATE_BOUND_FILE=/run/cmux/bound",
                "CMUX_TUI_TEMPLATE_WORKSPACE_NAME=Cloud",
                "HOME=/home/cmux",
                "USER=cmux",
                "LOGNAME=cmux",
                "SHELL=/bin/bash",
                "TERM=xterm-256color",
                "TERM_PROGRAM=ghostty",
                "TERM_PROGRAM_VERSION=1.2.3",
            ]
        );
        assert!(spec.remove_env.contains(&"NOTIFY_SOCKET"));
    }

    #[test]
    fn root_layout_sets_no_user_names() {
        let spec = daemon_spec(
            &layout(LayoutKind::Root),
            "",
            DEFAULT_REMOTE_WS_BIND,
            Path::new("/run/cmux/bound"),
        );
        assert!(spec.set_env.iter().all(|(k, _)| k != "USER" && k != "SHELL"));
        assert_eq!(spec.cwd, PathBuf::from("/root"));
        assert_eq!(ghostty_version(Some("1.3.0\n\n")), "1.3.0");
        assert_eq!(ghostty_version(None), "");
    }

    #[test]
    fn argv_matching_is_element_wise() {
        let bin = Path::new("/home/cmux/.cmux/bin/cmux-tui");
        let argv = |s: &str| split_cmdline(s.replace(' ', "\0").as_bytes());
        assert!(is_session_host_argv(
            &argv("/home/cmux/.cmux/bin/cmux-tui server start --session cloud --remote-ws x"),
            bin
        ));
        assert!(is_session_host_argv(
            &argv("/bin/sh /home/cmux/.cmux/bin/cmux-tui server start --session cloud"),
            bin
        ));
        assert!(!is_session_host_argv(
            &argv("sh -c /home/cmux/.cmux/bin/cmux-tui server start --session cloud"),
            bin
        ));
        assert!(!is_session_host_argv(
            &argv("/home/cmux/.cmux/bin/cmux-tui server start --session other"),
            bin
        ));
        assert!(!is_session_host_argv(
            &argv("/usr/bin/cmux-tui server start --session cloud"),
            bin
        ));
        assert!(is_terminal_host_argv(&argv(
            "/home/cmux/.cmux/bin/cmux-tui __terminal-host --bootstrap-stdio"
        )));
        assert!(!is_terminal_host_argv(&argv("grep __terminal-host")));
        assert!(!is_terminal_host_argv(&argv("/tmp/cmux-tui-evil server")));
    }

    #[test]
    fn record_pid_parses() {
        assert_eq!(record_host_pid(r#"{"record_version":1,"host_pid":4242}"#), Some(4242));
        assert_eq!(record_host_pid(r#"{"host_pid":0}"#), None);
        assert_eq!(record_host_pid("nope"), None);
    }
}
