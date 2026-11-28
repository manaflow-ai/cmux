//! An agent's Move to Cloud asks the person in its chat with a card (Move, Not now, Always) instead
//! of moving (`CloudMoveAsks` in the app). These are the card's rules: what an ask, a started or
//! ended move and each answer do. The app keeps the card, the grants and the words.

use serde::{Deserialize, Serialize};

/// A card button, the app's `Answer` raw values.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Answer {
    Move,
    NotNow,
    Always,
    AskFirst,
    Retry,
    Dismiss,
}

/// The card's look, the app's `AgentPaneToolCard.State`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum State {
    Ask,
    Working,
    Failed,
}

/// Which of the app's strings the card says.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Text {
    /// "Move this chat's folder … to Cloud?"
    Ask,
    Moving,
    MovingAlways,
    /// No move under this Cloud identity, or nothing ran.
    NoMove,
    UnfinishedShow,
    UnfinishedMove,
    /// The move's own failure, as the app has it.
    Failure,
}

/// A card to show.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Card {
    pub state: State,
    pub text: Text,
    pub answers: Vec<Answer>,
}

impl Card {
    fn new(state: State, text: Text, answers: &[Answer]) -> Card {
        Card { state, text, answers: answers.to_vec() }
    }
}

/// What a new ask reads: whether agents start moves without asking (`cloud.agentsStartWithoutAsking`),
/// whether the folder has an "Always" grant in this scope, and whether there is a scope (signed in).
#[derive(Clone, Copy, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Opening {
    pub delegated: bool,
    pub granted: bool,
    pub scoped: bool,
}

/// A new ask: start the move at once (`always` when a grant, not the setting, let it), or ask.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "do", rename_all = "camelCase")]
pub enum Opened {
    Start { always: bool },
    Show { card: Card },
}

pub fn open(opening: Opening) -> Opened {
    if opening.delegated || opening.granted {
        return Opened::Start { always: !opening.delegated };
    }
    let answers: &[Answer] = if opening.scoped {
        &[Answer::Move, Answer::NotNow, Answer::Always]
    } else {
        &[Answer::Move, Answer::NotNow]
    };
    Opened::Show { card: Card::new(State::Ask, Text::Ask, answers) }
}

/// The card of a move that started: Always's moves offer "Ask first next time".
pub fn started(always: bool) -> Card {
    if always {
        Card::new(State::Working, Text::MovingAlways, &[Answer::AskFirst])
    } else {
        Card::new(State::Working, Text::Moving, &[])
    }
}

/// The card of a move that stopped (None: it moved, and the card goes). A stop with a Retry offers it.
pub fn ended(failed: bool, retry: bool) -> Option<Card> {
    failed.then(|| {
        let answers: &[Answer] =
            if retry { &[Answer::Retry, Answer::Dismiss] } else { &[Answer::Dismiss] };
        Card::new(State::Failed, Text::Failure, answers)
    })
}

/// The launch offer of a move a quit or stop left unfinished: `show` when only its tab is left to open.
pub fn unfinished(show: bool) -> Card {
    let text = if show { Text::UnfinishedShow } else { Text::UnfinishedMove };
    Card::new(State::Failed, text, &[Answer::Retry, Answer::Dismiss])
}

/// The card a run that did nothing leaves (a refused or absent action).
pub fn refused(text: Text) -> Card {
    Card::new(State::Failed, text, &[Answer::Dismiss])
}

/// What an answer reads: the button, whether the card is a launch offer, whether the ask had a
/// scope and whether it is still the scope signed in now.
#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Answered {
    pub answer: Answer,
    #[serde(default)]
    pub offered: bool,
    #[serde(default)]
    pub scoped: bool,
    #[serde(default)]
    pub same_scope: bool,
}

/// What an answer does.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "do", rename_all = "camelCase")]
pub enum Reply {
    /// Show `card` (an old card after an account or team change: no move).
    Show {
        card: Card,
    },
    /// Start the move; with `grant`, remember the folder as Always first.
    Start {
        grant: bool,
    },
    /// Revoke the folder's Always (in the ask's scope) and keep moving, asking next time.
    AskFirst {
        card: Card,
    },
    /// Close the card; `remember` a launch offer's dismissal for its Retry.
    Close {
        remember: bool,
    },
    Nothing,
}

pub fn answer(answered: Answered) -> Reply {
    let Answered { answer, offered, scoped, same_scope } = answered;
    // Launch offers are a separate Retry flow with a pinned machine. Declining and "Ask first next
    // time" only take authority away.
    let grants = !matches!(answer, Answer::NotNow | Answer::Dismiss | Answer::AskFirst);
    if !offered && !same_scope && grants {
        return Reply::Show { card: refused(Text::NoMove) };
    }
    match answer {
        Answer::Move | Answer::Retry => Reply::Start { grant: false },
        Answer::Always if scoped => Reply::Start { grant: true },
        Answer::Always => Reply::Nothing,
        Answer::AskFirst => Reply::AskFirst { card: Card::new(State::Working, Text::Moving, &[]) },
        Answer::NotNow | Answer::Dismiss => Reply::Close { remember: offered },
    }
}

/// Whether an agent's ask may target `target` (`kind`, `id`): only its own chat tab, by its id or
/// resource id, or no target.
pub fn own_target(kind: Option<&str>, id: Option<&str>, tab: &str, resource: Option<&str>) -> bool {
    match kind {
        None => true,
        Some(kind) => kind == "tab" && id.is_some_and(|id| id == tab || Some(id) == resource),
    }
}

#[cfg(test)]
#[path = "asks_tests.rs"]
mod tests;
