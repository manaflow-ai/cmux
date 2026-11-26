//! Mirrors the app's AgentSubagentPanesFocusTests and AgentSubagentPanesReopenTests, through a host
//! that drives [`Panes`] the way the app's `AgentSubagentPanes.open` does.

use std::collections::{BTreeSet, HashMap};

use super::*;

const MS: i64 = 1_000_000;

/// The app's side: the tab keys it remembers, the tabs that exist, and a `place` that holds its
/// callbacks, as a pane still moving into place does.
#[derive(Default)]
struct Host {
    panes: Panes,
    tabs: HashMap<String, String>,
    open: BTreeSet<String>,
    now: i64,
    focused: Vec<String>,
    again: Vec<Request>,
    places: Vec<String>,
    /// The held open: its subagent and whether it was begun with focus.
    held: Option<(String, bool)>,
    watching: bool,
    stops: usize,
}

impl Host {
    fn tab(&mut self, agent: &str) -> Option<String> {
        let open = &self.open;
        self.tabs.retain(|_, key| open.contains(key));
        self.tabs.get(agent).cloned()
    }

    fn apply(&mut self, effects: Effects) {
        if effects.watch {
            self.watching = true;
        }
        if effects.stop_watching {
            self.watching = false;
            self.stops += 1;
        }
        self.again.extend(effects.again);
    }

    fn open(&mut self, agent: &str, focus: bool, asked: Option<bool>) -> bool {
        if let Some(key) = self.tab(agent) {
            if focus {
                self.focused.push(key);
            }
            return true;
        }
        let mut effects = Effects::default();
        let step = self.panes.open(agent, focus, asked, "chat", self.now, &mut effects);
        self.apply(effects);
        match step {
            Open::Skip => false,
            Open::Wait => true,
            Open::Place => {
                self.places.push("chat".into());
                self.held = Some((agent.to_owned(), focus));
                true
            }
        }
    }

    /// The held open lands: its tab exists, then the move ends.
    fn land(&mut self, key: &str) {
        let (agent, focus) = self.held.take().expect("an open is held");
        self.open.insert(key.to_owned());
        self.tabs.insert(agent.clone(), key.to_owned());
        self.panes.record(&agent);
        let has_tab = self.tab(&agent).is_some();
        let mut effects = Effects::default();
        if self.panes.landed(&agent, focus, has_tab, self.now, &mut effects) {
            self.focused.push(key.to_owned());
        }
        self.apply(effects);
    }

    fn acted(&mut self) {
        assert!(self.watching, "only a watch calls back");
        let mut effects = Effects::default();
        self.panes.user_acted(&mut effects);
        self.apply(effects);
    }
}

#[test]
fn a_click_while_the_subagents_pane_opens_unfocused_focuses_it_once_open() {
    let mut host = Host::default();
    assert!(host.open("explore", false, None));
    assert!(host.open("explore", true, None));
    assert!(host.focused.is_empty(), "nothing to focus before the tab exists");
    host.land("tab-explore");
    assert_eq!(host.focused, ["tab-explore"]);
}

#[test]
fn an_unfocused_open_alone_takes_no_focus() {
    let mut host = Host::default();
    assert!(host.open("explore", false, None));
    host.land("tab-explore");
    assert!(host.focused.is_empty());
}

#[test]
fn a_click_key_press_or_focus_change_after_the_click_cancels_the_owed_focus() {
    let mut host = Host::default();
    assert!(host.open("explore", false, None));
    assert!(!host.watching, "nothing is owed yet, so nothing watches");
    assert!(host.open("explore", true, None));
    host.acted();
    assert_eq!(host.stops, 1, "the first action ends the watch");
    host.land("tab-explore");
    assert!(host.focused.is_empty(), "the person's latest action wins");
}

#[test]
fn an_owed_focus_expires_after_its_bound() {
    let mut host = Host::default();
    assert!(host.open("explore", false, None));
    assert!(host.open("explore", true, None));
    host.now += FOCUS_BOUND_NS + MS;
    host.land("tab-explore");
    assert!(host.focused.is_empty(), "a pane that lands late takes no focus");
    assert_eq!(host.stops, 1, "the watch ends with the open");
}

#[test]
fn an_owed_focus_within_its_bound_still_lands() {
    let mut host = Host::default();
    assert!(host.open("explore", false, None));
    assert!(host.open("explore", true, None));
    host.now += FOCUS_BOUND_NS;
    host.land("tab-explore");
    assert_eq!(host.focused, ["tab-explore"]);
    assert!(!host.watching, "no watch outlives the open");
}

#[test]
fn a_repeat_click_restarts_the_bound() {
    let mut host = Host::default();
    assert!(host.open("explore", false, None));
    assert!(host.open("explore", true, None));
    host.now += 1500 * MS;
    assert!(host.open("explore", true, None));
    host.now += 1500 * MS;
    host.land("tab-explore");
    assert_eq!(host.focused, ["tab-explore"], "the latest click is the one that counts");
}

#[test]
fn a_waiting_focused_request_yields_to_a_later_action() {
    let mut host = Host::default();
    assert!(host.open("explore", false, None));
    assert!(host.open("plan", true, None));
    assert!(host.watching, "a focus that waits its turn is owed too");
    host.acted();
    host.land("tab-explore");
    assert_eq!(host.again.len(), 1);
    assert_eq!(host.again[0].agent, "plan");
    assert!(!host.again[0].focus, "the person's latest action wins");
}

#[test]
fn a_waiting_focused_request_expires_after_its_bound() {
    let mut host = Host::default();
    assert!(host.open("explore", false, None));
    assert!(host.open("plan", true, None));
    host.now += FOCUS_BOUND_NS + MS;
    host.land("tab-explore");
    assert!(!host.again[0].focus, "a pane whose turn comes late opens without focus");
    assert!(!host.watching, "nothing is owed any more, so nothing watches");
}

#[test]
fn a_waiting_focused_request_within_its_bound_keeps_focus() {
    let mut host = Host::default();
    assert!(host.open("explore", false, None));
    assert!(host.open("plan", true, None));
    host.now += FOCUS_BOUND_NS;
    host.land("tab-explore");
    assert!(host.again[0].focus);
}

#[test]
fn an_open_subagent_is_shown_not_opened_again() {
    let mut host = Host::default();
    assert!(host.open("one", false, None));
    host.land("tab1");
    assert!(host.open("one", true, None));
    assert_eq!(host.places.len(), 1);
    assert_eq!(host.focused, ["tab1"]);
}

/// Leo, 2026-11-07: "it opened up the side sub-agent chat again".
#[test]
fn an_open_nobody_asked_for_does_not_bring_back_a_pane_the_person_closed() {
    let mut host = Host::default();
    assert!(host.open("diagnose", false, None));
    host.land("tab-1");
    host.open.clear();
    assert!(!host.open("diagnose", false, None), "the page asked again by itself");
    assert_eq!(host.places.len(), 1);
}

#[test]
fn the_persons_own_open_still_shows_a_closed_subagent() {
    let mut host = Host::default();
    assert!(host.open("diagnose", false, None));
    host.land("tab-1");
    host.open.clear();
    assert!(host.open("diagnose", true, None));
    assert_eq!(host.places.len(), 2);
}

#[test]
fn another_subagent_still_opens_by_itself() {
    let mut host = Host::default();
    assert!(host.open("diagnose", false, None));
    host.land("tab-1");
    assert!(host.open("audit", false, None));
    assert_eq!(host.places.len(), 2);
}

#[test]
fn a_subagent_the_person_opened_and_closed_does_not_open_by_itself_later() {
    let mut host = Host::default();
    assert!(host.open("diagnose", true, None));
    host.land("tab-1");
    host.open.clear();
    assert!(!host.open("diagnose", false, None));
    assert_eq!(host.places.len(), 1);
}

#[test]
fn a_click_queued_past_the_focus_bound_still_reopens_a_closed_subagent() {
    let mut host = Host::default();
    assert!(host.open("a", true, None));
    host.land("tab-a");
    host.open.clear();
    assert!(host.open("b", false, None));
    assert!(host.open("a", true, None), "the click waits for B");
    host.now += 5_000 * MS;
    host.land("tab-b");
    let request = host.again[0].clone();
    assert_eq!(request.agent, "a");
    assert!(!request.focus, "too late to take focus");
    assert!(request.asked, "but the person asked");
    let before = host.places.len();
    assert!(host.open("a", false, Some(true)));
    assert_eq!(host.places.len(), before + 1, "A opens again");
}

#[test]
fn a_skipped_unasked_open_lets_the_queue_go_on() {
    let mut host = Host::default();
    assert!(host.open("b", false, None));
    assert!(host.open("a", false, None));
    assert!(host.open("c", false, None));
    host.panes.record("a");
    host.tabs.insert("a".into(), "tab-a".into());
    host.land("tab-b");
    let next = host.again.remove(0);
    assert_eq!(next.agent, "a");
    let before = host.places.len();
    assert!(!host.open(&next.agent, next.focus, Some(next.asked)));
    assert_eq!(host.places.len(), before, "A stays closed");
    assert_eq!(host.again.iter().map(|r| r.agent.as_str()).collect::<Vec<_>>(), ["c"]);
}

#[test]
fn an_unasked_open_of_a_closed_subagent_is_turned_down_at_once() {
    let mut host = Host::default();
    assert!(host.open("a", false, None));
    host.land("tab-a");
    host.open.clear();
    assert!(host.open("b", false, None));
    assert!(!host.open("a", false, None));
    host.land("tab-b");
    assert!(host.again.is_empty(), "A never waited");
    assert_eq!(host.places, ["chat", "chat"]);
}

#[test]
fn the_state_round_trips_as_json() {
    let mut host = Host::default();
    host.open("a", false, None);
    host.open("b", true, None);
    let text = serde_json::to_string(&host.panes).unwrap();
    assert_eq!(serde_json::from_str::<Panes>(&text).unwrap(), host.panes);
    assert_eq!(serde_json::from_str::<Panes>("{}").unwrap(), Panes::default());
    assert_eq!(reveal("x"), "subagent:x");
}
