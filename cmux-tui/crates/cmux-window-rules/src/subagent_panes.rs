//! The agent panes a chat's subagents open in (`chat.subagentPane`): one
//! tracker per source chat, opens one at a time, and the focus a click owes a
//! pane still opening. The app's `AgentSubagentPanes` keeps the tab keys it
//! remembers and runs the hooks (place, focus, watch the person); this is
//! the rest, a reducer over [`Panes`] the app holds between calls.
//!
//! - An open nobody asked for runs once per subagent, so a page built again
//!   never brings back a pane the person closed (Leo, 2026-11-07: "it opened
//!   up the side sub-agent chat again"). The person's own open shows it again.
//! - Opens run one at a time: a later one reads the column the earlier one's
//!   move made ([`crate::right_column`]), so it waits for that move.
//! - A click on a subagent whose pane is still opening without focus: the
//!   pane takes focus once it has opened, unless the person did something
//!   else first ([`Panes::user_acted`]) or [`FOCUS_BOUND_NS`] passed.
//!
//! Times are nanoseconds on one monotonic clock the app picks.

use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

/// How long an owed focus waits for its pane: one that lands later takes no
/// focus, as the person has moved on (an open can take 20 s). Two seconds.
pub const FOCUS_BOUND_NS: i64 = 2_000_000_000;

/// A waiting request: the subagent, whether it takes focus, the chat tab that
/// asked, and when focus was asked for. `asked`: the person asked for this
/// pane; it stays true when the focus lapses, so their open still shows a
/// closed subagent.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Request {
    pub agent: String,
    pub focus: bool,
    pub chat: String,
    pub at: i64,
    pub asked: bool,
}

/// A focus owed to subagent `agent`'s running open, asked for at `at`.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Owed {
    pub agent: String,
    pub at: i64,
}

/// One source chat's tracker.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Panes {
    /// Every subagent this chat showed a pane for.
    pub shown: BTreeSet<String>,
    /// The subagent whose open runs.
    pub opening: Option<String>,
    /// The subagent whose open runs without focus but that the person asked
    /// to see meanwhile, and when.
    pub focus_once_open: Option<Owed>,
    pub queue: Vec<Request>,
    /// Whether the app watches for the person's next action.
    pub watching: bool,
}

/// What [`Panes::open`] tells the app to do.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Open {
    /// An open nobody asked for, of a subagent this chat already showed:
    /// nothing opens (`open` answers false).
    Skip,
    /// Another open runs: this one waits its turn (`open` answers true).
    Wait,
    /// Place the pane now ([`crate::right_column::decide`]).
    Place,
}

/// The app's side effects of one step.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Effects {
    /// The waiting request to run next (`hooks.again`).
    pub again: Option<Request>,
    /// Start watching for the person's next action.
    pub watch: bool,
    /// Stop watching.
    pub stop_watching: bool,
}

impl Panes {
    /// Starts opening subagent `agent`'s pane for chat tab `chat`; false when
    /// another open runs (the request waits for [`Panes::finish`]; a repeat
    /// that asks for focus keeps that, from `now`) or this one already runs.
    /// `asked` defaults to `focus`.
    pub fn begin(
        &mut self,
        agent: &str,
        focus: bool,
        asked: Option<bool>,
        chat: &str,
        now: i64,
    ) -> bool {
        let Some(opening) = &self.opening else {
            self.opening = Some(agent.to_owned());
            return true;
        };
        let running = opening == agent;
        if running && focus {
            self.focus_once_open = Some(Owed { agent: agent.to_owned(), at: now });
        }
        if let Some(waiting) = self.queue.iter_mut().find(|request| request.agent == agent) {
            if focus {
                waiting.focus = true;
                waiting.at = now;
            }
            if asked.unwrap_or(focus) {
                waiting.asked = true;
            }
        } else if !running {
            self.queue.push(Request {
                agent: agent.to_owned(),
                focus,
                chat: chat.to_owned(),
                at: now,
                asked: asked.unwrap_or(focus),
            });
        }
        false
    }

    /// Ends the open that runs; the next waiting request, if any, without
    /// focus once its [`FOCUS_BOUND_NS`] has passed at `now`.
    pub fn finish(&mut self, now: i64, effects: &mut Effects) -> Option<Request> {
        self.opening = None;
        self.focus_once_open = None;
        if self.queue.is_empty() {
            self.settle(effects);
            return None;
        }
        let mut next = self.queue.remove(0);
        if next.focus && now - next.at > FOCUS_BOUND_NS {
            next.focus = false;
        }
        self.settle(effects);
        Some(next)
    }

    /// Whether subagent `agent`'s running open still owes the person focus at `now`.
    pub fn owes_focus(&self, agent: &str, now: i64) -> bool {
        self.focus_once_open
            .as_ref()
            .is_some_and(|owed| owed.agent == agent && now - owed.at <= FOCUS_BOUND_NS)
    }

    /// The person clicked, pressed a key or moved focus after asking: their
    /// latest action wins, so no owed focus lands.
    pub fn user_acted(&mut self, effects: &mut Effects) {
        self.focus_once_open = None;
        for request in &mut self.queue {
            request.focus = false;
        }
        self.settle(effects);
    }

    /// Stops watching for the person's next action once no focus is owed.
    fn settle(&mut self, effects: &mut Effects) {
        if self.focus_once_open.is_none() && !self.queue.iter().any(|request| request.focus) {
            if self.watching {
                effects.stop_watching = true;
            }
            self.watching = false;
        }
    }

    /// Records that subagent `agent` has a pane (the app keeps its tab key).
    pub fn record(&mut self, agent: &str) {
        self.shown.insert(agent.to_owned());
    }

    /// Shows subagent `agent`'s pane for chat tab `chat`, once the app found
    /// no open tab of it: an open nobody asked for skips a subagent this chat
    /// already showed and hands its turn to the next waiting request; an open
    /// while another runs waits (a focused one has the app watch the person);
    /// else the app places the pane, and calls [`Panes::landed`] once it moved.
    pub fn open(
        &mut self,
        agent: &str,
        focus: bool,
        asked: Option<bool>,
        chat: &str,
        now: i64,
        effects: &mut Effects,
    ) -> Open {
        let asked = asked.unwrap_or(focus);
        if !asked && self.shown.contains(agent) {
            if self.opening.is_none() {
                effects.again = self.finish(now, effects);
            }
            return Open::Skip;
        }
        if !self.begin(agent, focus, Some(asked), chat, now) {
            if focus && !self.watching {
                self.watching = true;
                effects.watch = true;
            }
            return Open::Wait;
        }
        Open::Place
    }

    /// Subagent `agent`'s open (begun with `focus`) ended at `now`; `has_tab`:
    /// the app has its tab open. True when the pane takes the focus a click
    /// owed it meanwhile; the next waiting request runs (`effects.again`).
    pub fn landed(
        &mut self,
        agent: &str,
        focus: bool,
        has_tab: bool,
        now: i64,
        effects: &mut Effects,
    ) -> bool {
        let takes_focus = !focus && self.owes_focus(agent, now) && has_tab;
        effects.again = self.finish(now, effects);
        takes_focus
    }
}

/// The `revealTurn` value that opens a pane on subagent `agent`'s view (the
/// page's `SUBAGENT_REVEAL`).
pub fn reveal(agent: &str) -> String {
    format!("subagent:{agent}")
}

#[cfg(test)]
#[path = "subagent_panes_tests.rs"]
mod tests;
