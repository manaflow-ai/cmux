//! Which stderr line explains why an agent process closed.

/// Whether a stderr line can say why an agent process died: not blank, not a
/// stack frame, not a wrapper tag, and not a wrapper's own exit line such as
/// `subrouter: exit status 1` (the `sr claude proxy` harness prints that after
/// Claude's real error, e.g. "No conversation found with session ID: ...").
pub(super) fn explains_exit(line: &str) -> bool {
    if line.is_empty() || line.starts_with("at ") || line.starts_with("[SYSTEM_ERROR]") {
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
mod explains_exit_tests {
    use super::explains_exit;

    #[test]
    fn a_wrapper_exit_line_does_not_hide_the_real_error() {
        let tail = ["No conversation found with session ID: e140627e", "subrouter: exit status 1"];
        let last = tail.iter().rev().map(|l| l.trim()).find(|l| explains_exit(l));
        assert_eq!(last, Some("No conversation found with session ID: e140627e"));
    }

    #[test]
    fn ordinary_lines_still_explain_the_exit() {
        assert!(explains_exit("Error: exit status unknown to me"));
        assert!(explains_exit("panic: index out of range"));
        assert!(!explains_exit("at Object.<anonymous> (cli.js:1:1)"));
        assert!(!explains_exit("[SYSTEM_ERROR] boom"));
        assert!(!explains_exit(""));
    }
}
