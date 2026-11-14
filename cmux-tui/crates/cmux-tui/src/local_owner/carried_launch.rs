//! What a `server restart` starts the next owner with (cmux-ad i3): the
//! launch flags and the launch environment of the owner it stops. Without
//! them the new owner of a session started by an interactive client
//! (`--term`, `--owner-host-fg/bg` from its terminal probe) gave every new
//! terminal another TERM and default colors, and an app's owner lost its
//! apps directories and Chief brains.
//!
//! The old owner's argv and environment are read once from the OS
//! (`/proc/<pid>/cmdline` and `environ` on Linux, `KERN_PROCARGS2` on macOS)
//! before it is stopped, and only when that process belongs to this
//! effective user (Linux shows any user's cmdline, so this checks the owner
//! of `/proc/<pid>`; macOS refuses another user's arguments itself). Only the flags and
//! environment keys of the detached owner's own launch contract
//! ([`super::spawn_detached_owner`]) are carried; anything else on the old
//! argv, and every other variable, is not.

use std::ffi::OsString;
use std::path::PathBuf;
use std::time::Duration;

use super::{EXIT_WITH_PID_ARG, EnsureWebSocket, ExitWith, OwnerSpec};

/// The environment keys of the detached owner's launch contract.
const CARRIED_ENV: [&str; 5] = [
    "CMUX_TUI_CHIEF_TOOLS_SOCKET",
    cmux_tui_core::chief_brains::ENV,
    cmux_tui_core::first_party_dir::ENV,
    cmux_tui_core::first_party_dir::DIRS_ENV,
    // The settings file the owner was started on: a restart from a client
    // without the variable must not move the settings owner to the default
    // file (settings.snapshot `path`, plans/cmux-next/settings-react.md).
    cmux_config::CONFIG_OVERRIDE,
];

/// The settings file this client names for the owner it spawns: its own
/// `CMUX_NEXT_CONFIG_FILE`, absolute. A relative value is taken from this
/// client's directory once, here (and a leading `~` from its `HOME`, as
/// `cmux_config::config_path` reads it), so the owner and every owner a
/// `server restart` starts after it, from any directory, keep one file: the
/// restart carries the owner's value as it is. `None` without the variable
/// or with an empty one, which means unset (`cmux_config::config_path`).
fn own_settings_file() -> Option<PathBuf> {
    std::env::var_os(cmux_config::CONFIG_OVERRIDE).filter(|value| !value.is_empty())?;
    let path = cmux_config::config_path();
    Some(std::path::absolute(&path).unwrap_or(path))
}

/// The launch environment of the owner this client starts, in the order to
/// set it: the values a restart carried, then this client's own settings
/// file, which wins over a carried one and goes to the owner absolute
/// ([`own_settings_file`]).
pub(super) fn launch_env(carried: &[(String, String)]) -> Vec<(OsString, OsString)> {
    let mut env: Vec<(OsString, OsString)> =
        carried.iter().map(|(key, value)| (key.into(), value.into())).collect();
    if let Some(file) = own_settings_file() {
        env.push((cmux_config::CONFIG_OVERRIDE.into(), file.into_os_string()));
    }
    env
}

/// The launch of a running owner that the next owner repeats.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct CarriedLaunch {
    pub state: Option<PathBuf>,
    pub term: Option<String>,
    pub host_colors: Option<cmux_tui_core::DefaultColors>,
    pub terminal_reap_grace: Option<Duration>,
    pub exit_with_pid: Option<ExitWith>,
    pub websocket: Option<EnsureWebSocket>,
    /// Values of [`CARRIED_ENV`] keys the old owner was started with.
    pub env: Vec<(String, String)>,
}

impl CarriedLaunch {
    /// The launch of owner `pid`; empty when the OS does not say (another
    /// user's process, a platform without the call) or `pid` is no headless
    /// owner.
    pub(crate) fn of_owner(pid: u32) -> Self {
        if !Self::is_own_process(pid) {
            return Self::default();
        }
        cmux_tui_core::platform::process_launch(pid, &CARRIED_ENV)
            .map(|mut launch| {
                // A settings file this client names itself wins, like its
                // own flags: the owner it spawns gets that one
                // ([`own_settings_file`]). An empty value names no file, so
                // the carried one stays.
                if own_settings_file().is_some() {
                    launch.env.retain(|(key, _)| key != cmux_config::CONFIG_OVERRIDE);
                }
                Self::from_launch(&launch.argv, launch.env)
            })
            .unwrap_or_default()
    }

    /// Whether `pid` runs as this effective user (Linux; elsewhere the
    /// platform call refuses another user's process by itself).
    fn is_own_process(pid: u32) -> bool {
        #[cfg(target_os = "linux")]
        {
            use std::os::unix::fs::MetadataExt;
            // SAFETY: geteuid has no preconditions and cannot fail.
            let euid = unsafe { libc::geteuid() };
            std::fs::metadata(format!("/proc/{pid}")).is_ok_and(|proc| proc.uid() == euid)
        }
        #[cfg(not(target_os = "linux"))]
        {
            let _ = pid;
            true
        }
    }

    /// The carried part of an owner's `argv` (program first) and `env`.
    /// A flag the owner would refuse is left out, never guessed: a value
    /// that is missing or is itself a flag (an empty argument the OS
    /// listing dropped) leaves its flag out and is read as the next flag.
    pub(crate) fn from_launch(argv: &[String], env: Vec<(String, String)>) -> Self {
        let mut carried = Self::default();
        if !argv.iter().skip(1).any(|arg| arg == "--headless") {
            return carried;
        }
        let mut colors = cmux_tui_core::DefaultColors::default();
        let (mut listener, mut origins) = (false, Vec::new());
        let mut args = argv.iter().skip(1).peekable();
        while let Some(arg) = args.next() {
            let flag = arg.as_str();
            let takes_value = matches!(
                flag,
                "--state"
                    | "--term"
                    | "--owner-host-fg"
                    | "--owner-host-bg"
                    | "--terminal-reap-grace-seconds"
                    | "--ws"
                    | "--ws-allow-origin"
            ) || flag == EXIT_WITH_PID_ARG;
            if !takes_value {
                continue;
            }
            let Some(value) = args.next_if(|value| !value.starts_with("--")) else { continue };
            match flag {
                "--state" => carried.state = Some(PathBuf::from(value)),
                "--term" => carried.term = Some(value.clone()),
                "--owner-host-fg" => colors.fg = crate::parse_owner_host_color(flag, value).ok(),
                "--owner-host-bg" => colors.bg = crate::parse_owner_host_color(flag, value).ok(),
                "--terminal-reap-grace-seconds" => {
                    carried.terminal_reap_grace = value.parse().ok().map(Duration::from_secs);
                }
                // A new loopback listener (its credential is minted again);
                // origins without a listener are no listener.
                "--ws" => listener = true,
                "--ws-allow-origin" => origins.push(value.clone()),
                _ => carried.exit_with_pid = super::parse_owner_exit_with(value).ok(),
            }
        }
        carried.websocket = listener.then_some(EnsureWebSocket { allow_origins: origins });
        if colors.fg.is_some() || colors.bg.is_some() {
            carried.host_colors = Some(colors);
        }
        carried.env = env;
        carried
    }

    /// Fills what `spec` does not set itself; the caller's own values win.
    pub(crate) fn apply(self, spec: &mut OwnerSpec) {
        spec.state = spec.state.take().or(self.state);
        spec.term = spec.term.take().or(self.term);
        spec.initial_host_colors = spec.initial_host_colors.take().or(self.host_colors);
        spec.terminal_reap_grace = spec.terminal_reap_grace.take().or(self.terminal_reap_grace);
        spec.exit_with_pid = spec.exit_with_pid.take().or(self.exit_with_pid);
        spec.websocket = spec.websocket.take().or(self.websocket);
        for (key, value) in self.env {
            match key.as_str() {
                "CMUX_TUI_CHIEF_TOOLS_SOCKET" => {
                    spec.chief_tools_socket = spec.chief_tools_socket.take().or(Some(value.into()));
                }
                key if key == cmux_tui_core::chief_brains::ENV => {
                    spec.chief_brains = spec.chief_brains.take().or(Some(value));
                }
                _ => spec.carried_env.push((key, value)),
            }
        }
    }

    /// The carried flags as the new owner gets them, for the restart's report.
    pub(crate) fn flags(&self) -> Vec<String> {
        let mut flags = Vec::new();
        if let Some(state) = &self.state {
            flags.extend(["--state".into(), state.display().to_string()]);
        }
        if let Some(term) = &self.term {
            flags.extend(["--term".into(), term.clone()]);
        }
        let hex =
            |color: cmux_tui_core::Rgb| format!("#{:02x}{:02x}{:02x}", color.r, color.g, color.b);
        if let Some(colors) = self.host_colors {
            if let Some(fg) = colors.fg {
                flags.extend(["--owner-host-fg".into(), hex(fg)]);
            }
            if let Some(bg) = colors.bg {
                flags.extend(["--owner-host-bg".into(), hex(bg)]);
            }
        }
        if let Some(grace) = self.terminal_reap_grace {
            flags.extend(["--terminal-reap-grace-seconds".into(), grace.as_secs().to_string()]);
        }
        if let Some(exit_with) = self.exit_with_pid {
            flags.extend([EXIT_WITH_PID_ARG.into(), exit_with.arg()]);
        }
        if self.websocket.is_some() {
            flags.push("--ws".into());
        }
        flags.extend(self.env.iter().map(|(key, _)| format!("env {key}")));
        flags
    }
}

#[cfg(test)]
mod tests;
