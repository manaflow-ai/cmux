//! Which stderr line explains why an agent process closed.

/// Whether a stderr line can say why an agent process died: not blank, not a
/// stack frame, not a wrapper tag or sr2's route banner, and not a wrapper's
/// own exit line such as
/// `subrouter: exit status 1` (the `sr claude proxy` harness prints that after
/// Claude's real error, e.g. "No conversation found with session ID: ...").
pub(super) fn explains_exit(line: &str) -> bool {
    if line.is_empty() || line.starts_with("at ") || line.starts_with("[SYSTEM_ERROR]") {
        return false;
    }
    // sr2 names its route at every start, before Claude runs: it says where
    // the harness went, never why it died.
    if line.starts_with("sr2 route:") {
        return false;
    }
    !is_wrapper_exit_line(line)
}

/// `<program>: exit status <n>`, as Go's `exec.ExitError` prints it.
fn is_wrapper_exit_line(line: &str) -> bool {
    let Some((program, rest)) = line.split_once(": exit status ") else {
        return false;
    };
    !program.is_empty()
        && !program.contains(char::is_whitespace)
        && !rest.is_empty()
        && rest.trim_start_matches('-').chars().all(|c| c.is_ascii_digit())
}

#[cfg(test)]
mod explains_exit_tests;
