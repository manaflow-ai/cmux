//! A chat moving to another machine, as the sidebar shows it (Leo, 2026-11-19: a visible move between
//! machines): the chat's row goes to the machine the moment the move starts, says the step, fills its bar,
//! and leaves when the chat's own row is there. The app keeps one [`Move`] per moving chat tab and asks
//! [`step`] what each event makes of it (op `cloud_move_chat_move`); `None` drops the move.

use serde::{Deserialize, Serialize};

/// One chat's move, as its sidebar row draws it.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Move {
    /// The workspace row the chat moves out of.
    pub workspace: Option<String>,
    /// The chat is that workspace's only tab: the row itself travels. Else it stays (the other tabs stay)
    /// and only shows the move.
    pub travels: bool,
    /// The machine it moves to (a daemon's machine id), once known.
    pub machine: Option<String>,
    /// The step and about how long is left (`moves::progress`).
    pub line: Option<String>,
    /// How far the move is, 0..=1, never lower than it showed; `None` until the first line.
    pub fraction: Option<f64>,
    /// The move is done and the travelled row waits on its machine for the workspace it left to close.
    pub landed: bool,
}

/// What happened to the move.
#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Event {
    /// A move starts (a sidebar drop, then its run; what came first stays).
    #[serde(rename_all = "camelCase")]
    Begin { workspace: Option<String>, travels: bool, machine: Option<String> },
    /// The run picked the machine.
    Reach { machine: String },
    /// A new progress line.
    Show { line: String, fraction: Option<f64> },
    /// The run moved the chat.
    Landed,
    /// The run ended, done or not.
    End,
    /// The workspace the chat left is gone, or the landing's deadline passed.
    Left,
}

/// The move after `event`; `None` drops it (the row is the chat's own again).
pub fn step(prior: Option<Move>, event: Event) -> Option<Move> {
    match event {
        Event::Begin { workspace, travels, machine } => {
            // A landed move is over: a new move of the same tab starts afresh.
            let mut next = prior.filter(|prior| !prior.landed).unwrap_or_default();
            if next.workspace.is_none() && workspace.is_some() {
                (next.workspace, next.travels) = (workspace, travels);
            }
            next.machine = machine.or(next.machine);
            Some(next)
        }
        Event::Reach { machine } => prior.map(|prior| Move { machine: Some(machine), ..prior }),
        Event::Show { line, fraction } => prior.map(|prior| {
            let fraction = match (prior.fraction, fraction) {
                (shown, Some(fraction)) => Some(shown.unwrap_or(0.0).max(fraction.clamp(0.0, 1.0))),
                (shown, None) => shown,
            };
            Move { line: Some(line), fraction, ..prior }
        }),
        // Only a row that travelled waits for its chat's own row; one that stayed is the chat's own already.
        Event::Landed => prior
            .filter(|prior| prior.travels && prior.workspace.is_some())
            .map(|prior| Move { landed: true, ..prior }),
        Event::End => prior.filter(|prior| prior.landed),
        Event::Left => None,
    }
}

#[cfg(test)]
mod tests;
