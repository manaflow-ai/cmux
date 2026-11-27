//! What a person who is not the chat's owner may do in it: the verbs of a teammate, of a guest
//! invited to talk, and of a viewer. One source for every host that serves such a person:
//!
//! - cmux-tui's agent-session proxy (`cmux-tui-core` `server/agent_session_proxy.rs`) checks
//!   each bound teammate's or guest's frame against these lists, by its own verb names;
//! - acpmux serves a teammate who reaches a Cloud VM through the Cloud carrier
//!   (`acpmux` `server/carrier.rs`): its rule matrix maps each verb in [`TEAMMATE_VERBS`] to the
//!   acpmux methods that do the same thing, and a test there fails when a verb here has no row.
//!
//! A verb added here is a right given to every teammate on both hosts: it needs the review of
//! the acpmux owner and of the Cloud backend lane (`acpmux` `docs/carrier-roles.md`).

/// A teammate's verbs: the shared chat's own, never start, trust, media, children, permission,
/// typing or view, whatever the proxy forwards.
pub const TEAMMATE_VERBS: [&str; 6] = [
    "agent-session-attach",
    "agent-session-observe",
    "agent-session-events",
    "agent-session-prompt",
    "agent-session-cancel",
    "agent-session-detach",
];

/// A guest invited with `talk` (a signed-in account): watch and write (every prompt held for the
/// owner), its typing and view. A guest who joined by the link alone gets [`VIEWER_VERBS`].
/// Never cancel, permission, children or media. An attach is the guest's writable observe.
pub const GUEST_VERBS: [&str; 7] = [
    "agent-session-attach",
    "agent-session-observe",
    "agent-session-events",
    "agent-session-prompt",
    "agent-session-typing",
    "agent-session-view",
    "agent-session-detach",
];

/// An invitee with the `view` role: watch only (no prompt, no typing).
pub const VIEWER_VERBS: [&str; 5] = [
    "agent-session-attach",
    "agent-session-observe",
    "agent-session-events",
    "agent-session-view",
    "agent-session-detach",
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_viewer_and_a_guest_never_get_more_than_they_should() {
        // A viewer never writes; a guest never cancels; a teammate never sees typing or view.
        assert!(!VIEWER_VERBS.contains(&"agent-session-prompt"));
        assert!(!GUEST_VERBS.contains(&"agent-session-cancel"));
        assert!(!TEAMMATE_VERBS.contains(&"agent-session-typing"));
        for verbs in [&TEAMMATE_VERBS[..], &GUEST_VERBS[..], &VIEWER_VERBS[..]] {
            assert!(verbs.iter().all(|v| v.starts_with("agent-session-")));
            assert!(!verbs.iter().any(|v| v.contains("permission") || v.contains("start")));
        }
    }
}
