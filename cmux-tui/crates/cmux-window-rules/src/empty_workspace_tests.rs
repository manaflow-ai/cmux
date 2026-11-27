//! Mirrors the app's EmptyWorkspaceRepairTests (and the rules
//! LastTabClosesWorkspaceTests leans on), through a host that drives
//! [`Repair`] the way the app's `EmptyWorkspaceRepair` does: a membership pass
//! examines every workspace, a pane flip examines one, then the retries run.

use std::collections::{BTreeMap, BTreeSet};

use super::*;

const LIVE: Now = Now { epoch: 1, live: true, can_create: true };

/// The app's side: its workspaces (whether each shows a pane), the
/// connection, the closes and creates it sent.
struct Host {
    repair: Repair,
    panes: BTreeMap<String, bool>,
    now: Now,
    closes: Vec<String>,
    creates: Vec<String>,
}

impl Host {
    fn new(keys: &[&str]) -> Self {
        let mut host = Self {
            repair: Repair::default(),
            panes: keys.iter().map(|key| ((*key).to_owned(), true)).collect(),
            now: LIVE,
            closes: Vec::new(),
            creates: Vec::new(),
        };
        host.snapshot();
        host
    }

    /// A snapshot (a new live tree): every workspace is examined, then the
    /// membership is pruned and the retries run. Started closes are returned.
    fn snapshot(&mut self) -> Vec<Close> {
        let keys: Vec<String> = self.panes.keys().cloned().collect();
        let mut closes: Vec<Close> = keys.iter().filter_map(|key| self.examine(key)).collect();
        let present: BTreeSet<String> = self.panes.keys().cloned().collect();
        self.repair.membership(&present);
        closes.extend(self.retry());
        closes
    }

    fn examine(&mut self, key: &str) -> Option<Close> {
        let has_pane = self.panes[key];
        self.repair.examine(key, has_pane, false, self.now)
    }

    fn retry(&mut self) -> Vec<Close> {
        let keys = self.repair.take_retries();
        let mut closes = Vec::new();
        for key in keys {
            if self.panes.contains_key(&key) {
                closes.extend(self.examine(&key));
            }
        }
        closes
    }

    /// Workspace `key`'s pane flips to `has_pane`: examined, then the retries.
    fn flip(&mut self, key: &str, has_pane: bool) -> Vec<Close> {
        self.panes.insert(key.to_owned(), has_pane);
        let mut closes: Vec<Close> = self.examine(key).into_iter().collect();
        closes.extend(self.retry());
        closes
    }

    /// Runs a started close to its decision; `refused`: the daemon refuses it.
    fn close(&mut self, close: Close, cause: Cause, refused: bool) {
        match self.repair.cause_known(&close.key, cause) {
            Some(Next::Close) => {
                self.closes.push(close.key.clone());
                if refused {
                    self.repair.close_failed(&close.key, close.populated_epoch, self.now);
                } else {
                    self.panes.remove(&close.key);
                    let present: BTreeSet<String> = self.panes.keys().cloned().collect();
                    self.repair.membership(&present);
                }
            }
            Some(Next::Create) => self.creates.push(close.key.clone()),
            None => {}
        }
    }

    fn run(&mut self, closes: Vec<Close>) {
        for close in closes {
            self.close(close, Cause::TabClosed, false);
        }
    }
}

#[test]
fn a_repeated_new_sends_one_create() {
    let mut repair = Repair::default();
    assert!(repair.create_first_tab("w1", LIVE));
    assert!(!repair.create_first_tab("w1", LIVE));
    assert!(repair.is_settling("w1"));
}

#[test]
fn a_failed_first_tab_keeps_its_reason_and_releases_the_workspace() {
    let mut repair = Repair::default();
    repair.begin_fill("w1");
    repair.create_failed("w1", "Refused()", LIVE);
    assert!(!repair.is_settling("w1"));
    assert_eq!(repair.failure("w1"), Some("Refused()"));
}

#[test]
fn a_workspace_emptied_on_purpose_settles_until_the_move_ends() {
    let mut repair = Repair::default();
    repair.begin_closing("w1");
    assert_eq!(repair.states.get("w1"), Some(&FirstTerminal::Closing));
    repair.end_closing("w1");
    assert_eq!(repair.states.get("w1"), None);
}

#[test]
fn nested_populates_hold_until_the_outermost_ends() {
    let mut repair = Repair::default();
    repair.begin_populating("w1");
    repair.begin_populating("w1");
    assert_eq!(repair.states.get("w1"), Some(&FirstTerminal::Populating(2)));
    repair.finish_populating("w1", true, None, LIVE);
    assert_eq!(repair.states.get("w1"), Some(&FirstTerminal::Populating(1)));
    repair.finish_populating("w1", true, None, LIVE);
    assert_eq!(repair.states.get("w1"), Some(&FirstTerminal::AwaitingPane));
}

/// #17632: a workspace whose last tab closed stays in the sidebar when the
/// daemon refuses the close once; the next change closes it again instead of
/// leaving it (or refilling it with a terminal).
#[test]
fn a_refused_close_is_retried_on_the_next_change() {
    let mut host = Host::new(&["ws-1", "ws-2"]);
    let closes = host.flip("ws-1", false);
    assert_eq!(closes.len(), 1);
    for close in closes {
        host.close(close, Cause::TabClosed, true);
    }
    assert_eq!(host.closes, ["ws-1"]);
    assert_eq!(host.repair.states.get("ws-1"), None);
    // Any later change (here another workspace's last tab) retries it.
    let closes = host.flip("ws-2", false);
    host.run(closes);
    assert_eq!(host.closes.iter().filter(|key| *key == "ws-1").count(), 2, "never retried");
    assert!(host.creates.is_empty(), "the emptied workspace was refilled instead of closed");
}

/// A refused close that spans a reconnect keeps the new connection's evidence.
#[test]
fn a_refused_close_across_a_reconnect_keeps_the_new_connections_evidence() {
    let mut host = Host::new(&["ws-1"]);
    let close = host.flip("ws-1", false).remove(0);
    assert_eq!(close.populated_epoch, Some(1));
    // The connection drops while the close is in flight; the new one shows
    // ws-1 with its pane, then the close fails.
    host.now.epoch = 2;
    host.panes.insert("ws-1".into(), true);
    assert!(host.snapshot().is_empty());
    host.close(close, Cause::TabClosed, true);
    // Its last tab closes on the new connection: closed, not ignored.
    let closes = host.flip("ws-1", false);
    assert_eq!(closes.len(), 1, "the refused close restored the old epoch over the new one");
    host.run(closes);
    assert_eq!(host.closes, ["ws-1", "ws-1"]);
}

/// Repopulated on a new connection while its close is in flight, the
/// workspace loses its last tab again before that close fails: the next
/// change closes it instead of leaving it empty.
#[test]
fn a_workspace_emptied_again_during_a_refused_close_is_closed_on_the_next_change() {
    let mut host = Host::new(&["ws-1", "ws-2"]);
    let close = host.flip("ws-1", false).remove(0);
    host.now.epoch = 2;
    host.panes.insert("ws-1".into(), true);
    assert!(host.snapshot().is_empty());
    assert!(host.flip("ws-1", false).is_empty(), "the close owns it");
    host.close(close, Cause::TabClosed, true);
    let closes = host.flip("ws-2", false);
    host.run(closes);
    assert_eq!(host.closes.iter().filter(|key| *key == "ws-1").count(), 2, "ws-1 was left open");
}

#[test]
fn the_cause_is_the_last_ended_terminals() {
    assert_eq!(cause(&[], "w1"), Cause::TabClosed);
    let ended = |key: &str, kind: &str, at: u64| Terminal {
        workspace_key: Some(key.to_owned()),
        exit: Some(Exit { outcome_kind: kind.to_owned(), exited_at_ms: at }),
    };
    let running = Terminal { workspace_key: Some("w1".into()), exit: None };
    assert_eq!(cause(std::slice::from_ref(&running), "w1"), Cause::TabClosed);
    assert_eq!(
        cause(&[ended("w1", "exit", 1), ended("w1", "unknown", 2)], "w1"),
        Cause::TerminalLost
    );
    assert_eq!(
        cause(&[ended("w1", "unknown", 2), ended("w1", "signal", 1)], "w1"),
        Cause::TerminalLost
    );
    assert_eq!(cause(&[ended("w1", "unknown", 1), ended("w1", "exit", 2)], "w1"), Cause::TabClosed);
    assert_eq!(cause(&[ended("w2", "unknown", 9), ended("w1", "exit", 1)], "w1"), Cause::TabClosed);
    // Equally recent: the first one decides, as Swift's `max(by:)`.
    assert_eq!(
        cause(&[ended("w1", "unknown", 3), ended("w1", "exit", 3)], "w1"),
        Cause::TerminalLost
    );
    assert_eq!(cause(&[ended("w1", "exit", 3), ended("w1", "unknown", 3)], "w1"), Cause::TabClosed);
}

/// LastTabClosesWorkspaceTests: Cmd-W on the last tab closes the workspace.
#[test]
fn closing_the_last_tab_closes_the_workspace() {
    let mut host = Host::new(&["w1", "w2"]);
    let closes = host.flip("w1", false);
    host.run(closes);
    assert_eq!(host.closes, ["w1"]);
    assert!(!host.panes.contains_key("w1"));
    assert_eq!(host.repair.decisions, [Decision { key: "w1".into(), cause: Cause::TabClosed }]);
}

#[test]
fn a_lost_terminal_keeps_the_workspace_with_a_new_one() {
    let mut host = Host::new(&["w1"]);
    let close = host.flip("w1", false).remove(0);
    host.close(close, Cause::TerminalLost, false);
    assert!(host.closes.is_empty());
    assert_eq!(host.creates, ["w1"]);
    assert_eq!(host.repair.states.get("w1"), Some(&FirstTerminal::AwaitingPane));
    // Its new pane shows: settled.
    host.flip("w1", true);
    assert!(!host.repair.is_settling("w1"));
    // A lost terminal whose close was taken back (a move ended it) does nothing.
    let mut repair = Repair::default();
    assert_eq!(repair.cause_known("w1", Cause::TerminalLost), None);
    assert!(repair.decisions.is_empty());
}

#[test]
fn nothing_closes_or_repairs_before_a_live_snapshot_or_in_home() {
    let mut repair = Repair::default();
    let launch = Now { live: false, ..LIVE };
    assert_eq!(repair.examine("w1", true, false, launch), None);
    assert!(repair.ever_populated.contains("w1"), "the launch snapshot's pane still counts");
    assert!(repair.populated.is_empty());
    assert_eq!(repair.examine("w1", false, false, launch), None);
    assert_eq!(repair.examine("home", true, true, LIVE), None);
    assert_eq!(repair.examine("home", false, true, LIVE), None);
    assert_eq!(repair.check("w1", false, false, launch), Check::default());
    assert_eq!(repair.check("home", false, true, LIVE), Check::default());
    assert!(repair.states.is_empty());
}

#[test]
fn a_disconnected_close_waits_for_the_next_change() {
    let mut host = Host::new(&["w1", "w2"]);
    host.now.can_create = false;
    assert!(host.flip("w1", false).is_empty());
    assert!(host.repair.retries.contains("w1"));
    host.now.can_create = true;
    let closes = host.flip("w2", true);
    assert_eq!(closes.iter().map(|close| close.key.as_str()).collect::<Vec<_>>(), ["w1"]);
}

#[test]
fn check_refills_a_workspace_that_held_a_pane_and_leaves_a_new_one_empty() {
    let mut repair = Repair::default();
    // A new empty workspace: its new-workspace actions show.
    assert_eq!(repair.check("new", false, false, LIVE), Check::default());
    // Held a pane on an earlier connection, none now: refilled once.
    repair.examine("w1", true, false, LIVE);
    let next = Now { epoch: 2, ..LIVE };
    assert_eq!(repair.check("w1", false, false, next), Check { close: None, create: true });
    assert_eq!(repair.check("w1", false, false, next), Check::default());
    // Seen with a pane on this connection: its last tab closed, so it closes.
    repair.examine("w2", true, false, next);
    let check = repair.check("w2", false, false, next);
    assert_eq!(check.close, Some(Close { key: "w2".into(), populated_epoch: Some(2) }));
    assert!(!check.create);
    // A pane: noted.
    assert_eq!(repair.check("w3", true, false, next), Check::default());
    assert_eq!(repair.populated.get("w3"), Some(&2));
    // Commands cannot run: nothing created.
    repair.examine("w4", true, false, LIVE);
    assert!(!repair.check("w4", false, false, Now { can_create: false, ..next }).create);
}

#[test]
fn a_failed_refill_is_not_retried_by_itself_until_a_reconnect() {
    let mut repair = Repair::default();
    repair.examine("w1", true, false, LIVE);
    let next = Now { epoch: 2, ..LIVE };
    assert!(repair.check("w1", false, false, next).create);
    repair.create_failed("w1", "boom", next);
    assert_eq!(repair.failure("w1"), Some("boom"));
    assert!(!repair.check("w1", false, false, next).create, "held on that connection");
    let again = Now { epoch: 3, ..LIVE };
    assert!(repair.check("w1", false, false, again).create, "a reconnect lifts it");
    assert_eq!(repair.failure("w1"), None);
    // New clears a failure and creates.
    repair.create_failed("w1", "boom", again);
    assert!(repair.create_first_tab("w1", again));
    assert_eq!(repair.failure("w1"), None);
    // A pane clears it too.
    repair.create_failed("w1", "boom", again);
    repair.examine("w1", true, false, again);
    assert_eq!(repair.failure("w1"), None);
}

#[test]
fn a_failed_populate_is_closed_by_its_creator_unless_that_close_failed() {
    let mut repair = Repair::default();
    repair.begin_populating("w1");
    repair.finish_populating("w1", false, Some("refused"), LIVE);
    assert_eq!(repair.states.get("w1"), Some(&FirstTerminal::Closing));
    assert_eq!(repair.failure("w1"), None);
    repair.begin_populating("w2");
    repair.keep_after_failed_close("w2");
    repair.finish_populating("w2", false, Some("refused"), LIVE);
    assert_eq!(repair.states.get("w2"), None);
    assert_eq!(repair.failure("w2"), Some("refused"));
    assert!(repair.kept_after_failed_close.is_empty());
    // Not populating: nothing to finish.
    repair.finish_populating("w3", true, None, LIVE);
    assert!(!repair.is_settling("w3"));
    // A populate's pane releases nothing while the call runs.
    repair.begin_populating("w4");
    repair.examine("w4", true, false, LIVE);
    assert_eq!(repair.states.get("w4"), Some(&FirstTerminal::Populating(1)));
}

#[test]
fn membership_forgets_the_workspaces_that_left() {
    let mut repair = Repair::default();
    repair.examine("gone", true, false, LIVE);
    repair.begin_closing("gone");
    repair.begin_fill("filling");
    repair.create_failed("filling", "x", LIVE);
    repair.keep_after_failed_close("gone");
    repair.retries.insert("gone".into());
    repair.begin_populating("pending");
    repair.membership(&BTreeSet::from(["kept".to_owned()]));
    assert!(repair.populated.is_empty());
    assert_eq!(repair.states.get("gone"), None, "a closed one goes");
    assert_eq!(
        repair.states.get("pending"),
        Some(&FirstTerminal::Populating(1)),
        "a populate stays"
    );
    assert!(repair.failures.is_empty() && repair.failure_epochs.is_empty());
    assert!(repair.kept_after_failed_close.is_empty() && repair.retries.is_empty());
    assert!(repair.ever_populated.contains("gone"), "kept for the daemon session");
}

#[test]
fn the_decisions_keep_the_last_32() {
    let mut repair = Repair::default();
    for index in 0..40 {
        repair.cause_known(&format!("w{index}"), Cause::TabClosed);
    }
    assert_eq!(repair.decisions.len(), DECISIONS_KEPT);
    assert_eq!(repair.decisions[0].key, "w8");
    assert_eq!(repair.decisions[31].key, "w39");
}

#[test]
fn a_close_failure_outside_a_close_changes_nothing() {
    let mut repair = Repair::default();
    repair.close_failed("w1", Some(1), LIVE);
    assert_eq!(repair, Repair::default());
    repair.begin_fill("w1");
    repair.create_failed("w2", "x", LIVE);
    assert_eq!(repair.failure("w2"), None);
}

#[test]
fn the_state_round_trips_as_json() {
    let mut host = Host::new(&["a", "b"]);
    host.flip("a", false);
    host.repair.begin_populating("c");
    host.repair.begin_fill("d");
    host.repair.create_failed("d", "x", LIVE);
    let text = serde_json::to_string(&host.repair).unwrap();
    assert_eq!(serde_json::from_str::<Repair>(&text).unwrap(), host.repair);
    assert_eq!(serde_json::from_str::<Repair>("{}").unwrap(), Repair::default());
    assert_eq!(
        serde_json::to_value(FirstTerminal::Populating(2)).unwrap(),
        serde_json::json!({"populating": 2})
    );
}
