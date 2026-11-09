//! The launch `cmux agent start` and `resume` give an agent's terminal, as
//! the daemon and the CLI read it.
//!
//! The CLI runs the launcher through the person's shell:
//! `<shell> -lc '<launcher> "$@"' cmux-agent <args>...` (cli/agent_start/launch.rs).
//! The daemon keeps that argv as the terminal's spawn command and marks the
//! terminal `extra.agent_start` in `session.snapshot`, so agent start can tell
//! its own panes from a person's without reading any process from the OS.

/// The `$0` of the launch script: the word that marks an agent start launch.
pub const ARG0: &str = "cmux-agent";

/// Whether `argv` is an agent start launch: `<shell> -lc <script> cmux-agent ...`.
pub fn is_agent_start_argv(_argv: &[String]) -> bool {
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(words: &[&str]) -> Vec<String> {
        words.iter().map(|word| (*word).to_owned()).collect()
    }

    /// W5-Q review (PR C): only the agent start launch shape is marked; a
    /// shell, a `pane run -- claude` or a script that only names `cmux-agent`
    /// elsewhere is not.
    #[test]
    fn w5q_only_the_agent_start_launch_is_an_agent_start() {
        assert!(is_agent_start_argv(&words(&[
            "/bin/zsh",
            "-lc",
            "sr2 claude \"$@\"",
            ARG0,
            "--resume",
            "x"
        ])));
        assert!(is_agent_start_argv(&words(&["/bin/sh", "-lc", "claude \"$@\"", ARG0])));
        assert!(!is_agent_start_argv(&words(&["/bin/zsh", "-l"])));
        assert!(!is_agent_start_argv(&words(&["claude"])));
        assert!(!is_agent_start_argv(&words(&["/bin/sh", "-c", "claude \"$@\"", ARG0])));
        assert!(!is_agent_start_argv(&words(&["/bin/sh", "-lc", ARG0, "other"])));
        assert!(!is_agent_start_argv(&[]));
    }
}
