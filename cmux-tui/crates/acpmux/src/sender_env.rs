//! The sender words lower modules read without the `acpmux send` CLI (`cli::sender`, which
//! re-exports them): the subagent mark acpmux's Bash hook sets, the word it may carry, and the
//! Japanese locale check.

/// Set by acpmux's Bash hook (`bg_hook.rs` [`crate::bg_hook::subagent_mark`]) on a command a
/// Claude Code subagent runs that may run the acpmux CLI (`bg_hook::may_run_acpmux`: not only one
/// that names acpmux; a wrapper, an alias or another path too): `TYPE:ID`, from the hook input's `agent_type` and
/// `agent_id`. A subagent runs in its lead's process and inherits the lead's whole environment
/// (`ACPMUX_SESSION_*`, `CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_CHILD_SESSION` too: read on a real
/// Claude Code 2.1.319, 2026-11-08), so nothing else tells its send from its lead's. A label
/// within the session its caller token proves, never a proof of its own.
pub const SUBAGENT_ENV: &str = "ACPMUX_CALLER_SUBAGENT";

/// A word the hook may put in a shell command unquoted, and the daemon in a provenance: 1 to 64
/// of `A-Za-z0-9._-`.
pub fn subagent_word(word: &str) -> bool {
    !word.is_empty()
        && word.len() <= 64
        && word.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

/// Whether `env`'s locale (LC_ALL, LC_MESSAGES, LANG, the first set) is Japanese, as
/// `cli/harness.rs` `add_help` reads it.
pub(crate) fn japanese(env: impl Fn(&str) -> Option<String>) -> bool {
    ["LC_ALL", "LC_MESSAGES", "LANG"]
        .iter()
        .find_map(|k| env(k).filter(|v| !v.is_empty()))
        .is_some_and(|locale| locale.to_ascii_lowercase().starts_with("ja"))
}
