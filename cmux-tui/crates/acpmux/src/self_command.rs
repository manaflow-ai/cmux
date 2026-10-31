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

use std::ffi::{OsStr, OsString};
use std::path::PathBuf;

/// `<exe> [prefix…] <words…>`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SelfCommand {
    pub exe: PathBuf,
    pub prefix: Vec<OsString>,
}

impl SelfCommand {
    /// This process's own binary, with the prefix its daemon starts with.
    pub fn current() -> std::io::Result<Self> {
        Ok(Self::new(std::env::current_exe()?, crate::daemon::daemon_prefix()))
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

    /// A command that runs subcommand `words` of this binary.
    pub fn command<S: AsRef<OsStr>>(&self, words: &[S]) -> std::process::Command {
        let mut command = std::process::Command::new(&self.exe);
        command.args(self.args(words));
        command
    }

    /// [`Self::command`] for tokio.
    pub fn tokio_command<S: AsRef<OsStr>>(&self, words: &[S]) -> tokio::process::Command {
        let mut command = tokio::process::Command::new(&self.exe);
        command.args(self.args(words));
        command
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
}
