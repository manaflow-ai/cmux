//! Session-engine verbs that also run under plain `cmux` (`cmux last coord`
//! is `cmux acp last coord`). Every acpmux verb runs as `cmux acp VERB` and most
//! as `cmux agent VERB`; the words in [`MOVED`] are about agent sessions, name
//! nothing cmux has a scope, shorthand, classic verb or app action for, and so
//! read the same at the top level.
//!
//! Stayed under `cmux acp` / `cmux agent` only ([`STAYED`]): a word cmux already
//! owns (`ls` is tmux's list-sessions, `send` the classic terminal send, `new`
//! and `run` cmux's own, `attach`, `open`, `task`, `history`, `skill`,
//! `machine`, `daemon`, `session`, `inbox`), or a word too generic to mean an
//! agent session at the top level (`search`, `process`, `gc`, `worktree`,
//! `group`, `preset`, `defaults`, `web`, `desktop`). `harness`, `chats` and
//! `board` were plain `cmux` words already.

/// Moved: plain `cmux VERB …` runs the session engine.
pub(crate) const MOVED: &[&str] = &[
    "last",
    "wait",
    "pending",
    "notices",
    "who-else",
    "resolve",
    "ledger",
    "watch",
    "bg",
    "dispatch",
    "race",
    "ensure",
    "retry",
    "deliver",
    "briefs",
    "archive",
    "unarchive",
    "bead",
    "continue",
    "compare",
    "register",
    "forum",
    "bridge",
    "resume-here",
];

/// Stayed: engine verbs that run only as `cmux acp VERB` (and `cmux agent VERB`).
#[cfg_attr(not(test), allow(dead_code))]
pub(crate) const STAYED: &[&str] = &[
    "ls", "send", "new", "run", "attach", "open", "open-tab", "task", "history", "skill",
    "machine", "daemon", "session", "inbox", "search", "process", "gc", "worktree", "group",
    "preset", "defaults", "web", "desktop",
];

/// Whether `raw_args` starts with a moved engine verb (`cmux last coord`).
pub(crate) fn requested(raw_args: &[String]) -> bool {
    raw_args.first().is_some_and(|head| MOVED.contains(&head.as_str()))
}

#[cfg(test)]
mod tests {
    use super::super::{Surface, internal, listed_scope, shorthand};
    use super::*;

    #[test]
    fn every_listed_word_is_an_engine_verb() {
        for word in MOVED.iter().chain(STAYED) {
            assert!(acpmux::cli::entry::is_command(word), "{word} is not an acpmux verb");
        }
        for word in MOVED {
            assert!(!STAYED.contains(word), "{word} is both moved and stayed");
        }
    }

    /// A moved word must not shadow anything plain `cmux` already means.
    #[test]
    fn moved_words_name_nothing_cmux_owns() {
        let root_help = crate::localization::catalog().local_server.cmux_root_help;
        for word in MOVED {
            assert!(!Surface::Cmux.accepts(word), "{word} is a cmux scope");
            assert!(!Surface::CmuxTui.accepts(word), "{word} is a cmux-tui scope");
            assert!(!listed_scope(root_help, word), "{word} is in cmux's root help");
            assert!(
                !super::super::app_action_help::has_section(word),
                "{word} is an app action scope"
            );
            assert!(
                internal::classic_verbs::resource_command(word).is_none(),
                "{word} is a classic verb"
            );
            let normalized =
                shorthand::normalize(&[(*word).to_owned()], Surface::Cmux).unwrap_or_default();
            assert_eq!(normalized, vec![(*word).to_owned()], "{word} is a tmux shorthand");
        }
    }

    #[test]
    fn moved_words_route_to_the_engine_with_the_verb_first() {
        let args: Vec<String> = ["last", "coord"].map(String::from).to_vec();
        assert!(requested(&args));
        assert_eq!(
            super::super::acp_scope_args(&args),
            ["last", "coord"].map(std::ffi::OsString::from)
        );
        assert!(!requested(&["ls".to_owned()]));
        assert!(!requested(&["send".to_owned(), "x".to_owned()]));
        assert!(!requested(&[]));
    }
}
