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

/// Claude Code's line when `--resume <id>` names a conversation its store does not hold.
const NO_CONVERSATION: &str = "No conversation found with session ID:";

/// Whether the agent's last stderr lines say Claude has no stored conversation `sid`: its
/// `--resume` of the chat's own conversation failed, so a resume can never succeed again.
pub(super) fn no_conversation_found(tail: &[String], sid: &str) -> bool {
    !sid.is_empty()
        && tail.iter().any(|line| {
            line.trim()
                .strip_prefix(NO_CONVERSATION)
                .is_some_and(|rest| rest.trim() == sid)
        })
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
    use super::{explains_exit, no_conversation_found};

    /// 2026-11-03, "iOS composer shortcuts": every resume of a transcript reduced to metadata
    /// failed with this line; only the chat's own id marks its conversation lost.
    #[test]
    fn no_conversation_found_names_only_the_chats_own_conversation() {
        let sid = "01a18f31-1961-72d1-899f-fe573366dd3f";
        let tail = vec![format!("No conversation found with session ID: {sid}")];
        assert!(no_conversation_found(&tail, sid));
        assert!(!no_conversation_found(&tail, "01a18f31-0000-0000-0000-000000000000"));
        assert!(!no_conversation_found(&tail, ""));
        let other = vec!["proxy down".to_owned(), "subrouter: exit status 1".to_owned()];
        assert!(!no_conversation_found(&other, sid));
    }

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
