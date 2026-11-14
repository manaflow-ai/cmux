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

/// The shell flag of the launch: a login shell (`-l`) runs the script (`-c`).
pub const SHELL_FLAG: &str = "-lc";

/// Whether `argv` is an agent start launch: `<shell> -lc <script> cmux-agent ...`.
pub fn is_agent_start_argv(argv: &[String]) -> bool {
    matches!(argv, [_, flag, _, arg0, ..] if flag == SHELL_FLAG && arg0 == ARG0)
}

#[cfg(test)]
mod tests;
