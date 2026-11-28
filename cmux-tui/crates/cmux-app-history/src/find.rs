//! Find in Directory (`FindSectionModel.swift`): what a typed query searches
//! and the state a ripgrep outcome leaves.

use serde::{Deserialize, Serialize};

/// The query ripgrep runs: trimmed; nil when blank or without a root (the section goes idle).
pub fn query(text: &str, has_root: bool) -> Option<String> {
    let trimmed = text.trim();
    (has_root && !trimmed.is_empty()).then(|| trimmed.to_string())
}

/// How a search ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum Outcome {
    /// No ripgrep on this Mac.
    Missing,
    Failed {
        status: i32,
    },
    Matches {
        limited: bool,
    },
}

/// The section's state after an outcome: results kept only for matches.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "state")]
pub enum State {
    Done {
        limited: bool,
    },
    /// The app shows `FindInDirectoryStrings.ripgrepMissing`.
    RipgrepMissing,
    /// The app shows `FindInDirectoryStrings.ripgrepExited(status)`.
    RipgrepExited {
        status: i32,
    },
}

pub fn state(outcome: Outcome) -> State {
    match outcome {
        Outcome::Missing => State::RipgrepMissing,
        Outcome::Failed { status } => State::RipgrepExited { status },
        Outcome::Matches { limited } => State::Done { limited },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_blank_query_or_no_root_is_idle() {
        assert_eq!(query("  needle \n", true).as_deref(), Some("needle"));
        assert_eq!(query(" \t\n", true), None);
        assert_eq!(query("needle", false), None);
    }

    #[test]
    fn outcomes_map_to_states() {
        assert_eq!(state(Outcome::Missing), State::RipgrepMissing);
        assert_eq!(state(Outcome::Failed { status: 2 }), State::RipgrepExited { status: 2 });
        assert_eq!(state(Outcome::Matches { limited: true }), State::Done { limited: true });
    }
}
