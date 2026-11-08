//! Who may answer an agent's Cloud ask: the Start / Not now card an agent's
//! `cmux cloud start-session` shows in its own chat (the app's
//! `CloudStartSessionAsks`), answered from the card or from the CLI
//! (`cmux agents dialog answer`, the MCP `agents_dialog_answer`).
//!
//! - Not now is anyone's: it only takes the ask away.
//! - Start is the person's. The person is a CLI request (`origin: "cli"`) that
//!   names no agent session (their own terminal). An agent (an MCP request, a
//!   request naming its agent session, or one with no origin at all) may
//!   answer Start only when the person delegated it, with the person-only
//!   setting `cloud.agentsStartWithoutAsking`; with it on, an agent's start
//!   asks nothing in the first place.
//!
//! The caller rule trusts the caller's claim, as every caller rule of the
//! control socket does (the start itself treats a run naming no agent session
//! as a person's or a script's): it adds no way round the card that the start
//! did not already have.

use serde::{Deserialize, Serialize};

/// Who answers.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Caller {
    Person,
    Agent,
}

/// A control request's caller: the person only for `origin: "cli"` with no
/// agent session. No origin (a CLI from before it sent one), `mcp`, `script`,
/// `remote` or any other word, or a named agent session, is an agent's.
pub fn caller(origin: Option<&str>, agent_session: Option<&str>) -> Caller {
    let session = agent_session.is_some_and(|session| !session.trim().is_empty());
    if origin == Some("cli") && !session { Caller::Person } else { Caller::Agent }
}

/// The card's two answers.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Choice {
    #[serde(rename = "start")]
    Start,
    #[serde(rename = "notNow")]
    NotNow,
}

/// A CLI answer as a choice: the option's id or label (`start`, `notNow`,
/// `Not now`), or a permission-style `allow` / `deny`, ignoring case and
/// spaces, dashes and underscores. Anything else is no choice.
pub fn choice(selection: &str) -> Option<Choice> {
    let word: String = selection
        .chars()
        .filter(|c| !c.is_whitespace() && *c != '-' && *c != '_')
        .flat_map(char::to_lowercase)
        .collect();
    match word.as_str() {
        "start" | "allow" | "yes" => Some(Choice::Start),
        "notnow" | "deny" | "decline" | "no" => Some(Choice::NotNow),
        _ => None,
    }
}

/// Whether the caller's answer is taken.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Verdict {
    #[serde(rename = "allowed")]
    Allowed,
    /// Only the person may give this answer: at the card, or from their own terminal.
    #[serde(rename = "person-required")]
    PersonRequired,
}

/// Whether `caller` may answer `choice`, with the person's delegation
/// (`cloud.agentsStartWithoutAsking`) on or off.
pub fn answer(caller: Caller, delegated: bool, choice: Choice) -> Verdict {
    match (choice, caller) {
        (Choice::NotNow, _) | (Choice::Start, Caller::Person) => Verdict::Allowed,
        (Choice::Start, Caller::Agent) if delegated => Verdict::Allowed,
        (Choice::Start, Caller::Agent) => Verdict::PersonRequired,
    }
}

/// Whether an agent's start asks the person first: always, unless the person
/// delegated it.
pub fn agent_asks_first(delegated: bool) -> bool {
    !delegated
}

#[cfg(test)]
mod tests;
