//! What happens to a workspace with no pane (the app's `EmptyWorkspaceRepair`
//! and `EmptiedWorkspaceCause`): a reducer over [`Repair`], which the app holds
//! between calls. The app keeps the store observation (which workspace gained
//! its first pane or lost its last) and the daemon commands; this decides.
//!
//! - A workspace whose last tab closed (Cmd-W, the tab's x, the CLI, or the
//!   process exiting) closes: this connection saw it with a pane, then without
//!   one (dogfood nxdog9, REWRITE.md round 3).
//! - One that lost its last terminal (its host died: a crash, a kill, a
//!   reboot) stays, with a new terminal.
//! - One that never held a pane stays empty, so the app shows its
//!   new-workspace actions.
//! - Each workspace has a [`FirstTerminal`] state from the moment this app
//!   creates its first terminal (or a repair does) until the store shows its
//!   pane; a workspace with a state is never repaired or closed. A failed
//!   request releases it with its reason, kept until a pane shows or New, and
//!   not refilled by itself on that connection (cx-tzlqb).
//! - A refused close is tried again on the next change (#17632).
//!
//! Every call takes [`Now`]: the connection epoch, whether the store holds a
//! live snapshot, and whether commands can run.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

/// How many decisions [`Repair::decisions`] keeps, newest last.
pub const DECISIONS_KEPT: usize = 32;

/// Why a workspace this connection saw with a pane has none now.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Cause {
    /// Its last tab was closed or its last process ended (exit or signal):
    /// the workspace closes.
    TabClosed,
    /// Its last terminal was lost, not ended: the daemon found the terminal
    /// host already dead when it adopted it (`TerminalExit` outcome
    /// `unknown`). The workspace stays and gets a new terminal.
    TerminalLost,
}

/// A registry terminal's end (`list-terminals`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Exit {
    pub outcome_kind: String,
    pub exited_at_ms: u64,
}

/// One registry terminal, the fields the cause reads.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Terminal {
    pub workspace_key: Option<String>,
    pub exit: Option<Exit>,
}

/// The cause from the daemon's terminal registry: the workspace's most
/// recently ended terminal decides (the first of equally recent ones). A
/// process end (exit, signal) is a closed tab; an unobserved end (outcome
/// `unknown`) is a lost terminal. With no ended terminal on record the tab was
/// closed by a client.
pub fn cause(terminals: &[Terminal], key: &str) -> Cause {
    let last = terminals
        .iter()
        .filter(|terminal| terminal.workspace_key.as_deref() == Some(key))
        .filter_map(|terminal| terminal.exit.as_ref())
        .fold(None::<&Exit>, |last, exit| match last {
            Some(last) if last.exited_at_ms >= exit.exited_at_ms => Some(last),
            _ => Some(exit),
        });
    match last {
        Some(exit) if exit.outcome_kind == "unknown" => Cause::TerminalLost,
        _ => Cause::TabClosed,
    }
}

/// Who is giving a workspace its first terminal.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum FirstTerminal {
    /// This app is running create-workspace + create-terminal; the count of
    /// nested callers.
    Populating(u32),
    /// A create-terminal was sent (a repair) or answered (either path):
    /// waiting for the store to show a pane.
    AwaitingPane,
    /// This app is moving every tab out of the workspace and closes it
    /// afterwards (a tab drag), or its last tab closed and it is being
    /// closed: empty on purpose, never repaired.
    Closing,
}

/// The app's answers at the time of a call.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Now {
    /// The daemon store's connection epoch.
    pub epoch: i64,
    /// Whether the store holds a live snapshot (not the launch snapshot).
    pub live: bool,
    /// Whether commands can run (a connection to send them on).
    pub can_create: bool,
}

/// One emptied workspace and what this app did with it.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Decision {
    pub key: String,
    pub cause: Cause,
}

/// A close to start: the app asks for the cause, then calls
/// [`Repair::cause_known`]. `populated_epoch` goes back with
/// [`Repair::close_failed`].
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Close {
    pub key: String,
    pub populated_epoch: Option<i64>,
}

/// What follows a known cause.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Next {
    /// The terminal was lost: create a new one (a failure is
    /// [`Repair::create_failed`]).
    Create,
    /// The last tab closed: close the workspace (a failure is
    /// [`Repair::close_failed`]).
    Close,
}

/// What [`Repair::check`] tells the app to do.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Check {
    pub close: Option<Close>,
    /// Create the workspace's first terminal (a failure is
    /// [`Repair::create_failed`]).
    pub create: bool,
}

/// The process-wide repair state, per daemon.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Repair {
    pub states: BTreeMap<String, FirstTerminal>,
    /// Why a workspace's first terminal failed, until a pane shows or New.
    pub failures: BTreeMap<String, String>,
    /// Each failure's connection epoch: a reconnect lifts the refill hold.
    pub failure_epochs: BTreeMap<String, i64>,
    /// Created workspaces whose terminal and then close failed: released.
    pub kept_after_failed_close: BTreeSet<String>,
    /// The last emptied workspaces and their cause, newest last.
    pub decisions: Vec<Decision>,
    /// Workspaces seen with a pane, with the epoch they were seen on: one
    /// seen on the current connection that has no pane now had its last tab
    /// closed.
    pub populated: BTreeMap<String, i64>,
    /// Workspaces that ever held a pane in this daemon session: a reconnect
    /// tells a lost terminal from a workspace created empty for the new-tab
    /// flow.
    pub ever_populated: BTreeSet<String>,
    /// Emptied workspaces to examine again on the next change.
    pub retries: BTreeSet<String>,
}

impl Repair {
    /// The store's membership changed: `present` is every workspace key in
    /// it. Forgets what it held for the ones that left.
    pub fn membership(&mut self, present: &BTreeSet<String>) {
        self.populated.retain(|key, _| present.contains(key));
        self.states.retain(|key, state| present.contains(key) || *state != FirstTerminal::Closing);
        let gone: Vec<String> =
            self.failures.keys().filter(|key| !present.contains(*key)).cloned().collect();
        for key in gone {
            self.clear_failure(&key);
        }
        self.kept_after_failed_close.retain(|key| present.contains(key));
        self.retries.retain(|key| present.contains(key));
    }

    /// The emptied workspaces to examine again ([`Repair::examine`]), now.
    pub fn take_retries(&mut self) -> Vec<String> {
        std::mem::take(&mut self.retries).into_iter().collect()
    }

    /// Workspace `key` gained its first pane or lost its last (`has_pane`);
    /// `home`: the store's or a window's Home, which is neither repaired nor
    /// closed. A close to start, when its last tab closed.
    pub fn examine(&mut self, key: &str, has_pane: bool, home: bool, now: Now) -> Option<Close> {
        // The launch snapshot can show a pane before the live tree arrives:
        // remember that, but close or repair nothing before a live snapshot.
        if has_pane {
            self.ever_populated.insert(key.to_owned());
        }
        if !now.live || home {
            return None;
        }
        if has_pane {
            self.note_populated(key, now);
            None
        } else {
            self.close_if_emptied(key, now).1
        }
    }

    fn note_populated(&mut self, key: &str, now: Now) {
        self.populated.insert(key.to_owned(), now.epoch);
        if self.failures.contains_key(key) {
            self.clear_failure(key);
        }
        // Whoever created the terminal is done, unless this app is still
        // inside its own populate call or closing it.
        if self.states.get(key) == Some(&FirstTerminal::AwaitingPane) {
            self.states.remove(key);
        }
    }

    /// Claims `key` for a close when this connection saw it with a pane and
    /// nothing else owns it: whether it is (being) closed, and the close to
    /// start.
    fn close_if_emptied(&mut self, key: &str, now: Now) -> (bool, Option<Close>) {
        if self.populated.get(key) != Some(&now.epoch) || self.states.contains_key(key) {
            return (self.states.get(key) == Some(&FirstTerminal::Closing), None);
        }
        // Disconnected: the next change tries again.
        if !now.can_create {
            self.retries.insert(key.to_owned());
            return (false, None);
        }
        self.states.insert(key.to_owned(), FirstTerminal::Closing);
        let populated_epoch = self.populated.remove(key);
        (true, Some(Close { key: key.to_owned(), populated_epoch }))
    }

    /// The cause of `key`'s close is known. A lost terminal keeps the
    /// workspace with a new one, while the close still owns it.
    pub fn cause_known(&mut self, key: &str, cause: Cause) -> Option<Next> {
        if cause == Cause::TerminalLost {
            if self.states.get(key) != Some(&FirstTerminal::Closing) {
                return None;
            }
            self.states.insert(key.to_owned(), FirstTerminal::AwaitingPane);
            self.record(key, Cause::TerminalLost);
            return Some(Next::Create);
        }
        self.record(key, Cause::TabClosed);
        Some(Next::Close)
    }

    fn record(&mut self, key: &str, cause: Cause) {
        self.decisions.push(Decision { key: key.to_owned(), cause });
        if self.decisions.len() > DECISIONS_KEPT {
            let extra = self.decisions.len() - DECISIONS_KEPT;
            self.decisions.drain(..extra);
        }
    }

    /// The close [`Repair::examine`] started was refused. The workspace is
    /// still open: keep its last-tab-close evidence so the next change closes
    /// it again instead of refilling it (#17632), and examine it again then
    /// (its pane changes were ignored while the close owned it).
    pub fn close_failed(&mut self, key: &str, populated_epoch: Option<i64>, now: Now) {
        if self.states.get(key) != Some(&FirstTerminal::Closing) {
            return;
        }
        self.states.remove(key);
        if let Some(epoch) = populated_epoch
            && epoch == now.epoch
            && !self.populated.contains_key(key)
        {
            self.populated.insert(key.to_owned(), epoch);
        }
        // A reconnect can replace the workspace model while the close is in
        // flight; the failed close still proves it had a terminal.
        if self.populated.get(key) != Some(&now.epoch) {
            self.populated.insert(key.to_owned(), now.epoch);
        }
        self.retries.insert(key.to_owned());
    }

    /// A first terminal (a repair, New, a person's first tab) failed with
    /// `error`: the workspace is released with its reason.
    pub fn create_failed(&mut self, key: &str, error: &str, now: Now) {
        if self.states.get(key) == Some(&FirstTerminal::AwaitingPane) {
            self.states.remove(key);
            self.record_failure(key, error, now);
        }
    }

    /// Checks workspace `key` after a store change. A populated workspace
    /// whose last tab closed is closed; one that held a pane before and has
    /// none (its host died) is refilled; a new empty one is left alone, for
    /// its new-workspace actions.
    pub fn check(&mut self, key: &str, has_pane: bool, home: bool, now: Now) -> Check {
        if !now.live || home {
            return Check::default();
        }
        if has_pane {
            self.note_populated(key, now);
            return Check::default();
        }
        if self.failure_epochs.get(key).is_some_and(|failed| *failed != now.epoch) {
            self.clear_failure(key);
        }
        if self.states.contains_key(key) {
            return Check::default();
        }
        let (closing, close) = self.close_if_emptied(key, now);
        if closing || !self.ever_populated.contains(key) || self.failures.contains_key(key) {
            return Check { close, create: false };
        }
        Check { close, create: self.create_tab(key, now) }
    }

    /// An explicit New: whether to create the first tab (a repeated press
    /// while one is on its way creates nothing).
    pub fn create_first_tab(&mut self, key: &str, now: Now) -> bool {
        if self.states.contains_key(key) || !now.can_create {
            return false;
        }
        self.clear_failure(key);
        self.create_tab(key, now)
    }

    fn create_tab(&mut self, key: &str, now: Now) -> bool {
        if self.states.contains_key(key) || !now.can_create {
            return false;
        }
        self.states.insert(key.to_owned(), FirstTerminal::AwaitingPane);
        true
    }

    /// Whether `key` is about to change by itself: its first terminal is on
    /// its way or it is being closed.
    pub fn is_settling(&self, key: &str) -> bool {
        self.states.contains_key(key)
    }

    /// Why `key`'s first terminal did not start, while it is still empty.
    pub fn failure(&self, key: &str) -> Option<&str> {
        self.failures.get(key).map(String::as_str)
    }

    /// `key` is emptied on purpose (its tabs are moving to another
    /// workspace) and will close: no repair until [`Repair::end_closing`].
    pub fn begin_closing(&mut self, key: &str) {
        self.states.insert(key.to_owned(), FirstTerminal::Closing);
    }

    /// The move failed (the tabs stayed): repairs apply again.
    pub fn end_closing(&mut self, key: &str) {
        if self.states.get(key) == Some(&FirstTerminal::Closing) {
            self.states.remove(key);
        }
    }

    /// A person's first tab in an existing empty workspace (Cmd-T) starts; a
    /// failure is [`Repair::create_failed`].
    pub fn begin_fill(&mut self, key: &str) {
        self.states.insert(key.to_owned(), FirstTerminal::AwaitingPane);
        self.clear_failure(key);
    }

    /// This app starts populating `key` (create-workspace, then
    /// create-terminal); calls nest.
    pub fn begin_populating(&mut self, key: &str) {
        let count = match self.states.get(key) {
            Some(FirstTerminal::Populating(count)) => count + 1,
            _ => 1,
        };
        self.states.insert(key.to_owned(), FirstTerminal::Populating(count));
    }

    /// A populate call ended. On success the workspace stays owned until the
    /// store shows its pane; a failed one was closed by its creator and is
    /// never repaired, unless that close failed too
    /// ([`Repair::keep_after_failed_close`]): then it is released with `error`.
    pub fn finish_populating(&mut self, key: &str, succeeded: bool, error: Option<&str>, now: Now) {
        let Some(FirstTerminal::Populating(count)) = self.states.get(key).copied() else {
            return;
        };
        if count > 1 {
            self.states.insert(key.to_owned(), FirstTerminal::Populating(count - 1));
        } else if !succeeded && self.kept_after_failed_close.remove(key) {
            self.states.remove(key);
            if let Some(error) = error {
                self.record_failure(key, error, now);
            }
        } else {
            let state =
                if succeeded { FirstTerminal::AwaitingPane } else { FirstTerminal::Closing };
            self.states.insert(key.to_owned(), state);
        }
    }

    /// The app could not close `key` after its first terminal failed.
    pub fn keep_after_failed_close(&mut self, key: &str) {
        self.kept_after_failed_close.insert(key.to_owned());
    }

    fn record_failure(&mut self, key: &str, error: &str, now: Now) {
        self.failures.insert(key.to_owned(), error.to_owned());
        self.failure_epochs.insert(key.to_owned(), now.epoch);
    }

    fn clear_failure(&mut self, key: &str) {
        self.failures.remove(key);
        self.failure_epochs.remove(key);
    }
}

#[cfg(test)]
#[path = "empty_workspace_tests.rs"]
mod tests;
