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
mod explains_exit_tests {
    use super::explains_exit;

    #[test]
    fn a_wrapper_exit_line_does_not_hide_the_real_error() {
        let tail = ["No conversation found with session ID: e140627e", "subrouter: exit status 1"];
        let last = tail.iter().rev().map(|l| l.trim()).find(|l| explains_exit(l));
        assert_eq!(last, Some("No conversation found with session ID: e140627e"));
    }

    /// acp-chief-issues.md #3: sr2 prints its route banner at every start; a
    /// start that died after it must quote the real error, never the banner.
    #[test]
    fn the_sr2_route_banner_does_not_explain_the_exit() {
        let tail = [
            "claude2: read rotation: context deadline exceeded",
            "sr2 route: profile settings name http://127.0.0.1:1; managed settings override it with the sr2 gateway",
            "sr2 route: gateway http://sr2-gateway.tail137216.ts.net:4016",
        ];
        let last = tail.iter().rev().map(|l| l.trim()).find(|l| explains_exit(l));
        assert_eq!(last, Some("claude2: read rotation: context deadline exceeded"));
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
