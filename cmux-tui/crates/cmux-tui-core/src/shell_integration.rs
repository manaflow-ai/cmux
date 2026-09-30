//! Launch description for the interactive shells cmux-tui starts.

/// An interactive shell launch.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShellLaunch {
    pub command: Vec<String>,
    pub env: Vec<(String, String)>,
}

/// The default interactive shell, launched as given.
pub fn integrate_default_shell(command: Vec<String>, extra_env: Vec<(String, String)>) -> ShellLaunch {
    ShellLaunch { command, env: extra_env }
}
