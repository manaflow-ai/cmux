//! One window's key hold while a creation waits for its reply (the macOS app's
//! `CreationInputBuffer`, its `NewTerminalKeys`, its reply bound and its tab keys).
//!
//! The app keeps each held `NSEvent` and hands this hold an id for it, with
//! whether it is a chord (Command or Control held). What the app reads live
//! comes in with each request:
//!
//! - `nowNs`: the monotonic clock.
//! - `listed`: for each made terminal's ticket, the daemon's tab the store lists
//!   of it now (the app's `madeTab` closures, read before the call).
//! - `kinds`: what each held key's binding does to the tabs (`TabKey`).
//!
//! Timers stay in the app: `open` answers `armReplyBound`, and the app sends
//! `replyBoundPassed` when it fires; `limitPassed` is the app's `expire(after:)`.
//! A ticket's owner check (`ObjectIdentifier`) stays in the app too.

use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

/// The longest a creation's reply keeps the window's keys (cmux-ad m12): 10 s.
pub const REPLY_WAIT_BOUND_NS: i64 = 10_000_000_000;

/// What a held key's action does to the focused pane's tabs.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TabKey {
    Makes,
    Closes,
}

const MAKERS: [&str; 7] = [
    "newTab.default",
    "newTab.afterCurrent",
    "newTab.atStart",
    "newTab.atEnd",
    "newTab.toRight",
    "newSurface",
    "openBrowser",
];

impl TabKey {
    /// What `action` (a key binding's action id) does to the tabs; None: neither.
    pub fn of_action(action: Option<&str>) -> Option<TabKey> {
        let action = action?;
        if action == "closeTab" {
            Some(TabKey::Closes)
        } else if MAKERS.contains(&action) {
            Some(TabKey::Makes)
        } else {
            None
        }
    }
}

/// The terminal a lane's keys are for.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HeldLane {
    pub tab: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub machine: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub made_surface: Option<u64>,
}

/// One held key: the app's event id, whether it is a chord, its creation and the
/// pane that had the focus at its press.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Held {
    pub event: u64,
    #[serde(default)]
    pub chord: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub creation: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pane: Option<String>,
}

/// A held key at the hold's end, in typing order.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum HeldKey {
    /// Keys of a lane whose terminal is not the focused one, typed as one run.
    Type { events: Vec<u64>, lane: HeldLane, panes: Vec<Option<String>> },
    /// An app shortcut typed for a lane whose terminal is not the focused one.
    Command { event: u64, lane: HeldLane, pane: Option<String> },
    /// A key that runs again as typed.
    Run { event: u64, lane: Option<HeldLane>, pane: Option<String> },
}

/// A key handed back to be held again (`prepend`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Earlier {
    pub event: u64,
    #[serde(default)]
    pub chord: bool,
    #[serde(default)]
    pub lane: Option<HeldLane>,
    #[serde(default)]
    pub pane: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PressLane {
    pub lane: HeldLane,
    pub person_moves: u64,
}

/// New Terminal Tab's creations of the hold (`NewTerminalKeys`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct NewTerminals {
    pub tickets: BTreeSet<i64>,
    pub silent_stand_ins: BTreeSet<i64>,
    /// The tickets whose create made a terminal (the app keeps its `madeTab` read).
    pub made: BTreeSet<i64>,
    pub surfaces: BTreeMap<i64, u64>,
}

/// What the app reads live for a call.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Live {
    pub now_ns: i64,
    pub listed: BTreeMap<i64, String>,
    pub kinds: BTreeMap<u64, TabKey>,
}

impl NewTerminals {
    fn ticket(&self, newest: i64, own: Option<i64>) -> Option<i64> {
        (self.tickets.contains(&newest) && own.unwrap_or(0) <= newest).then_some(newest)
    }

    fn resolve(
        &mut self,
        ticket: i64,
        landed: bool,
        made_tab: bool,
        made_surface: Option<u64>,
    ) -> bool {
        if !self.tickets.contains(&ticket) {
            return false;
        }
        if !landed {
            self.tickets.remove(&ticket);
            return true;
        }
        if made_tab {
            self.made.insert(ticket);
        } else {
            self.made.remove(&ticket);
        }
        set(&mut self.surfaces, ticket, made_surface);
        false
    }

    fn tab<'a>(&self, ticket: i64, live: &'a Live) -> Option<&'a String> {
        if self.made.contains(&ticket) { live.listed.get(&ticket) } else { None }
    }

    fn lost(&self, ticket: i64, live: &Live) -> bool {
        self.made.contains(&ticket) && !live.listed.contains_key(&ticket)
    }

    fn waits_for_tab(&self, ticket: i64, stand_in: bool, live: &Live) -> bool {
        (!stand_in || self.silent_stand_ins.contains(&ticket)) && self.lost(ticket, live)
    }
}

fn set<K: Ord, V>(map: &mut BTreeMap<K, V>, key: K, value: Option<V>) {
    match value {
        Some(value) => {
            map.insert(key, value);
        }
        None => {
            map.remove(&key);
        }
    }
}

/// Held keys dropped, for the app's log.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Dropped {
    pub count: usize,
    pub why: String,
}

/// The hold's state (the app sends it back with each call).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct CreationHold {
    pub events: Vec<Held>,
    pub lane_tabs: BTreeMap<i64, String>,
    pub lane_machines: BTreeMap<i64, String>,
    pub adopted: i64,
    pub pending: BTreeMap<i64, u64>,
    pub awaited: BTreeSet<u64>,
    pub early_tabs: BTreeMap<i64, String>,
    pub tabs: BTreeMap<i64, String>,
    pub made_tabs: BTreeSet<String>,
    pub new_terminals: NewTerminals,
    pub workspace_tickets: BTreeSet<i64>,
    pub made_workspaces: BTreeMap<i64, String>,
    pub moved_on_from: BTreeSet<i64>,
    pub failed_workspaces: BTreeSet<i64>,
    pub stranded_workspaces: BTreeSet<i64>,
    pub press_lanes: BTreeMap<i64, PressLane>,
    pub press_delivered: BTreeSet<i64>,
    pub untyped_terminal_keys: i64,
    pub reply_wait_limit_ns: i64,
    pub newest_generation: Option<u64>,
    pub next_id: i64,
    pub began_ns: i64,
    pub replied_at_ns: Option<i64>,
    pub newest_opened_at_ns: Option<i64>,
    pub newest_creation: i64,
    pub closing_tabs: BTreeMap<i64, Vec<String>>,
    pub every_key_closes: BTreeSet<i64>,
    pub answering: BTreeMap<i64, Vec<String>>,
    pub awaited_tab: Option<String>,
    pub awaits_page: bool,
    /// Keys dropped by the last call, for the app's log (cleared at each call).
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub dropped: Vec<Dropped>,
}

impl Default for CreationHold {
    fn default() -> Self {
        Self::new(0)
    }
}

/// What `open` asks the app to arm: the reply bound of creation `opened`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReplyBound {
    pub opened: i64,
    pub bound_ns: i64,
}

/// What a new creation opened.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Opened {
    pub ticket: i64,
    pub arm: ReplyBound,
}

/// `open`'s arguments.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Open {
    pub generation: u64,
    pub early_tab: Option<String>,
    pub tab: Option<String>,
    pub machine: Option<String>,
    pub new_workspace: bool,
    pub new_terminal: bool,
    #[serde(default = "yes")]
    pub stand_in_sends: bool,
    #[serde(default = "yes")]
    pub types_into_tab: bool,
    pub press_terminal: Option<HeldLane>,
    pub person_moves: u64,
    pub at_ns: Option<i64>,
}

fn yes() -> bool {
    true
}

impl Open {
    pub fn generation(generation: u64) -> Self {
        Open { generation, stand_in_sends: true, types_into_tab: true, ..Open::default() }
    }
}

impl CreationHold {
    pub fn new(began_ns: i64) -> Self {
        CreationHold {
            events: Vec::new(),
            lane_tabs: BTreeMap::new(),
            lane_machines: BTreeMap::new(),
            adopted: 0,
            pending: BTreeMap::new(),
            awaited: BTreeSet::new(),
            early_tabs: BTreeMap::new(),
            tabs: BTreeMap::new(),
            made_tabs: BTreeSet::new(),
            new_terminals: NewTerminals::default(),
            workspace_tickets: BTreeSet::new(),
            made_workspaces: BTreeMap::new(),
            moved_on_from: BTreeSet::new(),
            failed_workspaces: BTreeSet::new(),
            stranded_workspaces: BTreeSet::new(),
            press_lanes: BTreeMap::new(),
            press_delivered: BTreeSet::new(),
            untyped_terminal_keys: 0,
            reply_wait_limit_ns: REPLY_WAIT_BOUND_NS,
            newest_generation: None,
            next_id: 0,
            began_ns,
            replied_at_ns: None,
            newest_opened_at_ns: None,
            newest_creation: 0,
            closing_tabs: BTreeMap::new(),
            every_key_closes: BTreeSet::new(),
            answering: BTreeMap::new(),
            awaited_tab: None,
            awaits_page: false,
            dropped: Vec::new(),
        }
    }

    pub fn is_resolved(&self) -> bool {
        self.pending.is_empty()
    }
    pub fn holds_creation(&self) -> bool {
        self.next_id > 0
    }
    pub fn has_pending_creation(&self) -> bool {
        !self.pending.is_empty()
    }
    pub fn is_empty(&self) -> bool {
        self.events.is_empty()
    }

    fn log_dropped(&mut self, count: usize, why: &str) {
        if count > 0 {
            self.dropped.push(Dropped { count, why: why.to_owned() });
        }
    }

    fn remove_events(&mut self, mut drop: impl FnMut(&Held) -> bool) -> usize {
        let before = self.events.len();
        self.events.retain(|held| !drop(held));
        before - self.events.len()
    }

    pub fn open(&mut self, open: Open, live: &Live) -> Opened {
        self.next_id += 1;
        let id = self.next_id;
        self.newest_creation = id;
        self.newest_opened_at_ns = Some(open.at_ns.unwrap_or(live.now_ns));
        if open.new_workspace {
            if let Some(lane) = open.press_terminal {
                self.press_lanes.insert(id, PressLane { lane, person_moves: open.person_moves });
            }
        }
        let arm = ReplyBound { opened: self.newest_creation, bound_ns: self.reply_wait_limit_ns };
        self.pending.insert(id, open.generation);
        self.newest_generation = Some(open.generation);
        if open.new_workspace {
            self.workspace_tickets.insert(id);
        }
        if open.new_terminal {
            self.new_terminals.tickets.insert(id);
            set(&mut self.lane_machines, id, open.machine.clone());
            if !open.stand_in_sends {
                self.new_terminals.silent_stand_ins.insert(id);
            }
        }
        if let Some(early) = open.early_tab {
            self.early_tabs.insert(id, early);
        }
        if let Some(tab) = open.tab {
            self.tabs.insert(id, tab.clone());
            if open.types_into_tab {
                self.lane_tabs.insert(id, tab.clone());
                set(&mut self.lane_machines, id, open.machine);
            }
            self.made_tabs.insert(tab);
        }
        Opened { ticket: id, arm }
    }

    pub fn cancel(&mut self, tab: &str, live: &Live) -> bool {
        let ids: BTreeSet<i64> =
            self.tabs.iter().filter(|(_, t)| *t == tab).map(|(id, _)| *id).collect();
        if ids.is_empty() {
            return false;
        }
        for id in &ids {
            self.tabs.remove(id);
            self.early_tabs.remove(id);
            self.pending.remove(id);
            self.lane_tabs.remove(id);
            self.lane_machines.remove(id);
            self.new_terminals.tickets.remove(id);
        }
        self.remove_events(|held| held.creation.is_some_and(|c| ids.contains(&c)));
        if self.pending.is_empty() && self.awaited.is_empty() {
            let keep: Vec<bool> = self
                .events
                .iter()
                .map(|held| {
                    let laned = held.creation.and_then(|c| self.lane_tabs.get(&c)).is_some();
                    laned
                        || self.is_open_close(held.creation)
                        || self.is_stranded(held.creation, live)
                })
                .collect();
            let mut keep = keep.into_iter();
            self.events.retain(|_| keep.next().unwrap_or(true));
        }
        true
    }

    pub fn open_close(
        &mut self,
        closing: Vec<String>,
        machine: Option<String>,
        takes_every_key: bool,
        live: &Live,
    ) -> Opened {
        let creation = (self.newest_creation, self.newest_opened_at_ns);
        let opened = self.open(Open::generation(0), live);
        (self.newest_creation, self.newest_opened_at_ns) = creation;
        self.closing_tabs.insert(opened.ticket, closing);
        set(&mut self.lane_machines, opened.ticket, machine);
        if takes_every_key {
            self.every_key_closes.insert(opened.ticket);
        }
        opened
    }

    fn is_open_close(&self, id: Option<i64>) -> bool {
        id.is_some_and(|id| self.closing_tabs.contains_key(&id) || self.answering.contains_key(&id))
    }

    pub fn is_closing(&self, tab: Option<&str>) -> bool {
        self.every_key_closes.iter().any(|id| self.closing_tabs.contains_key(id))
            || tab.is_some_and(|tab| self.closing_tabs.values().any(|c| c.iter().any(|t| t == tab)))
    }

    pub fn settle_close(
        &mut self,
        ticket: i64,
        keys_to: Option<String>,
        stays: bool,
        machine: Option<String>,
        live: &Live,
    ) {
        let answered = self.answering.remove(&ticket);
        let closing = match self.closing_tabs.remove(&ticket).or_else(|| answered.clone()) {
            Some(closing) => closing,
            None => return,
        };
        self.every_key_closes.remove(&ticket);
        if !stays {
            let mut others: BTreeSet<i64> = self.closing_tabs.keys().copied().collect();
            if answered.is_none() {
                others.extend(self.answering.keys().copied());
            }
            if let Some(next) = others.iter().max().copied() {
                for held in &mut self.events {
                    if held.creation == Some(ticket) {
                        held.creation = Some(next);
                    }
                }
                return self.resolve(ticket, false, None, false, None, live);
            }
        }
        if stays {
            set(&mut self.lane_tabs, ticket, closing.first().cloned());
        } else {
            let tab = keys_to.filter(|tab| !closing.contains(tab));
            set(&mut self.lane_tabs, ticket, tab);
            set(&mut self.lane_machines, ticket, machine);
        }
        self.resolve(ticket, false, None, false, None, live);
    }

    pub fn park_close(&mut self, ticket: i64, live: &Live) {
        let Some(closing) = self.closing_tabs.remove(&ticket) else { return };
        self.every_key_closes.remove(&ticket);
        self.answering.insert(ticket, closing);
        self.resolve(ticket, false, None, false, None, live);
    }

    pub fn is_creating(&self, tab: &str) -> bool {
        self.tabs.iter().any(|(id, t)| t == tab && self.pending.contains_key(id))
    }

    pub fn early_lane(&self, tab: &str) -> Option<i64> {
        self.early_tabs.iter().filter(|(_, t)| *t == tab).map(|(id, _)| *id).max()
    }

    pub fn lane(&self, focused_tab: Option<&str>) -> Option<i64> {
        if let Some(close) =
            self.every_key_closes.iter().filter(|id| self.closing_tabs.contains_key(id)).max()
        {
            return Some(*close);
        }
        let focused = focused_tab?;
        if let Some(close) = self
            .closing_tabs
            .iter()
            .filter(|(_, c)| c.iter().any(|t| t == focused))
            .map(|(id, _)| *id)
            .max()
        {
            return Some(close);
        }
        self.lane_tabs.iter().filter(|(_, t)| *t == focused).map(|(id, _)| *id).max()
    }

    /// `madeTab`: whether the app passed a read of the made terminal's tab.
    pub fn resolve(
        &mut self,
        ticket: i64,
        awaits_focus: bool,
        workspace: Option<String>,
        made_tab: bool,
        made_surface: Option<u64>,
        live: &Live,
    ) {
        self.early_tabs.remove(&ticket);
        self.tabs.remove(&ticket);
        let Some(generation) = self.pending.remove(&ticket) else { return };
        if self.pending.is_empty() {
            self.replied_at_ns = Some(live.now_ns);
        }
        if awaits_focus {
            self.awaited.insert(generation);
        }
        let refused = self.new_terminals.resolve(ticket, awaits_focus, made_tab, made_surface);
        if !(refused || self.workspace_tickets.contains(&ticket)) {
            return;
        }
        match (awaits_focus, workspace) {
            (true, Some(workspace)) => {
                self.made_workspaces.insert(ticket, workspace);
            }
            _ => {
                if self.workspace_tickets.remove(&ticket) {
                    self.failed_workspaces.insert(ticket);
                }
                let dropped = self.remove_events(|held| held.creation == Some(ticket));
                self.log_dropped(dropped, "its create failed");
            }
        }
    }

    pub fn awaited_workspace(&self) -> Option<&String> {
        self.workspace_tickets.iter().max().and_then(|id| self.made_workspaces.get(id))
    }

    fn newest_unleft_workspace(&self) -> Option<i64> {
        self.workspace_tickets.difference(&self.moved_on_from).max().copied()
    }

    pub fn shown_workspace_to_wait_for(&self) -> Option<&String> {
        self.newest_unleft_workspace().and_then(|id| self.made_workspaces.get(&id))
    }

    pub fn left_workspace_with_keys(&self) -> Option<(i64, &String)> {
        let held: BTreeSet<i64> = self.events.iter().filter_map(|h| h.creation).collect();
        self.workspace_tickets
            .iter()
            .filter(|id| self.moved_on_from.contains(id) && held.contains(id))
            .max()
            .and_then(|id| self.made_workspaces.get(id).map(|w| (*id, w)))
    }

    pub fn owns_keyboard(&self, generation: u64) -> bool {
        self.holds_creation() && self.newest_generation == Some(generation)
    }

    pub fn keeps_keys_from_left_page(
        &self,
        awaits_other_tab: bool,
        generation: u64,
        focused_tab: Option<&str>,
    ) -> bool {
        awaits_other_tab
            && self.owns_keyboard(generation)
            && focused_tab.is_none_or(|tab| !self.made_tabs.contains(tab))
    }

    pub fn person_moved_on(&mut self) {
        if self.workspace_tickets.is_empty() {
            return;
        }
        self.moved_on_from.extend(self.workspace_tickets.iter().copied());
        self.newest_generation = None;
    }

    pub fn person_left_every_creation(&self) -> bool {
        !self.moved_on_from.is_empty()
            && self.moved_on_from.union(&self.failed_workspaces).count() as i64 == self.next_id
    }

    pub fn passes_on(&self, focused_tab: Option<&str>) -> bool {
        if !self.person_left_every_creation()
            || self.awaits_page
            || self.lane(focused_tab).is_some()
        {
            return false;
        }
        !self.events.iter().any(|h| h.creation.is_none())
    }

    /// `pane`: the pane of `tab` (the app's `paneOf(tab)`).
    pub fn bind_new_workspace_keys(
        &mut self,
        tab: Option<String>,
        machine: Option<String>,
        pane: Option<String>,
    ) {
        let unbound: BTreeSet<i64> = self
            .workspace_tickets
            .iter()
            .filter(|id| !self.lane_tabs.contains_key(id))
            .copied()
            .collect();
        let Some(tab) = tab else {
            let dropped = self.remove_events(|h| h.creation.is_some_and(|c| unbound.contains(&c)));
            return self.log_dropped(dropped, "its workspace shows no terminal");
        };
        for id in &unbound {
            self.lane_tabs.insert(*id, tab.clone());
            set(&mut self.lane_machines, *id, machine.clone());
        }
        let Some(pane) = pane else { return };
        for held in &mut self.events {
            if held.creation.is_some_and(|c| unbound.contains(&c)) {
                held.pane = Some(pane.clone());
            }
        }
    }

    pub fn drop_keys(&mut self, shown: Option<&str>) -> bool {
        let unshown: BTreeSet<i64> = self
            .workspace_tickets
            .iter()
            .filter(|id| {
                self.made_workspaces.get(id).is_none_or(|made| Some(made.as_str()) != shown)
            })
            .copied()
            .collect();
        if unshown.is_empty() {
            return false;
        }
        let dropped = self.remove_events(|h| h.creation.is_some_and(|c| unshown.contains(&c)));
        self.log_dropped(dropped, "the window never showed its workspace");
        self.workspace_tickets.retain(|id| !unshown.contains(id));
        true
    }

    fn is_stranded(&self, id: Option<i64>, live: &Live) -> bool {
        id.is_some_and(|id| {
            self.stranded_workspaces.contains(&id)
                || self.new_terminals.waits_for_tab(id, self.lane_tabs.contains_key(&id), live)
        })
    }

    pub fn awaits_made_terminal(&self, live: &Live) -> bool {
        self.events.iter().any(|h| h.creation.is_some_and(|c| self.new_terminals.lost(c, live)))
    }

    pub fn awaits(&self, generation: u64) -> bool {
        self.awaited.contains(&generation)
    }

    pub fn capture(
        &mut self,
        event: u64,
        chord: bool,
        focused_tab: Option<&str>,
        for_new_workspace: bool,
        for_newest_intent: bool,
        pane: Option<String>,
    ) {
        let workspace = if for_new_workspace { self.newest_unleft_workspace() } else { None };
        let own = self.lane(focused_tab).filter(|own| !(*own < 0 && workspace.is_some()));
        let terminal = if for_newest_intent {
            self.new_terminals.ticket(self.newest_creation, own)
        } else {
            None
        };
        self.events.push(Held { event, chord, creation: terminal.or(own).or(workspace), pane });
    }

    pub fn close_key_acts_now(
        &self,
        closes: bool,
        tab_key: Option<TabKey>,
        pane: Option<&str>,
        shown: Option<&str>,
        live: &Live,
    ) -> bool {
        if !closes || tab_key != Some(TabKey::Closes) {
            return closes;
        }
        let workspace =
            if shown.is_some() && self.shown_workspace_to_wait_for().map(String::as_str) == shown {
                self.newest_unleft_workspace()
            } else {
                None
            };
        !self.events.iter().any(|h| {
            (h.pane.as_deref() == pane || (workspace.is_some() && h.creation == workspace))
                && live.kinds.contains_key(&h.event)
        })
    }

    pub fn reduce_tab_keys(&mut self, drops_lone_close: bool, live: &Live) -> (i64, i64) {
        let mut open: BTreeMap<Option<String>, Vec<usize>> = BTreeMap::new();
        let (mut gone, mut pairs, mut lost) = (BTreeSet::new(), 0, 0);
        for (index, key) in self.events.iter().enumerate() {
            match live.kinds.get(&key.event) {
                Some(TabKey::Makes) => open.entry(key.pane.clone()).or_default().push(index),
                Some(TabKey::Closes) => {
                    if let Some(made) = open.get_mut(&key.pane).and_then(Vec::pop) {
                        gone.insert(made);
                        gone.insert(index);
                        pairs += 1;
                    } else if drops_lone_close {
                        gone.insert(index);
                        lost += 1;
                    }
                }
                None => open.clear(),
            }
        }
        if !gone.is_empty() {
            let mut index = 0;
            self.events.retain(|_| {
                let keep = !gone.contains(&index);
                index += 1;
                keep
            });
        }
        (pairs, lost)
    }

    pub fn prepend(&mut self, earlier: Vec<Earlier>, issuer: Option<&HeldLane>) {
        let creation = (self.next_id > 0).then_some(self.next_id);
        let mut entries = Vec::with_capacity(earlier.len());
        for key in earlier {
            let id = if key.lane.as_ref() == issuer {
                creation
            } else {
                key.lane.as_ref().map(|lane| self.adopt(lane))
            };
            entries.push(Held { event: key.event, chord: key.chord, creation: id, pane: key.pane });
        }
        self.events.splice(0..0, entries);
    }

    /// The lowest id of a lane already on `lane.tab` (Swift's `first(where:)` over a dictionary names no order).
    fn adopt(&mut self, lane: &HeldLane) -> i64 {
        if let Some(id) = self.lane_tabs.iter().find(|(_, t)| **t == lane.tab).map(|(id, _)| *id) {
            return id;
        }
        self.adopted += 1;
        let id = -self.adopted;
        self.lane_tabs.insert(id, lane.tab.clone());
        set(&mut self.lane_machines, id, lane.machine.clone());
        set(&mut self.new_terminals.surfaces, id, lane.made_surface);
        id
    }

    pub fn await_surface(&mut self, lane: &HeldLane) {
        self.awaited_tab = Some(lane.tab.clone());
        self.adopt(lane);
    }

    /// `terminal`: the awaited content has a terminal lane (`AwaitedContent.hasTerminalLane`).
    pub fn await_content(&mut self, tab: String, terminal: bool, machine: Option<String>) {
        if !terminal {
            self.awaited_tab = Some(tab);
            self.awaits_page = true;
            return;
        }
        self.await_surface(&HeldLane { tab, machine, made_surface: None });
    }

    pub fn waited_past_reply_bound(&self, bound_ns: Option<i64>, live: &Live) -> bool {
        self.awaits_creation_reply()
            && live.now_ns - self.newest_opened_at_ns.unwrap_or(self.began_ns)
                >= bound_ns.unwrap_or(self.reply_wait_limit_ns)
    }

    pub fn awaits_creation_reply(&self) -> bool {
        self.pending.keys().any(|id| !self.closing_tabs.contains_key(id))
    }

    /// `shows`: the press lanes' tabs that the window shows (the app's `shows(tab)`).
    pub fn end_reply_wait(
        &mut self,
        person_moves: Option<u64>,
        shows: &BTreeSet<String>,
        live: &Live,
    ) {
        let waiting: BTreeSet<i64> =
            self.pending.keys().filter(|id| !self.closing_tabs.contains_key(id)).copied().collect();
        for id in &waiting {
            self.pending.remove(id);
            self.tabs.remove(id);
            self.early_tabs.remove(id);
            self.new_terminals.tickets.remove(id);
            if !self.workspace_tickets.contains(id) {
                self.lane_tabs.remove(id);
                self.lane_machines.remove(id);
            } else if let Some(press) = self.press_lanes.get(id).filter(|press| {
                Some(press.person_moves) == person_moves && shows.contains(&press.lane.tab)
            }) {
                let lane = press.lane.clone();
                self.lane_tabs.insert(*id, lane.tab);
                set(&mut self.lane_machines, *id, lane.machine);
                self.press_delivered.insert(*id);
            } else {
                self.stranded_workspaces.insert(*id);
            }
        }
        self.workspace_tickets.retain(|id| !waiting.contains(id));
        if !waiting.is_empty() && self.pending.is_empty() {
            self.replied_at_ns = Some(live.now_ns);
        }
    }

    fn held_lane(&self, id: Option<i64>, live: &Live) -> Option<HeldLane> {
        let id = id?;
        let tab = self.new_terminals.tab(id, live).or_else(|| self.lane_tabs.get(&id))?;
        Some(HeldLane {
            tab: tab.clone(),
            machine: self.lane_machines.get(&id).cloned(),
            made_surface: self.new_terminals.surfaces.get(&id).copied(),
        })
    }

    /// The lane tab each held key is for, in order (the app asks `isShortcut(event, tab)` of the chords).
    pub fn held_tabs(&self, live: &Live) -> Vec<(u64, Option<String>)> {
        self.events
            .iter()
            .map(|h| (h.event, self.held_lane(h.creation, live).map(|l| l.tab)))
            .collect()
    }

    /// Every held key that is not stranded, as typed; the hold is empty after.
    pub fn take(&mut self, live: &Live) -> Vec<u64> {
        let keys = self
            .events
            .iter()
            .filter(|h| !self.is_stranded(h.creation, live))
            .map(|h| h.event)
            .collect();
        self.events.clear();
        keys
    }

    pub fn take_lane(&mut self, lane: i64, live: &Live) -> Vec<HeldKey> {
        let held = self.held_lane(Some(lane), live);
        let keys = self
            .events
            .iter()
            .filter(|h| h.creation == Some(lane))
            .map(|h| HeldKey::Run { event: h.event, lane: held.clone(), pane: h.pane.clone() })
            .collect();
        self.events.retain(|h| h.creation != Some(lane));
        keys
    }

    /// `shortcuts`: the held chords that are app shortcuts in their lane's tab.
    pub fn take_focused(
        &mut self,
        focused: Option<&str>,
        kept: Option<i64>,
        shortcuts: &BTreeSet<u64>,
        live: &Live,
    ) -> Vec<HeldKey> {
        let mut keys: Vec<HeldKey> = Vec::new();
        let mut untyped = 0;
        for held in self.events.iter().filter(|h| kept.is_none() || h.creation != kept) {
            if self.is_stranded(held.creation, live) {
                untyped += 1;
                continue;
            }
            let lane = self.held_lane(held.creation, live);
            let delivered = held.creation.is_some_and(|c| self.press_delivered.contains(&c));
            let lane = match lane {
                Some(lane) if Some(lane.tab.as_str()) != focused || delivered => lane,
                lane => {
                    keys.push(HeldKey::Run { event: held.event, lane, pane: held.pane.clone() });
                    continue;
                }
            };
            if held.chord && shortcuts.contains(&held.event) {
                keys.push(HeldKey::Command { event: held.event, lane, pane: held.pane.clone() });
                continue;
            }
            match keys.last_mut() {
                Some(HeldKey::Type { events, lane: last, panes }) if *last == lane => {
                    events.push(held.event);
                    panes.push(held.pane.clone());
                }
                _ => keys.push(HeldKey::Type {
                    events: vec![held.event],
                    lane,
                    panes: vec![held.pane.clone()],
                }),
            }
        }
        self.untyped_terminal_keys += untyped;
        self.events.retain(|h| !(kept.is_none() || h.creation != kept));
        keys
    }

    pub fn keys_kept_for_left_workspace(
        &self,
        shown: Option<&str>,
        terminal_ready: bool,
    ) -> Option<i64> {
        if let Some(current) = self.shown_workspace_to_wait_for() {
            if Some(current.as_str()) == shown {
                return None;
            }
        }
        let (ticket, workspace) = self.left_workspace_with_keys()?;
        (Some(workspace.as_str()) != shown || !terminal_ready).then_some(ticket)
    }

    /// The reply bound armed when creation `opened` began passed: whether the hold ends (`onBound(.reply)`).
    pub fn reply_bound_passed(&self, opened: i64) -> bool {
        self.awaits_creation_reply() && self.newest_creation == opened
    }

    /// The hold's limit passed: whether the hold ends (`onBound(.limit)`).
    pub fn limit_passed(&self) -> bool {
        !self.has_pending_creation()
    }

    /// The window is gone: the runs held for a terminal, and how many keys went with it.
    pub fn take_for_closed_window(&mut self, live: &Live) -> (Vec<(Vec<u64>, HeldLane)>, i64) {
        let mut lost = -self.untyped_terminal_keys;
        let mut runs = Vec::new();
        for key in self.take_focused(None, None, &BTreeSet::new(), live) {
            match key {
                HeldKey::Type { events, lane, .. } => runs.push((events, lane)),
                HeldKey::Command { .. } | HeldKey::Run { .. } => lost += 1,
            }
        }
        lost += self.untyped_terminal_keys;
        (runs, lost)
    }

    /// Whether the hold keeps a key (`chord`: Command or Control held).
    pub fn holds(
        &self,
        chord: bool,
        limit_ns: i64,
        expiring: bool,
        closes: bool,
        reply_limit_ns: Option<i64>,
        live: &Live,
    ) -> bool {
        if closes {
            return false;
        }
        if self.has_pending_creation() {
            return !self.waited_past_reply_bound(reply_limit_ns, live);
        }
        if expiring && live.now_ns - self.replied_at_ns.unwrap_or(self.began_ns) >= limit_ns {
            return false;
        }
        if self.holds_creation() {
            return true;
        }
        !(self.is_empty() && chord)
    }
}

#[cfg(test)]
#[path = "creation_hold_tests.rs"]
mod tests;
