//! This acpmux binary as a command: its executable and the arguments that
//! reach acpmux's own subcommands in it.
//!
//! Standalone, acpmux is `acpmux <word>`. Inside the cmux multicall binary it
//! is `cmux-tui acp <word>`: cmux-tui runs acpmux only when argv0 is `acpmux`
//! or the first argument is `acp` (`cmux-tui/src/main.rs`). On Linux
//! `current_exe` resolves an `acpmux` link to `cmux-tui`, so a process that
//! starts itself again must put the prefix ([`crate::daemon::daemon_prefix`],
//! set once by the entry point) before the word. Every place that starts this
//! binary with an acpmux subcommand goes through [`SelfCommand`].
//!
//! Once an update replaces the file a long-lived daemon runs from, Linux's
//! `current_exe` is `PATH (deleted)` and PATH is gone or holds another build.
//! [`SelfCommand::current`] names PATH, and its commands exec this build from
//! the open inode ([`program`]).

use std::ffi::{OsStr, OsString};
use std::path::{Path, PathBuf};

/// `<exe> [prefix…] <words…>`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SelfCommand {
    pub exe: PathBuf,
    pub prefix: Vec<OsString>,
}

impl SelfCommand {
    /// This process's own binary, with the prefix its daemon starts with.
    /// `exe` is the path without the ` (deleted)` Linux adds once an update
    /// replaced the file: a config or argv written for another process names
    /// the installed path, and [`Self::command`] still starts this build.
    pub fn current() -> std::io::Result<Self> {
        Ok(Self::new(undeleted(std::env::current_exe()?), crate::daemon::daemon_prefix()))
    }

    pub fn new(exe: PathBuf, prefix: Vec<OsString>) -> Self {
        Self { exe, prefix }
    }

    /// The arguments for subcommand `words`: the prefix, then the words.
    pub fn args<S: AsRef<OsStr>>(&self, words: &[S]) -> Vec<OsString> {
        self.prefix.iter().cloned().chain(words.iter().map(|w| w.as_ref().to_owned())).collect()
    }

    /// [`Self::args`] as text, for a command line written into a config
    /// (an MCP server, a harness argv).
    pub fn args_lossy<S: AsRef<OsStr>>(&self, words: &[S]) -> Vec<String> {
        self.args(words).iter().map(|a| a.to_string_lossy().into_owned()).collect()
    }

    /// The program [`Self::command`] execs: [`program`] of `exe`.
    pub fn program(&self) -> PathBuf {
        program(&self.exe)
    }

    /// A command that runs subcommand `words` of this binary. For this
    /// process's own binary on Linux it execs `/proc/self/exe` with argv0
    /// `exe`, so a background-task runner, the router or an MCP server starts
    /// after an update replaced the file (huge-blue, 2026-11-01: `bg_start`
    /// failed with "start the task's runner: No such file or directory").
    pub fn command<S: AsRef<OsStr>>(&self, words: &[S]) -> std::process::Command {
        let program = self.program();
        let mut command = std::process::Command::new(&program);
        #[cfg(unix)]
        if program != self.exe {
            std::os::unix::process::CommandExt::arg0(&mut command, &self.exe);
        }
        command.args(self.args(words));
        command
    }

    /// [`Self::command`] for tokio.
    pub fn tokio_command<S: AsRef<OsStr>>(&self, words: &[S]) -> tokio::process::Command {
        tokio::process::Command::from(self.command(words))
    }
}

/// What to exec to run `exe`. On Linux, for this process's own binary, the
/// open inode `/proc/self/exe`: once an update replaces the file a long-lived
/// daemon runs from (`~/.local/bin/acpmux`, a Cloud VM's
/// `~/.cmux/bin/cmux-tui`), the path is gone or holds another build. The child
/// then runs the daemon's own build, as cmux-tui's terminal hosts do
/// (`self_exe_for_spawn`). The caller keeps argv0 the path: a cmux-tui copy
/// named `acpmux` runs as acpmux by that name. Any other binary is `exe`.
pub fn program(exe: &Path) -> PathBuf {
    let own = cfg!(target_os = "linux")
        && std::env::current_exe().is_ok_and(|current| undeleted(current) == exe);
    if own { PathBuf::from("/proc/self/exe") } else { exe.to_path_buf() }
}

/// `path` without the ` (deleted)` Linux appends to a replaced executable
/// (`current_exe`, `/proc/<pid>/exe`).
pub fn undeleted(path: PathBuf) -> PathBuf {
    match path.to_str().and_then(|p| p.strip_suffix(" (deleted)")) {
        Some(p) => PathBuf::from(p),
        None => path,
    }
}

#[cfg(test)]
pub(crate) use tests::both as test_commands;

#[cfg(test)]
mod tests {
    use super::SelfCommand;
    use std::ffi::OsString;
    use std::path::PathBuf;

    /// The two ways this binary runs: standalone and inside cmux-tui.
    pub(crate) fn both() -> [SelfCommand; 2] {
        [
            SelfCommand::new(PathBuf::from("/opt/cmux/bin/acpmux"), Vec::new()),
            SelfCommand::new(PathBuf::from("/opt/cmux/bin/cmux-tui"), vec![OsString::from("acp")]),
        ]
    }

    #[test]
    fn subcommands_follow_the_prefix() {
        let [standalone, tui] = both();
        assert_eq!(standalone.args(&["daemon", "run"]), ["daemon", "run"]);
        assert_eq!(tui.args(&["daemon", "run"]), ["acp", "daemon", "run"]);
        assert_eq!(tui.args_lossy::<&str>(&[]), ["acp"]);
        let command = tui.command(&["router", "serve"]);
        assert_eq!(command.get_program(), "/opt/cmux/bin/cmux-tui");
        let args: Vec<_> = command.get_args().collect();
        assert_eq!(args, ["acp", "router", "serve"]);
        let command = tui.tokio_command(&["subsession-mcp"]);
        let args: Vec<_> = command.as_std().get_args().collect();
        assert_eq!(args, ["acp", "subsession-mcp"]);
    }

    /// This process's own binary runs from the open inode on Linux, with
    /// argv0 the path; another binary runs as given.
    #[test]
    fn its_own_binary_runs_from_the_open_inode_on_linux() {
        let this = SelfCommand::current().expect("this binary");
        let exe = std::env::current_exe().expect("current exe");
        assert_eq!(this.exe, exe);
        let command = this.command(&["daemon", "run"]);
        if cfg!(target_os = "linux") {
            assert_eq!(command.get_program(), "/proc/self/exe");
        } else {
            assert_eq!(command.get_program(), exe);
        }
        let [standalone, _] = both();
        assert_eq!(standalone.program(), PathBuf::from("/opt/cmux/bin/acpmux"));
    }

    #[test]
    fn a_replaced_file_reads_as_its_path() {
        let path = "/home/cmux/.cmux/bin/cmux-tui";
        assert_eq!(super::undeleted(format!("{path} (deleted)").into()), PathBuf::from(path));
        assert_eq!(super::undeleted(path.into()), PathBuf::from(path));
    }
}
