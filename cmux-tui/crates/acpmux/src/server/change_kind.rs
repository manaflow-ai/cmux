//! Part of the server; see `server/mod.rs`. Which mux records a watcher
//! hears of as `_acpmux/session_changed`, and the `kind` each is sent as.

/// The `kind` a mux record is sent as, or None when watchers do not hear of it.
pub(super) fn session_change_kind(record_kind: &str) -> Option<&str> {
    Some(match record_kind {
        "status"
        | "created"
        | "user_message"
        | "turn_end"
        | "turn_error"
        | "renamed"
        | "titled"
        | "forked"
        | "imported"
        | "permission_request"
        | "permission_decision"
        | "permission_group"
        | "permission_chat_allowance"
        | "mode"
        | "model"
        | "config"
        | "policy"
        | "tools"
        | "rules"
        | "tags"
        | "turn_started"
        | "turn_result"
        | "git"
        | "subsession"
        | "watch_started"
        | "watch_taken_over"
        // The row's `retry` came or went (`hub/auto_resume.rs`).
        | "auto_resume_scheduled"
        | "auto_resume_restored"
        | "auto_resume_stopped"
        | "auto_resume_skipped"
        | "auto_resume_exhausted"
        // A turn the row showed `retryDeciding` for gets no retry.
        | "auto_resume_settled"
        // Work the session started runs past its turn, or ended (`hub/work_below.rs`).
        | "subagents_working"
        // How many subagents run changed, or a background command started or ended: the
        // summary's `subagentsRunning`, `subagentNames` and `commandsRunning` (`hub/views.rs`).
        | "subagents_running"
        | "process_update"
        // What its harness spent and holds, read after a turn (`hub/usage_view.rs`).
        | "usage_stats" => record_kind,
        // A Stop's turn reads `stopping`, or a stuck chat works again: the row's `state`.
        "stopping" | "stop_escalated" | "stop_restarted" | "unstuck" => "status",
        k if k == "dequeued" || k.starts_with("queue") => "queue",
        "permission_auto" => "permission_resolved",
        "permission_reissued" => "permission_request",
        "available_commands_update" => "commands",
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    #[test]
    fn retry_restore_publishes_a_session_change() {
        assert_eq!(
            super::session_change_kind("auto_resume_restored"),
            Some("auto_resume_restored")
        );
        assert_eq!(super::session_change_kind("auto_resume_stopped"), Some("auto_resume_stopped"));
    }

    /// The hover card's live counts reach watchers as the summary changes.
    #[test]
    fn running_work_changes_publish_a_session_change() {
        assert_eq!(super::session_change_kind("subagents_running"), Some("subagents_running"));
        assert_eq!(super::session_change_kind("process_update"), Some("process_update"));
    }
}
